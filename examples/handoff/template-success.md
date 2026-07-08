---
handoff_id: <uuid-v4>
task_id: <task-id>
agent: <agent-name>
timestamp: <ISO-8601>
status: success
model: <model-name>
---

# HANDOFF — <task title>

## Original Goal

<Краткое описание исходной цели задачи в 1-2 предложениях. Что нужно было
сделать и зачем. Точка отсчёта для следующего агента, чтобы понять
постановку без чтения исходного issue.>

## Priority

critical|high|normal|low

<Одна строка обоснования приоритета. Например: high — блокирует релиз 2.1.>

## Context Summary

<Сжатый контекст задачи на старте. Включает:
- стек технологий (FastAPI 0.104, PostgreSQL 16, SQLAlchemy 2.0).
- связанный issue/PR.
- найденные через векторный поиск в public.handoff_documents похожие задачи.
- найденные через SOA проверенные решения.
- ограничения (бюджет токенов, дедлайн).
Не более 5-7 предложений.>

## Steps Taken

1. <Шаг 1 — что конкретно сделали, с указанием инструментов/MCP.>
2. <Шаг 2 — например: выполнили векторный поиск в public.skills.>
3. <Шаг 3 — например: делегировали OpenHands с расширенным промптом.>
4. <Шаг 4 — например: проверили через holix-qa (pytest, lint, coverage).>
5. <Шаг 5 — например: открыли PR через GitHub MCP.>

## Decisions Made

- <Решение 1>: <причина. Например: выбрали python-jose вместо PyJWT из-за
  поддержки JWS.>
- <Решение 2>: <причина. Например: HS256 вместо RS256 из-за простоты
  начальной конфигурации.>
- <Решение 3>: <причина.>

## Working Memory

<Текущее состояние. Что изменено, что проверено, что осталось открытым.
Например: 3 файла изменено, 47 тестов пройдено, миграция БД не требуется,
остался вопрос rotation refresh token в следующей итерации.>

## Key Findings

- <Находка 1 — что обнаружили в ходе работы. Например: старая система
  хранила session_id в Redis — нужно очистить при деплое.>
- <Находка 2 — например: pgvector отлично находит похожие handoffs по
  семантическому сходству, top-3 оказались релевантны.>
- <Находка 3 — например: SOA вернул 2 проверенных решения, одно применили.>

## Files Modified

- path/to/file.py — <что изменено. Например: новый модуль JWT-аутентификации.>
- path/to/other.py — <что изменено. Например: обновлён middleware auth.>
- path/to/test_file.py — <что изменено. Например: 12 новых unit-тестов.>

## Tests

- pytest: PASS (47 tests, 0 failed, 3 skipped)
- flake8: PASS (0 issues)
- coverage: 82% (новых файлов 91%)
- bandit: PASS (0 security issues)

## Next Steps

- <Что должен сделать следующий агент. Например: обновить документацию API
  в /docs/auth.md с описанием эндпоинтов /login и /refresh.>
- <Например: добавить rotation refresh token в следующей итерации.>
- <Например: настроить CI на запуск bandit в обязательном режиме.>

## Tokens Used

- input: 28400
- output: 9800
- total: 38200
- budget: 50000 (использовано 76%)

## Embedding Hints

<Ключевые слова для будущих векторных поисков в public.handoff_documents.
Эти теги повышают шанс, что следующий агент найдёт этот handoff через
embedding-поиск:>

- fastapi, jwt, auth, migration, python-jose, HS256, access token, refresh
  token, sqlalchemy, session to jwt, oauth, middleware
