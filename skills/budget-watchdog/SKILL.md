---
name: budget-watchdog
description: Сторож бюджета — ежечасная проверка расхода токенов/средств с авто-остановкой агентов при превышении порогов
triggers:
  - cron: "every 1h"
maker: hermes
checker: budget-watchdog
arbiter: hermes
max_retries: 1
token_budget: 5000
cost_limit_usd: 0.10
---

# Budget Watchdog — сторож бюджета Студии

Ежечасная cron-задача. Проверяет расход бюджета и действует по порогам.

## Пороги и действия

| Зона | Процент | Действие |
|------|---------|----------|
| 🟢 НОРМА | 0-60% | Ничего не делать |
| 🟡 ВНИМАНИЕ | 60-80% | Уведомление пользователю |
| 🟠 КРИТИЧЕСКИЙ | 80-90% | Рекомендация: переключить на дешёвую модель |
| 🔴 HARD STOP | 90%+ | Приостановка всех агентов, уведомление |

## Проверяемые метрики

- Количество сессий агентов за сегодня (`public.agent_sessions`)
- Суммарный token_budget использованный
- Дневной лимит (`limits.daily_cost_usd_limit`)

## Запрос к БД

```sql
SELECT 
  COUNT(*) as sessions_today,
  COALESCE(SUM(token_budget), 0) as budget_used
FROM public.agent_sessions 
WHERE created_at >= CURRENT_DATE;
```

## Эскалация

При 🔴 HARD STOP:
1. Все Holix-агенты приостанавливаются
2. Пользователь получает уведомление
3. Только ручное подтверждение возобновляет работу
