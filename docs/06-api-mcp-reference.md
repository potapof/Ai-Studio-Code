# Эталонный референс API и MCP-серверов

> Содержание: полный справочник всех интеграционных каналов «Студии 2.0» — postgres MCP, Stack Overflow for Agents MCP, GitHub MCP, Slack MCP, Sentry MCP, Hermes CLI, NocoDB REST API v2. Эндпоинты, методы, JSON-схемы, коды ошибок, rate-limit, аутентификация, примеры curl/Python, последовательности вызовов.

## 1. Карта интеграций 2.0

«Студия программирования» версии 2.0 интегрируется с сервисами через три типа интерфейсов:

| Тип | Пример | Используется |
|-----|--------|--------------|
| **MCP (Model Context Protocol)** | postgres MCP, SOA MCP, GitHub MCP, Slack MCP, Sentry MCP | Стандартизированный tool-based доступ для Hermes |
| **REST API** | NocoDB REST v2, Hermes HTTP API | Прямые HTTP-вызовы, webhooks |
| **CLI** | Hermes CLI, OpenHands CLI | Запуск как subprocess |

```mermaid
flowchart TB
    subgraph AGENTS["Агенты"]
        H[Hermes Agent]
        HC[Holix Coordinator]
        HA[Holix Archivist]
        HBL[Holix Backend Lead]
        HFL[Holix Frontend Lead]
        HQA[Holix QA]
        HLC[Holix Loop Checker]
        OH[OpenHands]
    end

    subgraph INTERNAL["Внутренние сервисы"]
        PG_MCP[postgres MCP<br/>stdio<br/>@modelcontextprotocol/server-postgres]
        PG[(PostgreSQL 16<br/>+ pgvector + AGE)]
        H_HTTP[Hermes HTTP API<br/>:8082]
        H_WEBHOOK[Hermes Webhooks<br/>:8081]
    end

    subgraph EXTERNAL_MCP["Внешние MCP-серверы"]
        SOA[Stack Overflow<br/>mcp.stackoverflow.com<br/>OAuth 2.1]
        GH[GitHub<br/>stdio npx<br/>PAT token]
        SL[Slack<br/>stdio python<br/>Bot token]
        SE[Sentry<br/>stdio python<br/>DSN]
    end

    subgraph LLM["LLM API"]
        DS[DeepSeek<br/>api.deepseek.com]
        OA[OpenAI<br/>api.openai.com]
        AN[Anthropic<br/>api.anthropic.com]
    end

    subgraph UI["UI для людей"]
        N_REST[NocoDB REST API v2<br/>:8080]
        N_UI[NocoDB Web UI]
    end

    H -->|MCP stdio| PG_MCP
    PG_MCP -->|SQL + Cypher| PG
    H -->|MCP HTTP OAuth 2.1| SOA
    H -->|MCP stdio| GH
    H -->|MCP stdio| SL
    H -->|MCP stdio| SE
    H -->|REST| DS
    
    HC -->|MCP stdio read_only| PG_MCP
    HA -->|MCP stdio read_write| PG_MCP
    HBL -->|MCP stdio read_only| PG_MCP
    HFL -->|MCP stdio read_only| PG_MCP
    HQA -.->|нет MCP| PG
    HLC -.->|нет MCP| PG
    OH -->|MCP stdio read_only| PG_MCP
    
    N_UI -->|SQL driver| PG
    USER([Пользователь]) -->|Kanban/формы| N_UI
    USER -->|CLI| H
    USER -->|HTTP API| H_HTTP
    
    N_REST -->|SQL| PG
    N_REST -->|webhook| H_WEBHOOK

    style H fill:#DBEAFE,stroke:#2563EB,stroke-width:2px
    style PG fill:#E0E7FF,stroke:#4F46E5,stroke-width:3px
    style SOA fill:#FCE7F3,stroke:#DB2777
    style PG_MCP fill:#F0FDF4,stroke:#16A34A
```

## 2. postgres MCP — главный MCP-сервер

### 2.1. Подключение

postgres MCP — это официальный MCP-сервер `@modelcontextprotocol/server-postgres`, предоставляющий Hermes стандартизованный доступ к PostgreSQL. Transport: stdio (через npx).

```bash
hermes mcp add hermes-brain --transport stdio -- \
  npx -y @modelcontextprotocol/server-postgres \
  "postgresql://nocodb_user:${POSTGRES_PASSWORD}@nocodb-postgres-db:5432/hermes_brain"
```

**Аутентификация:** через connection string в аргументах команды. Никаких JWT, никаких OAuth, никаких истекающих токенов. Прямое TCP-соединение к PostgreSQL.

### 2.2. Инструменты postgres MCP

#### `query` — выполнение SQL

Главный инструмент. Выполняет любой SQL, включая Cypher-запросы через `SELECT * FROM ag_catalog.cypher(...)`.

**Вход:**
```json
{
  "sql": "SELECT id, name, description, 1 - (embedding <=> $1::vector) AS similarity FROM public.skills WHERE status = 'approved' AND tenant_id = $2 ORDER BY embedding <=> $1::vector LIMIT 5",
  "params": [[0.123, -0.456, ...384 dimensions...], "default"]
}
```

**Выход:**
```json
{
  "rows": [
    {
      "id": 12,
      "name": "fastapi-jwt-auth",
      "description": "Паттерн аутентификации JWT в FastAPI",
      "similarity": 0.892
    },
    {
      "id": 34,
      "name": "eager-loading-patterns",
      "description": "Паттерны eager loading",
      "similarity": 0.851
    }
  ],
  "rowCount": 2,
  "executionTimeMs": 47
}
```

**Пример Cypher через query:**

```python
# Hermes вызывает postgres MCP для графового запроса
result = postgres_mcp.call("query", {
    "sql": """
        SELECT * FROM ag_catalog.cypher('code_graph', $$
            MATCH (service:Microservice)-[:DEPENDS_ON]->(lib:Library {name: 'fastapi'})
            RETURN service.name, service.version
        $$) AS (name agtype, version agtype)
    """
})
# result["rows"] = [{"name": "api-gateway", "version": "1.4.0"}, ...]
```

#### `list_tables` — список таблиц

```json
// Вход
{ "schema": "public" }

// Выход
{
  "tables": [
    {"name": "skills", "type": "BASE TABLE"},
    {"name": "handoff_documents", "type": "BASE TABLE"},
    {"name": "agent_sessions", "type": "BASE TABLE"},
    {"name": "api_keys_audit", "type": "PARTITIONED TABLE"},
    {"name": "tenants", "type": "BASE TABLE"}
  ]
}
```

#### `describe_table` — структура таблицы

```json
// Вход
{ "schema": "public", "table": "skills" }

// Выход
{
  "columns": [
    {"name": "id", "type": "bigint", "nullable": false, "default": "nextval(...)"},
    {"name": "name", "type": "character varying(100)", "nullable": false},
    {"name": "embedding", "type": "vector(384)", "nullable": true},
    ...
  ],
  "indexes": [
    {"name": "idx_skills_embedding", "type": "hnsw", "column": "embedding"},
    {"name": "idx_skills_tags", "type": "gin", "column": "tags"}
  ],
  "foreignKeys": []
}
```

#### `list_schemas` — список схем (для мультитенантности)

```json
// Вход
{}

// Выход
{
  "schemas": [
    {"name": "public", "owner": "nocodb_user"},
    {"name": "studio_default", "owner": "nocodb_user"},
    {"name": "studio_acme", "owner": "nocodb_user"},
    {"name": "ag_catalog", "owner": "postgres"}
  ]
}
```

#### `vector_search` — custom wrapper для pgvector k-NN

Высокоуровневая обёртка над `query`, упрощающая векторный поиск:

```json
// Вход
{
  "table": "public.skills",
  "embedding_column": "embedding",
  "query_vector": [0.123, -0.456, ...],
  "filter": "status = 'approved' AND tenant_id = 'default'",
  "top_k": 5,
  "distance_metric": "cosine"
}

// Выход
{
  "results": [
    {
      "id": 12,
      "name": "fastapi-jwt-auth",
      "description": "...",
      "similarity": 0.892,
      "content_markdown": "..."
    }
  ]
}
```

#### `graph_query` — custom wrapper для AGE Cypher

Высокоуровневая обёртка для графовых запросов:

```json
// Вход
{
  "graph": "code_graph",
  "cypher": "MATCH (s:Microservice)-[:DEPENDS_ON]->(l:Library {name: $lib}) RETURN s.name, s.version",
  "params": {"lib": "fastapi"},
  "limit": 50
}

// Выход
{
  "nodes": [
    {"name": "api-gateway", "version": "1.4.0", "labels": ["Microservice"]}
  ],
  "executionTimeMs": 23
}
```

### 2.3. Права доступа

| Агент | Право | Обоснование |
|-------|-------|-------------|
| `hermes` | read_write (без DDL) | Создание/обновление задач, HANDOFF.md, навыков |
| `holix-archivist` | read_write (без DELETE) | Создание навыков, генерация эмбеддингов |
| `holix-coordinator` | read_only | Чтение контекста для OpenHands |
| `holix-backend-lead` | read_only | Чтение контекста для декомпозиции |
| `holix-frontend-lead` | read_only | Чтение контекста для декомпозиции |
| `holix-qa` | нет доступа | Изолирован |
| `holix-loop-checker` | нет доступа | Изолирован |
| `openhands` | read_only | Чтение контекста, но не запись |

### 2.4. Безопасность

```json
{
  "security": {
    "forbid_ddl": true,           // CREATE/DROP/ALTER запрещены
    "forbid_truncate": true,      // TRUNCATE запрещён
    "row_limit": 10000,            // максимум 10K строк в результате
    "sql_injection_protection": "parameterized_queries_only",
    "query_timeout_ms": 30000,     // таймаут 30 секунд
    "statement_timeout_ms": 60000  // таймаут одного оператора 60 секунд
  }
}
```

### 2.5. First-invoke approval

Hermes v0.16+ поддерживает **first-invoke approval** — при первом вызове каждого MCP-инструмента Hermes запрашивает подтверждение у пользователя. Это критическая защита от prompt injection: если вредоносный контент из `issue.description` попытается заставить агента выполнить `DROP TABLE skills`, Hermes спросит: «Впервые вызывается инструмент `query` с DDL-операцией. Разрешить?»

Включается в `hermes-config.yaml`:

```yaml
mcp_client:
  - name: hermes-brain
    transport: stdio
    command: npx
    args: ["-y", "@modelcontextprotocol/server-postgres", "${HERMES_POSTGRES_URL}"]
    first_invoke_approval: true
```

## 3. Stack Overflow for Agents (SOA) MCP

### 3.1. Подключение

SOA — публичный MCP-сервер от Stack Overflow, предоставляющий AI-агентам доступ к проверенным техническим решениям. Transport: HTTP, аутентификация: OAuth 2.1.

```bash
hermes mcp add stackoverflow --transport http --url https://mcp.stackoverflow.com
# При первом вызове откроется браузер для OAuth 2.1 авторизации
```

**OAuth 2.1 flow:**
1. Hermes инициирует запрос к `https://mcp.stackoverflow.com/.well-known/oauth-authorization-server`
2. Получает `authorization_endpoint` и `token_endpoint`
3. Открывает браузер на `https://stackoverflow.com/oauth?client_id=...&redirect_uri=http://localhost:8082/oauth/callback&scope=read_inbox&code_challenge=...`
4. Пользователь входит в аккаунт Stack Overflow и предоставляет разрешение
5. Stack Overflow редиректит на `http://localhost:8082/oauth/callback?code=...`
6. Hermes обменивает code на access_token через `token_endpoint`
7. Access_token кэшируется и используется для всех последующих MCP-вызовов

### 3.2. Инструменты SOA

#### `so_search` — текстовый поиск по вопросам и ответам

```json
// Вход
{
  "query": "how to configure SSL in FastAPI",
  "tags": ["python", "fastapi", "ssl"],
  "sort": "relevance",  // relevance, votes, newest
  "limit": 10
}

// Выход
{
  "results": [
    {
      "question_id": 71234567,
      "title": "How to configure SSL in FastAPI with uvicorn",
      "tags": ["python", "fastapi", "ssl", "uvicorn"],
      "score": 156,
      "answer_count": 3,
      "accepted_answer_id": 71234589,
      "url": "https://stackoverflow.com/questions/71234567"
    }
  ],
  "total": 847,
  "quota_remaining": 87  // осталось вызовов из 100/день
}
```

#### `get_content` — получить полное содержание по ID

```json
// Вход
{
  "type": "question",  // question, answer, comment
  "id": 71234567
}

// Выход
{
  "type": "question",
  "id": 71234567,
  "title": "How to configure SSL in FastAPI with uvicorn",
  "body_markdown": "# SSL Configuration\n\nTo configure SSL...",
  "tags": ["python", "fastapi", "ssl", "uvicorn"],
  "creation_date": "2024-03-15T10:23:00Z",
  "score": 156,
  "accepted_answer_id": 71234589,
  "answers": [
    {
      "id": 71234589,
      "body_markdown": "Use the `--ssl-keyfile` and `--ssl-certfile` options...",
      "score": 142,
      "is_accepted": true
    }
  ]
}
```

#### `search_by_error` — поиск по сообщению об ошибке

```json
// Вход
{
  "error_message": "ConnectionError: HTTPSConnectionPool(host='localhost', port=8000)",
  "context": "FastAPI uvicorn",
  "limit": 5
}

// Выход
{
  "results": [
    {
      "question_id": 74567890,
      "title": "ConnectionError when starting uvicorn on localhost",
      "similarity": 0.91,
      "accepted_answer_summary": "Check if port is already in use: `lsof -i :8000`"
    }
  ]
}
```

#### `analyze_stack_trace` — анализ stack trace

```json
// Вход
{
  "stack_trace": "Traceback (most recent call last):\n  File \"app.py\", line 42, in <module>\n    raise ValueError(...)",
  "language": "python"
}

// Выход
{
  "error_type": "ValueError",
  "root_cause_hypothesis": "Manual raise of ValueError at app.py:42",
  "related_questions": [
    {"question_id": 12345678, "title": "How to handle ValueError properly"}
  ],
  "recommended_solutions": [
    "Use try/except block to catch ValueError",
    "Validate input before raising"
  ]
}
```

#### `get_accepted_answer` — получить принятый ответ для вопроса

```json
// Вход
{ "question_id": 71234567 }

// Выход
{
  "question_title": "How to configure SSL in FastAPI with uvicorn",
  "accepted_answer": {
    "body_markdown": "Use the `--ssl-keyfile` and `--ssl-certfile` options:\n\n```bash\nuvicorn main:app --ssl-keyfile ./key.pem --ssl-certfile ./cert.pem\n```",
    "score": 142,
    "author": {"name": "user123", "reputation": 15423}
  }
}
```

### 3.3. Rate limits

SOA в бета-версии имеет лимит **100 вызовов в день** на одного пользователя. Hermes использует лимит 80 вызовов (запас 20 для отладки):

```yaml
# hermes-config.yaml
mcp_client:
  - name: stackoverflow
    transport: http
    url: https://mcp.stackoverflow.com
    auth: oauth_2_1
    daily_limit: 100
    cache_ttl_seconds: 3600  # кэшировать ответы 1 час для экономии лимита
```

**Стратегия экономии лимита:**
1. **Кэширование** — все ответы SOA кэшируются в PostgreSQL (таблица `public.soa_cache`) с TTL 24 часа. Повторный запрос того же `query` берётся из кэша.
2. **Приоритизация** — SOA используется только для общих программистских вопросов. Внутренние вопросы идут через `public.skills` и `public.handoff_documents`.
3. **Batch-режим** — morning-triage loop может собрать до 10 ошибок за один прогон и выполнить один `search_by_error` с batch-параметром.

### 3.4. Логирование

Все вызовы SOA логируются в `public.api_keys_audit`:

```sql
SELECT timestamp, tool_name, input_params->>'query' AS query, 
       output_result->>'quota_remaining' AS quota_remaining
FROM public.api_keys_audit
WHERE mcp_server = 'stackoverflow'
ORDER BY timestamp DESC
LIMIT 10;
```

## 4. GitHub MCP

### 4.1. Подключение

```bash
hermes mcp add github --transport stdio -- \
  npx -y @modelcontextprotocol/server-github
# env: GITHUB_PERSONAL_ACCESS_TOKEN
```

Аутентификация — через Personal Access Token (PAT) с правами `repo`, `workflow`. Fine-grained PAT предпочтительнее — можно ограничить конкретными репозиториями.

### 4.2. Инструменты (14 штук)

| Инструмент | Описание | Права |
|-----------|----------|-------|
| `create_pull_request` | Открыть PR | hermes |
| `list_pull_requests` | Список PR | hermes, coordinator, loop-checker, openhands |
| `get_pull_request` | Детали PR | hermes, coordinator |
| `create_pull_request_review` | Review (approve/request_changes/comment) | hermes |
| `merge_pull_request` | Слить PR (с human approval) | hermes |
| `create_branch` | Создать ветку | hermes, coordinator |
| `get_file_contents` | Прочитать файл | hermes, coordinator, openhands |
| `create_or_update_file` | Commit файла | hermes |
| `list_commits` | Список коммитов | hermes, openhands |
| `get_workflow_run_status` | Статус GitHub Actions run | hermes |
| `list_workflow_runs` | Список runs | hermes, loop-checker |
| `get_job_logs` | Логи job | hermes, loop-checker |
| `create_issue` | Создать issue | hermes |
| `add_comment_to_issue` | Комментарий к issue | hermes |

### 4.3. Пример: открытие PR

```python
# Hermes вызывает GitHub MCP после verdict=PASS
def open_pull_request(loop_run_id: int, worktree_path: str, owner: str, repo: str):
    branch_name = f"loop/{loop_run_id}-{int(time.time())}"
    
    # 1. Создать ветку
    github_mcp.call("create_branch", {
        "owner": owner, "repo": repo,
        "branch_name": branch_name, "from_sha": "main"
    })
    
    # 2. Запушить изменения
    subprocess.run(["git", "push", "origin", f"HEAD:{branch_name}"], 
                   cwd=worktree_path, check=True)
    
    # 3. Открыть PR
    pr = github_mcp.call("create_pull_request", {
        "owner": owner, "repo": repo,
        "title": f"[loop:{loop_run_id}] {loop_metadata['description']}",
        "body": generate_pr_body(loop_run_id),
        "head": branch_name, "base": "main",
        "draft": False
    })
    
    return pr["html_url"]
```

## 5. Slack MCP

### 5.1. Подключение

```bash
hermes mcp add slack --transport stdio -- \
  python -m mcp_server_slack
# env: SLACK_BOT_TOKEN, SLACK_CHANNEL_ID
```

Bot token создаётся на https://api.slack.com/apps → New App → Bot → Scopes: `chat:write`, `channels:read`.

### 5.2. Инструменты

| Инструмент | Описание |
|-----------|----------|
| `post_message` | Отправить произвольное сообщение |
| `post_loop_completion` | Уведомление о завершении loop с метриками |
| `post_escalation` | Эскалация инцидента с упоминанием @here |
| `post_weekly_report` | Еженедельный отчёт по всем loop |

### 5.3. Пример уведомления

```python
def notify_loop_completed(loop_run: dict):
    slack_mcp.call("post_loop_completion", {
        "loop_name": loop_run["loop_name"],
        "status": loop_run["status"],
        "pr_url": loop_run.get("pr_url"),
        "tokens_used": loop_run["tokens_used"],
        "cost_usd": float(loop_run["cost_usd"]),
        "duration_seconds": int((loop_run["run_finished"] - loop_run["run_started"]).total_seconds()),
        "summary": generate_summary(loop_run)
    })
```

**Результат в Slack:**

```
Loop *dependency-update* ✅ completed
PR: https://github.com/myorg/myrepo/pull/47
Токенов: 38200 | Стоимость: $0.234
Длительность: 14m 32s

Обновлено 2 пакета: requests 2.31.0→2.32.0, black 24.1.0→24.4.2
```

## 6. Sentry MCP

### 6.1. Подключение

```bash
hermes mcp add sentry --transport stdio -- \
  python -m mcp_server_sentry
# env: SENTRY_DSN, SENTRY_API_TOKEN, SENTRY_ORG_SLUG=studio
```

### 6.2. Инструменты

| Инструмент | Описание |
|-----------|----------|
| `list_unresolved_issues` | Список нерешённых проблем |
| `get_issue_details` | Детали проблемы по ID |
| `get_event_stacktrace` | Stacktrace события |
| `resolve_issue` | Отметить решённой (hermes only) |
| `create_release` | Создать релиз для отслеживания regression |

## 7. Hermes CLI и HTTP API

### 7.1. Hermes CLI

```bash
# Простая задача
hermes task "Refactor the auth module" --delegate-to holix-coordinator

# Loop management
hermes loop list
hermes loop run dependency-update
hermes loop pause morning-triage
hermes loop enable flaky-test-fix

# MCP management
hermes mcp list
hermes mcp add hermes-brain --transport stdio -- npx -y @modelcontextprotocol/server-postgres "..."
hermes mcp test hermes-brain
hermes mcp remove nocodb-mcp  # удалить старое подключение

# Handoff
hermes handoff generate --task-id 142
hermes handoff list --limit 10
hermes handoff show <handoff_id>

# Skills
hermes skills register /home/studio/studio/examples/skills/dependency-update/SKILL.md
hermes skills list
hermes skills search "FastAPI JWT auth"

# Memory
hermes memory search "похожие задачи с медленным SQL"
hermes memory stats

# MCP server (для IDE)
hermes mcp server start --port 8082
```

### 7.2. Hermes HTTP API (порт 8082)

Hermes также слушает на порту 8082 (внутри Docker-сети) для HTTP-запросов:

#### POST /api/v1/tasks — делегировать задачу

```bash
curl -X POST http://hermes:8082/api/v1/tasks \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Refactor the auth module to use JWT",
    "delegate_to": "holix-coordinator",
    "context_skills": [1, 12, 34],
    "priority": "high",
    "max_tokens": 50000
  }'

# Response:
# {"task_id": "task_xyz789", "status": "pending", "created_at": "..."}
```

#### GET /api/v1/tasks/{task_id} — статус задачи

```bash
curl http://hermes:8082/api/v1/tasks/task_xyz789
# {"task_id": "task_xyz789", "status": "completed", "result": {...}}
```

#### POST /api/v1/loops/{name}/run — запустить loop

```bash
curl -X POST http://hermes:8082/api/v1/loops/dependency-update/run
# {"run_id": 142, "status": "running"}
```

#### GET /api/v1/loops/{name}/status — статус loop

```bash
curl http://hermes:8082/api/v1/loops/dependency-update/status
# {
#   "loop_name": "dependency-update",
#   "enabled": true,
#   "last_run": {"id": 142, "status": "completed"},
#   "next_scheduled": "2026-07-13T10:00:00Z",
#   "metrics_7d": {"runs": 1, "success_rate": 1.0, "cost_per_change": 0.234}
# }
```

### 7.3. Webhook endpoints (порт 8081)

| Endpoint | Source | Purpose |
|----------|--------|---------|
| `POST /webhooks/nocodb-task-created` | NocoDB | Уведомление о новой задаче |
| `POST /webhooks/github-actions` | GitHub Actions | CI failure → morning-triage loop |
| `POST /webhooks/github-pr` | GitHub | PR opened → lint-and-fix loop |
| `POST /webhooks/github-issue` | GitHub | Issue labeled → pr-drafting loop |
| `POST /webhooks/loop-status-changed` | NocoDB | Loop status update |

Все webhook'ы проверяют HMAC-подпись:

```python
def verify_webhook(payload: bytes, signature: str, secret: str) -> bool:
    expected = "sha256=" + hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature, expected)
```

## 8. NocoDB REST API v2

NocoDB предоставляет REST API v2 по адресу `http://nocodb-app:8080/api/v2/`. Этот API используется только для webhooks и внешних интеграций — Hermes работает через postgres MCP напрямую, минуя NocoDB.

### 8.1. CRUD-операции

#### GET /tables/{tableId}/records — список записей

```bash
curl -X GET \
  "http://localhost:8080/api/v2/tables/studio_default_tasks/records?where=(status,eq,open)&limit=10&sort=-created_at" \
  -H "xc-token: $NOCODB_API_TOKEN"
```

```json
{
  "list": [
    {
      "Id": 142,
      "title": "Refactor auth module",
      "status": "open",
      "priority": "high"
    }
  ],
  "pageInfo": {"totalRows": 47, "page": 1, "pageSize": 10}
}
```

#### POST /tables/{tableId}/records — создать

```bash
curl -X POST "http://localhost:8080/api/v2/tables/studio_default_tasks/records" \
  -H "xc-token: $NOCODB_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "New task",
    "status": "open",
    "priority": "normal"
  }'
```

#### PATCH /tables/{tableId}/records/{recordId} — обновить

```bash
curl -X PATCH "http://localhost:8080/api/v2/tables/studio_default_tasks/records/142" \
  -H "xc-token: $NOCODB_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "done"}'
```

### 8.2. Webhooks

#### POST /db/virtual/{baseId}/hook — зарегистрировать webhook

```bash
curl -X POST "http://localhost:8080/api/v2/db/virtual/hermes_brain/hook" \
  -H "xc-token: $NOCODB_API_TOKEN" \
  -d '{
    "event": "after.insert",
    "model_name": "studio_default_tasks",
    "url": "http://hermes:8081/webhooks/nocodb-task-created",
    "headers": "{\"X-Webhook-Source\": \"nocodb\"}"
  }'
```

### 8.3. Коды ошибок

| Код | Описание | Действие |
|-----|----------|----------|
| 200 | OK | Успех |
| 401 | Unauthorized | Неверный `xc-token` |
| 403 | Forbidden | Нет прав на операцию |
| 404 | Not Found | Таблица/запись не найдены |
| 422 | Unprocessable Entity | Нарушение constraints |
| 429 | Too Many Requests | Rate limit (60/мин) |
| 500 | Internal Server Error | Ошибка NocoDB |

## 9. Аутентификация и авторизация

### 9.1. Сводная таблица

| Сервис | Метод | Где хранится | Ротация |
|--------|-------|--------------|---------|
| postgres MCP | Connection string | `.env: HERMES_POSTGRES_URL` | при смене пароля |
| SOA MCP | OAuth 2.1 (PKCE) | Кэш Hermes (токен обновляется автоматически) | refresh_token |
| GitHub MCP | PAT (Personal Access Token) | `.env: GITHUB_TOKEN` | 90 дней |
| Slack MCP | Bot Token | `.env: SLACK_BOT_TOKEN` | 12 месяцев |
| Sentry MCP | API Token | `.env: SENTRY_API_TOKEN` | 90 дней |
| Hermes HTTP | Bearer token (внутренний) | Docker-сеть | — |
| NocoDB REST | `xc-token` header | `.env: NOCODB_API_TOKEN` | 90 дней |
| LLM API | `Authorization: Bearer sk-...` | `.env: DEEPSEEK_API_KEY` | по требованию |

### 9.2. Принцип минимальных привилегий

```mermaid
flowchart LR
    subgraph POSTGRES["PostgreSQL права"]
        RW_DDL[read_write + DDL]
        RW[read_write, без DDL/DELETE]
        RO[read_only]
        NONE[нет доступа]
    end
    
    H[Hermes] --> RW_DDL
    HA[Archivist] --> RW
    HC[Coordinator] --> RO
    HBL[Backend Lead] --> RO
    HFL[Frontend Lead] --> RO
    OH[OpenHands] --> RO
    HQA[QA] --> NONE
    HLC[Loop Checker] --> NONE
    
    style H fill:#DBEAFE,stroke:#2563EB,stroke-width:2px
    style OH fill:#FCE7F3,stroke:#DB2777
```

OpenHands имеет только read-доступ — он читает контекст, но не может изменять коллективную память. Запись результатов работы выполняется через Holix Coordinator → Архивариус → `public.handoff_documents`.

## 10. Последовательности вызовов

### 10.1. Полный цикл Loop Engineering 2.0

```mermaid
sequenceDiagram
    participant CRON as Cron
    participant H as Hermes
    participant PG as postgres MCP
    participant SOA as SOA MCP
    participant OH as OpenHands
    participant QA as Loop Checker
    participant GH as GitHub MCP
    participant SL as Slack MCP

    CRON->>H: trigger(dependency-update)
    H->>PG: INSERT INTO loop_runs(status=running)
    
    H->>PG: vector_search in handoff_documents
    PG-->>H: 3 похожих прошлых прогона
    
    H->>PG: SELECT from skills (context)
    PG-->>H: 5 релевантных навыков
    
    H->>SOA: so_search("pip audit best practices")
    SOA-->>H: 2 проверенных решения
    
    H->>OH: delegate(task, context, workoff)
    
    loop Maker iterations (max 3)
        OH->>OH: generate code in worktree
        OH-->>H: maker_output (diff)
        H->>QA: check(worktree_path)
        QA->>QA: pytest + flake8 + bandit
        QA-->>H: verdict(PASS/FAIL)
        
        alt PASS
            H->>GH: create_pull_request
            GH-->>H: PR URL
            H->>PG: UPDATE loop_runs(status=completed, pr_url)
            H->>PG: INSERT INTO handoff_documents (HANDOFF.md + embedding)
            H->>SL: post_loop_completion
        else FAIL & attempts < max
            H->>OH: retry with feedback
        else FAIL & attempts = max
            H->>PG: UPDATE loop_runs(status=escalated)
            H->>SL: post_escalation
        end
    end
```

### 10.2. Webhook-поток: GitHub → Loop

```mermaid
sequenceDiagram
    participant GH as GitHub Actions
    participant W as Hermes Webhook :8081
    participant H as Hermes
    participant CI as GitHub MCP
    participant L as Loop Registry
    
    GH->>W: POST /webhooks/github-actions<br/>(workflow_run.completed, conclusion=failure)
    W->>W: verify HMAC signature
    W->>H: dispatch event
    
    alt event matches "morning-triage" trigger
        H->>L: lookup loop by event
        L-->>H: morning-triage
        H->>H: create_run(loop_name=morning-triage)
        H->>CI: list_workflow_runs(status=failure)
        CI-->>H: [run1, run2, run3]
        
        loop for each failed run
            H->>CI: get_failed_jobs(run_id)
            CI-->>H: [job1, job2]
            H->>SOA: search_by_error(error_message)
            SOA-->>H: related solutions
            
            alt solution found
                H->>H: delegate to OpenHands (maker)
            else no solution
                H->>H: escalate to human
            end
        end
    end
```

## 11. Best practices

### 11.1. Идемпотентность

```python
# Плохо — каждый вызов создаёт новую запись
client.create_record("loop_runs", {"loop_name": "dep-update", "status": "running"})

# Хорошо — сначала проверяем
existing = client.list_records("loop_runs", 
    where="(loop_name,eq,dep-update)~and(status,eq,running)")
if existing["list"]:
    return existing["list"][0]
return client.create_record("loop_runs", {...})
```

### 11.2. Retry с exponential backoff

```python
def with_retry(func, max_retries=5, base_delay=1.0):
    for attempt in range(max_retries):
        try:
            return func()
        except (ConnectionError, TimeoutError) as e:
            if attempt == max_retries - 1:
                raise
            delay = base_delay * (2 ** attempt) + random.uniform(0, 1)
            time.sleep(delay)
```

### 11.3. Таймауты

```python
# Плохо
r = requests.get(url)

# Хорошо
r = requests.get(url, timeout=(5, 30))  # (connect, read)
```

### 11.4. Фильтрация секретов в логах

```python
SECRET_PATTERNS = [
    (r'sk-[A-Za-z0-9]{20,}', '[REDACTED_API_KEY]'),
    (r'ghp_[A-Za-z0-9]{36}', '[REDACTED_GITHUB_PAT]'),
    (r'xox[baprs]-[A-Za-z0-9-]+', '[REDACTED_SLACK_TOKEN]'),
    (r'Bearer [A-Za-z0-9._-]+', 'Bearer [REDACTED]'),
    (r'password\s*[:=]\s*\S+', 'password=[REDACTED]'),
]

def sanitize(text: str) -> str:
    for pattern, replacement in SECRET_PATTERNS:
        text = re.sub(pattern, replacement, text)
    return text
```

Все вызовы MCP-серверов автоматически логируются в `public.api_keys_audit` с применением `sanitize_for_log()`.

## 12. Что дальше

- **Hermes Agent** — [docs/07-hermes-agent.md](07-hermes-agent.md)
- **Оркестрация знаний** — [docs/08-knowledge-orchestration.md](08-knowledge-orchestration.md)
- **Handoff-Driven Development** — [docs/09-handoff-driven-development.md](09-handoff-driven-development.md)
