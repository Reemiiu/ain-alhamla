// أدوات واجهة مشتركة: هروب HTML، تنسيق الوقت، نوافذ منبثقة، إشعارات، تصدير CSV.

export function esc(str) {
  return String(str ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
export const escapeHtml = esc;

const MONTHS = ['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];

export function timeAgo(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  const min = Math.floor((Date.now() - d.getTime()) / 60000);
  if (min < -1) return `بعد ${fmtDuration(-min)}`;
  if (min < 1) return 'الآن';
  if (min < 60) return `قبل ${min} د`;
  const h = Math.floor(min / 60);
  if (h < 24) return `قبل ${h} س`;
  return `${d.getDate()} ${MONTHS[d.getMonth()]}`;
}
export function fmtDuration(min) {
  if (min < 60) return `${min} د`;
  const h = Math.floor(min / 60), m = min % 60;
  return m ? `${h} س ${m} د` : `${h} س`;
}
export function clock(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleTimeString('ar-SA', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Riyadh' });
}
export function dateTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return `${d.toLocaleDateString('ar-SA-u-ca-gregory', { day: 'numeric', month: 'short', timeZone: 'Asia/Riyadh' })} · ${clock(iso)}`;
}
export function num(n) { return typeof n === 'number' ? n.toLocaleString('ar') : (n ?? '—'); }
export function initials(name) {
  const p = String(name || '').trim().split(/\s+/).filter(Boolean);
  if (!p.length) return '؟';
  return p.length === 1 ? p[0][0] : `${p[0][0]}.${p[p.length - 1][0]}`;
}

export const ATT = {
  PRESENT: { label: 'حاضر', cls: 'good' }, LATE: { label: 'متأخر', cls: 'warn' },
  ABSENT: { label: 'غائب', cls: 'crit' }, OUT_OF_RANGE: { label: 'خارج النطاق', cls: 'crit' },
};
export function attPill(status, emptyLabel = 'لم يسجّل') {
  const s = ATT[status] ?? { label: emptyLabel, cls: 'muted' };
  return `<span class="pill ${s.cls}"><span class="dot"></span>${esc(s.label)}</span>`;
}
export const PRIORITY = {
  CRITICAL: { label: 'حرجة', cls: 'crit' }, HIGH: { label: 'عالية', cls: 'warn' }, NORMAL: { label: 'عادية', cls: 'muted' },
};
export function prioPill(level, reason) {
  const p = PRIORITY[level] ?? PRIORITY.NORMAL;
  if (level === 'NORMAL' || !level) return '<span class="prio-chip normal">عادية</span>';
  return `<span class="prio-chip ${p.cls}" title="${esc(reason || '')}">${p.label}${reason ? ` · ${esc(reason)}` : ''}</span>`;
}
export const ALERT_TYPE = {
  SOS: 'طلب نجدة SOS', LOST: 'حاج تائه', ABSENCE: 'غياب', DELAY: 'تأخر عن المهلة',
  GEOFENCE_BREACH: 'خروج عن النطاق', LOW_BATTERY: 'بطارية منخفضة',
  HEAT_STRESS: 'إجهاد حراري', BUDDY_SPLIT: 'انفصال عن الرفيق', OUTSIDE_SITE: 'خارج حدود المشعر',
  MISSED_DOSE: 'جرعة دواء فائتة', NO_MOVEMENT: 'لا حركة · أنت بخير؟',
};
export const SEVERITY = { CRITICAL: 'حرجة', MEDIUM: 'متوسطة', LOW: 'منخفضة' };
export const ALERT_STATUS = { OPEN: 'مفتوح', IN_PROGRESS: 'قيد المعالجة', RESOLVED: 'مُغلق' };
export const LANG = { ar: 'العربية', en: 'English', ur: 'اردو', id: 'Indonesia' };
export function sevColor(s) { return s === 'CRITICAL' ? 'var(--danger)' : s === 'MEDIUM' ? 'var(--warning)' : 'var(--success)'; }

export function stars(r) {
  if (r == null) return '—';
  const n = Math.round(Number(r));
  return `<span class="stars" title="${Number(r).toFixed(1)}">${'★'.repeat(n)}<span>${'★'.repeat(5 - n)}</span></span>`;
}

// ------------ نافذة منبثقة ------------
export function openModal({ title, sub = '', body, submitLabel = 'حفظ', danger = false, onSubmit, wide = false }) {
  const root = document.createElement('div');
  root.className = 'modal-overlay';
  root.innerHTML = `
    <div class="modal-card${wide ? ' wide' : ''}" role="dialog" aria-modal="true">
      <button class="modal-close" aria-label="إغلاق">✕</button>
      <h2>${esc(title)}</h2>
      ${sub ? `<p class="modal-sub">${sub}</p>` : ''}
      <div class="form-error" hidden></div>
      <form novalidate>
        ${body}
        ${onSubmit ? `<div class="modal-actions">
          <button type="button" class="btn btn-outline" data-cancel>إلغاء</button>
          <button type="submit" class="btn ${danger ? 'btn-danger' : 'btn-primary'}">${esc(submitLabel)}</button>
        </div>` : ''}
      </form>
    </div>`;
  document.body.appendChild(root);
  const close = () => root.remove();
  root.querySelector('.modal-close').onclick = close;
  root.querySelector('[data-cancel]')?.addEventListener('click', close);
  root.addEventListener('click', (e) => { if (e.target === root) close(); });
  const form = root.querySelector('form');
  const err = root.querySelector('.form-error');
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!onSubmit) return;
    const btn = form.querySelector('[type=submit]');
    err.hidden = true; btn.disabled = true;
    try {
      const keep = await onSubmit(Object.fromEntries(new FormData(form)), form);
      if (keep !== true) close();
    } catch (ex) {
      err.textContent = ex.message; err.hidden = false;
    } finally { btn.disabled = false; }
  });
  form.querySelector('input, select, textarea')?.focus();
  return { root, close, form };
}

// ------------ إشعار عابر ------------
export function toast(msg, kind = 'info') {
  let box = document.getElementById('toastBox');
  if (!box) { box = document.createElement('div'); box.id = 'toastBox'; document.body.appendChild(box); }
  const t = document.createElement('div');
  t.className = `toast ${kind}`; t.innerHTML = msg;
  box.appendChild(t);
  setTimeout(() => t.classList.add('out'), 4200);
  setTimeout(() => t.remove(), 4700);
}

// ------------ تصدير CSV (يفتح في Excel بالعربية) ------------
export function downloadCsv(filename, rows) {
  const csv = rows.map((r) => r.map((v) => `"${String(v ?? '').replace(/"/g, '""')}"`).join(',')).join('\r\n');
  const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' });
  const a = Object.assign(document.createElement('a'), { href: URL.createObjectURL(blob), download: filename });
  document.body.appendChild(a); a.click(); a.remove();
}

export function toLocalInput(date) {
  const d = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return d.toISOString().slice(0, 16);
}

export function battery(b) {
  if (b == null) return '<span class="muted">—</span>';
  const cls = b < 15 ? 'crit' : b < 35 ? 'warn' : 'good';
  return `<span class="battery ${cls}"><i style="width:${b}%"></i></span> <small>${b}٪</small>`;
}
