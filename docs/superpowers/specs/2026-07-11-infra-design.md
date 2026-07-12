# Spec — iac-video-processor-infra

**Data:** 2026-07-11
**Status:** Draft — pronto para virar plano de implementação
**Repo antigo de referência:** `iac-tech-challenge-infra`
**Spec guarda-chuva:** `docs/superpowers/specs/2026-07-11-video-processor-auth-infra-migration-design.md` (workspace raiz)

---

## 1. Responsabilidade

Provisionar a infraestrutura de rede e compute compartilhada pelos 3 serviços de autenticação (`video-processor-authentication-api`, `video-processor-authorizer`, `video-processor-users-api`):

- **VPC** com subnets privadas — necessária para o `users-service` alcançar o RDS provisionado em `iac-video-processor-data`.
- **Módulo Lambda genérico** — empacotamento/deploy reutilizado pelos 3 repos de serviço (cada um instancia esse módulo no seu próprio `terraform/` local, ver seção 5).
- **ECR** — um repositório por serviço, reservado para deploy de Lambda via imagem de container, caso o time prefira essa via em vez do zip padrão (decisão a confirmar no plano — ver seção 7).

**Fora de escopo nesta fase:** módulo EKS (existia no repo antigo para o backend; a arquitetura nova não usa EKS para o backend — só o frontend Next.js, que é ADR-009, fora de escopo).

---

## 2. Módulos Terraform (Registry, confirmados via MCP em 2026-07-11)

| Módulo | Versão | Uso |
|---|---|---|
| `terraform-aws-modules/vpc/aws` | 6.6.1 | VPC + subnets públicas/privadas + route tables |
| `terraform-aws-modules/lambda/aws` | 8.8.0 | Empacotamento/deploy de função Lambda (consumido pelos repos de serviço) |
| `terraform-aws-modules/ecr/aws` | 3.2.0 | Repositórios ECR por serviço (uso condicional, ver seção 7) |
| provider `hashicorp/aws` | 6.54.0 | — |

Reconsultar `get_latest_module_version` no MCP do Terraform antes do `terraform init` real — estes números são um snapshot da data deste spec.

---

## 3. Estrutura de pastas

```
iac-video-processor-infra/
├── dev/     # equivalente ao antigo localstack/ — state local, aplicado via tflocal
├── prod/    # equivalente ao antigo aws/ — state remoto (S3), aplicado via terraform real
└── modules/ # (se necessário customizar algo em cima do módulo de registry — avaliar no plano se é preciso)
```

Backend do state em `prod/`: bucket S3 dedicado, key `video-processor-infra/terraform.tfstate` (mesmo padrão de `iac-tech-challenge-infra/aws/main.tf`, só troca o prefixo do nome).

---

## 4. Recursos-chave

- **VPC:** tag `Name = video-processor-vpc` — **este nome de tag é o contrato**: `iac-video-processor-data` e `iac-video-processor-gateway` vão procurá-la via `data "aws_vpc"` filtrando por essa tag, exatamente como `iac-tech-challenge-data/aws/data.tf` faz hoje com `eks-tech-challenge-vpc`.
- **Subnets privadas:** tag `Name` contendo `*-private-*` (mesmo padrão de filtro usado pelos repos consumidores antigos — manter para não quebrar o `data` source).
- **Conectividade de saída (NAT Gateway vs. VPC Endpoints):** os Lambdas de autenticação precisam alcançar DynamoDB e Secrets Manager. Duas opções:
  - NAT Gateway (padrão do repo antigo, mais caro, resolve qualquer saída para internet).
  - VPC Endpoints (`com.amazonaws.<region>.dynamodb`, `com.amazonaws.<region>.secretsmanager`) — mais barato, sem dependência de internet, suficiente para o escopo desta fase.
  - **Recomendação:** VPC Endpoints, já que os 3 Lambdas desta fase só precisam de DynamoDB + Secrets Manager (RDS já é acesso interno à VPC, não precisa de endpoint). Decidir/confirmar no plano de implementação.
- **ECR:** um repositório por serviço (`video-processor-authentication-api`, `video-processor-authorizer`, `video-processor-users-api`), lifecycle policy para não acumular imagens antigas indefinidamente (mesmo padrão do `modules/ecr` antigo).

---

## 5. Relação com o Terraform dos repos de serviço

Este repo **não** cria as funções Lambda em si — cada repo de serviço (`video-processor-authentication-api`, `-authorizer`, `-users-api`) tem seu próprio `terraform/` local que instancia o módulo `terraform-aws-modules/lambda/aws` apontando para a VPC/subnets/ECR provisionados aqui (via `data` source, mesmo padrão de acoplamento por tag/nome). Ver seção 5 da spec guarda-chuva.

---

## 6. Porta do repo antigo (`iac-tech-challenge-infra`)

| Antigo | Novo | Observação |
|---|---|---|
| `modules/vpc` | módulo de registry `terraform-aws-modules/vpc/aws` | reescrito, não copiado |
| `modules/lambda` | módulo de registry `terraform-aws-modules/lambda/aws` | reescrito, não copiado |
| `modules/ecr` | módulo de registry `terraform-aws-modules/ecr/aws` | reescrito, não copiado |
| `modules/eks` | — | **não portado** (fora de escopo) |
| `aws/` + `localstack/` | `prod/` + `dev/` | renomeado (ver spec guarda-chuva, seção 6) |
| `conductor/` | — | ferramenta de tracking específica do time antigo; não é necessário portar, cada squad usa suas próprias tasks/specs agora |

---

## 7. Pontos em aberto (resolver no plano de implementação)

1. NAT Gateway vs. VPC Endpoints para saída de rede (recomendação: VPC Endpoints — ver seção 4).
2. ECR é realmente necessário nesta fase, ou os 3 Lambdas vão todos de zip (sem container image)? Se for zip, o módulo ECR pode ficar só provisionado mas sem uso imediato, ou ser adiado.
3. Tamanho/CIDR da VPC e número de AZs (o repo antigo não documentava isso explicitamente no README — verificar `modules/vpc/variables.tf` antigo como ponto de partida).
