# Студия дизайна и платформа — схемы (archify)

Интерактивные SVG-схемы архифая по Студии программирования: дизайн-стек и инфраструктура
платформы. Источники фактов: `~/studio/docs/16-design-studio.md`, `dsh-integration`,
`PROMPT-INOT-COUNCIL.md`, `12-loop-engineering.md`, `docker-compose.yml`.

| Схема | Тип | Файл | Статус | Что показывает |
|---|---|---|---|---|
| Стек студии дизайна | architecture | [design-studio.architecture.html](design-studio.architecture.html) | ✅ validate+deliver | Hermes → Herdr → dsh/OpenDesign → артефакты; роли |
| Цикл дизайн-задачи | workflow | [design-cycle.workflow.html](design-cycle.workflow.html) | ✅ validate+deliver | Исследование → план с ролями → реализация → тест → фикс → приёмка |
| Делегирование dsh | sequence | [design-delegation.sequence.html](design-delegation.sequence.html) | ✅ validate+deliver | Hermes → dsh-delegate → dsh(open-design) → референсы → артефакт → БЗ |
| Данные дизайна | dataflow | [design-data.dataflow.html](design-data.dataflow.html) | ✅ validate+deliver+visual | DESIGN.md + PNG → dsh (vision) → OpenDesign → артефакт |
| Цикл OpenDesign | lifecycle | [design-open-design-cycle.lifecycle.html](design-open-design-cycle.lifecycle.html) | ✅ validate+deliver | Бриф → направление → артефакт → критика → доставка/доработка |
| Loop-инжиниринг волна | workflow | [loop-engineering.workflow.html](loop-engineering.workflow.html) | ✅ validate+deliver | Trigger → контекст → Maker(OpenHands) → Checker(Holix) → Arbiter(Hermes) → HANDOFF |
| Мультиплексор агентов | architecture | [studio-agents.architecture.html](studio-agents.architecture.html) | ✅ validate+deliver | Holix/OpenHands/dsh → Herdr :8010 → Postgres (БЗ) |
| Мозг (БЗ) | dataflow | [studio-brain.dataflow.html](studio-brain.dataflow.html) | ✅ validate+deliver+visual | Документы/прогоны → эмбеддинги → pgvector + AGE → k-NN поиск |
| Docker-стек инфры | architecture | [studio-docker-stack.architecture.html](studio-docker-stack.architecture.html) | ✅ validate+deliver+visual | postgres-age, nocodb, redis, postgres, portainer, egress, syncthing, holix |

## Как это работает
- **dsh** — агентный харнесс DeepSeek (профиль `open-design` встраивает OpenDesign).
- **OpenDesign** — движок артефактов (web/desktop/mobile, slides, images; экспорт HTML/PDF/PPTX/MP4).
- **Loop-инжиниринг** — maker-checker-arbiter: OpenHands (maker) → Holix-checker → Hermes-arbiter;
  результат → HANDOFF.md в БЗ; контекст из прошлых прогонов (векторный поиск + SOA).
- **БЗ (мозг)** — Postgres pg16-age-vector: pgvector (эмбеддинги) + Apache AGE (code_graph/task_graph).
- **Herdr** — мультиплексор :8010: Holix/OpenHands/dsh → gateway → конвергентная БД.
- **Дизайн-материалы**: `/media/sf_OBSHAYA/screen` (DESIGN.md, UI_KIT.md, PATTERNS_*, 313 PNG).

## Прогон
```bash
node ~/.hermes/skills/software-development/archify/bin/archify.mjs validate|deliver <тип> <spec> <out> --quality showcase
```
Спеки (`.json`) — источники; HTML — артефакты (пересобираются командой выше).
Часть высоких схем (workflow/sequence/lifecycle с ветками) упирается в containment-скролл
лимита архифая (то же у эталонных примеров); validate showcase и deliver — зелёные.
