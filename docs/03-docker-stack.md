# Docker Compose стек 2.0

> Содержание: полная композиция сервисов, сети, тома, переменные окружения, healthchecks, resource limits. Обновлённый compose с PostgreSQL+pgvector+Apache AGE, прямым postgres MCP, egress-proxy, SOA.

## 1. Обзор стека 2.0

«Студия программирования» версии 2.0 развёртывается как **единый Docker Compose стек** из 15 контейнеров в общей сети `studio-net` (172.20.0.0/16). Все сервисы запускаются одной командой `docker compose up -d` и описываются в одном `docker-compose.yml`. Принципиальное отличие от v1.0: NocoDB больше не является «мозгом» системы — он понижен до «приборной панели» (только UI для людей), а роль мозга перешла к PostgreSQL 16 с расширениями pgvector и Apache AGE, доступ к которому осуществляется через официальный `@modelcontextprotocol/server-postgres`.

Виртуализация в три уровня (Windows → VirtualBox → Docker) сохранена как осознанный выбор: Windows-хост обеспечивает удобство управления, VirtualBox предоставляет нативный Linux для Docker, а Docker даёт изоляцию между сервисами. Все Docker volumes используют bind mounts на ext4-файловой системе внутри VM — никаких монтирований в общую папку vboxsf, как в v1.0 (где `noco.db` лежал в `/home/potapof/ai-studio/data/nocodb/` и вызывал `Permission denied` и `attempt to write a readonly database`).

## 2. Список сервисов 2.0

| Сервис | Контейнер | IP | Порт(ы) | Роль |
|--------|-----------|----|---------|------|
| `postgres-db` | `nocodb-postgres-db` | 172.20.0.30 | 5432 | PostgreSQL 16 + pgvector + Apache AGE (мозг) |
| `nocodb-app` | `nocodb-web-ui` | 172.20.0.20 | 8080 | NocoDB (приборная панель) |
| `hermes` | `hermes` | 172.20.0.10 | 8082, 8081 | Hermes Agent (оркестратор + MCP-сервер) |
| `holix-coordinator` | `holix-coordinator` | 172.20.0.41 | — | Шлюз к OpenHands |
| `holix-archivist` | `holix-archivist` | 172.20.0.42 | — | Управление skills + embeddings |
| `holix-backend-lead` | `holix-backend-lead` | 172.20.0.43 | — | Team Lead бэкенда |
| `holix-frontend-lead` | `holix-frontend-lead` | 172.20.0.44 | — | Team Lead фронтенда |
| `holix-qa` | `holix-qa` | 172.20.0.47 | — | Тесты, линтеры, SAST |
| `holix-loop-checker` | `holix-loop-checker` | 172.20.0.48 | — | Объективный проверяющий для loop |
| `holix-lint` | `holix-lint` | 172.20.0.49 | — | Линтер для lint-and-fix loop |
| `openhands` | `openhands` | 172.20.0.60 | — | Внешний подрядчик (Maker) |
| `egress-proxy` | `egress-squid` | 172.20.0.100 | 3128 | Egress firewall с whitelist |
| `portainer` | `portainer` | 172.20.0.70 | 9000 | Мониторинг Docker |
| `syncthing` | `syncthing` | 172.20.0.80 | 8384 | P2P синхронизация с Windows |

Итого 14 контейнеров. RAM: ~1 ГБ на Holix-агента × 7 = 7 ГБ, плюс 6 ГБ PostgreSQL (с AGE), 1 ГБ NocoDB, 0.5 ГБ Hermes, 1 ГБ OpenHands, 0.5 ГБ Portainer, 0.3 ГБ Syncthing, 0.2 ГБ egress. Итого ~16-18 ГБ RAM.

## 3. Полный docker-compose.yml

Полный файл — в [examples/docker-compose.yml](../examples/docker-compose.yml). Ниже — ключевые фрагменты.

### 3.1. PostgreSQL + pgvector + Apache AGE (мозг)

```yaml
services:
  postgres-db:
    image: pgvector/pgvector:pg16
    container_name: nocodb-postgres-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-hermes_brain}
      POSTGRES_USER: ${POSTGRES_USER:-nocodb_user}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
      POSTGRES_INITDB_ARGS: "--encoding=UTF-8 --locale=C"
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./examples/sql:/docker-entrypoint-initdb.d:ro
    networks:
      studio-net:
        ipv4_address: 172.20.0.30
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    deploy:
      resources:
        limits:
          memory: 6G  # больше RAM для HNSW-индексов и AGE
          cpus: '4'
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
```

**Ключевые особенности v2.0:**

1. Образ `pgvector/pgvector:pg16` — официальный PostgreSQL 16 с предустановленным pgvector. Apache AGE устанавливается через `CREATE EXTENSION age` после первого старта (см. [docs/04-convergent-database.md](04-convergent-database.md)).
2. База данных `hermes_brain` — отдельная БД для мозга (отделена от метаданных NocoDB).
3. `PGDATA: /var/lib/postgresql/data/pgdata` — поддиректория для данных, чтобы можно было монтировать дополнительные расширения.
4. Resource limit повышен до 6 ГБ RAM — Apache AGE и pgvector HNSW-индексы требуют памяти.
5. SQL-скрипты из `./examples/sql` выполняются автоматически при первом старте.

### 3.2. NocoDB (приборная панель, не мозг)

```yaml
  nocodb-app:
    image: nocodb/nocodb:latest
    container_name: nocodb-web-ui
    restart: unless-stopped
    depends_on:
      postgres-db:
        condition: service_healthy
    environment:
      NC_DB: "pg://postgres-db:5432/hermes_brain"  # та же БД, что у Hermes
      NC_DB_USER: ${POSTGRES_USER}
      NC_DB_PASSWORD: ${POSTGRES_PASSWORD}
      NC_AUTH_JWT_SECRET: ${NC_AUTH_JWT_SECRET:?NC_AUTH_JWT_SECRET is required}
      NC_PUBLIC_URL: "http://localhost:8080"
      NC_DISABLE_TELEMETRY: "true"
      NC_TRY: "false"
    ports:
      - "8080:8080"
    volumes:
      - nocodb_data:/usr/app/data
    networks:
      studio-net:
        ipv4_address: 172.20.0.20
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8080/api/v1/health"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 60s
    deploy:
      resources:
        limits:
          memory: 1G
          cpus: '1'
```

**Ключевое отличие от v1.0:** NocoDB подключается к той же БД `hermes_brain`, что и Hermes. Это обеспечивает **единую точку истины**: изменения менеджера через Kanban мгновенно видны агенту, и наоборот — результаты анализа агента автоматически появляются на дашборде. Никакой синхронизации между разными базами не требуется.

### 3.3. Hermes Agent

```yaml
  hermes:
    image: ghcr.io/nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    depends_on:
      nocodb-app:
        condition: service_healthy
      postgres-db:
        condition: service_healthy
      egress-proxy:
        condition: service_started
    env_file: .env
    environment:
      HERMES_CONFIG_PATH: /config/hermes-config.yaml
      HERMES_POSTGRES_URL: "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres-db:5432/hermes_brain"
      LLM_API_KEY: ${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY is required}
      LLM_MODEL: deepseek-chat
      LLM_BASE_URL: https://api.deepseek.com
      HTTP_PROXY: http://egress-proxy:3128
      HTTPS_PROXY: http://egress-proxy:3128
      NO_PROXY: localhost,postgres-db,nocodb-app,holix-*,openhands
      TZ: ${TZ:-Europe/Moscow}
    ports:
      - "8082:8080"  # Hermes HTTP API + MCP-сервер для IDE
      - "8081:8081"  # Webhook endpoints
    volumes:
      - hermes_data:/config
      - ./examples/configs/hermes-config.yaml:/config/hermes-config.yaml:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - /tmp/holix-worktrees:/worktrees
    networks:
      studio-net:
        ipv4_address: 172.20.0.10
    healthcheck:
      test: ["CMD-SHELL", "hermes healthcheck || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    deploy:
      resources:
        limits:
          memory: 1G
          cpus: '1'
```

**Ключевые особенности v2.0:**

1. Образ от Nous Research (`ghcr.io/nousresearch/hermes-agent:latest`), а не от стороннего форка.
2. `HERMES_POSTGRES_URL` — URL подключения к мозгу. Используется нативным Postgres Memory Provider Hermes и для `@modelcontextprotocol/server-postgres`.
3. `HTTP_PROXY`/`HTTPS_PROXY` — весь исходящий трафик Hermes (LLM API, SOA, GitHub) проходит через egress-proxy с whitelist.
4. Проброс Docker socket — для `delegate_task` (Hermes вызывает `docker exec` к Holix-контейнерам).
5. Порт 8082 → 8080 — Hermes работает как HTTP API + MCP-сервер (для IDE типа Cursor/Claude Desktop).
6. Порт 8081 — webhook endpoints (GitHub Actions, NocoDB webhooks).

### 3.4. Holix-агенты

Каждый Holix-агент — отдельный контейнер с workspace jail. Пример для `holix-archivist` (управляет библиотекой навыков и генерацией эмбеддингов):

```yaml
  holix-archivist:
    image: ghcr.io/holix/agent:latest
    container_name: holix-archivist
    restart: unless-stopped
    depends_on:
      - hermes
      - postgres-db
    env_file: .env
    environment:
      HOLIX_PROFILE: archivist
      HOLIX_CONFIG_PATH: /config/config.yaml
      HERMES_POSTGRES_URL: "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres-db:5432/hermes_brain"
      LLM_API_KEY: ${DEEPSEEK_API_KEY}
      LLM_MODEL: deepseek-chat
      LLM_TEMPERATURE: "0.3"
      TZ: ${TZ:-Europe/Moscow}
    volumes:
      - ./examples/configs/holix-archivist.yaml:/config/config.yaml:ro
      - holix_data/archivist:/workspace
      - hermes_data:/config/hermes-shared:ro  # доступ к skills только для чтения
    networks:
      studio-net:
        ipv4_address: 172.20.0.42
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - DAC_OVERRIDE
    tmpfs:
      - /tmp:size=512M  # больше tmpfs для модели эмбеддингов
    deploy:
      resources:
        limits:
          memory: 2G  # больше RAM для all-MiniLM-L6-v2
          cpus: '1'
    healthcheck:
      test: ["CMD-SHELL", "holix healthcheck || exit 1"]
      interval: 60s
      timeout: 10s
      retries: 3
```

**Ключевые особенности v2.0:**

1. `HERMES_POSTGRES_URL` — Архивариус подключается к мозгу напрямую через postgres MCP (read_write, но DELETE запрещён на уровне SQL-роли).
2. `tmpfs: /tmp:size=512M` — увеличен для кэширования модели эмбеддингов `all-MiniLM-L6-v2` (~80 МБ) и промежуточных тензоров.
3. `memory: 2G` — больше RAM, чем другим Holix-агентам, из-за работы с моделями эмбеддингов.
4. `hermes_data:/config/hermes-shared:ro` — Архивариус имеет доступ на чтение к skills Hermes для синхронизации с `public.skills`.

### 3.5. OpenHands

```yaml
  openhands:
    image: openhands/openhands:latest
    container_name: openhands
    restart: unless-stopped
    depends_on:
      - hermes
      - egress-proxy
    env_file: .env
    environment:
      LLM_API_KEY: ${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY is required}
      LLM_MODEL: deepseek-chat
      LLM_BASE_URL: https://api.deepseek.com
      WORKSPACE_BASE: /workspace
      SANDBOX_TYPE: rh
      HTTP_PROXY: http://egress-proxy:3128
      HTTPS_PROXY: http://egress-proxy:3128
      NO_PROXY: localhost,postgres-db,nocodb-app,hermes,holix-*
      TZ: ${TZ:-Europe/Moscow}
    volumes:
      - openhands_data:/workspace
      - ./examples/configs/openhands-config.toml:/workspace/.openhands/config.toml:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - /tmp/holix-worktrees:/worktrees
    networks:
      studio-net:
        ipv4_address: 172.20.0.60
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - SYS_ADMIN
      - NET_ADMIN
    deploy:
      resources:
        limits:
          memory: 2G
          cpus: '2'
```

**Ключевая особенность v2.0:** В конфиге `openhands-config.toml` указано `mcp.servers = ["hermes-brain-readonly"]` — OpenHands может только **читать** из мозга (получать контекст), но не писать. Запись результатов работы выполняется через Holix Coordinator → Архивариус → `public.handoff_documents`. Это предотвращает прямой доступ OpenHands к коллективной памяти и снижает риск prompt injection-атак.

### 3.6. Egress proxy (Squid с whitelist)

```yaml
  egress-proxy:
    image: ubuntu/squid:latest
    container_name: egress-squid
    restart: unless-stopped
    volumes:
      - ./examples/configs/squid.conf:/etc/squid/squid.conf:ro
      - ./examples/configs/squid-whitelist.txt:/etc/squid/whitelist.txt:ro
      - egress_logs:/var/log/squid
    networks:
      studio-net:
        ipv4_address: 172.20.0.100
    ports:
      - "3128:3128"
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: '0.5'
```

Whitelist в v2.0 расширен — добавлены домены SOA:

```
# LLM API
api.deepseek.com
api.openai.com
api.anthropic.com

# Stack Overflow for Agents
mcp.stackoverflow.com
stackoverflow.com
api.stackexchange.com

# GitHub
github.com
api.github.com
*.githubusercontent.com

# Уведомления
hooks.slack.com
api.telegram.org

# Sentry
sentry.io
*.ingest.sentry.io

# Пакетные репозитории
pypi.org
*.pypi.org
files.pythonhosted.org
registry.npmjs.org
*.npmjs.org
```

## 4. Сеть и тома

### 4.1. Docker network

```yaml
networks:
  studio-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
          ip_range: 172.20.0.0/24
          gateway: 172.20.0.1
    driver_opts:
      com.docker.network.bridge.name: br-studio
      com.docker.network.bridge.enable_icc: "true"
      com.docker.network.bridge.enable_ip_masquerade: "true"
```

Все контейнеры — в одной сети с фиксированными IP. Это упрощает отладку и настройку egress-правил.

### 4.2. Docker volumes

```yaml
volumes:
  postgres_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /var/lib/studio/postgres  # ext4 внутри VM, НЕ vboxsf!
  
  nocodb_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /var/lib/studio/nocodb
  
  hermes_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/studio/.hermes
  
  holix_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/studio/.holix
  
  openhands_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/studio/.openhands
  
  portainer_data:
    driver: local
  
  syncthing_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/studio/.config/syncthing
  
  egress_logs:
    driver: local
```

Используются bind mounts на ext4-файловой системе внутри VM. Это критически важно: попытка разместить `postgres_data` в общей папке vboxsf (как в v1.0) гарантированно приводит к повреждению данных из-за отсутствия POSIX-блокировок.

## 5. Resource limits 2.0

| Сервис | RAM | CPU | Обоснование |
|--------|-----|-----|-------------|
| postgres-db | 6 ГБ | 4 cores | HNSW-индексы pgvector + Apache AGE + реляционные |
| nocodb-app | 1 ГБ | 1 core | Node.js UI |
| hermes | 1 ГБ | 1 core | LLM API + MCP-клиент/сервер |
| holix-archivist | 2 ГБ | 1 core | Модель эмбеддингов all-MiniLM-L6-v2 |
| holix-coordinator | 1 ГБ | 1 core | Формирование контекста |
| holix-backend-lead | 1 ГБ | 1 core | Team Lead |
| holix-frontend-lead | 1 ГБ | 1 core | Team Lead |
| holix-qa | 2 ГБ | 2 cores | pytest + semgrep + trufflehog |
| holix-loop-checker | 1 ГБ | 1 core | Тесты для loop |
| holix-lint | 512 МБ | 0.5 core | Лёгкие линтеры |
| openhands | 2 ГБ | 2 cores | Песочница + LLM API |
| egress-proxy | 256 МБ | 0.5 core | Squid |
| portainer | 256 МБ | 0.25 core | Веб-UI |
| syncthing | 256 МБ | 0.25 core | P2P |
| **Итого** | **~21 ГБ** | **~17 cores** | помещается в 32 ГБ VM |

## 6. Healthchecks и зависимости

```mermaid
flowchart LR
    PG[postgres-db<br/>pg_isready] --> NOCODB[nocodb-app<br/>HTTP /api/v1/health]
    PG --> HERMES[hermes<br/>hermes healthcheck]
    EGRESS[egress-proxy] --> HERMES
    HERMES --> HC[holix-coordinator]
    HERMES --> HA[holix-archivist]
    HERMES --> HBL[holix-backend-lead]
    HERMES --> HFL[holix-frontend-lead]
    HERMES --> HQA[holix-qa]
    HERMES --> HLC[holix-loop-checker]
    HERMES --> HLF[holix-lint]
    HC --> OH[openhands]
    EGRESS --> OH
    
    style PG fill:#E0E7FF,stroke:#4F46E5,stroke-width:2px
    style HERMES fill:#DBEAFE,stroke:#2563EB,stroke-width:2px
    style OH fill:#FCE7F3,stroke:#DB2777
```

`start_period` даёт сервисам время на инициализацию: PostgreSQL — 30 секунд, NocoDB — 60 секунд, Hermes — 60 секунд.

## 7. Управление стеком

### 7.1. Базовые команды

```bash
# Запуск
docker compose up -d

# Статус
docker compose ps

# Логи (все)
docker compose logs -f --tail=100

# Логи конкретного сервиса
docker compose logs -f hermes

# Перезапуск одного сервиса
docker compose restart hermes

# Обновление образов
docker compose pull
docker compose up -d  # пересоздаст контейнеры с новыми образами
```

### 7.2. Инициализация после первого запуска

```bash
# 1. Установка расширений PostgreSQL (pgvector, AGE)
./scripts/06-init-convergent-db.sh

# 2. Подключение MCP-серверов к Hermes
./scripts/07-bootstrap-hermes-mcp.sh

# 3. Миграция с v1.0 (если применимо)
./scripts/08-migrate-nocodb-to-postgres.sh
```

### 7.3. Backup и restore

```bash
./scripts/backup.sh
./scripts/restore.sh 2026-07-05
```

## 8. Что дальше

- **Конвергентная база данных** — [docs/04-convergent-database.md](04-convergent-database.md)
- **NocoDB как приборная панель** — [docs/05-nocodb-dashboard.md](05-nocodb-dashboard.md)
- **Эталонный API/MCP референс** — [docs/06-api-mcp-reference.md](06-api-mcp-reference.md)
