# Ciclo de Vida do Incidente — SolidaryTech

Como um incidente nasce, é tratado e se encerra na plataforma. O objetivo do desenho
é reduzir o MTTR: cada etapa automatizada é tempo que não se gasta esperando um humano.

---

## Visão geral do fluxo

```
┌─ DETECÇÃO ──────────────────────────────────────────────────────────┐
│                                                                      │
│  New Relic Applied Intelligence        Prometheus / Grafana          │
│  (anomalia comportamental)             (regra determinística)        │
│           │                                     │                    │
│           └──────────────┬──────────────────────┘                    │
└──────────────────────────┼───────────────────────────────────────────┘
                           ▼
┌─ TRIAGEM ────────────────────────────────────────────────────────────┐
│  Alertmanager classifica por severity                                │
│    critical ──► PagerDuty (página o on-call) + Self-Healing (webhook) │
│    warning  ──► Discord #alerts (sem paginar)                         │
└──────────────────────────┬───────────────────────────────────────────┘
                           ▼
┌─ REMEDIAÇÃO ─────────────────────────────────────────────────────────┐
│  AUTOMÁTICA                          │  MANUAL                        │
│  relay ──► GitHub Actions            │  On-call investiga:            │
│  kubectl rollout restart             │  Traces (NR) → Logs (Loki)     │
│  ~90 segundos                        │  → Dashboard SRE               │
└──────────────────────────┬───────────────────────────────────────────┘
                           ▼
┌─ VERIFICAÇÃO ────────────────────────────────────────────────────────┐
│  SLO volta ao verde? Error budget parou de queimar?                   │
│     não ──► escala para severidade maior, volta à remediação          │
│     sim ──► alerta RESOLVED, PagerDuty fecha o incidente              │
└──────────────────────────┬───────────────────────────────────────────┘
                           ▼
┌─ PÓS-INCIDENTE ──────────────────────────────────────────────────────┐
│  Post-mortem (GitHub Issue) → ações preventivas → comunicação         │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 1. Detecção

Duas fontes complementares, porque nenhuma cobre tudo sozinha:

| Fonte | O que detecta | Exemplo |
|---|---|---|
| **New Relic Applied Intelligence** | Anomalias comportamentais sem limiar pré-definido | Latência que sobe 3x fora do padrão do horário, mesmo dentro do SLO |
| **Prometheus / Grafana** | Violações de regras explícitas | `donation-service` com 0 réplicas; burn rate acima de 14,4x |

A diferença importa: o AIOps pega o que não sabíamos procurar. A regra determinística
pega o que já sabemos que dói, e pega rápido.

---

## 2. Triagem e notificação

A severidade define o canal — e, principalmente, se alguém é acordado:

| Severidade | Canal | Ação esperada | Prazo |
|---|---|---|---|
| `critical` | PagerDuty + Discord + Self-Healing | On-call assume em até 5 min | Imediato |
| `warning` | Discord `#alerts` | Tratado em horário comercial | 1 dia útil |

Alertas `critical` disparam **em paralelo** a paginação humana e a remediação
automática. Não se espera o humano para tentar o restart.

---

## 3. Remediação

### Caminho automático

O `self-healing-relay` recebe o webhook, extrai o serviço do label `service` do alerta,
valida contra a allowlist e dispara o workflow `self-healing.yml`:

```
Alerta FIRING → relay (valida) → GitHub Actions → OIDC → kubectl rollout restart
```

Cobre a classe de falha mais comum: pod travado, memory leak, deadlock de conexão.
Um restart resolve e devolve o serviço em ~90 segundos.

### Caminho manual

Quando o restart não resolve, o on-call investiga na ordem que estreita o problema
mais rápido:

1. **Dashboard SRE** — qual SLI quebrou e há quanto tempo
2. **Traces no New Relic** — qual span consome o tempo ou retorna erro
3. **Logs no Loki** — a mensagem de erro, filtrada pelo trace ID
4. **`kubectl describe`** — eventos do pod, OOMKill, falha de probe

---

## 4. Verificação

Um incidente não fecha porque o alerta parou. Fecha quando se confirma que:

- O SLI voltou acima do SLO
- O error budget parou de queimar
- Nenhum alerta relacionado continua ativo

Se não voltou em 15 minutos, a severidade escala e aciona-se o PCN caso a causa seja
infraestrutural.

---

## 5. Post-mortem

Obrigatório para todo incidente `critical`, em até 48 h, como GitHub Issue com
label `post-mortem`.

**Estrutura:**

| Seção | Conteúdo |
|---|---|
| Resumo | O que aconteceu, em duas frases |
| Impacto | Doações afetadas, duração, error budget consumido |
| Linha do tempo | Detecção → notificação → remediação → verificação, com horários |
| Causa raiz | Os "cinco porquês" até a causa sistêmica |
| O que funcionou | O que detectou e mitigou bem |
| O que falhou | Onde se perdeu tempo |
| Ações preventivas | Tarefas com responsável e prazo |

**Regra de cultura:** o post-mortem é *blameless*. Busca-se a falha no sistema, não na
pessoa. Um post-mortem que termina em "fulano errou" não encontrou a causa raiz — a
pergunta seguinte é por que o sistema permitiu o erro.

---

## 6. Comunicação aos stakeholders

| Público | Canal | Quando |
|---|---|---|
| Equipe técnica | Discord `#alerts` | Automático, imediato |
| Liderança técnica | Discord `#incidentes` | Em até 15 min, se `critical` |
| Diretoria | E-mail | Em até 1 h, se o impacto passar de 30 min |
| ONGs parceiras | E-mail | Se houve perda de doação ou indisponibilidade acima de 1 h |
| Doadores | Banner na plataforma | Durante a indisponibilidade |

---

## 7. Como este desenho reduz o MTTR

| Etapa | Sem automação | Com o fluxo atual |
|---|---|---|
| Detecção | Até alguém notar / reclamação | 1 min (regra Grafana) |
| Notificação | Manual, por canal informal | Segundos (PagerDuty) |
| Diagnóstico | Login no servidor, grep em log | Traces + logs correlacionados |
| Remediação | Comando manual do on-call | ~90 s (restart automático) |
| **MTTR típico** | **30–60 min** | **~5 min** |

O ganho não vem de um componente único, mas de nenhuma etapa esperar por um humano
disponível.
