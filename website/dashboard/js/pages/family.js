// الأهل والرسائل: روابط متابعة آمنة للأهل (بدون موقع دقيق)، ورسائل صوتية تصل كل حاج بلغته.
import { rpc } from '../api.js';
import { renderShell, isAdmin } from '../shell.js';
import { esc, timeAgo, dateTime, toast, openModal } from '../ui.js';
import { LANGS } from '../v3.js';

const shell = renderShell({ page: 'family.html', title: 'الأهل والرسائل', subtitle: 'روابط طمأنينة للأهل، ورسائل المشرف مترجمة لكل حاج' });
let board = { groups: [], pilgrims: [] }, voiceLang = {};

if (shell) init(shell);

const linkUrl = (token) => new URL(`../family.html?t=${token}`, location.href).href;

async function init({ content, actions, user }) {
  actions.innerHTML = `${user.role !== 'OPERATIONS_CENTER' ? '<button class="btn btn-primary" id="newLink">+ رابط للأهل</button>' : ''}<button class="btn btn-outline" id="newVoice">+ رسالة للحجاج</button>`;
  content.innerHTML = `
    <div class="card"><div class="card-head"><h2>روابط متابعة الأهل</h2><span class="meta">الأهل يرون حالة حاجهم ورحلة مناسكه ورسالة المشرف، ولا يرون موقعه الدقيق</span></div>
      <div style="overflow-x:auto"><table class="db-table"><thead><tr><th>الحاج</th><th>المستلم</th><th>صالح حتى</th><th>المشاهدات</th><th>الحالة</th><th></th></tr></thead><tbody id="links"></tbody></table></div></div>
    <div class="card"><div class="card-head"><h2>الرسائل المترجمة</h2><span class="meta">كل حاج يقرأ الرسالة بلغة تطبيقه، ونعرف من سمعها</span></div><div id="voice"></div></div>`;
  document.getElementById('newLink')?.addEventListener('click', newLink);
  document.getElementById('newVoice').onclick = newVoice;
  board = await rpc('app_board');
  await Promise.all([loadLinks(), loadVoice()]);
}

async function loadLinks() {
  const rows = await rpc('app_family_links');
  document.getElementById('links').innerHTML = rows.map((l) => `
    <tr><td><b>${esc(l.pilgrim)}</b></td><td>${esc(l.contact ?? '—')}${l.relation ? ` <span class="meta">(${esc(l.relation)})</span>` : ''}</td>
      <td>${dateTime(l.expires_at)}</td><td>${l.views}${l.last_viewed ? `<div class="meta">${timeAgo(l.last_viewed)}</div>` : ''}</td>
      <td>${l.is_active ? '<span class="pill good">مفعّل</span>' : '<span class="pill muted">موقوف</span>'}</td>
      <td><div class="board-actions" style="flex-wrap:nowrap">
        <button class="btn btn-outline sm" data-copy="${l.token}">نسخ</button>
        <a class="btn btn-outline sm" target="_blank" rel="noopener" href="${linkUrl(l.token)}">عرض</a>
        ${shell.user.role !== 'OPERATIONS_CENTER' ? `<button class="btn btn-outline sm" data-tog="${l.id}" data-on="${l.is_active}">${l.is_active ? 'إيقاف' : 'تفعيل'}</button>` : ''}</div></td></tr>`).join('')
    || '<tr><td colspan="6"><div class="empty-state">لا توجد روابط بعد.</div></td></tr>';
  document.querySelectorAll('[data-copy]').forEach((b) => b.onclick = async () => {
    const u = linkUrl(b.dataset.copy);
    try { await navigator.clipboard.writeText(u); toast('نُسخ الرابط، أرسليه للأهل برسالة'); } catch { prompt('انسخي الرابط:', u); }
  });
  document.querySelectorAll('[data-tog]').forEach((b) => b.onclick = async () => {
    try { await rpc('app_set_family_link', { p_link_id: Number(b.dataset.tog), p_active: b.dataset.on !== 'true' }); toast(b.dataset.on === 'true' ? 'أُوقف الرابط فورًا' : 'فُعّل الرابط'); loadLinks(); }
    catch (e) { toast(esc(e.message), 'danger'); }
  });
}

function newLink() {
  const m = openModal({
    title: 'رابط متابعة للأهل', submitLabel: 'إنشاء الرابط',
    sub: 'رابط مؤقت يفتحه الأهل بدون حساب. يعرض حالة الحاج ومناسكه، ولا يعرض موقعه الدقيق.',
    body: `<label class="field-label">الحاج</label><select class="field" name="pid" id="flP">${board.pilgrims.map((p) => `<option value="${p.id}">${esc(p.full_name)}</option>`).join('')}</select>
      <label class="field-label">يُرسل إلى</label><select class="field" name="cid" id="flC"></select>
      <label class="field-label">المدة</label><select class="field" name="hours"><option value="">حتى نهاية الحملة</option><option value="48">٤٨ ساعة</option><option value="24">٢٤ ساعة</option></select>`,
    onSubmit: async (f) => {
      const r = await rpc('app_create_family_link', { p_pilgrim_id: Number(f.pid), p_contact_id: f.cid ? Number(f.cid) : null, p_hours: f.hours ? Number(f.hours) : null });
      const u = linkUrl(r.token);
      try { await navigator.clipboard.writeText(u); } catch { /* */ }
      toast('أُنشئ الرابط ونُسخ: أرسليه للأهل برسالة'); loadLinks();
    },
  });
  const sel = m.root.querySelector('#flP'), csel = m.root.querySelector('#flC');
  const fill = async () => {
    const cs = await rpc('app_contacts_of', { p_pilgrim_id: Number(sel.value) }).catch(() => []);
    csel.innerHTML = cs.map((c) => `<option value="${c.id}">${esc(c.name)}${c.relation ? ` (${esc(c.relation)})` : ''}</option>`).join('') || '<option value="">لا توجد جهات طوارئ</option>';
  };
  sel.onchange = fill; fill();
}

async function loadVoice() {
  const rows = await rpc('app_voice_list');
  const box = document.getElementById('voice');
  box.innerHTML = rows.map((v) => {
    const langs = ['ar', ...Object.keys(v.translations)];
    const cur = voiceLang[v.id] ?? 'ar';
    const text = cur === 'ar' ? v.transcript_ar : v.translations[cur];
    return `<div class="msg-row voice-row">
      <div class="voice-head"><b>${esc(v.sender)}</b> <span class="meta">→ ${esc(v.group ?? 'كل الحملة')} · ${timeAgo(v.created_at)}</span>${v.is_urgent ? ' <span class="pill crit">عاجلة</span>' : ''}</div>
      <div class="seg sm">${langs.map((k) => `<button class="${k === cur ? 'on' : ''}" data-v="${v.id}" data-l="${k}">${LANGS[k] ?? k}</button>`).join('')}</div>
      <div class="voice-text" dir="${['ar', 'ur'].includes(cur) ? 'rtl' : 'ltr'}">${esc(text)}</div>
      <div class="mini-stats">${Object.entries(v.status).map(([k, s]) => `<span class="${s.heard === s.total ? 'good' : 'warn'}">${LANGS[k] ?? k}: سمعها ${s.heard}/${s.total}</span>`).join('')}</div>
    </div>`;
  }).join('') || '<div class="empty-state">لا توجد رسائل بعد.</div>';
  box.querySelectorAll('[data-v]').forEach((b) => b.onclick = () => { voiceLang[b.dataset.v] = b.dataset.l; loadVoice(); });
}

function newVoice() {
  const gOpts = board.groups.map((g) => `<option value="${g.id}">${esc(g.name)}</option>`).join('');
  openModal({
    title: 'رسالة للحجاج', submitLabel: 'إرسال', wide: true,
    sub: 'تصل الرسالة لكل حاج في التطبيق بلغته. الترجمة الآلية تحتاج ربط خدمة ترجمة، لذا اكتبي الترجمات هنا أو اتركيها فتصل بالعربية.',
    body: `<div class="modal-grid">
      <div class="full"><label class="field-label">إلى</label><select class="field" name="group">${isAdmin(shell.user) ? '<option value="">كل الحملة</option>' : ''}${gOpts}</select></div>
      <div class="full"><label class="field-label">النص بالعربية</label><textarea class="field" name="ar" rows="3" required></textarea></div>
      <div><label class="field-label">English</label><textarea class="field" name="en" rows="2" dir="ltr"></textarea></div>
      <div><label class="field-label">اردو</label><textarea class="field" name="ur" rows="2"></textarea></div>
      <div><label class="field-label">Indonesia</label><textarea class="field" name="id" rows="2" dir="ltr"></textarea></div>
      <div><label class="field-label"><input type="checkbox" name="urgent"> عاجلة</label></div>
    </div>`,
    onSubmit: async (f) => {
      if (!f.ar.trim()) throw new Error('اكتبي نص الرسالة');
      const tr = {}; ['en', 'ur', 'id'].forEach((k) => { if (f[k]?.trim()) tr[k] = f[k].trim(); });
      await rpc('app_send_voice', { p_group_id: f.group ? Number(f.group) : null, p_transcript: f.ar, p_translations: tr, p_urgent: !!f.urgent });
      toast('أُرسلت الرسالة للحجاج'); loadVoice();
    },
  });
}
