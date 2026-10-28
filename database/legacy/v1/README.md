# عين الحملة — Ain Al-Hamla

قاعدة بيانات PostgreSQL لمنصة **عين الحملة**: منصة ذكية لإدارة حملات الحج، تربط الحجاج بالمشرفين، وتتابع الحضور والتجمعات والتنقلات، مع تنبيهات فورية عند غياب أو تأخر أحد الحجاج، وملف رقمي لكل حاج يتضمن بيانات التواصل والطوارئ وزر SOS لطلب المساعدة.

**القاعدة تعمل الآن فعليًا** على [Supabase](https://supabase.com) — PostgreSQL 16، وليست مجرد تصميم على الورق.

## المحتويات

| الملف | الوصف |
|---|---|
| [`schema.sql`](./schema.sql) | البنية الكاملة: 13 جدولاً، 11 نوع ENUM، قيود CHECK، 45 فهرس أداء، triggers، وRow Level Security على كل الجداول (بدون هاردوير) |
| [`seed.sql`](./seed.sql) | بيانات تجريبية واقعية لكل الجداول الـ13 (حملة، مشرفون، مجموعات، حجاج، مواقع، حضور، رحلات، تنبيهات، بلاغ SOS، جهات اتصال طارئة، إشعارات) |
| [`schema.dbml`](./schema.dbml) | مخطط العلاقات (ERD) بصيغة DBML، جاهز للاستيراد المباشر على [dbdiagram.io](https://dbdiagram.io) |

## بنية قاعدة البيانات — 13 جدولاً في 4 مجموعات (بدون هاردوير)

**١. الهوية والمستخدمون** — `users` · `pilgrims` · `supervisors`
**٢. الحملة والتنظيم** — `campaigns` · `groups`
**٣. التتبع والموقع والتنقلات** — `locations` · `attendance` · `trips` · `trip_groups`
**٤. السلامة والتنبيهات** — `alerts` · `sos_requests` · `emergency_contacts` · `notifications`

## أبرز القيود والتحسينات

- الحضور والتتبع بالكامل عبر تطبيق الحاج — لا NFC، لا QR reader، لا BLE tag (`attendance.source`: `APP_CHECKIN` / `GPS` / `MANUAL`)
- علاقة 1:1 بين `alerts` و`sos_requests`
- جهة اتصال طارئة رئيسية واحدة فقط لكل حاج (فهرس فريد جزئي على `emergency_contacts`)
- `groups.supervisor_id` يشير إلى جدول `supervisors` فعليًا، لا إلى أي مستخدم
- رحلة واحدة يمكن أن تخدم أكثر من مجموعة معًا (`trip_groups`، علاقة Many-to-Many)
- Trigger يمنع تلقائيًا تجاوز السعة القصوى للمجموعة
- Trigger لتحديث `updated_at` تلقائيًا
- جميع الحقول التصنيفية (role/type/status/severity/source) من نوع `ENUM` بدل نص حر
- Row Level Security مفعّلة على الجداول الـ13 كاملة

## التشغيل محليًا

```bash
createdb ain_alhamla
psql -d ain_alhamla -f schema.sql
psql -d ain_alhamla -f seed.sql
```

## التحقق من البيانات التجريبية

بعد تشغيل `seed.sql`، عدد الصفوف المتوقع في كل جدول:

| الجدول | العدد | الجدول | العدد |
|---|---|---|---|
| users | 10 | trips | 2 |
| campaigns | 1 | trip_groups | 3 |
| supervisors | 2 | alerts | 3 |
| groups | 2 | sos_requests | 1 |
| pilgrims | 6 | emergency_contacts | 7 |
| locations | 4 | notifications | 3 |
| attendance | 11 | | |

---

جزء من مشروع **عين الحملة** لإدارة وسلامة حملات الحج.

