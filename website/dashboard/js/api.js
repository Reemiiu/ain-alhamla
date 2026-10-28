// طبقة الاتصال بالقاعدة: الجلسة (token) + استدعاء دوال app_* التي تتحقق من الدور داخل الخادم.
import { supabase } from './supabase-client.js';

const KEY = 'ain_alhamla_session_v2';

export function getSession() {
  try {
    const raw = sessionStorage.getItem(KEY) || localStorage.getItem(KEY);
    return raw ? JSON.parse(raw) : null;
  } catch { return null; }
}

export function saveSession(session, remember) {
  try {
    (remember ? localStorage : sessionStorage).setItem(KEY, JSON.stringify(session));
  } catch { /* التخزين غير متاح */ }
}

export function clearSession() {
  try { sessionStorage.removeItem(KEY); localStorage.removeItem(KEY); } catch { /* */ }
}

// ── جلسة تطبيق الحاج والمشرف (Flutter) على نفس الموقع ─────────────────────
// التطبيق يحفظ إعداداته في localStorage بمفاتيح تبدأ بـ flutter. وقيمها بصيغة JSON،
// فصفحة الدخول الموحّدة تكتب الجلسة هنا ثم تفتح التطبيق مباشرة بدون دخول ثانٍ.
const APP_KEYS = ['flutter.ain_token', 'flutter.ain_role', 'flutter.ain_name', 'flutter.ain_me'];
const APP_LANGS = ['ar', 'en', 'ur', 'id'];

export function getAppSession() {
  try {
    const token = JSON.parse(localStorage.getItem('flutter.ain_token') || 'null');
    if (!token) return null;
    return { token, role: JSON.parse(localStorage.getItem('flutter.ain_role') || '""') };
  } catch { return null; }
}

export function saveAppSession(session, me) {
  try {
    localStorage.setItem('flutter.ain_token', JSON.stringify(session.token));
    localStorage.setItem('flutter.ain_role', JSON.stringify(session.user.role));
    localStorage.setItem('flutter.ain_name', JSON.stringify(session.user.full_name || ''));
    const p = me?.pilgrim;
    if (p && APP_LANGS.includes(p.preferred_language)) localStorage.setItem('flutter.ain_lang', JSON.stringify(p.preferred_language));
    if (p && typeof p.large_text === 'boolean') localStorage.setItem('flutter.ain_large', JSON.stringify(p.large_text));
  } catch { /* التخزين غير متاح */ }
}

export function clearAppSession() {
  try { APP_KEYS.forEach((k) => localStorage.removeItem(k)); } catch { /* */ }
}

/** الجوال والتابلت: المشرف يُفتح له تطبيق المشرف الميداني (الخريطة وGPS)، والكمبيوتر: لوحة المشرف. */
export function isFieldDevice() {
  try { return matchMedia('(max-width: 760px)').matches || matchMedia('(pointer: coarse)').matches; } catch { return false; }
}

/** أين تُفتح واجهة كل دور بعد الدخول. */
export function homeFor(role) {
  if (role === 'PILGRIM') return '../app/';
  if (role === 'SUPERVISOR' && isFieldDevice()) return '../app/';
  return 'index.html';
}

export async function logout() {
  const s = getSession();
  if (s?.token) await supabase.rpc('app_logout', { p_token: s.token }).catch(() => {});
  clearSession();
  clearAppSession();
  window.location.href = 'login.html';
}

/** يحوّل لصفحة الدخول إن لم توجد جلسة، ويمنع الحاج من لوحة التحكم. */
export function requireAuth(allowedRoles) {
  const s = getSession();
  if (!s?.token) { window.location.replace('login.html'); return null; }
  if (allowedRoles && !allowedRoles.includes(s.user.role)) { window.location.replace('index.html'); return null; }
  return s;
}

const MESSAGES = {
  SESSION_EXPIRED: 'انتهت الجلسة، الرجاء تسجيل الدخول من جديد.',
  FORBIDDEN: 'هذه الخدمة غير متاحة لدورك.',
  DUPLICATE_ID: 'رقم الهوية مُسجَّل مسبقاً.',
  GATHERING_CLOSED: 'تم إغلاق هذا التجمع.',
  CAPACITY_TOO_SMALL: 'السعة أقل من عدد الحجاج الحاليين.',
};

export function errorText(err) {
  if (!err) return '';
  const m = String(err.message || err);
  if (MESSAGES[m]) return MESSAGES[m];
  if (err.hint) return err.hint;
  if (/تجاوز السعة/.test(m)) return m;
  if (/Failed to fetch|NetworkError/i.test(m)) return 'تعذّر الاتصال بالخادم. تحقّق من الإنترنت.';
  if (/Could not find the function/i.test(m)) return 'دوال v2 غير موجودة في القاعدة — شغّلي database/04_migration_v2.sql على Supabase.';
  return m;
}

/** يستدعي دالة app_* ويضيف رمز الجلسة تلقائياً. */
export async function rpc(name, params = {}) {
  const s = getSession();
  const { data, error } = await supabase.rpc(name, { p_token: s?.token, ...params });
  if (error) {
    if (error.message === 'SESSION_EXPIRED') { clearSession(); window.location.replace('login.html'); }
    const e = new Error(errorText(error)); e.raw = error; throw e;
  }
  return data;
}

export { supabase };
