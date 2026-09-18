# ТЗ ДЛЯ HOLIX (backend-lead): модуль demo-data

Роль: исполнитель (backend). Ты реализуешь бэкенд-модуль демо-данных MAXSCRM.
Рабочая директория: /home/potapof/studio/projects/maxscrm/repo

## Контекст
- Приложение NestJS (apps/backend). Prisma schema: apps/backend/prisma/schema.prisma.
- Уже существует скрипт apps/backend/prisma/seed.ts (1487 строк) — он создаёт полный
  демо-набор для ОДНОЙ организации (товары, категории, бренды, контакты, лиды,
  заказы, кампании, лояльность, биллинг и т.д.), но он WIPES ALL TABLES и не
  привязан к конкретному orgId. Твоя задача — превратить эту логику в сервис,
  который загружает демо-данные В КОНКРЕТНУЮ организацию (tenant-scoped).
- Уже существует удаление демо: apps/backend/src/modules/identity/admin.service.ts
  resetDemoData(orgId) — удаляет все данные org (~70 таблиц, топологический порядок).
  ЕГО НЕ ТРОГАЙ.
- Онбординг новых пользователей: apps/backend/src/modules/identity/auth.service.ts
  authDev() и authWithMax() создают organization (findFirst по slug → create) и user.
  Там нужен хук: при СОЗДАНИИ новой организации — автозагрузка демо-данных.

## Задача: создать модуль apps/backend/src/modules/demo-data/

Файлы (создай все):

1. demo-data.types.ts — интерфейсы схемы контента (см. СХЕМА ниже). Экспортируй
   интерфейсы: DemoProductVariant, DemoProductSpec, DemoProduct, DemoContact,
   DemoLead, DemoOrderItem, DemoOrder, DemoMessage, DemoMessageTemplate, DemoSegment,
   DemoCampaign, DemoCoupon, DemoReview, DemoNotification, DemoCollection,
   DemoActivity, DemoFlashSale, DemoGroupBuy, DemoGiftCard, DemoExpressTemplate,
   DemoEmCampaign, DemoAbExperiment, DemoAuditEntry, DemoLoyalty, DemoTeamMember,
   DemoContent (главный).

2. demo-data.content.ts — НЕ ПИШИ (его параллельно генерит другой агент-дизайнер
   по той же схеме). В сервисе импортируй: import { demoContent } from './demo-data.content';
   и приведи к типу: const content = demoContent as unknown as DemoContent;

3. demo-data.service.ts — класс DemoDataService:
   - метод loadDemoData(orgId: string): Promise<{loaded: boolean; counts: Record<string, number>}>
     Логика (перенеси из seed.ts, адаптируй):
     a. Все операции — в рамках orgId (tenant), через this.prisma (PrismaService,
        паттерн как в других сервисах: this.prisma.client.<model>).
     b. Идемпотентность: если у org уже есть Store с полем slug равным слаг-основе
        org (или если число товаров org больше 0) — НЕ дублировать, вернуть
        { loaded: false } (демо уже загружено). НО: если в content появляются новые
        сущности (например, abExperiments не были загружены) — дозагрузить
        недостающие разделы. Простой подход: загружать только те разделы, где в org
        ещё нет данных (count === 0), каждый раздел независимо.
     c. Порядок создания (важно для FK):
        Store → Category → Brand → Product (с Variant, Media, Spec, Inventory) →
        Collection (CollectionProduct) → Coupon → DiscountRule → Contact → Lead →
        Segment → MessageTemplate → Campaign (CampaignRecipient) → Message →
        Notification → NotificationTemplate → Activity → FlashSale (FlashSaleItem) →
        GroupBuy (GroupBuyGroup, GroupBuyParticipant) → GiftCard (GiftCardTransaction)
        → ExpressTemplate → EmCampaign/EmTemplate/EmSegment/EmSubscriber →
        AbExperiment (AbAssignment) → AuditLog → Loyalty (программа, уровни, баллы,
        награды) → Billing (аккаунт, инвойсы, платежи) → User-ы команды (роль
        admin/manager/viewer; email вида имя@demo.local; пароль НЕ нужен — только
        maxUserId null, имя, email, роль; НЕ трогай существующего админа org).
        Order (OrderItem, OrderTimeline, ShippingAddress, Invoice, Payment, Refund,
        Shipment) — контакты уже созданы, items ссылаются на товары по slug.
     d. Все изображения товаров — строки из content.products[i].images (pixinlink).
     e. auditEntries → AuditLog (action, detail, orgId).
     f. Возвращай counts: { products: N, contacts: N, ... } по фактически созданным.
     g. Всё в try/catch: при ошибке логировать и не ронять вызывающего.
   - метод countDemoData(orgId: string): Promise<Record<string, number>> — количество
     записей по разделам (для статуса/проверки). Разделы: products, contacts, leads,
     orders, campaigns, coupons, messages, messageTemplates, notifications, reviews,
     activities, segments, collections, loyaltyLevels, abExperiments, emCampaigns.

4. demo-data.controller.ts — AdminDemoDataController (роут префикс /admin — уже
   используется identity/admin.controller.ts, посмотри как он устроен и подключи
   свой контроллер АНАЛОГИЧНО, с JwtAuthGuard и проверкой роли admin):
   - POST /api/v1/admin/demo-load → loadDemoData(req.user.orgId), только admin
     (роль из req.user.role === 'admin', иначе ForbiddenException).
   - GET /api/v1/admin/demo-status → countDemoData(orgId) (admin).

5. demo-data.module.ts — DemoDataModule (providers: [DemoDataService],
   controllers: [AdminDemoDataController], exports: [DemoDataService]).

6. Хук в apps/backend/src/modules/identity/auth.service.ts:
   - В конструктор добавь DemoDataService (импорт из '../demo-data/demo-data.service';
     в identity.module.ts добавь DemoDataModule в imports, чтобы DI работал).
   - В authDev() и authWithMax(): после organization.create (только когда org
     СОЗДАНА, а не найдена) — fire-and-forget:
     void this.demoData.loadDemoData(org.id).catch(err => console.error('demo load failed', err));
     НЕ await — логин не должен ждать загрузку демо.
   - ВАЖНО: не сломай unit-тесты apps/backend/src/modules/identity/auth.service.spec.ts
     (там моки PrismaService/JwtService/TwoFactorAuthService). Если тест падает из-за
     нового DI-зависимости — добавь мок DemoDataService в spec (Test.createTestingModule
     с provide: DemoDataService, useValue: { loadDemoData: jest.fn().mockResolvedValue({}) }).

## СХЕМА контента (совпадает с demo-data.types.ts; контент генерит другой агент)
- categories: массив { name: string, slug: string }
- brands: массив строк (названия)
- products: массив объектов:
  { name, slug, description, price (number), compareAtPrice? (number), sku (string),
    stock (number), categorySlug (string, ссылка на categories), brand (string),
    images (массив строк URL pixinlink), specs? (массив { name, value }),
    variants? (массив { name, sku, price, stock }) }
- reviews: { productSlug (string), rating (1-5), text, author }
- contacts: { name, phone, email?, tags? (массив строк), score? (number), source? }
- leads: { title, stage (одно из: new, qualified, negotiation, closedwon, closedlost),
  amount? (number), contactName? (string) }
- orders: { orderNumber (string уникальный), status (одно из: pending, confirmed,
  paid, processing, shipped, delivered, completed, cancelled, refunded,
  partially_refunded), deliveryType?, paymentMethod?, contactName (string),
  items: массив { productSlug, qty }, daysAgo? (number) }
- messages: { channel (max | telegram | email | sms), contactName?, fromContact (bool),
  text, hoursAgo? (number) } — диалоги группируются по контакту
- messageTemplates: { name, channel (max|telegram|email|sms), subject?, content }
- segments: { name, description? }
- campaigns: { name, channel, status (draft|sending|sent), subject?, content? }
- coupons: { code (уникальный), type (percent|fixed), value (number), maxUses?,
  expiresInDays? }
- collections: { name, slug, productSlugs (массив slug товаров) }
- notifications: { title, body, type? }
- activities: { type (одно из: lead.created, lead.stage.changed, contact.created,
  contact.updated, message.sent, message.received, notification.sent, order.created),
  description, daysAgo? }
- flashSales: { name, productSlugs (массив), discountPercent }
- groupBuys: { name, productSlug, discountPercent, participants (число) }
- giftCards: { code, balance (number) }
- expressTemplates: { name, carrier (cdek|pochta|courier|pickup), type }
- emCampaigns: { name, status (draft|sending|sent), subject? }
- abExperiments: { name, status (draft|running|completed) }
- auditEntries: { action, detail? }
- loyalty: { programName, levels: массив { name, minPoints (number),
  discountPercent? (number) } }
- team: массив { name, email, role (admin|manager|viewer) }

## Критерии готовности
- tsc --noEmit в apps/backend проходит (npm run typecheck).
- eslint без errors по новым файлам.
- jest по identity (auth.service.spec.ts) и admin — зелёные (поправь spec под DI).
- Не трогать: admin.service.ts (resetDemoData), demo-data.content.ts (чужой файл),
  схему Prisma, миграции.
- Не коммитить, не пушить — только писать файлы. По завершении напиши краткий
  отчёт: какие файлы созданы, какие counts возвращает loadDemoData для
  тестового org, что поправил в тестах.
