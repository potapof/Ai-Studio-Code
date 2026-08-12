#!/usr/bin/env python3
"""archivist-ingest.py — ингест знаний Архивариуса (outbox) в hermes_brain.

Архивариус (Holix-профиль) НЕ может писать в Postgres напрямую (sql_query в Holix 0.1.21
работает только с SQLite) — поэтому он пишет markdown-файлы с frontmatter в свой outbox:
    ~/.holix-host/profiles/archivist/workspace/outbox/<slug>.md
Этот скрипт UPSERT'ит их в public.knowledge_base (created_by='archivist') и перемещает
обработанные файлы в outbox/done/.

Формат файла:
---
title: <заголовок>
category: reference|pattern|guardrail|instruction
tags: [tag1, tag2]
---
<содержимое знания (markdown)>

Запуск: ~/studio/.venv/bin/python3 ~/studio/scripts/archivist-ingest.py
"""
import glob
import os
import re
import shutil
import subprocess
import sys

OUTBOX = os.path.expanduser("~/.holix-host/profiles/archivist/workspace/outbox")
DB = ["docker", "exec", "-i", "nocodb-postgres-db", "psql", "-U", "nocodb_user", "-d", "hermes_brain", "-t", "-A", "-c"]


def psql(sql: str) -> str:
    r = subprocess.run(DB + [sql], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  ! psql error: {r.stderr.strip()[:200]}", file=sys.stderr)
    return r.stdout.strip()


def esc(s: str) -> str:
    return s.replace("'", "''")


def parse_md(path: str):
    """Возвращает (title, category, tags, content) или None."""
    text = open(path, encoding="utf-8").read()
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n(.*)$", text, re.S)
    if not m:
        return None
    fm, content = m.group(1), m.group(2).strip()
    title = re.search(r"^title:\s*(.+)$", fm, re.M)
    category = re.search(r"^category:\s*(\S+)$", fm, re.M)
    tags = re.search(r"^tags:\s*\[(.*)\]$", fm, re.M)
    if not title or not content:
        return None
    tags_list = [t.strip().strip('"\'') for t in tags.group(1).split(",")] if tags else []
    cat = category.group(1) if category else "reference"
    if cat not in ("reference", "pattern", "guardrail", "instruction"):
        cat = "reference"
    return title.group(1).strip(), cat, tags_list, content


def main() -> None:
    done_dir = os.path.join(OUTBOX, "done")
    os.makedirs(done_dir, exist_ok=True)
    n = 0
    for path in sorted(glob.glob(os.path.join(OUTBOX, "*.md"))):
        parsed = parse_md(path)
        if parsed is None:
            print(f"  ! skip (no frontmatter): {os.path.basename(path)}", file=sys.stderr)
            continue
        title, category, tags, content = parsed
        slug = os.path.basename(path)
        source_file = f"archivist/{slug}"
        tag_literal = "{" + ",".join(esc(t) for t in tags) + "}"
        sql = (
            "INSERT INTO public.knowledge_base (title, content, category, tags, source_file, status, created_by, version) "
            f"VALUES ('{esc(title)}', '{esc(content)}', '{category}', '{tag_literal}'::text[], "
            f"'{esc(source_file)}', 'active', 'archivist', 1) "
            "ON CONFLICT (source_file) DO UPDATE SET "
            "content = EXCLUDED.content, title = EXCLUDED.title, tags = EXCLUDED.tags, "
            "category = EXCLUDED.category, updated_at = now()"
        )
        psql(sql)
        shutil.move(path, os.path.join(done_dir, slug))
        n += 1
        print(f"  ingested: {slug}")
    print(f"done: {n} knowledge entries from archivist outbox")


if __name__ == "__main__":
    main()
