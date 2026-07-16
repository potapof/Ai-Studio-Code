-- Схема tasks — задачи конвейера Студии программирования
-- База: hermes_brain. Выполнить: psql -U nocodb_user -d hermes_brain < tasks.sql
CREATE TABLE IF NOT EXISTS public.tasks (
    id BIGSERIAL PRIMARY KEY,
    title VARCHAR(500) NOT NULL,
    description TEXT,
    status VARCHAR(50) NOT NULL DEFAULT 'backlog'
        CHECK (status IN ('backlog','maker','checker','arbitrage','done','failed')),
    maker_agent VARCHAR(100),
    checker_agent VARCHAR(100),
    maker_result TEXT,
    checker_verdict VARCHAR(20)
        CHECK (checker_verdict IS NULL OR checker_verdict IN ('PASS','FAIL','NEEDS_HUMAN')),
    handoff_document_id BIGINT REFERENCES public.handoff_documents(id),
    session_id UUID DEFAULT gen_random_uuid(),
    created_at TIMESTAMP DEFAULT now(),
    updated_at TIMESTAMP DEFAULT now(),
    completed_at TIMESTAMP,
    tenant_id VARCHAR(100) DEFAULT 'default'
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON public.tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_tenant ON public.tasks(tenant_id);
CREATE INDEX IF NOT EXISTS idx_tasks_created ON public.tasks(created_at DESC);

COMMENT ON TABLE public.tasks IS 'Задачи конвейера maker-checker-arbitrage';
COMMENT ON COLUMN public.tasks.status IS 'backlog → maker → checker → arbitrage → done / failed';
