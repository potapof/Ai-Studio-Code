# 16. Студия дизайна: DeepSeek Harness + OpenDesign

Дата добавления: 2026-08-18 · Статус: работает, включена в чеклист готовности (секция 7)

Студия дизайна = связка из двух инструментов, которые Hermes использует для
дизайн-работы (генерация прототипов, лендингов, слайдов, дизайн-систем):

1. **DeepSeek Harness (`dsh`)** — официальный agent harness DeepSeek AI
   (github.com/deepseek-ai/deepseek-harness). Режимы: Web UI (:3080),
   `--profile headless "задача"` (одна задача → ответ → exit), Python SDK.
2. **OpenDesign (`nexu-io/open-design`)** — дизайн-движок для агентов
   (прототипы, landing, дашборды, слайды, изображения; экспорт HTML/PDF/PPTX/MP4).
   Встраивается в dsh через профиль `open-design` (пакет `@open-design/dsh-runtime`).

## Установленное окружение

| Компонент | Где | Версия |
|---|---|---|
| Node.js | системный (через `n`) | 24.19.0 (dsh требует ≥22, OpenDesign ~24) |
| pnpm | глобально (npm i -g pnpm@10) | 10.33.2 |
| dsh CLI | глобально (npm i -g @deepseek-ai/dsh) | 0.1.0-rc.7 |
| dsh Python SDK | ~/studio/.venv-dsh | 0.1.0rc7 |
| dsh-runtime (OpenDesign) | профиль `dsh --profile open-design` | 0.1.0 |
| OpenDesign исходники | ~/studio/open-design (clone, в .gitignore) | v0.19.2 |
| OpenDesign daemon | http://127.0.0.1:7456 (фон) | daemon собран |
| Web-UI OpenDesign | http://127.0.0.1:7456 (Next.js static export в apps/web/out) | — |

Ключ: `DEEPSEEK_API_KEY` из ~/studio/.env (подхватывается автоматически).
Модель: `DSH_MODEL=deepseek-v4-flash` (или deepseek-v4-pro).

## Проверка в чеклисте готовности

`bash ~/studio/scripts/studio-readiness.sh` — секция «7. Студия дизайна» проверяет:
- dsh CLI (`dsh --version`)
- профиль open-design (`dsh --profile open-design --probe` → runtime open-design)
- OpenDesign daemon (:7456 → HTTP 200)

`--deep` дополнительно: smoke dsh headless (`dsh --profile headless "D-OK"`).

## Подъём, если не работает

```bash
# dsh CLI нет
npm i -g @deepseek-ai/dsh          # Node>=22: sudo n 24

# профиль open-design слетел
dsh plugin --profile open-design add ~/studio/dsh/open-design-dsh-runtime-0.1.0.tgz

# daemon не запущен
cd ~/studio/open-design/apps/daemon && node dist/cli.js --no-open   # фон

# если open-design/ удалён — пересоздать:
git clone --depth 1 https://github.com/nexu-io/open-design.git ~/studio/open-design
cd ~/studio/open-design && pnpm install        # ~10 мин
pnpm --filter @open-design/dsh-runtime build
pnpm -C packages/dsh-runtime pack --pack-destination ~/studio/dsh/
pnpm --filter @open-design/daemon build        # daemon
pnpm --filter @open-design/web... build        # web-UI (Next.js, out/)
dsh plugin --profile open-design add ~/studio/dsh/open-design-dsh-runtime-<ver>.tgz
```

## Использование

```bash
# Быстрая дизайн-задача (DeepSeek напрямую, файлы+команды)
set -a; source ~/studio/.env; set +a
DSH_MODEL=deepseek-v4-flash dsh --profile headless "сгенерируй landing по DESIGN.md"

# Из Hermes: делегатор (аналог holix-delegate.sh)
~/studio/.venv-dsh/bin/python ~/studio/scripts/dsh-delegate.py "задача" \
  --workspace /путь/к/работе --session-id имя

# Полный цикл с артефактами OpenDesign (html/pdf/zip)
cd ~/studio/open-design/apps/daemon
node dist/cli.js project create --name "проект"
node dist/cli.js artifacts create --name file.html --input /путь/file.html --project "проект"
```

Проверено живыми прогонами 2026-08-18: headless дизайн-задача (чтение DESIGN_MOBILE.md →
3 правила), генерация landing.html по токенам maxscrm (primary #0F766E и др.),
регистрация артефакта через od (kind html, exports html/pdf/zip),
`od agent setup deepseek-harness --json` → already-compatible.

## Референсы дизайна maxscrm

Дизайн-система и экраны (не в git, общая папка VM): `/media/sf_OBSHAYA/screen`
(DESIGN.md, DESIGN_DESKTOP.md, DESIGN_MOBILE.md, UI_KIT.md, PATTERNS_*, SCREEN_MAP.md,
SYSTEM_PROMPT_STITCH.md + ~313 PNG экранов).
