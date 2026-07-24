# Runbook — deploy completo e teste do fluxo de auth + pipeline de vídeo (AWS Academy Lab)

**Contexto:** a conta AWS Academy Learner Lab reseta periodicamente (novo account ID, tudo apagado — sem aviso). Este runbook assume que você está partindo de uma conta vazia. Todos os comandos abaixo descobrem valores específicos da conta em tempo de execução (account ID, URLs, endpoints) — não têm nada hardcoded de uma sessão anterior.

**Repos envolvidos** (todos em `~/workspaces/video-processor-hackathon/`):
`iac-video-processor-infra`, `iac-video-processor-data`, `iac-video-processor-gateway`, `video-processor-authorizer`, `video-processor-authentication-api`, `video-processor-users-api`, `video-processor-converter`, `video-processor-link-api`.

**Pré-requisitos:** `~/.aws/credentials` (perfil `default`) com credenciais válidas da sessão do Lab; `aws` CLI, `kubectl`, `docker` (com **Docker Desktop rodando** — ver Troubleshooting), `jq`. `terraform >= 1.11`. **`DD_API_KEY`** exportado no ambiente (chave da API do Datadog — obrigatória, sem default, usada no apply da infra e no deploy do converter).

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

Guarde `$STATE_BUCKET` — é usado em todo `terraform init` abaixo (`iac-video-processor-infra`, `iac-video-processor-data`, `iac-video-processor-gateway` e `video-processor-converter` já têm o `backend "s3"` parametrizado, sem `bucket` fixo no `.tf`; `video-processor-authorizer` e `video-processor-authentication-api` idem).

## 2. `iac-video-processor-infra` — VPC, EKS, ECR, secrets, SNS/SQS, buckets do pipeline de vídeo

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-infra/prod
terraform init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"
terraform apply -input=false -auto-approve -var="datadog_api_key=${DD_API_KEY}"
```
Demora ~10-12min (EKS control plane + node group). Guarde os outputs:
```bash
CLUSTER_NAME=$(terraform output -raw cluster_name)
VPC_ID=$(terraform output -raw vpc_id)
ECR_USERS_API=$(terraform output -raw users_api_ecr_repository_url)
ECR_WORKER=$(terraform output -raw worker_ecr_repository_url)
ECR_LINK_API=$(terraform output -raw link_api_ecr_repository_url)
VIDEO_BUCKET=$(terraform output -raw video_processor_bucket_name)
ARTIFACTS_BUCKET=$(terraform output -raw artifacts_bucket_name)
STATUS_QUEUE_URL=$(terraform output -raw video_processing_status_queue_url)
UPLOAD_CONFIRMATION_QUEUE_URL=$(terraform output -raw video_upload_confirmation_queue_url)
NOTIFICATION_TOPIC_ARN=$(terraform output -raw notification_events_topic_arn)
```
`VIDEO_BUCKET`/`ARTIFACTS_BUCKET` levam o account ID no nome (`video-processor-bucket-prod-<account_id>`) — mesmo motivo do bucket de state: nome de bucket S3 é global, e sem esse sufixo o `CreateBucket` colide com o nome já usado por outra conta (já aconteceu — outro time do hackathon com a mesma convenção de nome).

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
DYNAMO_LINKS_TABLE=$(terraform output -raw links_table_name)
DYNAMO_EVENTS_TABLE=$(terraform output -raw link_events_table_name)
```
Este repo é só banco (RDS + DynamoDB) — o bucket S3 de vídeo vive em `iac-video-processor-infra` (passo 2), não aqui.

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
O Ingress já inclui o path `/api/links` (pro `link-api`, passo 7), além de `/api/users`.

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
export AWS_REGION=us-east-1   # asm-exec precisa disso explícito, mesmo passando ARN completo
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

## 6. `video-processor-converter` — build, push, apply (Lambdas `processing-worker` + `dlq-handler`)

`deploy/deploy.sh` automatiza build+push da imagem do worker, build+upload do zip do dlq-handler, e o `terraform apply` — usa o mesmo `$STATE_BUCKET` por convenção (`video-processor-bucket-andromeda-${ACCOUNT_ID}`, com fallback se `$STATE_BUCKET` já estiver setado no ambiente):

```bash
cd ~/workspaces/video-processor-hackathon/video-processor-converter
export DD_API_KEY   # já deve estar setado (pré-requisito do runbook)
./deploy/deploy.sh all prod
```
Builda a imagem do worker sem `--provenance`/`--sbom` (Lambda rejeita manifest OCI com attestation), publica em `$ECR_WORKER`; builda `dlq-handler.zip` via `Dockerfile.dlq` e sobe pro `$ARTIFACTS_BUCKET`; aplica o Terraform de `terraform/` com `image_tag`/`dlq_zip_key` computados a partir do SHA do commit atual. Sem passos manuais de secret — as filas/bucket já são resolvidas via `data source` no próprio Terraform desse repo (`terraform/data.tf`).

## 7. `video-processor-link-api` — build, push, secrets, deploy no EKS

```bash
cd ~/workspaces/video-processor-hackathon/video-processor-link-api

aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${ECR_LINK_API%%/*}"
docker build -t "$ECR_LINK_API:latest" .
docker push "$ECR_LINK_API:latest"

# Secret com o JWT_SECRET (jwt-signing-key-prod, mesmo segredo compartilhado
# com authentication-api/authorizer/users-api) — via asm-exec, nunca em texto puro:
python3 "$ASM_EXEC" -- kubectl create secret generic link-api-secrets -n default \
  --from-literal="JWT_SECRET={{resolve:secretsmanager:jwt-signing-key-prod:SecretString}}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Apontar o overlay pra imagem real (NÃO commitar essa edição)
sed -i "s|newName: .*|newName: ${ECR_LINK_API}|" k8s/overlays/aws/kustomization.yaml
kubectl apply -k k8s/overlays/aws/

# Valores que contêm o account ID / mudam por sessão — setados via kubectl set env,
# não hardcoded no manifesto (mesmo padrão do SQS_QUEUE_URL do users-api-worker, passo 5)
kubectl set env deployment/video-processor-link-api -n default \
  STATUS_QUEUE_URL="$STATUS_QUEUE_URL" \
  UPLOAD_CONFIRMATION_QUEUE_URL="$UPLOAD_CONFIRMATION_QUEUE_URL" \
  NOTIFICATION_TOPIC_ARN="$NOTIFICATION_TOPIC_ARN" \
  S3_BUCKET="$VIDEO_BUCKET" \
  DYNAMO_LINKS_TABLE="$DYNAMO_LINKS_TABLE" \
  DYNAMO_EVENTS_TABLE="$DYNAMO_EVENTS_TABLE"

kubectl rollout status deployment/video-processor-link-api -n default --timeout=90s
```

## 8. `video-processor-authorizer` — build, push, apply (Lambda)

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

## 9. `iac-video-processor-gateway` — apply PARCIAL (sem rotas `/auth/*`)

**Ciclo real:** o gateway precisa da Lambda `authentication` já existir; `authentication-api` precisa do endpoint do gateway já existir (pra montar `VERIFICATION_BASE_URL`). Resolvido em duas fases. As rotas `/links` (pro `link-api`) não têm esse ciclo — entram já nessa primeira fase, sem precisar comentar nada.

Comentar temporariamente em `prod/main.tf` e `prod/data.tf` (**nunca commitar essa versão comentada** — só um estado de trabalho local):
- `data.tf`: remover o bloco `data "aws_lambda_function" "authentication"`
- `main.tf`: remover as 3 rotas `POST /auth/login`, `POST /auth/signup`, `GET /auth/verify` do mapa `routes`, e remover o `resource "aws_lambda_permission" "authentication"`

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-gateway/prod
terraform init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"
terraform apply -input=false -auto-approve
API_ENDPOINT=$(terraform output -raw api_endpoint)
```

## 10. `video-processor-authentication-api` — build, push, apply (Lambda)

```bash
cd ~/workspaces/video-processor-hackathon/video-processor-authentication-api
AUTH_ECR="${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/video-processor-authentication-prod"
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
docker buildx build --platform linux/arm64 --provenance=false --sbom=false -t "$AUTH_ECR:latest" --push .

cd terraform/prod
terraform init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"
terraform apply -input=false -auto-approve -var="image_tag=latest"
```
`VERIFICATION_BASE_URL` deve resolver sozinho pro `$API_ENDPOINT` do passo 9 (o gateway já existe).

## 11. `iac-video-processor-gateway` — apply COMPLETO

Reverter o comentário temporário do passo 9 (`git checkout -- prod/main.tf prod/data.tf`, já que nada foi commitado assim) e reaplicar:

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-gateway
git checkout -- prod/main.tf prod/data.tf
cd prod
terraform apply -input=false -auto-approve
```

## 12. Teste end-to-end (auth + pipeline de vídeo)

### 12.1 Auth: signup → verify → login → GET /users/:id

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
# guarde o token JWT retornado (JWT_TOKEN abaixo)

curl -s -X GET "$API/users/SEU_USER_ID" -H "Authorization: Bearer $JWT_TOKEN"
# 200 esperado, com name/email/document/created_at/updated_at (sem password_hash nem role)
```

### 12.2 Pipeline de vídeo: criar link → upload → processar → download

Fixtures em `video-processor-converter/test/fixtures/`: `sample_720p.mp4`/`sample_1080p.mp4` (sucesso esperado), `sample_1440p.mp4` (`PROCESSING_FAILED`/`invalid_resolution` — acima de 1920x1080), `invalid_video.mp4` (garbage, não é vídeo válido — testa o caminho de retry/DLQ).

```bash
FIXDIR=~/workspaces/video-processor-hackathon/video-processor-converter/test/fixtures

# 1. Criar o link -> devolve linkId + uploadUrl (presigned PUT, expira em 1h)
RESP=$(curl -s -X POST "$API/links" -H "Authorization: Bearer $JWT_TOKEN" -H "Content-Type: application/json" \
  -d '{"fileName":"sample_720p.mp4","fileSize":48200,"isPrivate":false}')
LINK_ID=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['linkId'])")
UPLOAD_URL=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['uploadUrl'])")

# 2. Upload direto pro S3 (fora do domínio da API — presigned PUT já assinado).
#    Não existe callback de confirmação: o próprio S3 dispara o ObjectCreated,
#    que via fan-out SNS (video-upload-events-topic) alimenta ao mesmo tempo
#    a video-processing-queue (Lambda worker) e a video-upload-confirmation-queue
#    (link-api confirma UPLOAD_COMPLETED -> PROCESSING_PENDING sozinho).
curl -s -X PUT "$UPLOAD_URL" --data-binary "@$FIXDIR/sample_720p.mp4"

# 3. Poll do status (sem simulate-worker — processamento 100% real; a transição
#    UPLOAD_COMPLETED -> PROCESSING_PENDING também é automática, pode levar
#    alguns segundos a mais que antes do processamento aparecer)
curl -s "$API/links/$LINK_ID" -H "Authorization: Bearer $JWT_TOKEN"
# esperado: status PROCESSING_COMPLETED (com s3ProcessedKey) em poucos segundos

# 4. Audit trail completo (o "reason" de uma falha só aparece aqui, em metadata)
curl -s "$API/links/$LINK_ID/events" -H "Authorization: Bearer $JWT_TOKEN"

# 5. Download do zip processado
curl -s "$API/links/$LINK_ID/download" -H "Authorization: Bearer $JWT_TOKEN"
```

Repita os passos 1-4 pra `sample_1080p.mp4` (sucesso, no limite exato aceito) e `sample_1440p.mp4` (espera `PROCESSING_FAILED`/`invalid_resolution` em ~10s, sem passar pela DLQ — é rejeição de negócio numa única invocação, não um erro transitório).

**Caso da DLQ (`invalid_video.mp4`):** o `video-processing-queue` em prod tem `visibility_timeout_seconds = 1800` e `maxReceiveCount = 3` — o worker falha o `ffprobe` (garbage não é container de vídeo válido), pede retry, e só cai na `video-processing-dlq` depois de **~90min** (3 tentativas × 30min). O `dlq-handler` então publica `PROCESSING_FAILED`/`max_retries_exceeded`. Suba esse arquivo **primeiro**, em paralelo com o resto do teste, pra não bloquear — ou pule esse caso se não tiver 90min disponíveis.

---

## 13. Destroy — derrubar tudo

**Ordem importa:** o ALB criado pelo Load Balancer Controller (via `Ingress`) **não é gerenciado pelo Terraform** — precisa ser apagado manualmente primeiro, senão o `terraform destroy` da `infra` trava tentando apagar a VPC/subnets com ENIs do ALB ainda anexadas. Depois disso, destrua os stacks **na ordem inversa do deploy**: quem consome (via `data` source) sai antes de quem é consumido.

### 13.1 Apagar o Ingress (derruba o ALB) e o controller

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

### 13.2 `iac-video-processor-gateway`

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-gateway/prod
terraform destroy -input=false -auto-approve -refresh=false
```
`-refresh=false` é necessário: o `data "aws_lb" "eks_alb"` não encontra mais nada (o ALB já foi apagado no passo 13.1), e sem `-refresh=false` o Terraform tenta reler esse data source antes do plano de destroy e quebra. Como o destroy só precisa do que já está no state, não precisa reler nada.

### 13.3 `video-processor-authorizer` e `video-processor-authentication-api` (Lambdas)

```bash
cd ~/workspaces/video-processor-hackathon/video-processor-authorizer/terraform/prod
terraform destroy -input=false -auto-approve -var="image_tag=latest"

cd ~/workspaces/video-processor-hackathon/video-processor-authentication-api/terraform/prod
terraform destroy -input=false -auto-approve -refresh=false -var="image_tag=latest"
```
`authentication-api` também precisa de `-refresh=false` — o `data "aws_apigatewayv2_apis" "gateway"` não acha mais nada porque o gateway já foi destruído no passo 13.2. `image_tag` é variável obrigatória sem default; o valor em si não importa pro destroy, só precisa estar presente.

### 13.4 `video-processor-converter` (Lambdas `processing-worker` + `dlq-handler`)

```bash
cd ~/workspaces/video-processor-hackathon/video-processor-converter/terraform
terraform destroy -input=false -auto-approve \
  -var="environment=prod" -var="image_tag=latest" -var="dlq_zip_key=dlq-handler/latest.zip" -var="dd_api_key=${DD_API_KEY}"
```
`image_tag`/`dlq_zip_key`/`dd_api_key` são obrigatórios sem default; os valores em si não importam pro destroy (pode usar `latest` mesmo que não seja a tag real publicada).

### 13.5 `video-processor-link-api` (recursos k8s, não gerenciados por Terraform)

```bash
kubectl delete -k ~/workspaces/video-processor-hackathon/video-processor-link-api/k8s/overlays/aws
kubectl delete secret link-api-secrets -n default
```

### 13.6 `iac-video-processor-data` (RDS + DynamoDB — **dados perdidos de vez**)

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-data/prod
terraform destroy -input=false -auto-approve
```

### 13.7 `iac-video-processor-infra` (VPC, EKS, ECR, secrets, SNS/SQS, buckets)

```bash
cd ~/workspaces/video-processor-hackathon/iac-video-processor-infra/prod
terraform destroy -input=false -auto-approve -var="datadog_api_key=${DD_API_KEY}"
```
Demora ~10min (node group + cluster EKS). **Os repositórios ECR que receberam push de imagem vão falhar** (`RepositoryNotEmptyException`) porque o módulo não tem `force_delete`, e os **buckets `video_processor`/`artifacts` que tiverem objeto vão falhar** (`BucketNotEmpty` — `artifacts` não tem `force_destroy`, e `video_processor` pode não esvaziar sozinho se o destroy anterior falhar antes de tentar). Esvaziar antes de tentar de novo:

```bash
for repo in video-processor-users-api-prod video-processor-authorizer-prod video-processor-authentication-prod video-processor-worker-prod video-processor-link-api-prod; do
  IMAGE_IDS=$(aws ecr list-images --repository-name "$repo" --query "imageIds[*]" --output json)
  [ "$(echo "$IMAGE_IDS" | jq 'length')" -gt 0 ] && aws ecr batch-delete-image --repository-name "$repo" --image-ids "$IMAGE_IDS"
done

aws s3 rm "s3://${VIDEO_BUCKET}" --recursive
aws s3 rm "s3://${ARTIFACTS_BUCKET}" --recursive
```
Rodar o loop de ECR duas vezes se sobrar imagem "presa" atrás de um manifest list (`ImageReferencedByManifestList`) — a segunda passada limpa o que ficou órfão depois que a tag principal já foi removida. Depois, rodar `terraform destroy` de novo — só os recursos que falharam na primeira tentativa, o resto já foi destruído.

### 13.8 Confirmar que ficou tudo limpo

```bash
aws eks list-clusters --output json
aws ecr describe-repositories --query "repositories[].repositoryName" --output json
aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier" --output json
aws dynamodb list-tables --output json
aws apigatewayv2 get-apis --query "Items[].Name" --output json
aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`]" --output json
aws s3 ls   # só o bucket de state (video-processor-bucket-andromeda-<account_id>) deve sobrar
```
Tudo deve vir vazio (`[]`), exceto o `s3 ls` (bucket de state). Funções Lambda que sobrarem (`RedshiftEventSubscription`, `ModLabRole`, etc.) são da própria infra do AWS Academy Lab — não é nada nosso, ignorar.

---

## Troubleshooting

**Docker Desktop trava/cai no meio de um build (WSL2):** sintoma é `/usr/bin/docker: Input/output error` ou `command not found`. Verificar com `wsl.exe -l -v` — se `docker-desktop` aparecer `Stopped`, reabrir o Docker Desktop no Windows (fechar de vez pela bandeja antes de reabrir, não só clicar no ícone) e esperar aparecer `Running` antes de tentar de novo.

**Não usar `aws secretsmanager get-secret-value` direto:** fica bloqueado por um hook de segurança. Usar `asm-exec` (`{{resolve:secretsmanager:...}}`) — ver skill `aws-core:aws-secrets-manager`. **Exporte `AWS_REGION=us-east-1` antes de chamar `asm-exec`** — sem isso, a resolução falha (`Failed to resolve: ...`) mesmo passando o ARN completo do secret.

**Se `helm`/`kustomize` não estiverem instalados:** `helm` pode ser baixado sem sudo em `~/.local/bin` (`curl -fsSL https://get.helm.sh/helm-v3.21.3-linux-amd64.tar.gz | tar -xz -C /tmp && cp /tmp/linux-amd64/helm ~/.local/bin/`); `kubectl kustomize <dir>` cobre o `kustomize build`, mas não os subcomandos `edit` (por isso o `sed` nos passos 5/7 em vez de `kustomize edit set image`).

**`terraform apply`/`destroy` rodando em background parecer travado por vários minutos num único recurso** (ex.: `aws_lambda_permission`, `aws_apigatewayv2_vpc_link`): confira se não há **outro processo `terraform` concorrente** rodando contra o mesmo state antes de assumir que travou de verdade — um apply anterior interrompido (timeout do terminal, Ctrl+C) pode continuar rodando no servidor e criar recursos duplicados (API Gateway, Security Group, Log Group, permissão de Lambda) que colidem com uma segunda tentativa. Se isso acontecer: identifique com `aws apigatewayv2 get-apis` (ou o serviço equivalente) qual API/recurso é o órfão, apague-o manualmente (ou `terraform import` se já estiver em uso por um VPC Link/recurso que vale a pena preservar) e rode o apply de novo.

**Scripts `.sh` com erro `bash\r: No such file or directory`:** o ambiente pode ter `core.autocrlf=true` no Git, convertendo LF em CRLF na working tree e quebrando o shebang. Rodar `sed -i 's/\r$//' caminho/do/script.sh` antes de executar (não precisa mexer no `core.autocrlf` nem recommitar — o blob no repo já está em LF, só a working tree local ficou CRLF).
