/*
 * app.js — UI for Edison School Answers.
 *
 * All the thinking lives in engine.js; this file only renders it and handles
 * the one network call (the district's live feed, for closings).
 */
(function () {
  'use strict';

  const E = window.EdisonEngine;
  const PACK = window.PACK;
  const RULES = window.RULES;

  const el = (id) => document.getElementById(id);
  const thread = el('thread');
  const wrap = el('wrap');
  const alertsBox = el('alerts');

  // localStorage can throw (private windows, blocked site data), and the app
  // has to work without it — the saved school is a convenience, not state the
  // answers depend on.
  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : v; } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* ignore */ } }
  };

  let schoolId = store.get('schoolId', '');
  let liveAlerts = [];
  let alertStatus = { state: 'idle', at: null, note: '' };

  const engine = () => {
    const p = Object.assign({}, PACK);
    p.alerts = E.AlertParser.merge((PACK.alerts || []).concat(liveAlerts));
    return new E.AnswerEngine(p, RULES);
  };

  const schoolById = (id) => (PACK.schools || []).find((s) => s.id === id) || null;

  // ---------------------------------------------------------------- render

  function esc(s) {
    return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  }

  /**
   * An answer's first line carries the verdict; the bell-time lines that
   * follow are a small table, not prose. Splitting them makes the thing a
   * parent actually wants ("open? closed? what time?") readable at a glance.
   */
  function renderAnswer(a) {
    const node = document.createElement('div');
    node.className = 'a';

    // Walk the lines in order, collecting runs of prose and runs of bell
    // times. Order matters: "Regular school hours:" introduces the table and
    // the note about delayed openings follows it, so sorting all prose to the
    // top would read as nonsense.
    const HOUR_RE = /^(.+?):\s(\d{1,2}:\d{2}\s[AP]M\sto\s\d{1,2}:\d{2}\s[AP]M)$/;
    const blocks = [];
    for (const raw of String(a.answer).split('\n')) {
      const line = raw.trim();
      const m = HOUR_RE.exec(line);
      const kind = m ? 'hours' : 'prose';
      const last = blocks[blocks.length - 1];
      if (!last || last.kind !== kind) blocks.push({ kind: kind, items: [] });
      blocks[blocks.length - 1].items.push(m ? [m[1], m[2]] : line);
    }

    const verdict = verdictFor(a);
    if (verdict) {
      const v = document.createElement('span');
      v.className = 'verdict ' + verdict.tone;
      v.innerHTML = '<span class="dot"></span>' + esc(verdict.label);
      node.appendChild(v);
    }

    for (const b of blocks) {
      if (b.kind === 'prose') {
        const text = b.items.join('\n').trim();
        if (!text) continue;
        const p = document.createElement('div');
        p.className = 'body';
        p.textContent = text;
        node.appendChild(p);
      } else {
        const h = document.createElement('div');
        h.className = 'hours';
        for (const [who, when] of b.items) {
          const r = document.createElement('div');
          r.className = 'hour-row';
          r.innerHTML = '<b>' + esc(who) + '</b><span>' + esc(when) + '</span>';
          h.appendChild(r);
        }
        node.appendChild(h);
      }
    }

    const meta = document.createElement('div');
    meta.className = 'meta';
    if (a.confidence < 0.5) {
      const w = document.createElement('span');
      w.className = 'lowconf';
      w.textContent = "I'm not confident about this one — please double-check.";
      meta.appendChild(w);
    }
    if (a.sources && a.sources.length) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'srcbtn';
      btn.textContent = 'Where this came from';
      const list = document.createElement('div');
      list.className = 'sources';
      list.hidden = true;
      for (const s of a.sources) {
        const link = document.createElement('a');
        link.href = s; link.target = '_blank'; link.rel = 'noopener';
        link.textContent = s;
        list.appendChild(link);
      }
      btn.addEventListener('click', () => {
        list.hidden = !list.hidden;
        btn.textContent = list.hidden ? 'Where this came from' : 'Hide sources';
      });
      meta.appendChild(btn);
      node.appendChild(meta);
      node.appendChild(list);
    } else if (meta.childNodes.length) {
      node.appendChild(meta);
    }

    return node;
  }

  function verdictFor(a) {
    if (a.intent !== 'school_status' && a.intent !== 'day_schedule') return null;
    switch (a.kind) {
      case 'open':            return { tone: 'ok',   label: 'School is open' };
      case 'closed':          return { tone: 'bad',  label: 'No school' };
      case 'weekend':         return { tone: 'bad',  label: 'No school' };
      case 'early_dismissal': return { tone: 'warn', label: 'Early dismissal' };
      case 'delayed_opening': return { tone: 'warn', label: 'Delayed opening' };
      default: return null;
    }
  }

  function ask(text) {
    const q = String(text || '').trim();
    if (!q) return;

    el('intro') && el('intro').remove();
    el('try-label') && el('try-label').remove();
    el('chips') && el('chips').remove();

    const qn = document.createElement('div');
    qn.className = 'q';
    qn.textContent = q;
    wrap.appendChild(qn);

    let a;
    try {
      a = engine().answer(q, undefined, schoolId);
    } catch (err) {
      a = { answer: 'Something went wrong answering that. Try rewording it.',
            intent: 'error', kind: 'error', sources: [], confidence: 0 };
      if (window.console) console.error(err);
    }
    wrap.appendChild(renderAnswer(a));

    el('ask').value = '';
    autosize();
    requestAnimationFrame(() => { thread.scrollTop = thread.scrollHeight; });
  }

  // ---------------------------------------------------------------- alerts

  function renderAlerts() {
    alertsBox.innerHTML = '';
    const today = E.isoOf(E.todayIn(PACK.district.timeZone));
    const merged = E.AlertParser.merge((PACK.alerts || []).concat(liveAlerts));
    const active = merged
      .filter((a) => a.date >= today)
      .filter((a) => !a.schoolId || a.schoolId === schoolId)
      .sort((a, b) => a.date.localeCompare(b.date));

    for (const a of active) {
      const d = document.createElement('div');
      d.className = 'alert ' + (a.kind === 'closed' ? 'closed' : a.kind === 'delayed_opening' ? 'delay' : 'early');
      const head = a.kind === 'closed' ? 'Schools closed'
                 : a.kind === 'delayed_opening' ? 'Delayed opening'
                 : 'Early dismissal';
      const when = E.friendlyDay(a.date, PACK.district.timeZone);
      d.innerHTML =
        '<h2>' + esc(head + ' ' + when) + '</h2>' +
        '<p>' + esc(a.text) + '</p>' +
        (a.postedAt ? '<time>' + esc(new Date(a.postedAt).toLocaleString('en-US',
          { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })) + '</time>' : '');
      alertsBox.appendChild(d);
    }
  }

  /**
   * Reads the district's public live feed, plus the saved school's own feed.
   * This is the only network call the app makes. It is blocked when the page
   * is opened straight off disk (file://) or inside a sandboxed frame, so a
   * failure is reported plainly rather than left to look like "no closings".
   */
  async function checkAlerts() {
    const urls = [];
    if (PACK.alertFeedUrl) urls.push([PACK.alertFeedUrl, '']);
    if (schoolId && PACK.schoolFeedUrls && PACK.schoolFeedUrls[schoolId]) {
      urls.push([PACK.schoolFeedUrls[schoolId], schoolId]);
    }
    if (!urls.length) return;

    alertStatus = { state: 'checking', at: null, note: '' };
    const parser = new E.AlertParser(RULES, PACK.district.timeZone);
    let found = [];
    let ok = false;

    for (const [url, sid] of urls) {
      try {
        const res = await fetch(url, { cache: 'no-store' });
        if (!res.ok) continue;
        found = found.concat(parser.fromFeed(await res.json(), sid));
        ok = true;
      } catch (e) { /* try the next feed */ }
    }

    if (ok) {
      liveAlerts = found;
      alertStatus = { state: 'ok', at: new Date(), note: '' };
    } else {
      alertStatus = {
        state: 'blocked', at: new Date(),
        note: location.protocol === 'file:'
          ? 'This page was opened straight from a file, which browsers block from making requests. Run Run-WebApp.bat instead and live checks work.'
          : 'This copy cannot reach the district feed. Everything else still works from the information built into the app; run it from Run-WebApp.bat, or host it yourself, for live closing checks.'
      };
    }
    renderAlerts();
    renderSettings();
  }

  // ---------------------------------------------------------------- settings

  function renderSettings() {
    const sel = el('school');
    if (!sel.options.length) {
      const order = ['elementary', 'middle', 'high', 'academy', 'eelc', 'fdr'];
      sel.innerHTML = '<option value="">Not set</option>';
      for (const lvl of order) {
        const group = (PACK.schools || []).filter((s) => s.level === lvl)
          .sort((a, b) => a.name.localeCompare(b.name));
        if (!group.length) continue;
        const og = document.createElement('optgroup');
        og.label = E.levelLabel(lvl);
        for (const s of group) {
          const o = document.createElement('option');
          o.value = s.id; o.textContent = s.name;
          og.appendChild(o);
        }
        sel.appendChild(og);
      }
    }
    sel.value = schoolId;

    const stat = el('alertstat');
    const help = el('alerthelp');
    if (alertStatus.state === 'ok') {
      const n = liveAlerts.length;
      stat.innerHTML = '<span>Checked ' +
        esc(alertStatus.at.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })) +
        ' — ' + (n ? n + ' found' : 'nothing announced') + '</span>';
      help.textContent = 'The district posts weather closings the afternoon before. Reopen the app to check again.';
    } else if (alertStatus.state === 'blocked') {
      stat.innerHTML = '<span>Live checks unavailable</span>';
      help.textContent = alertStatus.note;
    } else {
      stat.innerHTML = '<span>Checking…</span>';
      help.textContent = '';
    }

    const built = PACK.generatedAt ? new Date(PACK.generatedAt) : null;
    el('packstat').innerHTML =
      '<span>' + (PACK.schools || []).length + ' schools · ' +
      (PACK.calendar || []).length + ' calendar entries · ' +
      (PACK.facts || []).length + ' pages</span>' +
      (built ? '<span>Information built ' + esc(built.toLocaleDateString('en-US',
        { month: 'short', day: 'numeric', year: 'numeric' })) + '</span>' : '') +
      '<span>Unofficial. For same-day closings, ParentSquare and the district website are the authority.</span>';
  }

  function applySchool() {
    const s = schoolById(schoolId);
    el('scopeline').textContent = s ? s.name : 'Edison Township Public Schools';
    renderAlerts();
  }

  // ---------------------------------------------------------------- chips

  const SUGGESTIONS = [
    'Is there school tomorrow?',
    'What time does school start?',
    'When is the next early dismissal?',
    'When is spring break?',
    'How do I report my child absent?',
    "What's on the calendar next week?"
  ];

  function renderChips() {
    const box = el('chips');
    if (!box) return;
    for (const s of SUGGESTIONS) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'chip';
      b.innerHTML =
        '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
        'stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M9 18l6-6-6-6"/></svg>' +
        esc(s);
      b.addEventListener('click', () => ask(s));
      box.appendChild(b);
    }
  }

  // ---------------------------------------------------------------- wiring

  function autosize() {
    const t = el('ask');
    t.style.height = 'auto';
    t.style.height = Math.min(t.scrollHeight, 120) + 'px';
  }

  el('composer').addEventListener('submit', (e) => {
    e.preventDefault();
    ask(el('ask').value);
  });

  el('ask').addEventListener('input', autosize);
  el('ask').addEventListener('keydown', (e) => {
    // Enter sends; Shift+Enter makes a new line.
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      ask(el('ask').value);
    }
  });

  el('settings-btn').addEventListener('click', () => {
    renderSettings();
    el('sheet').showModal();
  });

  el('school').addEventListener('change', (e) => {
    schoolId = e.target.value;
    store.set('schoolId', schoolId);
    applySchool();
    checkAlerts();
  });

  // Re-check whenever the app comes back to the foreground — on a phone that
  // is the cheapest moment, and the afternoon-before posting pattern means it
  // is usually early enough to matter.
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) checkAlerts();
  });

  renderChips();
  applySchool();
  renderSettings();
  checkAlerts();

  if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
    navigator.serviceWorker.register('sw.js').catch(() => { /* offline is a bonus, not a requirement */ });
  }
})();
