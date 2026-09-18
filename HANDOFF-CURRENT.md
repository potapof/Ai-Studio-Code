# HANDOFF-CURRENT — передача смены (перезаписывается при каждой передаче)

**Обновлено:** 2026-09-18, сессия после 20260918_134841 (Hermes)
**Тема смены:** Студия дизайна загружена; собраны ОТКАТ на DeepSeek (авто + переключатель),
ключ подписки перенесён в env; Holix переведён на релей.

---

## 1. Что сделано этой сменой и чем проверено

| Что | Файлы | Живая проверка |
|---|---|---|
| Откат в релее: при сбое Go (401/402/403/404/408/409/425/429/5xx/обрыв) запрос повторяется к `api.deepseek.com`, ответ помечен `X-Zen-Relay-Fallback: deepseek`; после сбоя primary не дёргается `ZEN_RELAY_COOLDOWN` (300с) | `~/studio/scripts/zen-go-relay.py`, юнит `~/.config/systemd/user/zen-go-relay.service` | Стенд (заглушка-429 на :8099 вместо Go, релей :8013): не-стрим → 200 «FB-OK» + заголовок; повторный запрос 1с, в primary 1 попадание (cooldown); стрим → 200 + `[DONE]`; `/models` → резерв; транспортная ошибка (`:9`) → резерв; режим `go` → 429 отдан как есть |
| Повтор на резервном пути (редкий обрыв связи не становится 502) | `zen-go-relay.py` (`send_rescue`) | Заглушка-«нестабильный резерв» рвёт 1-е соединение → 2 попадания, ответ 200 «RETRY-OK» |
| Переключатель всей Студии | `~/studio/scripts/studio-model-switch.sh` (`auto|go|deepseek|status`) | `auto` → «ответила: OpenCode Go»; `deepseek` → «ответила: DeepSeek (откат)», dsh `DS-MODE-OK`, Holix python-dev `WORKER-DS-OK` (25с); обратно `auto` → снова Go, OCR ✓, OpenHands `OH-OK` (10.4с) |
| Нативный откат Hermes | `~/.hermes/config.yaml` → `fallback_providers: [{deepseek, deepseek-v4-flash-vision-exp}]` | `hermes fallback list` → Primary opencode-go/deepseek-v4.1-flash, Fallback 1 deepseek |
| Ключ подписки перенесён в env, файл удалён | `~/studio/.env` (+`EnvironmentFile` в юните, `start-holix-gateway.sh`, `studio-readiness.sh`) | Дублирование проверено хешами (studio/.env = hermes/.env = старый файл), файл `shred -u`; релей `/health` → `key=set`; в env живого gateway-воркера ключ есть; чеклист PASS=23 FAIL=0 |
| Holix (10 профилей) переведён на релей — воркеры получают тот же откат | `~/.holix-host/profiles/*/config.yaml` (`base_url: http://127.0.0.1:8012/v1`), бэкап `~/studio/backups/holix-profiles-prerelay-20260918-1650/` | python-dev с инструментом: создал `/tmp/holix-relay-check.txt` = `HOLIX-RELAY-OK`, ответ `done` (57с); прогрев default «OK» (20с) |
| Документация | навыки `herdr-integration` (+`references/design-studio-dsh.md`), `studio-readiness`, `~/studio/docs/16-design-studio.md` | — |

Ключевые факты: модель `deepseek-v4.1-flash` есть только в подписке OpenCode Go (на api.deepseek.com
доступны `deepseek-flash` и `deepseek-v4-pro`), подписка требует заголовок `x-opencode-session` →
через релей ходят ВСЕ исполнители, кроме Hermes (Holix, dsh, OpenHands, open-code-review).

## 2. Что проверить первым делом в новой сессии

```bash
bash ~/studio/scripts/studio-readiness.sh                       # ожидаем PASS=23 FAIL=0
bash ~/studio/scripts/studio-model-switch.sh status             # режим релея + health + смоук (кто ответил)
curl -s 127.0.0.1:8012/health | python3 -m json.tool            # key=set, fallback_key=set, mode=auto
```

## 3. Открытые вопросы — ЖДУТ РЕШЕНИЯ ПОЛЬЗОВАТЕЛЯ

1. **Коммит/пуш изменений** `~/studio` — **закрыто этой же сменой**: коммит `9c81b29`
   (96 файлов, ~10.7 МБ: скрипты отката, доки, archify-схемы, планы/задачи/отчёты прошлых смен),
   запушен в `Ai-Studio-Code` main (проверено `git ls-remote` = локальный HEAD). Внешний клон
   инструмента `archify/` добавлен в `.gitignore` как `/archify/` (без якоря он задевал `docs/archify/`).
   Untracked-файлы внутри `projects/maxscrm/repo` — по-прежнему dirty: вложенный репозиторий
   НЕ трогал (свой CI и деплой стадий, только по явной просьбе).
2. **`openhands-delegate.sh`** — **закрыто**: вызывает `/home/potapof/studio/.venv/bin/python3`
   (проверено: `DELEGATE-OK`, 9.6с). Ранее падал с `ModuleNotFoundError: No module named 'openhands'`.
3. **Сторож квоты Go** (не делал): сейчас откат срабатывает по факту ошибки у клиентов релея и
   в fallback-цепочке Hermes. Если нужно, чтобы Студия сама переключалась в `deepseek` по факту
   исчерпания квоты (или дёргала уведомление) — нужен cron/watchdog со смоуком и вызовом
   `studio-model-switch.sh`. Жду решения.
4. OpenCode CLI — **решение пользователя: не ставить, вопрос закрыт** (не поднимать).
5. Ключ подписки — **закрыто**: перенесён в `~/studio/.env` (+ `~/.hermes/.env` для Hermes),
   файл `~/studio/.opencode-go-key.txt` удалён.

## 4. Откат / переключение (если подписка Go кончилась)

```bash
bash ~/studio/scripts/studio-model-switch.sh deepseek    # вся Студия на DeepSeek (релей + Hermes), со смоуком
bash ~/studio/scripts/studio-model-switch.sh auto        # штатный режим: Go + автооткат
bash ~/studio/scripts/studio-model-switch.sh go          # только Go, отката нет
```

Резервная модель — `ZEN_RELAY_FALLBACK_MODEL` (по умолчанию `deepseek-v4-flash-vision-exp`), ключ —
`DEEPSEEK_API_KEY` из `~/studio/.env`. Holix на релей переводился из бэкапа
`~/studio/backups/holix-profiles-prerelay-20260918-1650/` (вернуть профили → `cp` обратно → рестарт
gateway + прогрев default).

## 5. Диагностика ошибок (быстрое распознавание)

| Симптом | Причина | Лечение |
|---|---|---|
| Ответ с заголовком `X-Zen-Relay-Fallback: deepseek` | Go отдал ошибку — сработал откат | смотреть `/health` → `last_primary_error` |
| `/health` → `primary_cooling=true`, рост `fallback_requests` | primary упал, идёт cooldown 300с | причина в `last_primary_error` |
| HTTP 400 `MissingSessionID` | клиент идёт прямо в Go без заголовка | направлять через релей :8012 |
| HTTP 401 `ModelError: Model X is not supported` | id модели не из подписки Go | сверить с `curl -s 127.0.0.1:8012/v1/models` |
| dsh/OCR/OpenHands падают, Holix жив | лёг релей | `systemctl --user restart zen-go-relay.service` |
| Holix отвечает «пустой ответ» | профили не перечитались | рестарт gateway + прогрев default (~30с) |
| `holix-delegate.sh` → No module named 'openhands' | запуск OpenHands не из venv Студии | `~/studio/.venv/bin/python3 ~/studio/scripts/openhands-sdk-delegate.py …` |
