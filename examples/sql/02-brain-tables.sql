-- ============================================================================
-- 02-brain-tables.sql
-- ============================================================================
-- Основные таблицы "мозга" Hermes в схеме public.
-- Общие для всех тенантов (мультитенантность через tenant_id).
--
-- Зависимости: должен выполняться ПОСЛЕ 01-init-convergent-db.sql.
-- Идемпотентный: повторный запуск не вызывает ошибок.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. public.skills — библиотека навыков Hermes Agent (Skills System)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.skills (
    id               BIGSERIAL PRIMARY KEY,
    name             VARCHAR(100) UNIQUE NOT NULL,
    description      TEXT NOT NULL,
    content_markdown TEXT NOT NULL,
    skill_type       VARCHAR(30)  NOT NULL CHECK (skill_type IN ('loop','handoff','procedural','reference')),
    category         VARCHAR(50)  NOT NULL CHECK (category IN ('backend','frontend','devops','security','qa','general')),
    tags             TEXT[],
    embedding        VECTOR(384),
    source           VARCHAR(20)  DEFAULT 'manual' CHECK (source IN ('manual','hermes','openhands','soa')),
    status           VARCHAR(20)  DEFAULT 'draft'  CHECK (status IN ('draft','approved','deprecated')),
    created_by       VARCHAR(50)  DEFAULT 'system',
    tenant_id        VARCHAR(50)  DEFAULT 'default',
    version          INTEGER      DEFAULT 1,
    created_at       TIMESTAMP    DEFAULT NOW(),
    updated_at       TIMESTAMP    DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_skills_name     ON public.skills (name);
CREATE INDEX IF NOT EXISTS idx_skills_category ON public.skills (category);
CREATE INDEX IF NOT EXISTS idx_skills_status   ON public.skills (status);
CREATE INDEX IF NOT EXISTS idx_skills_tenant   ON public.skills (tenant_id);
CREATE INDEX IF NOT EXISTS idx_skills_tags_gin ON public.skills USING GIN (tags);

-- HNSW-индекс для cosine RAG-поиска по контенту навыка
CREATE INDEX IF NOT EXISTS idx_skills_embedding_hnsw
    ON public.skills USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

DROP TRIGGER IF EXISTS trg_skills_updated_at ON public.skills;
CREATE TRIGGER trg_skills_updated_at
    BEFORE UPDATE ON public.skills
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMENT ON TABLE  public.skills              IS 'Библиотека навыков Hermes Agent (Skills System). SKILL.md-контент + эмбеддинг для RAG-поиска.';
COMMENT ON COLUMN public.skills.name         IS 'Уникальное имя навыка (slug), например: fastapi-jwt-auth';
COMMENT ON COLUMN public.skills.content_markdown IS 'Полное содержимое SKILL.md (YAML frontmatter + markdown body)';
COMMENT ON COLUMN public.skills.embedding    IS 'Вектор контента (384d, all-MiniLM-L6-v2). NULL до вызова Embedding Service.';
COMMENT ON COLUMN public.skills.source       IS 'Происхождение навыка: manual (человек), hermes (сгенерирован Hermes), openhands, soa (SOA knowledge base)';
COMMENT ON COLUMN public.skills.tenant_id    IS 'Владелец навыка. "default" = общий для всех (cross-tenant)';

-- ---------------------------------------------------------------------------
-- 2. public.handoff_documents — векторная память HDD
-- ---------------------------------------------------------------------------
-- Handoff-Driven Development: все артефакты HandoffPacket сохраняются
-- в векторную БД для последующего RAG-поиска агентом.
CREATE TABLE IF NOT EXISTS public.handoff_documents (
    id                   BIGSERIAL PRIMARY KEY,
    document_type        VARCHAR(30) NOT NULL CHECK (document_type IN
                            ('handoff','decision','lesson','error_pattern','code_snippet','architecture')),
    title                VARCHAR(255) NOT NULL,
    content_markdown     TEXT NOT NULL,
    embedding            VECTOR(384),
    task_id              BIGINT,
    agent_name           VARCHAR(50),
    session_id           UUID,
    handoff_packet       JSONB,
    source_task_description TEXT,
    outcome              VARCHAR(20) CHECK (outcome IN ('success','failure','partial','escalated')),
    tokens_used          INTEGER  DEFAULT 0,
    cost_usd             DECIMAL(10,4) DEFAULT 0,
    tenant_id            VARCHAR(50) DEFAULT 'default',
    created_at           TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_handoff_type      ON public.handoff_documents (document_type);
CREATE INDEX IF NOT EXISTS idx_handoff_agent     ON public.handoff_documents (agent_name);
CREATE INDEX IF NOT EXISTS idx_handoff_tenant    ON public.handoff_documents (tenant_id);
CREATE INDEX IF NOT EXISTS idx_handoff_created   ON public.handoff_documents (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_handoff_embedding_hnsw
    ON public.handoff_documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

COMMENT ON TABLE  public.handoff_documents            IS 'Векторная память HDD: HandoffPacket, decisions, lessons, error patterns, code snippets, architecture notes для RAG';
COMMENT ON COLUMN public.handoff_documents.task_id    IS 'Ссылка на studio_<tenant>.tasks (внешняя, без FK — кросс-схема)';
COMMENT ON COLUMN public.handoff_documents.handoff_packet IS 'Структурированный HandoffPacket по AHP (Agentic Handoff Protocol)';
COMMENT ON COLUMN public.handoff_documents.outcome    IS 'Исход работы агента, породившей этот документ';

-- ---------------------------------------------------------------------------
-- 3. public.agent_sessions — сессии Hermes
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.agent_sessions (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_name           VARCHAR(50) NOT NULL,
    started_at           TIMESTAMP   DEFAULT NOW(),
    finished_at          TIMESTAMP,
    status               VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active','completed','terminated','failed')),
    model_name           VARCHAR(50),
    tokens_input         INTEGER  DEFAULT 0,
    tokens_output        INTEGER  DEFAULT 0,
    cost_usd             DECIMAL(10,4) DEFAULT 0,
    context_compressed   BOOLEAN  DEFAULT FALSE,
    handoff_document_id  BIGINT REFERENCES public.handoff_documents(id) ON DELETE SET NULL,
    tenant_id            VARCHAR(50) DEFAULT 'default',
    metadata             JSONB
);

CREATE INDEX IF NOT EXISTS idx_sessions_agent    ON public.agent_sessions (agent_name);
CREATE INDEX IF NOT EXISTS idx_sessions_started  ON public.agent_sessions (started_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_status   ON public.agent_sessions (status);
CREATE INDEX IF NOT EXISTS idx_sessions_tenant   ON public.agent_sessions (tenant_id);

COMMENT ON TABLE  public.agent_sessions              IS 'Сессии Hermes Agent (одна сессия = один запуск агента с уникальным контекстом)';
COMMENT ON COLUMN public.agent_sessions.handoff_document_id IS 'ID Handoff-документа, если сессия завершилась handoff';
COMMENT ON COLUMN public.agent_sessions.context_compressed IS 'TRUE если контекст был сжат (summarization) из-за превышения лимита токенов';

-- ---------------------------------------------------------------------------
-- 4. public.api_keys_audit — аудит всех API/MCP вызовов
-- ---------------------------------------------------------------------------
-- Партиционирование по неделям: ~12 партиций вперёд + DEFAULT для запоздалых.
-- PK ОБЯЗАТЕЛЬНО включает колонку партиционирования (timestamp).
CREATE TABLE IF NOT EXISTS public.api_keys_audit (
    id            BIGSERIAL,
    timestamp     TIMESTAMP   NOT NULL DEFAULT NOW(),
    agent_name    VARCHAR(50) NOT NULL,
    mcp_server    VARCHAR(50) NOT NULL CHECK (mcp_server IN
                    ('postgres','stackoverflow','github','slack','sentry','nocodb-rest','internal')),
    tool_name     VARCHAR(100) NOT NULL,
    input_params  JSONB,
    output_result JSONB,
    result_status VARCHAR(20) CHECK (result_status IN ('success','failure','blocked','timeout')),
    duration_ms   INTEGER,
    tokens_used   INTEGER  DEFAULT 0,
    cost_usd      DECIMAL(10,4) DEFAULT 0,
    session_id    UUID,
    tenant_id     VARCHAR(50) DEFAULT 'default',
    PRIMARY KEY (id, timestamp)
) PARTITION BY RANGE (timestamp);

COMMENT ON TABLE  public.api_keys_audit          IS 'Аудит всех API/MCP вызовов Hermes Agent. Партиционирование по неделям.';
COMMENT ON COLUMN public.api_keys_audit.input_params  IS 'Входные параметры ВЫЗОВА (после sanitize_for_log — секреты замаскированы)';
COMMENT ON COLUMN public.api_keys_audit.output_result IS 'Результат вызова (после sanitize_for_log)';
COMMENT ON COLUMN public.api_keys_audit.mcp_server IS 'Источник MCP-сервера: postgres, stackoverflow, github, slack, sentry, nocodb-rest, internal';

-- Создание 12 партиций по неделям вперёд через DO-блок с LOOP.
-- Каждая партиция покрывает ровно одну ISO-неделю (понедельник 00:00 – следующий понедельник 00:00).
DO $$
DECLARE
    v_week_start TIMESTAMP;
    v_week_end   TIMESTAMP;
    v_part_name  TEXT;
BEGIN
    -- Начало текущей ISO-недели (понедельник 00:00)
    v_week_start := date_trunc('week', NOW())::timestamp;

    FOR i IN 0..11 LOOP
        v_week_start := date_trunc('week', NOW())::timestamp + (INTERVAL '1 week' * i);
        v_week_end   := v_week_start + INTERVAL '1 week';
        v_part_name  := 'api_keys_audit_w_' || to_char(v_week_start, 'YYYYMMDD');

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS public.%I PARTITION OF public.api_keys_audit
             FOR VALUES FROM (%L) TO (%L)',
            v_part_name, v_week_start, v_week_end
        );
    END LOOP;

    -- DEFAULT-партиция для запоздалых или будущих записей
    EXECUTE 'CREATE TABLE IF NOT EXISTS public.api_keys_audit_default PARTITION OF public.api_keys_audit DEFAULT';
END $$;

-- Индексы на партиционированной таблице автоматически создаются на всех партициях
CREATE INDEX IF NOT EXISTS idx_audit_agent_time   ON public.api_keys_audit (agent_name, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_audit_mcp_time     ON public.api_keys_audit (mcp_server, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_audit_status       ON public.api_keys_audit (result_status);
CREATE INDEX IF NOT EXISTS idx_audit_session      ON public.api_keys_audit (session_id);
CREATE INDEX IF NOT EXISTS idx_audit_tenant_time  ON public.api_keys_audit (tenant_id, timestamp DESC);

-- ---------------------------------------------------------------------------
-- 5. Выдача прав ролям на новые таблицы
-- ---------------------------------------------------------------------------
GRANT SELECT ON public.skills, public.handoff_documents, public.agent_sessions, public.api_keys_audit TO studio_reader;
GRANT SELECT, INSERT, UPDATE, DELETE
    ON public.skills, public.handoff_documents, public.agent_sessions, public.api_keys_audit
    TO studio_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO studio_writer;

-- ---------------------------------------------------------------------------
-- 6. Отчёт
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_skills    INTEGER;
    v_handoffs  INTEGER;
    v_sessions  INTEGER;
    v_audit     INTEGER;
    v_parts     INTEGER;
BEGIN
    SELECT count(*) INTO v_skills   FROM public.skills;
    SELECT count(*) INTO v_handoffs FROM public.handoff_documents;
    SELECT count(*) INTO v_sessions FROM public.agent_sessions;
    SELECT count(*) INTO v_parts    FROM pg_partition_tree('public.api_keys_audit') WHERE isleaf;

    RAISE NOTICE '';
    RAISE NOTICE '===== Brain tables созданы =====';
    RAISE NOTICE 'public.skills           : готово (записей: %)', v_skills;
    RAISE NOTICE 'public.handoff_documents: готово (записей: %)', v_handoffs;
    RAISE NOTICE 'public.agent_sessions   : готово (записей: %)', v_sessions;
    RAISE NOTICE 'public.api_keys_audit   : готово (партиций: %)', v_parts;
    RAISE NOTICE '================================';
END $$;
