# Runbook — Primeiro Deploy

Sequência para colocar a plataforma no ar a partir de uma conta AWS limpa e do
repositório publicado. Cada passo termina com uma verificação; não avance sem ela.

**Pré-condições**

- AWS CLI autenticado na conta `603727984890`, região padrão `us-east-1`
- Terraform ≥ 1.6, Go ≥ 1.26 e `kubectl` instalados
- Repositório `lcsbm/solidarytech-fase5` público
- Nenhuma role de CI/CD de projetos anteriores na conta — o acesso de uma role
  mora na trust policy dela, não no provider OIDC, que é único por conta e fica

**Convenções**: comandos em bash (Git Bash no Windows), executados na raiz do
repositório salvo indicação. Nada de `terraform apply` ou `kubectl apply` fora do
que está escrito aqui — a esteira é o caminho.

---

## 0. Bootstrap — o único apply local

Cria o bucket de state e as três roles que a esteira assume. É o único Terraform
aplicado fora do GitHub Actions, porque é ele que cria a role de que a esteira
depende. Idempotente: se já foi aplicado, o `apply` responde `No changes`.

```bash
cd terraform/bootstrap
terraform init
terraform plan      # 10 recursos: bucket + 3 configs, 3 roles, 2 policies, 1 attachment. Zero OIDC provider.
terraform apply
cd ../..
```

**Verificação**

```bash
aws iam get-role --role-name SolidaryTech-CICD-terraform --query Role.MaxSessionDuration   # 7200
aws s3api get-bucket-versioning --bucket solidarytech-tfstate --query Status                # "Enabled"
```

---

## 1. Levar o código para a `main`

A `main` precisa conter o bootstrap com trust de dois formatos, o `go.sum` do
`donation-service`, os Jobs de schema e os workflows corrigidos. No momento desta
escrita, isso significa mergear dois PRs, **nesta ordem**:

```bash
git push -u origin fix/ci-sarif-upload-private-repo    # 1º — corrige o CI que os demais PRs usam
git push -u origin chore/first-deploy-prep             # 2º
```

**Verificação**: em cada PR, `validate`, `finops-policy`, `test` e `security-scan`
verdes. O job `plan` do segundo PR passa porque a role do passo 0 já existe.

---

## 2. Configurar o GitHub

**2a. Secret** — *Settings → Secrets and variables → Actions → New repository secret*

| Nome | Valor |
|---|---|
| `EKS_ADMIN_IAM_ARN` | saída de `aws sts get-caller-identity --query Arn --output text` |

**2b. Environments** — *Settings → Environments → New environment*

Crie `prod` e `dr`. Em cada um, *Required reviewers* → adicione a si mesmo.
É isso que faz `apply` e `destroy` **pararem para aprovação** em vez de rodarem
sozinhos — e é evidência para o relatório.

**Verificação**: *Settings → Environments* lista `prod` e `dr`, cada um com 1 reviewer.

---

## 3. Provisionar a infraestrutura — pela esteira

*Actions → "Terraform — Plan e Apply" → Run workflow* → `environment: prod`,
`action: apply`.

O job `apply` para na aprovação do environment; aprove. Leva 25–40 min
(EKS ~15, RDS ~10, add-ons ~5). **Enquanto roda, faça o passo 4.**

**Verificação**

```bash
aws eks describe-cluster --name solidarytech-production --query cluster.status            # "ACTIVE"
aws ecr describe-repositories --query "repositories[].repositoryName"                     # 3 repos solidarytech/*
aws secretsmanager list-secrets \
  --query "SecretList[?starts_with(Name,'solidarytech/production')].Name"                 # 2 database-url
```

**Depois do primeiro sucesso**: no CloudTrail, o evento `AssumeRoleWithWebIdentity`
da role `SolidaryTech-CICD-terraform` mostra qual formato de `sub` o GitHub emitiu
(com ou sem IDs numéricos). Remova o outro de `local.repo_subjects` em
`terraform/bootstrap/main.tf` e reaplique o bootstrap — a trust fica restrita ao
formato real.

---

## 4. Secrets Manager — os quatro que o Terraform não cria

Os dois `database-url` já existem, criados no passo 3 com senha gerada pelo
Terraform. Estes quatro guardam credenciais de terceiros: criados à mão, nunca
versionados.

| Nome | JSON | Onde obter |
|---|---|---|
| `solidarytech/grafana` | `{"admin": "<senha>"}` | você define |
| `solidarytech/pagerduty` | `{"integration_key": "<key>"}` | PagerDuty → Service → Integrations → Events API v2 |
| `solidarytech/discord` | `{"webhook_url": "<url>"}` | Discord → canal → Integrações → Webhooks |
| `solidarytech/new-relic` | `{"license_key": "<key>"}` | New Relic → API keys → tipo *License* (INGEST) |

```bash
aws secretsmanager create-secret --region us-east-1 --name solidarytech/grafana    --secret-string '{"admin":"<senha>"}'
aws secretsmanager create-secret --region us-east-1 --name solidarytech/pagerduty  --secret-string '{"integration_key":"<key>"}'
aws secretsmanager create-secret --region us-east-1 --name solidarytech/discord    --secret-string '{"webhook_url":"<url>"}'
aws secretsmanager create-secret --region us-east-1 --name solidarytech/new-relic  --secret-string '{"license_key":"<key>"}'
```

**Verificação**

```bash
aws secretsmanager list-secrets --query "SecretList[?starts_with(Name,'solidarytech/')].Name" --output table   # 6 ao todo
```

---

## 5. Primeiras imagens — pela esteira, antes do ArgoCD

*Actions → "CI — Build, Scan e Deploy" → Run workflow* → `service: all`.

Constrói, escaneia e publica as 3 imagens no ECR, e commita as tags reais nos
manifestos. Fazer isso **antes** do passo 6 evita que o ArgoCD tente puxar
`:latest`, que não existe (o ECR é `IMMUTABLE`): a primeira sincronização já
encontra imagens válidas.

**Verificação**

```bash
for s in ngo-service donation-service volunteer-service; do
  aws ecr describe-images --repository-name solidarytech/$s --query "imageDetails[].imageTags" --output text
done
git pull && git log --oneline -3    # 3 commits "deploy(<service>): <sha> [skip ci]"
```

---

## 6. GitOps — o único `kubectl apply`

```bash
aws eks update-kubeconfig --region us-east-1 --name solidarytech-production
kubectl apply -f gitops/bootstrap/app-of-apps.yaml
```

A partir daqui o ArgoCD entrega tudo, inclusive o schema dos bancos (Jobs
`*-schema`, hooks `PostSync`). Nenhum outro `kubectl apply` no projeto.

**Verificação** (dê ~3 min)

```bash
kubectl get applications -n argocd            # solidarytech-apps e -monitoring: Synced / Healthy
kubectl get externalsecrets -n solidarytech   # STATUS SecretSynced, READY True
kubectl get pods -n solidarytech              # 6 pods Running (2 por serviço); jobs de schema já removidos pelo hook
kubectl get pods -n monitoring                # prometheus, grafana, loki, otel-collector, self-healing-relay
```

Se uma ExternalSecret ficar em `SecretSyncedError`, o secret do passo 4 está
faltando ou com a chave JSON errada — o nome exato está na coluna JSON da tabela.
Se um Job de schema falhar, `kubectl logs job/<nome>-schema -n solidarytech`
mostra o erro do `psql`.

---

## 7. Validação funcional

```bash
HOST=$(kubectl get ingress solidarytech -n solidarytech -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -s "http://$HOST/ngos"                                                          # 2 ONGs do seed
curl -s -X POST "http://$HOST/donations" -H 'Content-Type: application/json' \
     -d '{"ngo_id":1,"amount":50.0,"donor_name":"Teste"}'                            # 201, status APPROVED
curl -s "http://$HOST/volunteers/1"                                                  # [] — vazio, sem erro

# O evento da doação chegou na fila
QUEUE=$(aws sqs get-queue-url --queue-name solidarytech-production-donations --query QueueUrl --output text)
aws sqs get-queue-attributes --queue-url "$QUEUE" --attribute-names ApproximateNumberOfMessages
```

**Painéis** — por port-forward; nada é exposto à internet

```bash
GRAFANA=$(kubectl get svc -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n monitoring "svc/$GRAFANA" 3000:80       # http://localhost:3000 → "SRE — SLOs e Error Budget"

kubectl port-forward -n argocd svc/argocd-server 8080:443        # https://localhost:8080, usuário admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

New Relic: *APM & Services* lista os 3 serviços após o primeiro tráfego; o
*Service map* mostra PostgreSQL e SQS ligados ao `donation-service`.

**Evidências para o relatório**: um screenshot de cada verificação acima.

---

## 8. Depois do primeiro deploy

- **Trust policy**: restringir ao formato de `sub` real — fim do passo 3.
- **State do bootstrap**: migrar para o bucket. Descomente o bloco `backend "s3"`
  em `terraform/bootstrap/main.tf` e rode `terraform init -migrate-state`. Sem
  isso, perder a máquina é perder o rastreamento das roles.
- **Branches locais** já mergeadas: `git branch -d fix/trivy-action-version feat/cluster-addons-and-destroy`.
- **Branch protection** em `main`, se quiser: o CI commita o bump de tag na `main`
  por design (`[skip ci]`); o `github-actions[bot]` precisa de bypass.

---

## Derrubar

*Actions → "Terraform — Destroy" → Run workflow* → `environment: prod`,
confirmação `destroy-prod`. Passa pela aprovação do environment. Bucket de state
e roles permanecem — pertencem ao bootstrap.

Para o DR: mesmo workflow, `environment: dr`, confirmação `destroy-dr`. O DR só
existe se foi aplicado (`Terraform — Plan e Apply` com `environment: dr`).
