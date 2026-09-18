# REPORT-MOBILE-AUDIT — Реестр дефектов мобильной версии (0.2, 2026-08-10)

Источники: baseline-скриншоты Playwright (68 PNG, 4 вьюпорта × 17 маршрутов, `apps/frontend/e2e/mobile/`), код-ревью лейаутов/компонентов, программный анализ скриншотов (PIL).
Дата baseline: 2026-08-10 19:22. Ветка: develop (до начала мобильной оптимизации).

## Ключевая метрика: сайдбар на мобильных (P0 — жалоба пользователя)

Замер границы сайдбара по скриншотам (серый border `#E2E8F0`, все страницы админки):

| Вьюпорт | CSS-ширина | Ширина меню | Доля экрана | Вердикт |
|---|---|---|---|---|
| Pixel 7 (mobile-chrome) | 412px | 239px | **57.9%** | ❌ P0 |
| iPhone 12 (mobile-safari) | 390px | 239px | **61.3%** | ❌ P0 |
| iPad gen 7 (tablet) | 810px | 239px | **29.5%** | ❌ P1 (планшет тоже страдает) |
| Desktop 1280×800 | 1280px | 240px | 18.7% | ✅ норма |

Контент на телефоне сжат до ~150-160px — обрезан, нечитаем. Причина: `AppLayout.tsx:31` — `<aside className="w-60 shrink-0 ...">` без единого responsive-класса. Метрика `documentElement.scrollWidth > clientWidth` НЕ ловит эту проблему (flex сжимает контент, не выступая за границы) — поэтому в REPORT-RAW overflow=0 при визуально сломанном макете. Это тех.долг: в mobile-audit нужна доп. проверка (см. п.10).

## Реестр дефектов (приоритет → раздел плана)

| # | Приоритет | Дефект | Файл(ы) | Раздел плана |
|---|---|---|---|---|
| 1 | **P0** | Сайдбар 240px занимает 58-61% экрана телефона, контент обрезан | `src/app/layouts/AppLayout.tsx` | Раздел 1 |
| 2 | **P0** | Нет мобильного хедера (гамбургер), меню нельзя скрыть | там же | Раздел 1 |
| 3 | P1 | StoreAdminLayout: таб-бар `flex` без `overflow-x-auto` — 11 табов вылезают за экран | `src/pages/store/StoreAdminLayout.tsx` | Раздел 2 |
| 4 | P1 | DataTable: нет карточного вида, только горизонтальный скролл (10 страниц: дашборд-активности, контакты, сделки, заказы, товары, бренды, шаблоны, campaigns, subscriber/template/automation-списки) | `src/components/ui/DataTable.tsx` | Раздел 3 |
| 5 | P1 | Modal: центрированный диалог на мобильных (17 мест), не bottom sheet | `src/components/ui/Modal.tsx` | Раздел 4 |
| 6 | P1 | Touch-цели: токен `min-h-touch` добавлен (0.3b), но НЕ применён к Button/Input/Select/ссылкам меню | `tailwind.config.js` + компоненты | Раздел 5 |
| 7 | P1 | iOS-зум: правило `font-size:16px` для input/select/textarea добавлено глобально (0.3b) — проверить, что не перекрывается | `src/index.css` | Раздел 5 |
| 8 | P2 | ProductEditorLayout: `px-6/p-6` неадаптивны, хедер перегружен на мобильном | `src/app/layouts/ProductEditorLayout.tsx` | Раздел 2 |
| 9 | P2 | StorefrontLayout: шапка (Лояльность/Избранное/Корзина текстом) рискует не влезть на <360px | `src/app/layouts/StorefrontLayout.tsx` | Раздел 7 |
| 10 | P2 | PageHeader: actions сжимаются в одну строку с заголовком | `src/components/ui/PageHeader.tsx` | Раздел 5 |
| 11 | P2 | App.tsx: ~50 статических импортов, нет code-split → тяжёлый старт на мобильных | `src/App.tsx` | Раздел 8 |
| 12 | P2 | Меню 16 пунктов без группировки — длинный скролл в drawer | `AppLayout.tsx` (NAV) | Раздел 1 |
| 13 | P2 | mobile-audit: метрика overflow не ловит flex-сжатие контента — добавить проверку «минимальная ширина контента» (напр. `main` должен быть ≥ 320px, скриншот-дифф после фиксов) | `e2e/mobile/mobile-audit.spec.ts` | Раздел 9 |

## Что уже хорошо (не ломать)

- viewport meta на месте (`index.html`)
- Дашборд: сетка метрик уже 1-col на мобильном (`grid-cols-1 sm:grid-cols-2 lg:grid-cols-4`)
- ProductEditorLayout табы уже с `overflow-x-auto`
- Сторефронт `/s/demo`: `max-w-6xl px-4` — отрисовался целиком на всех вьюпортах
- Все 16 админ-маршрутов + витрина отдают 200 и рендерятся (нет белых экранов/редиректов после dev-логина)
- Токены мобильной базы уже в коде (0.3b): `min-h-touch`, `rounded-sheet`, safe-утилиты, 16px-инпуты, tailwind 3.4.19 → `min-h-dvh` из коробки

## Артефакты

- Скриншоты: `apps/frontend/e2e/mobile/screenshots/{mobile-chrome,mobile-safari,tablet,desktop}/*.png` (68 шт., ~8.8 MB)
- Отчёт прогона: `apps/frontend/e2e/mobile/REPORT-RAW.md`
- Спека аудита: `apps/frontend/e2e/mobile/mobile-audit.spec.ts` (8/8 тестов passed)
- Стратегия: `~/studio/REPORT-MOBILE-STRATEGY.md`

## Рекомендация следующей волны (W1)

Начать с **Раздела 1 (каркас AppLayout)** — единственный P0, закрывает жалобу пользователя. После фикса: перепрогнать mobile-audit → сравнить долю сайдбара (ожидание: 0% на мобильных, меню в drawer).
