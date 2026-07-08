# Архитектура 2.0 — разделение ответственности

> Содержание: 2-уровневая архитектура (Мозг + Приборная панель), компоненты, обоснование выбора, верхнеуровневая Mermaid-диаграмма, принципы конвергенции данных.

## 1. Обзор архитектуры 2.0

«Студия программирования» версии 2.0 построена на принципе **разделения ответственности** (separation of concerns). Это кардинальное отличие от версии 1.0, где NocoDB пытался быть одновременно и приборной панелью для человека, и мозгом для AI-агента. Практика показала, что такая универсализация создаёт больше проблем, чем решает: MCP-сервер NocoDB выдаёт `Session terminated` и `404 Not Found`, JWT-токены истекают каждые 10 часов, ручной сброс паролей через `npx nocodb user:reset-password` и прямой `psql` к скрытому SQLite-файлу стал рутиной. Система не соответствовала ключевым требованиям: максимальная гибкость, высокая надёжность, работа исключительно через API/MCP без ручного вмешательства.

Архитектура 2.0 разделяет систему на **два независимых уровня** с разными целями, разными потребителями и разными технологиями. Уровень «Мозга» — это PostgreSQL 16 с расширениями pgvector (векторный поиск) и Apache AGE (графовый слой, язык Cypher), доступный AI-агенту через официальный `@modelcontextprotocol/server-postgres`. Уровень «Приборной панели» — это NocoDB, подключённый к тому же PostgreSQL, предоставляющий человеку Kanban-доски, CRM-формы и дашборды. Оба уровня работают с одной и той же базой данных, обеспечивая единую точку истины: изменения менеджера мгновенно видны агенту, результаты анализа агента автоматически появляются на дашборде.

Конвергентная база данных PostgreSQL с тремя расширениями соответствует современной парадигме, описанной в исследовании AkasicDB (KAIST): объединение реляционных, векторных и графовых данных в одном движке повышает точность ИИ на 78% и радикально снижает количество «галлюцинаций». Аналогичный подход используют Oracle AI Database 26ai (векторный поиск + Property Graph + RAG в ядре), Google Cloud Spanner (multi-model) и SurrealDB (заменяет 6 систем одним движком). Для «Студии» это означает: один SQL-запрос может одновременно выполнять `JOIN` по реляционным данным, `<->` k-NN векторный поиск и Cypher-обход графа зависимостей — без межсистемных round-trips, без ETL-синхронизации, без потери контекста.

## 2. Верхнеуровневая диаграмма

```mermaid
flowchart TB
    subgraph HOST["Windows 10 Pro — физический хост"]
        VB[VirtualBox 7.2]
        WIN_SYNC[Syncthing node]
        WIN_FS[Локальные файлы D:\StudioCode]
    end

    subgraph VM["Linux Mint 22 — гостевая VM (16-32 ГБ RAM)"]
        subgraph DOCKER["Docker Compose stack"]
            subgraph BRAIN["Уровень МОЗГА (машинный)"]
                PG[(PostgreSQL 16<br/>+ pgvector<br/>+ Apache AGE)]
                PG_MCP[postgres MCP<br/>stdio<br/>@modelcontextprotocol/server-postgres]
                EMBED[Embedding Service<br/>all-MiniLM-L6-v2<br/>384 dim]
            end

            subgraph DASH["Уровень ПРИБОРНОЙ ПАНЕЛИ (человеческий)"]
                NOCODB[NocoDB<br/>Kanban + CRM + Forms]
                NOCODB_UI[Web UI<br/>http://localhost:8080]
            end

            subgraph AGENT["Слой агентов"]
                HERMES[Hermes Agent<br/>Skills + Memory + /handoff]
                HOLIX[Holix agents<br/>исполнители + QA + Checker]
                OH[OpenHands<br/>внешний Maker]
            end

            subgraph EXT_KB["Внешние источники знаний"]
                SOA[Stack Overflow for Agents<br/>OAuth 2.1<br/>100 calls/day]
            end

            subgraph INFRA["Инфраструктура"]
                EGRESS[Egress Proxy<br/>Squid whitelist]
                PORT[Portainer]
                SYNC[Syncthing node]
            end
        end
    end

    USER([Пользователь]) -->|задача через CLI| HERMES
    USER -->|Kanban/формы| NOCODB_UI
    USER -->|review PR| GH[(GitHub)]

    HERMES -->|MCP stdio| PG_MCP
    PG_MCP -->|SQL + Cypher| PG
    HERMES -->|MCP HTTPS OAuth 2.1| SOA
    HERMES -->|delegate_task| HOLIX
    HOLIX -->|ограниченный контекст| OH
    OH -->|diff| HOLIX
    HOLIX -->|verify| PG
    HERMES -->|open PR| GH
    
    NOCODB -->|read/write SQL| PG
    EMBED -->|generate vectors| PG
    
    HERMES -->|egress через| EGRESS
    OH -->|egress через| EGRESS
    SOA -->|HTTPS через| EGRESS
    
    WIN_SYNC <-->|P2P TLS port 22000| SYNC
    SYNC --> SYNCED[~/syncthing-host]

    style HOST fill:#EFF6FF,stroke:#2563EB
    style VM fill:#F0FDF4,stroke:#16A34A
    style BRAIN fill:#E0E7FF,stroke:#4F46E5,stroke-width:2px
    style DASH fill:#FED7AA,stroke:#EA580C
    style HERMES fill:#DBEAFE,stroke:#2563EB,stroke-width:2px
    style SOA fill:#FCE7F3,stroke:#DB2777
    style PG fill:#E0E7FF,stroke:#4F46E5,stroke-width:3px
```

## 3. Два уровня архитектуры

### 3.1. Уровень «Мозга» — для AI-агента

**Технология:** PostgreSQL 16 + pgvector + Apache AGE.
**Потребитель:** Hermes Agent (через postgres MCP).
**Цель:** Долговременная память, семантический RAG-поиск, анализ сложных взаимосвязей.

Этот уровень оптимизирован для машинного взаимодействия. Он не имеет UI, не имеет форм, не имеет Kanban-досок. Только чистый, быстрый, транзакционный движок, доступный через стандартизированный MCP-протокол. Hermes подключается к нему через `@modelcontextprotocol/server-postgres` — официальный MCP-сервер с прямым TCP-соединением, без JWT, без OAuth-истечений, без промежуточных API-слоёв.

**Три типа данных в одном движке:**

1. **Реляционные данные** — структура проектов, задачи, пользователи, коммиты, метаданные. Классический PostgreSQL с ACID-транзакциями, foreign keys, JOIN-операциями.
2. **Векторные данные** — эмбеддинги текстовых артефактов (HANDOFF.md-файлы, фрагменты кода, документация, сообщения об ошибках) в столбцах типа `VECTOR(384)`. k-NN поиск через оператор `<->` с HNSW- или IVFFlat-индексами.
3. **Графовые данные** — через Apache AGE. Граф зависимостей кода (какой модуль вызывает какой), связи между задачами и коммитами, архитектура микросервисов. Запросы на языке Cypher, интегрированном в SQL.

**Ключевое преимущество:** единая транзакционная модель. При создании новой задачи можно одновременно INSERT реляционную запись, сгенерировать и сохранить векторный эмбеддинг, создать графовые связи — всё в одной ACID-транзакции. Это гарантирует целостность всех трёх представлений и устраняет рассинхронизацию, характерную для распределённых систем.

### 3.2. Уровень «Приборной панели» — для человека

**Технология:** NocoDB.
**Потребитель:** Менеджер, разработчик, заказчик (через веб-UI).
**Цель:** Kanban-доски, CRM, формы, визуализация данных без кодирования.

NocoDB остаётся в системе, но его роль кардинально сужена. Он больше не является «мозгом» — он стал «приборной панелью». Это open-source альтернатива Airtable, предоставляющая удобный интерфейс для создания CRUD-приложений, Kanban-досок, CRM-систем и календарей. Сильная сторона NocoDB — быстрое прототипирование и визуальное представление данных. Он подключается к PostgreSQL и читает/пишет в те же таблицы, что и Hermes.

**Что NocoDB делает в 2.0:**

- **Управление проектами:** Kanban-доски «To Do / In Progress / Done», карточки задач с приоритетами и сроками.
- **CRM и учёт клиентов:** таблицы клиентов, проектов, спецификаций, историй взаимодействий.
- **Технические спецификации:** структурированные таблицы требований к ПО, API-схем, конфигураций.
- **Визуализация данных:** таблицы, галереи, календари, диаграммы для понимания состояния проектов.

**Что NocoDB больше НЕ делает в 2.0:**

- Не является долговременной памятью Hermes (это делает PostgreSQL).
- Не предоставляет MCP-сервер для агента (это делает postgres MCP).
- Не хранит векторные эмбеддинги (это делает pgvector внутри PostgreSQL).
- Не выполняет семантический поиск (это делает Hermes через `<->` оператор).
- Не хранит графы зависимостей (это делает Apache AGE внутри PostgreSQL).

### 3.3. Двунаправленная синхронизация

Мозг и приборная панель не изолированы — они образуют **замкнутый цикл знаний**:

```mermaid
flowchart LR
    M[Менеджер] -->|создаёт задачу в Kanban| N[NocoDB UI]
    N -->|INSERT SQL| P[(PostgreSQL<br/>+pgvector+AGE)]
    H[Hermes] -->|SELECT SQL через MCP| P
    H -->|анализ задачи| H2[поиск похожих в pgvector<br/>обход графа в AGE]
    H2 -->|решение| O[OpenHands Maker]
    O -->|diff| H
    H -->|HANDOFF.md + embedding| P
    P -->|авто-обогащение| N
    N -->|новая карточка в Базе знаний| M
    
    style P fill:#E0E7FF,stroke:#4F46E5,stroke-width:3px
    style H fill:#DBEAFE,stroke:#2563EB,stroke-width:2px
    style N fill:#FED7AA,stroke:#EA580C
```

**Пример сценария:** Менеджер открывает дашборд NocoDB, видит карточку «Проблема с производительностью в API Gateway». Даёт команду Hermes: «Исследуй эту проблему». Hermes обращается к PostgreSQL: через графовый слой AGE находит все сервисы, вызывающие API Gateway; через векторный слой pgvector находит семантически похожие ошибки и их решения; через реляционный слой находит коммиты за последние две недели. Анализируя все три слоя в одном запросе, Hermes выявляет медленный SQL-запрос, добавленный в недавнем коммите. Он предлагает оптимизацию и автоматически создаёт новую карточку в NocoDB на доске «База знаний» с описанием проблемы и решения. Теперь это знание доступно всем участникам проекта.

## 4. Компоненты системы

### 4.1. PostgreSQL 16 — основа мозга

**Роль:** Надёжная реляционная СУБД с поддержкой ACID-транзакций, внешних ключей, сложных JOIN-операций. PostgreSQL 16 выбран за производительность, надёжность и поддержку расширений.

**Ключевые характеристики:**
- ACID-транзакции для всех операций (включая векторные и графовые через расширения).
- Параллельное выполнение запросов, поддержка сотен одновременных подключений.
- Репликация (streaming, logical) для отказоустойчивости.
- Партиционирование таблиц по диапазону, списку, хешу.
- Полноценный SQL с поддержкой CTE, window functions, JSONB.

### 4.2. pgvector — векторная память

**Роль:** Расширение PostgreSQL для хранения векторных эмбеддингов и выполнения быстрого k-NN семантического поиска. Это основа RAG-системы — технологии, позволяющей Hermes запоминать контекст и извлекать его по смыслу, а не по точному совпадению слов.

**Использование:**
- При сохранении HANDOFF.md генерируется эмбеддинг моделью `sentence-transformers/all-MiniLM-L6-v2` (384-мерный вектор).
- Эмбеддинг сохраняется в столбце типа `VECTOR(384)`.
- Создаётся HNSW-индекс для O(log n) поиска.
- При новой задаче Hermes генерирует эмбеддинг запроса и выполняет `SELECT ... ORDER BY embedding <-> $1 LIMIT 5`.

**Метрики расстояния:** cosine (`<=>`), L2 (`<->`), inner product (`<#>`). Для RAG обычно используется cosine — он нормирует длину векторов и хорошо работает для семантического сходства текстов.

### 4.3. Apache AGE — графовый слой

**Роль:** Расширение PostgreSQL, добавляющее поддержку графовых данных и языка запросов Cypher. Позволяет Hermes понимать сложные связи: зависимости между модулями кода, цепочки вызовов функций, влияние изменений на разные части системы.

**Установка:**

```bash
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "CREATE EXTENSION IF NOT EXISTS age;"
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "LOAD 'age';"
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "SET search_path = ag_catalog, \"$user\", public;"
```

**Пример запроса (найти все сервисы, зависящие от устаревшей библиотеки):**

```cypher
SELECT * FROM ag_catalog.cypher('code_graph', $$
    MATCH (service:Microservice)-[:DEPENDS_ON]->(lib:Library {name: 'old_jwt_lib'})
    RETURN service.name, service.version
$$) AS (name agtype, version agtype);
```

Этот запрос можно комбинировать с реляционным SQL:

```sql
SELECT s.name, s.version, t.id AS task_id, t.status
FROM ag_catalog.cypher('code_graph', $$
    MATCH (service:Microservice)-[:DEPENDS_ON]->(lib:Library {name: 'old_jwt_lib'})
    RETURN service.name, service.version
$$) AS (name agtype, version agtype) s
JOIN studio.tasks t ON t.service = s.name::text
WHERE t.status = 'open';
```

### 4.4. postgres MCP — стандартизованный доступ

**Роль:** Официальный MCP-сервер `@modelcontextprotocol/server-postgres`, предоставляющий Hermes стандартизованный доступ к PostgreSQL. Заменяет капризный NocoDB MCP.

**Подключение:**

```bash
hermes mcp add hermes-brain --transport stdio -- \
  npx -y @modelcontextprotocol/server-postgres \
  "postgresql://nocodb_user:${POSTGRES_PASSWORD}@nocodb-postgres-db:5432/hermes_brain"
```

**Преимущества перед NocoDB MCP:**
- Прямое TCP-соединение, без промежуточного HTTP API.
- Нет JWT-токенов с истечением 10 часов.
- Нет `Session terminated` и `404 Not Found`.
- Стандартизованный протокол MCP с поддержкой всеми LLM-агентами.
- Поддержка всех SQL-операций (SELECT, INSERT, UPDATE, DELETE, Cypher через `SELECT * FROM cypher(...)`).

### 4.5. NocoDB — приборная панель

**Роль:** Веб-UI для человека. Kanban-доски, формы, CRM, дашборды. Читает и пишет в тот же PostgreSQL через стандартное подключение (NocoDB поддерживает PostgreSQL как источник данных).

**Конфигурация:**

```yaml
# docker-compose.yml
nocodb-app:
  image: nocodb/nocodb:latest
  environment:
    NC_DB: "pg://nocodb-postgres-db:5432/hermes_brain"
    NC_DB_USER: nocodb_user
    NC_DB_PASSWORD: ${POSTGRES_PASSWORD}
```

NocoDB видит все таблицы в схеме `public` и `studio_*` (для мультитенантности). Менеджер может создать Kanban-доску на основе таблицы `studio.tasks` — изменения в карточках сразу записываются в PostgreSQL и мгновенно доступны Hermes.

### 4.6. Hermes Agent — оркестратор

**Роль:** AI-агент от Nous Research с встроенной системой навыков (Skills System), несколькими провайдерами памяти (нативный Postgres provider), двунаправленной поддержкой MCP (клиент с v0.5+, сервер с v0.6.0+), командой `/handoff` для передачи сессии между моделями, и встроенным компрессором контекста.

**Ключевые модули:**
- `Skills System` — процедурная память. Успешные решения сохраняются как `.md` файлы и переиспользуются в будущих задачах.
- `Memory Providers` — долговременная память. Поддержка Postgres, Redis, файла. Мы используем Postgres provider, который напрямую работает с pgvector.
- `MCP client` — подключение к внешним MCP-серверам (postgres, SOA, GitHub, Slack, Sentry).
- `MCP server` (с v0.6.0) — Hermes сам может выступать сервером, предоставляя свою историю сессий другим клиентам (Cursor, Claude Desktop).
- `/handoff` — команда передачи активной сессии между моделями. Генерирует структурированный HANDOFF.md.
- `Context compressor` — автоматическое сжатие длинных контекстов в структурированные документы.

Подробно — в [docs/07-hermes-agent.md](07-hermes-agent.md).

### 4.7. Stack Overflow for Agents — внешние знания

**Роль:** Публичный MCP-сервер от Stack Overflow, предоставляющий AI-агентам доступ к проверенным техническим решениям. Используется для общих программистских вопросов («как настроить SSL в FastAPI», «как исправить CORS-ошибку»). Аутентификация через OAuth 2.1, лимит 100 вызовов в день в бета-версии.

**Подключение:**

```bash
hermes mcp add stackoverflow --transport http --url https://mcp.stackoverflow.com
# При первом вызове откроется браузер для OAuth 2.1 авторизации
```

**Инструменты SOA:**
- `so_search` — текстовый поиск по вопросам и ответам.
- `get_content` — получить полное содержание вопроса, ответа или комментариев по ID.
- `search_by_error` — поиск решений по сообщениям об ошибках.
- `analyze_stack_trace` — анализ трассировок стека.

Подробно — в [docs/08-knowledge-orchestration.md](08-knowledge-orchestration.md).

### 4.8. Holix и OpenHands — исполнители

**Holix** — среда исполнения с workspace jail для внутренних агентов-исполнителей (Backend Lead, Frontend Lead, Python Dev, QA, Loop Checker, Lint Agent, Coordinator, Archivist). Каждый агент изолирован в своей файловой директории.

**OpenHands** — внешний подрядчик (Maker) для трудоёмких задач. Работает в собственной Docker-песочнице с egress firewall. Получает ограниченный контекст от Holix Coordinator, никогда — прямой доступ к кодовой базе или к PostgreSQL.

Подробно — в [docs/12-loop-engineering.md](12-loop-engineering.md).

## 5. Аппаратные требования

### 5.1. Обоснование

Поскольку все LLM-вызовы происходят через внешние API (DeepSeek, OpenAI, Anthropic), GPU не требуется. Бюджет полностью вкладывается в три ресурса: **многоядерный CPU** для параллельного выполнения агентов и графовых запросов, **большой объём RAM** для HNSW-индексов pgvector и Apache AGE, **быстрый NVMe SSD** для I/O-интенсивных операций.

### 5.2. Расчёт ресурсов

| Ресурс | Формула | Пример для 25 агентов |
|--------|---------|----------------------|
| RAM на агента | ~1 ГБ (Python + библиотеки + векторный кэш) | 25 × 1 ГБ = 25 ГБ |
| RAM на PostgreSQL | shared_buffers + HNSW-индексы + AGE | ~6-8 ГБ |
| RAM на систему | ОС + Docker daemon | ~4 ГБ |
| **Итого RAM** | | **~35-37 ГБ** |
| CPU ядер | Минимум 1 ядро на 2-3 активных агента + 2 ядра для PostgreSQL | ~12 ядер |
| CPU потоков | С учётом HT/SMT | ~24-56 потоков |
| SSD IOPS | NVMe M.2 PCIe 4.0: ~500K IOPS | достаточно |
| Сеть | LLM API + SOA: ~5-10 МБ/запрос | гигабитный Ethernet |

### 5.3. Рекомендованные конфигурации

| Компонент | Минимум | Оптимально |
|-----------|---------|------------|
| CPU | 1x AMD Ryzen 9 7900X (12C/24T) | 2x Intel Xeon E5-2680 v4 (28C/56T) |
| RAM | 32 ГБ DDR4 ECC | 64 ГБ DDR4 ECC |
| SSD | 1 ТБ NVMe M.2 PCIe 4.0 | 2 ТБ NVMe M.2 PCIe 4.0 |
| GPU | Не требуется | Не требуется |
| Сеть | Гигабитный Ethernet | 2.5 Гбит/с Ethernet |
| Хост-ОС | Windows 10 Pro 21H2+ | Windows 11 Pro 23H2+ |
| Гость-ОС | Linux Mint 22 | Linux Mint 22 / Ubuntu Server 24.04 LTS |

## 6. Сетевая топология

```mermaid
flowchart LR
    subgraph INET["Интернет"]
        LLM[LLM API<br/>DeepSeek/OpenAI/Anthropic]
        GH[GitHub]
        SOA[Stack Overflow<br/>mcp.stackoverflow.com]
        SLACK[Slack]
        SENTRY[Sentry]
    end

    subgraph VM["VM Linux Mint"]
        subgraph NET["Docker network: studio-net (172.20.0.0/16)"]
            HERMES[Hermes<br/>172.20.0.10]
            PG[(PostgreSQL+pgvector+AGE<br/>172.20.0.30:5432)]
            NOCODB[NocoDB<br/>172.20.0.20:8080]
            PG_MCP[postgres MCP<br/>stdio in Hermes]
            HOLIX[Holix agents<br/>172.20.0.40-50]
            OH[OpenHands<br/>172.20.0.60]
            EGRESS[Egress Squid<br/>172.20.0.100:3128]
        end
    end

    HERMES -->|stdio| PG_MCP
    PG_MCP -->|TCP 5432| PG
    NOCODB -->|TCP 5432| PG
    HERMES -->|HTTPS via EGRESS| SOA
    HERMES -->|HTTPS via EGRESS| LLM
    OH -->|HTTPS via EGRESS| LLM
    HOLIX -->|HTTPS via EGRESS| LLM
    HERMES -->|HTTPS via EGRESS| GH

    style NET fill:#FEF3C7,stroke:#D97706
    style PG fill:#E0E7FF,stroke:#4F46E5,stroke-width:2px
    style EGRESS fill:#FEE2E2,stroke:#DC2626,stroke-width:2px
```

Все сервисы работают в одной Docker-сети `studio-net`. **Сетевой доступ во внешний интернет** строго контролируется через egress-прокси (Squid) с whitelist доменов: LLM API, GitHub, SOA, Slack, Sentry, PyPI, npm registry. Любой другой исходящий трафик блокируется.

## 7. Поток данных: от задачи до PR

```mermaid
sequenceDiagram
    participant U as Пользователь
    participant N as NocoDB
    participant P as PostgreSQL+pgvector+AGE
    participant H as Hermes
    participant SOA as Stack Overflow
    participant HC as Holix Coordinator
    participant OH as OpenHands
    participant QA as Holix QA
    participant GH as GitHub

    U->>N: Создаёт задачу в Kanban
    N->>P: INSERT INTO studio.tasks
    U->>H: "Исследуй задачу #142"
    
    H->>P: Векторный поиск похожих задач (pgvector)
    P-->>H: 3 похожих задачи + решения
    H->>P: Граф зависимостей (AGE Cypher)
    P-->>H: 5 затронутых модулей
    H->>SOA: so_search("FastAPI SSL error")
    SOA-->>H: Верифицированное решение
    
    H->>HC: delegate_task(refactor_auth)
    HC->>P: semantic_search навыков (pgvector)
    P-->>HC: 4 релевантных навыка
    HC->>OH: задача + ограниченный контекст
    OH->>OH: генерация кода в worktree
    OH-->>HC: diff + commit
    HC->>QA: check(worktree)
    QA->>QA: pytest + flake8 + bandit
    QA-->>HC: PASS
    HC-->>H: result + verdict
    
    H->>GH: create_pull_request
    GH-->>H: PR URL
    H->>P: SAVE HANDOFF.md + embedding (pgvector)
    H->>P: UPDATE studio.tasks SET status='done'
    P->>N: Webhook → обновление Kanban
    N-->>U: Карточка перемещена в "Done"
```

## 8. Что дальше

- **Развёртывание VirtualBox + Linux Mint** — [docs/02-deployment.md](02-deployment.md)
- **Docker Compose стек** — [docs/03-docker-stack.md](03-docker-stack.md)
- **Конвергентная база данных** — [docs/04-convergent-database.md](04-convergent-database.md)
- **Эталонный API/MCP референс** — [docs/06-api-mcp-reference.md](06-api-mcp-reference.md)
