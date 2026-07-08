# Troubleshooting

> Топ-15 проблем при развёртывании и эксплуатации «Студии 2.0». Включая новые ошибки Apache AGE, SOA OAuth, postgres MCP.

## 1. Apache AGE не устанавливается

**Симптом:** `CREATE EXTENSION age` падает с `ERROR: could not open extension control file`.

**Причина:** Образ `pgvector/pgvector:pg16` не содержит AGE — только pgvector. AGE нужно устанавливать отдельно.

**Решение:**

Используйте кастомный Dockerfile, который собирает AGE поверх pgvector:

```dockerfile
FROM pgvector/pgvector:pg16

RUN apt-get update && apt-get install -y \
    build-essential \
    postgresql-server-dev-16 \
    git \
    && git clone https://github.com/apache/age.git /tmp/age \
    && cd /tmp/age \
    && git checkout release/PG16/1.5.0 \
    && make install \
    && rm -rf /tmp/age \
    && apt-get remove -y build-essential postgresql-server-dev-16 git \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*
```

Альтернативно — используйте готовый образ `goramstack/age-pgvector:pg16` (объединяет pgvector + AGE).

## 2. SOA OAuth не открывает браузер

**Симптом:** `hermes mcp add stackoverflow --transport http --url https://mcp.stackoverflow.com` выполнен, но при первом вызове браузер не открывается.

**Причина:** Hermes работает в Docker-контейнере без доступа к X-серверу хоста.

**Решение:**

Пробросьте DISPLAY или используйте ручной OAuth flow:

```bash
# Вариант 1: проброс DISPLAY (если есть X-сервер на хосте)
docker compose stop hermes
# В docker-compose.yml добавить:
#   environment:
#     DISPLAY: ${DISPLAY}
#   volumes:
#     - /tmp/.X11-unix:/tmp/.X11-unix:ro
docker compose up -d hermes

# Вариант 2: ручной OAuth flow
hermes mcp auth stackoverflow --manual
# Hermes выведет URL — откройте его вручную в браузере на хосте
# После авторизации скопируйте redirect URL обратно в Hermes
```

## 3. postgres MCP: Connection refused

**Симптом:** Hermes логирует `ECONNREFUSED 172.20.0.30:5432` при попытке вызвать postgres MCP.

**Причина:** PostgreSQL ещё не готов, или Hermes запущен раньше PostgreSQL.

**Решение:**

```yaml
# docker-compose.yml — убедитесь, что depends_on с condition
hermes:
  depends_on:
    postgres-db:
      condition: service_healthy  # не просто service_started
```

Проверьте healthcheck:

```bash
docker exec nocodb-postgres-db pg_isready
# /var/run/postgresql:5432 - accepting connections
```

## 4. pgvector: operator does not exist

**Симптом:** `ERROR: operator does not exist: vector <=> unknown` при выполнении SQL с `<=>`.

**Причина:** Расширение `vector` не установлено в текущей БД, или не загружено в сессии.

**Решение:**

```bash
# Установка расширения (если не установлено)
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "CREATE EXTENSION IF NOT EXISTS vector;"

# Проверка
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "\dx vector"
# Должно показать: vector | 0.7.0 | public
```

## 5. AGE: graph does not exist

**Симптом:** `ERROR: ag_catalog.create_graph: graph "code_graph" already exists` или наоборот — graph not found.

**Решение:**

```sql
-- Проверка существующих графов
SELECT name FROM ag_catalog.ag_graph;

-- Создание графа (если не существует)
SELECT ag_catalog.create_graph('code_graph');

-- Установка search_path (важно!)
SET search_path = ag_catalog, "$user", public;

-- Удаление графа (если нужно пересоздать)
SELECT ag_catalog.drop_graph('code_graph', true);  -- true = cascade
```

## 6. SOA: Daily quota exceeded

**Симптом:** `{"error": "quota_exceeded", "quota_remaining": 0}` от SOA MCP.

**Причина:** Лимит 100 вызовов в день исчерпан.

**Решение:**

1. **Проверьте кэширование** — `public.soa_cache` должна перехватывать повторные запросы:

```sql
SELECT query_text, hit_count, created_at 
FROM public.soa_cache 
ORDER BY hit_count DESC LIMIT 10;
```

2. **Увеличьте TTL кэша** в `hermes-config.yaml`:

```yaml
mcp_client:
  - name: stackoverflow
    cache_ttl_seconds: 86400  # 24 часа вместо 1 часа
```

3. **Приоритизируйте internal** — Hermes должен сначала искать в `public.handoff_documents`, и только при отсутствии — в SOA.

4. **Для production** — обратитесь в продажи Stack Overflow для увеличения лимита.

## 7. Hermes MCP: first-invoke approval блокирует loop

**Симптом:** Loop зависает на шаге maker — Hermes ждёт подтверждения first-invoke approval, но никто не подтверждает.

**Причина:** first-invoke approval требует human-in-the-loop, что несовместимо с автономными loop.

**Решение:**

Для loop используйте **pre-approved tools** — Hermes запоминает подтверждения и не запрашивает их повторно для того же инструмента с теми же параметрами:

```yaml
mcp_client:
  - name: hermes-brain
    first_invoke_approval: true
    pre_approved_tools:
      - query  # для loop query pre-approved с фильтром
    pre_approved_patterns:
      - "SELECT.*FROM studio_.*\\.loop_runs"
      - "SELECT.*FROM public\\.handoff_documents"
      - "INSERT INTO studio_.*\\.loop_runs"
```

Альтернатива — отключить first-invoke approval для автономных loop и оставить только для интерактивных задач.

## 8. PostgreSQL: out of memory

**Симптом:** `ERROR: out of memory` или `FATAL: the database system is in recovery mode`.

**Причина:** HNSW-индексы pgvector потребляют много RAM. При большом количестве векторов (>1M) PostgreSQL может исчерпать `shared_buffers`.

**Решение:**

1. Увеличьте `shared_buffers` в `postgresql.conf`:

```bash
docker exec -it nocodb-postgres-db bash -c "echo 'shared_buffers = 2GB' >> /var/lib/postgresql/data/pgdata/postgresql.conf"
docker compose restart postgres-db
```

2. Используйте IVFFlat вместо HNSW (меньше RAM, чуть медленнее):

```sql
DROP INDEX idx_skills_embedding;
CREATE INDEX idx_skills_embedding ON public.skills 
    USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
```

3. Рассмотрите half-precision (pgvector 0.7+):

```sql
ALTER TABLE public.skills ALTER COLUMN embedding TYPE vector(384) USING embedding::halfvec(384);
```

## 9. NocoDB не видит таблицы studio_*

**Симптом:** В NocoDB UI нет таблиц `studio_default.tasks` и других tenant-таблиц.

**Причина:** NocoDB по умолчанию показывает только схему `public`. Схемы `studio_*` нужно добавить явно.

**Решение:**

1. В NocoDB UI: **Project Settings → Schema → Add Schema**
2. Выберите схему `studio_default` (и другие tenant-схемы)
3. Нажмите **Sync** — NocoDB обнаружит все таблицы

Альтернатива через API:

```bash
curl -X POST "http://localhost:8080/api/v2/db/virtual/hermes_brain/schema" \
  -H "xc-token: $NOCODB_API_TOKEN" \
  -d '{"schema": "studio_default"}'
```

## 10. Loop infinite retry

**Симптом:** Loop делает 3 попытки, все fail, но не эскалирует.

**Решение:**

Проверьте логику `arbiter_decide()`:

```python
def arbiter_decide(verdict, attempts, max_retries, tokens_used, token_budget):
    if verdict == "PASS":
        return "OPEN_PR"
    if verdict == "NEEDS_HUMAN":
        return "ESCALATE"
    # FAIL
    if attempts >= max_retries:
        return "ESCALATE"
    if tokens_used >= token_budget:  # проверка лимита токенов
        return "ESCALATE"
    return "RETRY"
```

## 11. Worktree conflict

**Симптом:** `fatal: 'worktree/...' already exists`.

**Решение:**

```bash
cd ~/studio/projects/main-repo
git worktree prune
git worktree list

# Удалить конкретный worktree
git worktree remove ../worktrees/loop-dep-update-141 --force
git branch -D loop/dep-update/141
```

В runner.py добавьте try/finally для гарантированной очистки.

## 12. Webhook от GitHub не доходит

**Симптом:** GitHub показывает `Last delivery was not successful`.

**Решение:**

1. Webhook должен указывать на публичный URL, не localhost. Для тестирования — ngrok:

```bash
ngrok http 8081
# Получите https://abc123.ngrok.io
# Укажите в GitHub: https://abc123.ngrok.io/webhooks/github-actions
```

2. Проверьте HMAC-подпись.

3. Для production — nginx с TLS-сертификатом.

## 13. Hermes: context window exceeded

**Симптом:** `Error: context_length_exceeded` от LLM API.

**Причина:** Hermes накопил слишком много контекста в сессии.

**Решение:**

1. Проверьте, что context_compressor включён:

```yaml
context_compressor:
  enabled: true
  trigger_at_tokens: 100000  # сжимать при 100K
```

2. Вручную запустите `/handoff` для сохранения контекста и начала новой сессии:

```bash
hermes handoff generate --reason "context window cleanup"
```

3. Увеличьте `max_tokens` модели (если поддерживается) или переключитесь на модель с большим контекстом.

## 14. AGE Cypher syntax error

**Симптом:** `ERROR: syntax error at or near "$$"` при выполнении Cypher-запроса.

**Причина:** Конфликт между `$$` Cypher и `$$` PL/pgSQL function body.

**Решение:**

Используйте другой тег для Cypher-строки:

```sql
-- Плохо — конфликт $$
CREATE FUNCTION my_func() RETURNS void AS $$
SELECT * FROM cypher('code_graph', $$
    MATCH (n) RETURN n
$$) AS (n agtype);
$$ LANGUAGE SQL;

-- Хорошо — разные теги
CREATE FUNCTION my_func() RETURNS void AS $func$
    SELECT * FROM cypher('code_graph', $cy$
        MATCH (n) RETURN n
    $cy$) AS (n agtype);
$func$ LANGUAGE SQL;
```

## 15. Диск заполнен логами audit_log

**Симптом:** `No space left on device`. Таблица `public.api_keys_audit` занимает > 10 ГБ.

**Решение:**

Таблица партиционирована по неделям. Для удаления старых партиций:

```sql
-- Просмотр партиций
SELECT tablename, pg_size_pretty(pg_relation_size('public.'||tablename)) AS size
FROM pg_tables
WHERE tablename LIKE 'api_keys_audit_%'
ORDER BY tablename DESC;

-- Удаление партиций старше 12 недель (через функцию)
SELECT public.drop_old_audit_partitions(12);

-- Cron на ежемесячное выполнение
-- 0 0 1 * * psql -U nocodb_user -d hermes_brain -c "SELECT public.drop_old_audit_partitions(12);"
```

## Дополнительные ресурсы

- **Apache AGE docs:** https://age.apache.org/age-manual/
- **pgvector docs:** https://github.com/pgvector/pgvector
- **Hermes Agent:** https://hermes-agent.nousresearch.com/docs/
- **Stack Overflow for Agents:** https://meta.stackoverflow.com/questions/438910/introducing-stack-overflow-for-agents
- **NocoDB docs:** https://nocodb.com/docs

Если проблема не решена — создайте issue в GitHub-репозитории с:
1. Версиями всех компонентов (`docker compose images`)
2. Логами (`docker compose logs --since 1h`)
3. Шагами для воспроизведения
