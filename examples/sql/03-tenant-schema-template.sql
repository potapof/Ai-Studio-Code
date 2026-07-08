-- ============================================================================
-- 03-tenant-schema-template.sql
-- ============================================================================
-- Шаблон схемы одного тенанта (Студии) + функция create_tenant_schema().
-- Создаёт схему studio_default (тестовый тенант) и регистрирует её в public.tenants.
--
-- Зависимости: должен выполняться ПОСЛЕ 01-init-convergent-db.sql и 02-brain-tables.sql.
-- Идемпотентный: повторный запуск не вызывает ошибок.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. public.tenants — реестр всех тенантов
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tenants (
    id          SERIAL PRIMARY KEY,
    tenant_id   VARCHAR(50) UNIQUE NOT NULL,
    schema_name VARCHAR(100) NOT NULL,
    name        VARCHAR(100) NOT NULL,
    description TEXT,
    created_at  TIMESTAMP   DEFAULT NOW(),
    is_active   BOOLEAN     DEFAULT TRUE,
    settings    JSONB
);

DROP TRIGGER IF EXISTS trg_tenants_updated_at ON public.tenants;
CREATE TRIGGER trg_tenants_updated_at
    BEFORE UPDATE ON public.tenants
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMENT ON TABLE  public.tenants            IS 'Реестр всех Студий (тенантов). Один тенант = одна схема studio_<tenant_id>.';
COMMENT ON COLUMN public.tenants.tenant_id  IS 'Уникальный идентификатор тенанта, например: default, studio_a, studio_b';
COMMENT ON COLUMN public.tenants.schema_name IS 'Имя схемы PostgreSQL: studio_<tenant_id>';
COMMENT ON COLUMN public.tenants.settings   IS 'Лимиты токенов, стоимости, разрешённые MCP-серверы (JSONB)';

-- Тестовый тенант 'default'
INSERT INTO public.tenants (tenant_id, schema_name, name, description, settings)
VALUES (
    'default',
    'studio_default',
    'Тестовая Студия (default)',
    'Тестовый тенант для разработки и CI. Не используется в production.',
    '{"token_budget_daily": 200000, "cost_limit_daily_usd": 50.0, "allowed_mcp": ["postgres","stackoverflow","github"]}'::jsonb
)
ON CONFLICT (tenant_id) DO NOTHING;

GRANT SELECT ON public.tenants TO studio_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenants TO studio_writer;
GRANT USAGE, SELECT ON SEQUENCE public.tenants_id_seq TO studio_writer;

-- ===========================================================================
-- 2. Функция создания новой схемы тенанта
-- ===========================================================================
-- Принимает tenant_id, формирует имя схемы studio_<tenant_id>,
-- создаёт все tenant-таблицы, выдаёт права studio_writer,
-- регистрирует тенант в public.tenants, возвращает TRUE при успехе.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.create_tenant_schema(p_tenant_id TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_schema TEXT;
    v_loop_i INTEGER;
    v_month_start TIMESTAMP;
    v_month_end   TIMESTAMP;
    v_part_name   TEXT;
BEGIN
    IF p_tenant_id IS NULL OR p_tenant_id !~ '^[a-z0-9_]+$' THEN
        RAISE EXCEPTION 'Некорректный tenant_id: %. Допускаются только строчные буквы, цифры и _', p_tenant_id;
    END IF;

    v_schema := 'studio_' || p_tenant_id;
    RAISE NOTICE 'Создаётся схема %', v_schema;

    -- 1. CREATE SCHEMA
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema);

    -- 2. Все таблицы тенанта создаются через динамический SQL

    -- 2.1 projects
    EXECUTE format($f$
        CREATE TABLE IF NOT EXISTS %I.projects (
            id            SERIAL PRIMARY KEY,
            name          VARCHAR(100) NOT NULL,
            description   TEXT,
            repo_url      TEXT,
            default_branch VARCHAR(100) DEFAULT 'main',
            status        VARCHAR(20)  DEFAULT 'active',
            created_at    TIMESTAMP    DEFAULT NOW(),
            updated_at    TIMESTAMP    DEFAULT NOW()
        );
        DROP TRIGGER IF EXISTS trg_projects_updated_at ON %I.projects;
        CREATE TRIGGER trg_projects_updated_at
            BEFORE UPDATE ON %I.projects
            FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
        CREATE INDEX IF NOT EXISTS idx_projects_name   ON %I.projects (name);
        CREATE INDEX IF NOT EXISTS idx_projects_status ON %I.projects (status);
        COMMENT ON TABLE %I.projects IS 'Проекты Студии (репозитории, над которыми работает Hermes)';
    $f$, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema);

    -- 2.2 tasks
    EXECUTE format($f$
        CREATE TABLE IF NOT EXISTS %I.tasks (
            id                 BIGSERIAL PRIMARY KEY,
            external_id        VARCHAR(100),
            title              VARCHAR(255) NOT NULL,
            description        TEXT,
            status             VARCHAR(20) DEFAULT 'open' CHECK (status IN
                                 ('open','in_progress','review','done','cancelled','escalated')),
            priority           VARCHAR(10) DEFAULT 'normal' CHECK (priority IN
                                 ('low','normal','high','critical')),
            assignee_agent     VARCHAR(50),
            created_by         VARCHAR(50) DEFAULT 'human',
            task_type          VARCHAR(30) CHECK (task_type IN
                                 ('feature','bug','refactor','test','docs','dependency','security')),
            acceptance_criteria TEXT[],
            estimated_tokens   INTEGER,
            actual_tokens      INTEGER  DEFAULT 0,
            actual_cost_usd    DECIMAL(10,4) DEFAULT 0,
            pr_url             TEXT,
            worktree_path      TEXT,
            parent_task_id     BIGINT REFERENCES %I.tasks(id) ON DELETE SET NULL,
            skill_ids          BIGINT[],
            handoff_document_id BIGINT,
            created_at         TIMESTAMP DEFAULT NOW(),
            started_at         TIMESTAMP,
            finished_at        TIMESTAMP,
            updated_at         TIMESTAMP DEFAULT NOW()
        );
        DROP TRIGGER IF EXISTS trg_tasks_updated_at ON %I.tasks;
        CREATE TRIGGER trg_tasks_updated_at
            BEFORE UPDATE ON %I.tasks
            FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
        CREATE INDEX IF NOT EXISTS idx_tasks_status    ON %I.tasks (status);
        CREATE INDEX IF NOT EXISTS idx_tasks_priority  ON %I.tasks (priority);
        CREATE INDEX IF NOT EXISTS idx_tasks_assignee  ON %I.tasks (assignee_agent);
        CREATE INDEX IF NOT EXISTS idx_tasks_external  ON %I.tasks (external_id);
        CREATE INDEX IF NOT EXISTS idx_tasks_skills_gin ON %I.tasks USING GIN (skill_ids);
        COMMENT ON TABLE  %I.tasks                  IS 'Задачи Студии. external_id — номер issue/PR во внешней системе (GitHub, Linear).';
        COMMENT ON COLUMN %I.tasks.skill_ids        IS 'Массив ID навыков из public.skills, использованных при исполнении задачи';
        COMMENT ON COLUMN %I.tasks.handoff_document_id IS 'ID Handoff-документа в public.handoff_documents (без FK — кросс-схема)';
    $f$, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema);

    -- 2.3 loop_runs
    EXECUTE format($f$
        CREATE TABLE IF NOT EXISTS %I.loop_runs (
            id                BIGSERIAL PRIMARY KEY,
            loop_name         VARCHAR(100) NOT NULL,
            run_started       TIMESTAMP   DEFAULT NOW(),
            run_finished      TIMESTAMP,
            status            VARCHAR(20) DEFAULT 'running' CHECK (status IN
                                ('running','completed','failed','escalated','paused')),
            trigger_type      VARCHAR(20) CHECK (trigger_type IN
                                ('cron','event','manual','condition')),
            trigger_details   JSONB,
            worktree_path     TEXT,
            attempts          INTEGER  DEFAULT 0,
            tokens_used       INTEGER  DEFAULT 0,
            cost_usd          DECIMAL(10,4) DEFAULT 0,
            pr_url            TEXT,
            maker_output      JSONB,
            checker_verdict   JSONB,
            outcome           JSONB,
            lessons_learned   TEXT,
            handoff_document_id BIGINT,
            error_message     TEXT,
            updated_at        TIMESTAMP DEFAULT NOW()
        );
        DROP TRIGGER IF EXISTS trg_loop_runs_updated_at ON %I.loop_runs;
        CREATE TRIGGER trg_loop_runs_updated_at
            BEFORE UPDATE ON %I.loop_runs
            FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
        CREATE INDEX IF NOT EXISTS idx_loop_runs_name_time ON %I.loop_runs (loop_name, run_started DESC);
        CREATE INDEX IF NOT EXISTS idx_loop_runs_status    ON %I.loop_runs (status);
        CREATE INDEX IF NOT EXISTS idx_loop_runs_trigger   ON %I.loop_runs (trigger_type);
        COMMENT ON TABLE %I.loop_runs IS 'История прогонов loop (Maker-Checker-Arbiter циклы)';
    $f$, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema);

    -- 2.4 loop_lessons
    EXECUTE format($f$
        CREATE TABLE IF NOT EXISTS %I.loop_lessons (
            id            SERIAL PRIMARY KEY,
            loop_name     VARCHAR(100) NOT NULL,
            lesson        TEXT NOT NULL,
            discovered_at TIMESTAMP   DEFAULT NOW(),
            applied       BOOLEAN     DEFAULT FALSE,
            applied_at    TIMESTAMP,
            skill_id      BIGINT REFERENCES public.skills(id) ON DELETE SET NULL,
            pattern_count INTEGER     DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS idx_loop_lessons_name_time ON %I.loop_lessons (loop_name, discovered_at DESC);
        CREATE INDEX IF NOT EXISTS idx_loop_lessons_applied   ON %I.loop_lessons (applied);
        COMMENT ON TABLE %I.loop_lessons IS 'Извлечённые уроки из прогонов loop. skill_id — навык, в который урок уже встроен (NULL = ждёт интеграции)';
    $f$, v_schema, v_schema, v_schema);

    -- 2.5 loop_progress
    EXECUTE format($f$
        CREATE TABLE IF NOT EXISTS %I.loop_progress (
            id                  SERIAL PRIMARY KEY,
            loop_name           VARCHAR(100) UNIQUE NOT NULL,
            last_run            TIMESTAMP,
            last_status         VARCHAR(20),
            in_progress         JSONB,
            completed_today     JSONB,
            escalated_to_humans JSONB,
            progress_markdown   TEXT,
            updated_at          TIMESTAMP DEFAULT NOW()
        );
        DROP TRIGGER IF EXISTS trg_loop_progress_updated_at ON %I.loop_progress;
        CREATE TRIGGER trg_loop_progress_updated_at
            BEFORE UPDATE ON %I.loop_progress
            FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
        COMMENT ON TABLE %I.loop_progress IS 'Состояние PROGRESS.md для каждого loop. Обновляется в конце каждого прогона.';
    $f$, v_schema, v_schema, v_schema);

    -- 2.6 loop_registry
    EXECUTE format($f$
        CREATE TABLE IF NOT EXISTS %I.loop_registry (
            id              SERIAL PRIMARY KEY,
            name            VARCHAR(100) UNIQUE NOT NULL,
            skill_path      TEXT NOT NULL,
            maker_agent     VARCHAR(50) NOT NULL,
            checker_agent   VARCHAR(50) NOT NULL,
            arbiter_agent   VARCHAR(50) DEFAULT 'hermes',
            max_retries     INTEGER  DEFAULT 3,
            token_budget    INTEGER  DEFAULT 50000,
            cost_limit_usd  DECIMAL(10,4) DEFAULT 2.00,
            enabled         BOOLEAN  DEFAULT TRUE,
            triggers        JSONB    NOT NULL,
            stop_conditions JSONB,
            created_at      TIMESTAMP DEFAULT NOW(),
            updated_at      TIMESTAMP DEFAULT NOW()
        );
        DROP TRIGGER IF EXISTS trg_loop_registry_updated_at ON %I.loop_registry;
        CREATE TRIGGER trg_loop_registry_updated_at
            BEFORE UPDATE ON %I.loop_registry
            FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
        COMMENT ON TABLE  %I.loop_registry              IS 'Реестр всех loop Студии. Точка истины для loop-engine.';
        COMMENT ON COLUMN %I.loop_registry.skill_path   IS 'Путь к SKILL.md, описывающему loop (например: examples/skills/dependency-update/SKILL.md)';
        COMMENT ON COLUMN %I.loop_registry.triggers     IS 'JSONB: cron-расписание или event-condition для запуска loop';
    $f$, v_schema, v_schema, v_schema);

    -- 2.7 agent_audit_log (партиционирование по месяцам)
    EXECUTE format($f$
        CREATE TABLE IF NOT EXISTS %I.agent_audit_log (
            id             BIGSERIAL,
            timestamp      TIMESTAMP   NOT NULL DEFAULT NOW(),
            agent_name     VARCHAR(50) NOT NULL,
            action_type    VARCHAR(30) NOT NULL CHECK (action_type IN
                             ('command_exec','file_read','file_write','api_call',
                              'network_request','skill_install','permission_change','mcp_tool_call')),
            action_target  TEXT,
            action_params  JSONB,
            result_status  VARCHAR(20) CHECK (result_status IN ('success','failure','blocked')),
            result_details JSONB,
            ip_address     INET,
            session_id     UUID,
            request_id     UUID,
            PRIMARY KEY (id, timestamp)
        ) PARTITION BY RANGE (timestamp);
        COMMENT ON TABLE %I.agent_audit_log IS 'Аудит действий агентов в Студии. Партиционирование по месяцам. PK включает timestamp.';
    $f$, v_schema);

    -- 12 партиций по месяцам
    v_month_start := date_trunc('month', NOW())::timestamp;
    FOR v_loop_i IN 0..11 LOOP
        v_month_end   := date_trunc('month', NOW())::timestamp
                       + (INTERVAL '1 month' * (v_loop_i + 1));
        v_month_start := date_trunc('month', NOW())::timestamp
                       + (INTERVAL '1 month' * v_loop_i);
        v_part_name   := 'agent_audit_log_m_' || to_char(v_month_start, 'YYYYMM');

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.%I PARTITION OF %I.agent_audit_log
             FOR VALUES FROM (%L) TO (%L)',
            v_schema, v_part_name, v_schema, v_month_start, v_month_end
        );
    END LOOP;

    -- DEFAULT-партиция
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I.agent_audit_log_default PARTITION OF %I.agent_audit_log DEFAULT',
        v_schema, v_schema
    );

    -- Индексы на партиционированной таблице
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_audit_log_agent_time ON %I.agent_audit_log (agent_name, timestamp DESC)', v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_audit_log_action     ON %I.agent_audit_log (action_type)', v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_audit_log_status     ON %I.agent_audit_log (result_status)', v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_audit_log_session    ON %I.agent_audit_log (session_id)', v_schema);

    -- 3. Права для studio_writer
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO studio_writer', v_schema);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO studio_reader', v_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO studio_writer', v_schema);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO studio_reader', v_schema);
    EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO studio_writer', v_schema);

    -- 4. Регистрация в public.tenants (если ещё не зарегистрирован)
    INSERT INTO public.tenants (tenant_id, schema_name, name, description, settings)
    VALUES (
        p_tenant_id,
        v_schema,
        'Студия ' || p_tenant_id,
        'Автоматически создан через create_tenant_schema()',
        '{"token_budget_daily": 200000, "cost_limit_daily_usd": 50.0}'::jsonb
    )
    ON CONFLICT (tenant_id) DO NOTHING;

    RAISE NOTICE 'Схема % успешно создана и зарегистрирована', v_schema;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.create_tenant_schema(TEXT)
    IS 'Создаёт схему studio_<tenant_id> со всеми таблицами тенанта и регистрирует в public.tenants. Идемпотентна.';

-- ===========================================================================
-- 3. Создание тестового тенанта 'default'
-- ===========================================================================
SELECT public.create_tenant_schema('default');

-- ---------------------------------------------------------------------------
-- 4. Отчёт
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_tenants    INTEGER;
    v_default_ok BOOLEAN;
BEGIN
    SELECT count(*) INTO v_tenants FROM public.tenants;
    SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'studio_default') INTO v_default_ok;

    RAISE NOTICE '';
    RAISE NOTICE '===== Tenant template инициализирован =====';
    RAISE NOTICE 'Тенантов зарегистрировано: %', v_tenants;
    RAISE NOTICE 'Схема studio_default создана: %', v_default_ok;
    RAISE NOTICE 'Функция create_tenant_schema() готова к использованию';
    RAISE NOTICE '==========================================';
END $$;
