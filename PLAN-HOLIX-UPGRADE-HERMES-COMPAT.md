# PLAN — Обновление Holix + максимальная совместимость с Hermes

Проект: «Студия программирования» (studio-code). Дата: 2026-07-09.
Источник истины по Holix: репозиторий javded-itres/Holix (v0.1.21) и docs
(holix-agent.ru/docs, docs/en/*.md). Работаем строго итерациями: одна итерация →
отчёт → ваше явное «продолжай» → следующая.

═══════════════════════════════════════════════════════════
РЕЗУЛЬТАТ АНАЛИЗА (что есть сейчас)
═══════════════════════════════════════════════════════════
Holix в проекте — это 8 контейнеров на одном образе `ai-studio-holix-backend:latest`:
  7 ролей (coordinator, archivist, backend-lead, frontend-lead, qa, loop-checker,
  lint) + backend-executor. Оркестратор Hermes работает на ХОСТЕ (не в контейнере).

1. ВЕРСИЯ. В контейнерах Holix **0.1.19**. На PyPI последняя — **0.1.21**.
   Образ собран 13 дней назад из `~/ai-studio/holix/backend/Dockerfile`:
   `FROM python:3.12-slim` + `pipx install "Holix[all]"` (БЕЗ пина версии → при
   сборке подтянулась 0.1.19). CMD в образе `holix gateway start` (без -f),
   compose переопределяет на `--foreground` (+ наша обёртка настройки DeepSeek).

2. GATEWAY. Внутри контейнера работает Holix API Gateway v0.2.0:
   - `GET /` → require_auth=true, host_profile=default;
   - `GET /health`, `/v1/health` → ok (публичные);
   - `GET /v1/models` → 401 «API key required» (auth включён, но hx_-ключа НЕТ);
   - bind **127.0.0.1:8000** — только loopback ВНУТРИ контейнера. Другие
     контейнеры и хост НЕ достучатся. Портов наружу (`ports:`) у holix НЕТ.
   ИТОГ: Hermes-совместимый API технически есть, но де-факто недоступен никому.

3. АРТЕФАКТ. У backend-executor заданы `HERMES_DASHBOARD_ENABLED/HOST/PORT=8022` —
   это переменные Hermes-agent, Holix их не читает (порт 8022 пуст, gateway на 8000).
   Вводит в заблуждение → вычистить.

4. КОНФИГИ. `~/studio/examples/configs/holix-*.yaml` (7 шт.) — КАСТОМНЫЙ studio-формат
   (profile/model/tools/network), Holix его как нативный конфиг НЕ читает. Реальная
   конфигурация Holix идёт через env (провайдер DeepSeek — через нашу compose-обёртку
   `holix models add deepseek`, коммит 208f689) и нативный `/root/.holix`.

5. СОВМЕСТИМОСТЬ С HERMES (по GATEWAY_API.md — «полная» по матрице):
   /v1/chat/completions, /v1/responses, /v1/runs; /v1/models, /v1/capabilities,
   /v1/skills, /v1/toolsets; /api/sessions; /api/jobs; multimodal; SSE tool progress.
   Заголовки-алиасы X-Hermes-Profile / X-Hermes-Session-Id / X-Hermes-Session-Key.
   Чтобы это заработало реально, нужны: сетевой доступ к gateway (bind 0.0.0.0 +
   публикация порта) и hx_-ключ. Управляющие env (docs/en/GATEWAY.md):
   HOLIX_GATEWAY_HOST (def 127.0.0.1), HOLIX_GATEWAY_PORT (def 8000),
   HOLIX_REQUIRE_AUTH (def true), HOLIX_ENV=production (форсит auth + требует pepper),
   HOLIX_API_KEY_PEPPER (обяз. в production). Ключи hx_ — через POST /admin/api-keys
   (bootstrap: разово HOLIX_REQUIRE_AUTH=false). Ключи профиля hp_ — `holix profile key init`.

ЦЕЛИ
  A. Обновить Holix 0.1.19 → 0.1.21 воспроизводимо (пин версии) на всех 8 воркерах.
  B. Довести Hermes-совместимость до рабочей: gateway доступен по сети, auth с hx_,
     Hermes на хосте общается с воркерами через OpenAI/Hermes-совместимый /v1.
  C. Всё чисто: убрать артефакты, doctor-проверка, документация, коммит.

═══════════════════════════════════════════════════════════
ИТЕРАЦИИ
═══════════════════════════════════════════════════════════

ИТЕРАЦИЯ 0 — Подготовка и страховка (обратимость)
  Действия:
    - git: ветка feature/holix-upgrade в репозитории Ai-Studio-Code.
    - Бэкап текущего образа: `docker image save ai-studio-holix-backend:latest`
      → `~/studio/backups/holix-image-0.1.19-<дата>.tar` (для мгновенного отката).
    - Бэкап docker-compose.yml и examples/configs/ (в backups/).
    - Дамп БД hermes_brain (pre_*.sql) — на случай, если что-то заденет мозг.
    - Зафиксировать baseline: версии, /health всех воркеров.
  Проверка: файлы бэкапов существуют (image tar, compose, dump); baseline записан.
  Откат всей работы: `docker load` из tar + вернуть compose из бэкапа + recreate.

ИТЕРАЦИЯ 1 — Обновление образа Holix (0.1.19 → 0.1.21), воспроизводимо
  Действия:
    - Правка `~/ai-studio/holix/backend/Dockerfile`: пин
      `pipx install "Holix[all]==0.1.21"` (воспроизводимость, а не «latest»).
    - Пересборка образа, теги `ai-studio-holix-backend:0.1.21` и `:latest`.
  Проверка: `docker run --rm ai-studio-holix-backend:latest holix version` → 0.1.21.
  (Контейнеры ещё НЕ трогаем — работают на старом слое до пересоздания.)

ИТЕРАЦИЯ 2 — Пилот: пересоздать ТОЛЬКО holix-coordinator на новом образе
  Действия: `docker compose up -d --no-deps --force-recreate holix-coordinator`.
  Проверка:
    - status=running, RestartCount=0;
    - `holix version` в контейнере → 0.1.21;
    - gateway `GET /health` → 200; `holix status` → модель deepseek-v4-flash
      (наша startup-обёртка снова настроила DeepSeek после обнуления /root/.holix).
  Откат: вернуть :latest на старый образ (`docker tag` из :0.1.19) + recreate.

ИТЕРАЦИЯ 3 — Раскатка обновления на остальные 7 воркеров
  Действия: `docker compose up -d --no-deps --force-recreate <7 сервисов>`.
  Проверка (batch): все 8 → running/restart=0, holix version 0.1.21,
  gateway /health 200 у каждого.

ИТЕРАЦИЯ 4 — Hermes-совместимость, часть 1: сетевой доступ к gateway
  Действия (правка docker-compose.yml, по docs/en/GATEWAY.md):
    - Добавить env всем holix-сервисам: `HOLIX_GATEWAY_HOST=0.0.0.0`,
      `HOLIX_GATEWAY_PORT=8000` (env — высший приоритет в слоях конфигурации Holix).
    - Опубликовать порт gateway у coordinator на хост: `127.0.0.1:8000:8000`
      (безопасно — только loopback хоста; именно к нему подключится Hermes).
      Остальные воркеры остаются доступны по DNS внутри docker-сети.
    - Убрать артефактные `HERMES_DASHBOARD_*` (заменяются корректными HOLIX_*).
  Проверка:
    - из другого контейнера `curl http://holix-coordinator:8000/health` → 200;
    - с хоста `curl http://127.0.0.1:8000/health` → 200.
  Откат: убрать ports/env, recreate.

ИТЕРАЦИЯ 5 — Hermes-совместимость, часть 2: auth (admin hx_ + pepper)
  Действия (по docs/en/GATEWAY.md bootstrap-флоу):
    - Сгенерировать и задать `HOLIX_API_KEY_PEPPER` (в ~/studio/.env; пепперим
      ДО создания ключей — иначе ключ не совпадёт по хэшу).
    - Разово поднять coordinator с `HOLIX_REQUIRE_AUTH=false`, создать admin-ключ:
      `POST /admin/api-keys?name=hermes&permissions=read,write,execute,admin`.
    - Сохранить полученный `hx_…` в ~/studio/.env И в ~/.hermes/.env (для Hermes),
      вернуть `HOLIX_REQUIRE_AUTH=true`, recreate.
  Проверка:
    - `GET /v1/models` с `Authorization: Bearer hx_…` → 200 (список профилей);
    - без ключа → 401. Секрет не светим (sha256/маскирование в выводах).
  Откат: удалить ключ (DELETE /admin/api-keys/{id}), снять pepper/env.

ИТЕРАЦИЯ 6 — Hermes-совместимость, часть 3: интеграция Hermes ↔ Holix (E2E)
  Действия:
    - Настроить Hermes (хост) на использование воркеров Holix как OpenAI-совместимого
      провайдера: base_url http://127.0.0.1:8000/v1, Bearer hx_…, model=<имя профиля>
      (напр. "default"/"coordinator"), при необходимости заголовки X-Hermes-Profile /
      X-Hermes-Session-Id. Способ подключения согласуем (custom provider в конфиге
      Hermes ИЛИ отдельный клиент) — предложу вариант в начале итерации.
    - Прогнать ключевые пункты матрицы совместимости:
      `/v1/models`, `/v1/capabilities`, `/v1/chat/completions` (обычный и stream/SSE),
      `/api/sessions` (создать сессию + чат), `/api/jobs` (список).
  Проверка: E2E-запрос `/v1/chat/completions` к воркеру возвращает ответ DeepSeek;
  capabilities отдаёт Hermes-флаги; SSE-стрим приходит.

ИТЕРАЦИЯ 7 — Финализация и чистота
  Действия:
    - `holix doctor` на воркере (диагностика конфигурации), исправить замечания.
    - Причесать 7 studio-yaml (привести model к deepseek-v4-flash / пометить, что
      не читается Holix) — по согласованию, низкий приоритет.
    - Обновить SESSION-HANDOFF.md (актуальное состояние), пометить PLAN как выполненный.
    - Обновить навык deploy-studio (обновление образа + hermes-compat рецепт).
    - Коммит(ы) в feature/holix-upgrade → merge/PR в main, push.
    - Финальный ad-hoc verification-скрипт: 8×0.1.21, gateway доступен+authed,
      DeepSeek работает, hermes-эндпоинты отвечают.
  Проверка: verification-скрипт «ALL CHECKS PASSED»; remote-SHA совпадает.

═══════════════════════════════════════════════════════════
РИСКИ И ПРАВИЛА
═══════════════════════════════════════════════════════════
  - Не трогаем БД/мозг и чужие контейнеры без надобности; есть дамп pre_*.
  - Образ :latest общий для 8 сервисов → сначала пилот (1 воркер), потом раскатка.
  - Секреты (hx_, pepper, ключи) — только в .env, в командной строке не светим,
    в выводах маскируем; в git не коммитим (.env в gitignore).
  - Каждая итерация завершается отчётом (✅ что сделано, коммит) и ОСТАНОВКОЙ —
    следующая только после вашего «продолжай».
  - Полный откат: образ из tar (Итерация 0), compose из бэкапа.

СТАТУС: [ ] 0  [ ] 1  [ ] 2  [ ] 3  [ ] 4  [ ] 5  [ ] 6  [ ] 7   (ожидает утверждения)
