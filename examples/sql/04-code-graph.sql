-- ============================================================================
-- 04-code-graph.sql  (переписано под Apache AGE 1.5.0)
-- ============================================================================
-- Граф зависимостей кода через Apache AGE.
-- Граф code_graph создаётся в script 01 (или вручную create_graph).
--
-- ИСПРАВЛЕНО под AGE 1.5.0 (см. PLAN-FIX-AGE-GRAPH.md):
--   * cypher() не принимает params-текст 3-м аргументом → значения инлайним
--     в Cypher-строку через format() + экранирование (helper to_cypher_value).
--   * SET n += $map с параметром не работает → инлайн map-литерал {k:'v'}.
--   * list-comprehension [x IN .. | ..] не поддерживается → nodes(path) + разбор в SQL.
--   * триггер update_updated_at_column ждёт колонку updated_at → добавлена.
--
-- Идемпотентный: повторный запуск не вызывает ошибок (MERGE, IF NOT EXISTS).
-- ДЕМО-ДАННЫЕ НЕ ГРУЗЯТСЯ (граф остаётся чистым; helper-функции готовы к работе).
-- ============================================================================

LOAD 'age';
SET search_path = ag_catalog, public, "$user";

-- ---------------------------------------------------------------------------
-- 1. public.code_graph_meta — метаданные графа кода
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.code_graph_meta (
    id             SERIAL PRIMARY KEY,
    graph_name     VARCHAR(50) DEFAULT 'code_graph',
    last_synced_at TIMESTAMP,
    total_nodes    INTEGER  DEFAULT 0,
    total_edges    INTEGER  DEFAULT 0,
    sync_status    VARCHAR(20) DEFAULT 'pending' CHECK (sync_status IN ('pending','syncing','synced','failed')),
    settings       JSONB,
    updated_at     TIMESTAMP DEFAULT now()          -- нужна для общего триггера update_updated_at_column()
);

-- updated_at для существующей таблицы (если создана раньше без неё)
ALTER TABLE public.code_graph_meta ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP DEFAULT now();

-- Дедуп по graph_name перед уникальным индексом (частичные прогоны могли вставить дубли)
DELETE FROM public.code_graph_meta a
      USING public.code_graph_meta b
      WHERE a.ctid < b.ctid AND a.graph_name = b.graph_name;
CREATE UNIQUE INDEX IF NOT EXISTS uq_code_graph_meta_graph_name ON public.code_graph_meta (graph_name);

DROP TRIGGER IF EXISTS trg_code_graph_meta_updated_at ON public.code_graph_meta;
CREATE TRIGGER trg_code_graph_meta_updated_at
    BEFORE UPDATE ON public.code_graph_meta
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMENT ON TABLE public.code_graph_meta IS 'Метаданные графа зависимостей кода (code_graph через Apache AGE)';

INSERT INTO public.code_graph_meta (graph_name, sync_status, settings)
VALUES ('code_graph', 'pending', '{"exclude_paths": ["node_modules/", "vendor/", ".venv/"], "max_depth": 5}'::jsonb)
ON CONFLICT (graph_name) DO NOTHING;

GRANT SELECT ON public.code_graph_meta TO studio_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.code_graph_meta TO studio_writer;

-- ===========================================================================
-- 2. Хелперы экранирования: jsonb → Cypher-литералы (защита от инъекций)
-- ===========================================================================
-- Значение jsonb → Cypher-литерал ('строка' с экранированием, число/булево как есть).
CREATE OR REPLACE FUNCTION public.to_cypher_value(v jsonb) RETURNS text AS $$
DECLARE q text := chr(39); bs text := chr(92);
BEGIN
    RETURN CASE jsonb_typeof(v)
        WHEN 'string'  THEN q || replace(replace(v #>> '{}', bs, bs||bs), q, bs||q) || q
        WHEN 'number'  THEN v #>> '{}'
        WHEN 'boolean' THEN v #>> '{}'
        WHEN 'null'    THEN 'null'
        ELSE q || replace(replace(v::text, bs, bs||bs), q, bs||q) || q
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION public.to_cypher_value(jsonb) IS 'jsonb-значение → безопасный Cypher-литерал (экранирование кавычек/бэкслэшей)';

-- jsonb-объект → Cypher map-литерал {k1: v1, k2: v2}. Ключи — идентификаторы свойств.
CREATE OR REPLACE FUNCTION public.jsonb_to_cypher_map(p jsonb) RETURNS text AS $$
    SELECT COALESCE('{' || string_agg(key || ': ' || public.to_cypher_value(value), ', ') || '}', '{}')
    FROM jsonb_each(COALESCE(p, '{}'::jsonb));
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION public.jsonb_to_cypher_map(jsonb) IS 'jsonb-объект → Cypher map-литерал {k:''v''} для инлайна в запрос';

-- ===========================================================================
-- 3. Добавление узлов и рёбер (идемпотентно через MERGE)
-- ===========================================================================
-- node_type: Microservice, Library, Function, File, Class. Свойства — jsonb, обязателен "name".
CREATE OR REPLACE FUNCTION public.add_code_node(
    p_graph_name TEXT,
    p_node_type  TEXT,
    p_properties JSONB
) RETURNS ag_catalog.agtype AS $$
DECLARE
    v_result ag_catalog.agtype;
    v_name   TEXT;
BEGIN
    IF p_node_type !~ '^(Microservice|Library|Function|File|Class)$' THEN
        RAISE EXCEPTION 'Недопустимый node_type: %. Допустимо: Microservice, Library, Function, File, Class', p_node_type;
    END IF;
    v_name := p_properties->>'name';
    IF v_name IS NULL THEN
        RAISE EXCEPTION 'Свойство "name" обязательно в p_properties';
    END IF;

    -- Инлайн: имя и свойства как Cypher-литералы (AGE 1.5.0 не берёт map из параметра)
    EXECUTE format(
        'SELECT * FROM ag_catalog.cypher(%L, $cy$ MERGE (n:%s {name: %s}) SET n += %s RETURN n $cy$) AS (n ag_catalog.agtype)',
        p_graph_name,
        p_node_type,
        public.to_cypher_value(to_jsonb(v_name)),
        public.jsonb_to_cypher_map(p_properties)
    ) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql VOLATILE;

COMMENT ON FUNCTION public.add_code_node(TEXT, TEXT, JSONB)
    IS 'Добавляет/обновляет (MERGE по name) узел AGE-графа. node_type: Microservice|Library|Function|File|Class';

-- edge_type: DEPENDS_ON, CALLS, IMPORTS, EXTENDS, IMPLEMENTS, CONTAINS, DEFINED_IN.
CREATE OR REPLACE FUNCTION public.add_code_edge(
    p_graph_name  TEXT,
    p_from_name   TEXT,
    p_to_name     TEXT,
    p_edge_type   TEXT,
    p_properties  JSONB DEFAULT '{}'::jsonb
) RETURNS ag_catalog.agtype AS $$
DECLARE
    v_result ag_catalog.agtype;
    v_set    TEXT;
BEGIN
    IF p_edge_type !~ '^(DEPENDS_ON|CALLS|IMPORTS|EXTENDS|IMPLEMENTS|CONTAINS|DEFINED_IN)$' THEN
        RAISE EXCEPTION 'Недопустимый edge_type: %', p_edge_type;
    END IF;

    -- SET r += {..} только если есть свойства (иначе пустой map допустим, но пропустим для чистоты)
    v_set := CASE WHEN p_properties IS NULL OR p_properties = '{}'::jsonb
                  THEN '' ELSE ' SET r += ' || public.jsonb_to_cypher_map(p_properties) END;

    EXECUTE format(
        'SELECT * FROM ag_catalog.cypher(%L, $cy$ MATCH (a {name: %s}), (b {name: %s}) MERGE (a)-[r:%s]->(b)%s RETURN r $cy$) AS (r ag_catalog.agtype)',
        p_graph_name,
        public.to_cypher_value(to_jsonb(p_from_name)),
        public.to_cypher_value(to_jsonb(p_to_name)),
        p_edge_type,
        v_set
    ) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql VOLATILE;

COMMENT ON FUNCTION public.add_code_edge(TEXT, TEXT, TEXT, TEXT, JSONB)
    IS 'Добавляет/обновляет (MERGE) ребро между узлами AGE-графа по их name';

-- ===========================================================================
-- 4. Аналитические функции (plpgsql + инлайн-литералы)
-- ===========================================================================
-- Микросервисы, зависящие от указанной библиотеки.
CREATE OR REPLACE FUNCTION public.find_services_depending_on(p_library_name TEXT)
RETURNS TABLE(service_name TEXT, service_version TEXT) AS $$
BEGIN
    RETURN QUERY EXECUTE format(
        'SELECT trim(both chr(34) from r.sn::text), trim(both chr(34) from r.sv::text)
         FROM ag_catalog.cypher(%L, $cy$
             MATCH (service:Microservice)-[:DEPENDS_ON]->(lib:Library {name: %s})
             RETURN service.name, service.version
         $cy$) AS r(sn ag_catalog.agtype, sv ag_catalog.agtype)',
        'code_graph',
        public.to_cypher_value(to_jsonb(p_library_name))
    );
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION public.find_services_depending_on(TEXT)
    IS 'Микросервисы, зависящие от библиотеки p_library_name.';

-- Модули, затронутые при изменении файла (impact circle) до глубины p_max_depth.
CREATE OR REPLACE FUNCTION public.find_impact_circle(
    p_file_path TEXT,
    p_max_depth INTEGER DEFAULT 3
) RETURNS TABLE(affected_module TEXT, distance INTEGER) AS $$
BEGIN
    RETURN QUERY EXECUTE format(
        'SELECT trim(both chr(34) from r.am::text), trim(both chr(34) from r.dist::text)::integer
         FROM ag_catalog.cypher(%L, $cy$
             MATCH path = (file:File {path: %s})<-[*1..10]-(affected)
             WHERE file <> affected AND length(path) <= %s
             RETURN distinct affected.name, min(length(path))
         $cy$) AS r(am ag_catalog.agtype, dist ag_catalog.agtype)',
        'code_graph',
        public.to_cypher_value(to_jsonb(p_file_path)),
        GREATEST(1, LEAST(p_max_depth, 10))::text
    );
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION public.find_impact_circle(TEXT, INTEGER)
    IS 'Модули, затронутые при изменении файла, с расстоянием.';

-- Узлы, участвующие в циклических зависимостях (start=end пути). Возврат скаляров (имён).
CREATE OR REPLACE FUNCTION public.find_circular_dependencies()
RETURNS TABLE(node_in_cycle TEXT) AS $$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT DISTINCT trim(both chr(34) from r.nm::text)
         FROM ag_catalog.cypher($cg$code_graph$cg$, $cy$
             MATCH (n)-[*1..10]->(n)
             WHERE n.name IS NOT NULL
             RETURN DISTINCT n.name
         $cy$) AS r(nm ag_catalog.agtype)';
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION public.find_circular_dependencies()
    IS 'Имена узлов, участвующих в циклических зависимостях (путь start=end, до 10 рёбер).';

-- ===========================================================================
-- 5. Заглушка синхронизации с репозиторием
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.sync_code_graph(p_repo_path TEXT)
RETURNS BOOLEAN AS $$
DECLARE v_meta_id INTEGER;
BEGIN
    UPDATE public.code_graph_meta
       SET sync_status = 'pending', last_synced_at = NOW(),
           settings = COALESCE(settings,'{}'::jsonb) || json_build_object('repo_path', p_repo_path)::jsonb
     WHERE graph_name = 'code_graph'
     RETURNING id INTO v_meta_id;
    RAISE NOTICE 'sync_code_graph(%): PLACEHOLDER (реальная синхронизация — через Python-парсер AST).', p_repo_path;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql VOLATILE;

COMMENT ON FUNCTION public.sync_code_graph(TEXT)
    IS 'PLACEHOLDER: синхронизация графа с репозиторием (Python-парсер AST).';

-- ---------------------------------------------------------------------------
-- Обновление счётчиков метаданных (на текущем — возможно пустом — графе)
-- ---------------------------------------------------------------------------
DO $meta$
DECLARE v_nodes INTEGER; v_edges INTEGER;
BEGIN
    LOAD 'age';
    EXECUTE 'SELECT count(*)::int FROM ag_catalog.cypher($cg$code_graph$cg$, $cy$ MATCH (n) RETURN n $cy$) AS (n ag_catalog.agtype)' INTO v_nodes;
    EXECUTE 'SELECT count(*)::int FROM ag_catalog.cypher($cg$code_graph$cg$, $cy$ MATCH ()-[r]->() RETURN r $cy$) AS (r ag_catalog.agtype)' INTO v_edges;
    UPDATE public.code_graph_meta
       SET total_nodes = v_nodes, total_edges = v_edges,
           sync_status = 'synced', last_synced_at = NOW()
     WHERE graph_name = 'code_graph';
    RAISE NOTICE 'code_graph: узлов=%, рёбер=%', v_nodes, v_edges;
END $meta$;
