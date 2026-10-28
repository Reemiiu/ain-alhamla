import { renderShell, onTick, isAdmin } from '../shell.js';
import { createLiveMap, MAP_LEGEND, saveOfflineArea, savedTilesCount } from '../live-map.js';
import { esc, timeAgo, ATT, PRIORITY } from '../ui.js';

const shell = renderShell({ page: 'map.html', title: 'الخريطة الحية', subtitle: 'آخر موقع لكل حاج ومشرف، النطاقات الآمنة، والبلاغات المفتوحة' });

if (shell) init(shell);

async function init({ content, user }) {
  content.innerHTML = `
    <div class="row" style="align-items:stretch">
      <div class="card" style="flex:3; min-width:300px">
        <div class="card-head"><h2>الخريطة</h2>
          <div class="offline-save"><span id="tilesInfo" class="meta"></span>
            <button class="btn btn-outline" id="saveOffline" title="ينزّل صور منطقة صغيرة حول مواقع الحملة فقط">حفظ الخريطة بدون إنترنت</button></div>
        </div>
        <div id="bigMap"></div>${MAP_LEGEND}
      </div>
      <div class="card side-list" style="flex:1; min-width:240px"><div class="card-head"><h2>${isAdmin(user) ? 'كل الحجاج' : 'مجموعتي'}</h2></div>
        <input class="field" id="mq" placeholder="ابحث..."><div id="plist"></div></div>
    </div>`;
  const m = await createLiveMap(document.getElementById('bigMap'), { height: 'calc(100vh - 240px)' });
  let data = await m.refresh();
  const draw = () => {
    const q = document.getElementById('mq').value.trim();
    const pr = { CRITICAL: 3, HIGH: 2, NORMAL: 1 };
    document.getElementById('plist').innerHTML = data.pilgrims.filter((p) => !q || p.name.includes(q))
      .sort((a, b) => (b.open_alert ? 1 : 0) - (a.open_alert ? 1 : 0) || pr[b.priority] - pr[a.priority])
      .map((p) => `<button class="p-item" data-lat="${p.lat}" data-lng="${p.lng}">
        <b>${esc(p.name)}</b>${p.open_alert ? ' <span class="pill crit">بلاغ</span>' : ''}${p.priority !== 'NORMAL' ? ` <span class="prio-chip ${PRIORITY[p.priority].cls}">${PRIORITY[p.priority].label}</span>` : ''}
        <span class="meta">${esc(p.group ?? '')} · ${ATT[p.status]?.label ?? 'لم يسجّل'} · ${timeAgo(p.at)} · 🔋${p.battery ?? '—'}٪</span></button>`).join('');
    document.querySelectorAll('.p-item').forEach((b) => b.onclick = () => m.focus(Number(b.dataset.lat), Number(b.dataset.lng)));
  };
  document.getElementById('mq').oninput = draw;
  draw();

  // حفظ صور الخريطة للمنطقة حول مواقع الحملة (تعمل بعدها بدون إنترنت)
  const info = document.getElementById('tilesInfo'), btn = document.getElementById('saveOffline');
  const showCount = async () => { const n = await savedTilesCount(); info.textContent = n ? `محفوظ: ${n} صورة` : ''; };
  showCount();
  btn.onclick = async () => {
    btn.disabled = true;
    const r = await saveOfflineArea(data.locations, (a, b) => { info.textContent = `جارٍ الحفظ ${a} من ${b}`; });
    btn.disabled = false;
    await showCount();
    if (!r.supported) info.textContent = 'المتصفح لا يدعم الحفظ';
    else info.textContent += r.complete ? ' — جاهزة بدون إنترنت ✓' : ' — انقطع الاتصال، أعيدي المحاولة';
  };
  onTick(async () => { data = await m.refresh(); draw(); });
}
