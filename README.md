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
├── services/                   Código dos 3 microsserviços + Dockerfiles
├── terraform/
│   ├── bootstrap/              Bucket de state e role de push no ECR
│   │   └── seed/               A única role criada fora de um workflow — inputs versionados
│   ├── modules/
│   │   ├── platform/           Toda a plataforma de um ambiente: EKS, RDS, SQS, add-ons
│   │   └── registry/           Repositórios ECR de uma região
│   └── envs/
│       ├── registry/           ECR nas duas regiões + replicação — state e aprovação próprios
│       ├── prod/               us-east-1 — ambiente primário
│       └── dr/                 us-east-2 — warm standby (mesmo módulo)
├── gitops/
│   ├── apps/
│   │   ├── base/               Manifestos dos serviços, sem host de registro
│   │   └── overlays/{prod,dr}  ECR da região, fila, tabela, roles IRSA, secrets
│   ├── monitoring/             Prometheus, Grafana, Loki, OTel, relay de self-healing, SLOs
│   └── bootstrap/              App-of-Apps do ArgoCD (prod e dr)
├── .github/workflows/          bootstrap · CI com Trivy · Terraform plan/apply · destroy
└── docs/                       PCN · FinOps · ITSM · runbook do primeiro deploy
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
Environment = "Production" | "DR" | "Shared" | "Bootstrap"
CostCenter  = "NGO-Core"
ManagedBy   = "Terraform"
```

O pipeline [`terraform.yml`](.github/workflows/terraform.yml) falha se qualquer root
deixar de declarar as 4 tags.

**Otimizações aplicadas:**
- Node group Spot para `ngo-service` e `volunteer-service` (~65% de economia)
- NAT Gateway único em vez de um por AZ (~US$ 32/mês economizados)
- DynamoDB em `PAY_PER_REQUEST` — sem capacidade provisionada ociosa
- Lifecycle policy no ECR retendo apenas as 10 imagens mais recentes, nas duas regiões
- CI constrói apenas os serviços que mudaram

---

## Disaster Recovery

Estratégia **Ativo-Passivo (Warm Standby)** entre `us-east-1` e `us-east-2`, com
**RTO de 4 horas** e **RPO de 24 horas**. Detalhes em [`docs/PCN.md`](docs/PCN.md).

O ambiente espelho é descrito pelo **mesmo módulo** da produção e sobe pela esteira:
*Actions → "Terraform — Plan e Apply" → `environment: dr`*. Os manifestos do DR
(`gitops/apps/overlays/dr`) já apontam para o ECR de us-east-2 — no desastre, nenhuma
imagem é puxada da região caída.

---

## Como subir o ambiente

**Nada é provisionado fora de um workflow.** A única exceção é física: um workflow não
toca a AWS sem uma role que possa assumir, e criar essa role por workflow exigiria
outra antes dela, indefinidamente. A regressão termina em **uma** role — a semente —,
criada com dois comandos cujos inputs estão versionados em `terraform/bootstrap/seed/`.
Tudo o que ela cria a partir daí é Terraform aplicado por workflow, com aprovação.

A sequência completa, com verificação em cada passo, está em
[`docs/RUNBOOK-primeiro-deploy.md`](docs/RUNBOOK-primeiro-deploy.md). Em resumo:

| # | O quê | Onde | Aprovação |
|---|---|---|---|
| 0 | Semente — role `SolidaryTech-CICD-terraform` | 2 comandos `aws iam` | — |
| 1 | Bootstrap — bucket de state, role de push | *Terraform — Bootstrap* | environment `bootstrap` |
| 2 | Registry — ECR nas duas regiões | *Terraform — Plan e Apply* → `registry` | environment `registry` |
| 3 | Produção — EKS, RDS, DynamoDB, SQS, add-ons | *Terraform — Plan e Apply* → `prod` | environment `prod` |
| 4 | Primeiras imagens | *CI — Build, Scan e Deploy* → `all` | — |
| 5 | GitOps — `kubectl apply -f gitops/bootstrap/app-of-apps.yaml` | o único `kubectl apply` | — |

O bootstrap resolve sozinho o ovo-e-galinha do state: na primeira execução aplica com
state local, cria o bucket e migra o próprio state para dentro dele. Nenhum `apply`
dispara sozinho — todos passam pelo *environment* protegido do GitHub. Em pull request,
o workflow só roda `plan` e publica o resultado como comentário.

A partir do passo 5 o ArgoCD assume a entrega: um push em `services/**` dispara o
`ci.yml`, que testa, escaneia com Trivy, publica a imagem e grava a tag nos dois
overlays. O ArgoCD detecta o commit e sincroniza — deploys acontecem por commit no
repositório, nunca por comando manual.

### Add-ons do cluster

ArgoCD, ingress-nginx, External Secrets e metrics-server são instalados pelo Terraform
(`terraform/modules/platform/helm-addons.tf`), não por GitOps — o ArgoCD não tem como
instalar a si mesmo. Tudo que vem depois deles é entregue pelo ArgoCD.

---

## Como derrubar o ambiente

Manter EKS e RDS ligados fora das janelas de demonstração custa ~US$ 250/mês por
ambiente. O workflow de destroy existe por razão de FinOps.

*Actions → "Terraform — Destroy" → Run workflow* → escolha o ambiente e digite
`destroy-prod` ou `destroy-dr` como confirmação.

Duas barreiras impedem um destroy acidental: a confirmação precisa casar com o
ambiente escolhido no menu (não existe um "DESTROY" genérico), e o job passa pelo
*environment* protegido do GitHub, que exige aprovação manual.

O que **não** cai com o destroy, de propósito: o bucket de state e a role de push
(bootstrap), o registro de imagens nas duas regiões (apagar imagens é ação manual e
deliberada — por isso `registry` nem aparece no menu) e a semente.

---

## Segurança

- **Uma única role** criada fora de um workflow — a semente —, com trust restrita a
  este repositório e inputs versionados; tudo o mais é Terraform aplicado por esteira
- Autenticação AWS por **OIDC** no CI/CD — nenhuma access key estática no repositório
- Acesso a SQS e DynamoDB por **IRSA**, sem credenciais no cluster
- Self-healing pela **API do Kubernetes** com o token do próprio ServiceAccount — sem
  PAT, sem credencial externa, sem depender do GitHub durante um incidente
- Connection strings no **AWS Secrets Manager**, sincronizadas pelo External Secrets Operator
- Containers rodam como não-root, com `readOnlyRootFilesystem` e todas as capabilities removidas
- Namespace sob Pod Security Standard `restricted`
- Trivy bloqueia o merge em vulnerabilidade CRITICAL (código, dependências, imagem e IaC)
