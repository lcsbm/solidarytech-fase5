# FinOps — Tagueamento, Rightsizing e Forecast

Documento de custos da plataforma SolidaryTech. O orçamento da ONG é limitado, então
cada recurso precisa estar rastreado a um centro de custo e justificado.

---

## 1. Estratégia de tagueamento

### Tags obrigatórias

Toda a infraestrutura carrega quatro tags, aplicadas via `default_tags` no provider AWS
— o que garante cobertura inclusive sobre recursos criados por submódulos de terceiros,
onde é fácil esquecer de propagar tags manualmente:

| Tag | Valor | Para que serve |
|---|---|---|
| `Project` | `SolidaryTech` | Separa esta plataforma de outras cargas na conta |
| `Environment` | `Production` \| `DR` \| `Shared` \| `Bootstrap` | Separa produção, DR, o registro de imagens (compartilhado pelos dois) e o bootstrap |
| `CostCenter` | `NGO-Core` | Agrupa o gasto no centro de custo da operação |
| `ManagedBy` | `Terraform` | Identifica recursos órfãos criados fora da IaC |

Declaração em `terraform/envs/prod/main.tf`:

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = "Production"
      CostCenter  = "NGO-Core"
      ManagedBy   = "Terraform"
    }
  }
}
```

### Governança: a política é verificada no CI

Tag obrigatória que depende de disciplina humana vira tag faltante. O job
`finops-policy` em `.github/workflows/terraform.yml` falha o pipeline se qualquer
ambiente deixar de declarar as quatro tags:

```yaml
for tag in Project Environment CostCenter ManagedBy; do
  if ! grep -q "$tag" "$env_dir/main.tf"; then
    echo "::error::Ambiente '$env_name' nao declara a tag FinOps obrigatoria: $tag"
    FALHOU=1
  fi
done
```

Além disso, `copy_tags_to_snapshot = true` no RDS faz os snapshots herdarem as tags —
sem isso, backups aparecem como custo não atribuído no Cost Explorer.

---

## 2. Rightsizing

Os `requests` e `limits` foram definidos por perfil de carga, não por cópia de um
template. O `request` reserva capacidade no nó; superdimensioná-lo desperdiça o nó
inteiro, mesmo que o pod nunca use o reservado.

| Serviço | Request CPU | Limit CPU | Request Mem | Limit Mem | Justificativa |
|---|---|---|---|---|---|
| `donation-service` | 100m | 500m | 64Mi | 128Mi | Go, binário estático; Hot Path exige teto maior para picos |
| `ngo-service` | 50m | 300m | 128Mi | 256Mi | Python/Flask; runtime consome mais memória que Go |
| `volunteer-service` | 50m | 300m | 128Mi | 256Mi | Python/Flask; sem pool de conexões relacional |

O `donation-service` pede mais CPU e menos memória que os demais: é o inverso do perfil
Python. Um binário Go não carrega interpretador, mas é o serviço que absorve os picos
de doação.

**Escalonamento:** o `donation-service` tem HPA (2 a 10 réplicas, gatilho em 70% de CPU)
com janela de subida de 30s e descida de 300s. Subir rápido protege a doação; descer
devagar evita thrashing.

---

## 3. Forecast mensal

Base de cálculo: 730 horas/mês, região us-east-1 (DR em us-east-2), preços On-Demand
de novembro de 2026. **Estimativas — confirmar no AWS Pricing Calculator antes de
comprometer orçamento.**

### Ambiente de produção

| Recurso | Dimensionamento | Custo/mês (US$) |
|---|---|---|
| EKS control plane | 1 cluster, suporte padrão | 73,00 |
| EC2 On-Demand | 2 × t3.medium (cargas críticas) | 60,74 |
| EC2 Spot | 2 × t3.medium (cargas burstable) | 18,25 |
| EBS gp3 | 4 × 20 GB (nós) | 6,40 |
| RDS PostgreSQL | 2 × db.t3.micro | 26,28 |
| RDS storage | 2 × 20 GB gp3 | 4,60 |
| RDS backup | ~20 GB, retenção 7 dias | 1,90 |
| NAT Gateway | 1 (compartilhado entre AZs) | 32,85 |
| NAT — processamento | ~50 GB | 2,25 |
| Network Load Balancer | 1 (ingress-nginx) | 16,43 |
| DynamoDB | PAY_PER_REQUEST, volume baixo | 2,00 |
| SQS | < 1 milhão de requisições | 0,00 |
| ECR | ~3 GB de imagens | 0,30 |
| Secrets Manager | 2 segredos | 0,80 |
| CloudWatch Logs | volume mínimo | 2,00 |
| **Subtotal produção** | | **247,80** |

### Ambiente de DR (warm standby)

| Recurso | Dimensionamento | Custo/mês (US$) |
|---|---|---|
| EKS control plane | 1 cluster | 73,00 |
| EC2 On-Demand | 1 × t3.medium | 30,37 |
| EBS gp3 | 1 × 20 GB | 1,60 |
| RDS PostgreSQL | 2 × db.t3.micro | 26,28 |
| RDS storage | 2 × 20 GB | 4,60 |
| NAT Gateway | 1 | 32,85 |
| DynamoDB | réplica | 1,00 |
| ECR | imagens replicadas | 0,30 |
| **Subtotal DR** | | **170,00** |

### Total

| | US$/mês | US$/ano |
|---|---|---|
| Produção | 247,80 | 2.973,60 |
| DR (warm standby) | 170,00 | 2.040,00 |
| **Total** | **417,80** | **5.013,60** |

> A resiliência custa **41% do orçamento total**. Não é desperdício — é o preço do RTO
> de 4 horas. A seção 5 apresenta a alternativa, caso a diretoria aceite um RTO maior.

---

## 4. Otimizações já aplicadas

| Decisão | Economia/mês | Trade-off aceito |
|---|---|---|
| **EKS em versão com suporte padrão** | **365,00** | Exige upgrade do cluster ~1x/ano |
| Node group Spot para cargas não-críticas | 42,50 | Interrupção possível; nunca no Hot Path |
| NAT Gateway único em vez de um por AZ | 32,85 | Ponto único de falha na saída da VPC |
| DynamoDB PAY_PER_REQUEST | ~15,00 | Custo unitário maior sob carga alta constante |
| Lifecycle no ECR (retém 10 imagens) | ~3,00 | Rollback limitado a 10 versões |
| CI constrói só o serviço alterado | — | Minutos de runner economizados |
| **Total economizado** | **~458,35** | |

### Sobre a maior economia da lista

Versões do Kubernetes fora do suporte padrão custam **US$ 0,60/hora** em vez de
US$ 0,10 — seis vezes mais, US$ 438/mês por cluster. Com dois clusters (produção e DR),
rodar uma versão vencida custaria **US$ 730/mês adicionais**, quase triplicando a conta.

A versão foi fixada em **1.36** (suporte padrão) e a variável em
`terraform/modules/platform/variables.tf` carrega essa advertência, para que um upgrade
futuro não reintroduza o problema silenciosamente.

---

## 5. Recomendações

### Recomendação principal: Compute Savings Plan

Os nós On-Demand representam a maior linha de custo variável estável da plataforma.
Um **Compute Savings Plan de 1 ano, sem pagamento adiantado**, reduz essa linha em
aproximadamente 30%:

| | Atual | Com Savings Plan |
|---|---|---|
| EC2 On-Demand (prod + DR) | 91,11 | ~63,80 |
| **Economia** | | **~27,31/mês (~328/ano)** |

O Savings Plan cobre EC2 independentemente de família, tamanho e região, então continua
valendo se a arquitetura mudar. O compromisso de 1 ano é compatível com o horizonte da
plataforma.

### Recomendação alternativa: DR em cold standby

Se a diretoria aceitar elevar o RTO de 4 h para ~6 h, é possível desligar o cluster de
DR e manter apenas o Terraform versionado, os snapshots replicados e as imagens no ECR:

| | Warm standby | Cold standby |
|---|---|---|
| Custo do DR | 170,00 | ~33,00 |
| RTO | 4 horas | ~6 horas |
| **Economia** | | **137,00/mês (1.644/ano)** |

A decisão é de negócio: 2 horas adicionais de indisponibilidade valem US$ 1.644/ano
para a SolidaryTech? O time técnico não deve decidir isso sozinho.

### Recomendação futura: migração para Graviton

Instâncias `t4g.medium` (ARM) custam cerca de 20% menos que `t3.medium` com desempenho
equivalente para estas cargas. Exige build multi-arquitetura das imagens — trabalho
pequeno para Go, um pouco maior para as dependências Python compiladas.

Economia estimada: **~US$ 18/mês**. Fica como evolução, não como ação imediata.

---

## 6. Acompanhamento

| Prática | Frequência |
|---|---|
| Revisão do Cost Explorer agrupado por `CostCenter` | Mensal |
| Comparação entre forecast e realizado | Mensal |
| Revisão dos `requests` contra o uso real no Grafana | Trimestral |
| AWS Budget com alerta em 80% do previsto | Contínuo |

O rightsizing não é tarefa única: `requests` definidos antes do tráfego real são
hipóteses. A revisão trimestral existe para corrigi-los com dados.
