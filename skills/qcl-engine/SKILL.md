---
name: qcl-engine
description: Quality Control Loop — центральный конвейер качества Студии. Параллельная проверка задачи 3+ специалистами, скоринг, автоматический возврат на доработку или эскалация человеку
triggers:
  - event: task_submitted
  - event: pr_opened
maker: holix-qa
checker: holix-loop-checker
arbiter: hermes
max_retries: 2
token_budget: 80000
cost_limit_usd: 3.00
---

# QCL Engine — Quality Control Loop

Центральный навык Студии. Каждая задача перед сдачей проходит через этот конвейер.

## Когда применять

- Разработчик (backend-lead / frontend-lead) сдал задачу — `SUBMIT`
- Открыт Pull Request
- Найдена ошибка в CI — нужен root cause анализ

## Pipeline (4 стадии)

```
STAGE 1: MULTI-REVIEW (параллельно)
├── holix-qa           → тесты (unit + integration)
├── holix-lint         → кодстайл, форматирование
├── holix-loop-checker → антипаттерны, зацикливания
│
STAGE 2: SCORE AGGREGATION
├── Каждый агент выставляет score 0-100
├── Порог: ≥ 80 по каждой проверке
├── Критические находки → автоматический RETURN
│
STAGE 3: DECISION
├── ✅ ALL ≥ 80, 0 CRITICAL → APPROVED
├── 🔄 Любая < 80 → RETURN_TO_AUTHOR (макс. 2 цикла)
├── ↗️  ROUTE_TO_SPECIALIST → проблема требует узкого спеца
└── ⚠️  2 цикла без улучшения → ESCALATE_HITL (человеку)
│
STAGE 4: ITERATION CONTROL
├── Итерация 1/2: разработчик исправляет → повтор QCL
├── Итерация 2/2: FAIL → эскалация человеку
└── MAX: 7 итераций (absolute limit)
```

## Скоринг

### holix-qa (тесты)
| Score | Критерий |
|-------|----------|
| 90-100 | Все тесты проходят, coverage ≥ 80% |
| 80-89 | Тесты проходят, coverage 60-79% |
| 60-79 | Тесты проходят, coverage < 60% или есть skipped |
| < 60 | Тесты падают или отсутствуют |

### holix-lint (кодстайл)
| Score | Критерий |
|-------|----------|
| 90-100 | 0 ошибок линтера |
| 80-89 | 0 ошибок, ≤ 5 warnings |
| 60-79 | 1-3 ошибки |
| < 60 | > 3 ошибок |

### holix-loop-checker (архитектура)
| Score | Критерий |
|-------|----------|
| 90-100 | Паттерны соблюдены, нет дублирования |
| 80-89 | Мелкие замечания |
| 60-79 | Нарушение паттерна, дублирование логики |
| < 60 | Архитектурный конфликт, циклическая зависимость |

## Пример: QCL-трассировка

```
=== QCL Run: задача "REST API products" ===

STAGE 1: Multi-Review (параллельно, 3 агента)
  holix-qa            → 88/100 ✅ (тесты проходят, coverage 76%)
  holix-lint          → 92/100 ✅ (0 ошибок, 2 warnings)
  holix-loop-checker  → 75/100 ❌ (дублирование логики в ProductService и ProductController)

STAGE 2: Aggregation
  holix-loop-checker: 75 < 80 → триггер RETURN
  Критических находок: 0

STAGE 3: Decision
  → RETURN_TO_AUTHOR
  → Feedback: "Вынести общую логику в ProductRepository. 
    ProductController не должен дублировать валидацию из ProductService."

STAGE 4: Iteration
  → Итерация 1/2. Ожидание исправлений от backend-lead.
```

## Интеграция со спящими агентами

При наличии меток в задаче QCL автоматически пробуждает спящих:

| Метка | Пробуждается | Проверка |
|-------|-------------|----------|
| `security` | holix-security | OWASP Top 10, поиск секретов |
| `perf` | holix-performance | N+1 запросы, бандл, бенчмарки |
| `bug` / `crash` | holix-debug | Root cause анализ |

## Команда для Hermes

```
Ты (Hermes) получаешь SUBMIT от разработчика.
Вызываешь skill qcl-engine:
  1. Отправляешь задачу на параллельную проверку (qa + lint + loop-checker)
  2. Собираешь скоринг
  3. Если APPROVED → докладываешь пользователю
  4. Если RETURN → возвращаешь разработчику с фидбеком
  5. Если итерация 2 и FAIL → эскалируешь человеку
```
