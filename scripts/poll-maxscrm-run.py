#!/usr/bin/env python3
"""Полить GitHub Actions runs для head_sha и выдать сводку; при завершении проверить staging.

Использование: python3 poll-maxscrm-run.py <head_sha> [репо]
Токен берём из remote URL (x-access-token) репозитория.
"""
import sys, json, time, urllib.request, urllib.error, subprocess, re

REPO = "maxscrmru/maxscrm"
BASE = f"https://api.github.com/repos/{REPO}/actions"

def token_from_remote():
    repo_dir = "/home/potapof/studio/projects/maxscrm/repo"
    url = subprocess.check_output(
        ["git", "-C", repo_dir, "remote", "get-url", "origin"], text=True).strip()
    m = re.search(r'x-access-token:([^@]+)@', url)
    return m.group(1) if m else None

def api(path, token, retries=5):
    req = urllib.request.Request(BASE + path,
        headers={"Authorization": f"token {token}", "Accept": "application/vnd.github+json",
                 "User-Agent": "poll-maxscrm-run"})
    last = None
    for i in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            last = e
            if e.code == 404:
                # известный кейс: у токена нет actions:read на уровне runs — пробуем workflow-level
                return None
            time.sleep(10 * (i + 1))
        except Exception as e:
            last = e
            time.sleep(10 * (i + 1))
    raise last

def runs_for_head(sha, token):
    # ВАЖНО: /actions/runs?head_sha= НЕНАДЁЖЕН — для push-раннов возвращает 0, хотя ранн существует
    # (проверено 2026-09-09). Берём свежие ранны без фильтра и матчим head_sha по префиксу локально.
    d = api("/runs?per_page=50", token)
    if d and "workflow_runs" in d:
        matched = [r for r in d["workflow_runs"] if (r.get("head_sha") or "").startswith(sha)]
        return matched, True
    # fallback: workflow-level (если runs-скоуп недоступен)
    wfs = ["ci.yml", "deploy-staging.yml", "deploy-help.yml", "deploy-prod.yml", "publish-sdk.yml"]
    out = []
    for wf in wfs:
        d = api(f"/workflows/{wf}/runs?per_page=10", token)
        if d and "workflow_runs" in d:
            for r in d["workflow_runs"]:
                if (r.get("head_sha") or "").startswith(sha):
                    out.append(r)
    return out, False

def main():
    sha = sys.argv[1]
    token = token_from_remote()
    if not token:
        print("NO TOKEN"); sys.exit(2)
    print(f"Polling runs for {sha} on {REPO}")
    start = time.time()
    deadline = start + 75 * 60
    seen = {}
    while time.time() < deadline:
        runs, level = runs_for_head(sha, token)
        if runs is None:
            print("Repo-level /actions/runs -> 404; trying workflow-level endpoints next loop")
        actives = []
        for r in runs:
            rid, wf, status, concl = r["id"], r["name"], r["status"], r["conclusion"]
            actives.append((wf, status, concl))
            if status != "completed":
                seen[rid] = (wf, status, concl)
        print(f"[{int(time.time()-start)}s] {len(runs)} runs found:", "; ".join(
            f"{wf}:{s}" for wf, s, _ in actives))
        if runs and all(r["status"] == "completed" for r in runs):
            print("\n=== ALL RUNS COMPLETED ===")
            fails = []
            for r in runs:
                print(f"  {r['name']}: {r['status']} / {r['conclusion']}  ({r['html_url']})")
                if r["conclusion"] not in ("success", "skipped"):
                    fails.append(r["name"])
            print("\nRESULT:", "ALL_GREEN" if not fails else f"FAILURES: {', '.join(fails)}")
            sys.exit(1 if fails else 0)
        time.sleep(45)
    print(f"TIMEOUT after {int(time.time()-start)}s; still active: {seen}")
    sys.exit(2)

if __name__ == "__main__":
    main()
