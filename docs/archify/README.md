# Студия дизайна — схемы (archify)

Как всё устроено в Студии дизайна: **Hermes** (оркестратор) → **dsh** (DeepSeek Harness,
исполнитель дизайна) + **OpenDesign** (движок артефактов), поверх **дизайн-ресурсов**
и с записью результата в **hermes_brain**. Собраны archify из фактов документации
(`~/studio/docs/16-design-studio.md`, `dsh-integration`, `INoT Council`).

| Схема | Тип | Файл | Статус | Что показывает |
|---|---|---|---|---|
| Стек студии дизайна | architecture | [design-studio.architecture.html](design-studio.architecture.html) | ✅ validate+deliver | Hermes → Herdr → dsh/OpenDesign → артефакты; роли |
| Цикл дизайн-задачи | workflow | [design-cycle.workflow.html](design-cycle.workflow.html) | ✅ validate+deliver | Исследование → план с ролями → реализация → тест → фикс → приёмка |
| Делегирование dsh | sequence | [design-delegation.sequence.html](design-delegation.sequence.html) | ✅ validate+deliver | Hermes → dsh-delegate → dsh(open-design) → референсы → артефакт → БЗ |
| Данные дизайна | dataflow | [design-data.dataflow.html](design-data.dataflow.html) | ✅ validate+deliver+visual | DESIGN.md + PNG → dsh (vision) → OpenDesign → артефакт |
| Цикл OpenDesign | lifecycle | [design-open-design-cycle.lifecycle.html](design-open-design-cycle.lifecycle.html) | ✅ validate+deliver | Бриф → направление → артефакт → критика → доставка/доработка |

## Как это работает
- **dsh** — агентный харнесс DeepSeek; профиль `open-design` встраивает OpenDesign как runtime
  (struct. thinking, tool calls, session resume). Модель `deepseek-v4-flash-vision-exp` (мультимедиа).
- **OpenDesign** — движок: web/desktop/mobile прототипы, дашборды, слайды, изображения, video;
  экспорт HTML/PDF/PPTX/MP4; sandboxed iframe preview. Daemon :7456 + Web-UI.
- **Делегирование**: `~/studio/scripts/dsh-delegate.py` (или `dsh --profile headless "..."`) —
  обязательно `source ~/studio/.env` (иначе dsh стартует без ключа и молча выходит).
- **Роли**: Hermes — управляющий (решения/арбитраж); dsh — дизайн; Holix/OpenHands — dev/test.
- **INoT Council** — автономный процесс решений (диагностика → 4 агента → 3 раунда → консенсус).
- **Дизайн-материалы**: `/media/sf_OBSHAYA/screen` (DESIGN.md, UI_KIT.md, PATTERNS_*, 313 PNG).

## Прогон
```bash
node ~/.hermes/skills/software-development/archify/bin/archify.mjs validate|deliver <тип> <spec> <out> --quality showcase
```
Все спеки (`.json`) — источники; HTML — артефакты архифая (пересобираются командой выше).
