---
handoff_id: <uuid-v4>
task_id: <task-id>
agent: <agent-name>
timestamp: <ISO-8601>
status: failure
model: <model-name>
---

# HANDOFF — <task title>

## Original Goal

<Краткое описание исходной цели задачи в 1-2 предложениях. Сохраняется
дословно из исходного задания.>

## Priority

critical|high|normal|low

<Одна строка обоснования приоритета.>

## Context Summary

<Сжатый контекст на старте: стек, связанный issue, найденные через векторный
поиск handoffs, SOA-решения, ограничения. 5-7 предложений.>

## Failure Reason

<Главная причина провала. Одна-две строки. Например: "Превышен budget
токенов (150000), holix-qa не запущен.">

## Attempted Approaches

- <Подход 1 — что пробовали. Например: bump numpy до 2.0 — 12 тестов упали.>
- <Подход 2 — например: monkey-patching — ломается в production из-за JIT.>
- <Подход 3 — например: даунгрейд pandas до 1.5 — конфликт с SQLAlchemy 2.0.>

## Blockers

- <Блокер 1 — что помешало. Например: нет доступа к staging Stripe.>
- <Блокер 2 — например: документация external API требует NDA.>
- <Блокер 3 — например: превышен budget, работа невозможна без одобрения.>

## Lessons Learned

- <Урок 1 — что учесть. Например: перед bump major numpy прогнать
  deprecation-warnings в отдельном CI job.>
- <Урок 2 — например: SOA не имеет решений для numpy 2.0 + pandas 1.x.>
- <Урок 3 — например: budget 150000 недостаточен для миграции типов.>

## Recommended Next Agent

<Какой агент подхватит задачу и почему. Например: "holix-archivist — для
анализа архитектуры миграции." Или: "human — нужно бизнес-решение об
увеличении budget или изменении acceptance criteria.">

## Working Memory

<Текущее состояние. Например: 1 файл изменён (numpy_compat.py — shim),
тесты FAIL (12 failures, 4 errors), worktree не удалён, PR не открыт.>

## Key Findings

- <Находка 1 — например: numpy 2.0 удалил np.float — нужно 47 правок.>
- <Находка 2 — например: pgvector нашёл 2 похожих handoffs, оба через
  даунгрейд, что не подходит.>

## Files Modified

- path/to/file.py — <что изменено. Может быть пусто.>
- path/to/other.py — <что изменено.>

<Если файлов нет — оставить: "Файлы не изменены" или "Изменения откатаны.">

## Tests

- pytest: FAIL (12 failed, 4 errors, 231 passed)
- flake8: PASS (0 issues)
- Подробности: <ссылка на лог>

## Next Steps

- <Что должен сделать следующий агент. Например: проанализировать 12 failures
  и оценить объём миграции np.float -> float.>
- <Например: запросить увеличение budget до 250000 токенов через Hermes.>

## Tokens Used

- input: 142800
- output: 8200
- total: 151000
- budget: 150000 (превышено на 1000, остановлено принудительно)

## Embedding Hints

<Ключевые слова для будущих векторных поисков, включая термины ошибки:>

- numpy, numpy 2.0, np.float, deprecation, migration failed, pandas conflict,
  SQLAlchemy 2.0 type hints, budget exceeded, workaround
