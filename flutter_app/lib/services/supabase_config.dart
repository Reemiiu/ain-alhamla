/// بيانات الاتصال بمشروع Supabase الخاص بـ "عين الحملة".
///
/// عبّئي القيمتين التاليتين من: Supabase Dashboard → Project Settings → API
/// - supabaseUrl: "Project URL"
/// - supabaseAnonKey: "anon public" key (وليس service_role — هذا المفتاح فقط
///   هو الآمن للاستخدام داخل تطبيق الجوال)
///
/// لا تضعي مفتاح service_role هنا أبداً؛ صلاحياته كاملة على القاعدة ويجب أن
/// يبقى على الخادم فقط.
class SupabaseConfig {
  SupabaseConfig._();

  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://mlmjvuypiblaixwzmemd.supabase.co',
  );

  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_r-_eGijAq4vgcXXHZyizGA_Lddf9vy7',
  );
}
