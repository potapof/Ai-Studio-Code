#!/bin/bash
# archivist-weekly-audit.sh — еженедельный аудит базы знаний Архивариусом (cron: воскресенье 3:00)
# 1) готовит дайджест БЗ для архивариуса (он не может читать Postgres напрямую)
# 2) архивариус ревьюит дайджест и пишет рекомендации в outbox
# 3) ингест outbox → knowledge_base
set -uo pipefail
ARCH=~/.holix-host/profiles/archivist
DIGEST="$ARCH/workspace/kb-digest.md"
OUTBOX="$ARCH/workspace/outbox"
mkdir -p "$OUTBOX"

# 1. Дайджест: все записи БЗ (title/category/created_by/updated_at) + свежие сессии
docker exec nocodb-postgres-db psql -U nocodb_user -d hermes_brain -t -A -F ' | ' -c \
  "SELECT title, category, created_by, updated_at::date FROM public.knowledge_base ORDER BY updated_at DESC;" \
  > "$DIGEST"
docker exec nocodb-postgres-db psql -U nocodb_user -d hermes_brain -t -A -F ' | ' -c \
  "SELECT agent_name, status, started_at::date FROM public.agent_sessions ORDER BY started_at DESC LIMIT 10;" \
  >> "$DIGEST"
echo "digest: $(wc -l < "$DIGEST") lines"

# 2. Аудит архивариусом
~/studio/scripts/holix-delegate.sh archivist \
  "You are the knowledge archivist. Read /home/potapof/.holix-host/profiles/archivist/workspace/kb-digest.md with read_file. Review the knowledge base digest: identify duplicates, stale entries (older than 30 days), gaps and lessons worth capturing. Write your findings as ONE knowledge file per finding into /home/potapof/.holix-host/profiles/archivist/workspace/outbox/ using write_file, following the archivist-outbox skill format (frontmatter title/category/tags). Reply with exactly: AUDIT-DONE" \
  --timeout 600 2>&1 | tail -3

# 3. Ингест + эмбеддинги (иначе свежие записи невидимы векторному поиску)
~/studio/.venv/bin/python3 ~/studio/scripts/archivist-ingest.py
~/studio/.venv/bin/python3 ~/studio/scripts/gen-embeddings.py
echo "audit done: $(date '+%F %T')"
