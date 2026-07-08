-- ============================================================================
-- 01-init-convergent-db.sql
-- ============================================================================
-- Инициализация конвергентной БД "hermes_brain" (PostgreSQL 16 + pgvector + Apache AGE)
-- База данных: hermes_brain
-- Пользователь: nocodb_user
--
-- Версия 2.0: PostgreSQL выступает единым "мозгом" для AI-агента (Hermes),
-- а NocoDB используется только как UI (приборная панель для человека).
-- Конвергентная БД хранит реляционные + векторные + графовые данные в одном движке.
--
-- Идемпотентный: повторный запуск не вызывает ошибок.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Расширения
-- ---------------------------------------------------------------------------

-- pgvector: векторные Embeddings для RAG-поиска по навыкам и HANDOFF-документам
CREATE EXTENSION IF NOT EXISTS vector;

-- Apache AGE: графовая БД поверх PostgreSQL для графа зависимостей кода
CREATE EXTENSION IF NOT EXISTS age;

-- Загрузка AGE в текущую сессию (требуется перед работой с Cypher)
LOAD 'age';

-- Путь поиска: ag_catalog имеет приоритет для Cypher-функций
SET search_path = ag_catalog, "$user", public;

-- pg_trgm: триграммы для fuzzy-полнотекстового поиска по именам навыков и кода
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- pgcrypto: gen_random_uuid() для session_id и request_id
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- 2. Графы Apache AGE
-- ---------------------------------------------------------------------------

-- Граф зависимостей кода (Microservice → Library → Function → File)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'code_graph'
    ) THEN
        PERFORM ag_catalog.create_graph('code_graph');
        RAISE NOTICE 'Создан граф code_graph';
    ELSE
        RAISE NOTICE 'Граф code_graph уже существует — пропуск';
    END IF;
END $$;

-- Граф связей между задачами (Task → Task, Task → Skill, Task → HandoffDocument)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'task_graph'
    ) THEN
        PERFORM ag_catalog.create_graph('task_graph');
        RAISE NOTICE 'Создан граф task_graph';
    ELSE
        RAISE NOTICE 'Граф task_graph уже существует — пропуск';
    END IF;
END $$;

-- Возвращаем search_path в нормальное состояние
SET search_path = public, ag_catalog;

-- ---------------------------------------------------------------------------
-- 3. Роли для мультитенантного доступа
-- ---------------------------------------------------------------------------

-- studio_reader: только чтение (для аналитических запросов, BI, readonly UI)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'studio_reader') THEN
        CREATE ROLE studio_reader LOGIN
            PASSWORD 'change_me_reader'
            CONNECTION LIMIT 20;
        RAISE NOTICE 'Создана роль studio_reader';
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO studio_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO studio_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO studio_reader;

-- studio_writer: полный CRUD для Hermes Agent и NocoDB
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'studio_writer') THEN
        CREATE ROLE studio_writer LOGIN
            PASSWORD 'change_me_writer'
            CONNECTION LIMIT 50;
        RAISE NOTICE 'Создана роль studio_writer';
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO studio_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO studio_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO studio_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO studio_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO studio_writer;

-- ---------------------------------------------------------------------------
-- 4. Сервисные функции
-- ---------------------------------------------------------------------------

-- Автообновление updated_at через триггер
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.update_updated_at_column()
    IS 'Триггерная функция для автообновления колонки updated_at';

-- Маскирование секретов в логах и audit-таблицах.
-- IMMUTABLE: результат зависит только от аргумента, можно индексировать и кэшировать.
-- Маскируются паттерны: sk-*, ghp_*, xox[baprs]-*, Bearer, password=, token=, api_key=
CREATE OR REPLACE FUNCTION public.sanitize_for_log(input_text TEXT)
RETURNS TEXT AS $$
BEGIN
    IF input_text IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN regexp_replace(
        regexp_replace(
            regexp_replace(
                regexp_replace(
                    regexp_replace(
                        regexp_replace(
                            regexp_replace(
                                input_text,
                                -- OpenAI-style: sk-...
                                '(sk-[A-Za-z0-9_\-]{6})[A-Za-z0-9_\-]+', '\1***REDACTED***', 'g'
                            ),
                            -- GitHub Personal Access Token: ghp_...
                            '(ghp_[A-Za-z0-9]{6})[A-Za-z0-9]+', '\1***REDACTED***', 'g'
                        ),
                        -- Slack tokens: xox[baprs]-...
                        '(xox[baprs]-[A-Za-z0-9\-]{6})[A-Za-z0-9\-]+', '\1***REDACTED***', 'g'
                    ),
                    -- HTTP Authorization Bearer
                    '(Bearer\s+)[A-Za-z0-9_\-\.]+', '\1***REDACTED***', 'g'
                ),
                -- password=... (в connection strings и формах)
                '(password\s*=\s*)[^\s;'',]+', '\1***REDACTED***', 'gi'
            ),
            -- token=... (в query string и JSON)
            '(token\s*=\s*)[^\s;'',]+', '\1***REDACTED***', 'gi'
        ),
        -- api_key=...
        '(api_key\s*=\s*)[^\s;'',]+', '\1***REDACTED***', 'gi'
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION public.sanitize_for_log(TEXT)
    IS 'Маскирует секреты (API-ключи, токены, пароли) в тексте для логов. IMMUTABLE.';

-- Обёртка для будущей интеграции с Python-моделью эмбеддингов.
-- Сейчас возвращает NULL — реальная генерация выполняется Архивариусом или
-- отдельным Embedding Service через SQL-функцию на PL/Python или RPC.
-- Размерность: 384 (соответствует схеме all-MiniLM-L6-v2 и колонке VECTOR(384)).
CREATE OR REPLACE FUNCTION public.generate_embedding(input_text TEXT)
RETURNS vector AS $$
BEGIN
    -- PLACEHOLDER: здесь будет вызов Python-модели, например:
    --   SELECT plpy.execute(...) для PL/Python или
    --   http-вызов к Embedding Service через pg_http или rust extension.
    -- Пока возвращаем NULL — эмбеддинги проставляются внешним сервисом.
    RETURN NULL::vector;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION public.generate_embedding(TEXT)
    IS 'PLACEHOLDER: обёртка для генерации embeddings. Реальная генерация через Embedding Service (Python-модель all-MiniLM-L6-v2, размерность 384).';

-- ---------------------------------------------------------------------------
-- 5. Метаданные БД
-- ---------------------------------------------------------------------------

COMMENT ON DATABASE hermes_brain IS
    'Hermes Brain v2.0 — конвергентная БД (PostgreSQL 16 + pgvector + Apache AGE). '
    'Единый "мозг" для AI-агента Hermes. NocoDB используется только как UI. '
    'Мультитенантность: каждая Студия (организация) имеет схему studio_<tenant_id>.';

-- ---------------------------------------------------------------------------
-- 6. Отчёт об инициализации
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    v_ext_vector  TEXT;
    v_ext_age     TEXT;
    v_ext_trgm    TEXT;
    v_ext_crypto  TEXT;
    v_graph_count INTEGER;
BEGIN
    SELECT extversion INTO v_ext_vector FROM pg_extension WHERE extname = 'vector';
    SELECT extversion INTO v_ext_age    FROM pg_extension WHERE extname = 'age';
    SELECT extversion INTO v_ext_trgm   FROM pg_extension WHERE extname = 'pg_trgm';
    SELECT extversion INTO v_ext_crypto FROM pg_extension WHERE extname = 'pgcrypto';
    SELECT count(*)   INTO v_graph_count FROM ag_catalog.ag_graph;

    RAISE NOTICE '';
    RAISE NOTICE '===== Инициализация hermes_brain завершена =====';
    RAISE NOTICE 'vector    : %', COALESCE(v_ext_vector,  'ОТСУТСТВУЕТ');
    RAISE NOTICE 'age       : %', COALESCE(v_ext_age,     'ОТСУТСТВУЕТ');
    RAISE NOTICE 'pg_trgm   : %', COALESCE(v_ext_trgm,    'ОТСУТСТВУЕТ');
    RAISE NOTICE 'pgcrypto  : %', COALESCE(v_ext_crypto,  'ОТСУТСТВУЕТ');
    RAISE NOTICE 'Графов AGE: %', v_graph_count;
    RAISE NOTICE 'Роли      : studio_reader, studio_writer';
    RAISE NOTICE '===============================================';
END $$;
