// =====================================================================
// بيانات الاتصال بمشروع Supabase الخاص بـ "عين الحملة"
// =====================================================================
//
// عبّئي القيمتين التاليتين من: Supabase Dashboard → Project Settings → API
// - SUPABASE_URL: "Project URL"
// - SUPABASE_ANON_KEY: "anon public" key (وليس service_role)
//
// ⚠️ لا تضعي مفتاح service_role هنا أبداً — صلاحياته كاملة على القاعدة
// ويجب أن يبقى على الخادم فقط. مفتاح anon public هو الوحيد الآمن
// للاستخدام داخل صفحات موقع عام (كود يعمل في متصفح الزائر).
//
// تم تعبئة المفتاح العام (publishable) لمشروع عين الحملة — آمن للاستخدام في المتصفح.
// لا تضعي هنا أبداً المفتاح السري sb_secret_...

export const SUPABASE_URL = 'https://mlmjvuypiblaixwzmemd.supabase.co';
export const SUPABASE_ANON_KEY = 'sb_publishable_r-_eGijAq4vgcXXHZyizGA_Lddf9vy7';

// مفتاح Google Maps (اختياري). اتركيه فارغاً = خريطة OpenStreetMap مجانية بدون مفتاح.
// لتفعيل Google Maps: Google Cloud Console → Maps JavaScript API → أنشئي مفتاحاً
// وقيّديه بنطاق موقعك (HTTP referrers)، ثم الصقيه هنا.
export const GOOGLE_MAPS_API_KEY = '';
