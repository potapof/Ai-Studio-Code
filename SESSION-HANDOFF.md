# SESSION HANDOFF — Студия программирования

Обновлено: 2026-07-11 (ночной автономный прогон). Читать первым.

═══════════════════════════════════════════════════════════
ГЛАВНОЕ ЗА НОЧЬ: агентское исполнение Holix ПОЧИНЕНО
═══════════════════════════════════════════════════════════
Было: `/v1/chat/completions` на воркерах зависал (100%+ CPU, нет ответа) — Hermes
не мог делегировать Holix-воркерам. Стало: воркер отвечает реальным контентом
(проверено: «2+2»→"4", «7×6»→"42" через coordinator gateway с ключом).

ДВЕ КОРНЕВЫЕ ПРИЧИНЫ (найдены py-spy + чтением исходников Holix):
1. ЗАВИСАНИЕ = onnxruntime thread-thrash. LangGraph-нода `memory_retrieval_node`
   на КАЖДЫЙ запрос делает ChromaDB-эмбеддинг (ONNX MiniLM). onnxruntime плодит
   потоки по числу ядер ХОСТА (12+), а cgroup-лимит `cpus:'1'` → трэшинг → создание
   ONNX-сессии тянется минутами. Фикс: поднять лимит CPU (coordinator cpus:'6').
2. «Agent completed without producing a final response» (tokens=0) = баг LangGraph-
   пути в Holix 0.1.21: `core/agent.py::_run_with_graph` ловит ответ только из
   `FinalResponseEvent`, а граф его не эмитит с контентом. Фикс: `USE_LANGGRAPH=false`
   → агент идёт легаси-путём (`core/agent_execution.py`), который возвращает контент.

КРИТИЧНЫЕ НАСТРОЙКИ (иначе не работает):
- Модель агента = `deepseek-chat` (НЕ reasoning `deepseek-v4-flash`! reasoning отдаёт
  пустой content + reasoning_content → легаси-путь получает пусто). При
  `models_via_providers: true` агент берёт ПРОВАЙДЕРСКИЙ `default_model` — его надо
  форсить (в wrapper есть `sed default_model→deepseek-chat`, т.к. `holix models add`
  на эфемерном /root/.holix сбрасывает его на первый = v4-flash).
- `USE_LANGGRAPH=false` (в ~/studio/.env, все воркеры через env_file).
- CPU-лимит контейнера ≥ несколько ядер (иначе ONNX-трэшинг в warm-up и памяти).
- ⚠️ Имена ENV Holix БЕЗ префикса, если у поля в config.py нет validation_alias:
  `REQUIRE_AUTH` (НЕ HOLIX_REQUIRE_AUTH!), `USE_LANGGRAPH`, `MODEL`,
  `ENABLE_LONG_TERM_MEMORY`, `AUTO_SUMMARIZE_CONVERSATIONS`, `NON_INTERACTIVE`.
  С alias (префикс HOLIX_ работает): `HOLIX_GATEWAY_HOST/PORT`, `HOLIX_API_KEY_PEPPER`,
  `HOLIX_ENV`, `HOLIX_LOG_DEBUG`. Всегда сверять по config.py (validation_alias).

═══════════════════════════════════════════════════════════
СОСТОЯНИЕ ПЛАТФОРМЫ (актуально)
═══════════════════════════════════════════════════════════
- Единый проект studio-code (~/studio/docker-compose.yml).
- Holix обновлён 0.1.19 → **0.1.21** на всех 8 воркерах (образ
  `ai-studio-holix-backend:0.1.21`/`:latest`, id cf7bad3d27ab; собран инкрементально
  `FROM :0.1.19 + pipx install "Holix[all]==0.1.21"` + запечённая ChromaDB-модель).
  Старый образ сохранён как `:0.1.19` и в backups/*.tar.gz — откат.
- 8 holix-воркеров: coordinator, archivist, backend-lead, frontend-lead, qa,
  loop-checker, lint, backend-executor. Все на deepseek-chat + USE_LANGGRAPH=false.
- Gateway: bind 0.0.0.0:8000 у всех; coordinator опубликован на хост
  **127.0.0.1:8010** (точка входа Hermes). Health у всех 200 (после warm-up).
- Auth: coordinator require_auth=true + hx_-ключ (в ~/studio/.holix-hermes-key.txt
  и ~/.hermes/.env как HOLIX_GATEWAY_KEY); постоянный том /root/.holix у coordinator
  (bind ~/ai-studio/holix/coordinator/.holix) → ключ переживает пересоздание.
  Роли: require_auth=true, но КЛЮЧА НЕТ (эфемерный /root/.holix) → см. next-steps.
- LLM: провайдер deepseek; агент — deepseek-chat; провайдер знает и v4-flash/pro.
- MCP postgres: как было (crystaldba, restricted).

═══════════════════════════════════════════════════════════
ПРОВЕРЕНО (реальным выводом)
═══════════════════════════════════════════════════════════
- coordinator /v1/chat/completions с hx_-ключом → HTTP 200, content "4" и "42".
- Все 8 воркеров: образ 0.1.21, restart=0, gateway health 200 (по DNS/хост).
- qa (роль): конфиг deepseek-chat + USE_LANGGRAPH=false + провайдерский
  default_model=deepseek-chat — идентичен coordinator (агентское исполнение работает).
- Без ключа /v1/models → 401, с ключом → 200 (auth).

⚠️ Скорость: агентский ответ ~45-70с (ONNX memory-retrieval при warm-up + шаги ReAct).
Работает, но медленно — кандидат на оптимизацию (см. next-steps).

═══════════════════════════════════════════════════════════
NEXT STEPS (не сделано за ночь — осознанно отложено)
═══════════════════════════════════════════════════════════
1. AUTH-WIRING РОЛЕЙ: у 6 ролей эфемерный /root/.holix → нет hx_-ключа, их /v1
   закрыт 401. Варианты: (а) REQUIRE_AUTH=false для внутренних ролей (доступны только
   в docker-сети) — но .env общий с coordinator, нужен отдельный механизм/override;
   (б) постоянный том /root/.holix каждому + bootstrap ключа; (в) единый ключ через
   общий том security/. Решить с пользователем.
2. СОСТАВ К ЗАМЫСЛУ: тимлиды делегируют `holix-python-dev`/`holix-react-dev` —
   таких контейнеров НЕТ. backend-executor — сирота без yaml-роли. Добавить dev-
   исполнителей и прописать делегирование (по согласованию — см. диалог).
3. E2E: настроить Hermes (хост) на вызов coordinator (`--delegate-to` / custom
   provider на http://127.0.0.1:8010/v1, ключ hx_), прогнать maker-checker.
4. СКОРОСТЬ: агентский ответ 45-70с. Профилировать: возможно, отключить
   conversation-memory-retrieval полностью (не только LTM) или поднять cpus ролям.
5. РОЛЯМ поднять cpus (сейчас '1' у части → warm-up ~4мин, трэшинг). Дать 2-4 ядра.

═══════════════════════════════════════════════════════════
БЫСТРЫЙ СТАРТ НОВОЙ СЕССИИ
═══════════════════════════════════════════════════════════
```bash
cd ~/studio && docker compose ps                      # 14 контейнеров
# health воркеров (по DNS из coordinator — надёжнее exec под нагрузкой):
for c in holix-coordinator holix-qa holix-lint; do \
 docker exec holix-coordinator curl -s -o /dev/null -w "$c=%{http_code}\n" http://$c:8000/health; done
# боевой агентский тест (ключ в файле):
KEY=$(cat ~/studio/.holix-hermes-key.txt)
curl -s --max-time 120 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
 -X POST http://127.0.0.1:8010/v1/chat/completions \
 -d '{"model":"default","messages":[{"role":"user","content":"2+2? одним числом"}],"max_tokens":100}'
```
Диагностика зависания агента: `docker exec <c> pip install --break-system-packages py-spy`
(нужен cap_add SYS_PTRACE), затем `py-spy dump --pid 1` во время запроса.

═══════════════════════════════════════════════════════════
КЛЮЧЕВЫЕ ФАЙЛЫ
═══════════════════════════════════════════════════════════
```
~/studio/docker-compose.yml                 — стек (ветка feature/holix-upgrade)
~/studio/.env                                — секреты + USE_LANGGRAPH/ENABLE_LTM/OMP (gitignore)
~/studio/.holix-hermes-key.txt               — hx_-ключ coordinator (chmod 600, gitignore)
~/ai-studio/holix/backend/Dockerfile          — база образа (пин)
~/ai-studio/holix/backend/Dockerfile.update   — инкрементальная сборка 0.1.21 + bake модели
~/ai-studio/holix/coordinator/.holix          — постоянный профиль coordinator (ключ/конфиг)
~/studio/backups/holix-image-0.1.19-*.tar.gz  — откат образа
~/studio/PLAN-HOLIX-NIGHT.md                  — план ночного прогона
```
Навык deploy-studio (Проблема 18) — полный разбор фикса агентского исполнения.
