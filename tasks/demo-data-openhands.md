# ТЗ ДЛЯ OPENHANDS: кнопка «Загрузить демо данные» в дашборде

Роль: исполнитель (frontend). Рабочая директория:
/home/potapof/studio/projects/maxscrm/repo

## Контекст
- MAXSCRM: Vite + React + TypeScript фронтенд в apps/frontend.
- В дашборде УЖЕ есть кнопка удаления демо-данных: apps/frontend/src/pages/dashboard/
  DashboardPage.tsx использует resetDemoData из apps/frontend/src/lib/api.ts
  (POST /api/v1/admin/demo-reset, мутация resetMutation, toast, invalidateQueries).
  НАЙДИ эту кнопку в JSX (ищи resetMutation / «Удалить демо») — она есть.
- Бэкенд (параллельно другой агент) добавит POST /api/v1/admin/demo-load —
  загрузка демо-данных в текущую организацию (админ).

## Задача
1. apps/frontend/src/lib/api.ts:
   - Добавь тип DemoLoadResult: { loaded: boolean; counts: Record<string, number> }.
   - Добавь функцию loadDemoData(): Promise<DemoLoadResult> — по образцу
     resetDemoData (POST /api/v1/admin/demo-load, заголовок Authorization как там).
2. apps/frontend/src/pages/dashboard/DashboardPage.tsx:
   - Добавь useMutation loadMutation (mutationFn: loadDemoData) по образцу
     resetMutation: onSuccess — toast об успехе (например, «Демо-данные загружены»)
     + invalidateQueries(); onError — toast об ошибке.
   - В JSX рядом с кнопкой удаления демо добавь кнопку «Загрузить демо данные»
     (стиль как у соседней; иконка — любую подходящую из lucide-react, например
     Database или Download; loading-состояние — disabled + спиннер как у соседней).
   - Убедись, что обе кнопки видны только админу, если соседняя так ограничена
     (проверь условие, повтори его).
3. НЕ трогай: другие файлы, логику resetDemoData, стили глобально.

## Критерии готовности
- pnpm run typecheck в apps/frontend — без ошибок.
- pnpm run lint (frontend) — без НОВЫХ errors.
- pnpm run test (frontend, vitest) — зелёные (если есть тесты DashboardPage —
  посмотри, обнови при необходимости; если тестов нет — не создавай).
- Не коммитить, не пушить — только файлы. В конце краткий отчёт: что изменено,
  как выглядит кнопка.
