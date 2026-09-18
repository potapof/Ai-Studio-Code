#!/usr/bin/env python3
"""Zen Go relay — локальный OpenAI-совместимый прокси к OpenCode Go с откатом на DeepSeek.

Зачем: подписка OpenCode Go требует от каждого клиента заголовок
``x-opencode-session`` (без него апстрим отвечает 400 MissingSessionID).
Клиенты, которые не умеют слать свои заголовки (dsh, open-code-review),
ходят через этот релей: он добавляет ключ Go и заголовок сессии,
остальное проксирует как есть, включая SSE-стриминг.

Откат (fallback): если подписка Go недоступна (квота исчерпана, 401/402/403,
429, 5xx, обрыв связи), релей повторяет тот же запрос к DeepSeek API
(``ZEN_RELAY_FALLBACK_UPSTREAM``) с моделью ``ZEN_RELAY_FALLBACK_MODEL``.
Признак отката в ответе — заголовок ``X-Zen-Relay-Fallback: deepseek``.
После первого отката primary не дёргается ``ZEN_RELAY_COOLDOWN`` секунд
(быстрый путь на DeepSeek), затем снова пробуется Go.

Порт/апстрим/ключи задаются переменными окружения:
  ZEN_RELAY_HOST               (default 127.0.0.1)
  ZEN_RELAY_PORT               (default 8012)
  ZEN_RELAY_MODE               auto | go | deepseek   (default auto)
  ZEN_RELAY_UPSTREAM           (default https://opencode.ai/zen/go/v1)
  ZEN_RELAY_FALLBACK_UPSTREAM  (default https://api.deepseek.com)
  ZEN_RELAY_FALLBACK_MODEL     (default deepseek-v4-flash-vision-exp)
  ZEN_RELAY_FALLBACK_KEY_ENV   (default DEEPSEEK_API_KEY)
  ZEN_RELAY_COOLDOWN           (default 300 сек)
  OPENCODE_GO_API_KEY          ключ подписки OpenCode Go (обязателен, кроме режима deepseek)
"""

from __future__ import annotations

import json
import os
import time
import uuid
from collections.abc import AsyncIterator
from typing import Any

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

HOST = os.environ.get("ZEN_RELAY_HOST", "127.0.0.1")
PORT = int(os.environ.get("ZEN_RELAY_PORT", "8012"))
UPSTREAM = os.environ.get("ZEN_RELAY_UPSTREAM", "https://opencode.ai/zen/go/v1").rstrip("/")
MODE = os.environ.get("ZEN_RELAY_MODE", "auto").strip().lower()
FALLBACK_UPSTREAM = os.environ.get("ZEN_RELAY_FALLBACK_UPSTREAM", "https://api.deepseek.com").rstrip("/")
FALLBACK_MODEL = os.environ.get("ZEN_RELAY_FALLBACK_MODEL", "deepseek-v4-flash-vision-exp")
FALLBACK_KEY_ENV = os.environ.get("ZEN_RELAY_FALLBACK_KEY_ENV", "DEEPSEEK_API_KEY")
COOLDOWN = float(os.environ.get("ZEN_RELAY_COOLDOWN", "300"))
USER_AGENT = "studio-zen-relay/1.1"

if MODE not in {"auto", "go", "deepseek"}:
    raise SystemExit(f"zen-go-relay: неверный ZEN_RELAY_MODE={MODE!r} (ожидается auto|go|deepseek)")

# Статусы апстрима, после которых имеет смысл пробовать резервный провайдер.
FAILOVER_STATUSES = {
    int(s) for s in os.environ.get(
        "ZEN_RELAY_FAILOVER_STATUSES", "401,402,403,404,408,409,425,429,500,502,503,504,529"
    ).split(",") if s.strip()
}

# Заголовки, которые нельзя пробрасывать наверх (задаём сами).
HOP_HEADERS = {
    "host", "authorization", "content-length", "connection",
    "accept-encoding", "user-agent", "x-opencode-session",
}

# Состояние отката (однопроцессный uvicorn — гонок нет).
STATE: dict[str, Any] = {
    "failover_events": 0,            # сколько раз primary УПАЛ (переход в резерв)
    "fallback_requests": 0,          # сколько запросов обслужено резервом
    "last_primary_error": None,      # {"status": int|str, "detail": str, "at": iso}
    "last_fallback_at": None,
    "primary_down_until": 0.0,
}


def go_key() -> str:
    key = (os.environ.get("OPENCODE_GO_API_KEY") or "").strip().strip("\"'")
    if not key:
        raise RuntimeError("OpenCode Go key not found: задайте OPENCODE_GO_API_KEY "
                           "(источник — ~/studio/.env / ~/.hermes/.env)")
    return key


def fallback_key() -> str:
    return (os.environ.get(FALLBACK_KEY_ENV) or "").strip().strip("\"'")


def failover_enabled() -> bool:
    return MODE == "auto" and bool(fallback_key()) and bool(FALLBACK_UPSTREAM)


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def primary_cooling() -> bool:
    return time.time() < STATE["primary_down_until"]


def mark_failover(reason: str) -> None:
    """Зафиксировать падение primary и уйти в резерв на COOLDOWN секунд."""
    STATE["failover_events"] += 1
    STATE["primary_down_until"] = time.time() + COOLDOWN
    print(f"[relay] failover → {FALLBACK_MODEL} @ {FALLBACK_UPSTREAM} (cooldown {COOLDOWN:.0f}s): {reason}",
          flush=True)


def mark_fallback_served() -> None:
    STATE["fallback_requests"] += 1
    STATE["last_fallback_at"] = now_iso()


def mark_primary_error(status: Any, detail: str) -> None:
    STATE["last_primary_error"] = {"status": status, "detail": detail[:400], "at": now_iso()}


app = FastAPI(title="zen-go-relay", docs_url=None, redoc_url=None)
client = httpx.AsyncClient(timeout=httpx.Timeout(connect=30.0, read=900.0, write=60.0, pool=30.0))


def client_headers(request: Request) -> dict[str, str]:
    return {k: v for k, v in request.headers.items() if k.lower() not in HOP_HEADERS}


def go_headers(request: Request) -> dict[str, str]:
    headers = client_headers(request)
    headers["Authorization"] = f"Bearer {go_key()}"
    headers["User-Agent"] = USER_AGENT
    # Стабильный идентификатор диалога: если клиент передал свой — сохраняем,
    # иначе генерируем на запрос (Go использует его для маршрутизации/кеша промптов).
    headers["x-opencode-session"] = request.headers.get("x-opencode-session") or f"studio-relay-{uuid.uuid4().hex}"
    return headers


def deepseek_headers(request: Request) -> dict[str, str]:
    headers = client_headers(request)
    headers["Authorization"] = f"Bearer {fallback_key()}"
    headers["User-Agent"] = USER_AGENT
    headers.pop("x-opencode-session", None)
    return headers


async def send(url: str, headers: dict[str, str], payload: dict[str, Any], stream: bool) -> Any:
    """Отправить запрос к апстриму. Возвращает httpx.Response (buffered или stream)."""
    if not stream:
        return await client.post(url, json=payload, headers=headers)
    req = client.build_request("POST", url, json=payload, headers=headers)
    return await client.send(req, stream=True)


async def send_rescue(url: str, headers: dict[str, str], payload: dict[str, Any], stream: bool) -> Any:
    """Отправка на резервный апстрим: одна повторная попытка на транспортную ошибку.
    Резервный путь должен быть надёжнее основного — редкий обрыв связи (сеть, DNS,
    TLS) не должен превращаться в 502 у клиента."""
    try:
        return await send(url, headers, payload, stream)
    except httpx.TransportError:
        return await send(url, headers, payload, stream)


def failover_worthy(resp: Any) -> bool:
    return resp.status_code in FAILOVER_STATUSES


async def models_rescue(headers: dict[str, str]) -> Any:
    """GET /models у резервного апстрима: одна повторная попытка на транспортную ошибку."""
    try:
        return await client.get(f"{FALLBACK_UPSTREAM}/models", headers=headers)
    except httpx.TransportError:
        return await client.get(f"{FALLBACK_UPSTREAM}/models", headers=headers)


@app.get("/health")
async def health() -> JSONResponse:
    return JSONResponse({
        "status": "ok",
        "mode": MODE,
        "upstream": UPSTREAM,
        "key": "set" if (os.environ.get("OPENCODE_GO_API_KEY") or "").strip() else "missing",
        "fallback": FALLBACK_UPSTREAM if failover_enabled() else ("off" if MODE != "deepseek" else "forced"),
        "fallback_model": FALLBACK_MODEL,
        "fallback_key": "set" if fallback_key() else "missing",
        "failover_events": STATE["failover_events"],
        "fallback_requests": STATE["fallback_requests"],
        "last_fallback_at": STATE["last_fallback_at"],
        "primary_cooling": primary_cooling(),
        "last_primary_error": STATE["last_primary_error"],
    })


@app.get("/v1/models")
@app.get("/models")
async def models(request: Request) -> Response:
    if MODE == "deepseek" or (failover_enabled() and primary_cooling()):
        mark_fallback_served()
        resp = await models_rescue(deepseek_headers(request))
        return Response(content=resp.content, status_code=resp.status_code,
                        media_type=resp.headers.get("content-type", "application/json"))
    try:
        resp = await client.get(f"{UPSTREAM}/models", headers=go_headers(request))
    except httpx.HTTPError as exc:
        if not failover_enabled():
            return JSONResponse({"error": {"message": f"relay: upstream unreachable: {exc}"}}, status_code=502)
        mark_primary_error(type(exc).__name__, repr(exc))
        mark_failover(f"models: transport error: {exc!r}")
        mark_fallback_served()
        resp = await models_rescue(deepseek_headers(request))
    if resp.status_code != 200 and failover_enabled():
        mark_primary_error(resp.status_code, resp.text[:400])
        mark_failover(f"models: HTTP {resp.status_code}")
        mark_fallback_served()
        resp = await models_rescue(deepseek_headers(request))
    return Response(content=resp.content, status_code=resp.status_code,
                    media_type=resp.headers.get("content-type", "application/json"))


@app.post("/v1/chat/completions")
@app.post("/chat/completions")
async def chat_completions(request: Request) -> Response:
    raw = await request.body()
    try:
        payload: dict[str, Any] = json.loads(raw or b"{}")
    except json.JSONDecodeError:
        return JSONResponse({"error": {"message": "relay: invalid JSON body"}}, status_code=400)

    if not payload.get("model"):
        return JSONResponse({"error": {"message": "relay: 'model' is required"}}, status_code=400)

    stream = bool(payload.get("stream"))
    fallback_payload = {**payload, "model": FALLBACK_MODEL}

    async def via_fallback(reason: str, new_failure: bool) -> Response:
        if MODE == "auto" and new_failure:
            mark_failover(reason)
        mark_fallback_served()
        resp = await send_rescue(f"{FALLBACK_UPSTREAM}/chat/completions", deepseek_headers(request), fallback_payload, stream)
        return with_fallback_header(await as_response(resp, stream))

    # Режим deepseek — жёсткое переключение: primary не дёргаем вовсе.
    if MODE == "deepseek":
        try:
            return await via_fallback("mode=deepseek", new_failure=False)
        except httpx.HTTPError as exc:
            return JSONResponse({"error": {"message": f"relay: fallback upstream unreachable: {exc}"}}, status_code=502)

    # auto: если primary уже падал — идём напрямую на резерв, пока не истёк cooldown.
    if failover_enabled() and primary_cooling():
        try:
            return await via_fallback("primary cooling down", new_failure=False)
        except httpx.HTTPError as exc:
            return JSONResponse({"error": {"message": f"relay: fallback upstream unreachable: {exc}"}}, status_code=502)

    try:
        resp = await send(f"{UPSTREAM}/chat/completions", go_headers(request), payload, stream)
    except httpx.HTTPError as exc:
        mark_primary_error(type(exc).__name__, repr(exc))
        if not failover_enabled():
            return JSONResponse({"error": {"message": f"relay: upstream unreachable: {exc}"}}, status_code=502)
        return await via_fallback(f"transport error: {exc!r}", new_failure=True)

    if resp.status_code == 200 or not (failover_enabled() and failover_worthy(resp)):
        return await as_response(resp, stream)

    body = await drain(resp, stream)
    detail = body.decode("utf-8", "replace")[:400]
    mark_primary_error(resp.status_code, detail)
    return await via_fallback(f"HTTP {resp.status_code}: {detail}", new_failure=True)


def with_fallback_header(resp: Response) -> Response:
    resp.headers["X-Zen-Relay-Fallback"] = "deepseek"
    return resp


async def drain(resp: Any, stream: bool) -> bytes:
    """Дочитать тело ответа, который больше не понадобится."""
    if stream:
        body = await resp.aread()
        await resp.aclose()
        return body
    return resp.content


async def as_response(resp: Any, stream: bool) -> Response:
    """Привести ответ апстрима к Response, сохраняя SSE-стриминг."""
    if not stream:
        return Response(content=resp.content, status_code=resp.status_code,
                        media_type=resp.headers.get("content-type", "application/json"))
    if resp.status_code != 200:
        body = await drain(resp, True)
        return Response(content=body, status_code=resp.status_code,
                        media_type=resp.headers.get("content-type", "application/json"))

    async def sse() -> AsyncIterator[bytes]:
        try:
            async for chunk in resp.aiter_raw():
                yield chunk
        finally:
            await resp.aclose()

    return StreamingResponse(sse(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


if __name__ == "__main__":
    uvicorn.run(app, host=HOST, port=PORT, log_level=os.environ.get("ZEN_RELAY_LOG_LEVEL", "warning"))
