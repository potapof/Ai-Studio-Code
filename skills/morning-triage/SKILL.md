---
name: morning-triage
description: Утренний разбор CI failures за последние 24 часа с классификацией и автоматическим фиксом bug-типа
triggers:
  - cron: "0 9 * * 1-5"
maker: openhands
checker: holix-qa
arbiter: hermes
max_retries: 2
token_budget: 100000
cost_limit_usd: 5.00
---

# Morning Triage Loop

## Контекст

Каждый будний день в 9:00 Hermes собирает список CI failures за последние
24 часа из GitHub Actions через GitHub MCP. Каждый failed run классифицируется
по одной из категорий: env, flake, bug, dependency, infra. Для bug-категории
запускается автоматический фикс через OpenHands. Для flake-категории
запускается `flaky-test-fix` loop. Для env/infra — эскалация в DevOps через
Slack. Сводка отправляется в Slack-канал `#studio-ci`.

Перед классификацией Hermes обязан найти в Stack Overflow for Agents (SOA)
через `search_by_error` похожие ошибки — возможно, решение уже известно и
фикс займёт минуту вместо полного цикла работы OpenHands.

## Шаги

1. Через GitHub MCP получить список failed runs:

   ```text
   github.mcp.list_workflow_runs(status="failure", since="24h")
   ```

2. Отфильтровать: оставить только runs из ветки `main` (feature-ветки
   пропускаются) и не старше 24 часов.
3. Для каждого failed run:
   - `github.mcp.get_failed_jobs(run_id)` — получить упавшие джобы.
   - Извлечь логи: `github.mcp.get_job_logs(job_id)`.
4. Классификация (через CI/CD-анализатор или через LLM-классификатор Hermes):
   - `env` — ошибка окружения (нет секрета, недоступен сервис) — эскалация DevOps.
   - `flake` — тест прошёл на retry — делегировать в `flaky-test-fix` loop.
   - `bug` — реальная ошибка в коде — попытаться починить.
   - `dependency` — ошибка версий пакетов — делегировать в `dependency-update`.
   - `infra` — упал GitHub/-runner/network — эскалация DevOps.
5. Перед классификацией в `bug` Hermes делает запрос в SOA:

   ```text
   soa.search_by_error(error_message=<фрагмент лога>, top_k=3)
   ```

   Если найдено готовое решение — оно передаётся OpenHands как подсказка.
6. Для `bug`: создать worktree `fix-ci-{run_id}`, делегировать OpenHands с
   контекстом (логи + SOA findings), проверить фикс через holix-qa.
7. Если holix-qa PASS — открыть PR через GitHub MCP с заголовком
   `fix(ci): resolve failure in {workflow_name} #{run_id}`.
8. Если holix-qa FAIL после `max_retries` — эскалировать, оставить комментарий
   в issue (созданной автоматически) с логами и контекстом.
9. Обновить PROGRESS.md: дата, run_id, категория, результат, ссылка на PR.
10. Сводку за день отправить в Slack через MCP:

    ```text
    slack.mcp.post_message(channel="#studio-ci", text=summary)
    ```

11. Сгенерировать HANDOFF.md через `/handoff` для каждого bug-fix и сохранить
    в `public.handoff_documents`.

## Жёсткие критерии остановки

- Все bug-fixes либо прошли holix-qa, либо эскалированы.
- Доля эскалаций < 50% от общего числа bug-fixes (иначе loop неэффективен).
- Сумма токенов < 100000.
- Количество попыток < 2.
- Все сводные записи добавлены в PROGRESS.md.

## Исключения

- Failed run в feature-ветке (не `main`) — пропускается без действий.
- Failed run старше 24 часов — пропускается (поиск `since="24h"` отсекает).
- Если для failed run уже есть активный PR с меткой `ci-fix` — пропускается,
  чтобы не дублировать работу.
- Run из `scheduled` workflow (cron) — обрабатывается отдельным loop
  `scheduled-triage`, здесь пропускается.
- Если GitHub API возвращает 5xx — повторить 3 раза с backoff, затем
  эскалировать в DevOps.
