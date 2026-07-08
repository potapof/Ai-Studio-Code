---
name: flaky-test-fix
description: Воспроизведение и исправление нестабильных тестов, прошедших на retry в CI
triggers:
  - event: ci_test_failure
    condition: "test passed on retry"
maker: openhands
checker: holix-qa
arbiter: hermes
max_retries: 3
token_budget: 75000
cost_limit_usd: 3.00
---

# Flaky Test Fix Loop

## Контекст

Тест упал в CI, но прошёл при автоматическом retry. Это классический flaky
test — нестабильный тест, который может упасть из-за таймингов, race
condition, сети или состояния БД. Hermes ловит событие `ci_test_failure` с
условием `test passed on retry` и запускает этот loop.

Перед началом Hermes использует SOA `analyze_stack_trace` для анализа stack
trace упавшего теста. Также выполняется векторный поиск в
`public.handoff_documents` — возможно, похожий flaky уже чинили в прошлом
прогоне и рецепт фикса известен. Если найден — OpenHands получает готовую
подсказку.

## Шаги

1. Получить из CI failure payload имя упавшего теста и stack trace.
2. Hermes выполняет векторный поиск в `public.handoff_documents` по запросу
   `flaky test {test_name}` — топ-3 релевантных записи.
3. Hermes вызывает SOA `analyze_stack_trace` для анализа трейса и получения
   рекомендаций.
4. OpenHands создаёт worktree `fix-flaky-{test_short_hash}` от `main`.
5. Локально запустить тест 10 раз для воспроизведения:

   ```bash
   pytest --repeat=10 -v tests/path/to/test_file.py::test_name > /tmp/flaky.log
   ```

6. Если не воспроизводится (10/10 PASS) — запустить 50 раз:
   `pytest --repeat=50 -v`. Если 50/50 PASS — закрыть loop с пометкой
   `not-reproducible`, оставить комментарий в CI.
7. Анализ паттерна failures (если воспроизвёлся):
   - `Timeout` — увеличить `@pytest.mark.timeout`, добавить `pytest-timeout`.
   - `Race condition` — добавить `threading.Lock` или `asyncio.Event`.
   - `Network` — обернуть в `tenacity.retry` с экспоненциальным backoff.
   - `DB flakiness` — `conftest.py` cleanup fixtures, `transaction.rollback`.
   - `Order dependency` — `@pytest.mark.dependency`, удалить глобальное состояние.
8. Подготовить фикс в worktree. Запустить тест 50 раз для верификации:

   ```bash
   pytest --repeat=50 -v tests/path/to/test_file.py::test_name
   ```

9. Если стабильность >= 98% — запустить полный набор тестов:

   ```bash
   pytest -x --maxfail=3
   ```

10. Если PASS — коммит `test: fix flaky {test_name} ({reason})`, открыть PR.
11. Если после `max_retries` стабильность < 98% — эскалировать, оставить
    комментарий с анализом паттерна.
12. Сгенерировать HANDOFF.md через `/handoff`, сохранить в
    `public.handoff_documents` с тегами `flaky, {pattern}, {test_name}`.

## Жёсткие критерии остановки

- Стабильность >= 98% из 50 запусков целевого теста.
- `pytest` exit code 0 на полном наборе тестов.
- Нет новых warnings (сравнить с baseline `pytest --tb=short -W error`).
- Сумма токенов < 75000.
- Количество попыток < 3.

## Исключения

- Тест требует external service (Stripe webhook, Twilio SMS) — эскалировать с
  пометкой `needs-mock-or-test-env`.
- Тест помечен `@pytest.mark.skip` — пропускается.
- Тест из `tests/integration/` — особый конфиг: запускать с `--integration`
  флагом, использовать test-контейнеры вместо моков.
- Тест зависит от времени суток (`datetime.now()`) — использовать
  `freezegun.freeze_time` вместо изменения логики.
- Если `pytest --repeat` не установлен — установить `pytest-repeat` через
  `pip install pytest-repeat` (в requirements-dev.txt).
