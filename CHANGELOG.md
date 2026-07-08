# Changelog

Все заметные изменения «Студии программирования» документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версионирование — [Semantic Versioning](https://semver.org/lang/ru/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Интеграция DeLM как второго внешнего подрядчика
- Переход на Firecracker microVM для всех OpenHands задач
- Grafana + Loki + Promtail для централизованного логирования
- Поддержка GitLab CI в CI/CD MCP-сервере
- SLO-метрики и алерты

## [2.0.0] — 2026-07-05

### Кардинальные архитектурные изменения

Версия 2.0 — это **полный рефакторинг** архитектуры на основе опыта эксплуатации v1.0. Практика показала, что использование NocoDB в качестве центрального «мозга» AI-агента создаёт больше проблем, чем решает. NocoDB понижен до «приборной панели» (только UI для людей), а роль мозга перешла к конвергентной БД PostgreSQL с расширениями pgvector и Apache AGE.

### Added
- **Разделение ответственности**: двухуровневая архитектура (Мозг + Приборная панель)
- **Конвергентная БД**: PostgreSQL 16 + pgvector (векторный поиск) + Apache AGE (графовый слой, Cypher) в одном движке `hermes_brain`
- **Прямой postgres MCP**: официальный `@modelcontextprotocol/server-postgres` вместо нестабильного NocoDB MCP
- **Stack Overflow for Agents (SOA)**: новый внешний источник проверенных технических знаний через MCP-сервер `https://mcp.stackoverflow.com` (OAuth 2.1, 100 вызовов/день)
- **Hermes Agent от Nous Research** с Skills System, Memory Providers (нативный Postgres), двунаправленным MCP (клиент + сервер с v0.6.0), командой `/handoff` и контекстным компрессором
- **Handoff-Driven Development (HDD)**: новая парадигма — метод программирования с накоплением опыта. HANDOFF.md по Agent Handoff Protocol (AHP), сохранение в `public.handoff_documents` с векторным эмбеддингом
- **Мультитенантность через схемы PostgreSQL**: `studio_<tenant_id>` с изолированными таблицами и ролями
- **Knowledge Orchestration**: гибридная модель знаний с routing rules (SOA для общих вопросов, PostgreSQL для внутренних)
- **Кэширование SOA-ответов** в `public.soa_cache` с TTL 24 часа для экономии лимита
- **First-invoke approval** (Hermes v0.16+): подтверждение при первом вызове каждого MCP-инструмента
- **Графовый анализ зависимостей кода**: `code_graph` через Apache AGE с Cypher-запросами
- **Новая метрика `tokens_saved_per_handoff_reuse`**: измеряет эффективность HDD
- **postgres MCP security**: forbid_ddl, forbid_truncate, row_limit, parameterized_queries_only

### Changed
- **NocoDB понижен**: больше не «мозг», только приборная панель для человека (Kanban, CRM, формы)
- **NocoDB подключается к `hermes_brain`** (а не к `studio_db`) — единая точка истины
- **PostgreSQL resource limit** увеличен до 6 ГБ RAM (для HNSW-индексов и AGE)
- **Hermes Agent** от Nous Research (`ghcr.io/nousresearch/hermes-agent`) вместо сторонних форков
- **Docker-сеть** расширена whitelist доменов (добавлены `mcp.stackoverflow.com`, `stackoverflow.com`, `api.stackexchange.com`)
- **Resource limits** обновлены с учётом AGE (postgres-db: 6 ГБ, holix-archivist: 2 ГБ)

### Removed
- NocoDB MCP-сервер (заменён на postgres MCP)
- Хостовое монтирование `noco.db` (заменяло на Docker Volume внутри VM)
- Зависимость от JWT-токенов NocoDB (каждые 10 часов) — теперь прямой TCP к PostgreSQL
- Таблица `studio_db` — миграция в `hermes_brain` через `06-migration-from-nocodb.sql`

### Security
- First-invoke approval для всех MCP-серверов
- OAuth 2.1 с PKCE для SOA (вместо статических API-ключей)
- postgres MCP security: forbid_ddl, forbid_truncate, row_limit=10000, parameterized_queries_only
- Разделение прав: OpenHands read_only, Archivist read_write без DELETE, Coordinator/Leads read_only
- Per-tenant роли PostgreSQL с изоляцией на уровне схем
- Фильтрация логов от credentials через `sanitize_for_log()` (IMMUTABLE функция)

### Documentation
- README.md с новой 2-уровневой архитектурой и принципами 2.0
- 15 документов в docs/: architecture, deployment, docker-stack, convergent-database, nocodb-dashboard, api-mcp-reference, hermes-agent, knowledge-orchestration, handoff-driven-development, multitenancy, security-model, loop-engineering, monitoring-metrics, troubleshooting, roadmap
- Mermaid-диаграммы: архитектурные, последовательностные, ER, Gantt, state
- Полный .env.example со всеми переменными 2.0 (включая SOA_CLIENT_ID, HERMES_MCP_SERVER_TOKEN)

### Migration
- `scripts/08-migrate-nocodb-to-postgres.sh` — автоматизированная миграция с v1.0
- `examples/sql/06-migration-from-nocodb.sql` — SQL-скрипт переноса данных
- `docs/15-roadmap.md` — 12-недельный план миграции

## [1.0.0] — 2026-06-26

### Added
- Полная архитектура «Студии программирования» с NocoDB как «мозгом»
- Развёртывание в VirtualBox 7.2 с Linux Mint 22
- Docker Compose стек из 16 контейнеров
- PostgreSQL 16 с расширением pgvector
- NocoDB как центральная база знаний с REST API v2 и MCP-сервером
- 9 профилей Holix-агентов с workspace jail
- Интеграция OpenHands как внешнего подрядчика
- 4 уровня модели безопасности
- Loop Engine в Hermes
- 5 готовых SKILL.md шаблонов
- 5 MCP-серверов (NocoDB, GitHub, Slack, Sentry, CI/CD)
- 12 bash-скриптов для установки и обслуживания
- Эталонный референс всех API и MCP-серверов
- 8 фаз внедрения Loop Engineering за 10 недель

### Known Issues (устранены в 2.0)
- NocoDB MCP выдаёт `Session terminated` и `404 Not Found`
- JWT-токены NocoDB истекают каждые 10 часов
- Хостовое монтирование `noco.db` вызывает `Permission denied` и `attempt to write a readonly database`
- DNS-имя `nocodb-web-ui` не разрешается на хосте Linux Mint
- Сложность ручного сброса паролей через `npx nocodb user:reset-password`

## [0.9.0] — 2026-06-20

### Added
- Базовая структура репозитория
- Начальные наброски архитектуры
- Первый прототип docker-compose.yml

## [0.1.0] — 2026-06-01

### Added
- Инициализация проекта
- Концептуальная модель «Студии программирования»
