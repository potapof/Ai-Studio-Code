-- ============================================================================
-- 06-migration-from-nocodb.sql
-- ============================================================================
-- МИГРАЦИЯ с версии 1.0 (NocoDB как мозг) на версию 2.0 (PostgreSQL+pgvector+AGE).
-- Выполняется ОДИН РАЗ при переходе на новую архитектуру.
--
-- Зависимости:
--   - 01-init-convergent-db.sql (расширения, графы, функции)
--   - 02-brain-tables.sql (public.skills, public.handoff_documents, ...)
--   - 03-tenant-schema-template.sql (public.tenants)
--
-- Что делает скрипт:
--   1. Проверяет, что pgvector и AGE установлены (RAISE EXCEPTION если нет)
--   2. Проверяет, существует ли старая БД studio_db (SKIP с WARNING если нет)
--   3. Если studio_db есть: копирует навыки через dblink в public.skills
--   4. Создаёт инструкцию-комментарий для бэкапа старой SQLite NocoDB
--   5. Выводит отчёт о миграции
--   6. Сидирует 10 базовых навыков (если public.skills пуста)
--   7. Сидирует метаданные тенантов (если public.tenants пуста)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Комментарий к БД (новая архитектура)
-- ---------------------------------------------------------------------------
COMMENT ON DATABASE hermes_brain IS
    'Hermes Brain v2.0 — конвергентная БД (PostgreSQL 16 + pgvector + Apache AGE). '
    'АРХИТЕКТУРА v2.0: PostgreSQL — единый "мозг" для AI-агента Hermes; '
    'NocoDB — только UI (приборная панель для человека), читает/пишет в тот же PostgreSQL. '
    'Используется официальный MCP-сервер @modelcontextprotocol/server-postgres. '
    'Мультитенантность: каждая Студия (организация) имеет схему studio_<tenant_id>. '
    'Векторные данные: pgvector (VECTOR(384), all-MiniLM-L6-v2). '
    'Графовые данные: Apache AGE (code_graph — зависимости кода, task_graph — связи задач). '
    'Миграция с v1.0 (NocoDB как мозг) выполнена скриптом 06-migration-from-nocodb.sql.';

-- ---------------------------------------------------------------------------
-- 1. Проверка расширений (КРИТИЧНО)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
        RAISE EXCEPTION 'pgvector не установлен! Запустите 01-init-convergent-db.sql ПЕРЕД миграцией.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'age') THEN
        RAISE EXCEPTION 'Apache AGE не установлен! Запустите 01-init-convergent-db.sql ПЕРЕД миграцией.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto') THEN
        RAISE EXCEPTION 'pgcrypto не установлен! Запустите 01-init-convergent-db.sql ПЕРЕД миграцией.';
    END IF;
    RAISE NOTICE 'Проверка расширений: OK (vector, age, pgcrypto установлены)';
END $$;

-- dblink нужен для кросс-БД миграции (если старая БД ещё живёт в том же кластере)
CREATE EXTENSION IF NOT EXISTS dblink;

-- ---------------------------------------------------------------------------
-- 2. Инструкция по бэкапу старой SQLite NocoDB (v1.0)
-- ---------------------------------------------------------------------------
-- Если по пути /var/lib/studio/nocodb-v1/noco.db есть файл SQLite,
-- перед миграцией ОБЯЗАТЕЛЬНО создайте резервную копию:
--
--   bash:
--     cp /var/lib/studio/nocodb-v1/noco.db /var/lib/studio/nocodb-v1/noco.db.backup.$(date +%Y%m%d)
--     sqlite3 /var/lib/studio/nocodb-v1/noco.db ".dump" > /tmp/nocodb-v1-dump.sql
--
-- После бэкапа старую SQLite можно экспортировать в CSV и импортировать в studio_db
-- (PostgreSQL) через \copy, либо использовать dblink-миграцию ниже.
COMMENT ON SCHEMA public IS
    'v2.0: схема public хранит "мозг" Hermes (skills, handoff_documents, agent_sessions, api_keys_audit, tenants). '
    'Миграция с v1.0: скопируйте SQLite NocoDB → studio_db (PostgreSQL) → dblink → public.skills. '
    'Инструкция по бэкапу SQLite: см. комментарий в 06-migration-from-nocodb.sql.';

-- ===========================================================================
-- 3. Миграция данных из старой БД studio_db (если существует)
-- ===========================================================================
DO $$
DECLARE
    v_old_db_exists BOOLEAN;
    v_conn_ok       BOOLEAN := FALSE;
    v_old_table_ok  BOOLEAN := FALSE;
    v_migrated      INTEGER := 0;
    v_skipped       INTEGER := 0;
BEGIN
    -- Проверяем существование старой БД в текущем кластере
    SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'studio_db')
      INTO v_old_db_exists;

    IF NOT v_old_db_exists THEN
        RAISE WARNING 'Старая БД studio_db не найдена в кластере. Пропуск миграции данных. Будут созданы только seed-навыки.';
        RETURN;
    END IF;

    RAISE NOTICE 'Найдена старая БД studio_db. Начинаю миграцию навыков...';

    -- Подключаемся к старой БД
    BEGIN
        PERFORM dblink_connect('mig_conn', 'dbname=studio_db');
        v_conn_ok := TRUE;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Не удалось подключиться к studio_db: %. Пропуск миграции данных.', SQLERRM;
        RETURN;
    END;

    -- Проверяем существование таблицы skills в старой БД
    BEGIN
        PERFORM * FROM dblink('mig_conn',
            'SELECT 1 FROM information_schema.tables WHERE table_name = ''skills'' LIMIT 1'
        ) AS t(check_val INTEGER);
        v_old_table_ok := FOUND;
    EXCEPTION WHEN OTHERS THEN
        v_old_table_ok := FALSE;
    END;

    IF NOT v_old_table_ok THEN
        RAISE WARNING 'Таблица skills не найдена в studio_db. Пропуск миграции.';
        PERFORM dblink_disconnect('mig_conn');
        RETURN;
    END IF;

    -- 3a. Копируем старые навыки во временную таблицу
    DROP TABLE IF EXISTS public._migration_old_skills;
    CREATE TEMP TABLE public._migration_old_skills AS
    SELECT * FROM dblink('mig_conn',
        'SELECT title, description, content, skill_type, category, tags, source, created_at, updated_at FROM skills'
    ) AS t(
        title        TEXT,
        description  TEXT,
        content      TEXT,
        skill_type   TEXT,
        category     TEXT,
        tags         TEXT[],
        source       TEXT,
        created_at   TIMESTAMP,
        updated_at   TIMESTAMP
    );

    -- 3b. Маппинг и вставка в public.skills
    INSERT INTO public.skills (
        name, description, content_markdown,
        skill_type, category, tags,
        source, status, created_by, tenant_id, version,
        created_at, updated_at
    )
    SELECT
        title,
        COALESCE(description, ''),
        COALESCE(content, ''),
        CASE COALESCE(skill_type, 'reference')
            WHEN 'loop'        THEN 'loop'
            WHEN 'handoff'     THEN 'handoff'
            WHEN 'procedural'  THEN 'procedural'
            ELSE 'reference'
        END,
        CASE COALESCE(category, 'general')
            WHEN 'backend'  THEN 'backend'
            WHEN 'frontend' THEN 'frontend'
            WHEN 'devops'   THEN 'devops'
            WHEN 'security' THEN 'security'
            WHEN 'qa'       THEN 'qa'
            ELSE 'general'
        END,
        tags,
        CASE COALESCE(source, 'manual')
            WHEN 'hermes'   THEN 'hermes'
            WHEN 'openhands' THEN 'openhands'
            WHEN 'soa'      THEN 'soa'
            ELSE 'manual'
        END,
        'approved',           -- все мигрированные навыки сразу approved
        'migration',          -- метка источника миграции
        'default',
        1,
        COALESCE(created_at, NOW()),
        COALESCE(updated_at, NOW())
    FROM public._migration_old_skills
    WHERE title IS NOT NULL AND title <> ''
    ON CONFLICT (name) DO NOTHING;

    GET DIAGNOSTICS v_migrated = ROW_COUNT;

    -- Считаем пропущенные (дубликаты по name)
    SELECT count(*) - v_migrated INTO v_skipped FROM public._migration_old_skills WHERE title IS NOT NULL;

    -- 3c. Генерация embeddings (PLACEHOLDER — реальная генерация через Embedding Service)
    UPDATE public.skills
       SET embedding = public.generate_embedding(content_markdown)
     WHERE embedding IS NULL
       AND created_by = 'migration';

    -- 3d. Очистка временной таблицы
    DROP TABLE IF EXISTS public._migration_old_skills;

    -- Отключение от старой БД
    PERFORM dblink_disconnect('mig_conn');

    RAISE NOTICE '';
    RAISE NOTICE '===== Отчёт о миграции =====';
    RAISE NOTICE 'Перенесено навыков  : %', v_migrated;
    RAISE NOTICE 'Пропущено (дубли)   : %', GREATEST(v_skipped, 0);
    RAISE NOTICE 'Embeddings сгенерировано: PLACEHOLDER (NULL) — запустите Embedding Service позже';
    RAISE NOTICE 'Старая БД studio_db сохранена — можно удалить после проверки';
    RAISE NOTICE '===========================';
END $$;

-- ---------------------------------------------------------------------------
-- 4. Сидирование метаданных тенантов (если public.tenants пуста)
-- ---------------------------------------------------------------------------
INSERT INTO public.tenants (tenant_id, schema_name, name, description, settings)
SELECT
    'default',
    'studio_default',
    'Тестовая Студия (default)',
    'Тестовый тенант для разработки и CI.',
    '{"token_budget_daily": 200000, "cost_limit_daily_usd": 50.0, "allowed_mcp": ["postgres","stackoverflow","github"]}'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM public.tenants LIMIT 1);

-- ---------------------------------------------------------------------------
-- 5. Сидирование 10 базовых навыков (если public.skills пуста)
-- ---------------------------------------------------------------------------
-- Все навыки: status='approved', category='general', source='manual',
-- embedding=NULL (генерируется позже через Embedding Service).
INSERT INTO public.skills
    (name, description, content_markdown, skill_type, category, tags, source, status, created_by, tenant_id, version)
SELECT * FROM (VALUES
    -- 1. FastAPI JWT auth
    (
        'fastapi-jwt-auth'::varchar,
        'Паттерн аутентификации JWT в FastAPI'::text,
        $md$# fastapi-jwt-auth

## Когда применять
Защита эндпоинтов FastAPI через JWT-токены.

## Шаги
1. Установить `python-jose[cryptography]` и `passlib[bcrypt]`.
2. Создать `OAuth2PasswordBearer` dependency.
3. Реализовать `authenticate_user(username, password)` с проверкой через `pwd_context.verify`.
4. Выпустить JWT через `jwt.encode({...}, SECRET_KEY, algorithm="HS256")` с `exp` claim.
5. Создать `get_current_user` dependency, декодирующий токен и возвращающий User.

## Антипаттерны
- Хранить пароли в plain text (всегда bcrypt).
- Использовать симметричный алгоритм без ротации ключа.
- Не проверять `exp` в токене.

## Связанные навыки
- postgresql-pgvector-rag (для поиска похожих паттернов)
$md$::text,
        'procedural'::varchar,
        'general'::varchar,
        ARRAY['fastapi','jwt','auth','security']::text[],
        'manual'::varchar,
        'approved'::varchar,
        'system'::varchar,
        'default'::varchar,
        1
    ),
    -- 2. PostgreSQL pgvector RAG
    (
        'postgresql-pgvector-rag',
        'RAG-поиск через pgvector',
        $md$# postgresql-pgvector-rag

## Когда применять
Поиск релевантных документов/навыков по семантической близости (RAG).

## Шаги
1. Колонка `embedding VECTOR(384)` (all-MiniLM-L6-v2).
2. HNSW-индекс: `CREATE INDEX ... USING hnsw (embedding vector_cosine_ops)`.
3. Генерация embedding через Embedding Service (Python-модель или API).
4. Поиск: `SELECT ... ORDER BY embedding <=> $1 LIMIT 5` (cosine distance).
5. Гибридный поиск: объединить с `pg_trgm` для лексического совпадения через `ts_rank`.

## Метрики
- cosine similarity > 0.75 — релевантно.
- Для 384d и HNSW latency < 5ms на 1M векторов.

## Антипаттерны
- Использовать IVFFlat вместо HNSW для < 1M векторов (HNSW быстрее).
- Забывать `vector_cosine_ops` (по умолчанию L2 — другой результат).
$md$::text,
        'procedural',
        'general',
        ARRAY['pgvector','rag','postgresql','embeddings'],
        'manual',
        'approved',
        'system',
        'default',
        1
    ),
    -- 3. Apache AGE Cypher basics
    (
        'apache-age-cypher-basics',
        'Базовые запросы Cypher в AGE',
        $md$# apache-age-cypher-basics

## Когда применять
Запросы к графу зависимостей кода (code_graph) через Apache AGE.

## Базовый синтаксис
```sql
SELECT * FROM ag_catalog.cypher('code_graph', $$
    MATCH (s:Microservice)-[:DEPENDS_ON]->(l:Library {name: $lib})
    RETURN s.name, s.version
$$, '{"lib": "fastapi"}') AS (name agtype, version agtype);
```

## Параметры
- Передаются третьим аргументом как JSON-строка.
- Доступ в Cypher через `$param_name`.

## Полезные шаблоны
- Variable-length path: `-[r:DEPENDS_ON*1..3]->`
- Кратчайший путь: `shortestPath((a)-[:DEPENDS_ON*..10]->(b))`
- Циклы: `MATCH path = (n)-[:DEPENDS_ON*1..10]->(n)`

## Антипаттерны
- `LOAD 'age'` обязателен в каждой сессии перед использованием.
- `search_path` должен включать `ag_catalog` для типа `agtype`.
- Не использовать `EXECUTE format()` для интерполяции пользовательского ввода в Cypher — только параметрами.
$md$::text,
        'reference',
        'general',
        ARRAY['age','cypher','graph','postgresql'],
        'manual',
        'approved',
        'system',
        'default',
        1
    ),
    -- 4. Hermes Handoff pattern
    (
        'hermes-handoff-pattern',
        'Паттерн HANDOFF.md',
        $md$# hermes-handoff-pattern

## Когда применять
Передача контекста между агентами или сессиями через структурированный HandoffPacket.

## Структура HANDOFF.md
```markdown
# Handoff: <task_name>

## Цель
<краткая цель задачи>

## Выполнено
- <факт 1>
- <факт 2>

## Не выполнено / Заблокировано
- <что осталось> + <причина>

## Ключевые решения
- <решение> + <обоснование>

## Следующие шаги
1. <шаг 1>
2. <шаг 2>

## Контекст для следующего агента
<важные детали, которые нельзя потерять>
```

## Хранение
- HandoffPacket сохраняется в `public.handoff_documents` (JSONB + embedding).
- session_id связывает с `public.agent_sessions`.
- outcome: success | failure | partial | escalated.

## RAG
- Каждый handoff индексируется через pgvector.
- Новый агент перед стартом ищет `MATCH (handoff_documents.embedding) ORDER BY cosine LIMIT 5`.
$md$::text,
        'handoff',
        'general',
        ARRAY['hermes','handoff','context','rag'],
        'manual',
        'approved',
        'system',
        'default',
        1
    ),
    -- 5. Loop engineering Maker-Checker
    (
        'loop-engineering-maker-checker',
        'Maker-Checker split',
        $md$# loop-engineering-maker-checker

## Когда применять
Автоматизация повторяющихся задач через loop с разделением Maker / Checker / Arbiter.

## Роли
- **Maker**: создаёт решение (код, PR, ответ). Например: OpenHands, Hermes-LLM.
- **Checker**: проверяет решение против критериев. Например: holix-qa, линтеры, тесты.
- **Arbiter**: решает, что делать при FAIL — retry или escalate. Всегда Hermes.

## Жизненный цикл
1. Trigger (cron / event / manual) запускает loop.
2. Maker выполняет работу, пишет `maker_output` (JSONB).
3. Checker проверяет, пишет `checker_verdict` (JSONB: pass/fail + причины).
4. Arbiter: pass → open_pr; fail → retry (если attempts < max_retries) или escalate.
5. Финальный outcome записывается в `studio_<t>.loop_runs`.

## Бюджеты
- `token_budget`: лимит токенов на один прогон.
- `cost_limit_usd`: лимит стоимости на один прогон.
- При превышении — эскалация.

## Антипаттерны
- Maker и Checker — один и тот же агент (нет independent verification).
- Arbiter = Maker (конфликт интересов).
- Без `max_retries` — бесконечный loop.
$md$::text,
        'loop',
        'general',
        ARRAY['loop','maker-checker','automation','hermes'],
        'manual',
        'approved',
        'system',
        'default',
        1
    ),
    -- 6. Docker compose multi-tenant
    (
        'docker-compose-multi-tenant',
        'Мультитенантность через схемы',
        $md$# docker-compose-multi-tenant

## Когда применять
Изоляция данных нескольких Студий (организаций) в одном PostgreSQL-кластере.

## Архитектура
- БД: одна (`hermes_brain`).
- Схемы: `public` (общие таблицы) + `studio_<tenant_id>` для каждой Студии.
- Функция `public.create_tenant_schema(tenant_id TEXT)` создаёт схему со всеми таблицами.

## Преимущества
- Дешевле, чем БД-per-tenant (одно подключение, один кэш).
- Проще бэкап: `pg_dump --schema=studio_a`.
- Кросс-тенантные запросы (аналитика) — естественный SQL JOIN.

## Недостатки
- Случайный CROSS--schema запрос при ошибке в search_path.
- Нужно явно выставлять tenant_id в каждой tenant-таблице (для audit и RLS).

## docker-compose.yml
```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: hermes_brain
      POSTGRES_USER: nocodb_user
    volumes:
      - ./init-scripts:/docker-entrypoint-initdb.d
```

## Антипаттерны
- Один пользователь с правами на все схемы (использовать RLS).
- Миграции, затрагивающие `public` без координации между тенантами.
$md$::text,
        'procedural',
        'general',
        ARRAY['docker','multi-tenant','postgresql','devops'],
        'manual',
        'approved',
        'system',
        'default',
        1
    ),
    -- 7. MCP postgres integration
    (
        'mcp-postgres-integration',
        'Подключение postgres MCP к Hermes',
        $md$# mcp-postgres-integration

## Когда применять
Подключение Hermes Agent к PostgreSQL через официальный MCP-сервер.

## Установка
```bash
npm install -g @modelcontextprotocol/server-postgres
```

## Конфигурация Hermes
```json
{
  "mcp_servers": {
    "postgres": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres",
               "postgresql://nocodb_user:***@localhost:5432/hermes_brain"]
    }
  }
}
```

## Доступные инструменты
- `query`: SELECT-запросы (read-only по умолчанию).
- `schema`: просмотр схемы БД.
- `tables`: список таблиц.

## Безопасность
- Использовать роль `studio_reader` для агента по умолчанию.
- `studio_writer` — только для loops, которым нужен INSERT/UPDATE.
- НИКОГДА не передавать пароль суперпользователя в MCP.

## Антипаттерны
- Использовать NocoDB MCP (нестабильный) вместо официального postgres MCP.
- Давать агенту DROP/CREATE права.
$md$::text,
        'procedural',
        'general',
        ARRAY['mcp','postgres','hermes','integration'],
        'manual',
        'approved',
        'system',
        'default',
        1
    ),
    -- 8. SOA hybrid search
    (
        'soa-hybrid-search',
        'Гибридный поиск SOA + PostgreSQL',
        $md$# soa-hybrid-search

## Когда применять
Поиск по базе знаний SOA (Structured Open-ended Answers) с гибридом лексики + семантики.

## Компоненты
1. **Лексический**: `pg_trgm` (trigram similarity) + `tsvector` (full-text).
2. **Семантический**: `pgvector` (cosine similarity, 384d).
3. **Ранжирование**: взвешенная сумма: `0.4 * ts_rank + 0.6 * (1 - cosine_distance)`.

## Запрос
```sql
SELECT id, title,
       0.4 * ts_rank(tsv, query) +
       0.6 * (1 - (embedding <=> $1)) AS hybrid_score
  FROM knowledge
 WHERE tsv @@ query OR embedding <=> $1 < 0.3
 ORDER BY hybrid_score DESC
 LIMIT 10;
```

## Метрики
- Recall@10 > 0.85 на датасете SOA.
- Latency < 50ms для 100k документов.

## Антипаттерны
- Только семантический поиск (теряет точные совпадения имён функций).
- Только лексический (не находит синонимы).
$md$::text,
        'procedural',
        'general',
        ARRAY['soa','hybrid-search','pgvector','pg_trgm'],
        'manual',
        'approved',
        'system',
        'default',
        1
    ),
    -- 9. Workspace jail Holix
    (
        'workspace-jail-holix',
        'Изоляция агентов в Holix',
        $md$# workspace-jail-holix

## Когда применять
Изоляция исполнения агента в sandbox (Holix) для предотвращения случайных разрушений.

## Принципы
1. Каждый агент работает в отдельном worktree git (`worktree/loop-<name>-<run_id>`).
2. Файловая система агента ограничена worktree + read-only mount репозитория.
3. Сетевые запросы — через allow-list доменов.
4. Глобальные инструменты (npm install, pip install) требуют approval.

## Holix-конфигурация
```yaml
jail:
  root: /workspaces/{{run_id}}
  fs:
    - mount: /repo  source: {{repo_path}} mode: ro
    - mount: /work  source: tmpfs  size: 1G
  network:
    allow:
      - github.com
      - pypi.org
    deny: "*"
  exec:
    timeout: 300s
```

## Антипаттерны
- Давать агенту доступ к `~/.ssh` или `~/.aws`.
- Разрешать `git push --force`.
- Запускать агента от root.
$md$::text,
        'procedural',
        'general',
        ARRAY['holix','sandbox','security','isolation'],
        'manual',
        'approved',
        'system',
        'default',
        1
    ),
    -- 10. OpenHands context isolation
    (
        'openhands-context-isolation',
        'Ограниченный контекст для OpenHands',
        $md$# openhands-context-isolation

## Когда применять
Запуск OpenHands как Maker-агента в loop с ограниченным контекстом (для экономии токенов).

## Принципы
1. Передавать в OpenHands только релевантные файлы (по impact_circle из code_graph).
2. Не передавать весь репозиторий — только changed files + их зависимости.
3. Максимальный контекст: 50k токенов (для задач > 50k — escalation).

## Подготовка контекста
```python
# 1. Найти affected files
affected = db.execute("SELECT * FROM find_impact_circle(%s, 3)", [changed_file])
# 2. Собрать контент
context = "\n".join(read_file(f) for f in affected)
# 3. Передать в OpenHands
openhands.run(task_description, context=context, max_tokens=50000)
```

## Метрики
- Median tokens per run: < 30k (для feature-задач).
- Cost per accepted change: < $5.

## Антипаттерны
- Передавать весь репозиторий (теряет фокус, дорого).
- Не указывать `max_tokens` (бесконтрольный расход).
- Игнорировать `find_impact_circle` (агент не видит зависимостей).
$md$::text,
        'reference',
        'general',
        ARRAY['openhands','context','tokens','efficiency'],
        'manual',
        'approved',
        'system',
        'default',
        1
    )
) AS t(name, description, content_markdown, skill_type, category, tags, source, status, created_by, tenant_id, version)
WHERE NOT EXISTS (SELECT 1 FROM public.skills LIMIT 1)
ON CONFLICT (name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. Финальный отчёт о миграции
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_skills_count   INTEGER;
    v_tenants_count  INTEGER;
    v_handoffs_count INTEGER;
    v_sessions_count INTEGER;
    v_old_db_exists  BOOLEAN;
    v_migrated_count INTEGER;
BEGIN
    SELECT count(*) INTO v_skills_count   FROM public.skills;
    SELECT count(*) INTO v_tenants_count  FROM public.tenants;
    SELECT count(*) INTO v_handoffs_count FROM public.handoff_documents;
    SELECT count(*) INTO v_sessions_count FROM public.agent_sessions;
    SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'studio_db') INTO v_old_db_exists;
    SELECT count(*) INTO v_migrated_count FROM public.skills WHERE created_by = 'migration';

    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE '  МИГРАЦИЯ v1.0 → v2.0 ЗАВЕРШЕНА';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Старая БД studio_db найдена    : %', v_old_db_exists;
    IF v_old_db_exists THEN
        RAISE NOTICE 'Навыков мигрировано из studio_db: %', v_migrated_count;
    END IF;
    RAISE NOTICE '----------------------------------------';
    RAISE NOTICE 'Текущее состояние hermes_brain v2.0:';
    RAISE NOTICE '  Навыков в public.skills      : %', v_skills_count;
    RAISE NOTICE '  Тенантов в public.tenants    : %', v_tenants_count;
    RAISE NOTICE '  Handoff-документов           : %', v_handoffs_count;
    RAISE NOTICE '  Сессий агентов               : %', v_sessions_count;
    RAISE NOTICE '----------------------------------------';
    RAISE NOTICE 'СЛЕДУЮЩИЕ ШАГИ:';
    RAISE NOTICE '  1. Запустить Embedding Service для генерации embeddings (skills.embedding IS NULL)';
    RAISE NOTICE '  2. Выполнить SELECT public.create_tenant_schema(''<new_tenant>'') для новых Студий';
    RAISE NOTICE '  3. Подключить NocoDB к hermes_brain (только как UI)';
    RAISE NOTICE '  4. Настроить Hermes MCP на @modelcontextprotocol/server-postgres';
    RAISE NOTICE '  5. После проверки — DROP DATABASE studio_db (старая БД)';
    RAISE NOTICE '========================================';
END $$;
