-- ============================================================================
-- 05-metrics-views.sql
-- ============================================================================
-- VIEW и MATERIALIZED VIEW для метрик "мозга" Hermes.
-- Агрегируют данные по всем тенантам (студиям).
--
-- Зависимости:
--   - 01-init-convergent-db.sql
--   - 02-brain-tables.sql
--   - 03-tenant-schema-template.sql (для tenant-таблиц: loop_runs, agent_audit_log)
--   - 04-code-graph.sql (для public.code_graph_meta)
--
-- Идемпотентный: повторный запуск не вызывает ошибок (DROP VIEW IF EXISTS).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Вспомогательная функция: собрать loop_runs со всех тенантов
-- ---------------------------------------------------------------------------
-- Динамически UNION-ит studio_<tenant>.loop_runs по всем активным тенантам.
-- Используется в VIEW loop_metrics и loop_health.
CREATE OR REPLACE FUNCTION public.collect_all_loop_runs()
RETURNS TABLE(
    tenant_id           TEXT,
    loop_name           TEXT,
    run_started         TIMESTAMP,
    run_finished        TIMESTAMP,
    status              TEXT,
    trigger_type        TEXT,
    tokens_used         INTEGER,
    cost_usd            DECIMAL(10,4),
    pr_url              TEXT,
    handoff_document_id BIGINT,
    outcome             JSONB
) AS $$
DECLARE
    v_tenant_id TEXT;
    v_schema    TEXT;
    v_sql       TEXT := '';
BEGIN
    FOR v_tenant_id, v_schema IN
        SELECT tenant_id, schema_name FROM public.tenants WHERE is_active
    LOOP
        IF v_sql <> '' THEN
            v_sql := v_sql || ' UNION ALL ';
        END IF;
        v_sql := v_sql || format(
            $f$
            SELECT %L::text AS tenant_id,
                   loop_name, run_started, run_finished,
                   status::text, trigger_type::text,
                   tokens_used, cost_usd, pr_url,
                   handoff_document_id, outcome
              FROM %I.loop_runs
            $f$,
            v_tenant_id,
            v_schema
        );
    END LOOP;

    IF v_sql = '' THEN
        RETURN;  -- нет активных тенантов
    END IF;

    RETURN QUERY EXECUTE v_sql;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION public.collect_all_loop_runs()
    IS 'Динамически собирает loop_runs со всех активных тенантов (UNION ALL по studio_<id>.loop_runs). STABLE.';

-- ===========================================================================
-- 1. public.loop_metrics — еженедельная агрегация по всем тенантам (VIEW)
-- ===========================================================================
DROP VIEW IF EXISTS public.loop_metrics;

CREATE OR REPLACE VIEW public.loop_metrics AS
SELECT
    r.tenant_id,
    r.loop_name,
    date_trunc('week', r.run_started)::date AS week,
    count(*)                                                    AS total_runs,
    count(*) FILTER (WHERE r.status = 'completed')             AS successful_runs,
    count(*) FILTER (WHERE r.status = 'failed')                AS failed_runs,
    count(*) FILTER (WHERE r.status = 'escalated')             AS escalated_runs,
    COALESCE(sum(r.tokens_used), 0)                            AS total_tokens,
    COALESCE(sum(r.cost_usd), 0)                               AS total_cost,
    count(*) FILTER (WHERE r.pr_url IS NOT NULL)               AS prs_opened,
    round(
        100.0 * count(*) FILTER (WHERE r.status = 'completed')
              / NULLIF(count(*), 0),
        2
    )                                                           AS success_rate_pct,
    -- КЛЮЧЕВАЯ метрика: стоимость одного принятого изменения (completed + PR)
    round(
        sum(r.cost_usd) / NULLIF(
            count(*) FILTER (WHERE r.status = 'completed' AND r.pr_url IS NOT NULL),
            0
        ),
        4
    )                                                           AS cost_per_accepted_change,
    round(
        100.0 * count(*) FILTER (WHERE r.status = 'escalated')
              / NULLIF(count(*), 0),
        2
    )                                                           AS escalation_rate_pct
FROM public.collect_all_loop_runs() r
WHERE r.run_started >= NOW() - INTERVAL '90 days'
GROUP BY r.tenant_id, r.loop_name, date_trunc('week', r.run_started);

COMMENT ON VIEW public.loop_metrics IS
    'Еженедельные агрегированные метрики по всем loop всех тенантов. '
    'cost_per_accepted_change — КЛЮЧЕВАЯ метрика эффективности loop.';

GRANT SELECT ON public.loop_metrics TO studio_reader;
GRANT SELECT ON public.loop_metrics TO studio_writer;

-- ===========================================================================
-- 2. public.loop_health — здоровье каждого loop за последние 7 дней (VIEW)
-- ===========================================================================
DROP VIEW IF EXISTS public.loop_health;

CREATE OR REPLACE VIEW public.loop_health AS
WITH recent AS (
    SELECT
        r.tenant_id,
        r.loop_name,
        count(*)                                                    AS runs_7d,
        round(
            100.0 * count(*) FILTER (WHERE r.status = 'completed')
                  / NULLIF(count(*), 0),
            2
        )                                                           AS success_rate_7d,
        round(
            sum(r.cost_usd) / NULLIF(
                count(*) FILTER (WHERE r.status = 'completed' AND r.pr_url IS NOT NULL),
                0
            ),
            4
        )                                                           AS cost_per_change_7d,
        round(
            100.0 * count(*) FILTER (WHERE r.status = 'escalated')
                  / NULLIF(count(*), 0),
            2
        )                                                           AS escalation_rate_7d
    FROM public.collect_all_loop_runs() r
    WHERE r.run_started >= NOW() - INTERVAL '7 days'
    GROUP BY r.tenant_id, r.loop_name
),
last_status AS (
    SELECT DISTINCT ON (r.tenant_id, r.loop_name)
        r.tenant_id,
        r.loop_name,
        r.status AS last_status,
        r.run_started AS last_run_at
    FROM public.collect_all_loop_runs() r
    ORDER BY r.tenant_id, r.loop_name, r.run_started DESC
)
SELECT
    ls.tenant_id,
    ls.loop_name,
    COALESCE(re.runs_7d, 0)           AS runs_7d,
    re.success_rate_7d,
    re.cost_per_change_7d,
    re.escalation_rate_7d,
    ls.last_status,
    ls.last_run_at,
    CASE
        WHEN ls.last_status = 'paused'                          THEN 'paused'
        WHEN re.runs_7d IS NULL OR re.runs_7d = 0               THEN 'healthy'  -- нет активности = нет проблем
        WHEN re.success_rate_7d IS NOT NULL
             AND re.success_rate_7d >= 80
             AND COALESCE(re.escalation_rate_7d, 0) <= 10       THEN 'healthy'
        WHEN re.success_rate_7d IS NOT NULL
             AND re.success_rate_7d >= 50
             AND COALESCE(re.escalation_rate_7d, 0) <= 30       THEN 'needs_attention'
        ELSE                                                          'unhealthy'
    END                                                          AS health_status
FROM last_status ls
LEFT JOIN recent re
    ON re.tenant_id = ls.tenant_id
   AND re.loop_name = ls.loop_name;

COMMENT ON VIEW public.loop_health IS
    'Здоровье каждого loop за последние 7 дней. health_status: healthy|needs_attention|unhealthy|paused.';

GRANT SELECT ON public.loop_health TO studio_reader;
GRANT SELECT ON public.loop_health TO studio_writer;

-- ===========================================================================
-- 3. public.agent_performance — производительность агентов (MATERIALIZED VIEW)
-- ===========================================================================
DROP MATERIALIZED VIEW IF EXISTS public.agent_performance;

CREATE MATERIALIZED VIEW public.agent_performance AS
SELECT
    a.tenant_id,
    a.agent_name,
    count(*)                                                         AS total_requests,
    round(avg(a.tokens_used), 0)                                     AS avg_tokens_per_request,
    round(avg(a.cost_usd), 4)                                        AS avg_cost_per_request,
    round(
        100.0 * count(*) FILTER (WHERE a.result_status = 'success')
              / NULLIF(count(*), 0),
        2
    )                                                                AS success_rate,
    max(a.timestamp)                                                 AS last_active_at
FROM public.api_keys_audit a
WHERE a.timestamp >= NOW() - INTERVAL '30 days'
GROUP BY a.tenant_id, a.agent_name
WITH DATA;

-- Уникальный индекс ОБЯЗАТЕЛЕН для REFRESH CONCURRENTLY
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_performance_key
    ON public.agent_performance (tenant_id, agent_name);

COMMENT ON MATERIALIZED VIEW public.agent_performance IS
    'Производительность агентов за последние 30 дней (агрегация по public.api_keys_audit). '
    'Обновляется через public.refresh_agent_performance().';

GRANT SELECT ON public.agent_performance TO studio_reader;
GRANT SELECT ON public.agent_performance TO studio_writer;

-- ===========================================================================
-- 4. public.knowledge_stats — статистика базы знаний (VIEW)
-- ===========================================================================
DROP VIEW IF EXISTS public.knowledge_stats;

CREATE OR REPLACE VIEW public.knowledge_stats AS
SELECT
    t.tenant_id,
    -- Навыки: tenant-specific + shared (default)
    (SELECT count(*) FROM public.skills s
      WHERE s.tenant_id = t.tenant_id OR s.tenant_id = 'default')        AS total_skills,
    (SELECT count(*) FROM public.skills s
      WHERE (s.tenant_id = t.tenant_id OR s.tenant_id = 'default')
        AND s.status = 'approved')                                       AS approved_skills,
    (SELECT count(*) FROM public.skills s
      WHERE (s.tenant_id = t.tenant_id OR s.tenant_id = 'default')
        AND s.status = 'draft')                                          AS draft_skills,
    -- Handoff-документы
    (SELECT count(*) FROM public.handoff_documents h
      WHERE h.tenant_id = t.tenant_id)                                   AS total_handoff_documents,
    -- Граф кода (глобальный, общий для всех тенантов)
    COALESCE((SELECT total_nodes FROM public.code_graph_meta
               WHERE graph_name = 'code_graph' LIMIT 1), 0)             AS total_code_nodes,
    COALESCE((SELECT total_edges FROM public.code_graph_meta
               WHERE graph_name = 'code_graph' LIMIT 1), 0)             AS total_code_edges,
    -- PLACEHOLDER: средняя similarity последнего RAG-запроса.
    -- Реальное значение проставляется Архивариусом после каждого RAG-поиска
    -- (записывается в public.handoff_documents.metadata или отдельную таблицу).
    NULL::float                                                          AS avg_similarity_score
FROM public.tenants t
WHERE t.is_active;

COMMENT ON VIEW public.knowledge_stats IS
    'Статистика базы знаний по тенантам. total_code_nodes/edges — глобальные (граф общий). '
    'avg_similarity_score — PLACEHOLDER для последнего RAG-запроса.';

GRANT SELECT ON public.knowledge_stats TO studio_reader;
GRANT SELECT ON public.knowledge_stats TO studio_writer;

-- ===========================================================================
-- 5. public.mcp_usage_stats — статистика MCP-серверов (VIEW)
-- ===========================================================================
DROP VIEW IF EXISTS public.mcp_usage_stats;

CREATE OR REPLACE VIEW public.mcp_usage_stats AS
SELECT
    a.mcp_server,
    a.tool_name,
    count(*)                                                         AS total_calls,
    round(
        100.0 * count(*) FILTER (WHERE a.result_status = 'success')
              / NULLIF(count(*), 0),
        2
    )                                                                AS success_rate,
    round(avg(a.duration_ms), 0)                                     AS avg_duration_ms,
    COALESCE(sum(a.tokens_used), 0)                                 AS total_tokens,
    COALESCE(sum(a.cost_usd), 0)                                    AS total_cost,
    max(a.timestamp)                                                 AS last_used_at
FROM public.api_keys_audit a
WHERE a.timestamp >= NOW() - INTERVAL '30 days'
GROUP BY a.mcp_server, a.tool_name;

COMMENT ON VIEW public.mcp_usage_stats IS
    'Статистика использования MCP-серверов и их инструментов за последние 30 дней.';

GRANT SELECT ON public.mcp_usage_stats TO studio_reader;
GRANT SELECT ON public.mcp_usage_stats TO studio_writer;

-- ===========================================================================
-- 6. Функция для REFRESH MATERIALIZED VIEW CONCURRENTLY
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.refresh_agent_performance()
RETURNS BOOLEAN AS $$
BEGIN
    -- CONCURRENTLY требует уникальный индекс (создан выше) и не блокирует чтение.
    -- Если данных ещё нет (VIEW пустой), первый REFRESH CONCURRENTLY упадёт —
    -- поэтому проверяем, был ли уже populated.
    IF EXISTS (SELECT 1 FROM public.agent_performance LIMIT 1) THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY public.agent_performance;
        RAISE NOTICE 'agent_performance обновлён (CONCURRENTLY)';
    ELSE
        REFRESH MATERIALIZED VIEW public.agent_performance;
        RAISE NOTICE 'agent_performance обновлён (первичная загрузка, без CONCURRENTLY)';
    END IF;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.refresh_agent_performance()
    IS 'Обновляет MATERIALIZED VIEW agent_performance. CONCURRENTLY — не блокирует SELECT.';

-- ---------------------------------------------------------------------------
-- 7. Отчёт
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_views_count INTEGER;
    v_mv_count    INTEGER;
    v_funcs_count INTEGER;
BEGIN
    SELECT count(*) INTO v_views_count
      FROM pg_views WHERE schemaname = 'public'
        AND viewname IN ('loop_metrics','loop_health','knowledge_stats','mcp_usage_stats');
    SELECT count(*) INTO v_mv_count
      FROM pg_matviews WHERE schemaname = 'public' AND matviewname = 'agent_performance';
    SELECT count(*) INTO v_funcs_count
      FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
     WHERE n.nspname = 'public'
       AND p.proname IN ('collect_all_loop_runs','refresh_agent_performance');

    RAISE NOTICE '';
    RAISE NOTICE '===== Metrics views созданы =====';
    RAISE NOTICE 'VIEWs         : % (ожидалось 4)', v_views_count;
    RAISE NOTICE 'MATVIEWs      : % (ожидалось 1)', v_mv_count;
    RAISE NOTICE 'Функций-обёрток: % (ожидалось 2)', v_funcs_count;
    RAISE NOTICE '================================';
END $$;
