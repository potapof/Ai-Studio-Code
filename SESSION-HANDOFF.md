# SESSION HANDOFF — Студия программирования

Обновлено: 9 июля 2026 (конец сессии).
Читать первым в новой сессии. Быстрый старт и откаты — в конце.

═══════════════════════════════════════════════════════════
СОСТОЯНИЕ ПЛАТФОРМЫ (актуально)
═══════════════════════════════════════════════════════════
- ЕДИНЫЙ docker-compose проект: **studio-code** → `~/studio/docker-compose.yml`
- 14 контейнеров, все Up, restart-петель нет:
  - nocodb-postgres-db (healthy), nocodb-web-ui, openhands-outsourcer, holix-backend-executor
  - 7 holix: coordinator, archivist, backend-lead, frontend-lead, qa, loop-checker, lint
  - egress-squid, portainer, syncthing
- Сеть: `ai-studio_ai_studio_network` (жёсткое имя через `networks: name:`), под проектом studio-code
- БД: образ `studio-postgres:pg16-age-vector` (PG16.14 bookworm + pgvector 0.8.3 + Apache AGE 1.5.0)
  - Данные (bind): `/home/potapof/ai-studio/data/postgres`
  - hermes_brain: skills=20, knowledge_base=25, standards_library=3
  - Графы AGE: code_graph, task_graph (пустые, готовы к наполнению)
- Веб: NocoDB :8080 · Portainer :9000 · Syncthing :8384
- LLM: провайдер deepseek, модель воркеров **deepseek-v4-flash** (7 holix + backend-executor + openhands)
- MCP postgres: Docker-обёртка crystaldba/postgres-mcp (restricted), URL в ~/.hermes/.env; 9 инструментов mcp_postgres_*

═══════════════════════════════════════════════════════════
СДЕЛАНО В ЭТОЙ СЕССИИ
═══════════════════════════════════════════════════════════
1. Установлен uv/uvx 0.11.28 (~/.local/bin)
2. MCP к PostgreSQL — надёжно/безопасно (Docker-обёртка в сети, пароль только в env, restricted)
3. Устранены restart-петли ВСЕХ 8 holix/executor (было ~8000 перезапусков): фикс `holix gateway start --foreground`
4. Удалён битый контейнер openhands (exit 126)
5. Объединены 2 проекта (ai-studio + studio) → один studio-code; данные мозга сохранены 1:1
6. Секреты: аудит (.env в gitignore, в историю не попадали), зачистка плейнтекст DeepSeek-ключа с диска
7. Apache AGE установлен без egress к debian (multi-stage образ: age.so из apache/age:release_PG16_1.5.0 → в pgvector). Dockerfile: `~/studio/docker/postgres-age/`
8. Переписан `examples/sql/04-code-graph.sql` под AGE 1.5.0 (5 функций графа работают)
9. Ротация DeepSeek-ключа: контейнеры (9 шт) переведены на новый ключ
10. openhands посажен на DeepSeek (LLM_MODEL/LLM_BASE_URL добавлены — не было)
11. Модель воркеров → deepseek-v4-flash

Коммиты (Ai-Studio-Code, main): 5cd18df (объединение) → 67b2223 (AGE) → 1339eff (fix 04) → d169c4c (openhands→DeepSeek) → b5e3493 (flash). Все запушены.

═══════════════════════════════════════════════════════════
НАДО СДЕЛАТЬ (для новой сессии / пользователя)
═══════════════════════════════════════════════════════════
ПРИОРИТЕТ 1 — завершить ротацию ключа (осталось за пользователем):
- [ ] Перезапустить Hermes на хосте → возьмёт новый DeepSeek-ключ из ~/.hermes/.env (это и есть переход в новую сессию)
- [ ] ТОЛЬКО ПОСЛЕ этого — отозвать СТАРЫЙ ключ на platform.deepseek.com
  ⚠️ Не отзывать старый ключ до перезапуска Hermes.

ПРИОРИТЕТ 2 — проверить модель:
- [ ] Дать первую реальную задачу holix/openhands. Если провайдер вернёт 400 на «deepseek-v4-flash» — имя модели неверное, поправить LLM_MODEL в ~/studio/docker-compose.yml (7 holix + backend-executor + openhands) и `docker compose up -d`.

ОПЦИОНАЛЬНО (по желанию):
- [ ] sync_code_graph — сейчас заглушка; реализовать Python-парсер AST для наполнения code_graph реальными зависимостями репозитория
- [ ] Ротация прочих секретов (GITHUB_TOKEN, POSTGRES_PASSWORD и др.) — по той же схеме
- [ ] Наполнить графы code_graph/task_graph реальными данными (функции add_code_node/add_code_edge готовы)

═══════════════════════════════════════════════════════════
БЫСТРЫЙ СТАРТ НОВОЙ СЕССИИ
═══════════════════════════════════════════════════════════
```bash
cd ~/studio
docker compose ps                              # 14 контейнеров studio-code
docker exec nocodb-postgres-db pg_isready -U nocodb_user
hermes mcp test postgres                       # MCP + БД
# проверить модель у воркеров:
docker inspect holix-coordinator --format '{{range .Config.Env}}{{println .}}{{end}}' | grep LLM_MODEL
```

Проверка данных мозга + AGE:
```bash
docker exec nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c \
 "SELECT extname,extversion FROM pg_extension WHERE extname IN ('age','vector'); \
  SELECT name FROM ag_catalog.ag_graph;"
```

═══════════════════════════════════════════════════════════
КЛЮЧЕВЫЕ ФАЙЛЫ И БЭКАПЫ
═══════════════════════════════════════════════════════════
```
~/studio/docker-compose.yml              — единый стек (проект studio-code)
~/studio/docker/postgres-age/Dockerfile  — образ PG16+pgvector+AGE
~/studio/examples/sql/04-code-graph.sql  — граф кода (переписан под AGE 1.5.0)
~/studio/.env                            — секреты (gitignore); DEEPSEEK_API_KEY (новый)
~/.hermes/.env                           — DEEPSEEK_API_KEY (новый) + URL для MCP
~/.hermes/config.yaml                    — блок mcp_servers.postgres
~/studio/backups/                        — дампы БД (full_*, pre_*)
~/ai-studio/data/postgres                — физические данные мозга
~/ai-studio/docker-compose.yml.deprecated_20260709 — старый проект (для отката)
Планы: ~/studio/PLAN-UNIFY.md, PLAN-AGE-SECRETS.md, PLAN-FIX-AGE-GRAPH.md
```

Откат объединения (если нужно):
```bash
cd ~/studio && docker compose down
mv ~/ai-studio/docker-compose.yml.deprecated_20260709 ~/ai-studio/docker-compose.yml
cp ~/studio/docker-compose.split.bak.20260709_142350 ~/studio/docker-compose.yml
cd ~/ai-studio && docker compose up -d
cd ~/studio && docker compose -p studio up -d
# при потере данных: восстановить из ~/studio/backups/full_*.sql
```

═══════════════════════════════════════════════════════════
ГРАБЛИ (учтены, см. навык deploy-studio, Проблемы 13–15)
═══════════════════════════════════════════════════════════
- holix: `holix gateway start` уходит в фон → нужен `--foreground`
- AGE ставить только multi-stage (egress режет debian apt); тег apache/age брать bookworm-совместимый (1.5.0, не 1.6.0/trixie)
- AGE 1.5.0 Cypher: нет `[:A|B]` (использовать `[*1..N]`), нет `[x|..]`, `SET += $map`-параметр не работает (инлайн литерал), agtype-строку брать через trim(chr(34))
- docker exec для stdin-heredoc — обязателен флаг `-i`
- MCP docker-обёртка иногда оставляет осиротевшие контейнеры → периодически чистить
