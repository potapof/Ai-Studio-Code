# Мониторинг и метрики

> Содержание: метрика `cost_per_accepted_change`, VIEW `loop_metrics` и `loop_health`, метрика `tokens_saved_per_handoff_reuse`, Kanban-дашборд, правила автоостановки, мониторинг Docker через Portainer.

## 1. Философия метрик

В Loop Engineering 2.0 есть **одна главная метрика** — стоимость принятого изменения (`cost_per_accepted_change`). Все остальные метрики (потраченные токены, количество попыток, число запущенных loop) — вспомогательные. Ловушка, в которую попадают многие команды — оптимизация вторичных метрик в ущерб главной: например, снижение потраченных токенов за счёт отказа от сложных задач (loop становится дешёвым, но бесполезным).

Дополнительная метрика в 2.0 — **`tokens_saved_per_handoff_reuse`**. Она измеряет, сколько токенов сэкономлено за счёт переиспользования HANDOFF.md из прошлых похожих задач. Если метрика растёт со временем — система учится (HDD работает). Если stagnant — handoff'ы не переиспользуются, и нужно пересмотреть логику векторного поиска или качество embedding hints.

## 2. VIEW `loop_metrics`

```sql
CREATE OR REPLACE VIEW public.loop_metrics AS
SELECT 
    t.tenant_id,
    lr.loop_name,
    DATE_TRUNC('week', lr.run_started) AS week,
    COUNT(*) AS total_runs,
    COUNT(*) FILTER (WHERE lr.status = 'completed') AS successful_runs,
    COUNT(*) FILTER (WHERE lr.status = 'failed') AS failed_runs,
    COUNT(*) FILTER (WHERE lr.status = 'escalated') AS escalated_runs,
    SUM(lr.tokens_used) AS total_tokens,
    SUM(lr.cost_usd) AS total_cost,
    COUNT(*) FILTER (WHERE lr.pr_url IS NOT NULL) AS prs_opened,
    ROUND(100.0 * COUNT(*) FILTER (WHERE lr.status = 'completed') / NULLIF(COUNT(*), 0), 2) 
        AS success_rate_pct,
    ROUND(SUM(lr.cost_usd) / NULLIF(COUNT(*) FILTER (WHERE lr.pr_url IS NOT NULL), 0), 4) 
        AS cost_per_accepted_change,
    ROUND(100.0 * COUNT(*) FILTER (WHERE lr.status = 'escalated') / NULLIF(COUNT(*), 0), 2) 
        AS escalation_rate_pct
FROM public.tenants t
JOIN LATERAL (
    SELECT * FROM studio_default.loop_runs WHERE t.tenant_id = 'default'
    UNION ALL
    SELECT * FROM studio_acme.loop_runs WHERE t.tenant_id = 'acme'
    -- добавлять по мере создания тенантов
) lr ON true
GROUP BY t.tenant_id, lr.loop_name, DATE_TRUNC('week', lr.run_started);
```

## 3. VIEW `loop_health` — текущее здоровье

```sql
CREATE OR REPLACE VIEW public.loop_health AS
WITH last_7d AS (
    SELECT 
        t.tenant_id,
        lr.loop_name,
        COUNT(*) AS runs_7d,
        ROUND(100.0 * COUNT(*) FILTER (WHERE lr.status = 'completed') / NULLIF(COUNT(*), 0), 2) 
            AS success_rate_7d,
        ROUND(SUM(lr.cost_usd) / NULLIF(COUNT(*) FILTER (WHERE lr.pr_url IS NOT NULL), 0), 4) 
            AS cost_per_change_7d,
        ROUND(100.0 * COUNT(*) FILTER (WHERE lr.status = 'escalated') / NULLIF(COUNT(*), 0), 2) 
            AS escalation_rate_7d
    FROM public.tenants t
    JOIN LATERAL (
        SELECT * FROM studio_default.loop_runs WHERE t.tenant_id = 'default'
        UNION ALL
        SELECT * FROM studio_acme.loop_runs WHERE t.tenant_id = 'acme'
    ) lr ON true
    WHERE lr.run_started > NOW() - INTERVAL '7 days'
    GROUP BY t.tenant_id, lr.loop_name
),
last_status AS (
    SELECT DISTINCT ON (loop_name) loop_name, status
    FROM studio_default.loop_runs
    ORDER BY loop_name, run_started DESC
)
SELECT 
    l7.tenant_id,
    l7.loop_name,
    l7.runs_7d,
    l7.success_rate_7d,
    l7.cost_per_change_7d,
    l7.escalation_rate_7d,
    ls.status AS last_status,
    CASE
        WHEN ls.status = 'paused' THEN 'paused'
        WHEN l7.success_rate_7d < 50 OR l7.cost_per_change_7d > 20 OR l7.escalation_rate_7d > 30 
            THEN 'unhealthy'
        WHEN l7.success_rate_7d < 70 OR l7.cost_per_change_7d > 5 
            THEN 'needs_attention'
        ELSE 'healthy'
    END AS health_status
FROM last_7d l7
JOIN last_status ls ON l7.loop_name = ls.loop_name;
```

## 4. Метрика `tokens_saved_per_handoff_reuse`

Новая метрика 2.0 — измеряет эффективность HDD:

```sql
-- Сравнение: средние токены на задачу сейчас vs 4 недели назад
SELECT 
    DATE_TRUNC('week', created_at) AS week,
    COUNT(*) AS new_handoffs,
    ROUND(AVG(tokens_used)) AS avg_tokens_per_task,
    LAG(ROUND(AVG(tokens_used)), 4) OVER (ORDER BY DATE_TRUNC('week', created_at)) AS avg_4_weeks_ago,
    ROUND(
        LAG(ROUND(AVG(tokens_used)), 4) OVER (ORDER BY DATE_TRUNC('week', created_at)) - 
        ROUND(AVG(tokens_used))
    ) AS tokens_saved_per_task
FROM public.handoff_documents
WHERE document_type = 'handoff'
  AND outcome = 'success'
GROUP BY week
ORDER BY week DESC;
```

**Пример результата:**

| week | new_handoffs | avg_tokens_per_task | avg_4_weeks_ago | tokens_saved_per_task |
|------|-------------|---------------------|-----------------|----------------------|
| 2026-W27 | 12 | 28400 | 45000 | 16600 |
| 2026-W26 | 15 | 32100 | 52000 | 19900 |
| 2026-W25 | 18 | 38500 | NULL | NULL |

Если `tokens_saved_per_task` растёт — система учится. Если уменьшается или отрицательная — качество handoff'ов падает, нужно пересмотреть embedding hints.

## 5. Kanban-дашборд в NocoDB

Создайте Kanban-view для таблицы `loop_runs` с группировкой по `health_status`:

| Колонка | Условие | Действие |
|---------|---------|----------|
| **Healthy** | `cost_per_change < $5 AND success_rate >= 70%` | Loop работает штатно |
| **Needs attention** | `$5 <= cost_per_change < $20 OR 50% <= success_rate < 70%` | Уведомление в Slack |
| **Unhealthy** | `cost_per_change > $20 OR success_rate < 50% OR escalation_rate > 30%` | Автоостановка |
| **Paused** | `last_status = 'paused'` | Требует ручного перезапуска |

## 6. Правила автоостановки

```python
def should_pause_loop(loop_name: str, tenant_id: str) -> tuple[bool, str]:
    """Проверить, нужно ли приостановить loop."""
    metrics = get_recent_metrics(loop_name, tenant_id, days=7)
    
    if metrics.success_rate < 0.5:
        return True, f"Success rate {metrics.success_rate:.1%} < 50%"
    
    if metrics.cost_per_change > 50:
        return True, f"Cost per change ${metrics.cost_per_change:.2f} > $50"
    
    if metrics.escalation_rate > 0.3:
        return True, f"Escalation rate {metrics.escalation_rate:.1%} > 30%"
    
    return False, "OK"


def auto_pause_check():
    """Ежечасная проверка всех активных loop."""
    for tenant in get_active_tenants():
        for loop in get_active_loops(tenant):
            should_pause, reason = should_pause_loop(loop["name"], tenant)
            if should_pause:
                pause_loop(loop["name"], tenant, reason=reason)
                notify_slack_escalation(loop_name=loop["name"], reason=f"Auto-paused: {reason}")
```

Cron Hermes:

```yaml
- name: auto-pause-check
  type: cron
  schedule: "0 * * * *"  # каждый час
  task: "auto_pause_check"
```

## 7. Еженедельный отчёт

Hermes cron каждый понедельник в 9:00 генерирует отчёт в Slack:

```markdown
## Loop Weekly Report (2026-W27)

### Top performers
1. `lint-and-fix`: 47 PRs, $0.001/change, 100% success
2. `dependency-update`: 1 PR, $0.23/change, 100% success
3. `morning-triage`: 5 PRs, $2.93/change, 58% success

### Needs attention
- `morning-triage`: success rate 58% < 70% target
  - Основная причина failures: flaky tests в модуле billing
  - Рекомендация: запустить flaky-test-fix loop

### Paused
- `flaky-test-fix`: paused due to 37.5% success rate

### Cost summary
Total: $24.86 for 55 accepted changes ($0.45/change avg)

### HDD impact
- 12 новых HANDOFF.md сохранено
- Средние токены на задачу: 28400 (vs 45000 4 недели назад)
- Сэкономлено: ~16600 токенов/задача за счёт переиспользования handoff'ов
```

## 8. Мониторинг Docker через Portainer

Portainer доступен на http://localhost:9000. Предоставляет:
- **Containers** — список с CPU/RAM utilization в реальном времени
- **Logs** — просмотр логов любого контейнера
- **Console** — web-terminal внутрь контейнера
- **Volumes** — управление Docker volumes
- **Stacks** — управление docker-compose

## 9. Мониторинг MCP-серверов

```sql
-- Статистика использования MCP-серверов за неделю
SELECT 
    mcp_server,
    tool_name,
    COUNT(*) AS total_calls,
    ROUND(100.0 * COUNT(*) FILTER (WHERE result_status = 'success') / COUNT(*), 2) AS success_rate,
    ROUND(AVG(duration_ms)) AS avg_duration_ms,
    SUM(tokens_used) AS total_tokens,
    SUM(cost_usd) AS total_cost,
    MAX(timestamp) AS last_used
FROM public.api_keys_audit
WHERE timestamp > NOW() - INTERVAL '7 days'
GROUP BY mcp_server, tool_name
ORDER BY total_calls DESC;
```

**Пример результата:**

| mcp_server | tool_name | total_calls | success_rate | avg_duration_ms | total_tokens |
|-----------|-----------|-------------|--------------|-----------------|--------------|
| postgres | query | 234 | 99.6 | 47 | 0 |
| postgres | vector_search | 89 | 100.0 | 52 | 0 |
| stackoverflow | so_search | 47 | 87.2 | 487 | 0 |
| github | list_workflow_runs | 76 | 98.7 | 234 | 0 |
| slack | post_loop_completion | 12 | 100.0 | 156 | 0 |

## 10. Логирование

### 10.1. Логи Docker

```bash
docker compose logs -f --tail=100
docker compose logs -f hermes
docker compose logs hermes 2>&1 | grep -i error
```

### 10.2. Структурированные логи

Каждый сервис пишет логи в JSON-формате:

```json
{
  "level": "info",
  "timestamp": "2026-07-05T10:00:00Z",
  "agent": "hermes",
  "event": "loop_started",
  "loop_name": "dependency-update",
  "run_id": 142,
  "tenant_id": "default"
}
```

## 11. Что дальше

- **Troubleshooting** — [docs/14-troubleshooting.md](14-troubleshooting.md)
- **Дорожная карта** — [docs/15-roadmap.md](15-roadmap.md)
