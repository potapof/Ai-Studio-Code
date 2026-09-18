# ПЛАН: Демо-данные для всех новых пользователей + кнопка «Удалить демо данные» (2026-08-27)

## Цель (ТЗ пользователя)
1. Максимально заполнить демоданными ВСЕ разделы maxscrm.
2. Демо-данные живут на сервере отдельным разделом (не удаляются), загружаются
   всем НОВЫМ пользователям (новым org).
3. Кнопка «Удалить демо данные» в дашборде (УЖЕ ЕСТЬ: resetDemoData →
   POST /admin/demo-reset, DashboardPage — реализовано в прошлых сессиях).
4. Изображения: https://pixinlink.ru/{WxH}/{промпт ≤3 слов} (проверен: HTTP 200 svg).
5. Многоуровневая задача: распределить по всем агентам, Hermes верифицирует.

## Рекон (факты)
- Онбординг: authDev/authWithMax создают org (findFirst по slug → create) и user.
  auth.service.ts:162-191. Точка автозагрузки демо — при organization.create.
- seed.ts (1487 строк, apps/backend/prisma/seed.ts): ПОЛНЫЙ демо-набор для 1 org
  (12 товаров, 6 категорий, 5 брендов, 28 контактов, 22 лида, 6 шаблонов,
  4 сегмента, кампании, лояльность, 10 заказов, биллинг, плагины...).
  WIPES ALL TABLES — НЕ подходит как сервис; нужен tenant-scoped загрузчик.
- demo-reset УЖЕ есть: admin.service.ts resetDemoData(orgId) удаляет ВСЕ данные org
  (топологический порядок, ~70 таблиц, только admin). Кнопка на фронте есть.
- Каскадов в Prisma нет (onDelete: Cascade = 0) — удаление только вручную (уже сделано).
- Модели всех разделов есть: Product/Category/Brand/Collection/Coupon/DiscountRule/
  FlashSale/GroupBuy/GiftCard/Contact/Lead/Activity/Message/MessageTemplate/Segment/
  Campaign/CampaignRecipient/Loyalty*/Notification(+Template)/Order+*/Invoice/Payment/
  Refund/Shipment/ExpressTemplate/DeliverySetting/Inventory/AbExperiment/AbAssignment/
  AbEvent/EmCampaign/EmTemplate/EmSegment/EmSubscriber/EmAutomation/StorePlugin/
  Wb*/Ozon*/Integration1C/AuditLog/Billing*.

## Архитектура решения
Модуль apps/backend/src/modules/demo-data/ (источник на сервере, НЕ удаляется):
- demo-data.content.ts — статический контент (генерит dsh) по схеме ниже.
- demo-data.types.ts — типы схемы контента (пишет Holix).
- demo-data.service.ts — loadDemoData(orgId): tenant-scoped засев всех сущностей
  (адаптация логики seed.ts под конкретный orgId; идемпотентно: если store org уже
  есть с демо — пропуск/дозагрузка). Без wipes.
- demo-data.controller.ts — POST /admin/demo-load (загрузка демо в свою org, admin).
- demo-data.module.ts — регистрация.
- Хук в auth.service.ts: при create org → loadDemoData(org.id) fire-and-forget
  (не блокирует логин; try/catch; тесты auth.service.spec должны остаться зелёными).

Фронтенд (OpenHands):
- lib/api.ts: loadDemoData() → POST /api/v1/admin/demo-load.
- DashboardPage: кнопка «Загрузить демо данные» рядом с существующей
  «Удалить демо данные» (после удаления можно вернуть демо).

## Схема demo-data.content.ts (ЕДИНАЯ для dsh и Holix)
См. ТЗ агентам (DemoContent): categories, brands, products (name/slug/description/
price/compareAtPrice?/sku/stock/categorySlug/brand/images[] pixinlink/specs?/variants?),
reviews, contacts, leads, orders (items по productSlug), messages, messageTemplates,
segments, campaigns, coupons, collections, notifications, activities, flashSales,
groupBuys, giftCards, expressTemplates, emCampaigns, abExperiments, auditEntries,
loyalty (программа+уровни), team (admin/manager/viewer).

## Распределение (волна 1, параллельно, файлы не пересекаются)
| Агент | Задача | Файлы |
|---|---|---|
| Holix (backend-lead) | Модуль demo-data: types/service/controller/module + хук в auth.service | demo-data.{types,service,controller,module}.ts, auth.service.ts |
| OpenHands (--fast) | Фронт: api.loadDemoData + кнопка в дашборде | lib/api.ts, DashboardPage.tsx |
| dsh (headless) | Контент demo-data.content.ts по схеме (все разделы, pixinlink ≤3 слов) | demo-data.content.ts |

## Верификация (Hermes)
1. prisma validate + generate; tsc --noEmit; eslint; jest (identity+admin);
   vitest (frontend).
2. Живой прогон локально: создать НОВУЮ org (auth/dev с новым slug) →
   демо загрузилось (проверить counts по разделам) → POST /admin/demo-load →
   POST /admin/demo-reset → данные org очищены, источник не тронут.
3. Коммит + пуш develop → авто-деплой staging.
4. На staging: та же цепочка (новая org → демо есть).

## Известные риски
- dsh может отклониться от схемы → поймает tsc, поправит Hermes.
- Хук в auth.service сломает unit-тесты (мок Prisma) → поправить тест/хук.
- Загрузка демо долгая (сотни записей) → fire-and-forget + лог в AuditLog.
