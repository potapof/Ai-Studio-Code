---
name: pr-drafting
description: Генерация draft PR из GitHub issue с меткой ready-for-dev через полный цикл разработки
triggers:
  - event: issue_labeled
    label: ready-for-dev
maker: openhands
checker: holix-qa
arbiter: hermes
max_retries: 2
token_budget: 150000
cost_limit_usd: 7.00
---

# PR Drafting Loop

## Контекст

Когда issue в GitHub получает метку `ready-for-dev`, Hermes запускает этот
loop: читает issue, ищет релевантные навыки в `public.skills` через векторный
поиск, находит похожие прошлые задачи в `public.handoff_documents`, ищет
проверенные решения на Stack Overflow через SOA MCP. На основе собранного
контекста OpenHands реализует feature, пишет тесты и открывает DRAFT PR.

Loop имеет высокий бюджет (150000 токенов, $7.00), потому что это полноценная
задача разработки. Если acceptance criteria не покрыты — PR не открывается,
в issue оставляется комментарий с просьбой уточнить требования.

## Шаги

1. Через GitHub MCP получить детали issue:

   ```text
   github.mcp.get_issue(issue_number=<number>)
   ```

2. Через postgres MCP выполнить векторный поиск в `public.skills`:

   ```sql
   SELECT name, description, embedding <=> $1 AS distance
   FROM public.skills
   ORDER BY distance LIMIT 5;
   ```

   Где `$1` — embedding описания issue. Найденные навыки передаются OpenHands
   как готовые инструкции.

3. Через postgres MCP выполнить векторный поиск в `public.handoff_documents`:

   ```sql
   SELECT task_title, summary, embedding <=> $1 AS distance
   FROM public.handoff_documents
   ORDER BY distance LIMIT 5;
   ```

   Найденные прошлые задачи передаются как контекст (что уже делали, какие
   решения работали, какие подводные камни).

4. Через SOA MCP `so_search` найти проверенные решения:

   ```text
   soa.so_search(query=<ключевые слова из issue>, top_k=5)
   ```

5. Сформировать ограниченный контекст: issue + skills + handoffs + SOA
   findings. Если суммарный размер > 30000 токенов — обрезать, оставив
   только топ-3 от каждого источника.
6. Создать worktree `feature-{issue_number}` от `main`.
7. Делегировать OpenHands с расширенным системным промптом:
   - Прочитать issue целиком.
   - Реализовать feature согласно acceptance criteria.
   - Написать unit-тесты (coverage новых файлов >= 70%).
   - Обновить документацию (README, docstrings).
   - Использовать найденные навыки из `public.skills`.
8. После завершения работы OpenHands передаёт результат в holix-qa для
   проверки: pytest, lint, coverage, acceptance criteria checklist.
9. Если holix-qa PASS — открыть DRAFT PR через GitHub MCP:

   ```text
   github.mcp.create_pr(
     title="[#<issue_number>] <issue_title>",
     body="<ссылка на issue> + summary + checklist>",
     draft=True
   )
   ```

10. Если holix-qa FAIL после `max_retries` — оставить комментарий в issue:
    `needs clarification: <reason>` с описанием проблемы.
11. Связать PR с issue: добавить в тело PR строку `Closes #<issue_number>`.
12. Сгенерировать HANDOFF.md через `/handoff`, сохранить в
    `public.handoff_documents` с embedding для будущих поисков.

## Жёсткие критерии остановки

- Все acceptance criteria из issue покрыты (проверяет holix-qa).
- `pytest` проходит на полном наборе тестов.
- Coverage новых файлов >= 70%.
- Линтеры (flake8, eslint) возвращают exit 0.
- PR создан в статусе `draft=true`.
- Сумма токенов < 150000.
- Количество попыток < 2.

## Исключения

- Issue с меткой `complex` или `architecture` — эскалировать Hermes-у для
  ручного анализа, loop не запускается.
- Требует изменения БД schema (миграции Alembic) — эскалировать с пометкой
  `needs-db-migration-review`.
- Требует новых external API (Stripe, Twilio, SendGrid) — эскалировать с
  пометкой `needs-external-api-review`.
- Нет acceptance criteria в issue — оставить комментарий с просьбой
  уточнить, loop не запускается до исправления.
- Issue помечен как `epic` или имеет подзадачи — пропускается (обрабатываются
  подзадачи отдельно).
- Если worktree `feature-{issue_number}` уже существует — повторно не
  создаётся, loop завершается с пометкой `already-in-progress`.
