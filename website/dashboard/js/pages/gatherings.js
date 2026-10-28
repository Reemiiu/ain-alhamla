// التجمعات والحضور: فتح تجمع بمهلة، لوحة حضور لحظية، تسجيل يدوي، إغلاق التجمع، وإنهاء المنسك بتقرير.
import { supabase, rpc } from '../api.js';
import { renderShell, onTick } from '../shell.js';
import { esc, clock, dateTime, timeAgo, attPill, prioPill, openModal, toast, toLocalInput, initials, LANG } from '../ui.js';

const shell = renderShell({ page: 'gatherings.html', title: 'التجمعات والحضور', subtitle: 'افتح تجمعاً بموعد ومهلة، وتابع من وصل لحظة بلحظة' });
let groups = [], gatherings = [], selected = null, locations = [], rituals = [], trips = [];

if (shell) init(shell);

async function init({ content, actions }) {
  actions.innerHTML = '<button class="btn btn-primary" id="newBtn">+ تجمع جديد</button>';
  document.getElementById('newBtn').onclick = openCreate;
  content.innerHTML = `
    <div class="row" style="align-items:flex-start">
      <div class="card" style="flex:0 0 330px; max-width:100%"><div class="card-head"><h2>التجمعات</h2></div><div id="glist"></div></div>
      <div style="flex:1; min-width:300px" id="board"><div class="card"><div class="empty-state">اختر تجمعاً.</div></div></div>
    </div>`;
  const [me, loc, rit, tr] = await Promise.all([
    rpc('app_me'),
    supabase.from('locations').select('id, name, type').order('id'),
    supabase.from('rituals').select('id, name, status, seq').order('seq'),
    supabase.from('trips').select('id, vehicle_no, status').neq('status', 'COMPLETED'),
  ]);
  groups = me.groups; locations = loc.data ?? []; rituals = rit.data ?? []; trips = tr.data ?? [];
  await loadList();
  onTick(async () => { await loadList(); if (selected) renderBoard(); });
}

async function loadList() {
  const { data } = await supabase.from('gatherings')
    .select('id, title, group_id, ritual_id, scheduled_at, deadline_minutes, status, groups(name), locations(name), rituals(name)')
    .in('group_id', groups.map((g) => g.id)).order('scheduled_at', { ascending: false }).limit(60);
  gatherings = (data ?? []).sort((a, b) => (a.status === 'CLOSED') - (b.status === 'CLOSED') || new Date(a.scheduled_at) - new Date(b.scheduled_at));
  if (!selected) selected = gatherings.find((g) => g.status !== 'CLOSED')?.id ?? gatherings[0]?.id ?? null;
  document.getElementById('glist').innerHTML = gatherings.map((g) => `
    <button class="g-item ${g.id === selected ? 'on' : ''} ${g.status.toLowerCase()}" data-id="${g.id}">
      <b>${esc(g.title)}</b>
      <span class="meta">${esc(g.groups?.name ?? '')} · ${esc(g.locations?.name ?? '')}</span>
      <span class="meta">${dateTime(g.scheduled_at)} · ${g.status === 'CLOSED' ? 'مغلق' : g.status === 'OPEN' ? '<b class="txt-ok">مفتوح</b>' : 'مجدول'}</span>
    </button>`).join('') || '<div class="empty-state">لا توجد تجمعات بعد.</div>';
  document.querySelectorAll('.g-item').forEach((b) => b.onclick = () => { selected = Number(b.dataset.id); loadList(); renderBoard(); });
  if (selected && !document.querySelector('#board .att-board')) renderBoard();
}

let countdownTimer;
async function renderBoard() {
  const g = gatherings.find((x) => x.id === selected);
  if (!g) return;
  const [b, att] = await Promise.all([
    rpc('app_board', { p_group_id: g.group_id }),
    supabase.from('attendance').select('pilgrim_id, status, source, checkpoint_time, distance_m').eq('gathering_id', g.id),
  ]);
  const byP = Object.fromEntries((att.data ?? []).map((a) => [a.pilgrim_id, a]));
  const members = b.pilgrims;
  const ok = members.filter((p) => ['PRESENT', 'LATE'].includes(byP[p.id]?.status)).length;
  const pct = Math.round(100 * ok / Math.max(1, members.length));
  const deadline = new Date(new Date(g.scheduled_at).getTime() + g.deadline_minutes * 60000);
  const closed = g.status === 'CLOSED';

  document.getElementById('board').innerHTML = `
    <div class="card att-board">
      <div class="card-head"><h2>${esc(g.title)}</h2>
        <span class="pill ${closed ? 'muted' : pct === 100 ? 'good' : 'warn'}"><span class="dot"></span>${closed ? 'مغلق' : pct === 100 ? 'جاهزة للانطلاق' : 'بانتظار البقية'}</span></div>
      <div class="ready-big">
        <div class="ring" style="--p:${pct}"><span>${pct}٪</span></div>
        <div style="flex:1">
          <div class="meta">${esc(g.groups?.name ?? '')} · ${esc(g.locations?.name ?? '')}${g.rituals?.name ? ' · منسك ' + esc(g.rituals.name) : ''}</div>
          <div class="meta">الموعد ${clock(g.scheduled_at)} · المهلة ${g.deadline_minutes} دقيقة (حتى ${clock(deadline.toISOString())})</div>
          ${!closed ? `<div class="countdown" id="countdown"></div>` : ''}
          <div class="mini-stats">
            <span class="good">حاضر ${members.filter((p) => byP[p.id]?.status === 'PRESENT').length}</span>
            <span class="warn">متأخر ${members.filter((p) => byP[p.id]?.status === 'LATE').length}</span>
            <span class="crit">خارج النطاق ${members.filter((p) => byP[p.id]?.status === 'OUT_OF_RANGE').length}</span>
            <span class="muted">لم يسجّل ${members.filter((p) => !byP[p.id]).length}</span>
          </div>
        </div>
        <div class="board-actions">
          ${!closed ? '<button class="btn btn-outline" id="closeBtn">إغلاق التجمع</button>' : ''}
          ${g.ritual_id ? '<button class="btn btn-primary" id="finishBtn">إنهاء المنسك وإصدار التقرير</button>' : ''}
        </div>
      </div>
    </div>
    <div class="table-card"><div style="overflow-x:auto"><table class="db-table">
      <thead><tr><th>الحاج</th><th>الأولوية</th><th>الحالة</th><th>وقت التسجيل</th><th>المسافة</th>${closed ? '' : '<th>تسجيل يدوي</th>'}</tr></thead>
      <tbody>${members.map((p) => { const a = byP[p.id]; return `
        <tr class="${!a && !closed && new Date() > deadline ? 'row-missing' : ''}">
          <td><div class="row-person"><span class="row-avatar">${esc(initials(p.full_name))}</span><div>${esc(p.full_name)}
            ${p.preferred_language !== 'ar' ? `<span class="lang-chip">${LANG[p.preferred_language]}</span>` : ''}
            <div class="meta"><a href="tel:${esc(p.phone)}">${esc(p.phone)}</a></div></div></div></td>
          <td>${prioPill(p.priority_level, p.priority_reason)}</td>
          <td>${attPill(a?.status)}${a?.source === 'MANUAL' ? ' <small class="muted">يدوي</small>' : ''}</td>
          <td class="muted">${a ? clock(a.checkpoint_time) : '—'}</td>
          <td class="muted">${a?.distance_m != null ? a.distance_m + ' م' : p.last_ping ? `آخر موقع ${timeAgo(p.last_ping.at)}` : '—'}</td>
          ${closed ? '' : `<td><div class="seg sm" data-p="${p.id}">
            <button data-st="PRESENT">حاضر</button><button data-st="LATE">متأخر</button><button data-st="ABSENT">غائب</button></div></td>`}
        </tr>`; }).join('')}</tbody></table></div></div>`;

  clearInterval(countdownTimer);
  const cd = document.getElementById('countdown');
  if (cd) {
    const tickCd = () => {
      const ms = deadline - Date.now();
      const m = Math.floor(Math.abs(ms) / 60000), s = Math.floor(Math.abs(ms) / 1000) % 60;
      cd.className = `countdown ${ms < 0 ? 'over' : ms < 5 * 60000 ? 'soon' : ''}`;
      cd.textContent = ms >= 0 ? `متبقٍ على انتهاء المهلة ${m}:${String(s).padStart(2, '0')}` : `انتهت المهلة منذ ${m} د — يُنبَّه على الغائبين تلقائياً`;
    };
    tickCd(); countdownTimer = setInterval(tickCd, 1000);
  }
  document.querySelectorAll('.seg.sm button').forEach((btn) => btn.onclick = async () => {
    const pid = Number(btn.parentElement.dataset.p);
    try { await rpc('app_manual_attendance', { p_gathering_id: g.id, p_pilgrim_id: pid, p_status: btn.dataset.st }); renderBoard(); }
    catch (e) { toast(e.message, 'danger'); }
  });
  document.getElementById('closeBtn')?.addEventListener('click', () => openModal({
    title: 'إغلاق التجمع', submitLabel: 'إغلاق التجمع', danger: true,
    body: '<p>كل من لم يسجّل حضوره سيُسجَّل <b>غائباً</b> ويصدر له تنبيه غياب، ويتحدّث تقرير المنسك تلقائياً.</p>',
    onSubmit: async () => { const r = await rpc('app_close_gathering', { p_gathering_id: g.id }); toast(`أُغلق التجمع — غائبون: ${r.absent}`); await loadList(); renderBoard(); },
  }));
  document.getElementById('finishBtn')?.addEventListener('click', () => openModal({
    title: `إنهاء منسك «${g.rituals?.name ?? ''}» لـ${g.groups?.name ?? ''}`, submitLabel: 'إصدار التقرير',
    sub: 'يُغلق كل تجمعات المنسك المفتوحة، ويصدر التقرير للإدارة، ويُطلب من الحجاج تقييم المنسك.',
    body: '<label class="field-label">تعليقك على المنسك (يظهر للإدارة في التقرير)</label><textarea class="field" name="comment" rows="4" placeholder="ما الذي سار جيداً؟ ما الملاحظات والمقترحات؟"></textarea>',
    onSubmit: async (f) => { const id = await rpc('app_finish_ritual', { p_ritual_id: g.ritual_id, p_group_id: g.group_id, p_comment: f.comment }); location.href = `reports.html#r${id}`; },
  }));
}

function openCreate() {
  const now = new Date(Date.now() + 30 * 60000);
  openModal({
    title: 'تجمع جديد', sub: 'يصل إشعار لكل حجاج المجموعة بالموعد والمهلة، ويُنبَّه على من لم يسجّل بعد انتهائها.',
    body: `<div class="modal-grid">
      <div class="full"><label class="field-label">العنوان</label><input class="field" name="title" required placeholder="التجمع عند بوابة المخيم"></div>
      <div><label class="field-label">المجموعة</label><select class="field" name="group">${groups.map((g) => `<option value="${g.id}">${esc(g.name)}</option>`).join('')}</select></div>
      <div><label class="field-label">المكان</label><select class="field" name="loc">${locations.map((l) => `<option value="${l.id}">${esc(l.name)}</option>`).join('')}</select></div>
      <div><label class="field-label">الموعد</label><input class="field" type="datetime-local" name="at" value="${toLocalInput(now)}" required></div>
      <div><label class="field-label">المهلة (دقيقة)</label><input class="field" type="number" name="deadline" value="15" min="0" max="240"></div>
      <div><label class="field-label">المنسك</label><select class="field" name="ritual"><option value="">—</option>${rituals.filter((r) => r.status !== 'COMPLETED').map((r) => `<option value="${r.id}">${esc(r.name)}</option>`).join('')}</select></div>
      <div><label class="field-label">الحافلة</label><select class="field" name="trip"><option value="">—</option>${trips.map((t) => `<option value="${t.id}">${esc(t.vehicle_no)}</option>`).join('')}</select></div>
    </div>`,
    submitLabel: 'فتح التجمع',
    onSubmit: async (f) => {
      if (!f.title.trim()) throw new Error('اكتب عنوان التجمع');
      selected = await rpc('app_create_gathering', {
        p_group_id: Number(f.group), p_location_id: Number(f.loc), p_title: f.title, p_scheduled_at: new Date(f.at).toISOString(),
        p_deadline_minutes: Number(f.deadline || 15), p_ritual_id: f.ritual ? Number(f.ritual) : null, p_trip_id: f.trip ? Number(f.trip) : null,
      });
      toast('تم فتح التجمع وإشعار الحجاج'); await loadList(); renderBoard();
    },
  });
}
