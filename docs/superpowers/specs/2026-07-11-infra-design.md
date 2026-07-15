# Spec — iac-video-processor-infra

**Data:** 2026-07-11 (atualizado 2026-07-13 — EKS volta ao escopo; Ingress centralizado após revisão do mesmo dia; atualizado 2026-07-14 — pontos em aberto resolvidos, state locking, contratos de `dev/`; renomeado 2026-07-14 — futuro serviço `video-processor-api` passa a se chamar `video-processor-converter`)
**Status:** Aprovado para virar plano de implementação
**Repo antigo de referência:** `iac-tech-challenge-infra`
**Spec guarda-chuva:** `docs/superpowers/specs/2026-07-11-video-processor-auth-infra-migration-design.md` (workspace raiz)

---

## 1. Responsabilidade

Provisionar a infraestrutura de rede e compute compartilhada pelos serviços do domínio de autenticação/usuários:

- **VPC** com subnets públicas/privadas — necessária tanto para o `users-api` (EKS) quanto para as Lambdas de `authentication`/`authorizer` acessarem DynamoDB/Secrets Manager.
- **EKS (cluster + node group)** — hospeda `video-processor-users-api` e, futuramente, `video-processor-converter` e `links-generator` (specs futuras). **Atualizado 2026-07-13:** volta ao escopo — `users-api` deixou de ser Lambda e passou a ser uma API containerizada (ver spec guarda-chuva e `video-processor-users-api`, seção 8).
- **AWS Load Balancer Controller** (Helm, instalado via pipeline) — provisiona dinamicamente o Application Load Balancer compartilhado a partir de um **único `Ingress` centralizado, mantido por este repo** (ver seção 6; corrigido 2026-07-13 — não é um `Ingress` por serviço).
- **Módulo Lambda genérico** — empacotamento/deploy reutilizado pelos 2 repos de serviço que continuam Lambda (`video-processor-authentication-api`, `video-processor-authorizer`).
- **ECR** — um repositório por serviço containerizado (`users-api` e futuros). Deixa de ser condicional: é essencial agora que há containers reais rodando no EKS.

---

## 2. Módulos Terraform (Registry, confirmados via MCP em 2026-07-11, EKS confirmado em 2026-07-13)

| Módulo | Versão | Uso |
|---|---|---|
| `terraform-aws-modules/vpc/aws` | 6.6.1 | VPC + subnets públicas/privadas + route tables |
| `terraform-aws-modules/eks/aws` | 21.24.0 | Cluster EKS + node group — **novo nesta atualização** |
| `terraform-aws-modules/lambda/aws` | 8.8.0 | Empacotamento/deploy de função Lambda (consumido por `authentication`/`authorizer`) |
| `terraform-aws-modules/ecr/aws` | 3.2.0 | Repositórios ECR por serviço containerizado |
| provider `hashicorp/aws` | 6.54.0 | — |
| Terraform CLI | `>= 1.11` | **Atualizado 2026-07-14** — requisito para `use_lockfile` (locking nativo do backend S3, GA a partir da 1.11, ver seção 3.1); mais restritivo que o `>= 1.7.0` do `iac-video-processor-gateway`, sem problema já que são states independentes |

Reconsultar `get_latest_module_version` no MCP do Terraform antes do `terraform init` real — estes números são um snapshot da data deste spec. Versão do módulo `terraform-aws-modules/eks/aws` 21.24.0 confirmada como a mais recente em 2026-07-14 (release notes do repo no GitHub); campos de IAM do submódulo `eks-managed-node-group` confirmados por leitura direta do código-fonte (`create_iam_role`, `iam_role_arn` — ver seção 5).

---

## 3. Estrutura de pastas

```
iac-video-processor-infra/
├── dev/     # equivalente ao antigo localstack/ — state local, aplicado via tflocal
├── prod/    # equivalente ao antigo aws/ — state remoto (S3), aplicado via terraform real
├── modules/ # (se necessário customizar algo em cima do módulo de registry — avaliar no plano se é preciso)
└── k8s/
    └── ingress.yaml   # Ingress único centralizado — ver seção 6.1
```

Backend do state em `prod/`: bucket S3 dedicado, key `video-processor-infra/terraform.tfstate` (mesmo padrão de `iac-tech-challenge-infra/aws/main.tf`, só troca o prefixo do nome).

O pipeline CI (`.github/workflows/`) deste repo, após o `terraform apply`, roda o passo de instalação do AWS Load Balancer Controller via Helm (seção 6) — igual ao `iac-tech-challenge-infra/.github/workflows/infra-pipeline.yml` já faz hoje.

### 3.1 State locking (decisão 2026-07-14 — diferente do débito aceito no `iac-video-processor-gateway`)

O backend S3 de `prod/` usa `use_lockfile = true` (locking nativo do Terraform, GA na 1.11, sem tabela DynamoDB) em vez de ficar sem locking. Diferente do `iac-video-processor-gateway` — onde a ausência de locking ficou registrada como débito técnico aceito (API Gateway é rápido de recriar) —, aqui o recurso de maior blast radius é o cluster EKS (dezenas de minutos para recriar, node group + control plane), então o custo de dois `apply` concorrentes é mais alto. `use_lockfile` só exige `s3:GetObject`/`s3:PutObject`/`s3:DeleteObject` no arquivo de lock, dentro do mesmo bucket de state já usado — nenhuma permissão IAM nova além da que o Academy já concede para o próprio state.

### 3.2 Escopo real de `dev/` (LocalStack Community)

LocalStack Community mocka a API do EKS (aceita `terraform apply` para `aws_eks_cluster`/node group), mas **não roda um control plane Kubernetes de verdade** — não há `kubectl`/Helm funcional contra esse cluster. Portanto:

- `dev/` provisiona, via Terraform, **VPC + EKS (mock) + ECR** — reproduz exatamente o que `iac-tech-challenge-infra/localstack/main.tf` já fazia (chamando os módulos contra os endpoints do LocalStack).
- Os passos de Helm (AWS Load Balancer Controller) e `kubectl apply -f k8s/ingress.yaml` do pipeline CI (seção 6) **só existem no pipeline de `prod/`** — não há equivalente em `dev/`, mesma lógica que levou o `iac-video-processor-gateway/dev/` a hardcodar um ARN de listener de ALB como `local` em vez de descobrir um real (LocalStack Community não tem esse fluxo).
- **IAM em `dev/`:** `LabRole` não existe no LocalStack. Em vez de criar uma role manual (como o repo antigo fazia com `aws_iam_role.eks_local`), `dev/` usa o default do módulo `terraform-aws-modules/eks/aws` (`create_iam_role = true`, sem override) — o módulo cria a role sozinho, sem precisar de um recurso `aws_iam_role` adicional escrito à mão. Só `prod/` referencia `LabRole` (seção 5).

---

## 4. Recursos-chave

- **VPC (`prod/`):** tag `Name = video-processor-vpc` — **este nome de tag é o contrato**: `iac-video-processor-data` e `iac-video-processor-gateway` vão procurá-la via `data "aws_vpc"` filtrando por essa tag, exatamente como `iac-tech-challenge-data/aws/data.tf` faz hoje com `eks-tech-challenge-vpc`.
- **VPC (`dev/`):** tag `Name = video-processor-vpc-local` — **contrato confirmado 2026-07-14**: `iac-video-processor-gateway/dev/data.tf` (já implementado) filtra `data "aws_vpc"` exatamente por esse valor. Se este repo criar a VPC de `dev/` com outra tag, o `tflocal plan` do gateway falha ao não encontrar a VPC — não é uma escolha livre, é um contrato já fixado pelo lado consumidor.
- **CIDR e AZs (resolvido 2026-07-14):** `10.0.0.0/16`, 2 AZs (`us-east-1a`, `us-east-1b`) — replica `iac-tech-challenge-infra/modules/vpc/variables.tf` (mesmos defaults `vpc_cidr`/`azs`), subnets `/24` via `cidrsubnet(var.vpc_cidr, 8, index)`, mesma lógica de tags de auto-discovery abaixo.
- **Subnets privadas:** tag `Name` contendo `*-private-*` (mesmo padrão de filtro usado pelos repos consumidores antigos — manter para não quebrar o `data` source). Subnets públicas precisam da tag `kubernetes.io/role/elb = 1` (auto-discovery do AWS Load Balancer Controller para colocar o ALB nelas).
- **Conectividade de saída — NAT Gateway (decisão revista 2026-07-13, topologia resolvida 2026-07-14):** a recomendação anterior (VPC Endpoints) valia só para 2 Lambdas alcançando DynamoDB + Secrets Manager. Com o EKS de volta, os nodes/controller precisam alcançar bem mais serviços (ECR — API + Docker registry, EKS API, ELB API, STS, CloudWatch Logs) — replicar 6+ VPC Endpoints é mais complexo do que 1 NAT Gateway, e o custo de algumas horas de lab é irrelevante frente ao tempo de setup. **Decisão: 1 NAT Gateway único** (não 1 por AZ), compartilhado pelas duas route tables privadas — mesmo padrão do repo antigo (`iac-tech-challenge-infra/modules/vpc/main.tf`: 1 `aws_nat_gateway` na subnet pública do índice 0, referenciado pela única `aws_route_table.private`).
- **ECR:** um repositório por serviço containerizado (`video-processor-users-api` e futuros `video-processor-converter`/`links-generator`), lifecycle policy para não acumular imagens antigas indefinidamente (mesmo padrão do `modules/ecr` antigo). `authentication`/`authorizer` continuam Lambda via zip — sem ECR.
- **Tag do ALB compartilhado (corrigido 2026-07-13):** `video-processor/alb = unified` — tag **determinística e exclusiva**, aplicada via annotation `alb.ingress.kubernetes.io/tags` no `Ingress` centralizado (seção 6), consumida pelo `iac-video-processor-gateway` via `data.aws_lb`. **Não** usar a tag genérica `kubernetes.io/cluster/video-processor-eks-prod = owned` para esse fim — ela é aplicada a qualquer ALB do cluster, e com mais de um ALB o `data.aws_lb` fica ambíguo (foi exatamente o bug que o `tech-challenge` corrigiu — ver seção 6).

---

## 5. LabRole (AWS Academy) — onde a role é de fato usada

Diferente do `iac-video-processor-gateway` (que não toca em IAM, ver aquele spec seção 6.1), **este repo é o único ponto do domínio de autenticação/usuários que referencia a `LabRole` diretamente**, porque é aqui que existe compute de verdade (cluster EKS, node group):

```hcl
data "aws_iam_role" "lab_role" {
  name = "LabRole"
}
```

- **Cluster EKS (`prod/`):** `create_iam_role = false`, `iam_role_arn = data.aws_iam_role.lab_role.arn` — reaproveita a `LabRole` em vez de criar uma role nova (o módulo `terraform-aws-modules/eks/aws` cria uma por padrão; isso precisa ser desligado explicitamente, senão o `terraform apply` falha no Academy por falta de `iam:CreateRole`).
- **Node group (`prod/`) — nome do campo resolvido 2026-07-14:** confirmado por leitura direta do código-fonte do módulo (`terraform-aws-eks` tag `v21.24.0`, `modules/eks-managed-node-group/variables.tf`) — o campo é **`create_iam_role`** (não `create_node_iam_role`; essa variação não existe nesta versão), mesmo nome usado no nível do cluster. `create_iam_role = false`, `iam_role_arn = data.aws_iam_role.lab_role.arn`. Replica o padrão do `modules/eks` antigo, que já usava `role_arn = var.role_arn` (default `"LabRole"`) tanto pro cluster quanto pro node group.
- **Node group (`dev/`):** `LabRole` não existe no LocalStack — `dev/` deixa `create_iam_role` no default (`true`), o módulo cria a role sozinho (ver seção 3.2). Só `prod/` referencia `LabRole`.
- **Versão do EKS e sizing do node group (resolvido 2026-07-14):** `1.30`, `t3.medium`, `desired_size = 1`/`min_size = 1`/`max_size = 2` — replica `iac-tech-challenge-infra/modules/eks/main.tf` (`ami_type = "AL2023_x86_64_STANDARD"`). Decisão YAGNI: nesta fase só `users-api` roda no cluster; aumentar depois via `scaling_config` quando `video-processor-converter`/`links-generator` chegarem, sem recriar o node group.
- **Convenção de nomes por ambiente (2026-07-14):** cluster `video-processor-eks-${var.environment}` (não um nome fixo sem sufixo) — mesmo padrão adotado no `iac-video-processor-gateway`, onde o recurso do módulo foi renomeado para `video-processor-api-gateway-${var.environment}` durante a implementação, para manter os 3 repos IaC consistentes entre si.
- **`enable_irsa = false`:** decisão deliberada — **não usamos IRSA/OIDC provider** nesta arquitetura. Confirmado ao inspecionar os pipelines antigos (`tech-challenge-s1/.github/workflows/deploy.yml`, `tech-challenge-users/.github/workflows/deploy.yml`): o padrão real do time é injetar as credenciais temporárias da sessão do Academy (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`, vindas de secrets do GitHub Actions) diretamente como Kubernetes `Secret`, consumido via `envFrom`/env vars pelos pods que precisam da AWS SDK — tanto pelo AWS Load Balancer Controller quanto pela aplicação (`users-api` vai precisar disso pra falar com DynamoDB, ver `video-processor-users-api`, seção 8.2). IRSA exigiria criar um OIDC provider (`iam:CreateOpenIDConnectProvider`) e uma role nova com trust policy — outra criação de recurso IAM, evitada pelo mesmo motivo que a `LabRole` é reaproveitada em vez de criar roles novas.
- **`create_kms_key = false`:** o repo antigo (`modules/eks/main.tf`) não configurava `encryption_config` no `aws_eks_cluster` — sem criptografia de secrets via KMS. Mantemos esse padrão (não criar uma KMS key nova) para reduzir a superfície de permissões exigidas no Academy; encryption at rest de secrets do cluster fica como débito técnico, não bloqueador nesta fase.

**Resumo do contrato de IAM entre os repos:** só `iac-video-processor-infra` busca e usa `LabRole` via Terraform. `iac-video-processor-gateway` não usa IAM nenhuma. Os repos de serviço Lambda (`authentication`, `authorizer`) usam `LabRole` como execution role da própria função (mesmo padrão do repo antigo). `users-api` (e futuras APIs em EKS) não usam IAM role nenhuma diretamente — recebem credenciais de sessão via Kubernetes `Secret`, não via role.

---

## 6. AWS Load Balancer Controller (Helm, via pipeline CI — não Terraform)

**Decisão:** instalado via `helm upgrade --install` dentro do pipeline CI deste repo (`iac-video-processor-infra`), replicando o passo já existente em `iac-tech-challenge-infra/.github/workflows/infra-pipeline.yml`. **Não** usamos o provider `helm` do Terraform — mantém consistência com o único precedente real do time (Helm sempre via CLI de pipeline, nunca via Terraform), e evita depender de conectividade do runner do Terraform Cloud/local com o control plane do EKS recém-criado no mesmo apply.

**Escopo confirmado 2026-07-14:** este passo (e o `kubectl apply -f k8s/ingress.yaml` da seção 6.1) só existe no pipeline de `prod/` — LocalStack Community não roda um control plane Kubernetes de verdade contra o cluster mockado de `dev/` (ver seção 3.2). Não há equivalente de Helm/Ingress em `dev/`.

**Não duplicar em cada repo de serviço** (correção em relação ao padrão antigo, onde tanto `iac-tech-challenge-infra` quanto `tech-challenge-s1` reinstalavam o mesmo controller de forma redundante) — instala **uma vez só**, aqui, depois do `terraform apply` que cria o cluster.

```yaml
# .github/workflows/infra-pipeline.yml (depois do terraform apply)
- name: Update Kubeconfig
  run: aws eks update-kubeconfig --region ${{ secrets.AWS_REGION }} --name video-processor-eks-prod

- name: Install AWS Load Balancer Controller
  run: |
    kubectl create secret generic aws-alb-credentials \
      --from-literal=AWS_ACCESS_KEY_ID=${{ secrets.AWS_ACCESS_KEY_ID }} \
      --from-literal=AWS_SECRET_ACCESS_KEY=${{ secrets.AWS_SECRET_ACCESS_KEY }} \
      --from-literal=AWS_SESSION_TOKEN=${{ secrets.AWS_SESSION_TOKEN }} \
      -n kube-system \
      --dry-run=client -o yaml | kubectl apply -f -

    helm repo add eks https://aws.github.io/eks-charts
    helm repo update eks
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName=video-processor-eks-prod \
      --set serviceAccount.create=true \
      --set region=${{ secrets.AWS_REGION }} \
      --set vpcId=$VPC_ID \
      --set "envFrom[0].secretRef.name=aws-alb-credentials" \
      --wait
```

### 6.1 Ingress centralizado (corrigido 2026-07-13 — substitui "Ingress por serviço + group.name")

A primeira versão deste spec propunha que cada serviço (`users-api` e futuros) declarasse seu próprio `Ingress`, coordenados só por uma annotation `group.name` compartilhada. **Essa é exatamente a decisão que o `tech-challenge` tomou primeiro e depois reverteu** (ver `tech-challenge-fiap/docs/superpowers/specs/2026-05-19-centralized-ingress-design.md`): sem um dono único do arquivo de roteamento, bastou um serviço esquecer a annotation pra gerar um ALB extra, `internet-facing`, por fora do API Gateway — e a tag genérica de cluster ficou ambígua pro `data.aws_lb` do gateway (múltiplos ALBs com a mesma tag).

**Decisão (adotada aqui desde o início, não como correção pós-bug):** um único recurso `Ingress`, mantido **por este repo**, não pelos repos de serviço.

```
iac-video-processor-infra/
└── k8s/
    └── ingress.yaml
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: video-processor-ingress
  namespace: default
  annotations:
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/tags: video-processor/alb=unified
    alb.ingress.kubernetes.io/healthcheck-path: /health
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /users
            pathType: Prefix
            backend:
              service:
                name: video-processor-users-api-svc
                port:
                  number: 80
```

- `scheme: internal` — ALB não exposto direto à internet, só alcançável pelo VPC Link do `iac-video-processor-gateway` (mesma decisão de segurança do `tech-challenge`).
- `alb.ingress.kubernetes.io/tags: video-processor/alb=unified` — tag determinística e exclusiva (não a tag genérica de cluster), consumida pelo `data.aws_lb` do gateway (ver `iac-video-processor-gateway`, seção 5).
- Este `Ingress` é aplicado por este repo (`kubectl apply -f k8s/ingress.yaml`, pipeline deste repo, depois do EKS + Load Balancer Controller estarem de pé), **não** pelo pipeline de `video-processor-users-api` — o repo de serviço entrega só `Deployment` + `Service` (porta 80), sem `Ingress` próprio (ver seção 7 e `video-processor-users-api`, seção 8.2, corrigidos).
- **Adicionando um serviço novo no futuro** (`video-processor-converter`, `links-generator`): o time de infra soma uma entrada em `rules[0].http.paths` deste `Ingress` apontando pro `Service` do novo serviço — nenhum `Ingress` novo, nenhum ALB novo.

---

## 7. Relação com o Terraform/manifests dos repos de serviço

- **`video-processor-authentication-api`, `video-processor-authorizer`** (continuam Lambda): cada um tem seu próprio `terraform/` local que instancia `terraform-aws-modules/lambda/aws`, apontando pra VPC/subnets/ECR provisionados aqui via `data` source. Sem mudança em relação à versão anterior deste spec.
- **`video-processor-users-api`** (agora EKS): **não** instancia mais o módulo Lambda. Em vez disso, tem `k8s/base/` + `k8s/overlays/aws/` (**Deployment, Service, HPA — sem `Ingress`**, corrigido 2026-07-13, ver seção 6.1) aplicados via `kubectl apply -k` no próprio pipeline de deploy do serviço, contra o cluster provisionado aqui. Constrói e publica imagem no ECR deste repo. Ver `video-processor-users-api`, seção 8.2, para o detalhe completo.

---

## 8. Porta do repo antigo (`iac-tech-challenge-infra`)

| Antigo | Novo | Observação |
|---|---|---|
| `modules/vpc` | módulo de registry `terraform-aws-modules/vpc/aws` | reescrito, não copiado |
| `modules/eks` | módulo de registry `terraform-aws-modules/eks/aws` | **portado nesta atualização** (2026-07-13) — reescrito, mesma decisão de IAM (`LabRole`, sem IRSA, sem KMS key nova) que o módulo caseiro antigo já tomava |
| `modules/lambda` | módulo de registry `terraform-aws-modules/lambda/aws` | reescrito, não copiado |
| `modules/ecr` | módulo de registry `terraform-aws-modules/ecr/aws` | reescrito, não copiado |
| Helm (LB Controller) no pipeline | mantido, sem duplicar | ver seção 6 — antes duplicado em 2 repos, agora só aqui |
| `k8s/ingresses/ingress.yaml` (versão final, pós-correção, do `tech-challenge`) | `k8s/ingress.yaml` | portado desde o início nesta versão — evita repetir o ciclo "Ingress por serviço → bug de múltiplos ALBs → centralizar" que o `tech-challenge` teve que percorrer (ver seção 6.1) |
| `aws/` + `localstack/` | `prod/` + `dev/` | renomeado (ver spec guarda-chuva, seção 6) |
| `conductor/` | — | ferramenta de tracking específica do time antigo; não é necessário portar |

---

## 9. Pontos em aberto — todos resolvidos em 2026-07-14

1. ~~Versão exata do EKS e tamanho/tipo de instância do node group~~ — **Resolvido:** `1.30`, `t3.medium`, `desired=1/min=1/max=2` (replica o repo antigo; ver seção 5). YAGNI — só `users-api` roda nesta fase, sizing sobe depois via `scaling_config` sem recriar o node group.
2. ~~Nome exato do campo de IAM role no node group do módulo 21.24.0~~ — **Resolvido:** `create_iam_role` (idêntico ao nível do cluster; `create_node_iam_role` não existe nesta versão), confirmado por leitura direta do código-fonte do submódulo `eks-managed-node-group` (ver seção 5).
3. ~~Tamanho/CIDR da VPC e número de AZs~~ — **Resolvido:** `10.0.0.0/16`, 2 AZs (`us-east-1a`/`us-east-1b`), 1 NAT Gateway único — replica `iac-tech-challenge-infra/modules/vpc` (ver seção 4).

Decisões adicionais tomadas na mesma revisão (não eram pontos em aberto do spec original, surgiram da experiência de implementar `iac-video-processor-gateway`):

4. **State locking:** `use_lockfile = true` no backend S3 de `prod/` (Terraform `>= 1.11`), diferente do débito aceito no gateway — justificado pelo blast radius maior do EKS (ver seção 3.1).
5. **Contrato de tag da VPC em `dev/`:** `video-processor-vpc-local`, já assumido como fixo pelo `iac-video-processor-gateway/dev/data.tf` implementado (ver seção 4).
6. **IAM em `dev/`:** sem `LabRole` (não existe no LocalStack) — usa o default do módulo (`create_iam_role = true`) em vez de uma role manual (ver seção 3.2 e 5).
7. **Convenção de nomes por ambiente:** sufixo `-${var.environment}` nos nomes de recurso (ex.: `video-processor-eks-${var.environment}`), para consistência com o padrão adotado no gateway (ver seção 5).
