#!/usr/bin/env python3
"""build-code-graph.py — построить AGE-граф зависимостей кода MAXSCRM.

Сканирует apps/backend/src и apps/frontend/src (.ts/.tsx), парсит относительные
импорты, создаёт узлы File и рёбра DEPENDS_ON через public.add_code_node/
add_code_edge (psql → docker exec nocodb-postgres-db).

Идемпотентно: MERGE по name. Повторный запуск обновляет/дополняет граф.

Запуск: python3 ~/studio/scripts/build-code-graph.py [repo_root]
"""
import json
import os
import re
import subprocess
import sys

REPO = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/studio/projects/maxscrm/repo")
ROOTS = [os.path.join(REPO, "apps/backend/src"), os.path.join(REPO, "apps/frontend/src")]
SKIP_DIRS = {"node_modules", "dist", "build", ".git", ".turbo", "coverage", "__pycache__"}
SKIP_FILES = (".spec.ts", ".test.ts", ".d.ts")

DB = ["docker", "exec", "-i", "nocodb-postgres-db", "psql", "-U", "nocodb_user", "-d", "hermes_brain", "-t", "-A", "-c"]
IMPORT_RE = re.compile(r"(?:import|export)\s+(?:[^'\"']*?\s+from\s+)?['\"]([^'\"]+)['\"]|require\(['\"]([^'\"]+)['\"]\)")


def psql(sql: str) -> str:
    r = subprocess.run(DB + [sql], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(f"  ! {r.stderr.strip()[:160]}\n")
    return r.stdout.strip()


def esc(s: str) -> str:
    return s.replace("'", "''")


def collect_files() -> list[str]:
    files = []
    for root in ROOTS:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in filenames:
                if fn.endswith((".ts", ".tsx")) and not fn.endswith(SKIP_FILES):
                    files.append(os.path.join(dirpath, fn))
    return sorted(files)


def rel_name(path: str) -> str:
    """Имя узла: путь от корня репо без расширения."""
    p = os.path.relpath(path, REPO)
    for ext in (".tsx", ".ts", ".js"):
        if p.endswith(ext):
            p = p[: -len(ext)]
            break
    return p


def resolve_import(src_file: str, imp: str) -> str | None:
    """Относительный импорт → путь к файлу (без расширения)."""
    if not imp.startswith(("./", "../")):
        return None
    base = os.path.dirname(src_file)
    candidate = os.path.normpath(os.path.join(base, imp))
    for ext in (".ts", ".tsx", ".js", ".jsx"):
        if os.path.isfile(candidate + ext):
            return candidate + ext
    if os.path.isdir(candidate):
        for idx in ("index.ts", "index.tsx", "index.js"):
            if os.path.isfile(os.path.join(candidate, idx)):
                return os.path.join(candidate, idx)
    return None


def main() -> None:
    files = collect_files()
    print(f"scanned {len(files)} files")

    nodes, edges = [], []
    for f in files:
        try:
            text = open(f, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        nodes.append((rel_name(f), f))
        for m in IMPORT_RE.finditer(text):
            imp = m.group(1) or m.group(2)
            if not imp:
                continue
            target = resolve_import(f, imp)
            if target and os.path.isfile(target):
                edges.append((rel_name(f), rel_name(target)))

    # Загрузка: узлы
    for i in range(0, len(nodes), 50):
        batch = nodes[i : i + 50]
        sql = ";".join(
            f"SELECT public.add_code_node('code_graph','File','{esc(json.dumps({'name': n, 'path': p, 'language': 'typescript'}))}'::jsonb)"
            for n, p in batch
        )
        psql(sql)
    print(f"loaded {len(nodes)} nodes")

    # Загрузка: рёбра (уникальные)
    seen = set()
    uniq_edges = []
    for a, b in edges:
        if (a, b) not in seen:
            seen.add((a, b))
            uniq_edges.append((a, b))
    for i in range(0, len(uniq_edges), 50):
        batch = uniq_edges[i : i + 50]
        sql = ";".join(
            f"SELECT public.add_code_edge('code_graph','{esc(a)}','{esc(b)}','DEPENDS_ON','{{}}'::jsonb)"
            for a, b in batch
        )
        psql(sql)
    print(f"loaded {len(uniq_edges)} unique edges")

    v = psql("SELECT count(*) FROM code_graph._ag_label_vertex;")
    e = psql("SELECT count(*) FROM code_graph._ag_label_edge;")
    print(f"graph now: {v} vertices, {e} edges")


if __name__ == "__main__":
    main()
