# Superpowers Planning — привязка к Студии программирования

> Источник истины по правилам — навык Hermes `superpowers-planning`
> (`~/.hermes/skills/software-development/superpowers-planning/SKILL.md`).
> Этот файл — указатель и сводка для Студии, НЕ дубликат. При расхождении
> правит навык.

## Что установлено
- Плагин **obra/superpowers** v6.3.0 → Hermes-плагин, включён:
  `~/.hermes/plugins/superpowers/` (`.hermes-plugin/__init__.py` + `skill/`)
  и `plugins.enabled` содержит `superpowers`.
- Телеметрия отключена: `SUPERPOWERS_DISABLE_TELEMETRY=true` в `~/.hermes/.env`.

## Когда применять
Когда пользователь просит «создай план работ», «запланируй», «построй план»,
«составь план», «спланируй» → включить флоу superpowers:
1. **`superpowers:brainstorming`** — классификация (spike/bounded/architectural),
   уточнение, дизайн, одобрение (гейт — не кодить до одобрения).
2. **`superpowers:writing-plans`** — план: bite-sized TDD-задачи, точные пути,
   полный код, шаги верификации, No-Placeholders, self-review.
3. **Исполнение:** `superpowers:subagent-driven-development` (Hermes-оркестратор
   диспатчит по задаче + двухэтапный ревью) ИЛИ `superpowers:executing-plans`
   (инлайн с чекпоинтами).

## КРИТИЧНО: как грузить plugin-навыки
Plugin-навыки НЕ в flat `~/.hermes/skills/` и НЕ в `<available_skills>` —
только явно:
- `skill_view("superpowers:<имя>")` (напр. `superpowers:brainstorming`), либо
- `read_file("~/.hermes/plugins/superpowers/skills/<имя>/SKILL.md")` (fallback).

## Ключевые правила Студии
- **Роли:** Hermes = оркестратор (ТЗ/верификация/арбитраж/БЗ), исполнители
  Holix / OpenHands / dsh. Маршрутизация: сложное→Holix, массовое→OpenHands,
  дизайн→dsh, тривиальное→Hermes. Один исполнитель на файл.
- **Гейты:** интерактив — ждать отведа (clarify=пауза); автономный режим —
  Hermes решает сам (INoT Council) и идёт дальше; между фазами одобренного
  плана «продолжать?» НЕ спрашивать.
- **Верификация:** реальные lint/typecheck/test/build гоняет Hermes.
- **Рекон:** полный grep, без дублей существующего кода.
- **БЗ:** log_agent_session + record_loop_run + handoff.

## Локация планов/спек
- Код-проект: `<проект>/docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`
  и `<проект>/docs/superpowers/plans/YYYY-MM-DD-<feature>.md`.
- Внутри-студийные планы: `~/studio/PLAN-<topic>.md`.

## Приоритет
- Для планирования superpowers > встроенный `plan` (тот — облегчённый fallback,
  его craft уже адаптирован из superpowers).
- `superpowers:*`-версии навыков (TDD/debugging/review) в рамках флоу.
