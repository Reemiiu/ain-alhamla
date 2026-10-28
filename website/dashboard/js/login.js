// صفحة دخول واحدة لكل الأدوار:
// الحاج ← تطبيق الحاج مباشرة، المشرف ← واجهة المشرف (التطبيق على الجوال، واللوحة على الكمبيوتر)،
// الإدارة ومركز العمليات ← لوحة الإدارة.
import { supabase } from './supabase-client.js';
import {
  saveSession, getSession, clearSession, errorText,
  getAppSession, saveAppSession, clearAppSession, homeFor,
} from './api.js';

const params = new URLSearchParams(window.location.search);

// رجوع من التطبيق بعد تسجيل الخروج: نفس الرمز كان مشتركاً، فننهي جلسة اللوحة أيضاً
if (params.get('from') === 'app' && !getAppSession()) clearSession();

// من دخل سابقاً تُفتح له واجهته مباشرة
(function resume() {
  const dash = getSession();
  if (dash?.token && homeFor(dash.user.role) === 'index.html') { window.location.replace('index.html'); return; }
  if (getAppSession()) window.location.replace('../app/');
})();

const form = document.getElementById('loginForm');
const errorBox = document.getElementById('formError');
const submitBtn = document.getElementById('submitBtn');

function showError(html) { errorBox.innerHTML = html; errorBox.hidden = false; }

document.querySelectorAll('[data-demo]').forEach((b) => b.addEventListener('click', () => {
  document.getElementById('nationalId').value = b.dataset.demo;
  document.getElementById('password').value = 'Demo@1234';
}));

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  errorBox.hidden = true;
  const nationalId = document.getElementById('nationalId').value.trim();
  const password = document.getElementById('password').value;
  if (!nationalId || !password) { showError('الرجاء تعبئة رقم الهوية وكلمة المرور.'); return; }

  submitBtn.disabled = true;
  submitBtn.textContent = 'جارٍ تسجيل الدخول...';
  try {
    const { data, error } = await supabase.rpc('app_login', { p_national_id: nationalId, p_password: password });
    if (error) throw error;
    if (!data) { showError('رقم الهوية أو كلمة المرور غير صحيحة.'); return; }

    const role = data.user.role;
    const remember = document.getElementById('remember').checked;
    clearSession();
    clearAppSession();

    if (role === 'PILGRIM') {
      // لغة الحاج وخطه المفضّلان، ليفتح التطبيق بلغته من أول شاشة
      let me = null;
      try { ({ data: me } = await supabase.rpc('app_me', { p_token: data.token })); } catch { /* يكمل بدونها */ }
      saveAppSession(data, me);
    } else {
      saveSession(data, remember);
      if (role === 'SUPERVISOR') saveAppSession(data, null); // المشرف يقدر يفتح التطبيق الميداني بنفس الدخول
    }
    submitBtn.textContent = 'جارٍ فتح واجهتك...';
    window.location.href = homeFor(role);
  } catch (err) {
    console.error(err);
    showError(errorText(err) || 'تعذّر تسجيل الدخول.');
  } finally {
    if (submitBtn.textContent !== 'جارٍ فتح واجهتك...') {
      submitBtn.disabled = false;
      submitBtn.textContent = 'دخول';
    }
  }
});
