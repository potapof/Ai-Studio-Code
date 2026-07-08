---
name: dependency-update
description: Еженедельное безопасное обновление minor/patch Python-зависимостей с проверкой через pytest и pip-audit
triggers:
  - cron: "0 10 * * 1"
maker: openhands
checker: holix-qa
arbiter: hermes
max_retries: 3
token_budget: 50000
cost_limit_usd: 2.00
---

# Dependency Update Loop

## Контекст

Python-проект использует `requirements.txt` для фиксации зависимостей. Каждую
неделю в понедельник в 10:00 Hermes запускает этот loop для безопасного
обновления minor- и patch-версий. Major-обновления пропускаются и помечаются
для ручного ревью. Цель — держать зависимости свежими без регрессий и без
критических CVE.

Перед началом работы Hermes обязан выполнить векторный поиск в таблице
`public.handoff_documents` через postgres MCP, чтобы извлечь опыт прошлых
прогонов dependency-update (что ломалось, какие пакеты требуют осторожности,
какие версии вызывали регрессии). Найденный контекст передаётся OpenHands как
часть системного промпта.

## Шаги

1. Hermes делает векторный поиск в `public.handoff_documents` по запросу
   "dependency update python pip" и получает топ-5 релевантных записей.
2. OpenHands создаёт worktree `worktree/deps-{YYYY-MM-DD}` от `main`.
3. Получить список устаревших пакетов:

   ```bash
   pip list --outdated --format=json > /tmp/outdated.json
   ```

4. Для каждого пакета из списка определить тип обновления:
   - `patch` (1.2.3 -> 1.2.4) — обновляем.
   - `minor` (1.2.3 -> 1.3.0) — обновляем.
   - `major` (1.2.3 -> 2.0.0) — пропускаем, логируем в PROGRESS.md.
5. Для каждого minor/patch обновления по очереди:
   - Обновить версию в `requirements.txt`.
   - Установить: `pip install -r requirements.txt`.
   - Запустить тесты: `pytest -x --maxfail=1`.
   - Если exit code 0 — коммит `chore(deps): bump {pkg} {old} -> {new}`.
   - Если exit code != 0 — `git checkout requirements.txt`, пометить пакет
     как `needs-human`, продолжить со следующего.
6. После всех обновлений запустить аудит безопасности:

   ```bash
   pip-audit --strict --desc > /tmp/audit.txt
   ```

7. Если `pip-audit` находит critical CVE — эскалировать в Slack через MCP и
   создать issue в GitHub с меткой `security`.
8. Через GitHub MCP открыть PR в `main` с описанием всех обновлений.
9. Сгенерировать HANDOFF.md через `/handoff` и сохранить в `public.handoff_documents`.

## Жёсткие критерии остановки

- `pytest` exit code 0 на финальном наборе обновлений.
- `pip-audit` не находит critical CVE.
- Сумма токенов input+output < 50000.
- Количество попыток `max_retries` < 3.
- Время выполнения loop < 30 минут.

## Исключения

- Major-версии (например Django 4.2 -> 5.0) — пропускаются автоматически,
  логируются в PROGRESS.md как `major-skipped: {pkg} {old} -> {new}`.
- Known-breaking-changes (numpy 2.0, celery 5.4, pandas 3.0) — даже minor
  обновления пропускаются, пакет добавляется в whitelist-блокировки.
- `requirements-dev.txt` обновляется отдельным loop `dev-deps-update`, здесь
  не трогается.
- Пакеты, помеченные в `requirements.txt` комментарием `# pinned: do-not-bump`,
  пропускаются.
- Если worktree уже существует (повторный запуск) — использовать существующий
  с флагом `--resume`.
