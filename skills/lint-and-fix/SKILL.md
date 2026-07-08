---
name: lint-and-fix
description: Автоматическое применение автофиксов линтеров при открытии PR
triggers:
  - event: pull_request_opened
maker: holix-lint
checker: linters
arbiter: hermes
max_retries: 1
token_budget: 10000
cost_limit_usd: 0.50
---

# Lint-and-Fix Loop

## Контекст

При открытии любого PR в репозиторий Hermes запускает этот loop для
автоматического применения style-фиксов. Loop использует локального агента
`holix-lint` (не OpenHands — это дешёвая детерминированная операция).
Изменения пушатся в ту же PR-ветку, новый PR не создаётся. Если линтеры
находят non-autofixable issues — `holix-lint` оставляет комментарии в PR
через GitHub MCP.

Лимит токенов и стоимости жёстко ограничен: 10000 токенов и $0.50. Это
защита от случайного раздутия задач. Если лимит превышен — loop
останавливается, в PR оставляется комментарий `lint-budget-exceeded`.

## Шаги

1. Через GitHub MCP получить список изменённых файлов в PR:

   ```text
   github.mcp.list_pr_files(pr_number=<number>)
   ```

2. Отфильтровать по типу:
   - `.py` — black, isort, flake8.
   - `.ts`, `.tsx`, `.js`, `.jsx` — eslint, prettier.
   - `.css`, `.scss`, `.html`, `.json`, `.md` (только prettier) — prettier.
3. Применить автофиксы для Python:

   ```bash
   black --line-length=120 <files>
   isort --profile=black <files>
   ```

4. Применить автофиксы для JS/TS:

   ```bash
   eslint --fix <files>
   prettier --write <files>
   ```

5. Проверить через flake8 на non-autofixable issues:

   ```bash
   flake8 --max-line-length=120 --select=E,W,F <files>
   ```

6. Если есть изменения после автофиксов:
   - Закоммитить с сообщением:

     ```text
     style: auto-fix lint issues by holix-lint [black, isort, eslint, prettier]
     ```

   - Запушить в PR-ветку (НЕ создавать новый PR):

     ```bash
     git push origin HEAD:refs/heads/<pr_branch>
     ```

7. Если flake8 нашёл non-autofixable issues — оставить комментарии в PR
   через GitHub MCP `create_review_comment` для каждого issue с указанием
   файла, строки и описанием.
8. Обновить PROGRESS.md: номер PR, количество файлов, применённые инструменты.
9. Сгенерировать HANDOFF.md (короткий) через `/handoff` для аудита.

## Жёсткие критерии остановки

- Все доступные автофиксы применены (black/isort/eslint/prettier exit 0).
- Линтеры flake8 и eslint возвращают exit 0 или только warnings (не errors).
- Изменения запушены в PR-ветку.
- Сумма токенов < 10000.
- Стоимость < $0.50.
- Количество попыток < 1 (loop однопроходный, без ретраев).

## Исключения

- `.md` файлы — применить только prettier (без eslint/black).
- Файлы в `vendored/`, `third_party/`, `node_modules/` — пропускаются.
- Файлы в `migrations/` (Alembic) — пропускаются (автогенерируемые).
- PR с меткой `no-auto-fix` — пропускается целиком без действий.
- PR от dependabot или renovate — пропускается (они сами управляют стилем).
- Если PR-ветка защищена (branch protection `require_signed_commits`) —
  пуш может быть отклонён, в этом случае оставить комментарий в PR с
  предложенными изменениями.
- Если количество изменённых файлов > 50 — пропустить автофикс, оставить
  комментарий `too-many-files-review-manually`.
