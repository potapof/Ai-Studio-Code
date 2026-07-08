-- ============================================================================
-- 04-code-graph.sql
-- ============================================================================
-- Граф зависимостей кода через Apache AGE.
-- Граф code_graph уже создан в script 01.
--
-- Содержит:
--   1. Метаданные графа (public.code_graph_meta)
--   2. Cypher-обёртки для удобного вызова из PL/pgSQL
--   3. Демо-данные: микросервисы, библиотеки, функции, файлы
--
-- Зависимости: должен выполняться ПОСЛЕ 01-init-convergent-db.sql.
-- Идемпотентный: повторный запуск не вызывает ошибок (MERGE вместо CREATE).
-- ============================================================================

-- Загрузка AGE и установка пути поиска (на случай, если сессия новая)
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
    settings       JSONB
);

DROP TRIGGER IF EXISTS trg_code_graph_meta_updated_at ON public.code_graph_meta;
CREATE TRIGGER trg_code_graph_meta_updated_at
    BEFORE UPDATE ON public.code_graph_meta
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMENT ON TABLE  public.code_graph_meta              IS 'Метаданные графа зависимостей кода (code_graph через Apache AGE)';
COMMENT ON COLUMN public.code_graph_meta.total_nodes  IS 'Количество узлов в графе (обновляется после sync)';
COMMENT ON COLUMN public.code_graph_meta.settings     IS 'Исключения (например, node_modules/, vendor/) и правила синхронизации';

-- Начальная запись метаданных
INSERT INTO public.code_graph_meta (graph_name, sync_status, settings)
VALUES ('code_graph', 'pending', '{"exclude_paths": ["node_modules/", "vendor/", ".venv/"], "max_depth": 5}'::jsonb)
ON CONFLICT DO NOTHING;

GRANT SELECT ON public.code_graph_meta TO studio_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.code_graph_meta TO studio_writer;

-- ===========================================================================
-- 2. Низкоуровневые функции для добавления узлов и рёбер
-- ===========================================================================

-- Добавить узел в граф. node_type: Microservice, Library, Function, File, Class.
-- Использует MERGE по свойству "name" — идемпотентно.
-- Свойства передаются JSONB: {"name": "fastapi", "version": "0.104.0"}.
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

    -- MERGE по name для идемпотентности, затем обновляем все свойства
    EXECUTE format(
        $f$
        SELECT * FROM ag_catalog.cypher(%L, $cy$
            MERGE (n:%s {name: $name})
            SET n += $props
            RETURN n
        $cy$, %L) AS (n ag_catalog.agtype)
        $f$,
        p_graph_name,
        p_node_type,
        json_build_object('name', v_name, 'props', p_properties)::text
    ) INTO v_result;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql VOLATILE;

COMMENT ON FUNCTION public.add_code_node(TEXT, TEXT, JSONB)
    IS 'Добавляет (или обновляет через MERGE) узел в AGE-графе. node_type: Microservice|Library|Function|File|Class';

-- Добавить ребро в граф. edge_type: DEPENDS_ON, CALLS, IMPORTS, EXTENDS, IMPLEMENTS, CONTAINS, DEFINED_IN.
-- Соединяет два узла по их свойству "name".
CREATE OR REPLACE FUNCTION public.add_code_edge(
    p_graph_name  TEXT,
    p_from_name   TEXT,
    p_to_name     TEXT,
    p_edge_type   TEXT,
    p_properties  JSONB DEFAULT '{}'::jsonb
) RETURNS ag_catalog.agtype AS $$
DECLARE
    v_result ag_catalog.agtype;
BEGIN
    IF p_edge_type !~ '^(DEPENDS_ON|CALLS|IMPORTS|EXTENDS|IMPLEMENTS|CONTAINS|DEFINED_IN)$' THEN
        RAISE EXCEPTION 'Недопустимый edge_type: %. Допустимо: DEPENDS_ON, CALLS, IMPORTS, EXTENDS, IMPLEMENTS, CONTAINS, DEFINED_IN', p_edge_type;
    END IF;

    -- MERGE ребра между двумя узлами, найденными по name
    EXECUTE format(
        $f$
        SELECT * FROM ag_catalog.cypher(%L, $cy$
            MATCH (a), (b)
            WHERE a.name = $from_name AND b.name = $to_name
            MERGE (a)-[r:%s]->(b)
            SET r += $props
            RETURN r
        $cy$, %L) AS (r ag_catalog.agtype)
        $f$,
        p_graph_name,
        p_edge_type,
        json_build_object('from_name', p_from_name, 'to_name', p_to_name, 'props', p_properties)::text
    ) INTO v_result;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql VOLATILE;

COMMENT ON FUNCTION public.add_code_edge(TEXT, TEXT, TEXT, TEXT, JSONB)
    IS 'Добавляет (или обновляет через MERGE) ребро между двумя узлами AGE-графа по их свойству name';

-- ===========================================================================
-- 3. Аналитические функции (READ-ONLY)
-- ===========================================================================

-- Найти все микросервисы, зависящие от указанной библиотеки.
-- IMMUTABLE по спецификации (результат зависит только от аргумента и графа,
-- но граф изменяется редко — для cache-ключей допустимо).
CREATE OR REPLACE FUNCTION public.find_services_depending_on(p_library_name TEXT)
RETURNS TABLE(service_name TEXT, service_version TEXT) AS $$
    SELECT
        (r.service_name::text)::jsonb #>> '{}',
        (r.service_version::text)::jsonb #>> '{}'
    FROM ag_catalog.cypher('code_graph', $cy$
        MATCH (service:Microservice)-[:DEPENDS_ON]->(lib:Library {name: $lib_name})
        RETURN service.name, service.version
    $cy$, json_build_object('lib_name', p_library_name)::text)
    AS r(service_name ag_catalog.agtype, service_version ag_catalog.agtype);
$$ LANGUAGE SQL IMMUTABLE;

COMMENT ON FUNCTION public.find_services_depending_on(TEXT)
    IS 'Возвращает все микросервисы, зависящие от библиотеки p_library_name. IMMUTABLE по спецификации.';

-- Найти все модули, затронутые при изменении файла (impact circle).
-- Обходит рёбра CONTAINS, DEFINED_IN, CALLS, IMPORTS в обратном направлении
-- на глубину до max_depth (BFS через variable-length path).
CREATE OR REPLACE FUNCTION public.find_impact_circle(
    p_file_path TEXT,
    p_max_depth INTEGER DEFAULT 3
) RETURNS TABLE(affected_module TEXT, distance INTEGER) AS $$
    SELECT
        (r.affected_module::text)::jsonb #>> '{}',
        (r.distance::text)::integer
    FROM ag_catalog.cypher('code_graph', $cy$
        MATCH path = (file:File {path: $file_path})<-[:DEFINED_IN|CONTAINS|CALLS|IMPORTS*1..10]-(affected)
        WHERE file <> affected AND length(path) <= $depth
        RETURN distinct affected.name, min(length(path)) as dist
    $cy$, json_build_object('file_path', p_file_path, 'depth', p_max_depth)::text)
    AS r(affected_module ag_catalog.agtype, dist ag_catalog.agtype);
$$ LANGUAGE SQL STABLE;

COMMENT ON FUNCTION public.find_impact_circle(TEXT, INTEGER)
    IS 'Возвращает модули, затронутые при изменении файла, с расстоянием от исходного файла. STABLE.';

-- Найти циклические зависимости в графе (paths, где узел зависит сам от себя через цепочку).
-- Ограничение длины цикла: 10 рёбер (для производительности).
CREATE OR REPLACE FUNCTION public.find_circular_dependencies()
RETURNS TABLE(cycle_path TEXT[]) AS $$
    SELECT
        ARRAY(
            SELECT (node::text)::jsonb #>> '{}'
            FROM unnest(string_to_array(
                trim(both '[]' from r.cycle_nodes::text), ','
            )) AS node
        )
    FROM ag_catalog.cypher('code_graph', $cy$
        MATCH path = (n)-[:DEPENDS_ON|CALLS|IMPORTS*1..10]->(n)
        WHERE n.name IS NOT NULL
        RETURN [x IN nodes(path) | x.name] as cycle_nodes
        LIMIT 50
    $cy$) AS r(cycle_nodes ag_catalog.agtype);
$$ LANGUAGE SQL STABLE;

COMMENT ON FUNCTION public.find_circular_dependencies()
    IS 'Возвращает циклические зависимости в графе (до 50 циклов). Каждая запись — массив имён узлов.';

-- ===========================================================================
-- 4. Заглушка для будущей синхронизации с реальным репозиторием
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.sync_code_graph(p_repo_path TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_meta_id INTEGER;
BEGIN
    -- PLACEHOLDER: здесь будет вызов Python-парсера (через PL/Python или RPC),
    -- который обходит AST репозитория и заполняет граф через add_code_node/add_code_edge.
    --
    -- Логика:
    --   1. git clone/pull репозитория
    --   2. Для каждого .py/.js/.ts файла: extract imports → add_code_node(File) + add_code_edge(IMPORTS)
    --   3. Для каждой функции/класса: add_code_node(Function|Class) + add_code_edge(DEFINED_IN)
    --   4. Для каждого package.json/requirements.txt: add_code_node(Library) + add_code_edge(DEPENDS_ON)

    UPDATE public.code_graph_meta
       SET sync_status = 'pending',
           last_synced_at = NOW(),
           settings = settings || json_build_object('repo_path', p_repo_path)::jsonb
     WHERE graph_name = 'code_graph'
     RETURNING id INTO v_meta_id;

    RAISE NOTICE 'sync_code_graph(%): PLACEHOLDER. Реальная синхронизация реализуется через Python-парсер.', p_repo_path;
    RAISE NOTICE 'Метаданные графа обновлены (id=%). Установите sync_status=''syncing'' перед запуском парсера.', v_meta_id;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql VOLATILE;

COMMENT ON FUNCTION public.sync_code_graph(TEXT)
    IS 'PLACEHOLDER: синхронизация графа с реальным репозиторием. Реализация — через Python-парсер AST.';

-- ===========================================================================
-- 5. Демонстрационные данные графа
-- ===========================================================================
-- Узлы
SELECT * FROM public.add_code_node('code_graph', 'Microservice', '{"name": "api-gateway", "version": "1.4.0", "language": "python"}'::jsonb);
SELECT * FROM public.add_code_node('code_graph', 'Microservice', '{"name": "auth-service", "version": "2.1.0", "language": "python"}'::jsonb);
SELECT * FROM public.add_code_node('code_graph', 'Library',      '{"name": "fastapi", "version": "0.104.0", "registry": "pypi"}'::jsonb);
SELECT * FROM public.add_code_node('code_graph', 'Library',      '{"name": "sqlalchemy", "version": "2.0.23", "registry": "pypi"}'::jsonb);
SELECT * FROM public.add_code_node('code_graph', 'Function',     '{"name": "authenticate_user", "returns": "Token", "async": true}'::jsonb);
SELECT * FROM public.add_code_node('code_graph', 'File',         '{"name": "auth.py", "path": "app/api/v1/auth.py", "loc": 142}'::jsonb);

-- Рёбра
SELECT * FROM public.add_code_edge('code_graph', 'api-gateway', 'auth-service', 'DEPENDS_ON', '{"protocol": "http"}'::jsonb);
SELECT * FROM public.add_code_edge('code_graph', 'auth-service', 'fastapi',     'DEPENDS_ON', '{"constraint": ">=0.100.0"}'::jsonb);
SELECT * FROM public.add_code_edge('code_graph', 'auth-service', 'sqlalchemy',  'DEPENDS_ON', '{"constraint": ">=2.0.0"}'::jsonb);
SELECT * FROM public.add_code_edge('code_graph', 'auth-service', 'authenticate_user', 'CONTAINS', '{}'::jsonb);
SELECT * FROM public.add_code_edge('code_graph', 'authenticate_user', 'auth.py', 'DEFINED_IN', '{"line": 45}'::jsonb);

-- ---------------------------------------------------------------------------
-- 6. Обновление метаданных после заполнения
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_nodes INTEGER;
    v_edges INTEGER;
BEGIN
    -- Подсчёт узлов
    SELECT count(*) INTO v_nodes
    FROM ag_catalog.cypher('code_graph', $cy$
        MATCH (n) RETURN count(n) as cnt
    $cy$) AS (cnt ag_catalog.agtype);

    -- Подсчёт рёбер
    SELECT count(*) INTO v_edges
    FROM ag_catalog.cypher('code_graph', $cy$
        MATCH ()-[r]->() RETURN count(r) as cnt
    $cy$) AS (cnt ag_catalog.agtype);

    UPDATE public.code_graph_meta
       SET total_nodes   = (v_nodes::text)::integer,
           total_edges   = (v_edges::text)::integer,
           sync_status   = 'synced',
           last_synced_at = NOW()
     WHERE graph_name = 'code_graph';

    RAISE NOTICE '';
    RAISE NOTICE '===== code_graph заполнен =====';
    RAISE NOTICE 'Узлов: %', v_nodes;
    RAISE NOTICE 'Рёбер: %', v_edges;
    RAISE NOTICE '==============================';
END $$;

-- ---------------------------------------------------------------------------
-- 7. Демонстрация вызова аналитических функций
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_svc TEXT;
    v_ver TEXT;
BEGIN
    -- Демо: кто зависит от fastapi?
    RAISE NOTICE '--- Демо: find_services_depending_on(''fastapi'') ---';
    FOR v_svc, v_ver IN SELECT * FROM public.find_services_depending_on('fastapi') LOOP
        RAISE NOTICE '  Сервис: % (версия %)', v_svc, v_ver;
    END LOOP;

    -- Демо: impact circle для auth.py
    RAISE NOTICE '--- Демо: find_impact_circle(''app/api/v1/auth.py'', 2) ---';
    FOR v_svc, v_ver IN
        SELECT affected_module, distance::text
        FROM public.find_impact_circle('app/api/v1/auth.py', 2)
    LOOP
        RAISE NOTICE '  Затронут: % (расстояние %)', v_svc, v_ver;
    END LOOP;
END $$;
