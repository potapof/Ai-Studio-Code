# Мобильная стратегия MAXSCRM — документ-решение (0.3, 2026-08-10)

Синтез: решения ресёрча (AntD Pro / Material 3 / Apple HIG / WCAG 2.5.8) + архитектор Holix (coordinator, holix run).
Назначение: исполняется OpenHands (junior) без вопросов; токены применяются в `apps/frontend/tailwind.config.js` и `apps/frontend/src/index.css`.

## 1. Breakpoints и навигация

- **Сайдбар**: виден при `lg:` (≥1024px) и выше. Ниже `lg` — скрыт, меню открывается **drawer**'ом (слайд слева) по кнопке-гамбургеру в мобильном хедере.
- **Drawer**: ширина 280px, `max-width: 85vw`, скругление правого края, оверлей `rgba(0,0,0,.5)`, закрытие: оверлей / Esc / клик по пункту / свайп влево.
- **Таб-бары** (StoreAdmin, ProductEditor): скролл-контейнер (`overflow-x-auto`, скрытый скроллбар), авто-скролл активного таба в видимую зону.
- **Bottom nav**: НЕ вводить сейчас (16 пунктов меню > 5; drawer достаточно). Опционально после аудита частоты переходов.
- **Модалки**: на ширине ниже `lg` — bottom sheet (см. п.3).

## 2. Дизайн-токены Tailwind (добавить в tailwind.config.js)

- `minHeight: { touch: '44px' }` — минимальная высота интерактивных элементов.
- `spacing` / отступы контента: мобильный `p-4` (16px), desktop `p-6` (24px) — через существующие утилиты, новые токены не нужны.
- `fontSize`: инпуты/селекты/textarea на мобильном ≥ 16px (iOS авто-зум). Глобально в CSS: `input, select, textarea { font-size: 16px; }` на вьюпортах < 640px (или всегда 16px — проще и безопаснее).
- **safe-area**: утилиты в CSS:
  - `.safe-top { padding-top: env(safe-area-inset-top); }`
  - `.safe-bottom { padding-bottom: env(safe-area-inset-bottom); }`
  - `.safe-left/.safe-right` аналогично; для фиксированных элементов — `height: calc(100dvh - env(safe-area-inset-bottom))` по необходимости.
- **dvh**: заменить `min-h-screen`/`h-screen` на `min-h-dvh`/`h-dvh` во всех full-height лейаутах и оверлеях, с fallback: `@supports not (height: 100dvh) { …100vh… }` (или Tailwind 3.4 поддерживает `min-h-dvh` напрямую — проверить версию).
- `borderRadius: { 'sheet': '1rem' }` — верхние углы bottom sheet (16px; токен `2xl` уже есть).

## 3. Паттерны

- **Таблицы → карточки**: DataTable на < `sm` рендерит каждую строку как Card (label из header, value из render/raw). Горизонтальный скролл — только fallback/опция.
- **Модалки → bottom sheet** (ниже `lg`): скругление верхних углов 16px, drag-handle 36×4px сверху по центру, `max-height: 90dvh`, контент скроллится, закрытие свайпом вниз (порог 80px), бэкдроп, Esc; `padding-bottom: env(safe-area-inset-bottom)`.
- **Touch-цели**: ≥ 44×44px (WCAG 2.5.8); кнопки-иконки — не менее 40×40px с отступом ≥ 8px.
- **iOS-зум**: `font-size: 16px` глобально для input/select/textarea.

## 4. Порядок внедрения

1. **Каркас**: брейкпоинт `lg`, скрытие сайдбара, drawer, гамбургер, токены safe-area/dvh, 16px-инпуты.
2. **Массовая адаптация**: таблицы→карточки, модалки→bottom sheets, touch-цели 44px, паддинги контента.
3. **Перформанс**: code-splitting роутов, мемоизация списков (react-window при >100 строк — по мере необходимости), ленивые картинки, ревизия ре-рендеров zustand.

## 5. Риски webview MAX

- **Клавиатура**: visualViewport сжимает область — фиксированные элементы (drawer, sheet) могут перекрывать инпуты; использовать dvh и проверять `visualViewport.height`.
- **Safe-area**: iPhone с «чёлкой» и жестовой полосой — без `env(safe-area-inset-*)` контент уходит под системные элементы.
- **100vh на Android webview** включает адресную строку — только `dvh`.
- **Zoom-жесты**: отключить на контейнерах (`touch-action`), тесты на реальных iOS Safari и Android WebView (не только Chrome).

## Правило для junior-агентов

Любые новые компоненты — по умолчанию mobile-first (минимум sm/md), токены из tailwind.config, никаких инлайн-пикселей и 100vh.
