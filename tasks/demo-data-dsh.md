# ТЗ ДЛЯ DSH (дизайн/контент): demo-data.content.ts

Роль: контент-дизайнер. Ты генерируешь ФАЙЛ ДАННЫХ для демо-наполнения MAXSCRM.
Рабочая директория: /home/potapof/studio/projects/maxscrm/repo

## Задача
Создай файл apps/backend/src/modules/demo-data/demo-data.content.ts —
один TypeScript-файл с константой demoContent (см. СХЕМУ ниже).
Файл должен быть ПОЛНЫМ (не обрывай, без заглушек, без комментариев-плейсхолдеров).

## Правила контента
1. Язык данных: русский (названия, описания, тексты — естественные, как для
   реального магазина инструментов/электроники/хозтоваров).
2. Изображения: СТРОГО формат https://pixinlink.ru/500x500/промпт-слова
   где промпт — от 1 до 3 слов через дефис (русские слова, например
   https://pixinlink.ru/500x500/дрель-шуруповерт). Размер 500x500 менять можно
   (например 800x800 для карточек, 300x300 для аватаров контактов — НЕ нужно,
   достаточно 500x500). Для каждого товара 2-3 изображения с РАЗНЫМИ промптами
   (ракурсы/варианты: общий вид, крупный план, в работе).
3. Объём (максимум, но разумно):
   - categories: 10 (инструменты, электроинструменты, садовая техника, сантехника,
     электротовары, автотовары, крепеж, строительные смеси, освещение, бытовая техника)
   - brands: 8 (вымышленные русскоязычные, например ПрофИнструмент, ЭлектроМакс,
     СтройДом, ТехноСад, ВольтПлюс, КрепМастер, СветоТех, ДомСервис)
   - products: 30 (по 3 на категорию; реалистичные товары с ценой в рублях,
     описанием 1-2 предложения, sku вида SKU-001, stock 3-150, compareAtPrice у
     части товаров, specs 2-4 шт у части, variants 1-3 у товаров с размерами/цветами)
   - reviews: 24 (rating 3-5, тексты отзывов покупателей, author русские имена)
   - contacts: 36 (русские ФИО, телефоны формата +7 9XX XXX-XX-XX, email, tags
     1-3 из набора: VIP, опт, hoReCa, розница, новый, постоянный, проблемный,
     score 0-100, source: storefront|import|manual|telegram|max)
   - leads: 28 (стадии new/qualified/negotiation/closedwon/closedlost поровну,
     amount 5000-450000, title по типу «Поставка дрелей в розницу», «Оснащение
     строительной бригады», contactName — имена из contacts)
   - orders: 14 (статусы: paid 3, processing 2, shipped 3, delivered 3, completed 1,
     cancelled 1, refunded 1; paymentMethod: card|cash|sbp; deliveryType:
     cdek|pochta|courier|pickup; items 1-4 шт на заказ по productSlug; daysAgo 0-45)
   - messages: 10 диалогов по 3-6 сообщений (channel max/telegram/email/sms,
     fromContact чередуется, тексты про товары/заказы/доставку, hoursAgo 1-200)
   - messageTemplates: 8 (каналы max/telegram/email/sms, name и content русские,
     у email subject)
   - segments: 5 (VIP-клиенты, Оптовые покупатели, HoReCa, Новые за 30 дней, Все)
   - campaigns: 5 (status: draft 1, sending 1, sent 3; каналы max/telegram/email;
     subject/content русские)
   - coupons: 6 (коды типа SALE10, WELCOME500 и т.п.; type percent|fixed;
     value 5-30 процентов или 200-2000 рублей; maxUses 50-500; expiresInDays 7-60)
   - collections: 5 (Хиты продаж, Новинки, Распродажа, Для дачи, Подарки;
     productSlugs по 5-8 шт)
   - notifications: 6 (title/body русские, type: system|order|marketing)
   - activities: 18 (type из списка: lead.created, lead.stage.changed,
     contact.created, contact.updated, message.sent, message.received,
     notification.sent, order.created; description русская; daysAgo 0-20)
   - flashSales: 2 (name, productSlugs по 3-5, discountPercent 10-30)
   - groupBuys: 2 (name, productSlug, discountPercent 15-25, participants 12-40)
   - giftCards: 3 (code вида GC-XXXX-XXXX, balance 500-5000)
   - expressTemplates: 4 (carrier: cdek|pochta|courier|pickup, type: standard|
     express|economy)
   - emCampaigns: 3 (status draft|sending|sent, subject русский)
   - abExperiments: 3 (name русское, status draft|running|completed)
   - auditEntries: 12 (action: user.login, user.created, product.created,
     product.updated, order.status_changed, contact.imported, campaign.sent,
     settings.updated; detail русский)
   - loyalty: 1 программа (name «MAX Кэшбэк», levels 4: Бронза 0 / Серебро 1000 /
     Золото 5000 / Платина 15000, discountPercent 1/3/5/8)
   - team: 4 (role: admin 1, manager 2, viewer 1; email вида ivan@demo.local)

## СХЕМА ФАЙЛА (строго)
Файл: export const demoContent = { ... } БЕЗ указания типа (типы определит
другой агент; твой объект должен структурно совпадать):

{
  categories: [{ name, slug }],
  brands: [string],
  products: [{ name, slug, description, price, compareAtPrice?, sku, stock,
               categorySlug, brand, images: [string], specs?: [{ name, value }],
               variants?: [{ name, sku, price, stock }] }],
  reviews: [{ productSlug, rating, text, author }],
  contacts: [{ name, phone, email?, tags?: [string], score?, source? }],
  leads: [{ title, stage, amount?, contactName? }],          // stage: new|qualified|negotiation|closedwon|closedlost
  orders: [{ orderNumber, status, deliveryType?, paymentMethod?, contactName,
             items: [{ productSlug, qty }], daysAgo? }],
  messages: [{ channel, contactName?, fromContact, text, hoursAgo? }],  // channel: max|telegram|email|sms
  messageTemplates: [{ name, channel, subject?, content }],
  segments: [{ name, description? }],
  campaigns: [{ name, channel, status, subject?, content? }],  // status: draft|sending|sent
  coupons: [{ code, type, value, maxUses?, expiresInDays? }],  // type: percent|fixed
  collections: [{ name, slug, productSlugs: [string] }],
  notifications: [{ title, body, type? }],
  activities: [{ type, description, daysAgo? }],
  flashSales: [{ name, productSlugs: [string], discountPercent }],
  groupBuys: [{ name, productSlug, discountPercent, participants }],
  giftCards: [{ code, balance }],
  expressTemplates: [{ name, carrier, type }],                // carrier: cdek|pochta|courier|pickup
  emCampaigns: [{ name, status, subject? }],
  abExperiments: [{ name, status }],                          // status: draft|running|completed
  auditEntries: [{ action, detail? }],
  loyalty: { programName, levels: [{ name, minPoints, discountPercent? }] },
  team: [{ name, email, role }],                              // role: admin|manager|viewer
}

Требования к валидности:
- slug-и категорий и товаров — латиницей (translit), уникальные.
- orderNumber уникальные (ORD-2026-001 и т.п.).
- productSlug в reviews/orders/collections/flashSales/groupBuys должны СУЩЕСТВОВАТЬ
  в products (сверься), contactName в leads/orders/messages — из contacts.
- Все ключи, указанные как обязательные, присутствуют у КАЖДОГО объекта.
- Файл — валидный TypeScript: импортов нет, только export const demoContent.
- После создания проверь сам: node-синтаксис не нужен — просто визуально сверь
  структуру и закрытие скобок.

## Критерии готовности
Файл создан, полный, без плейсхолдеров. В конце отчёт: сколько записей по
каждому разделу (products: N, contacts: N и т.д.).
