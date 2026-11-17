# SolidaryTech — Hackathon Fase 5

Plataforma de microsserviços que conecta ONGs a doadores e voluntários, operada com
práticas de SRE, FinOps, ITSM/AIOps e Disaster Recovery.

**FIAP — Pós-Graduação em DevOps e Arquitetura Cloud**
Lucas Santana Bezerra de Melo — RM 373161 — [@lcsbm](https://github.com/lcsbm)

---

## Serviços

| Serviço | Stack | Porta | Persistência | Papel |
|---|---|---|---|---|
| `ngo-service` | Python 3.12 · Flask | 8081 | PostgreSQL (`ngo_db`) | Cadastro de ONGs parceiras |
| `donation-service` | Go 1.26 · net/http | 8082 | PostgreSQL (`donation_db`) + SQS | **Hot Path** — processamento de doações |
| `volunteer-service` | Python 3.12 · Flask | 8083 | DynamoDB | Match entre voluntários e campanhas |

O `donation-service` é o caminho crítico: é sobre ele que os SLOs são definidos e é o
único que nunca roda em capacidade Spot.

---

## Arquitetura

```
                      ┌──────────────┐
  Internet ──────────►│ NGINX Ingress│
                      └──────┬───────┘
          ┌──────────────────┼──────────────────┐
          ▼                  ▼                  ▼
   ngo-service       donation-service    volunteer-service
     (Spot)            (On-Demand)            (Spot)
          │                  │                  │
          ▼                  ▼                  ▼
     RDS ngo_db      RDS donation_db       DynamoDB
                            │
                            ▼
                      SQS + DLQ

  Todos os serviços ──OTLP :4317──► OTel Collector ──► Prometheus / Loki / New Relic
```

---

## Estrutura do repositório

```
├── services/              Código dos 3 microsserviços + Dockerfiles
├── terraform/
│   ├── modules/platform/  Módulo único que descreve toda a plataforma
│   └── envs/
│       ├── prod/          us-east-1 — ambiente primário
│       └── dr/            us-east-2 — warm standby (mesmo módulo)
├── gitops/
│   ├── apps/              Manifestos dos serviços (ArgoCD sincroniza)
│   ├── monitoring/        Regras de SLO e Error Budget
│   └── bootstrap/         App-of-Apps do ArgoCD
├── .github/workflows/     CI/CD com Trivy (SAST/SCA) e Terraform
└── docs/PCN.md            Plano de Continuidade de Negócios
```

---

## SLOs — donation-service

| SLI | Definição | SLO (30 dias) |
|---|---|---|
| Disponibilidade | Requisições que não retornam 5xx | 99,9% |
| Latência | Requisições atendidas em até 500ms | 99,9% |

Error budget de 0,1% equivale a **~43 minutos** de degradação por mês.
As regras vivem em [`gitops/monitoring/slo-rules.yaml`](gitops/monitoring/slo-rules.yaml)
e usam alertas multi-window de burn rate (Google SRE Workbook): a queima acelerada
(14,4x) pagina o on-call; a sustentada (6x) abre ticket.

---

## FinOps

**Tags obrigatórias** aplicadas via `default_tags` do provider AWS — toda a infraestrutura,
inclusive recursos criados por submódulos de terceiros:

```hcl
Project     = "SolidaryTech"
Environment = "Production" | "DR"
CostCenter  = "NGO-Core"
ManagedBy   = "Terraform"
```

O pipeline [`terraform.yml`](.github/workflows/terraform.yml) falha se qualquer ambiente
deixar de declarar as 4 tags.

**Otimizações aplicadas:**
- Node group Spot para `ngo-service` e `volunteer-service` (~65% de economia)
- NAT Gateway único em vez de um por AZ (~US$ 32/mês economizados)
- DynamoDB em `PAY_PER_REQUEST` — sem capacidade provisionada ociosa
- Lifecycle policy no ECR retendo apenas as 10 imagens mais recentes
- CI constrói apenas os serviços que mudaram

---

## Disaster Recovery

Estratégia **Ativo-Passivo (Warm Standby)** entre `us-east-1` e `us-east-2`, com
**RTO de 4 horas** e **RPO de 24 horas**. Detalhes em [`docs/PCN.md`](docs/PCN.md).

O ambiente espelho sobe com um comando, usando o mesmo módulo da produção:

```bash
cd terraform/envs/dr
terraform init && terraform apply
```

---

## Como subir o ambiente

A infraestrutura é provisionada **pela esteira**, não por `terraform apply` local.
O único passo manual é o bootstrap, e ele existe por uma razão específica: a esteira
se autentica na AWS assumindo uma role OIDC, e essa role não pode ser criada pela
própria esteira que depende dela.

### Passo 0 — Bootstrap (uma única vez, local)

Cria o bucket de state e as três roles de CI/CD. É o único `terraform apply` que
roda fora da esteira, e o único state que fica local.

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

Depois, cadastre o secret `EKS_ADMIN_IAM_ARN` em
*Settings > Secrets and variables > Actions*.

### Passo 1 — Infraestrutura, pela esteira

*Actions > "Terraform — Plan e Apply" > Run workflow* → `environment: prod`,
`action: apply`.

O `apply` nunca dispara sozinho: exige acionamento manual e passa pelo
*environment* protegido do GitHub. Em pull request, o workflow só roda `plan` e
publica o resultado como comentário.

### Passo 2 — GitOps

```bash
aws eks update-kubeconfig --region us-east-1 --name solidarytech-production
kubectl apply -f gitops/bootstrap/app-of-apps.yaml
```

Este é o único `kubectl apply` do projeto. A partir dele o ArgoCD assume a entrega
dos três serviços e de toda a stack de observabilidade — deploys passam a acontecer
por commit no repositório, nunca por comando manual.

### Passo 3 — Aplicações

Um push em `services/**` dispara o `ci.yml`, que testa, escaneia com Trivy, publica
a imagem no ECR e atualiza a tag no manifesto GitOps. O ArgoCD detecta o commit e
sincroniza.

---

## Segurança

- Autenticação AWS por **OIDC** no CI/CD — nenhuma access key estática no repositório
- Acesso a SQS e DynamoDB por **IRSA**, sem credenciais no cluster
- Connection strings no **AWS Secrets Manager**, sincronizadas pelo External Secrets Operator
- Containers rodam como não-root, com `readOnlyRootFilesystem` e todas as capabilities removidas
- Namespace sob Pod Security Standard `restricted`
- Trivy bloqueia o merge em vulnerabilidade CRITICAL (código, dependências, imagem e IaC)
