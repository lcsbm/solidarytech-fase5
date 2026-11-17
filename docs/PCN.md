# Plano de Continuidade de Negócios — SolidaryTech

**Versão:** 1.0
**Data:** Novembro de 2026
**Responsável técnico:** Lucas Santana Bezerra de Melo (RM 373161)
**Destinatário:** Diretoria da SolidaryTech

---

## 1. Por que este plano existe

A SolidaryTech ganhou exposição em rede nacional e passou a receber picos de acesso
imprevisíveis. Hoje, uma indisponibilidade prolongada da plataforma significa doações
que simplesmente não acontecem — e, diferente de um e-commerce, uma doação perdida
raramente é refeita depois.

Este documento define o que a organização se compromete a garantir diante de uma falha
grave, quanto tempo levamos para voltar ao ar e quanto de informação podemos perder no
pior cenário.

---

## 2. Compromissos: RTO e RPO

| Métrica | Valor | O que significa na prática |
|---|---|---|
| **RTO** (Recovery Time Objective) | **4 horas** | Prazo máximo entre a declaração do desastre e a plataforma voltar a aceitar doações. |
| **RPO** (Recovery Point Objective) | **24 horas** | Volume máximo de dados que podemos perder, medido em tempo. No pior caso, perdemos as transações desde o último backup diário. |

### Composição do RTO (4 horas)

| Etapa | Tempo estimado |
|---|---|
| Decisão e declaração formal do desastre | 30 min |
| Escala do cluster de DR (`terraform apply`) | 30 min |
| Restauração dos bancos a partir do snapshot | 45 min |
| Sincronização das aplicações pelo ArgoCD | 15 min |
| Validação funcional (testes de fumaça) | 30 min |
| Propagação de DNS | 60 min |
| **Margem de segurança** | 30 min |
| **Total** | **4 horas** |

### Composição do RPO por base de dados

O RPO declarado é o do componente mais exposto. Cada base tem garantia própria:

| Dados | Mecanismo | RPO real |
|---|---|---|
| Doações (PostgreSQL) | Snapshot automático diário + retenção 7 dias | 24 h |
| ONGs (PostgreSQL) | Snapshot automático diário + retenção 7 dias | 24 h |
| Voluntários (DynamoDB) | Point-in-Time Recovery contínuo | ~5 min |
| Eventos de doação (SQS) | Fila durável + DLQ com retenção de 14 dias | 0 (nenhuma perda) |

> **Observação para a diretoria:** o RPO de 24 h é um compromisso conservador, ditado
> pelo custo dos snapshots. Reduzi-lo para 5 minutos nas bases relacionais é tecnicamente
> viável com réplicas cross-region, ao custo adicional estimado de **US$ 30/mês**.
> A decisão é de negócio, não técnica — a seção 6 detalha o trade-off.

---

## 3. Arquitetura de resiliência

A plataforma opera em modelo **Ativo-Passivo (Warm Standby)** entre duas regiões da AWS:

```
us-east-1 (PRIMÁRIO — ativo)          us-east-2 (DR — aquecido)
├── EKS solidarytech-production       ├── EKS solidarytech-dr (1 nó ligado)
│   ├── nós On-Demand (donation)      │
│   └── nós Spot (ngo, volunteer)     │
├── RDS ngo_db + donation_db          ├── RDS provisionado, restaurado sob demanda
├── DynamoDB (PITR ativo)             ├── DynamoDB (PITR ativo)
├── SQS + DLQ                         ├── SQS + DLQ
└── ECR (origem das imagens) ────replicação automática───► ECR (espelho)
```

O ponto central: **as duas regiões são descritas pelo mesmo módulo Terraform**
(`terraform/modules/platform`). A região de DR não é uma cópia manual que envelhece —
toda mudança aplicada na produção é aplicável ao DR com os mesmos arquivos.

### Por que Warm Standby e não Ativo-Ativo

Ativo-Ativo eliminaria o RTO, mas dobraria o custo de infraestrutura. Para uma ONG com
orçamento restrito, manter um ambiente completo ocioso não se justifica. O Warm Standby
mantém o cluster de DR com **1 nó ligado** (custo de ~US$ 35/mês) e escala sob demanda.

---

## 4. Procedimento de ativação do DR

Pré-requisito: a decisão de acionar o DR cabe ao responsável técnico de plantão, após
confirmar que a indisponibilidade do primário excede 1 hora sem previsão de retorno.

**Passo 1 — Escalar o cluster de DR.** Pela esteira, para que a ação fique registrada
no histórico do GitHub Actions e auditável no post-mortem:

> *Actions > "Terraform — Plan e Apply" > Run workflow* → `environment: dr`,
> `action: apply`

**Passo 2 — Restaurar os bancos** a partir do snapshot mais recente:

```bash
aws rds restore-db-instance-from-db-snapshot \
  --region us-east-2 \
  --db-instance-identifier solidarytech-dr-donation \
  --db-snapshot-identifier <snapshot-mais-recente>
```

**Passo 3 — Sincronizar as aplicações** no cluster de DR:

```bash
aws eks update-kubeconfig --region us-east-2 --name solidarytech-dr
kubectl apply -f gitops/bootstrap/app-of-apps.yaml
```

**Passo 4 — Validar:**

```bash
kubectl get pods -n solidarytech
curl https://<endpoint-dr>/health
```

**Passo 5 — Redirecionar o DNS** no Route53 para o load balancer da região de DR.

> **Break-glass:** se o próprio GitHub Actions estiver indisponível durante o
> desastre, o passo 1 pode ser executado localmente com
> `terraform -chdir=terraform/envs/dr apply -var="warm_standby_nodes=2"`.
> O uso dessa exceção precisa constar do post-mortem — ela contorna a trilha de
> auditoria que a esteira fornece.

### Retorno ao primário (failback)

Depois que a região primária for restabelecida, o retorno segue a ordem inversa, com uma
diferença crítica: **os dados gerados durante o período de DR precisam ser replicados de
volta antes do redirecionamento do DNS**. Essa etapa é manual e exige janela de manutenção
anunciada às ONGs parceiras.

---

## 5. Teste do plano

Um plano de continuidade que nunca foi testado é uma suposição, não uma garantia.

| Teste | Frequência | Evidência esperada |
|---|---|---|
| `terraform plan` no ambiente de DR | A cada PR (automatizado no CI) | Plan limpo, sem divergência do primário |
| Restauração de snapshot em ambiente isolado | Trimestral | Banco restaurado e íntegro |
| Simulação completa de failover | Semestral | RTO real medido e comparado às 4 h |

---

## 6. Riscos aceitos conscientemente

Estes pontos são limitações conhecidas. Registrá-los é parte do plano:

1. **Janela de 24 h de perda nas bases relacionais.** Mitigável com réplicas cross-region
   (+US$ 30/mês). Pendente de decisão da diretoria.
2. **Failback manual.** O retorno ao primário não é automatizado e exige janela de
   manutenção. Automatizá-lo exigiria replicação bidirecional, de complexidade e custo
   desproporcionais à escala atual.
3. **Dependência de região única da AWS por vez.** Uma falha simultânea em us-east-1 e
   us-east-2 não é coberta. A probabilidade é considerada aceitável frente ao custo de
   uma terceira região ou de outro provedor.
4. **Instâncias Spot no primário.** `ngo-service` e `volunteer-service` rodam em capacidade
   interrompível para economizar ~65%. O `donation-service` — o caminho crítico da doação —
   **nunca** roda em Spot. Uma interrupção afeta cadastro de ONGs e voluntários, não a doação.

---

## 7. Comunicação durante um incidente

| Público | Canal | Quando | Responsável |
|---|---|---|---|
| Equipe técnica | PagerDuty + Discord `#alerts` | Imediato (automático) | Alertmanager |
| Diretoria | E-mail + telefone | Em até 30 min da declaração | Responsável técnico |
| ONGs parceiras | E-mail + status page | Em até 1 h da declaração | Diretoria |
| Doadores | Banner na plataforma + redes sociais | Ao restabelecer o serviço | Comunicação |

---

## 8. Revisão

Este plano é revisado **semestralmente** ou sempre que houver mudança arquitetural
relevante. A próxima revisão está prevista para **maio de 2027**.
