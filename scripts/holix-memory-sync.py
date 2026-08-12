#!/usr/bin/env python3
"""holix-memory-sync.py — синк долгосрочной памяти Holix в knowledge_base (hermes_brain).

Читает ltm_entries из ~/.holix-host/profiles/*/data/memory/ltm.db (SQLite)
и UPSERT'ит в public.knowledge_base (category='reference', source_file='holix/<profile>/<key>').

Идемпотентно: ON CONFLICT (source_file) DO UPDATE.
Запуск: python3 ~/studio/scripts/holix-memory-sync.py
"""
import glob
import os
import sqlite3
import subprocess
import sys

HOLIX = os.path.expanduser("~/.holix-host/profiles")
DB = ["docker", "exec", "-i", "nocodb-postgres-db", "psql", "-U", "nocodb_user", "-d", "hermes_brain", "-t", "-A", "-c"]


def psql(sql: str) -> str:
    r = subprocess.run(DB + [sql], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  ! psql error: {r.stderr.strip()[:160]}", file=sys.stderr)
    return r.stdout.strip()


def esc(s: str) -> str:
    return s.replace("'", "''")


def main() -> None:
    n = 0
    for ltm in sorted(glob.glob(f"{HOLIX}/*/data/memory/ltm.db")):
        profile = ltm.split("/profiles/")[1].split("/")[0]
        try:
            db = sqlite3.connect(ltm)
            rows = db.execute(
                "SELECT id, key, content, memory_type, category, created_at FROM ltm_entries WHERE content IS NOT NULL AND content != ''"
            ).fetchall()
            db.close()
        except sqlite3.Error as e:
            print(f"  ! {profile}: {e}", file=sys.stderr)
            continue
        for lid, key, content, mtype, category, created_at in rows:
            k = key or f"{mtype or 'memory'}-{category or 'gen'}"
            title = f"holix/{profile}: {k}"
            source_file = f"holix/{profile}/{lid}"  # id гарантирует уникальность (key может быть NULL)
            tags = ["holix", "memory", profile] + ([category] if category else [])
            sql = (
                "INSERT INTO public.knowledge_base (title, content, category, tags, source_file, status, created_by, version) "
                f"VALUES ('{esc(title)}', '{esc(content[:60000])}', 'reference', "
                f"'{{{','.join(esc(t) for t in tags)}}}'::text[], '{esc(source_file)}', 'active', 'holix-sync', 1) "
                "ON CONFLICT (source_file) DO UPDATE SET content = EXCLUDED.content, updated_at = now()"
            )
            psql(sql)
            n += 1
    total = psql("SELECT count(*) FROM knowledge_base WHERE status='active';")
    print(f"synced {n} holix memory entries; knowledge_base active: {total}")


if __name__ == "__main__":
    main()
