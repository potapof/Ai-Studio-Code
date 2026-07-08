-- ============================================================================
-- 07-knowledge-base.sql
-- ============================================================================
-- Таблицы базы знаний Студии программирования.
-- Три слоя знаний:
--   public.skills              — «КАК делать» (процедурное знание)
--   public.knowledge_base      — «ЧТО известно» (декларативное знание)
--   public.standards_library   — «ЧТО РЕШИЛИ» (архитектурные решения, ADR)
--
-- Идемпотентный: повторный запуск не вызывает ошибок.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. public.knowledge_base — декларативные знания
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.knowledge_base (
    id              BIGSERIAL PRIMARY KEY,
    title           VARCHAR(200) NOT NULL,
    content         TEXT NOT NULL,
    category        VARCHAR(30) NOT NULL CHECK (category IN (
                        'architecture', 'pattern', 'prompt', 'guardrail',
                        'anti-pattern', 'instruction', 'reference'
                    )),
    tags            TEXT[],
    source_file     VARCHAR(500),       -- из какого файла извлечено
    source_section  VARCHAR(200),       -- раздел/подход внутри файла
    embedding       VECTOR(384),
    status          VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active','deprecated','draft')),
    created_by      VARCHAR(50) DEFAULT 'hermes',
    version         INTEGER DEFAULT 1,
    created_at      TIMESTAMP DEFAULT NOW(),
    updated_at      TIMESTAMP DEFAULT NOW()
);

-- Индексы
CREATE INDEX IF NOT EXISTS idx_kb_category   ON public.knowledge_base (category);
CREATE INDEX IF NOT EXISTS idx_kb_status     ON public.knowledge_base (status);
CREATE INDEX IF NOT EXISTS idx_kb_tags_gin   ON public.knowledge_base USING GIN (tags);

-- HNSW-индекс для семантического поиска по содержимому
CREATE INDEX IF NOT EXISTS idx_kb_embedding_hnsw
    ON public.knowledge_base USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- Триггер автообновления updated_at
DROP TRIGGER IF EXISTS trg_kb_updated_at ON public.knowledge_base;
CREATE TRIGGER trg_kb_updated_at
    BEFORE UPDATE ON public.knowledge_base
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMENT ON TABLE  public.knowledge_base IS
    'База декларативных знаний Студии: паттерны, промпты, guardrails, anti-patterns.';
COMMENT ON COLUMN public.knowledge_base.category IS
    'architecture | pattern | prompt | guardrail | anti-pattern | instruction | reference';
COMMENT ON COLUMN public.knowledge_base.source_file IS
    'Исходный файл, из которого извлечено знание (для трассировки)';

-- ---------------------------------------------------------------------------
-- 2. public.standards_library — архитектурные решения (ADR)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.standards_library (
    id              BIGSERIAL PRIMARY KEY,
    title           VARCHAR(200) NOT NULL,
    decision        TEXT NOT NULL,         -- что решили
    rationale       TEXT NOT NULL,         -- почему
    alternatives    TEXT,                  -- альтернативы, которые отвергли
    consequences    TEXT,                  -- последствия решения
    status          VARCHAR(20) DEFAULT 'proposed' CHECK (status IN (
                        'proposed', 'approved', 'superseded', 'deprecated'
                    )),
    superseded_by   BIGINT REFERENCES public.standards_library(id),
    handoff_id      VARCHAR(50),           -- из какого HANDOFF извлечено
    embedding       VECTOR(384),
    created_by      VARCHAR(50) DEFAULT 'hermes',
    version         INTEGER DEFAULT 1,
    created_at      TIMESTAMP DEFAULT NOW(),
    updated_at      TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_std_status ON public.standards_library (status);

CREATE INDEX IF NOT EXISTS idx_std_embedding_hnsw
    ON public.standards_library USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

DROP TRIGGER IF EXISTS trg_std_updated_at ON public.standards_library;
CREATE TRIGGER trg_std_updated_at
    BEFORE UPDATE ON public.standards_library
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMENT ON TABLE public.standards_library IS
    'Библиотека стандартов и архитектурных решений (ADR).';
COMMENT ON COLUMN public.standards_library.decision IS 'Что решили — суть архитектурного решения';
COMMENT ON COLUMN public.standards_library.rationale IS 'Почему приняли именно это решение';
COMMENT ON COLUMN public.standards_library.alternatives IS 'Какие альтернативы рассматривали и почему отвергли';
COMMENT ON COLUMN public.standards_library.handoff_id IS 'Ссылка на HANDOFF, из которого извлечено решение';

-- ---------------------------------------------------------------------------
-- 3. Отчёт
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_kb_count INTEGER;
    v_std_count INTEGER;
BEGIN
    SELECT count(*) INTO v_kb_count FROM public.knowledge_base;
    SELECT count(*) INTO v_std_count FROM public.standards_library;

    RAISE NOTICE '';
    RAISE NOTICE '===== База знаний создана =====';
    RAISE NOTICE 'knowledge_base    : % записей', v_kb_count;
    RAISE NOTICE 'standards_library : % записей', v_std_count;
    RAISE NOTICE '================================';
END $$;
