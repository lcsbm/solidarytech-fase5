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
repositório salvo indicação. **Nada é provisionado fora de um workflow** — com uma
única exceção, física, explicada no passo 0.

---

## 0. A semente — a única coisa criada fora de um workflow

Nenhum workflow toca a AWS sem uma role que ele possa assumir. Criar essa role por
workflow exigiria outra role antes dela, indefinidamente. A regressão termina em
**uma** role, criada com dois comandos cujos inputs estão versionados em
`terraform/bootstrap/seed/`:

```bash
aws iam create-role \
  --role-name SolidaryTech-CICD-terraform \
  --assume-role-policy-document file://terraform/bootstrap/seed/trust-policy.json \
  --max-session-duration 7200 \
  --tags Key=Project,Value=SolidaryTech Key=Environment,Value=Bootstrap Key=CostCenter,Value=NGO-Core Key=ManagedBy,Value=Seed

aws iam attach-role-policy \
  --role-name SolidaryTech-CICD-terraform \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

A trust confia apenas em `lcsbm/solidarytech-fase5`, nos dois formatos de `sub` que o
GitHub pode emitir. Tudo o que esta role cria daqui em diante é Terraform aplicado por
workflow. Ela não entra em state algum: existe antes dele.

**Verificação**

```bash
aws iam get-role --role-name SolidaryTech-CICD-terraform --query '[Role.MaxSessionDuration, Role.AssumeRolePolicyDocument.Statement[0].Condition.StringLike]'
```

---

## 1. Levar o código para a `main`

Os workflows só existem para o GitHub quando estão na `main`. No momento desta
escrita, isso significa mergear dois PRs, **nesta ordem**:

```bash
git push -u origin fix/ci-sarif-upload-private-repo    # 1º — corrige o CI que os demais PRs usam
git push -u origin chore/first-deploy-prep             # 2º — bootstrap, registry, overlays, go.sum, schema, runbook
```

**Verificação**: em cada PR, `validate`, `finops-policy`, `test` e `security-scan`
verdes. O job `plan` do segundo PR falha — esperado: o bucket de state ainda não
existe. Ele passa a partir do passo 3a.

---

## 2. Configurar o GitHub

**2a. Secret** — *Settings → Secrets and variables → Actions → New repository secret*

| Nome | Valor |
|---|---|
| `EKS_ADMIN_IAM_ARN` | saída de `aws sts get-caller-identity --query Arn --output text` |

**2b. Environments** — *Settings → Environments → New environment*

Crie **quatro**: `bootstrap`, `registry`, `prod` e `dr`. Em cada um, *Required
reviewers* → adicione a si mesmo. É isso que faz cada `apply` e `destroy` **parar
para aprovação** em vez de rodar sozinho — e é evidência para o relatório.

**Verificação**: *Settings → Environments* lista os quatro, cada um com 1 reviewer.

---

## 3. Provisionar — três workflows, nesta ordem

### 3a. Bootstrap — bucket de state e role de push no ECR

*Actions → "Terraform — Bootstrap" → Run workflow*. Aprove no environment.

Na primeira execução o job aplica com state local, cria o bucket e migra o próprio
state para dentro dele. Nas seguintes, usa o S3 direto. Leva ~1 min.

**Verificação**

```bash
aws s3api get-bucket-versioning --bucket solidarytech-tfstate --query Status     # "Enabled"
aws s3 ls s3://solidarytech-tfstate/bootstrap/                                   # terraform.tfstate
aws iam get-role --role-name SolidaryTech-CICD-ecr-push --query Role.Arn
```

### 3b. Registry — ECR nas duas regiões

*Actions → "Terraform — Plan e Apply" → Run workflow* → `environment: registry`,
`action: apply`. Aprove. Leva ~1 min.

Cria os 3 repositórios em us-east-1 **e** em us-east-2 com as mesmas garantias, e a
replicação do primário para o DR. Tem state e aprovação próprios porque sobrevive a
subir e derrubar qualquer cluster.

**Verificação**

```bash
aws ecr describe-repositories --region us-east-1 --query "repositories[].repositoryName"   # 3 solidarytech/*
aws ecr describe-repositories --region us-east-2 --query "repositories[].repositoryName"   # os mesmos 3
aws ecr describe-registry --query "replicationConfiguration.rules[0].destinations[0].region"  # "us-east-2"
```

### 3c. Produção — EKS, RDS, DynamoDB, SQS e add-ons

*Actions → "Terraform — Plan e Apply" → Run workflow* → `environment: prod`,
`action: apply`. Aprove. Leva 25–40 min (EKS ~15, RDS ~10, add-ons ~5).
**Enquanto roda, faça o passo 4.**

**Verificação**

```bash
aws eks describe-cluster --name solidarytech-production --query cluster.status            # "ACTIVE"
aws secretsmanager list-secrets \
  --query "SecretList[?starts_with(Name,'solidarytech/production')].Name"                 # 2 database-url
```

**Depois do primeiro sucesso**: no CloudTrail, o evento `AssumeRoleWithWebIdentity`
da role `SolidaryTech-CICD-terraform` mostra qual formato de `sub` o GitHub emitiu
(com ou sem IDs numéricos). Remova o outro de `terraform/bootstrap/seed/trust-policy.json`
e de `local.repo_subjects` em `terraform/bootstrap/main.tf`, atualize a semente com
`aws iam update-assume-role-policy` e reaplique o bootstrap — as trusts ficam restritas
ao formato real.

---

## 4. Secrets Manager — os quatro que o Terraform não cria

Os dois `database-url` já existem, criados no passo 3c com senha gerada pelo
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

Constrói, escaneia e publica as 3 imagens no ECR primário (a replicação as copia
para o DR), e grava as tags reais nos dois overlays Kustomize. Fazer isso **antes**
do passo 6 evita que o ArgoCD tente puxar `:latest`, que não existe (o ECR é
`IMMUTABLE`): a primeira sincronização já encontra imagens válidas.

**Verificação**

```bash
for s in ngo-service donation-service volunteer-service; do
  aws ecr describe-images --repository-name solidarytech/$s --query "imageDetails[].imageTags" --output text
done
git pull && git log --oneline -3    # 3 commits "deploy(<service>): <sha> [skip ci]"
grep newTag gitops/apps/overlays/prod/kustomization.yaml    # 3 tags = os SHAs acima
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

- **Trust policy**: restringir ao formato de `sub` real — fim do passo 3c.
- **Branches locais** já mergeadas: `git branch -d fix/trivy-action-version feat/cluster-addons-and-destroy`.
- **Branch protection** em `main`, se quiser: o CI commita o bump de tag na `main`
  por design (`[skip ci]`); o `github-actions[bot]` precisa de bypass.
- **DR**: para manter o warm standby de fato aquecido, aplique `environment: dr` pela
  esteira e replique as quatro secrets manuais para us-east-2 — ver `docs/PCN.md`.

---

## Derrubar

*Actions → "Terraform — Destroy" → Run workflow* → `environment: prod`,
confirmação `destroy-prod`. Passa pela aprovação do environment.

Para o DR: mesmo workflow, `environment: dr`, confirmação `destroy-dr`.

O que **não** cai com o destroy, de propósito: o bucket de state e a role de push
(bootstrap), o registro de imagens nas duas regiões (registry — apagar imagens é
ação manual e deliberada) e a semente.
