# Конвергентная база данных — мозг системы

> Содержание: PostgreSQL 16 + pgvector + Apache AGE как единый движок для реляционных, векторных и графовых данных. Схема `hermes_brain`, таблицы `skills` и `handoff_documents`, графы `code_graph` и `task_graph`, SQL + Cypher в одном запросе, мультитенантность через схемы.

## 1. Зачем конвергентная БД

В версии 1.0 NocoDB играл роль «мозга» AI-агента. Практика показала, что это архитектурное несоответствие: NocoDB — это low-code/no-code платформа для создания CRUD-приложений с веб-интерфейсом, ориентированная на визуальное восприятие человека. Его сильные стороны (гибкая модель данных, быстрое прототипирование, удобный UI) становятся слабыми при попытке использовать его как долговременную память для RAG-системы. NocoDB не имеет встроенной поддержки векторных эмбеддингов, его MCP-сервер выдаёт `Session terminated` и `404 Not Found`, JWT-токены истекают каждые 10 часов, а ручной сброс паролей через `npx nocodb user:reset-password` или прямой `psql` к скрытому SQLite-файлу стал рутиной.

В версии 2.0 «мозгом» становится **конвергентная база данных** PostgreSQL 16 с тремя расширениями: нативная реляционная поддержка (ACID, JOIN, foreign keys), `pgvector` для векторного поиска (семантический RAG), и `Apache AGE` для графовых запросов на языке Cypher (анализ зависимостей кода). Все три типа данных хранятся в одном движке, в одних транзакциях, с одним языком запросов. Это соответствует современной парадигме, описанной в исследовании AkasicDB (KAIST): объединение реляционных, векторных и графовых данных в единой системе повышает точность ИИ на 78% и радикально снижает количество «галлюцинаций».

Конвергентный подход устраняет три проблемы распределённых систем. **Во-первых**, отсутствие ETL-синхронизации: не нужно переносить данные между PostgreSQL, Pinecone и Neo4j. **Во-вторых**, ACID-целостность: при создании новой задачи можно одновременно INSERT реляционную запись, сгенерировать и сохранить векторный эмбеддинг, создать графовые связи — всё в одной транзакции. **В-третьих**, производительность: один SQL-запрос может сочетать JOIN, `<->` k-NN векторный поиск и Cypher-обход графа, без межсистемных round-trips.

## 2. Архитектура

```mermaid
flowchart TB
    subgraph PG["PostgreSQL 16 — hermes_brain"]
        subgraph REL["Реляционный слой (нативный)"]
            T1[public.skills]
            T2[public.handoff_documents]
            T3[public.agent_sessions]
            T4[public.api_keys_audit]
            T5[public.tenants]
            T6[studio_*.tasks/loop_runs/...]
        end
        
        subgraph VEC["Векторный слой (pgvector)"]
            V1[VECTOR(384) columns]
            V2[HNSW indexes]
            V3[k-NN operator <=>]
        end
        
        subgraph GRAPH["Графовый слой (Apache AGE)"]
            G1[code_graph]
            G2[task_graph]
            G3[Cypher queries]
        end
    end
    
    HERMES[Hermes Agent] -->|postgres MCP<br/>stdio| PG
    NOCODB[NocoDB UI] -->|SQL driver| PG
    ARCHIVIST[Holix Archivist] -->|postgres MCP<br/>read_write| PG
    COORDINATOR[Holix Coordinator] -->|postgres MCP<br/>read_only| PG
    
    style PG fill:#E0E7FF,stroke:#4F46E5,stroke-width:3px
    style HERMES fill:#DBEAFE,stroke:#2563EB,stroke-width:2px
    style VEC fill:#FCE7F3,stroke:#DB2777
    style GRAPH fill:#F0FDF4,stroke:#16A34A
```

## 3. Установка расширений

Расширения устанавливаются в БД `hermes_brain` после первого запуска PostgreSQL:

```bash
# 1. Создание базы данных
docker exec -it nocodb-postgres-db psql -U nocodb_user -d postgres -c \
  "CREATE DATABASE hermes_brain;"

# 2. Установка расширений
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c \
  "CREATE EXTENSION IF NOT EXISTS vector;"  # pgvector

docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c \
  "CREATE EXTENSION IF NOT EXISTS age;"  # Apache AGE

# 3. Загрузка AGE и установка search_path
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "LOAD 'age';"
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c \
  "SET search_path = ag_catalog, \"\$user\", public;"

# 4. Создание графов
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c \
  "SELECT ag_catalog.create_graph('code_graph');"
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c \
  "SELECT ag_catalog.create_graph('task_graph');"

# 5. Дополнительные расширения
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c \
  "CREATE EXTENSION IF NOT EXISTS pg_trgm;"  # полнотекстовый поиск
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c \
  "CREATE EXTENSION IF NOT EXISTS pgcrypto;"  # gen_random_uuid
```

Готовый скрипт — `scripts/06-init-convergent-db.sh`.

## 4. Реляционный слой

### 4.1. `public.skills` — библиотека навыков Hermes

Hermes Agent имеет встроенную Skills System: успешные решения сохраняются как `.md` файлы и переиспользуются в будущих задачах. В v2.0 все навыки хранятся в PostgreSQL, а не в файловой системе — это даёт поиск, версионирование и мультитенантность.

```sql
CREATE TABLE public.skills (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(100) UNIQUE NOT NULL,
    description TEXT NOT NULL,
    content_markdown TEXT NOT NULL,
    skill_type VARCHAR(30) NOT NULL,  -- 'loop', 'handoff', 'procedural', 'reference'
    category VARCHAR(50) NOT NULL,    -- 'backend', 'frontend', 'devops', 'security', 'qa', 'general'
    tags TEXT[],
    embedding VECTOR(384),            -- 384-мерный эмбеддинг контента
    source VARCHAR(20) DEFAULT 'manual',
    status VARCHAR(20) DEFAULT 'draft',
    created_by VARCHAR(50) DEFAULT 'system',
    tenant_id VARCHAR(50) DEFAULT 'default',
    version INTEGER DEFAULT 1,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Индексы
CREATE INDEX idx_skills_category ON public.skills (category, status);
CREATE INDEX idx_skills_tenant ON public.skills (tenant_id);
CREATE INDEX idx_skills_tags ON public.skills USING GIN (tags);
CREATE INDEX idx_skills_embedding ON public.skills 
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

COMMENT ON TABLE public.skills IS 'Библиотека навыков Hermes Agent (Skills System)';
COMMENT ON COLUMN public.skills.embedding IS 'Векторное представление контента (all-MiniLM-L6-v2, 384 dim)';
```

### 4.2. `public.handoff_documents` — векторная память HDD

Это сердце Handoff-Driven Development. После каждой задачи Hermes генерирует `HANDOFF.md` по Agent Handoff Protocol (AHP), который сохраняется в эту таблицу с векторным эмбеддингом. При новой похожей задаче Hermes находит релевантные handoff-документы через k-NN поиск.

```sql
CREATE TABLE public.handoff_documents (
    id BIGSERIAL PRIMARY KEY,
    document_type VARCHAR(30) NOT NULL,  -- 'handoff', 'decision', 'lesson', 'error_pattern'
    title VARCHAR(255) NOT NULL,
    content_markdown TEXT NOT NULL,
    embedding VECTOR(384),
    task_id BIGINT,                      -- ссылка на studio_<tenant>.tasks
    agent_name VARCHAR(50),
    session_id UUID,
    handoff_packet JSONB,                -- структурированный HandoffPacket по AHP
    source_task_description TEXT,
    outcome VARCHAR(20),                 -- 'success', 'failure', 'partial', 'escalated'
    tokens_used INTEGER DEFAULT 0,
    cost_usd DECIMAL(10,4) DEFAULT 0,
    tenant_id VARCHAR(50) DEFAULT 'default',
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_handoff_type ON public.handoff_documents (document_type, tenant_id);
CREATE INDEX idx_handoff_agent ON public.handoff_documents (agent_name, created_at DESC);
CREATE INDEX idx_handoff_embedding ON public.handoff_documents 
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
```

### 4.3. `public.agent_sessions` — сессии Hermes

```sql
CREATE TABLE public.agent_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_name VARCHAR(50) NOT NULL,
    started_at TIMESTAMP DEFAULT NOW(),
    finished_at TIMESTAMP,
    status VARCHAR(20) DEFAULT 'active',
    model_name VARCHAR(50),
    tokens_input INTEGER DEFAULT 0,
    tokens_output INTEGER DEFAULT 0,
    cost_usd DECIMAL(10,4) DEFAULT 0,
    context_compressed BOOLEAN DEFAULT FALSE,
    handoff_document_id BIGINT,
    tenant_id VARCHAR(50) DEFAULT 'default',
    metadata JSONB
);
```

### 4.4. `public.api_keys_audit` — аудит всех API/MCP вызовов

Партиционированная по неделям таблица для аудита всех вызовов MCP-серверов. Каждая запись: агент, MCP-сервер, инструмент, входные параметры (после `sanitize_for_log`), результат, длительность, стоимость.

```sql
CREATE TABLE public.api_keys_audit (
    id BIGSERIAL,
    timestamp TIMESTAMP DEFAULT NOW() NOT NULL,
    agent_name VARCHAR(50) NOT NULL,
    mcp_server VARCHAR(50) NOT NULL,  -- 'postgres', 'stackoverflow', 'github', 'slack', 'sentry'
    tool_name VARCHAR(100) NOT NULL,
    input_params JSONB,
    output_result JSONB,
    result_status VARCHAR(20),
    duration_ms INTEGER,
    tokens_used INTEGER DEFAULT 0,
    cost_usd DECIMAL(10,4) DEFAULT 0,
    session_id UUID,
    tenant_id VARCHAR(50) DEFAULT 'default',
    PRIMARY KEY (id, timestamp)
) PARTITION BY RANGE (timestamp);

-- Создание партиций на 12 недель вперёд
-- (см. examples/sql/02-brain-tables.sql для полного кода)
```

### 4.5. `public.tenants` — реестр тенантов

```sql
CREATE TABLE public.tenants (
    id SERIAL PRIMARY KEY,
    tenant_id VARCHAR(50) UNIQUE NOT NULL,
    schema_name VARCHAR(100) NOT NULL,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    is_active BOOLEAN DEFAULT TRUE,
    settings JSONB
);

-- Тестовый тенант
INSERT INTO public.tenants (tenant_id, schema_name, name, description)
VALUES ('default', 'studio_default', 'Default Studio', 'Тестовый тенант')
ON CONFLICT (tenant_id) DO NOTHING;
```

## 5. Векторный слой (pgvector)

### 5.1. Модель эмбеддингов

Используется `sentence-transformers/all-MiniLM-L6-v2` — компактная модель (~80 МБ), генерирующая 384-мерные векторы. Хорошо подходит для семантического поиска по техническим текстам (код, документация, HANDOFF.md). Альтернативы для специфичных доменов: `BAAI/bge-small-en`, `nomic-ai/nomic-embed-text-v1`.

Загрузка модели в Holix Archivist:

```python
from sentence_transformers import SentenceTransformer
model = SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2')

def generate_embedding(text: str) -> list[float]:
    """Сгенерировать 384-мерный эмбеддинг текста."""
    return model.encode(text).tolist()
```

### 5.2. Тип VECTOR и индексы

pgvector добавляет тип `VECTOR(N)` для хранения N-мерных векторов. Поддерживаются индексы:

| Индекс | Когда использовать | Производительность |
|--------|-------------------|-------------------|
| **HNSW** | До 1M векторов, нужен быстрый поиск | O(log n), ~10x быстрее IVFFlat |
| **IVFFlat** | > 1M векторов, можно пожертвовать точностью | O(sqrt(n)), меньше памяти |

Для «Студии» выбран **HNSW** с параметрами `m=16, ef_construction=64`:

```sql
CREATE INDEX idx_skills_embedding ON public.skills 
    USING hnsw (embedding vector_cosine_ops) 
    WITH (m = 16, ef_construction = 64);
```

### 5.3. Метрики расстояния

pgvector поддерживает три оператора:

| Оператор | Метрика | Когда использовать |
|----------|---------|-------------------|
| `<->` | L2 (Euclidean) | Общий случай |
| `<=>` | Cosine | Текстовые эмбеддинги (нормализованные) |
| `<#>` | Inner product (negative) | Если векторы уже нормализованы |

Для RAG с all-MiniLM-L6-v2 используется **cosine** (`<=>`), так как модель выдаёт нормализованные векторы и cosine хорошо работает для семантического сходства текстов.

### 5.4. k-NN поиск

Семантический поиск навыков по смыслу:

```sql
-- Найти 5 наиболее релевантных навыков для запроса
SELECT 
    id, name, description,
    1 - (embedding <=> $1::vector) AS similarity
FROM public.skills
WHERE status = 'approved'
  AND tenant_id = 'default'
  AND category = ANY($2)  -- массив категорий
ORDER BY embedding <=> $1::vector
LIMIT 5;
```

Где `$1` — вектор запроса (384-мерный), `$2` — массив категорий для фильтрации. Результат `similarity` в диапазоне [0, 1], где 1 — полное совпадение.

**Пример из Python (Hermes через postgres MCP):**

```python
# Hermes генерирует эмбеддинг запроса
query = "как оптимизировать запросы к SQLAlchemy"
query_embedding = embedding_model.encode(query).tolist()

# Выполняет SQL через postgres MCP
result = postgres_mcp.call("query", {
    "sql": """
        SELECT id, name, description, content_markdown,
               1 - (embedding <=> $1::vector) AS similarity
        FROM public.skills
        WHERE status = 'approved' AND tenant_id = $2
        ORDER BY embedding <=> $1::vector
        LIMIT 5
    """,
    "params": [query_embedding, current_tenant_id]
})

for skill in result["rows"]:
    print(f"[{skill['similarity']:.3f}] {skill['name']}: {skill['description']}")
```

## 6. Графовый слой (Apache AGE)

### 6.1. Что такое AGE

Apache AGE (A Graph Extension) — это расширение PostgreSQL, добавляющее поддержку графовых данных и языка запросов Cypher. AGE позволяет создавать графы (наборы узлов и рёбер) внутри PostgreSQL и выполнять Cypher-запросы к ним, интегрированные с SQL.

AGE идеально подходит для «Студии», потому что позволяет Hermes понимать сложные связи:
- **Граф зависимостей кода** — какой модуль вызывает какой, какие функции зависят от какой библиотеки.
- **Граф связей между задачами** — какая задача блокирует какую, какие задачи связаны с одним epic.
- **Граф архитектуры** — какие микросервисы взаимодействуют, через какие API.

### 6.2. Создание графа

```sql
-- Создание графа (выполняется один раз)
SELECT ag_catalog.create_graph('code_graph');
SELECT ag_catalog.create_graph('task_graph');

-- Установка search_path для работы с AGE
SET search_path = ag_catalog, "$user", public;
```

### 6.3. Добавление узлов и рёбер

```sql
-- Добавить микросервис (узел с меткой Microservice)
SELECT * FROM ag_catalog.cypher('code_graph', $$
    CREATE (:Microservice {
        name: 'api-gateway',
        version: '1.4.0',
        language: 'python',
        framework: 'fastapi'
    })
$$) AS (result agtype);

-- Добавить библиотеку (узел с меткой Library)
SELECT * FROM ag_catalog.cypher('code_graph', $$
    CREATE (:Library {
        name: 'fastapi',
        version: '0.104.0',
        ecosystem: 'pypi'
    })
$$) AS (result agtype);

-- Создать ребро DEPENDS_ON
SELECT * FROM ag_catalog.cypher('code_graph', $$
    MATCH (s:Microservice {name: 'api-gateway'}), (l:Library {name: 'fastapi'})
    CREATE (s)-[:DEPENDS_ON {since: '2024-01-15'}]->(l)
$$) AS (result agtype);
```

### 6.4. Cypher-запросы

**Найти все сервисы, зависящие от указанной библиотеки:**

```sql
SELECT * FROM ag_catalog.cypher('code_graph', $$
    MATCH (service:Microservice)-[:DEPENDS_ON]->(lib:Library {name: 'fastapi'})
    RETURN service.name, service.version
$$) AS (name agtype, version agtype);
```

**Найти циклические зависимости:**

```sql
SELECT * FROM ag_catalog.cypher('code_graph', $$
    MATCH path = (a:Microservice)-[:DEPENDS_ON*1..10]->(a)
    RETURN [node IN nodes(path) | node.name] AS cycle
$$) AS (cycle agtype);
```

**Найти круг влияния изменения файла (до 3 уровней):**

```sql
SELECT * FROM ag_catalog.cypher('code_graph', $$
    MATCH (f:File {path: 'app/api/v1/auth.py'})<-[:DEFINED_IN*1..3]-(affected)
    RETURN DISTINCT affected.name, label(affected)
    LIMIT 50
$$) AS (name agtype, type agtype);
```

### 6.5. Комбинированный SQL + Cypher запрос

Ключевая мощь конвергентной БД — возможность комбинировать реляционный SQL и Cypher в одном запросе. Пример: найти все открытые задачи, связанные с микросервисами, которые зависят от устаревшей библиотеки:

```sql
SELECT 
    t.id,
    t.title,
    t.priority,
    s.service_name::text AS service,
    s.service_version::text AS version
FROM studio_default.tasks t
JOIN ag_catalog.cypher('code_graph', $$
    MATCH (service:Microservice)-[:DEPENDS_ON]->(lib:Library {name: 'old_jwt_lib'})
    RETURN service.name, service.version
$$) AS (service_name agtype, service_version agtype) s
  ON t.title ILIKE '%' || s.service_name::text || '%'
WHERE t.status = 'open'
ORDER BY t.priority DESC;
```

Этот запрос находит микросервисы, зависящие от устаревшей библиотеки (через граф), и связывает их с открытыми задачами (через реляционный JOIN). В распределённой системе это потребовало бы трёх запросов к трём разным БД и ручного слияния результатов.

## 7. Мультитенантность через схемы

Каждая «Студия» (организация) имеет свою схему PostgreSQL `studio_<tenant_id>` с изолированными таблицами. Это позволяет нескольким организациям работать на одной инфраструктуре с полной изоляцией данных.

### 7.1. Создание нового тенанта

```sql
-- Функция create_tenant_schema() создаёт схему со всеми таблицами
SELECT public.create_tenant_schema('studio_acme');
-- Создаёт схему studio_acme с таблицами:
--   studio_acme.tasks
--   studio_acme.loop_runs
--   studio_acme.loop_lessons
--   studio_acme.loop_progress
--   studio_acme.loop_registry
--   studio_acme.projects
--   studio_acme.agent_audit_log
```

### 7.2. Изоляция данных

Каждая схема изолирована на уровне PostgreSQL:
- Таблицы `studio_acme.tasks` и `studio_glb.tasks` — разные таблицы.
- Можно создать отдельных пользователей PostgreSQL с правами только на свою схему.
- Графы AGE (`code_graph`) могут быть разделены через свойство `tenant_id` на узлах.

Hermes передаёт `tenant_id` во всех запросах. Holix Backend маршрутизирует запросы к правильной схеме. Подробно — в [docs/10-multitenancy.md](10-multitenancy.md).

## 8. Доступ через postgres MCP

Hermes подключается к мозгу через официальный `@modelcontextprotocol/server-postgres`:

```bash
hermes mcp add hermes-brain --transport stdio -- \
  npx -y @modelcontextprotocol/server-postgres \
  "postgresql://nocodb_user:${POSTGRES_PASSWORD}@nocodb-postgres-db:5432/hermes_brain"
```

**Доступные MCP-инструменты:**

| Инструмент | Описание |
|-----------|----------|
| `query` | Выполнение SQL (включая Cypher через `SELECT * FROM cypher(...)`) |
| `list_tables` | Список таблиц в схеме |
| `describe_table` | Описание структуры таблицы |
| `list_schemas` | Список схем (для мультитенантности) |
| `vector_search` | Custom wrapper для pgvector k-NN |
| `graph_query` | Custom wrapper для AGE Cypher |

**Безопасность:**
- `forbid_ddl: true` — запрещены CREATE/DROP/ALTER
- `forbid_truncate: true` — запрещён TRUNCATE
- `row_limit: 10000` — максимум строк в результате
- `sql_injection_protection: parameterized_queries_only` — только параметризованные запросы

Подробно — в [docs/06-api-mcp-reference.md](06-api-mcp-reference.md).

## 9. Backup и восстановление

### 9.1. Backup

```bash
# Полный дамп hermes_brain
docker exec nocodb-postgres-db pg_dump -U nocodb_user -d hermes_brain | gzip > \
  ~/syncthing-host/backup/hermes_brain-$(date +%Y-%m-%d).sql.gz

# Только схема (для воспроизведения структуры)
docker exec nocodb-postgres-db pg_dump -U nocodb_user -d hermes_brain --schema-only | gzip > \
  ~/syncthing-host/backup/hermes_brain-schema-$(date +%Y-%m-%d).sql.gz

# Дамп графов AGE (через Cypher export)
docker exec nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c \
  "SELECT * FROM ag_catalog.cypher('code_graph', \$$ MATCH (n) RETURN n \$$) AS (node agtype);" \
  > ~/syncthing-host/backup/code_graph-$(date +%Y-%m-%d).json
```

### 9.2. Восстановление

```bash
# Остановка сервисов кроме PostgreSQL
docker compose stop hermes holix-* openhands portainer

# Восстановление
gunzip -c ~/syncthing-host/backup/hermes_brain-2026-07-05.sql.gz | \
  docker exec -i nocodb-postgres-db psql -U nocodb_user -d hermes_brain

# Перезапуск
docker compose up -d
```

## 10. Что дальше

- **NocoDB как приборная панель** — [docs/05-nocodb-dashboard.md](05-nocodb-dashboard.md)
- **Эталонный API/MCP референс** — [docs/06-api-mcp-reference.md](06-api-mcp-reference.md)
- **Мультитенантность** — [docs/10-multitenancy.md](10-multitenancy.md)
