# SESSION-HANDOFF — Итоги PLAN-NEXT-2

Дата: 2026-07-20. Автономный прогон всех 6 итераций.

## Итерация 1 — Архивариус

**Результат:** агент проверен, выявлены блокеры.

**Проблемы:**
- Гейтвей на порту 8000 не возвращает HTTP-ответ (баг Holix)
- MCP postgres через `npx @modelcontextprotocol/server-postgres` не работает — в контейнере нет npx/nodejs
- `NON_INTERACTIVE=true` + `run_terminal_command` требует подтверждения → бесконечный цикл

**Обходной путь (принят):** Hermes пишет в hermes_brain напрямую через свой MCP postgres. Архивариус отложен до фикса Holix.

## Итерация 2 — OpenHands

**Результат:** ✅ интеграция работает.

- API доступен на :3000, эндпоинт: POST /api/conversations/{id}/message
- Агент выполняет задачи: создал fibonacci.py и hello.py
- Написан скрипт: `~/studio/scripts/openhands-delegate.sh`
- Скорость: ~5-10 мин на задачу (DeepSeek)

## Итерация 3 — NocoDB

**Результат:** ✅ приборная панель готова.

- Workspace «Ai Studio» с проектом «AI Studio Knowledge Base»
- PostgreSQL hermes_brain подключён: 47 таблиц
- PostgreSQL studio_db подключён (пустой)
- SQLite-таблицы наполнены: Features (4), Tasks (5), Projects (2)
- docker-compose: добавлен NC_ALLOW_LOCAL_EXTERNAL_DBS=true
- Доступ: http://localhost:8080, potapof@gmail.com / StudioPass2026!

## Итерация 4 — База знаний

**Результат:** инфраструктура готова, данные не сгенерированы.

- pgvector 0.8.3 установлен и работает
- HNSW-индексы созданы (skills, handoff_documents)
- Эмбеддинги НЕ сгенерированы — архивариус не запускал sentence-transformers
- 20 навыков, 3 handoff-документа, 25 записей knowledge_base

**Что нужно:** запустить генерацию эмбеддингов для skills и handoff_documents

## Итерация 5 — Интеграционный прогон

**Результат:** цепочка частично работает.

- ✅ NocoDB → чтение задачи
- ❌ Holix delegation (non-interactive блокирует инструменты)
- ✅ Запись в PostgreSQL (handoff_documents)
- ✅ Обновление статуса в NocoDB

**Корень проблемы:** все Holix-воркеры (coordinator, archivist, python-dev, etc.) не могут выполнять задачи с инструментами в режиме NON_INTERACTIVE=true. Текстовые ответы работают.

## Итерация 6 — Хозяйственное

- ✅ openhands-delegate.sh написан
- ✅ docker-compose.yml обновлён
- ✅ NocoDB наполнен данными
- ✅ Этот документ написан
- ⬜ Коммит + push в main

## Файлы изменены

- `docker-compose.yml` — добавлен NC_ALLOW_LOCAL_EXTERNAL_DBS
- `scripts/openhands-delegate.sh` — новый скрипт

## Ключевые проблемы (на будущее)

1. **Holix non-interactive bug** — нужен фикс AUTO_ALLOW_THRESHOLD или /v1/permissions/grant
2. **Архивариус** — нужен npx/nodejs в контейнере или замена MCP-транспорта
3. **pgvector эмбеддинги** — нужна генерация (архивариус или отдельный скрипт)
4. **OpenHands скорость** — 5-10 мин на задачу, рассмотреть смену модели
