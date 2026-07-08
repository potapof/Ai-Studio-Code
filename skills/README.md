# Каталог навыков «Студии программирования»

Все навыки хранятся в этом репозитории как единственный источник истины.
При развёртывании загружаются в PostgreSQL (hermes_brain.skills) для RAG-поиска.

## Доступные навыки

| Навык | Назначение | Тип |
|-------|-----------|-----|
| [deploy-studio](./deploy-studio/SKILL.md) | Полное развёртывание платформы с нуля | procedural |
| [morning-triage](./morning-triage/SKILL.md) | Утренний разбор ошибок и инцидентов | loop |
| [pr-drafting](./pr-drafting/SKILL.md) | Автоматическая генерация Pull Request из Issue | handoff |
| [flaky-test-fix](./flaky-test-fix/SKILL.md) | Исправление нестабильных тестов | loop |
| [lint-and-fix](./lint-and-fix/SKILL.md) | Автофиксы стиля кода | loop |
| [dependency-update](./dependency-update/SKILL.md) | Еженедельное обновление зависимостей | loop |

## Как добавить новый навык

1. Создать папку `skills/имя-навыка/`
2. Добавить `SKILL.md` (обязательно)
3. При необходимости: `scripts/`, `templates/`, `data/`
4. `git add` → `git commit` → `git push`
5. Запустить `scripts/sync-skills.sh` для загрузки в БД

## Как это работает

```
GitHub (источник истины)          PostgreSQL (оперативный кэш)
─────────────────────────          ─────────────────────────
skills/                            public.skills
  ├── deploy-studio/SKILL.md  ───→ запись + embedding
  ├── morning-triage/SKILL.md ───→ запись + embedding
  └── ...                          ...

Агент сканирует каталог (короткое описание) → выбирает навык →
загружает полный SKILL.md → выполняет задачу.
```
