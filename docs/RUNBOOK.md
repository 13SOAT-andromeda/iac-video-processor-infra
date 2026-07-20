# Runbook — deploy completo e teste do fluxo de auth (AWS Academy Lab)

**Contexto:** a conta AWS Academy Learner Lab reseta periodicamente (novo account ID, tudo apagado — sem aviso). Este runbook assume que você está partindo de uma conta vazia. Todos os comandos abaixo descobrem valores específicos da conta em tempo de execução (account ID, URLs, endpoints) — não têm nada hardcoded de uma sessão anterior.

**Repos envolvidos** (todos em `~/workspaces/video-processor-hackathon/`):
`iac-video-processor-infra`, `iac-video-processor-data`, `iac-video-processor-gateway`, `video-processor-authorizer`, `video-processor-authentication-api`, `video-processor-users-api`.

**Pré-requisitos:** `~/.aws/credentials` (perfil `default`) com credenciais válidas da sessão do Lab; `aws` CLI, `kubectl`, `docker` (com **Docker Desktop rodando** — ver Troubleshooting), `jq`. `terraform >= 1.11`.

---

## 0. Confirmar que a conta está vazia (opcional, só pra saber onde você está)

```bash
aws sts get-caller-identity
aws eks list-clusters
aws s3 ls
```
Se `eks list-clusters` e `s3 ls` vierem vazios, é reset novo — siga o runbook do início.

## 1. Bootstrap do bucket de state do Terraform

O bucket antigo (`video-processor-bucket-andromeda`) fica preso na conta anterior a cada reset — nomes de bucket S3 são globais. Crie um novo, sufixado com o account ID atual:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="video-processor-bucket-andromeda-${ACCOUNT_ID}"
aws s3 mb "s3://${STATE_BUCKET}" --region us-east-1
```

Guarde `$STATE_BUCKET` — é usado em todo `terraform init` abaixo (`iac-video-processor-infra`, `iac-video-processor-data` e `iac-video-processor-gateway` já têm o `backend "s3"` parametrizado, sem `bucket` fixo no `.tf`; `video-processor-authorizer` e `video-processor-authentication-api` idem).

## 2. `iac-video-processor-infra` — VPC, EKS, ECR, secrets, SNS/SQS

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-infra/prod
terraform init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"
terraform apply -input=false -auto-approve
```
Demora ~10-12min (EKS control plane + node group). Guarde os outputs:
```bash
CLUSTER_NAME=$(terraform output -raw cluster_name)
VPC_ID=$(terraform output -raw vpc_id)
ECR_USERS_API=$(terraform output -raw users_api_ecr_repository_url)
```

## 3. `iac-video-processor-data` — RDS + DynamoDB

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-data/prod
terraform init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"
terraform apply -input=false -auto-approve
```
Demora ~7min (RDS). Guarde os outputs:
```bash
RDS_SECRET_ARN=$(terraform output -raw rds_master_user_secret_arn)
RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
```

## 4. AWS Load Balancer Controller + Ingress

```bash
aws eks update-kubeconfig --region us-east-1 --name "$CLUSTER_NAME"
kubectl get nodes   # confirma pelo menos 1 node Ready

CREDS=$(aws configure export-credentials --profile default)
kubectl create secret generic aws-alb-credentials -n kube-system \
  --from-literal=AWS_ACCESS_KEY_ID="$(echo "$CREDS" | jq -r .AccessKeyId)" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$(echo "$CREDS" | jq -r .SecretAccessKey)" \
  --from-literal=AWS_SESSION_TOKEN="$(echo "$CREDS" | jq -r .SessionToken)" \
  --dry-run=client -o yaml | kubectl apply -f -

helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=true \
  --set region=us-east-1 \
  --set vpcId="$VPC_ID" \
  --set "envFrom[0].secretRef.name=aws-alb-credentials" \
  --wait

kubectl apply -f ~/workspaces/video-processor-hackathon/iac-video-processor-infra/k8s/ingress.yaml
kubectl get ingress video-processor-ingress -n default -w   # Ctrl+C quando ADDRESS aparecer
```

## 5. `video-processor-users-api` — build, push, secrets, deploy no EKS

```bash
cd ~/workspaces/video-processor-hackathon/video-processor-users-api

aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${ECR_USERS_API%%/*}"
docker build --target production -t "$ECR_USERS_API:latest" .
docker push "$ECR_USERS_API:latest"

# Secret com as credenciais de sessão (pro pod acessar Secrets Manager)
kubectl create secret generic aws-session-credentials -n default \
  --from-literal=AWS_ACCESS_KEY_ID="$(echo "$CREDS" | jq -r .AccessKeyId)" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$(echo "$CREDS" | jq -r .SecretAccessKey)" \
  --from-literal=AWS_SESSION_TOKEN="$(echo "$CREDS" | jq -r .SessionToken)" \
  --from-literal=AWS_REGION=us-east-1 \
  --dry-run=client -o yaml | kubectl apply -f -

# Secret do banco — NUNCA rodar get-secret-value direto (fica bloqueado pelo hook
# de segurança). Usar asm-exec pra resolver sem expor o valor:
ASM_EXEC=$(find ~/.claude/plugins/cache/claude-plugins-official/aws-core -iname "asm-exec" | head -1)
DB_HOST="${RDS_ENDPOINT%%:*}"
DB_PORT="${RDS_ENDPOINT##*:}"
python3 "$ASM_EXEC" -- kubectl create secret generic users-api-db-credentials -n default \
  --from-literal=DB_HOST="$DB_HOST" \
  --from-literal=DB_PORT="$DB_PORT" \
  --from-literal="DB_USER={{resolve:secretsmanager:${RDS_SECRET_ARN}:SecretString:username}}" \
  --from-literal="DB_PASSWORD={{resolve:secretsmanager:${RDS_SECRET_ARN}:SecretString:password}}" \
  --from-literal=DB_NAME=usersdb

# Apontar o overlay pra imagem real (NÃO commitar essa edição)
sed -i "s|newName: .*|newName: ${ECR_USERS_API}|" k8s/overlays/aws/kustomization.yaml
kubectl apply -k k8s/overlays/aws/
kubectl rollout status deployment/video-processor-users-api -n default --timeout=120s

QUEUE_URL=$(aws sqs get-queue-url --queue-name video-processor-user-events-queue-prod --query QueueUrl --output text)
kubectl set env deployment/video-processor-users-api-worker -n default SQS_QUEUE_URL="$QUEUE_URL"
kubectl rollout status deployment/video-processor-users-api-worker -n default --timeout=90s
```

## 6. `video-processor-authorizer` — build, push, apply (Lambda)

Lambdas usam `provided:al2023-arm64` — build multi-plataforma sem attestations (Lambda rejeita manifest OCI com provenance/SBOM):

```bash
cd ~/workspaces/video-processor-hackathon/video-processor-authorizer
AUTHZ_ECR="${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/video-processor-authorizer-prod"
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
docker buildx build --platform linux/arm64 --provenance=false --sbom=false -t "$AUTHZ_ECR:latest" --push .

cd terraform/prod
terraform init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"
terraform apply -input=false -auto-approve -var="image_tag=latest"
```

## 7. `iac-video-processor-gateway` — apply PARCIAL (sem rotas `/auth/*`)

**Ciclo real:** o gateway precisa da Lambda `authentication` já existir; `authentication-api` precisa do endpoint do gateway já existir (pra montar `VERIFICATION_BASE_URL`). Resolvido em duas fases.

Comentar temporariamente em `prod/main.tf` e `prod/data.tf` (**nunca commitar essa versão comentada** — só um estado de trabalho local):
- `data.tf`: remover o bloco `data "aws_lambda_function" "authentication"`
- `main.tf`: remover as 3 rotas `POST /auth/login`, `POST /auth/signup`, `GET /auth/verify` do mapa `routes`, e remover o `resource "aws_lambda_permission" "authentication"`

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-gateway/prod
terraform init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"
terraform apply -input=false -auto-approve
API_ENDPOINT=$(terraform output -raw api_endpoint)
```

## 8. `video-processor-authentication-api` — build, push, apply (Lambda)

```bash
cd ~/workspaces/video-processor-hackathon/video-processor-authentication-api
AUTH_ECR="${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/video-processor-authentication-prod"
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
docker buildx build --platform linux/arm64 --provenance=false --sbom=false -t "$AUTH_ECR:latest" --push .

cd terraform/prod
terraform init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"
terraform apply -input=false -auto-approve -var="image_tag=latest"
```
`VERIFICATION_BASE_URL` deve resolver sozinho pro `$API_ENDPOINT` do passo 7 (o gateway já existe).

## 9. `iac-video-processor-gateway` — apply COMPLETO

Reverter o comentário temporário do passo 7 (`git checkout -- prod/main.tf prod/data.tf`, já que nada foi commitado assim) e reaplicar:

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-gateway
git checkout -- prod/main.tf prod/data.tf
cd prod
terraform apply -input=false -auto-approve
```

## 10. Teste end-to-end

```bash
API=$(cd ~/workspaces/video-processor-hackathon/iac-video-processor-gateway/prod && terraform output -raw api_endpoint)

# Signup
curl -s -X POST "$API/auth/signup" -H "Content-Type: application/json" \
  -d '{"name":"John Doe","email":"SEU_EMAIL_UNICO@example.com","password":"MockUserPass!2025","document":"652.904.150-84"}'
# guarde o userId retornado

# Não há serviço de e-mail real — o link de verificação fica na fila SQS:
QUEUE_URL=$(aws sqs get-queue-url --queue-name notification-events-queue-prod --query QueueUrl --output text)
aws sqs receive-message --queue-url "$QUEUE_URL" --max-number-of-messages 1 --wait-time-seconds 3
# extraia o "token=..." do verification_link no corpo da mensagem

curl -s -X GET "$API/auth/verify?token=SEU_TOKEN"

curl -s -X POST "$API/auth/login" -H "Content-Type: application/json" \
  -d '{"email":"SEU_EMAIL_UNICO@example.com","password":"MockUserPass!2025"}'
# guarde o token JWT retornado

curl -s -X GET "$API/users/SEU_USER_ID" -H "Authorization: Bearer SEU_JWT"
# 200 esperado, com name/email/document/created_at/updated_at (sem password_hash nem role)
```

---

## 11. Destroy — derrubar tudo

**Ordem importa:** o ALB criado pelo Load Balancer Controller (via `Ingress`) **não é gerenciado pelo Terraform** — precisa ser apagado manualmente primeiro, senão o `terraform destroy` da `infra` trava tentando apagar a VPC/subnets com ENIs do ALB ainda anexadas. Depois disso, destrua os stacks **na ordem inversa do deploy**: quem consome (via `data` source) sai antes de quem é consumido.

### 11.1 Apagar o Ingress (derruba o ALB) e o controller

```bash
kubectl delete -f ~/workspaces/video-processor-hackathon/iac-video-processor-infra/k8s/ingress.yaml

# aguardar o ALB sumir de verdade antes de seguir
for i in $(seq 1 20); do
  COUNT=$(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?contains(LoadBalancerName, 'k8s-default-videopro')])" --output text)
  [ "$COUNT" = "0" ] && break
  sleep 10
done

helm uninstall aws-load-balancer-controller -n kube-system
kubectl delete secret aws-alb-credentials -n kube-system
```

### 11.2 `iac-video-processor-gateway`

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-gateway/prod
terraform destroy -input=false -auto-approve -refresh=false
```
`-refresh=false` é necessário: o `data "aws_lb" "eks_alb"` não encontra mais nada (o ALB já foi apagado no passo 11.1), e sem `-refresh=false` o Terraform tenta reler esse data source antes do plano de destroy e quebra. Como o destroy só precisa do que já está no state, não precisa reler nada.

### 11.3 `video-processor-authorizer` e `video-processor-authentication-api` (Lambdas)

```bash
cd ~/workspaces/video-processor-hackathon/video-processor-authorizer/terraform/prod
terraform destroy -input=false -auto-approve -var="image_tag=latest"

cd ~/workspaces/video-processor-hackathon/video-processor-authentication-api/terraform/prod
terraform destroy -input=false -auto-approve -refresh=false -var="image_tag=latest"
```
`authentication-api` também precisa de `-refresh=false` — o `data "aws_apigatewayv2_apis" "gateway"` não acha mais nada porque o gateway já foi destruído no passo 11.2. `image_tag` é variável obrigatória sem default; o valor em si não importa pro destroy, só precisa estar presente.

### 11.4 `iac-video-processor-data` (RDS + DynamoDB — **dados perdidos de vez**)

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-data/prod
terraform destroy -input=false -auto-approve
```

### 11.5 `iac-video-processor-infra` (VPC, EKS, ECR, secrets, SNS/SQS)

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-infra/prod
terraform destroy -input=false -auto-approve
```
Demora ~10min (node group + cluster EKS). **Os repositórios ECR que receberam push de imagem vão falhar** (`RepositoryNotEmptyException`) porque o módulo não tem `force_delete`. Esvaziar antes de tentar de novo:

```bash
for repo in video-processor-users-api-prod video-processor-authorizer-prod video-processor-authentication-prod; do
  IMAGE_IDS=$(aws ecr list-images --repository-name "$repo" --query "imageIds[*]" --output json)
  [ "$(echo "$IMAGE_IDS" | jq 'length')" -gt 0 ] && aws ecr batch-delete-image --repository-name "$repo" --image-ids "$IMAGE_IDS"
done
```
Rodar duas vezes se sobrar imagem "presa" atrás de um manifest list (`ImageReferencedByManifestList`) — a segunda passada limpa o que ficou órfão depois que a tag principal já foi removida. Depois, rodar `terraform destroy` de novo — só os 3 `aws_ecr_repository` restantes, o resto já foi destruído na primeira tentativa.

### 11.6 Confirmar que ficou tudo limpo

```bash
aws eks list-clusters --output json
aws ecr describe-repositories --query "repositories[].repositoryName" --output json
aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier" --output json
aws dynamodb list-tables --output json
aws apigatewayv2 get-apis --query "Items[].Name" --output json
aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`]" --output json
```
Tudo deve vir vazio (`[]`). Funções Lambda que sobrarem (`RedshiftEventSubscription`, `ModLabRole`, etc.) são da própria infra do AWS Academy Lab — não é nada nosso, ignorar.

---

## Troubleshooting

**Docker Desktop trava/cai no meio de um build (WSL2):** sintoma é `/usr/bin/docker: Input/output error` ou `command not found`. Verificar com `wsl.exe -l -v` — se `docker-desktop` aparecer `Stopped`, reabrir o Docker Desktop no Windows (fechar de vez pela bandeja antes de reabrir, não só clicar no ícone) e esperar aparecer `Running` antes de tentar de novo.

**Não usar `aws secretsmanager get-secret-value` direto:** fica bloqueado por um hook de segurança. Usar `asm-exec` (`{{resolve:secretsmanager:...}}`) — ver skill `aws-core:aws-secrets-manager`.

**Se `helm`/`kustomize` não estiverem instalados:** `helm` pode ser baixado sem sudo em `~/.local/bin` (`curl -fsSL https://get.helm.sh/helm-v3.21.3-linux-amd64.tar.gz | tar -xz -C /tmp && cp /tmp/linux-amd64/helm ~/.local/bin/`); `kubectl kustomize <dir>` cobre o `kustomize build`, mas não os subcomandos `edit` (por isso o `sed` no passo 5 em vez de `kustomize edit set image`).
