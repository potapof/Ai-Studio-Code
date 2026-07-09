# Session Handoff — 9 июля 2026

## Состояние платформы (после объединения в один проект)
- Docker-проект: **studio-code** (единый, объединил бывшие ai-studio + studio)
- 14 контейнеров Up под одним проектом:
  - postgres-db (nocodb-postgres-db, healthy), nocodb-web-ui, openhands-outsourcer, holix-backend-executor
  - 7 holix: coordinator, archivist, backend-lead, frontend-lead, qa, loop-checker, lint
  - egress-squid, portainer, syncthing
- Сеть: ai-studio_ai_studio_network (жёсткое имя через `networks: name:`) — под проектом studio-code
- PostgreSQL: ✅ hermes_brain (skills=20, knowledge_base=25, standards_library=3)
- NocoDB :8080 ✅ · Portainer :9000 ✅ · Syncthing :8384 ✅

## Что сделано в этой сессии
1. Установлен uv/uvx (0.11.28) в ~/.local/bin
2. **MCP к PostgreSQL** — настроен надёжно и безопасно:
   - Docker-обёртка crystaldba/postgres-mcp в сети ai-studio_ai_studio_network
   - Пароль только в ~/.hermes/.env как ${HERMES_POSTGRES_URL}; в config.yaml/args пароля НЕТ
   - --access-mode=restricted (только чтение). 9 инструментов mcp_postgres_*
3. **Устранены restart-петли** у всех 8 holix/executor (было ~8000 перезапусков каждый):
   причина — `holix gateway start` уходит в фон → контейнер «выходит». Фикс: `--foreground`
4. Удалён битый контейнер openhands (exit 126, /app/entrypoint.sh permission denied)
5. **Объединены два compose-проекта в один** (studio-code):
   - Единый ~/studio/docker-compose.yml (14 сервисов), реальные пути данных ai-studio
   - hermes-контейнер убран (Hermes на хосте), исправлен сломанный DEEPSEEK_API_KEY
   - Данные мозга сохранены 1:1 (проверено дампом до/после)

## Ключевые файлы
```
~/studio/docker-compose.yml            — единый стек (проект studio-code)
~/studio/.env                          — секреты (НЕ в Git)
~/.hermes/.env                         — HERMES_POSTGRES_URL для MCP
~/.hermes/config.yaml                  — блок mcp_servers.postgres
~/studio/backups/                      — дампы БД (full_*, pre_switch_*)
~/ai-studio/docker-compose.yml.deprecated_20260709 — старый файл (обратимо)
~/ai-studio/data/postgres              — физические данные мозга
```

## Откат объединения (если понадобится)
```bash
cd ~/studio && docker compose down
mv ~/ai-studio/docker-compose.yml.deprecated_20260709 ~/ai-studio/docker-compose.yml
cp ~/studio/docker-compose.split.bak.20260709_142350 ~/studio/docker-compose.yml
cd ~/ai-studio && docker compose up -d
cd ~/studio && docker compose -p studio up -d
# при потере данных: восстановить из ~/studio/backups/full_*.sql
```

## Быстрый старт новой сессии
```bash
cd ~/studio
docker compose ps                      # 14 контейнеров studio-code
docker exec nocodb-postgres-db pg_isready
hermes mcp test postgres               # проверка MCP
```

## Что осталось (не критично)
- Apache AGE не установлен (только vector/pg_trgm/pgcrypto) — графовые функции недоступны; фикс = свой образ + пересоздание БД
- hermes-ceo (ghcr.io/nousresearch/hermes-agent) образ недоступен — Hermes работает на хосте, контейнер не нужен
- Секреты в .env стоит ротировать (ключ засветился в старом compose)
- MCP docker-обёртка иногда оставляет осиротевшие контейнеры при жёстком завершении — периодически чистить
