# Runbook de pipelines — sequência de disparo entre repos (via GitHub Actions)

**Status:** rascunho, descreve o alvo depois que as pipelines da spec `2026-07-25-cicd-pipelines-design.md` (repo `video-processor-specs`) forem implementadas. **Ainda não implementado** — nenhum dos 8 repos abaixo tem o workflow `ci-cd.yml` descrito ali hoje. Até a implementação acontecer, o processo válido continua sendo o `RUNBOOK.md` (deploy manual via AWS CLI/Terraform local).
**Não editar `RUNBOOK.md`** neste momento — outra sessão está atualizando aquele arquivo em paralelo. Fazer o merge das duas versões fica para depois.
**Objetivo deste documento:** responder “em qual repo eu disparo o quê, em que ordem” — não repete comandos AWS CLI que já estão no `RUNBOOK.md`.

---

## Quando esta ordem importa

Com CD automático por repo (push em `main` → apply/deploy), a ordem entre repos **não importa em regime permanente** — cada repo só reflete o que mudou nele, contra uma conta AWS que já tem todo o resto provisionado.

A ordem abaixo só é necessária em **bootstrap de conta vazia** — o cenário recorrente neste projeto: a conta AWS Academy Learner Lab reseta entre sessões (infra derrubada, conta não é destruída de vez — ver memória de projeto `project_aws_academy_lab_resets`). Nesse caso, todos os 8 repos já têm código em `main`, mas nenhum recurso existe na AWS — e os `data` sources cross-repo (ex.: o gateway lendo a Lambda de `authentication`) falham se disparados fora de ordem.

---

## Pré-requisitos antes de disparar qualquer pipeline

1. **Secrets de organização atualizados** com credenciais de sessão válidas da conta atual (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`/`AWS_REGION`/`AWS_ACCOUNT_ID`) — expiram em horas, precisam ser atualizados a cada sessão do Lab antes de rodar qualquer workflow que toque AWS.
2. **`AWS_S3_TF_STATE_BUCKET_NAME`** apontando para um bucket que existe (ver `RUNBOOK.md`, passo 1 — bucket sufixado com o account ID atual; nomes de bucket S3 são globais, o bucket da sessão anterior fica preso na conta anterior).
3. Visibilidade dos secrets de org corrigida para "Selected repositories" incluindo os 8 repos abaixo (spec de design, seção 6.3) — sem isso, os repos privados (`iac-*`, `authorizer`, `authentication-api`) não enxergam os secrets e o job falha em `configure-aws-credentials`.

---

## Ordem de bootstrap (conta vazia)

Cada linha = um repo + o mecanismo de disparo. Como o código já está em `main`, o disparo é via **`workflow_dispatch`** (re-executa o workflow existente sem precisar de commit novo) — pela CLI (`gh workflow run ci-cd.yml --repo 13SOAT-andromeda/<repo> --ref main`) ou pela aba Actions do GitHub.

| # | Repo | O que a pipeline provisiona | Observação |
|---|---|---|---|
| 1 | `iac-video-processor-infra` | VPC, EKS, ECR, secrets (inclui `jwt-signing-key-prod`, `datadog-postgres-dbm-password-prod`), SNS/SQS, buckets de vídeo/artifacts | ~10-12min (EKS). Precisa de `DD_API_KEY` disponível pro job (var/secret de org). |
| — | *(fora de qualquer repo)* | AWS Load Balancer Controller (Helm) + `k8s/ingress.yaml` | Não é Terraform nem faz parte de nenhum CD desta spec — continua manual, igual ao `RUNBOOK.md` passo 4, rodado contra o `kubeconfig` do cluster criado no passo 1. Candidato a automatizar numa spec futura. |
| 2 | `iac-video-processor-data` | RDS Postgres, DynamoDB | ~7min (RDS). Independente do passo 1 além do backend de state compartilhado. |
| 3 | `video-processor-users-api` | Deploy no EKS (`kubectl apply -k`) | Depende do cluster (passo 1) e do Ingress (passo acima) já existirem. |
| 4 | `video-processor-converter` | Lambda `processing-worker` + `dlq-handler` | Depende das filas/buckets do passo 1. |
| 5 | `video-processor-link-api` | Deploy no EKS (`kubectl apply -k`) | Depende do cluster + filas/tópicos do passo 1. |
| 6 | `video-processor-authorizer` | Lambda authorizer | Sem dependência cíclica — pode rodar a qualquer momento depois do passo 1 (secret `jwt-signing-key-prod`). |
| 7 | `iac-video-processor-gateway` — **fase 1** | API Gateway, **sem** rotas `/auth/*` | Ver "Gate manual: ciclo gateway ↔ authentication-api" abaixo — precisa de uma variação temporária do código, igual ao `RUNBOOK.md` passo 9. |
| 8 | `video-processor-authentication-api` | Lambda de autenticação | `VERIFICATION_BASE_URL` resolve contra o endpoint do gateway criado na fase 1. |
| 9 | `iac-video-processor-gateway` — **fase 2** | API Gateway completo, com rotas `/auth/*` | Reverter a variação temporária da fase 1 e disparar de novo. |

**Passos 3, 4, 5 e 6 são independentes entre si** — podem ser disparados em paralelo, desde que o passo 1 (e o passo 2, para o que depende de RDS/DynamoDB) já tenha terminado.

---

## Gate manual: ciclo gateway ↔ `authentication-api`

Igual ao `RUNBOOK.md` (passos 9-11), esse ciclo não é resolvido pela pipeline em si — é um passo manual de bootstrap:

1. Antes do passo 7 da tabela acima, comentar temporariamente em `iac-video-processor-gateway` (`prod/main.tf`, `prod/data.tf`): o `data "aws_lambda_function" "authentication"`, as 3 rotas `/auth/*` e o `aws_lambda_permission.authentication`. **Não commitar essa versão comentada** — só um estado de trabalho local, ou uma branch descartável usada só para o `workflow_dispatch` da fase 1.
2. Disparar o passo 7 (gateway, fase 1) e o passo 8 (`authentication-api`).
3. Reverter o comentário (`git checkout -- prod/main.tf prod/data.tf` se nada foi commitado) e disparar o passo 9 (gateway, fase 2).

Esse gate só existe no bootstrap. Depois que os dois repos estão aplicados uma vez, merges subsequentes em qualquer um dos dois não recriam o ciclo — o `data` source já resolve contra o recurso existente.

---

## Regime permanente (depois do bootstrap)

Nenhuma ação cross-repo necessária. Cada repo dispara sua própria pipeline no seu próprio `push`/merge para `main`, de forma independente, na ordem em que os PRs forem mergeados — não na ordem da tabela acima.

---

## Teste end-to-end e destroy

Sem mudança em relação ao `RUNBOOK.md` (seções 12 e 13) — este documento cobre só a ordem de disparo das pipelines, não os passos de teste manual (`curl` no endpoint do gateway) nem a sequência de destroy, que continuam válidos como estão.
