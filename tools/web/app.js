/*
 * app.js — UI for School Answers.
 *
 * All the thinking lives in engine.js; this file only renders it and handles
 * the one network call (the district's live feed, for closings).
 */
(function () {
  'use strict';

  const E = window.SchoolEngine || window.EdisonEngine;
  const RULES = window.RULES;

  // The district the app was built with, collected in full: its pages, its
  // bell times, its office numbers. Any other district is read live instead,
  // which gets the calendar and the closings but not the pages - see
  // district.js for why.
  const BUNDLED = window.PACK;
  let PACK = BUNDLED;

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
  function renderAnswer(a, question) {
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

  // Set once the parent asks something, so a background update never reloads
  // the page out from under an answer they are reading.
  let asked = false;

  /**
   * Every typed question goes to Schoolo when Schoolo is available.
   *
   * It used to be the other way round: rules first, Schoolo behind a button.
   * That meant each new way of phrasing something needed a new rule, and the
   * rules could not spell-check, could not tell "is today an early dismissal"
   * from "list the early dismissals", and never would. The model handles the
   * wording; the tools give it the exact dates, times and numbers. The rules
   * engine still runs the summary at the top of the screen — instant, free
   * and working with no signal — and still answers everything if Schoolo
   * cannot be reached.
   */
  async function ask(text) {
    const q = String(text || '').trim();
    if (!q) return;
    asked = true;

    showQuestion(q);

    const s = await getSampler();
    if (s) {
      const ok = await schooloAnswer(q, s);
      if (ok) return;
    }
    answerFromRules(q);
  }

  function showQuestion(q) {
    for (const id of ['glance', 'ways', 'intro', 'try-label', 'chips', 'disclaimer']) {
      const n = el(id);
      if (n) n.hidden = true;
    }
    const qn = document.createElement('div');
    qn.className = 'q';
    qn.textContent = q;
    wrap.appendChild(qn);
    el('ask').value = '';
    autosize();
    requestAnimationFrame(() => { thread.scrollTop = thread.scrollHeight; });
  }

  /** Returns true if Schoolo answered; false to fall back to the rules. */
  async function schooloAnswer(question, s) {
    const node = document.createElement('div');
    node.className = 'a claude';
    const badge = document.createElement('span');
    badge.className = 'claude-badge';
    badge.textContent = 'Schoolo';
    const body = document.createElement('div');
    body.className = 'body thinking';
    body.textContent = 'Thinking…';
    node.appendChild(badge);
    node.appendChild(body);
    wrap.appendChild(node);
    thread.scrollTop = thread.scrollHeight;

    let started = false;
    try {
      const limits = await s.limits().catch(() => null);
      const opts = {
        modelTier: 'quick',
        onText: ({ text }) => {
          started = true;
          body.classList.remove('thinking');
          body.textContent = text;
          thread.scrollTop = thread.scrollHeight;
        }
      };
      let prompt = buildPrompt(question);
      if (limits && limits.tools) {
        opts.tools = schooloTools();
      } else {
        // No tools here: hand over the closest pages instead.
        prompt += '\n\n--- DISTRICT INFORMATION ---\n' +
                  contextFor(question, 14000) + '\n--- END ---\n';
        opts.cache = { gcTime: 300000 };
      }
      await s(prompt, opts);
      badge.textContent = 'Schoolo · from the district\'s own pages';
      return true;
    } catch (err) {
      const code = (err && err.code) || 'upstream_error';
      if (code === 'rate_limited') {
        body.classList.remove('thinking');
        body.textContent = 'Schoolo is busy. Here is what the app knows:';
        return false;                 // rules answer underneath
      }
      if (started && err && err.text) {
        body.textContent = err.text;
        badge.textContent = 'Schoolo · cut off';
        return true;
      }
      node.remove();                  // say nothing about it; just answer
      return false;
    }
  }

  /** The offline answer: instant, exact, and limited to what it has rules for. */
  function answerFromRules(q) {
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
        wrap.appendChild(renderAnswer(u.a, q));
      }
    } catch (err) {
      wrap.appendChild(renderAnswer({
        answer: 'Something went wrong answering that. Try rewording it.',
        intent: 'error', kind: 'error', sources: [], confidence: 0
      }));
      if (window.console) console.error(err);
    }
    requestAnimationFrame(() => { thread.scrollTop = thread.scrollHeight; });
  }

  // ---------------------------------------------------------------- ask Claude

  /*
   * The built-in answers are exact and instant and work with no signal, so
   * they go first. But they only cover what someone thought to write a rule
   * for. When the app is unsure — or plainly could not find anything — it can
   * hand the question to Claude, along with the district pages that look
   * closest, and get a real answer back.
   *
   * It runs on the reader's own Claude account, so it asks their permission
   * the first time and only ever on a deliberate tap. If they say no, or they
   * are not signed in, the button simply is not there and everything else
   * still works.
   */
  // The promise is memoised, not its result: resolving can take ten seconds,
  // and several answers may ask at once. Caching the result would hand the
  // later callers a null that only meant "not resolved yet".
  let samplerPromise = null;

  function getSampler() {
    if (!samplerPromise) {
      samplerPromise = (window.claude && typeof window.claude.use === 'function')
        ? Promise.resolve(window.claude.use('sample')).catch(() => null)
        : Promise.resolve(null);
    }
    return samplerPromise;
  }

  /** The district pages most likely to hold the answer, as plain text. */
  function contextFor(question, limit) {
    const eng = engine();
    const terms = E.normalize(question).split(' ').filter((w) => w.length > 2);
    const school = schoolIds.length ? schoolById(schoolIds[0]) : null;
    const hits = eng.factMatches(terms, school, [], 5);
    let out = '';
    for (const h of hits) {
      const piece = `\n### ${h.fact.title}\n(${h.fact.url})\n${h.fact.text}\n`;
      if (out.length + piece.length > limit) break;
      out += piece;
    }
    return out;
  }

  /**
   * The app's own lookups, handed to Schoolo as things it can call.
   *
   * This is the part that matters. A rule per phrasing never finishes —
   * "list early dismissal days" needed its own rule, and the next way someone
   * phrases it will need another. Giving the model the lookups instead means
   * it handles the wording and the data handles the facts, which is the only
   * split that holds up. Dates, times and phone numbers always come from
   * here, never from the model's own recollection.
   */
  function schooloTools() {
    const eng = engine();

    const describeDay = (iso, school) => {
      const d = E.fromISO(iso);
      if (!d) return { error: 'Date must look like 2026-11-25.' };
      const info = eng.dayInfo(d, school || null);
      const out = {
        date: iso,
        weekday: E.dateLong(d).split(',')[0],
        status: info.kind,
        reason: info.reason || null
      };
      const field = info.kind === 'delayed_opening' ? 'delayed'
                  : info.kind === 'early_dismissal' ? 'early' : 'regular';
      if (info.kind !== 'closed' && info.kind !== 'weekend') {
        out.hours = {};
        for (const b of (PACK.bells || [])) {
          const span = b[field];
          if (span && span.start) {
            out.hours[E.levelLabel(b.level)] = E.time12(span.start) + ' to ' + E.time12(span.end);
          }
        }
      }
      return out;
    };

    const findSchool = (name) => {
      if (!name) return null;
      return eng.resolveSchool(E.normalize(String(name)));
    };

    return [
      {
        name: 'school_day',
        description: 'What kind of school day a given date is: open, closed, early dismissal, ' +
          'delayed opening or weekend, with the reason and the bell times that apply. ' +
          'Use this for any question about a specific day.',
        inputSchema: {
          type: 'object',
          properties: {
            date: { type: 'string', description: 'The date, as 2026-11-25.' },
            school: { type: 'string', description: 'Optional school name.' }
          },
          required: ['date']
        },
        execute: (input) => describeDay(String(input.date || ''), findSchool(input.school))
      },
      {
        name: 'special_days',
        description: 'Every day in the school year that is not a normal full day. ' +
          'Returns a list with dates, what each is, and whether it has passed. ' +
          'Use this for "list all", "how many are left", or planning questions.',
        inputSchema: {
          type: 'object',
          properties: {
            kind: {
              type: 'string',
              description: 'One of: closed, early_dismissal, delayed_opening, break, all.'
            }
          }
        },
        execute: (input) => {
          const k = String(input.kind || 'all').toLowerCase();
          const want = k === 'closed' ? ['closed']
            : k === 'break' ? ['break']
            : k === 'early_dismissal' ? ['early_dismissal', 'single_session']
            : k === 'delayed_opening' ? ['delayed_opening']
            : ['closed', 'break', 'early_dismissal', 'single_session', 'delayed_opening'];
          const today = E.isoOf(eng.today());
          return (PACK.calendar || [])
            .filter((e) => e.scope === 'district' && want.indexOf(e.kind) >= 0)
            .sort((a, b) => a.date.localeCompare(b.date))
            .map((e) => ({
              date: e.date,
              through: e.endDate !== e.date ? e.endDate : undefined,
              what: e.title,
              kind: e.kind,
              passed: (e.endDate || e.date) < today
            }));
        }
      },
      {
        name: 'school_contact',
        description: "A school's address, phone, fax and website. Use this for any " +
          'question about reaching a school, including reporting an absence.',
        inputSchema: {
          type: 'object',
          properties: { school: { type: 'string', description: 'The school name.' } },
          required: ['school']
        },
        execute: (input) => {
          const s = findSchool(input.school);
          if (!s) return { error: 'No school by that name. Ask search_pages instead.' };
          const c = (PACK.contacts || []).find((x) => x.schoolId === s.id) || {};
          return {
            school: s.name, level: E.levelLabel(s.level),
            address: c.address || null, phone: c.phone || null,
            fax: c.fax || null, website: s.url,
            otherNumbers: (c.phones || []).filter((p) => p !== c.phone),
            emails: c.emails || []
          };
        }
      },
      {
        name: 'search_pages',
        description: "Search the district's and schools' published pages. Returns the " +
          'closest few with their text and web address. Use this for policies, ' +
          'programmes, services and anything not about dates or contacts.',
        inputSchema: {
          type: 'object',
          properties: { query: { type: 'string', description: 'What to look for.' } },
          required: ['query']
        },
        execute: (input) => {
          const terms = E.normalize(String(input.query || '')).split(' ').filter((w) => w.length > 2);
          const school = schoolIds.length ? schoolById(schoolIds[0]) : null;
          return eng.factMatches(terms, school, [], 4).map((h) => ({
            title: h.fact.title,
            url: h.fact.url,
            text: String(h.fact.text || '').slice(0, 1800)
          }));
        }
      }
    ];
  }

  function buildPrompt(question) {
    const eng = engine();
    const today = eng.today();
    const mine = schoolIds.map(schoolById).filter(Boolean).map((s) => s.name);

    let p = 'You are Schoolo, answering questions for a parent in ' + districtName() + '.\n';
    p += 'Today is ' + E.dateLong(today) + '.\n';
    if (mine.length) p += 'Their children attend: ' + mine.join(', ') + '.\n';

    p += '\nYou have tools that read the district\'s own information. Use them rather than ';
    p += 'answering from memory:\n';
    p += '- school_day for anything about a particular date\n';
    p += '- special_days to list closings, early dismissals or breaks\n';
    p += '- school_contact for a school\'s phone, address or absence line\n';
    p += '- search_pages for policies, programmes and everything else\n';
    p += '\nCall as many as you need. Work out dates yourself before calling: if they say ';
    p += '"next Tuesday", convert it using today\'s date above.\n';
    p += '\nNever invent a date, a time or a phone number — if a tool did not give it to you, ';
    p += 'say you could not find it and point them to ' + (siteHost() || "the district's website") + " or their school office.\n";
    p += 'Answer in two to four short sentences, plainly, for a parent in a hurry. ';
    p += 'No headings and no bullet points unless you are listing dates, which you may list ';
    p += 'one per line.\n';
    p += '\nThe parent asks: ' + question;
    return p;
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

      // What is actually happening at their schools — spirit week, picture
      // day, a concert. The district publishes these per school and we
      // already collect them; they were just never being shown.
      const key = E.isoOf(d.date);
      const evts = [];
      for (const e of (PACK.calendar || [])) {
        if (e.kind !== 'event') continue;
        const ends = e.endDate || e.date;
        if (!(key >= e.date && key <= ends)) continue;
        if (e.scope === 'district') { evts.push({ title: e.title, who: null }); continue; }
        for (const id of (e.schoolIds || [])) {
          if (schoolIds.indexOf(id) < 0) continue;
          const s = schoolById(id);
          evts.push({ title: e.title, who: s ? s.shortName : null });
        }
      }

      if (evts.length) {
        const box = document.createElement('div');
        box.className = 'glance-events';
        const h = document.createElement('div');
        h.className = 'evt-head';
        h.textContent = evts.length === 1 ? 'Also on' : 'Also on (' + evts.length + ')';
        box.appendChild(h);
        // A few at most; the rest are a question away.
        for (const ev of evts.slice(0, 4)) {
          const row = document.createElement('div');
          row.className = 'evt';
          const b = document.createElement('b');
          b.textContent = ev.title;
          row.appendChild(b);
          if (ev.who && schoolIds.length > 1) {
            const who = document.createElement('span');
            who.className = 'who';
            who.textContent = ev.who;
            row.appendChild(who);
          }
          box.appendChild(row);
        }
        if (evts.length > 4) {
          const more = document.createElement('div');
          more.className = 'evt';
          more.textContent = '+ ' + (evts.length - 4) + ' more';
          box.appendChild(more);
        }
        day.appendChild(box);
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

  /**
   * Builds the school checklist into a container. Used by both the welcome
   * screen and Settings, so there is one list to keep right rather than two.
   */
  function buildPicker(container, idPrefix, onChange) {
    // Rebuilt from scratch, because changing district changes the schools.
    // This used to bail out if anything was already drawn, which left the
    // previous district's school list on screen under the new district's
    // name - a parent would have ticked a school in another state.
    container.textContent = '';

    // The three levels every district has, first and in the order a parent
    // thinks of them; then whatever else this district happens to run, in
    // its own words; then anything the level of which we could not work out,
    // which for a district read live is most of them. Nothing is dropped for
    // not fitting a category - a school missing from this list is a school a
    // parent cannot pick.
    const levels = [];
    for (const l of ['elementary', 'middle', 'high']) levels.push(l);
    for (const s of (PACK.schools || [])) {
      if (s.level && levels.indexOf(s.level) < 0) levels.push(s.level);
    }
    levels.push('');

    const districtLabels = (PACK.district && PACK.district.levelLabels) || null;
    for (const lvl of levels) {
      const group = (PACK.schools || []).filter((s) => (s.level || '') === lvl)
        .sort((a, b) => a.name.localeCompare(b.name));
      if (!group.length) continue;
      const g = document.createElement('div');
      g.className = 'grp';
      g.textContent = lvl ? E.levelLabel(lvl, districtLabels)
                          : (levels.some((l) => l && (PACK.schools || []).some((s) => s.level === l))
                             ? 'Other schools' : 'Schools');
      container.appendChild(g);
      for (const s of group) {
        const lab = document.createElement('label');
        const cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.value = s.id;
        cb.id = idPrefix + s.id;
        cb.addEventListener('change', () => {
          if (cb.checked) { if (schoolIds.indexOf(s.id) < 0) schoolIds.push(s.id); }
          else { schoolIds = schoolIds.filter((x) => x !== s.id); }
          saveSchools();
          syncPickers();
          if (onChange) onChange();
        });
        lab.appendChild(cb);
        lab.appendChild(document.createTextNode(s.name));
        container.appendChild(lab);
      }
    }
  }

  /** Keeps both copies of the list ticked the same way. */
  function syncPickers() {
    for (const id of ['schoolpicker', 'welcome-picker']) {
      const c = el(id);
      if (!c) continue;
      for (const cb of c.querySelectorAll('input[type=checkbox]')) {
        cb.checked = schoolIds.indexOf(cb.value) >= 0;
      }
    }
    const done = el('welcome-done');
    if (done) {
      done.disabled = schoolIds.length === 0;
      done.textContent = schoolIds.length === 0
        ? 'Pick at least one school'
        : (schoolIds.length === 1 ? 'Done' : `Done — ${schoolIds.length} schools`);
    }
  }

  function renderSettings() {
    buildPicker(el('schoolpicker'), 'sch-', () => { applySchool(); checkAlerts(); });
    syncPickers();

    renderBranding();

    const dstat = el('districtstat');
    if (dstat) {
      dstat.textContent = '';
      const line = document.createElement('span');
      line.textContent = districtName();
      dstat.appendChild(line);
      const what = document.createElement('span');
      // Said plainly, because the difference is real and a parent who does
      // not know it will think the app is broken when it cannot find their
      // district's dress code.
      what.textContent = hasPages()
        ? 'Calendar, closings, school hours, office numbers and the district’s pages.'
        : 'Calendar and closings, read from this district’s own feed. Its pages — policies, hours, office numbers — have not been collected, so questions about those go unanswered.';
      dstat.appendChild(what);
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
    el('scopeline').textContent = names.length ? names.join(' · ') : districtName();

    // Once the glance card is answering today's question, the "here is what
    // this app does" paragraph is just pushing the suggestions off screen.
    const intro = el('intro');
    if (intro) intro.hidden = names.length > 0;

    renderAlerts();
    renderGlance();
  }

  // ---------------------------------------------------------------- chips

  // Offered to someone who has not asked anything yet, so they can see what
  // the app is for. The second list is only offered where the district's
  // pages have been read: suggesting "how do I report my child absent" to
  // someone the app cannot answer that for is a small cruelty.
  const SUGGESTIONS_CALENDAR = [
    'Is there school tomorrow?',
    'When is the next early dismissal?',
    'When is spring break?',
    "What's on the calendar next week?"
  ];
  const SUGGESTIONS_PAGES = [
    'What time does school start?',
    'How do I report my child absent?'
  ];

  function renderChips() {
    const box = el('chips');
    if (!box) return;
    // Rebuilt, not added to: changing district changes what can be asked.
    box.textContent = '';
    const list = hasPages()
      ? SUGGESTIONS_CALENDAR.slice(0, 2).concat(SUGGESTIONS_PAGES, SUGGESTIONS_CALENDAR.slice(2))
      : SUGGESTIONS_CALENDAR;
    for (const s of list) {
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
    for (const id of ['glance', 'ways', 'intro', 'chips', 'try-label', 'disclaimer']) {
      const n = el(id);
      if (n) n.hidden = (id === 'intro') ? schoolIds.length > 0 : false;
    }
    renderGlance();
    thread.scrollTop = 0;
  }

  el('home-btn').addEventListener('click', () => { hideCalendar(); hidePractice(); goHome(); });

  // ---------------------------------------------------------------- month

  // Browsing and asking answer different moods: a question is for someone who
  // has one, a month is for someone deciding whether to book something on the
  // 14th. Only days that are not a normal full day are marked - a calendar
  // where every square is coloured tells you nothing.

  const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
                  'August', 'September', 'October', 'November', 'December'];

  let calMonth = null;    // the first of the month on screen
  let calPicked = null;   // the day whose detail is open, if any

  function dotClass(kind) {
    return kind === 'closed' ? 'closed'
         : kind === 'early_dismissal' ? 'early'
         : kind === 'delayed_opening' ? 'late' : '';
  }

  function kindLabel(kind) {
    return kind === 'closed' ? 'No school'
         : kind === 'early_dismissal' ? 'Early dismissal'
         : kind === 'delayed_opening' ? 'Delayed opening'
         : kind === 'weekend' ? 'Weekend'
         : kind === 'unknown' ? 'Beyond the published calendar'
         : 'Normal full day';
  }

  function renderCalendar() {
    const eng = engine();
    const grid = el('cal-grid');
    if (!eng || !grid) return;
    if (!calMonth) calMonth = E.anchor(eng.today().getUTCFullYear(),
                                       eng.today().getUTCMonth() + 1, 1);

    el('cal-title').textContent = MONTHS[calMonth.getUTCMonth()] + ' ' + calMonth.getUTCFullYear();
    grid.innerHTML = '';

    const school = schoolIds.length ? schoolById(schoolIds[0]) : null;
    const todayKey = E.isoOf(eng.today());
    const daysInMonth = new Date(Date.UTC(calMonth.getUTCFullYear(),
                                          calMonth.getUTCMonth() + 1, 0)).getUTCDate();

    // Pad so the 1st lands under its own weekday.
    for (let i = 0; i < calMonth.getUTCDay(); i++) {
      const blank = document.createElement('div');
      blank.className = 'cal-cell blank';
      grid.appendChild(blank);
    }

    for (let d = 1; d <= daysInMonth; d++) {
      const date = E.anchor(calMonth.getUTCFullYear(), calMonth.getUTCMonth() + 1, d);
      const key = E.isoOf(date);
      const info = eng.dayInfo(date, school);

      const cell = document.createElement('button');
      cell.type = 'button';
      cell.className = 'cal-cell'
        + (info.kind === 'weekend' ? ' weekend' : '')
        + (key === todayKey ? ' today' : '')
        + (key === calPicked ? ' picked' : '');
      cell.setAttribute('aria-label',
        E.dateLong(date) + ', ' + kindLabel(info.kind) + (info.reason ? ', ' + info.reason : ''));

      const num = document.createElement('span');
      num.className = 'cal-num';
      num.textContent = String(d);
      cell.appendChild(num);

      const dot = document.createElement('i');
      dot.className = 'cal-dot ' + dotClass(info.kind);
      cell.appendChild(dot);

      cell.addEventListener('click', () => {
        calPicked = (calPicked === key) ? null : key;
        renderCalendar();
      });
      grid.appendChild(cell);
    }

    renderCalendarDetail(eng, school);
  }

  function renderCalendarDetail(eng, school) {
    const box = el('cal-detail');
    if (!box) return;
    box.innerHTML = '';
    if (!calPicked) return;

    const date = E.fromISO(calPicked);
    if (!date) return;
    const info = eng.dayInfo(date, school);
    const entries = eng.entriesOn(date, school);

    const card = document.createElement('div');
    card.className = 'cal-detail';

    const h = document.createElement('h3');
    h.textContent = E.dateLong(date);
    card.appendChild(h);

    const k = document.createElement('p');
    k.className = 'kind';
    k.textContent = kindLabel(info.kind);
    card.appendChild(k);

    if (!entries.length) {
      const p = document.createElement('p');
      p.className = 'none';
      p.textContent = 'Nothing on the calendar for this day.';
      card.appendChild(p);
    } else {
      const ul = document.createElement('ul');
      for (const e of entries) {
        const li = document.createElement('li');
        li.textContent = e.title;
        ul.appendChild(li);
      }
      card.appendChild(ul);
    }
    box.appendChild(card);
  }

  function showCalendar() {
    const eng = engine();
    if (eng && !eng.publishesSchoolSchedule) {
      // Nothing to browse, so say why rather than showing an empty month.
      answerFromRules('what is on the calendar');
      return;
    }
    calPicked = null;
    el('thread').hidden = true;
    el('composer').hidden = true;
    el('calendar-view').hidden = false;
    renderCalendar();
    refreshCalendarExport();
    window.scrollTo(0, 0);
  }

  /**
   * The offer to put the dates in the phone's own calendar, which is this
   * website's version of the iPhone app's night-before reminders.
   *
   * Hidden rather than disabled when there is nothing to export: a district
   * that publishes no school schedule would otherwise get a button that
   * hands over an empty file.
   */
  function refreshCalendarExport() {
    const box = el('cal-export');
    if (!box) return;
    if (!window.SchoolCal || !window.PACK) { box.hidden = true; return; }

    const n = SchoolCal.count(PACK, { schoolIds: schoolIds });
    box.hidden = n === 0;
    if (n === 0) return;

    const note = el('cal-ics-note');
    if (note) {
      note.textContent = n + (n === 1 ? ' day' : ' days') +
        ', each with a reminder the evening before. Opens in the calendar ' +
        'app you already have, so the reminding happens even if you never ' +
        'open this page again.';
    }
  }

  function exportCalendarFile() {
    if (!window.SchoolCal || !window.PACK) return;
    const text = SchoolCal.build(PACK, { schoolIds: schoolIds });
    SchoolCal.download(text, SchoolCal.filename(PACK));
  }

  function hideCalendar() {
    const v = el('calendar-view');
    if (!v || v.hidden) return;
    v.hidden = true;
    el('thread').hidden = false;
    el('composer').hidden = false;
  }

  function shiftMonth(by) {
    if (!calMonth) return;
    calMonth = E.anchor(calMonth.getUTCFullYear(), calMonth.getUTCMonth() + 1 + by, 1);
    calPicked = null;
    renderCalendar();
  }

  // -------------------------------------------------------------- practice

  // Three states in one section: the decks, making one, studying one. The
  // logic lives in practice.js, shared rule-for-rule with the iPhone app.

  let decks = (window.Practice ? Practice.load() : []);
  let studyDeck = null;     // the deck being studied
  let studyQueue = [];      // today's cards, hardest first
  let studyDone = 0;

  function practiceDue() {
    return decks.reduce((n, d) => n + Practice.dueCards(d).length, 0);
  }

  /** Keeps the home card honest about what is waiting. */
  function refreshPracticeCard() {
    const sub = el('practice-sub');
    const badge = el('practice-badge');
    if (!sub || !badge) return;
    if (!decks.length) {
      // Since 1.3 there is something to practise without writing anything
      // first, and the card is the only place that gets said.
      sub.textContent = Practice.packs().length
        ? 'Your notes, or a set already written'
        : 'Turn your notes into questions';
      badge.hidden = true;
      return;
    }
    const due = practiceDue();
    sub.textContent = due ? (due + ' card' + (due === 1 ? '' : 's') + ' waiting')
                          : 'Nothing due - come back tomorrow';
    badge.hidden = due === 0;
    badge.textContent = String(due);
  }

  function showPracticePane(which) {
    for (const id of ['practice-decks', 'practice-new', 'practice-study']) {
      const n = el(id);
      if (n) n.hidden = (id !== 'practice-' + which);
    }
  }

  function showPractice() {
    el('thread').hidden = true;
    el('composer').hidden = true;
    hideCalendar();
    el('practice-view').hidden = false;
    renderDecks();
    showPracticePane('decks');
    window.scrollTo(0, 0);
  }

  function hidePractice() {
    const v = el('practice-view');
    if (!v || v.hidden) return;
    v.hidden = true;
    el('thread').hidden = false;
    el('composer').hidden = false;
    refreshPracticeCard();
  }

  function renderDecks() {
    const list = el('deck-list');
    if (!list) return;
    list.innerHTML = '';
    el('practice-empty').hidden = decks.length > 0;

    decks.forEach((d) => {
      const due = Practice.dueCards(d).length;
      const row = document.createElement('button');
      row.className = 'deck';
      row.type = 'button';

      const text = document.createElement('span');
      text.className = 'deck-text';
      const name = document.createElement('b');
      name.textContent = d.name;
      const sub = document.createElement('small');
      sub.textContent = d.cards.length + ' cards · ' + Practice.learned(d) + ' learned'
                      + (due ? ' · ' + due + ' due' : '');
      text.appendChild(name);
      text.appendChild(sub);
      row.appendChild(text);

      const del = document.createElement('span');
      del.className = 'deck-del';
      del.textContent = '×';
      del.title = 'Delete this deck';
      del.addEventListener('click', (e) => {
        e.stopPropagation();
        if (!window.confirm('Delete "' + d.name + '"? This cannot be undone.')) return;
        decks = decks.filter((x) => x.id !== d.id);
        Practice.save(decks);
        renderDecks();
      });
      row.appendChild(del);

      row.addEventListener('click', () => startStudy(d));
      list.appendChild(row);
    });

    renderPacks();
  }

  /**
   * The ready-made sets, under the decks somebody has made themselves.
   *
   * A set already taken stays listed but disabled rather than disappearing:
   * vanishing rows make a person wonder whether they imagined it, and the
   * greyed row is also the answer to "did I already add this?".
   */
  function renderPacks() {
    const box = el('pack-offer');
    const list = el('pack-list');
    if (!box || !list) return;

    const available = Practice.packs();
    box.hidden = available.length === 0;
    if (!available.length) return;

    list.innerHTML = '';
    available.forEach((p) => {
      const taken = decks.some((d) => d.packId === p.id);

      const row = document.createElement('button');
      row.className = 'deck';
      row.type = 'button';
      if (taken) row.disabled = true;

      const text = document.createElement('span');
      text.className = 'deck-text';

      const tag = document.createElement('span');
      tag.className = 'deck-tag';
      tag.textContent = p.subject + (taken ? ' · added' : '');

      const name = document.createElement('b');
      name.textContent = p.name;

      const sub = document.createElement('small');
      sub.textContent = p.cards.length + ' cards · ' + p.note;

      text.appendChild(tag);
      text.appendChild(name);
      text.appendChild(sub);
      row.appendChild(text);

      row.addEventListener('click', () => {
        if (taken) return;
        decks.push(Practice.deckFromPack(p));
        Practice.save(decks);
        renderDecks();
        refreshPracticeCard();
      });

      list.appendChild(row);
    });
  }

  // ---- making one

  function renderPreview() {
    const box = el('deck-preview');
    const notes = el('deck-notes').value;
    box.innerHTML = '';
    if (!notes.trim()) { el('deck-save').disabled = true; return; }

    const r = Practice.parse(notes);
    el('deck-save').disabled = r.cards.length === 0;

    const found = document.createElement('div');
    found.className = 'pr-preview';
    const h = document.createElement('h3');
    h.textContent = 'Found ' + r.cards.length + ' question' + (r.cards.length === 1 ? '' : 's');
    found.appendChild(h);

    r.cards.slice(0, 6).forEach((c) => {
      const p = document.createElement('div');
      p.className = 'pr-pair';
      const b = document.createElement('b');
      b.textContent = c.front;
      const s = document.createElement('span');
      s.textContent = c.back;
      p.appendChild(b); p.appendChild(s);
      found.appendChild(p);
    });
    if (r.cards.length > 6) {
      const more = document.createElement('p');
      more.className = 'pr-skip';
      more.textContent = 'and ' + (r.cards.length - 6) + ' more';
      found.appendChild(more);
    }
    box.appendChild(found);

    // Said out loud rather than silently dropped.
    if (r.skipped.length) {
      const sk = document.createElement('div');
      sk.className = 'pr-preview';
      const h2 = document.createElement('h3');
      h2.textContent = "Couldn't read " + r.skipped.length;
      sk.appendChild(h2);
      r.skipped.slice(0, 4).forEach((line) => {
        const p = document.createElement('p');
        p.className = 'pr-skip';
        p.textContent = line;
        sk.appendChild(p);
      });
      const why = document.createElement('p');
      why.className = 'pr-skip';
      why.textContent = 'These had no term and meaning in them - headings and '
                      + 'notes-to-self usually. Add a dash or a colon if one should be a question.';
      sk.appendChild(why);
      box.appendChild(sk);
    }
  }

  // ---- studying

  function startStudy(deck) {
    studyDeck = deck;
    studyQueue = Practice.dueCards(deck);
    studyDone = 0;
    el('study-title').textContent = deck.name;
    showPracticePane('study');
    renderStudy();
  }

  function renderStudy() {
    const card = studyQueue[0];
    const back = el('study-back');
    if (!card) {
      el('study-front').textContent = studyDone
        ? 'Done for now'
        : 'Nothing due in this deck';
      back.hidden = false;
      el('study-back-text').textContent = studyDone
        ? studyDone + ' answered. The ones you got wrong come back today; the rest come back later.'
        : 'Everything here has been answered recently. Come back tomorrow.';
      el('study-reveal-row').hidden = true;
      el('study-answer-row').hidden = true;
      el('study-left').textContent = '';
      return;
    }
    el('study-front').textContent = card.front;
    el('study-back-text').textContent = card.back;
    back.hidden = true;
    el('study-reveal-row').hidden = false;
    el('study-answer-row').hidden = true;
    el('study-left').textContent = studyQueue.length + ' left';
  }

  function answerStudy(correct) {
    const card = studyQueue[0];
    if (!card || !studyDeck) return;
    if (correct) Practice.markCorrect(card); else Practice.markWrong(card);
    Practice.save(decks);

    studyQueue.shift();
    // A card got wrong is not finished with: back to the end of today's
    // queue, so the session ends when you actually know them.
    if (!correct) studyQueue.push(card);
    studyDone += 1;
    renderStudy();
  }

  const wayPr = el('way-practice');
  if (wayPr) wayPr.addEventListener('click', showPractice);
  const deckNew = el('deck-new');
  if (deckNew) deckNew.addEventListener('click', () => {
    el('deck-name').value = '';
    el('deck-notes').value = '';
    el('deck-preview').innerHTML = '';
    el('deck-save').disabled = true;
    showPracticePane('new');
  });
  const deckNotes = el('deck-notes');
  if (deckNotes) deckNotes.addEventListener('input', renderPreview);
  const deckCancel = el('deck-cancel');
  if (deckCancel) deckCancel.addEventListener('click', () => showPracticePane('decks'));
  const deckSave = el('deck-save');
  if (deckSave) deckSave.addEventListener('click', () => {
    const r = Practice.parse(el('deck-notes').value);
    if (!r.cards.length) return;
    const name = el('deck-name').value.trim() || 'Untitled';
    decks.push(Practice.newDeck(name, r.cards));
    Practice.save(decks);
    renderDecks();
    showPracticePane('decks');
  });
  const sReveal = el('study-reveal');
  if (sReveal) sReveal.addEventListener('click', () => {
    el('study-back').hidden = false;
    el('study-reveal-row').hidden = true;
    el('study-answer-row').hidden = false;
  });
  const sRight = el('study-right');
  if (sRight) sRight.addEventListener('click', () => answerStudy(true));
  const sWrong = el('study-wrong');
  if (sWrong) sWrong.addEventListener('click', () => answerStudy(false));
  const sBack = el('study-back-btn');
  if (sBack) sBack.addEventListener('click', () => { renderDecks(); showPracticePane('decks'); });

  refreshPracticeCard();

  const wayCal = el('way-calendar');
  if (wayCal) wayCal.addEventListener('click', showCalendar);
  const calPrev = el('cal-prev');
  if (calPrev) calPrev.addEventListener('click', () => shiftMonth(-1));
  const calNext = el('cal-next');
  if (calNext) calNext.addEventListener('click', () => shiftMonth(1));
  const calIcs = el('cal-ics');
  if (calIcs) calIcs.addEventListener('click', exportCalendarFile);

  // Each school's checkbox wires itself up in renderSettings.

  // Re-check whenever the app comes back to the foreground — on a phone that
  // is the cheapest moment, and the afternoon-before posting pattern means it
  // is usually early enough to matter.
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) checkAlerts();
  });

  // ---------------------------------------------------------------- district

  /**
   * Choosing a district.
   *
   * The app knows of several thousand, from a list built once by searching
   * the platform they all share. It carries only one of them in full; the
   * rest are read from their own public feeds when a parent picks them, and
   * kept on the phone afterwards so the app still answers with no signal.
   */
  const DISTRICTS = (window.DISTRICTS || []).slice();
  const DD = window.DistrictData;

  const bundledOrgId = (BUNDLED.district && BUNDLED.district.orgId) || 0;

  // The district carried in full is always offered, whether or not the
  // search happened to list it, and under its own proper name. The search
  // list names districts after the folder they upload into, which for this
  // one reads "Edison Public Schools" where the district calls itself
  // "Edison Township Public Schools" - and a parent who picks one name
  // should not then see a different one at the top of the screen.
  if (bundledOrgId) {
    const bd = BUNDLED.district || {};
    const row = {
      o: bundledOrgId,
      n: bd.name || 'Your district',
      s: '',
      u: String(bd.url || '').replace(/^https?:\/\//, ''),
      k: (BUNDLED.schools || []).length
    };
    const at = DISTRICTS.findIndex((d) => d.o === bundledOrgId);
    if (at >= 0) DISTRICTS.splice(at, 1);
    DISTRICTS.unshift(row);
  }
  const PACK_KEY = (orgId) => 'districtPack:' + orgId;
  // Calendars change a few times a year, so a month-old copy is fine. The
  // things that change hour to hour - closings - are never cached: those are
  // fetched live every time the app opens.
  const PACK_MAX_AGE_DAYS = 30;

  function savedDistrictOrgId() {
    const v = parseInt(store.get('districtOrgId', ''), 10);
    return v > 0 ? v : bundledOrgId;
  }

  function districtRow(orgId) {
    return DISTRICTS.find((d) => d.o === orgId) || null;
  }

  function cachedPack(orgId) {
    try {
      const raw = localStorage.getItem(PACK_KEY(orgId));
      if (!raw) return null;
      const p = JSON.parse(raw);
      const age = (Date.now() - Date.parse(p.generatedAt || 0)) / 86400000;
      if (!(age >= 0) || age > PACK_MAX_AGE_DAYS) return null;
      return p;
    } catch (e) { return null; }
  }

  function cachePack(orgId, pack) {
    // Only ever one district's copy on the phone. A family uses one
    // district, and a big one runs to most of a megabyte; keeping every
    // district anyone ever looked at would eventually fill the quota and
    // start failing the save that matters.
    try {
      const keep = PACK_KEY(orgId);
      const stale = [];
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k && k.indexOf('districtPack:') === 0 && k !== keep) stale.push(k);
      }
      for (const k of stale) localStorage.removeItem(k);
    } catch (e) { /* ignore */ }

    try { localStorage.setItem(PACK_KEY(orgId), JSON.stringify(pack)); }
    catch (e) { /* a full or blocked store just means we rebuild next time */ }
  }

  /**
   * Makes `orgId` the district in use, fetching its information if this is
   * the first time. Returns true if it worked.
   */
  async function useDistrict(orgId, onStep) {
    if (!orgId || orgId === bundledOrgId) {
      PACK = BUNDLED;
      store.set('districtOrgId', String(bundledOrgId));
      return true;
    }
    let p = cachedPack(orgId);
    if (!p) {
      if (!DD) return false;
      const row = districtRow(orgId);
      p = await DD.build({
        orgId: orgId,
        name: row ? row.n : 'Your district',
        url: row && row.u ? 'https://' + row.u : ''
      }, RULES, onStep);
      cachePack(orgId, p);
    }
    PACK = p;
    store.set('districtOrgId', String(orgId));
    return true;
  }

  /** Districts whose name starts with, or contains, what has been typed. */
  function searchDistricts(q, limit) {
    const s = String(q || '').trim().toLowerCase();
    if (s.length < 2) return [];
    const starts = [], contains = [];
    for (const d of DISTRICTS) {
      const n = d.n.toLowerCase();
      if (n.startsWith(s)) starts.push(d);
      else if (n.indexOf(s) >= 0 || (d.s || '').toLowerCase() === s) contains.push(d);
      if (starts.length >= limit) break;
    }
    return starts.concat(contains).slice(0, limit);
  }

  function renderDistrictResults() {
    const box = el('district-results');
    const note = el('district-note');
    if (!box) return;
    const q = (el('district-search') || {}).value || '';
    box.textContent = '';
    if (q.trim().length < 2) {
      note.textContent = DISTRICTS.length
        ? DISTRICTS.length.toLocaleString() + ' districts to choose from.'
        : '';
      return;
    }
    const hits = searchDistricts(q, 10);
    if (!hits.length) {
      note.textContent = "No district by that name. It may not publish its calendar this way.";
      return;
    }
    note.textContent = '';
    for (const d of hits) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'dresult';
      const name = document.createElement('b');
      name.textContent = d.n;
      const sub = document.createElement('span');
      sub.textContent = [d.s, d.k ? d.k + ' schools' : ''].filter(Boolean).join(' · ');
      b.appendChild(name);
      b.appendChild(sub);
      b.addEventListener('click', () => pickDistrict(d));
      box.appendChild(b);
    }
  }

  async function pickDistrict(d) {
    const note = el('district-note');
    const box = el('district-results');
    if (box) box.textContent = '';
    if (note) note.textContent = 'Getting ' + d.n + "'s calendar…";
    try {
      // Changing district makes the old choice of schools meaningless.
      if (d.o !== savedDistrictOrgId()) { schoolIds = []; saveSchools(); }
      const ok = await useDistrict(d.o, (s) => { if (note) note.textContent = s + '…'; });
      if (!ok) throw new Error('could not load');
    } catch (e) {
      if (note) note.textContent = "Couldn't read that district's calendar. Try again, or pick another.";
      return;
    }
    showWelcomeStep('schools');
  }

  function districtName() {
    return (PACK.district && PACK.district.name) || 'Your district';
  }

  function districtShort() {
    const eng = new E.AnswerEngine(PACK, RULES);
    return eng.districtShort;
  }

  /**
   * The app's name, mark and small print all depend on whose schools it is
   * answering for, so none of them is written into the page.
   *
   * The small print in particular has to be honest about two different
   * things: for the district carried in full it is built from pages that
   * are linked under every answer; for a district read live there are no
   * pages, only the calendar and the closings.
   */
  function renderBranding() {
    // While the district question is on screen, nothing has been chosen, so
    // the app must not claim a district. Someone in Ohio opening this for
    // the first time was shown "Edison School Answers - Edison Township
    // Public Schools" directly above the words "Which district?", which
    // reads as though the question had already been answered, wrongly.
    //
    // This lives here rather than at the point the screen is drawn, because
    // the background check for closings re-renders when it finishes and was
    // quietly putting the wrong name back a second later.
    const choosing = (function () {
      const w = el('welcome'), d = el('welcome-district');
      return !!(w && d && !w.hidden && !d.hidden);
    })();
    if (choosing) {
      const t = el('apptitle');   if (t) t.textContent = 'School Answers';
      const m = el('home-mark');  if (m) m.textContent = 'S';
      const s = el('scopeline');  if (s) s.textContent = 'Choose your district';
      const dis = el('disclaimer'); if (dis) dis.textContent = '';
      try { document.title = 'School Answers'; } catch (e) { /* ignore */ }
      return;
    }

    const short = districtShort();
    const mark = el('home-mark');
    if (mark) mark.textContent = (short && short !== 'the district') ? short.charAt(0).toUpperCase() : 'S';

    const title = el('apptitle');
    if (title) {
      title.textContent = (short && short !== 'the district')
        ? short + ' School Answers' : 'School Answers';
    }

    const head = el('askhead');
    if (head) {
      head.textContent = (short && short !== 'the district')
        ? 'Ask about ' + short + ' schools.' : 'Ask about your schools.';
    }

    try { document.title = (title && title.textContent) || 'School Answers'; } catch (e) { /* ignore */ }

    const dis = el('disclaimer');
    if (!dis) return;
    dis.textContent = '';
    const site = siteHost();
    const parts = [
      hasPages()
        ? "Unofficial. Built from the district's own public pages, which are linked under every answer."
        : "Unofficial. Built from the calendar and announcements " + districtName() + ' publishes itself.',
      ' For same-day closings, the district’s own notifications and '
    ];
    dis.appendChild(document.createTextNode(parts[0] + parts[1]));
    if (site) {
      const a = document.createElement('a');
      a.href = 'https://' + site;
      a.target = '_blank';
      a.rel = 'noopener';
      a.textContent = site;
      dis.appendChild(a);
      dis.appendChild(document.createTextNode(' are the official word.'));
    } else {
      dis.appendChild(document.createTextNode('its website are the official word.'));
    }
  }

  /** The district's website without the scheme, for saying out loud. */
  function siteHost() {
    const u = (PACK.district && PACK.district.url) || '';
    return u.replace(/^https?:\/\//, '').replace(/\/+$/, '');
  }

  /**
   * Whether this district's pages have been read. Only the bundled district
   * has them; for the others the app has the calendar and the closings but
   * no policies, bell times or office numbers, and should say so plainly
   * rather than letting a parent wonder why it keeps drawing a blank.
   */
  function hasPages() {
    return !!(PACK.facts && PACK.facts.length);
  }

  // ---------------------------------------------------------------- welcome

  /**
   * Shown once, to someone who has not said whose schools they care about.
   * "Skip for now" is there deliberately: nobody should be made to fill in a
   * form before they can look at anything.
   */
  function showWelcomeStep(which) {
    const d = el('welcome-district'), s = el('welcome-schools');
    if (!d || !s) return;
    d.hidden = which !== 'district';
    s.hidden = which !== 'schools';
    if (which === 'schools') {
      buildPicker(el('welcome-picker'), 'wel-', null);
      syncPickers();
    } else {
      renderBranding();
      renderDistrictResults();
      const box = el('district-search');
      if (box) setTimeout(() => { try { box.focus(); } catch (e) { /* ignore */ } }, 50);
    }
  }

  function showWelcome(step) {
    const w = el('welcome');
    if (!w) return;
    w.hidden = false;
    el('thread').hidden = true;
    el('composer').hidden = true;
    showWelcomeStep(step || (DISTRICTS.length > 1 ? 'district' : 'schools'));
  }

  function closeWelcome() {
    const w = el('welcome');
    if (w) w.hidden = true;
    el('thread').hidden = false;
    el('composer').hidden = false;
    try { localStorage.setItem('welcomed', '1'); } catch (e) { /* ignore */ }
    renderChips();
    applySchool();
    renderSettings();
    checkAlerts();
  }

  el('welcome-done').addEventListener('click', closeWelcome);
  el('welcome-skip').addEventListener('click', closeWelcome);

  const backBtn = el('welcome-back');
  if (backBtn) backBtn.addEventListener('click', () => showWelcomeStep('district'));

  const dsearch = el('district-search');
  if (dsearch) {
    let t = null;
    dsearch.addEventListener('input', () => {
      clearTimeout(t);
      t = setTimeout(renderDistrictResults, 90);
    });
  }

  const changeBtn = el('change-district');
  if (changeBtn) {
    changeBtn.addEventListener('click', () => {
      const sheet = el('sheet');
      if (sheet && sheet.open) sheet.close();
      showWelcome('district');
    });
  }

  // Restoring a district chosen on an earlier visit. Everything below runs
  // whether or not that works, so a district whose feed is briefly down
  // leaves the app usable rather than blank.
  (async function boot() {
    const saved = savedDistrictOrgId();
    if (saved !== bundledOrgId) {
      try { await useDistrict(saved); } catch (e) { /* fall back to the bundled one */ }
    }

    renderChips();
    renderBranding();
    applySchool();
    renderSettings();
    checkAlerts();

    if (!schoolIds.length && store.get('welcomed', '') !== '1') {
      showWelcome();
      return;
    }

    // Holding the app's icon on a phone offers "Is there school tomorrow?"
    // and "Next day off" - the two things worth a shortcut, because they are
    // what you want at the moment you are deciding whether to set an alarm.
    // Each opens the app with the question already asked.
    try {
      const q = new URLSearchParams(location.search).get('ask');
      if (q && q.trim()) {
        history.replaceState(null, '', location.pathname);   // don't re-ask on reload
        ask(q.trim());
      }
    } catch (e) { /* a shortcut that does not fire is not worth an error */ }
  })();

  if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
    navigator.serviceWorker.register('sw.js').catch(() => { /* offline is a bonus, not a requirement */ });

    // An update takes effect on the NEXT open, because this page already
    // loaded the old files before the new ones finished saving. For an app
    // whose job is to be right at 6:45am that is one open too many: a fix
    // published tonight should not still be wrong tomorrow morning.
    //
    // So when the new version takes over, reload - but only while nothing
    // has been asked yet. Yanking the page out from under someone reading
    // an answer would be worse than showing them yesterday's build.
    // Only on an update, never on a first visit: on a first visit there is
    // no controller yet, the page already has the newest files, and
    // reloading would just be a flicker for nothing.
    const hadController = !!navigator.serviceWorker.controller;
    let reloading = false;
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      if (reloading || asked || !hadController) return;
      reloading = true;
      location.reload();
    });
  }
})();
