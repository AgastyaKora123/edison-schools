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

  // A family can have children at more than one school. Older versions saved a
  // single id; carry that forward rather than losing the setting.
  let schoolIds = (function () {
    const many = store.get('schoolIds', '');
    if (many) return many.split(',').filter(Boolean);
    const one = store.get('schoolId', '');
    return one ? [one] : [];
  })();
  const saveSchools = () => store.set('schoolIds', schoolIds.join(','));

  let liveAlerts = [];
  let alertStatus = { state: 'idle', at: null, note: '' };

  // What the last question settled on, kept per school so a follow-up means
  // the same thing for each child.
  let lastContext = {};

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
   * Turns phone numbers and email addresses in an answer into things you can
   * tap. "Report an absence" becomes one tap to call instead of copying a
   * number out by hand — the kind of thing a website chatbot cannot give you.
   *
   * Built with real nodes rather than assembled markup, so answer text can
   * never be interpreted as HTML.
   */
  function fillLinkified(parent, text) {
    const re = /(\b\d{3}[-.\s]\d{3}[-.\s]\d{4}(?:\s*(?:x|ext\.?)\s*\d{2,6})?)|([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})/g;
    let last = 0, m;
    while ((m = re.exec(text)) !== null) {
      if (m.index > last) parent.appendChild(document.createTextNode(text.slice(last, m.index)));
      const a = document.createElement('a');
      if (m[1]) {
        const digits = m[1].replace(/[^\d]/g, '');
        const ext = /(?:x|ext\.?)\s*(\d{2,6})/i.exec(m[1]);
        a.href = 'tel:+1' + digits.slice(0, 10) + (ext ? ',' + ext[1] : '');
      } else {
        a.href = 'mailto:' + m[2];
      }
      a.textContent = m[0];
      a.className = 'tapable';
      parent.appendChild(a);
      last = m.index + m[0].length;
    }
    if (last < text.length) parent.appendChild(document.createTextNode(text.slice(last)));
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
        fillLinkified(p, text);
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

    // Hidden, not removed, so tapping the title brings the glance back.
    for (const id of ['glance', 'intro', 'try-label', 'chips', 'disclaimer']) {
      const n = el(id);
      if (n) n.hidden = true;
    }

    const qn = document.createElement('div');
    qn.className = 'q';
    qn.textContent = q;
    wrap.appendChild(qn);

    try {
      const eng = engine();
      // With children at several schools, answer for each and show the
      // answer once if they agree. Two children at the same level usually
      // get one answer; an elementary and a high schooler get two, which is
      // exactly what the parent needs to see.
      const ids = schoolIds.length ? schoolIds : [''];
      const results = ids.map((id) => ({
        id: id,
        a: eng.answer(q, undefined, id, lastContext[id] || null)
      }));
      for (const r of results) lastContext[r.id] = r.a.context;

      const unique = [];
      for (const r of results) {
        const same = unique.find((u) => u.a.answer === r.a.answer);
        if (same) same.ids.push(r.id);
        else unique.push({ a: r.a, ids: [r.id] });
      }

      for (const u of unique) {
        if (unique.length > 1) {
          const names = u.ids.map((id) => {
            const s = schoolById(id);
            return s ? s.shortName : 'All schools';
          }).join(' · ');
          const lbl = document.createElement('div');
          lbl.className = 'ans-school';
          lbl.textContent = names;
          wrap.appendChild(lbl);
        }
        wrap.appendChild(renderAnswer(u.a));
      }
    } catch (err) {
      wrap.appendChild(renderAnswer({
        answer: 'Something went wrong answering that. Try rewording it.',
        intent: 'error', kind: 'error', sources: [], confidence: 0
      }));
      if (window.console) console.error(err);
    }

    el('ask').value = '';
    autosize();
    requestAnimationFrame(() => { thread.scrollTop = thread.scrollHeight; });
  }

  // ---------------------------------------------------------------- glance

  /**
   * The opening view answers the two questions a parent has before they have
   * thought of a question: is there school, and what time. A chatbot on a
   * website cannot do this — it waits to be asked.
   *
   * Today is always shown. Tomorrow is shown too, because by evening that is
   * the one that matters, and because a closing announced this afternoon is
   * about tomorrow.
   */
  function renderGlance() {
    const box = el('glance');
    if (!box) return;
    box.innerHTML = '';

    const eng = engine();
    const today = eng.today();
    const days = [
      { when: 'Today', date: today },
      { when: 'Tomorrow', date: E.addDays(today, 1) }
    ];

    const card = document.createElement('div');
    card.className = 'glance';

    days.forEach((d, idx) => {
      const schools = schoolIds.length ? schoolIds.map(schoolById).filter(Boolean) : [null];
      const infos = schools.map((s) => ({ school: s, info: eng.dayInfo(d.date, s) }));

      // The worst status across the children drives the headline, so a
      // closure at one school is never hidden behind "open" at another.
      const rank = { closed: 3, delayed_opening: 2, early_dismissal: 1, weekend: 3, regular: 0, unknown: 0 };
      const worst = infos.slice().sort((a, b) => (rank[b.info.kind] || 0) - (rank[a.info.kind] || 0))[0].info;

      let tone = 'ok', head = 'School is open';
      if (worst.kind === 'weekend') { tone = 'bad'; head = 'No school'; }
      else if (worst.kind === 'closed') { tone = 'bad'; head = 'No school'; }
      else if (worst.kind === 'delayed_opening') { tone = 'warn'; head = 'Delayed opening'; }
      else if (worst.kind === 'early_dismissal') { tone = 'warn'; head = 'Early dismissal'; }
      else if (worst.kind === 'unknown') { tone = 'ok'; head = 'Not on the calendar'; }

      const day = document.createElement('div');
      day.className = 'glance-day' + (idx > 0 ? ' muted' : '');

      const when = document.createElement('div');
      when.className = 'glance-when';
      when.innerHTML = esc(d.when) + ' <em>' + esc(E.dateShort(d.date)) + '</em>';
      day.appendChild(when);

      const h = document.createElement('div');
      h.className = 'glance-head ' + tone;
      h.innerHTML = '<span class="dot"></span>' + esc(head);
      day.appendChild(h);

      // Times, per school when they differ.
      if (worst.kind !== 'weekend' && worst.kind !== 'closed') {
        const rows = document.createElement('div');
        rows.className = 'glance-rows';
        const seen = [];
        for (const { school, info } of infos) {
          const level = school ? school.level : null;
          const levels = level ? [level] : ['elementary', 'middle', 'high'];
          for (const lvl of levels) {
            const bell = (PACK.bells || []).find((b) => b.level === lvl);
            if (!bell) continue;
            const span = info.kind === 'delayed_opening' ? bell.delayed
                       : info.kind === 'early_dismissal' ? bell.early
                       : bell.regular;
            if (!span || !span.start) continue;
            const label = school ? school.shortName : E.levelLabel(lvl);
            const text = E.time12(span.start) + ' – ' + E.time12(span.end);
            const key = label + text;
            if (seen.indexOf(key) >= 0) continue;
            seen.push(key);
            const r = document.createElement('div');
            r.className = 'glance-row';
            r.innerHTML = '<b>' + esc(label) + '</b><span>' + esc(text) + '</span>';
            rows.appendChild(r);
          }
        }
        if (rows.childNodes.length) day.appendChild(rows);
      }

      if (worst.reason) {
        const why = document.createElement('div');
        why.className = 'glance-why';
        why.textContent = worst.reason;
        day.appendChild(why);
      }

      card.appendChild(day);
    });

    box.appendChild(card);
  }

  // ---------------------------------------------------------------- alerts

  function renderAlerts() {
    alertsBox.innerHTML = '';
    const today = E.isoOf(E.todayIn(PACK.district.timeZone));
    const merged = E.AlertParser.merge((PACK.alerts || []).concat(liveAlerts));
    const active = merged
      .filter((a) => a.date >= today)
      .filter((a) => !a.schoolId || schoolIds.indexOf(a.schoolId) >= 0)
      .sort((a, b) => a.date.localeCompare(b.date));

    for (const a of active) {
      const d = document.createElement('div');
      d.className = 'alert ' + (a.kind === 'closed' ? 'closed' : a.kind === 'delayed_opening' ? 'delay' : 'early');
      // Name the school when the closure is only that school's, so nobody
      // reads a one-building closure as a district snow day.
      const who = a.schoolId ? (schoolById(a.schoolId) || {}).shortName : null;
      const head = (a.kind === 'closed' ? (who ? who + ' closed' : 'Schools closed')
                 : a.kind === 'delayed_opening' ? (who ? who + ' opening late' : 'Delayed opening')
                 : (who ? who + ' early dismissal' : 'Early dismissal'));
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
    // One feed per child's school, so a closure at either one is seen.
    for (const id of schoolIds) {
      if (PACK.schoolFeedUrls && PACK.schoolFeedUrls[id]) {
        urls.push([PACK.schoolFeedUrls[id], id]);
      }
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
          ? 'Opened straight from a file, which browsers stop from going online. Everything already in the app still works.'
          : 'This copy cannot reach the district for live updates, so closings announced from now on will not appear here. Everything else works, including the calendar and hours. Always check ParentSquare on a bad-weather morning.'
      };
    }
    renderAlerts();
    // A newly found closing changes today's headline, not just the banner.
    renderGlance();
    renderSettings();
  }

  // ---------------------------------------------------------------- settings

  function renderSettings() {
    const picker = el('schoolpicker');
    if (!picker.childNodes.length) {
      const order = ['elementary', 'middle', 'high', 'academy', 'eelc', 'fdr'];
      for (const lvl of order) {
        const group = (PACK.schools || []).filter((s) => s.level === lvl)
          .sort((a, b) => a.name.localeCompare(b.name));
        if (!group.length) continue;
        const g = document.createElement('div');
        g.className = 'grp';
        g.textContent = E.levelLabel(lvl);
        picker.appendChild(g);
        for (const s of group) {
          const lab = document.createElement('label');
          const cb = document.createElement('input');
          cb.type = 'checkbox';
          cb.value = s.id;
          cb.id = 'sch-' + s.id;
          cb.addEventListener('change', () => {
            if (cb.checked) { if (schoolIds.indexOf(s.id) < 0) schoolIds.push(s.id); }
            else { schoolIds = schoolIds.filter((x) => x !== s.id); }
            saveSchools();
            applySchool();
            checkAlerts();
          });
          lab.appendChild(cb);
          lab.appendChild(document.createTextNode(s.name));
          picker.appendChild(lab);
        }
      }
    }
    for (const cb of picker.querySelectorAll('input[type=checkbox]')) {
      cb.checked = schoolIds.indexOf(cb.value) >= 0;
    }

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
    const names = schoolIds.map(schoolById).filter(Boolean).map((s) => s.shortName);
    el('scopeline').textContent = names.length ? names.join(' · ') : 'Edison Township Public Schools';

    // Once the glance card is answering today's question, the "here is what
    // this app does" paragraph is just pushing the suggestions off screen.
    const intro = el('intro');
    if (intro) intro.hidden = names.length > 0;

    renderAlerts();
    renderGlance();
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

  /** Clears the questions and brings today's summary back. */
  function goHome() {
    lastContext = {};   // a cleared thread starts a fresh conversation
    for (const n of wrap.querySelectorAll('.q, .a, .ans-school')) n.remove();
    for (const id of ['glance', 'intro', 'chips', 'try-label', 'disclaimer']) {
      const n = el(id);
      if (n) n.hidden = (id === 'intro') ? schoolIds.length > 0 : false;
    }
    renderGlance();
    thread.scrollTop = 0;
  }

  el('home-btn').addEventListener('click', goHome);

  // Each school's checkbox wires itself up in renderSettings.

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
