// تقارير المناسك: تقرير بعد كل منسك لكل مجموعة + تقرير شامل للمنسك، مع تعليق المشرف وتقييم الحجاج ورد الإدارة.
import { supabase, rpc } from '../api.js';
import { renderShell, isAdmin } from '../shell.js';
import { esc, dateTime, timeAgo, stars, openModal, toast, downloadCsv, PRIORITY, ATT } from '../ui.js';

const shell = renderShell({ page: 'reports.html', title: 'تقارير المناسك', subtitle: 'تقرير يصدر بعد كل منسك لكل مجموعة' });
let rituals = [], groups = [], reports = [], user;

if (shell) init(shell);

async function init(s) {
  user = s.user;
  const me = await rpc('app_me');
  groups = me.groups;
  await load();
  window.addEventListener('hashchange', route);
  route();
}

async function load() {
  const [r, rep] = await Promise.all([
    supabase.from('rituals').select('id, name, hajj_day, seq, status, starts_at, ends_at, locations(name)').order('seq'),
    supabase.from('ritual_reports').select('*, users(full_name)').in('group_id', groups.map((g) => g.id)),
  ]);
  rituals = r.data ?? []; reports = rep.data ?? [];
}

function rate(rp) { return rp.total_count ? Math.round(100 * (rp.present_count + rp.late_count) / rp.total_count) : null; }

function route() {
  const h = location.hash;
  if (h.startsWith('#r')) return showReport(Number(h.slice(2)));
  if (h.startsWith('#all')) return showRitual(Number(h.slice(4)));
  showGrid();
}

function showGrid() {
  const c = shell.content;
  c.innerHTML = `
    <div class="table-card"><div style="overflow-x:auto"><table class="db-table report-grid">
      <thead><tr><th>المنسك</th>${groups.map((g) => `<th>${esc(g.name)}</th>`).join('')}<th></th></tr></thead>
      <tbody>${rituals.map((r) => `<tr>
        <td><b>${esc(r.name)}</b><div class="meta">${r.hajj_day} ذي الحجة · ${esc(r.locations?.name ?? '')} ·
          <span class="pill ${r.status === 'COMPLETED' ? 'good' : r.status === 'IN_PROGRESS' ? 'warn' : 'muted'}">${r.status === 'COMPLETED' ? 'مكتمل' : r.status === 'IN_PROGRESS' ? 'جارٍ الآن' : 'قادم'}</span></div></td>
        ${groups.map((g) => {
          const rp = reports.find((x) => x.ritual_id === r.id && x.group_id === g.id);
          if (!rp) {
            return `<td>${r.status !== 'UPCOMING' && !isAdmin(user)
              ? `<button class="btn btn-outline sm" data-issue="${r.id}" data-g="${g.id}">إصدار التقرير</button>` : '<span class="muted">لم يصدر</span>'}</td>`;
          }
          const pct = rate(rp);
          return `<td><a class="rep-cell" href="#r${rp.id}"><b class="${pct >= 95 ? 'txt-ok' : pct >= 80 ? 'txt-warn' : 'txt-danger'}">${pct ?? '—'}٪</b>
            <span>حضور</span>${rp.absent_count ? `<span class="pill crit">${rp.absent_count} غياب</span>` : ''}
            ${rp.avg_rating ? stars(rp.avg_rating) : ''}${rp.supervisor_comment ? '<span class="pill muted">💬 تعليق</span>' : ''}</a></td>`;
        }).join('')}
        <td>${reports.some((x) => x.ritual_id === r.id) ? `<a class="btn btn-outline sm" href="#all${r.id}">التقرير الشامل</a>` : ''}
          ${user.role === 'ADMIN' && r.status !== 'COMPLETED' && r.status !== 'UPCOMING' ? `<button class="btn btn-primary sm" data-complete="${r.id}">إنهاء المنسك للحملة</button>` : ''}</td>
      </tr>`).join('')}</tbody></table></div></div>
    <p class="meta">النسبة = (حاضر + متأخر) ÷ عدد أفراد المجموعة. يصدر التقرير عند إنهاء المشرف للمنسك، أو تلقائياً عند إنهاء الإدارة للمنسك.</p>`;
  c.querySelectorAll('[data-issue]').forEach((b) => b.onclick = () => issue(Number(b.dataset.issue), Number(b.dataset.g)));
  c.querySelectorAll('[data-complete]').forEach((b) => b.onclick = () => openModal({
    title: 'إنهاء المنسك للحملة كاملة', submitLabel: 'إنهاء وإصدار التقارير',
    body: '<p>يصدر تقرير لكل مجموعة لم يُصدر لها تقرير بعد، ويتغيّر المنسك إلى «مكتمل».</p>',
    onSubmit: async () => { await rpc('app_set_ritual_status', { p_ritual_id: Number(b.dataset.complete), p_status: 'COMPLETED' }); await load(); showGrid(); toast('صدرت التقارير'); },
  }));
}

function issue(ritualId, groupId) {
  const r = rituals.find((x) => x.id === ritualId);
  openModal({
    title: `إصدار تقرير «${r.name}»`, submitLabel: 'إصدار التقرير',
    body: '<label class="field-label">تعليقك على المنسك</label><textarea class="field" name="comment" rows="4"></textarea>',
    onSubmit: async (f) => { const id = await rpc('app_finish_ritual', { p_ritual_id: ritualId, p_group_id: groupId, p_comment: f.comment }); await load(); location.hash = `r${id}`; },
  });
}

async function showReport(id) {
  let rp = reports.find((x) => x.id === id);
  if (!rp) { await load(); rp = reports.find((x) => x.id === id); }
  if (!rp) { location.hash = ''; return; }
  const r = rituals.find((x) => x.id === rp.ritual_id), g = groups.find((x) => x.id === rp.group_id);
  const { data: com } = await supabase.from('comments').select('id, kind, body, rating, created_at, parent_id, users(full_name)')
    .eq('ritual_id', rp.ritual_id).eq('group_id', rp.group_id).order('created_at');
  const s = rp.summary ?? {}, pct = rate(rp);
  shell.content.innerHTML = `
    <div class="report-head no-print"><a class="link" href="#">→ كل التقارير</a>
      <div class="page-actions"><button class="btn btn-outline" id="csvBtn">تصدير CSV</button><button class="btn btn-primary" onclick="print()">طباعة / PDF</button></div></div>
    <div class="card report-doc">
      <div class="report-title">
        <img src="../assets/logo.jpg" alt=""><div><div class="meta">تقرير منسك — عين الحملة</div><h2>${esc(r?.name)} · ${esc(g?.name)}</h2>
        <div class="meta">${r?.hajj_day} ذي الحجة · صدر ${dateTime(rp.updated_at)}${rp.users?.full_name ? ` · بواسطة ${esc(rp.users.full_name)}` : ''}</div></div>
      </div>
      <div class="stat-row compact">
        <div class="stat-card"><span>نسبة الحضور</span><div class="stat-value">${pct ?? '—'}٪</div></div>
        <div class="stat-card"><span>حاضر</span><div class="stat-value txt-ok">${rp.present_count}</div></div>
        <div class="stat-card"><span>متأخر</span><div class="stat-value txt-warn">${rp.late_count}</div></div>
        <div class="stat-card"><span>غائب / خارج النطاق</span><div class="stat-value txt-danger">${rp.absent_count + rp.out_of_range_count}</div></div>
        <div class="stat-card"><span>تنبيهات · SOS</span><div class="stat-value">${rp.alerts_count} · ${rp.sos_count}</div></div>
        <div class="stat-card"><span>متوسط الاستجابة</span><div class="stat-value">${rp.avg_response_min ?? '—'}<small> د</small></div></div>
        <div class="stat-card"><span>تقييم الحجاج</span><div class="stat-value">${rp.avg_rating ?? '—'}</div>${stars(rp.avg_rating)}</div>
      </div>
      <h3>التجمعات</h3>
      <table class="db-table"><thead><tr><th>التجمع</th><th>المكان</th><th>الوقت</th><th>حاضر</th><th>متأخر</th><th>غائب</th></tr></thead>
        <tbody>${(s.gatherings ?? []).map((x) => `<tr><td>${esc(x.title)}</td><td>${esc(x.location)}</td><td>${dateTime(x.scheduled_at)}</td>
          <td>${x.present}</td><td>${x.late}</td><td>${x.absent}</td></tr>`).join('') || '<tr><td colspan="6" class="muted">لا توجد تجمعات مسجّلة لهذا المنسك</td></tr>'}</tbody></table>
      <h3>حالات تحتاج متابعة</h3>
      ${(s.issues ?? []).length ? `<ul class="issue-list">${s.issues.map((x) => `<li><b>${esc(x.name)}</b> — ${ATT[x.status]?.label ?? 'لم يسجّل'}
        ${x.priority !== 'NORMAL' ? `<span class="prio-chip ${PRIORITY[x.priority]?.cls}">أولوية ${PRIORITY[x.priority]?.label}</span>` : ''}</li>`).join('')}</ul>`
        : '<p class="muted">لا يوجد — حضر الجميع في الوقت ✔</p>'}
      <h3>تعليق المشرف</h3>
      <blockquote class="sup-comment">${esc(rp.supervisor_comment || 'لم يكتب المشرف تعليقاً.')}</blockquote>
      <h3>تقييم الحجاج وتعليقاتهم</h3>
      ${(com ?? []).filter((c) => c.kind === 'PILGRIM_FEEDBACK').map((c) => `<div class="feed-row"><div>${stars(c.rating)} <b>${esc(c.users?.full_name)}</b>
        <div class="feed-body">${esc(c.body || '—')}</div></div></div>`).join('') || '<p class="muted">لا توجد تقييمات بعد.</p>'}
      <h3>النقاش بين المشرف والإدارة</h3>
      <div id="thread">${(com ?? []).filter((c) => c.kind !== 'PILGRIM_FEEDBACK').map((c) => `<div class="feed-row ${c.parent_id ? 'reply' : ''}"><div>
        <b>${esc(c.users?.full_name)}</b> <span class="kind-tag k-${c.kind}">${c.kind === 'ADMIN_REPLY' ? 'الإدارة' : 'المشرف'}</span>
        <div class="feed-body">${esc(c.body)}</div><span class="meta">${timeAgo(c.created_at)}</span></div></div>`).join('') || '<p class="muted">لا يوجد نقاش.</p>'}</div>
      <form class="inline-form no-print" id="replyForm"><input class="field" name="body" required placeholder="${isAdmin(user) ? 'رد الإدارة على المشرف...' : 'أضف تعليقاً للإدارة...'}"><button class="btn btn-primary">إرسال</button></form>
    </div>`;
  document.getElementById('replyForm').onsubmit = async (e) => {
    e.preventDefault();
    const parent = (com ?? []).filter((c) => c.kind === 'SUPERVISOR_NOTE').pop();
    try {
      await rpc('app_add_comment', { p_body: e.target.body.value, p_ritual_id: rp.ritual_id, p_group_id: rp.group_id, p_parent_id: isAdmin(user) ? parent?.id ?? null : null });
      toast('تم الإرسال'); showReport(id);
    } catch (ex) { toast(ex.message, 'danger'); }
  };
  document.getElementById('csvBtn').onclick = () => downloadCsv(`تقرير_${r?.name}_${g?.name}.csv`, [
    ['المنسك', r?.name], ['المجموعة', g?.name], ['نسبة الحضور', `${pct}%`], ['حاضر', rp.present_count], ['متأخر', rp.late_count],
    ['غائب', rp.absent_count], ['خارج النطاق', rp.out_of_range_count], ['تنبيهات', rp.alerts_count], ['SOS', rp.sos_count],
    ['متوسط الاستجابة (د)', rp.avg_response_min], ['تقييم الحجاج', rp.avg_rating], ['تعليق المشرف', rp.supervisor_comment], [],
    ['الحاج', 'الحالة', 'الأولوية'], ...(s.issues ?? []).map((x) => [x.name, ATT[x.status]?.label ?? 'لم يسجّل', PRIORITY[x.priority]?.label]),
  ]);
}

function showRitual(rid) {
  const r = rituals.find((x) => x.id === rid);
  const reps = reports.filter((x) => x.ritual_id === rid);
  const sum = (k) => reps.reduce((a, x) => a + (x[k] ?? 0), 0);
  const tot = sum('total_count'), pct = tot ? Math.round(100 * (sum('present_count') + sum('late_count')) / tot) : null;
  shell.content.innerHTML = `
    <div class="report-head no-print"><a class="link" href="#">→ كل التقارير</a><button class="btn btn-primary" onclick="print()">طباعة / PDF</button></div>
    <div class="card report-doc">
      <div class="report-title"><img src="../assets/logo.jpg" alt=""><div><div class="meta">التقرير الشامل للمنسك</div><h2>${esc(r?.name)}</h2>
        <div class="meta">${r?.hajj_day} ذي الحجة · ${reps.length} مجموعة · ${tot} حاجاً</div></div></div>
      <div class="stat-row compact">
        <div class="stat-card"><span>نسبة الحضور</span><div class="stat-value">${pct ?? '—'}٪</div></div>
        <div class="stat-card"><span>غياب</span><div class="stat-value txt-danger">${sum('absent_count')}</div></div>
        <div class="stat-card"><span>تأخر</span><div class="stat-value txt-warn">${sum('late_count')}</div></div>
        <div class="stat-card"><span>تنبيهات</span><div class="stat-value">${sum('alerts_count')}</div></div>
        <div class="stat-card"><span>SOS</span><div class="stat-value">${sum('sos_count')}</div></div>
      </div>
      <table class="db-table"><thead><tr><th>المجموعة</th><th>الحضور</th><th>حاضر</th><th>متأخر</th><th>غائب</th><th>تنبيهات</th><th>الاستجابة</th><th>التقييم</th><th>تعليق المشرف</th></tr></thead>
      <tbody>${reps.map((x) => `<tr><td><a href="#r${x.id}">${esc(groups.find((g) => g.id === x.group_id)?.name)}</a></td><td><b>${rate(x)}٪</b></td>
        <td>${x.present_count}</td><td>${x.late_count}</td><td>${x.absent_count}</td><td>${x.alerts_count}</td><td>${x.avg_response_min ?? '—'} د</td>
        <td>${stars(x.avg_rating)}</td><td class="muted">${esc(x.supervisor_comment ?? '—')}</td></tr>`).join('')}</tbody></table>
    </div>`;
}
