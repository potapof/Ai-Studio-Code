#!/usr/bin/env python3
"""sync-knowledge.py — синк источников знаний Hermes в knowledge_base (hermes_brain).

Собирает:
  - навыки: ~/.hermes/skills/**/SKILL.md (name, description, content)
  - память: ~/.hermes/memories/MEMORY.md, USER.md
и UPSERT'ит в public.knowledge_base (по source_file, category='skill'/'memory').

Идемпотентно: повторный запуск обновляет существующие записи (updated_at),
не создаёт дубли. Эмбеддинги (embedding) не генерируются — остаются NULL
(генерация через ONNX all-MiniLM — отдельная задача).

Запуск: python3 ~/studio/scripts/sync-knowledge.py
"""
import glob
import os
import subprocess
import sys

HERMES = os.path.expanduser("~/.hermes")
STUDIO = os.path.expanduser("~/studio")
DB = ["docker", "exec", "-i", "nocodb-postgres-db", "psql", "-U", "nocodb_user", "-d", "hermes_brain", "-t", "-A", "-c"]


def psql(sql: str) -> str:
    r = subprocess.run(DB + [sql], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  ! psql error: {r.stderr.strip()[:200]}", file=sys.stderr)
    return r.stdout.strip()


def esc(s: str) -> str:
    return s.replace("'", "''")


def upsert(source_file: str, title: str, category: str, content: str, tags: list[str]) -> None:
    sql = (
        "INSERT INTO public.knowledge_base (title, content, category, tags, source_file, status, created_by, version) "
        f"VALUES ('{esc(title)}', '{esc(content)}', '{esc(category)}', "
        f"'{{{','.join(esc(t) for t in tags)}}}'::text[], '{esc(source_file)}', 'active', 'hermes-sync', 1) "
        "ON CONFLICT (source_file) DO UPDATE SET "
        "content = EXCLUDED.content, title = EXCLUDED.title, tags = EXCLUDED.tags, updated_at = now()"
    )
    psql(sql)


def main() -> None:
    n = 0
    # Навыки
    for path in sorted(glob.glob(f"{HERMES}/skills/**/SKILL.md", recursive=True)):
        rel = path.replace(HERMES + "/", "")
        text = open(path, encoding="utf-8", errors="replace").read()
        name = os.path.basename(os.path.dirname(path))
        title = f"skill: {name}"
        upsert(rel, title, "pattern", text[:60000], ["skill", name])
        n += 1
    # Память
    for fname in ("MEMORY.md", "USER.md"):
        path = os.path.join(HERMES, "memories", fname)
        if os.path.exists(path):
            text = open(path, encoding="utf-8", errors="replace").read()
            upsert(f"memories/{fname}", f"memory: {fname}", "reference", text[:60000], ["memory"])
            n += 1
    # План KB-REVIVE (актуальный статус работ)
    plan = os.path.join(STUDIO, "PLAN-KB-REVIVE.md")
    if os.path.exists(plan):
        text = open(plan, encoding="utf-8", errors="replace").read()
        upsert("studio/PLAN-KB-REVIVE.md", "Plan: KB Revive (актуальный статус)", "reference", text[:60000], ["plan", "kb-revive"])
        n += 1
    total = psql("SELECT count(*) FROM public.knowledge_base WHERE status='active';")
    print(f"synced {n} sources; knowledge_base active rows: {total}")


if __name__ == "__main__":
    main()
