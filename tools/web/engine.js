/*
 * engine.js — the school answer engine, JavaScript port.
 *
 * Port of engine/Answer-Query.ps1 and engine/Alerts.ps1. The PowerShell is the
 * oracle; tests/questions.jsonl and tests/alerts.jsonl are the contract, and
 * web/tests.html replays both files in the browser. Unlike the Swift port,
 * this one is verified in a real JS runtime before shipping.
 *
 * No framework, no build step, no dependencies.
 *
 * DATES: every date is an "anchor" — a Date pinned to 12:00 UTC on the day in
 * question. Arithmetic uses the UTC accessors, so adding a day is always a
 * day, regardless of the viewer's time zone or a DST boundary. The district's
 * own time zone is used only to decide which day "today" is.
 */

(function (global) {
  'use strict';

  // ---------------------------------------------------------------- dates

  function anchor(y, m, d) {           // m is 1-based
    return new Date(Date.UTC(y, m - 1, d, 12, 0, 0));
  }

  function isoOf(dt) {
    const y = dt.getUTCFullYear();
    const m = String(dt.getUTCMonth() + 1).padStart(2, '0');
    const d = String(dt.getUTCDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  }

  function fromISO(s) {
    if (typeof s !== 'string') return null;
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s.trim());
    if (!m) return null;
    return anchor(+m[1], +m[2], +m[3]);
  }

  function addDays(dt, n) {
    const out = new Date(dt.getTime());
    out.setUTCDate(out.getUTCDate() + n);
    return out;
  }

  function addMonths(dt, n) {
    const out = new Date(dt.getTime());
    out.setUTCMonth(out.getUTCMonth() + n);
    return out;
  }

  function dayDiff(a, b) {
    return Math.round((b.getTime() - a.getTime()) / 86400000);
  }

  function weekday(dt) { return dt.getUTCDay(); }   // 0 = Sunday

  /** Monday-based week start, matching the PowerShell oracle. */
  function weekStart(dt) {
    const dow = weekday(dt);
    return addDays(dt, -(dow === 0 ? 6 : dow - 1));
  }

  /** Today in the district's own time zone, as an anchor. */
  function todayIn(timeZone) {
    try {
      const parts = new Intl.DateTimeFormat('en-CA', {
        timeZone: timeZone || 'America/New_York',
        year: 'numeric', month: '2-digit', day: '2-digit'
      }).formatToParts(new Date());
      const get = (t) => +parts.find((p) => p.type === t).value;
      return anchor(get('year'), get('month'), get('day'));
    } catch (e) {
      const n = new Date();
      return anchor(n.getFullYear(), n.getMonth() + 1, n.getDate());
    }
  }

  const FMT_CACHE = {};
  function fmtDate(dt, opts) {
    const key = JSON.stringify(opts);
    if (!FMT_CACHE[key]) {
      FMT_CACHE[key] = new Intl.DateTimeFormat('en-US', Object.assign({ timeZone: 'UTC' }, opts));
    }
    return FMT_CACHE[key].format(dt);
  }

  const dateLong  = (d) => fmtDate(d, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
  const dateShort = (d) => fmtDate(d, { weekday: 'short', month: 'short', day: 'numeric' });
  const weekdayName = (d) => fmtDate(d, { weekday: 'long' });

  function dateRange(s, e) {
    if (isoOf(s) === isoOf(e)) return dateLong(s);
    const sy = s.getUTCFullYear(), ey = e.getUTCFullYear();
    if (sy === ey && s.getUTCMonth() === e.getUTCMonth()) {
      return `${fmtDate(s, { month: 'long' })} ${s.getUTCDate()}-${e.getUTCDate()}, ${sy}`;
    }
    if (sy === ey) {
      return `${fmtDate(s, { month: 'long', day: 'numeric' })} - ${fmtDate(e, { month: 'long', day: 'numeric' })}, ${sy}`;
    }
    return `${fmtDate(s, { month: 'long', day: 'numeric', year: 'numeric' })} - ${fmtDate(e, { month: 'long', day: 'numeric', year: 'numeric' })}`;
  }

  function time12(hhmm) {
    const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm || '');
    if (!m) return hhmm || '';
    let h = +m[1];
    const ap = h >= 12 ? 'PM' : 'AM';
    h = h % 12 || 12;
    return `${h}:${m[2]} ${ap}`;
  }

  // ---------------------------------------------------------------- text

  function normalize(q) {
    if (!q) return '';
    let s = String(q).toLowerCase();
    s = s.replace(/[‘’ʼ]/g, "'").replace(/[“”]/g, '"');
    s = s.replace(/&/g, ' and ');
    s = s.replace(/[^a-z0-9/:'\-. ]/g, ' ');
    return s.replace(/\s+/g, ' ').trim();
  }

  function tokens(s) {
    return (s || '').split(/[^a-z0-9]+/i).filter(Boolean);
  }

  function escapeRe(s) {
    return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  /** Whole-word phrase containment, so "sun" does not match "sunday". */
  function containsPhrase(hay, needle) {
    if (!needle) return false;
    const pat = '(?:^|[^a-z0-9])' + escapeRe(needle).replace(/\\ /g, '\\s+') + '(?:[^a-z0-9]|$)';
    return new RegExp(pat).test(hay);
  }

  function matches(s, pattern) {
    try { return new RegExp(pattern).test(s); } catch (e) { return false; }
  }

  function capture(s, pattern) {
    try {
      const m = new RegExp(pattern).exec(s);
      return m || null;
    } catch (e) { return null; }
  }

  function terminated(s) {
    const t = String(s || '').trim();
    if (!t) return '';
    return /[.!?]$/.test(t) ? t : t + '.';
  }

  function htmlToText(html) {
    if (!html) return '';
    let t = String(html);
    t = t.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, ' ');
    t = t.replace(/<br\s*\/?>/gi, '\n');
    t = t.replace(/<\/(p|div|li|tr|h[1-6])>/gi, '\n');
    t = t.replace(/<[^>]+>/g, ' ');
    const ents = {
      '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'",
      '&apos;': "'", '&nbsp;': ' ', '&rsquo;': '’', '&lsquo;': '‘',
      '&ldquo;': '“', '&rdquo;': '”', '&ndash;': '–',
      '&mdash;': '—', '&hellip;': '…'
    };
    t = t.replace(/&[a-z#0-9]+;/gi, (e) => (e in ents ? ents[e] : e));
    t = t.replace(/[ ​]/g, ' ');
    t = t.replace(/[ \t]+/g, ' ');
    t = t.replace(/^[ \t]+|[ \t]+$/gm, '');
    t = t.replace(/(\r?\n){2,}/g, '\n');
    return t.trim();
  }

  // ================================================================ engine

  function AnswerEngine(pack, rules) {
    this.pack = pack || {};
    this.rules = rules || {};
    const d = this.pack.district || {};
    this.tz = d.timeZone || 'America/New_York';

    // Where an answer says it came from. These used to be four constants
    // pointing at Edison. They come from the information file now, so the
    // same engine answers for any district that runs the same website
    // software - which is several thousand of them.
    const site = String(d.url || '').replace(/\/+$/, '');
    const page = (p, fallback) => (d.pages && d.pages[p]) || (site ? site + fallback : '');
    this.urls = {
      site: site,
      calendar: page('calendar', '/page/district-yearly-calendar/'),
      events: page('events', '/events/'),
      hours: page('hours', '/page/school-hours/'),
      feed: page('feed', '/live-feed/')
    };
    // What to call the district when an answer names it.
    this.districtName = d.name || 'the district';
    this.districtShort = d.shortName || shortenDistrict(d.name) || 'the district';
    this.allSchoolsLabel = this.districtShort === 'the district'
      ? 'schools in the district'
      : this.districtShort + ' schools';

    // Names for the groupings a district uses beyond elementary/middle/high -
    // a preschool, an academy, a career centre. Its own, from its own file.
    this.levelLabels = d.levelLabels || {};

    // The district's own name is noise when searching its pages - every page
    // says it. Which words those are depends on the district, so the list is
    // built per district rather than written down.
    this.stop = new Set(STOP);
    for (const w of String(d.name || '').toLowerCase().split(/[^a-z0-9]+/)) {
      if (w.length > 2) this.stop.add(w);
    }

    // Whether this district publishes its school-day calendar at all.
    //
    // Plenty do not. They publish events - board meetings, job fairs,
    // graduations - and keep term dates in a PDF elsewhere. Conroe ISD is
    // one: 66 entries and not a closing, break or early dismissal among
    // them. A sample of twelve districts suggested about half are like this.
    //
    // It matters because without it every weekday looks like a normal school
    // day, and "is there school tomorrow" is answered "yes, open" purely
    // because the date is a Tuesday. That is a guess dressed as a fact, and
    // the day it is wrong is a holiday.
    this.publishesSchoolSchedule = (this.pack.calendar || [])
      .some((e) => SCHEDULE_KINDS.indexOf(e.kind) >= 0);
  }

  /**
   * "Edison Township Public Schools" -> "Edison". "Conroe ISD" -> "Conroe".
   * Districts name themselves in half a dozen house styles; what a parent
   * calls theirs is almost always the first distinctive word or two.
   */
  function shortenDistrict(name) {
    if (!name) return '';
    let s = String(name)
      .replace(/\b(independent|unified|consolidated|community|county|township|city|area|regional|local|joint|union|central|public|charter)\b/gi, ' ')
      .replace(/\b(school district|schools district|school system|schools|school|district|isd|usd|cusd|cisd|sd|psd|cs|academy|academies|corporation|corp)\b/gi, ' ')
      .replace(/\s+/g, ' ')
      .trim();
    // Everything was a qualifier (e.g. "Central School District"): keep the
    // original rather than returning nothing.
    if (!s) s = String(name).replace(/\s+/g, ' ').trim();
    const words = s.split(' ').filter(Boolean);
    return words.slice(0, 2).join(' ');
  }

  AnswerEngine.prototype.today = function () { return todayIn(this.tz); };

  // ---------------------------------------------------------------- slots

  AnswerEngine.prototype.resolveMonthDay = function (month, day, year, today) {
    if (!(month >= 1 && month <= 12) || !(day >= 1 && day <= 31)) return null;
    if (year) {
      const d = anchor(year, month, day);
      if (d.getUTCMonth() + 1 !== month || d.getUTCDate() !== day) return null;
      return d;
    }
    // No year: future readings are cheap, past ones cost triple, so in
    // November "march 10" means next March.
    const base = today.getUTCFullYear();
    let best = null, bestScore = Infinity;
    [base - 1, base, base + 1].forEach((y) => {
      const cand = anchor(y, month, day);
      if (cand.getUTCMonth() + 1 !== month || cand.getUTCDate() !== day) return;
      const delta = dayDiff(today, cand);
      const score = delta >= -3 ? Math.abs(delta) : Math.abs(delta) * 3;
      if (score < bestScore) { bestScore = score; best = cand; }
    });
    return best;
  };

  AnswerEngine.prototype.nextWeekday = function (from, target, strictlyAfter) {
    const start = strictlyAfter ? addDays(from, 1) : from;
    for (let i = 0; i < 8; i++) {
      const d = addDays(start, i);
      if (weekday(d) === target) return d;
    }
    return from;
  };

  AnswerEngine.prototype.resolveDate = function (norm, today) {
    const R = this.rules;

    // 1. week / month ranges
    if (containsPhrase(norm, 'next week')) {
      const s = addDays(weekStart(today), 7);
      return { start: s, end: addDays(s, 6), isRange: true, phrase: 'next week' };
    }
    if (containsPhrase(norm, 'this week')) {
      const s = weekStart(today);
      return { start: s, end: addDays(s, 6), isRange: true, phrase: 'this week' };
    }
    if (containsPhrase(norm, 'next month')) {
      const s = addMonths(anchor(today.getUTCFullYear(), today.getUTCMonth() + 1, 1), 1);
      return { start: s, end: addDays(addMonths(s, 1), -1), isRange: true, phrase: 'next month' };
    }
    if (containsPhrase(norm, 'this month')) {
      const s = anchor(today.getUTCFullYear(), today.getUTCMonth() + 1, 1);
      return { start: s, end: addDays(addMonths(s, 1), -1), isRange: true, phrase: 'this month' };
    }

    // 2. relative day words, longest first so "day after tomorrow" wins
    const dw = R.dateWords || {};
    const dwKeys = Object.keys(dw).sort((a, b) => b.length - a.length);
    for (const k of dwKeys) {
      if (containsPhrase(norm, k)) {
        const d = addDays(today, dw[k].offsetDays | 0);
        return { start: d, end: d, isRange: false, phrase: k };
      }
    }

    // 3. month + day, either order
    const months = R.months || {};
    const monthNames = Object.keys(months).sort((a, b) => b.length - a.length);
    const alt = monthNames.map(escapeRe).join('|');

    let g = capture(norm, `(?:^|[^a-z])(${alt})\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:\\s*,?\\s*(\\d{4}))?(?![0-9])`);
    if (g) {
      const d = this.resolveMonthDay(months[g[1]], +g[2], g[3] ? +g[3] : 0, today);
      if (d) return { start: d, end: d, isRange: false, phrase: `${g[1]} ${g[2]}` };
    }
    g = capture(norm, `(?:^|[^0-9])(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?(${alt})\\.?(?:\\s*,?\\s*(\\d{4}))?(?![0-9])`);
    if (g) {
      const d = this.resolveMonthDay(months[g[2]], +g[1], g[3] ? +g[3] : 0, today);
      if (d) return { start: d, end: d, isRange: false, phrase: `${g[1]} ${g[2]}` };
    }

    // 4. bare month name = that whole month. Before the numeric form, matching
    //    the order in Answer-Query.ps1.
    for (const n of monthNames) {
      if (!containsPhrase(norm, n)) continue;
      const mo = months[n];
      let yr = today.getUTCFullYear();
      if (mo < today.getUTCMonth() + 1 - 6) yr++;
      const s = anchor(yr, mo, 1);
      return { start: s, end: addDays(addMonths(s, 1), -1), isRange: true, phrase: n };
    }

    // 5. numeric M/D, M/D/YY
    g = capture(norm, '(?:^|[^0-9])(\\d{1,2})[/\\-](\\d{1,2})(?:[/\\-](\\d{2,4}))?(?![0-9])');
    if (g) {
      let yr = 0;
      if (g[3]) { yr = +g[3]; if (yr < 100) yr += 2000; }
      const d = this.resolveMonthDay(+g[1], +g[2], yr, today);
      if (d) return { start: d, end: d, isRange: false, phrase: `${g[1]}/${g[2]}` };
    }

    // 5b. named holidays. The calendar wins where it names the day itself, so
    //     "thanksgiving" lands on Thanksgiving Recess, not a bare date.
    const hol = R.holidays || {};
    for (const n of Object.keys(hol).sort((a, b) => b.length - a.length)) {
      if (!containsPhrase(norm, n)) continue;
      const md = hol[n];
      if (!md || md.length < 2) continue;
      const d = this.resolveMonthDay(+md[0], +md[1], 0, today);
      if (d) return { start: d, end: d, isRange: false, phrase: n };
    }

    // 6. weekday names
    const wd = R.weekdays || {};
    const wdKeys = Object.keys(wd).sort((a, b) => b.length - a.length);
    for (const n of wdKeys) {
      if (!containsPhrase(norm, n)) continue;
      const isNext = matches(norm, `(?:^|[^a-z])next\\s+${escapeRe(n)}`);
      const d = this.nextWeekday(today, wd[n], isNext);
      return { start: d, end: d, isRange: false, phrase: isNext ? `next ${n}` : n };
    }

    return null;
  };

  AnswerEngine.prototype.resolveSchool = function (norm) {
    let best = null, bestLen = 0;
    for (const s of (this.pack.schools || [])) {
      const terms = [s.name, s.shortName].concat(s.aliases || []);
      for (let t of terms) {
        t = String(t || '').toLowerCase().trim();
        if (t.length < 2 || t.length <= bestLen) continue;
        if (containsPhrase(norm, t)) { best = s; bestLen = t.length; }
      }
    }
    return best;
  };

  /**
   * Like containsPhrase, but lets the last word be plural. "How many late
   * starts this year" was finding no schedule kind at all, because the list
   * holds "late start" and the whole-word match stopped at the "s". Listing
   * every plural by hand is the treadmill; allowing one is not.
   */
  function containsPhrasePlural(hay, needle) {
    if (!needle) return false;
    const pat = '(?:^|[^a-z0-9])' + escapeRe(needle).replace(/\\ /g, '\\s+') +
                '(?:es|s)?(?:[^a-z0-9]|$)';
    return new RegExp(pat).test(hay);
  }

  /**
   * Squash repeated letters: "dissmisal" and "dismissal" both become
   * "dismisal". Doubled or dropped double letters are far and away the
   * commonest typo in these particular words, and a parent typing
   * "dissmisal" means exactly what a parent typing "dismissal" means.
   *
   * Only ever used as a last resort, and only on words of six letters or
   * more, because on short words it destroys meaning: "off" would squash to
   * "of", and a day off is not a day of.
   */
  function squashDoubles(s) {
    return String(s).replace(/([a-z])\1+/g, '$1');
  }

  function longestMapMatch(norm, map) {
    let best = null, bestLen = 0;
    for (const key of Object.keys(map || {})) {
      for (const w of (map[key] || [])) {
        if (String(w).length > bestLen && containsPhrasePlural(norm, String(w))) {
          best = key; bestLen = String(w).length;
        }
      }
    }
    if (best) return best;

    const squashed = squashDoubles(norm);
    for (const key of Object.keys(map || {})) {
      for (const w of (map[key] || [])) {
        const t = String(w);
        if (t.replace(/[^a-z]/g, '').length < 6) continue;
        if (t.length > bestLen && containsPhrasePlural(squashed, squashDoubles(t))) {
          best = key; bestLen = t.length;
        }
      }
    }
    return best;
  }

  AnswerEngine.prototype.resolveLevel = function (n) { return longestMapMatch(n, this.rules.levelWords); };
  AnswerEngine.prototype.resolveScheduleKind = function (n) { return longestMapMatch(n, this.rules.scheduleWords); };
  AnswerEngine.prototype.resolveBreak = function (n) { return longestMapMatch(n, this.rules.breaks); };

  // ---------------------------------------------------------------- intents

  AnswerEngine.prototype.intentScores = function (norm) {
    const toks = new Set(tokens(norm));
    const out = [];
    for (const intent of (this.rules.intents || [])) {
      // requireAny is a hard gate for intents whose patterns must be broad.
      const req = intent.requireAny || [];
      if (req.length && !req.some((r) => containsPhrase(norm, r))) {
        out.push({ id: intent.id, resolver: intent.resolver, priority: intent.priority, score: 0 });
        continue;
      }
      let score = 0;
      const kw = intent.keywords || {};
      for (const k of Object.keys(kw)) {
        if (k.indexOf(' ') >= 0) { if (containsPhrase(norm, k)) score += kw[k]; }
        else if (toks.has(k)) score += kw[k];
      }
      for (const p of (intent.patterns || [])) if (matches(norm, p)) score += 8;
      out.push({ id: intent.id, resolver: intent.resolver, priority: intent.priority, score: score });
    }
    out.sort((a, b) => (b.score - a.score) || (b.priority - a.priority));
    return out;
  };

  // ---------------------------------------------------------------- calendar

  AnswerEngine.prototype.entriesOn = function (dt, school) {
    const key = isoOf(dt);
    const sid = school ? school.id : null;
    return (this.pack.calendar || []).filter((e) => {
      const s = e.date, en = e.endDate || e.date;
      if (!(key >= s && key <= en)) return false;
      if (e.scope === 'district') return true;
      if (!sid) return false;
      return (e.schoolIds || []).indexOf(sid) >= 0;
    });
  };

  /**
   * The most recently posted live alert covering this day.
   * A district alert applies to everyone; a school's own alert applies only to
   * that school — Lincoln losing heat must not close Woodbrook.
   */
  AnswerEngine.prototype.alertOn = function (dt, school) {
    const key = isoOf(dt);
    const sid = school ? school.id : null;
    const rank = { closed: 3, delayed_opening: 2, early_dismissal: 1 };
    let best = null, bestRank = 0, bestPosted = '';
    for (const a of (this.pack.alerts || [])) {
      if (a.date !== key) continue;
      if (a.schoolId && a.schoolId !== sid) continue;
      const r = rank[a.kind] || 0;
      if (!r) continue;
      const posted = a.postedAt || '';
      if (r > bestRank || (r === bestRank && posted > bestPosted)) {
        best = a; bestRank = r; bestPosted = posted;
      }
    }
    return best;
  };

  AnswerEngine.prototype.schoolYearEnd = function () {
    let max = '';
    for (const e of (this.pack.calendar || [])) {
      if (e.scope !== 'district') continue;
      const en = e.endDate || e.date;
      if (en > max) max = en;
    }
    return max;
  };

  AnswerEngine.prototype.dayInfo = function (dt, school) {
    const wd = weekday(dt);
    if (wd === 0 || wd === 6) return { kind: 'weekend', reason: '', entry: null, alert: null };

    // A live alert outranks the published calendar: a snow closing is exactly
    // the case where the calendar says "normal full day" and is wrong.
    const al = this.alertOn(dt, school);
    if (al && ['closed', 'delayed_opening', 'early_dismissal'].indexOf(al.kind) >= 0) {
      let reason = al.text || '';
      if (reason.length > 160) reason = reason.slice(0, 157) + '...';
      return { kind: al.kind, reason: reason, entry: null, alert: al };
    }

    const es = this.entriesOn(dt, school);
    const pick = (kinds) => es.find((e) => kinds.indexOf(e.kind) >= 0);

    let e = pick(['closed', 'break']);
    if (e) return { kind: 'closed', reason: e.title, entry: e, alert: null };
    e = pick(['no_school_students']);
    if (e) return { kind: 'closed', reason: e.title, entry: e, alert: null };
    e = pick(['early_dismissal', 'single_session']);
    if (e) return { kind: 'early_dismissal', reason: e.title, entry: e, alert: null };
    e = pick(['delayed_opening']);
    if (e) return { kind: 'delayed_opening', reason: e.title, entry: e, alert: null };

    const end = this.schoolYearEnd();
    if (end && isoOf(dt) > end) {
      return { kind: 'unknown', reason: 'after the published school year', entry: null, alert: null };
    }
    return { kind: 'regular', reason: '', entry: null, alert: null };
  };

  // ---------------------------------------------------------------- bells

  // Only the three levels every district has. Anything else - a preschool,
  // an academy, a career centre - is named by the district itself and comes
  // from its own information file, because no fixed list could hold them.
  const LEVEL_LABELS = {
    elementary: 'Elementary schools',
    middle: 'Middle schools',
    high: 'High schools'
  };
  const titleCase = (s) => String(s || '').replace(/[_-]+/g, ' ')
    .replace(/(^|\s)([a-z])/g, (m, a, b) => a + b.toUpperCase());
  const levelLabel = (l, labels) => (labels && labels[l]) || LEVEL_LABELS[l] || titleCase(l);

  AnswerEngine.prototype.bellLines = function (ctx, dayKind) {
    let levels;
    if (ctx.level) levels = [ctx.level];
    else if (ctx.school) levels = [ctx.school.level];
    else levels = ['elementary', 'middle', 'high'];

    const field = dayKind === 'delayed_opening' ? 'delayed'
                : dayKind === 'early_dismissal' ? 'early' : 'regular';

    const lines = [];
    for (const lvl of levels) {
      for (const b of (this.pack.bells || [])) {
        if (b.level !== lvl) continue;
        const span = b[field];
        if (!span || !span.start) continue;
        const line = `${levelLabel(lvl, this.levelLabels)}: ${time12(span.start)} to ${time12(span.end)}`;
        if (lines.indexOf(line) < 0) lines.push(line);
      }
    }
    return lines.join('\n');
  };

  // ---------------------------------------------------------------- retrieval

  // The kinds of entry that make a calendar a school calendar rather than a
  // list of events. Mirrors AnswerEngine.scheduleKinds in the iPhone app.
  const SCHEDULE_KINDS = ['closed', 'break', 'early_dismissal', 'single_session',
                          'delayed_opening', 'no_school_students', 'first_day', 'last_day'];

  const STOP = new Set(('what when where who how why is are do does did the a an my our i we you to for of in on at ' +
    'it its be can could should would will there their and or if about from me kid kids child children son daughter ' +
    'school schools district please tell').split(' '));

  AnswerEngine.prototype.factMatches = function (terms, school, requireTags, top) {
    const facts = this.pack.facts || [];
    if (!facts.length || !terms.length) return [];
    requireTags = requireTags || [];
    top = top || 3;

    if (!this._docs) {
      const df = Object.create(null);
      const docs = facts.map((f) => {
        const title = (f.title || '').toLowerCase();
        const tags = (f.tags || []).join(' ').toLowerCase();
        const bag = Object.create(null);
        for (const t of tokens(`${title} ${(f.text || '').toLowerCase()} ${tags}`)) {
          bag[t] = (bag[t] || 0) + 1;
        }
        for (const k in bag) df[k] = (df[k] || 0) + 1;
        return { fact: f, title: title, tags: tags, bag: bag };
      });
      this._docs = docs;
      this._df = df;
    }
    const docs = this._docs, df = this._df, N = docs.length;
    const sid = school ? school.id : null;

    const scored = [];
    for (const d of docs) {
      if (requireTags.length && !requireTags.some((rt) => d.tags.indexOf(rt) >= 0)) continue;
      let score = 0;
      for (const t of terms) {
        const tf = d.bag[t] || 0;
        if (!tf) continue;
        const n = df[t] || 1;
        const idf = Math.log(1 + (N - n + 0.5) / (n + 0.5));
        score += idf * (tf / (tf + 1.5));
        if (containsPhrase(d.title, t)) score += idf * 1.2;
        if (containsPhrase(d.tags, t)) score += idf * 1.0;
      }
      if (score <= 0) continue;

      // A question about one school is answered from that school's page or a
      // district-wide one, never from a different school's. Lincoln has no
      // attendance page, and a mere score penalty let JMI's page win, handing
      // a Lincoln parent JMI's attendance email.
      const fsid = d.fact.schoolId || '';
      if (sid) {
        if (fsid === sid) score *= 2.2;
        else if (fsid) continue;
      } else if (fsid) score *= 0.7;

      // Staff pages (payroll, certification, tuition reimbursement) are in the
      // pack so the app covers everything the district publishes, but a
      // parent's question should not be answered from one unless they clearly
      // asked about it. If the query terms overlap the page's own title, the
      // penalty lifts.
      if (d.fact.audience === 'staff') {
        const deliberate = terms.some((t) => containsPhrase(d.title, t));
        if (!deliberate) score *= 0.2;
      }

      scored.push({ fact: d.fact, score: score });
    }
    scored.sort((a, b) => b.score - a.score);
    return scored.slice(0, top);
  };

  AnswerEngine.prototype.factExcerpt = function (fact, terms, maxChars) {
    maxChars = maxChars || 420;
    const lines = String(fact.text || '').split('\n').map((l) => l.trim()).filter(Boolean);
    if (!lines.length) return '';

    const scored = lines.map((line, i) => {
      const l = line.toLowerCase();
      let hits = terms.reduce((n, t) => n + (containsPhrase(l, t) ? 1 : 0), 0);
      if (/\d{3}[-.\s]\d{3}[-.\s]\d{4}/.test(l)) hits += 2;
      if (/@[a-z0-9.\-]+\.[a-z]{2,}/.test(l)) hits += 1;
      return { i: i, hits: hits, line: line };
    });

    let keep = scored.filter((s) => s.hits > 0).sort((a, b) => b.hits - a.hits).slice(0, 6);
    if (!keep.length) keep = scored.slice(0, 4);
    keep.sort((a, b) => a.i - b.i);

    let out = '';
    for (const k of keep) {
      const next = out ? out + '\n' + k.line : k.line;
      if (next.length > maxChars) break;
      out = next;
    }
    return out || lines[0];
  };

  // ---------------------------------------------------------------- answers

  function mk(text, intent, kind, sources, confidence, schoolId) {
    const seen = Object.create(null);
    const uniq = (sources || []).filter((s) => s && !seen[s] && (seen[s] = true));
    return {
      answer: text, intent: intent, kind: kind, sources: uniq,
      confidence: confidence === undefined ? 0.8 : confidence,
      schoolId: schoolId || ''
    };
  }


  /**
   * Did the question name a particular day we failed to work out?
   *
   * "Is there school on christmas eve" used to answer "yes, open on Monday
   * November 23" — the words were not understood, the date quietly fell back
   * to today, and the answer was confidently wrong about a day the district
   * is closed. Saying "I'm not sure which day you mean" is far better.
   */
  AnswerEngine.prototype.asksAboutSomeOtherDay = function (norm) {
    return (this.rules.dayHints || []).some((h) => norm.indexOf(String(h)) >= 0);
  };

  /**
   * Is the question "how many of them are there?" rather than "is it one
   * today?" — and does it span the year rather than a day?
   *
   * "How many early dismissal days are in this school year" used to score
   * highest on day_schedule (on the words "early" and "dismissal"), find no
   * date, quietly fall back to today and answer "Saturday, November 21, 2026
   * is a Saturday - no school." Confidently wrong, and about the wrong
   * question. Counting and enumerating are never about a single day.
   */
  const COUNTING_RE = /(?:^|[^a-z0-9])(how many|how much|how often|number of|count of)(?:[^a-z0-9]|$)/;
  const SPAN_RE = /(?:^|[^a-z0-9])(this (school )?year|the (school )?year|whole year|rest of the|all year|left|remaining)(?:[^a-z0-9]|$)/;
  const ENUMERATE_RE = /(?:^|[^a-z0-9])(list|every|all the|all of the)(?:[^a-z0-9]|$)/;

  AnswerEngine.prototype.asksForCount = function (norm) {
    return COUNTING_RE.test(norm);
  };

  AnswerEngine.prototype.asksForAll = function (norm) {
    return COUNTING_RE.test(norm) || ENUMERATE_RE.test(norm) || SPAN_RE.test(norm);
  };

  // Resolvers that answer about one day. Any of these reached by a counting
  // question is a routing mistake.
  const ONE_DAY_RESOLVERS = ['school_status', 'day_schedule', 'bell_times', 'fact_search'];
  const MULTI_DAY_SUBJECT =
    /(?:^|[^a-z0-9])(days? off|holidays?|closings?|closures?|no school|half days?|early dismissals?|single sessions?|late starts?|delayed openings?|snow days?)(?:[^a-z0-9]|$)/;

  /**
   * What to say when the district simply has not published the thing being
   * asked about. Naming the district makes clear it is them and not the app,
   * and the link is where the answer actually lives.
   */
  AnswerEngine.prototype.noScheduleAnswer = function (intent) {
    let t = `${this.districtShort} publishes events to its calendar but not its ` +
            'school-day schedule, so I don\'t know its closings, breaks or early dismissals.';
    if (this.urls.calendar) {
      t += '\n\nThose are usually on the district\'s own calendar page.';
    }
    return mk(t, intent, 'no_schedule', [this.urls.calendar, this.urls.site], 0.6);
  };

  AnswerEngine.prototype.rSchoolStatus = function (ctx) {
    // Without a published schedule, every weekday looks like a normal school
    // day, so this would answer "yes, open" on Thanksgiving.
    if (!this.publishesSchoolSchedule) return this.noScheduleAnswer('school_status');
    if (!ctx.date && this.asksAboutSomeOtherDay(ctx.norm)) {
      return mk('I\'m not sure which day you mean. Try naming the date — ' +
                '"is there school on December 24" — or ask about today or tomorrow.',
                'school_status', 'unclear_date', [this.urls.calendar], 0.2);
    }
    const slot = ctx.date || { start: ctx.today, end: ctx.today, isRange: false, phrase: 'today' };
    const label = ctx.school ? ctx.school.name : this.allSchoolsLabel;
    const isAre = ctx.school ? 'is' : 'are';

    if (slot.isRange) {
      const lines = [];
      for (let d = slot.start; isoOf(d) <= isoOf(slot.end); d = addDays(d, 1)) {
        const info = this.dayInfo(d, ctx.school);
        if (info.kind === 'weekend') continue;
        const desc = info.kind === 'closed' ? `closed - ${info.reason}`
          : info.kind === 'early_dismissal' ? `early dismissal - ${info.reason}`
          : info.kind === 'delayed_opening' ? `delayed opening - ${info.reason}`
          : info.kind === 'regular' ? 'normal full day' : 'no calendar entry';
        lines.push(`${dateShort(d)}: ${desc}`);
      }
      return mk(`${label} for ${slot.phrase}:\n${lines.join('\n')}`, 'school_status', 'range',
                [this.urls.events], 0.85, ctx.school ? ctx.school.id : '');
    }

    const date = slot.start;
    const info = this.dayInfo(date, ctx.school);
    const src = [];
    if (info.entry) src.push(info.entry.url);
    if (info.alert) src.push(this.urls.feed);
    src.push(this.urls.calendar);

    let note = '';
    if (info.alert) {
      const p = info.alert.postedAt ? new Date(info.alert.postedAt) : null;
      note = p && !isNaN(p) ? `\nDistrict announcement posted ${p.toLocaleString('en-US',
        { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })}.`
        : '\nFrom a district announcement.';
    }

    switch (info.kind) {
      case 'weekend':
        return mk(`${dateLong(date)} is a ${weekdayName(date)}, so there is no school.`,
                  'school_status', 'weekend', src, 0.95);
      case 'closed': {
        let t = `No - ${label} ${isAre} closed on ${dateLong(date)}.`;
        if (info.reason) t += ' Reason: ' + terminated(info.reason);
        return mk(t + note, 'school_status', 'closed', src, 0.95);
      }
      case 'early_dismissal': {
        let t = `Yes - ${label} ${isAre} open on ${dateLong(date)}, but it is an early dismissal day (${info.reason}).`;
        const bl = this.bellLines(ctx, 'early_dismissal');
        if (bl) t += '\n' + bl;
        return mk(t + note, 'school_status', 'early_dismissal', src, 0.9);
      }
      case 'delayed_opening': {
        let t = `Yes - ${label} ${isAre} open on ${dateLong(date)}, on a delayed opening (${info.reason}).`;
        const bl = this.bellLines(ctx, 'delayed_opening');
        if (bl) t += '\n' + bl;
        return mk(t + note, 'school_status', 'delayed_opening', src, 0.9);
      }
      case 'regular':
        return mk(`Yes - ${label} ${isAre} open on ${dateLong(date)}, a normal full day.`,
                  'school_status', 'open', src, 0.85);
      default:
        return mk(`I don't have a calendar entry for ${dateLong(date)} (${info.reason}). Check the district calendar to be sure.`,
                  'school_status', 'unknown', src, 0.4);
    }
  };

  AnswerEngine.prototype.rDaySchedule = function (ctx) {
    if (!this.publishesSchoolSchedule) return this.noScheduleAnswer('day_schedule');
    const asked = ctx.scheduleKind;
    const slot = ctx.date || { start: ctx.today, end: ctx.today, isRange: false, phrase: 'today' };

    if (slot.isRange) {
      const hits = [];
      for (let d = slot.start; isoOf(d) <= isoOf(slot.end); d = addDays(d, 1)) {
        const info = this.dayInfo(d, ctx.school);
        if (asked && info.kind === asked) hits.push(`${dateShort(d)} - ${info.reason}`);
        else if (!asked && ['early_dismissal', 'delayed_opening', 'closed'].indexOf(info.kind) >= 0) {
          hits.push(`${dateShort(d)} - ${info.kind}: ${info.reason}`);
        }
      }
      if (!hits.length) {
        const what = asked ? asked.replace(/_/g, ' ') : 'schedule change';
        return mk(`No ${what} is listed for ${slot.phrase}.`, 'day_schedule', 'none', [this.urls.events], 0.85);
      }
      return mk(`For ${slot.phrase}:\n${hits.join('\n')}`, 'day_schedule', 'range', [this.urls.events], 0.9);
    }

    const date = slot.start;
    const info = this.dayInfo(date, ctx.school);
    const src = [];
    if (info.entry) src.push(info.entry.url);
    src.push(this.urls.hours);

    if (info.kind === 'weekend') {
      return mk(`${dateLong(date)} is a ${weekdayName(date)} - no school.`, 'day_schedule', 'weekend', src, 0.95);
    }
    if (info.kind === 'closed') {
      const why = info.reason ? ` (${info.reason})` : '';
      return mk(`Schools are closed on ${dateLong(date)}${why}, so there is no dismissal.`,
                'day_schedule', 'closed', src, 0.92);
    }

    // The district runs "Single Session Day" and "Early Dismissal" on the same
    // shortened schedule, and dayInfo folds both into early_dismissal.
    let effective = asked || 'early_dismissal';
    if (effective === 'single_session') effective = 'early_dismissal';
    const what = effective.replace(/_/g, ' ');
    const article = 'aeiou'.indexOf(what[0]) >= 0 ? 'an' : 'a';

    if (info.kind === effective) {
      let t = `Yes - ${dateLong(date)} is ${article} ${what} (${info.reason}).`;
      const bl = this.bellLines(ctx, effective);
      if (bl) t += '\n' + bl;
      return mk(t, 'day_schedule', effective, src, 0.92);
    }

    let t = `No - ${dateLong(date)} is not ${article} ${what}.`;
    if (info.kind === 'regular') {
      t += ' It is a normal full day.';
      const bl = this.bellLines(ctx, 'regular');
      if (bl) t += '\n' + bl;
    } else if (info.kind === 'early_dismissal' || info.kind === 'delayed_opening') {
      t += ` It is listed as ${info.kind.replace(/_/g, ' ')} (${info.reason}).`;
    }
    return mk(t, 'day_schedule', 'no', src, 0.88);
  };

  AnswerEngine.prototype.rBellTimes = function (ctx) {
    const date = (ctx.date && !ctx.date.isRange) ? ctx.date.start : null;
    let dayKind = 'regular', reason = '';

    if (!date && ctx.scheduleKind) {
      if (ctx.scheduleKind === 'delayed_opening') dayKind = 'delayed_opening';
      else if (ctx.scheduleKind === 'early_dismissal' || ctx.scheduleKind === 'single_session') dayKind = 'early_dismissal';
    }

    if (date) {
      const info = this.dayInfo(date, ctx.school);
      if (info.kind === 'weekend') {
        return mk(`${dateLong(date)} is a ${weekdayName(date)} - no school.`, 'bell_times', 'weekend', [this.urls.hours], 0.95);
      }
      if (info.kind === 'closed') {
        const why = info.reason ? ` (${info.reason})` : '';
        return mk(`Schools are closed on ${dateLong(date)}${why}.`, 'bell_times', 'closed', [this.urls.calendar], 0.92);
      }
      if (info.kind === 'early_dismissal' || info.kind === 'delayed_opening') {
        dayKind = info.kind; reason = info.reason;
      }
    }

    const bl = this.bellLines(ctx, dayKind);
    if (!bl) return mk("I don't have published hours for that.", 'bell_times', 'none', [], 0.3);

    let head;
    if (date) {
      head = dayKind === 'regular' ? `Hours for ${dateLong(date)}:`
        : `${dateLong(date)} is ${dayKind.replace(/_/g, ' ')} (${reason}). Hours:`;
    } else if (dayKind === 'delayed_opening') head = 'Delayed opening hours:';
    else if (dayKind === 'early_dismissal') head = 'Early dismissal / single session hours:';
    else head = 'Regular school hours:';

    let t = `${head}\n${bl}`;
    if (dayKind === 'regular' && !date) {
      t += '\nDelayed opening starts 2 hours later; early dismissal/single session ends early.';
    }
    return mk(t, 'bell_times', dayKind, [this.urls.hours], 0.9, ctx.school ? ctx.school.id : '');
  };

  AnswerEngine.prototype.rNextOccurrence = function (ctx) {
    const k = ctx.scheduleKind;
    const wanted = k === 'early_dismissal' ? ['early_dismissal', 'single_session']
      : k === 'single_session' ? ['single_session']
      : k === 'delayed_opening' ? ['delayed_opening']
      : k === 'closed' ? ['closed', 'break']
      : ['closed', 'break', 'early_dismissal', 'single_session', 'delayed_opening'];

    const sid = ctx.school ? ctx.school.id : null;
    const todayKey = isoOf(ctx.today);
    let best = null;
    for (const e of (this.pack.calendar || [])) {
      if (wanted.indexOf(e.kind) < 0) continue;
      if (e.scope !== 'district') {
        if (!sid || (e.schoolIds || []).indexOf(sid) < 0) continue;
      }
      if (e.date < todayKey) continue;
      if (!best || e.date < best.date) best = e;
    }

    if (!best) {
      const what = k ? k.replace(/_/g, ' ') : 'schedule change';
      return mk(`Nothing further is published for a ${what} this school year.`,
                'next_occurrence', 'none', [this.urls.events], 0.6);
    }

    const s = fromISO(best.date), e2 = fromISO(best.endDate) || s;
    const days = dayDiff(ctx.today, s);
    const when = days === 0 ? 'today' : days === 1 ? 'tomorrow' : `in ${days} days`;
    let t = `The next one is ${dateRange(s, e2)} - ${best.title} (${when}).`;
    if (['early_dismissal', 'single_session', 'delayed_opening'].indexOf(best.kind) >= 0) {
      const bl = this.bellLines(ctx, best.kind === 'delayed_opening' ? 'delayed_opening' : 'early_dismissal');
      if (bl) t += '\n' + bl;
    }
    return mk(t, 'next_occurrence', best.kind, [best.url], 0.9);
  };

  AnswerEngine.prototype.rBreakDates = function (ctx) {
    let brk = ctx.break_;
    if (!brk) {
      if (matches(ctx.norm, 'last day')) brk = 'summer break';
      else if (matches(ctx.norm, 'first day|when does school start|when does school begin')) brk = '__first__';
    }

    let cands;
    if (brk === '__first__') {
      cands = (this.pack.calendar || []).filter((e) => e.kind === 'first_day');
    } else {
      const syn = (brk && this.rules.breaks && this.rules.breaks[brk]) || ['recess', 'break'];
      cands = (this.pack.calendar || []).filter((e) => {
        const t = (e.title || '').toLowerCase();
        return syn.some((s) => t.indexOf(String(s).toLowerCase()) >= 0);
      });
    }

    if (!cands.length) {
      if (!this.publishesSchoolSchedule) return this.noScheduleAnswer('break_dates');
      return mk(`I couldn't find ${brk || 'that break'} on the published calendar.`,
                'break_dates', 'none', [this.urls.calendar], 0.4);
    }

    // A break closes the whole district, so the district's own entry is the
    // answer. Without this, a school's "FDR Thanksgiving Feast" or "Single
    // Session Day- Spring Break" outranks the actual recess and a parent is
    // told the wrong week.
    const districtOnly = cands.filter((e) => e.scope === 'district');
    if (districtOnly.length) cands = districtOnly;

    const todayKey = isoOf(ctx.today);
    const future = cands.filter((e) => e.date >= todayKey).sort((a, b) => a.date.localeCompare(b.date));
    const past = cands.slice().sort((a, b) => b.date.localeCompare(a.date));
    const pick = future[0] || past[0];

    const s = fromISO(pick.date), e2 = fromISO(pick.endDate) || s;
    if (!s) return mk("I couldn't read that calendar entry.", 'break_dates', 'none', [], 0.2);
    const nDays = dayDiff(s, e2) + 1;

    let t = `${pick.title}: ${dateRange(s, e2)}`;
    if (nDays > 1) t += ` (${nDays} days)`;
    t += '.';

    if (pick.date >= todayKey) {
      const away = dayDiff(ctx.today, s);
      t += away === 0 ? ' That starts today.' : away === 1 ? ' That starts tomorrow.' : ` That starts in ${away} days.`;
      let back = addDays(e2, 1);
      while (weekday(back) === 0 || weekday(back) === 6) back = addDays(back, 1);
      t += ` Students return ${dateShort(back)}.`;
    }
    return mk(t, 'break_dates', 'break', [pick.url, this.urls.calendar], 0.92);
  };

  /**
   * "List every early dismissal", "what are all the days off this year".
   *
   * Shows the whole school year rather than the next fortnight: someone
   * asking for the list is planning, not checking today. Without this,
   * "list early dismissal days" matched on the words "early dismissal" and
   * was answered as "is TODAY an early dismissal" — a flat, useless no.
   */
  AnswerEngine.prototype.rListOccurrences = function (ctx) {
    const k = ctx.scheduleKind;
    const wanted = k === 'early_dismissal' ? ['early_dismissal', 'single_session']
      : k === 'single_session' ? ['single_session']
      : k === 'delayed_opening' ? ['delayed_opening']
      : k === 'closed' ? ['closed', 'break']
      : ['closed', 'break', 'early_dismissal', 'single_session', 'delayed_opening'];
    const label = k === 'early_dismissal' ? 'Early dismissal and single session days'
      : k === 'single_session' ? 'Single session days'
      : k === 'delayed_opening' ? 'Delayed openings'
      : k === 'closed' ? 'Days schools are closed'
      : 'Days that are not a normal full day';

    const sid = ctx.school ? ctx.school.id : null;
    const todayKey = isoOf(ctx.today);

    // Schools republish the district's own dates on their calendars, so a
    // districtwide early dismissal appears once for the district and again
    // for each of your children's schools. Collapse by date and title, and
    // let the district's copy win.
    const byKey = new Map();
    for (const e of (this.pack.calendar || [])) {
      if (wanted.indexOf(e.kind) < 0) continue;
      if (e.scope !== 'district') {
        if (!sid || (e.schoolIds || []).indexOf(sid) < 0) continue;
      }
      const key = e.date + '|' + (e.title || '').toLowerCase();
      const prev = byKey.get(key);
      if (!prev || (prev.scope !== 'district' && e.scope === 'district')) byKey.set(key, e);
    }
    const rows = [...byKey.values()].sort((a, b) => a.date.localeCompare(b.date));

    if (!rows.length) {
      if (!this.publishesSchoolSchedule) return this.noScheduleAnswer('list_occurrences');
      return mk('Nothing like that is on the published calendar.',
                'list_occurrences', 'none', [this.urls.calendar], 0.5);
    }

    const upcoming = rows.filter((r) => (r.endDate || r.date) >= todayKey);
    const past = rows.length - upcoming.length;

    const lines = upcoming.map((r) => {
      const s = fromISO(r.date), e = fromISO(r.endDate) || s;
      const d = isoOf(s) === isoOf(e) ? dateShort(s) : `${dateShort(s)}-${dateShort(e)}`;
      return `${d} - ${r.title}`;
    });

    let t;
    if (ctx.counting) {
      // They asked for a number, so lead with the number — for the whole
      // year, which is what "in this school year" means, not just what is
      // left. The list that follows is the part they can still plan around.
      t = `${label}: ${rows.length} on this school year's calendar.`;
      t += upcoming.length
        ? ` ${upcoming.length} still to come:\n` + lines.join('\n')
        : ' None left.';
      if (past) t += `\n\n(${past} already passed.)`;
    } else if (!upcoming.length) {
      t = `${label}: none left this school year.`;
      if (past) t += `\n\n(${past} already passed this school year.)`;
    } else {
      t = `${label} still to come (${upcoming.length}):\n` + lines.join('\n');
      if (past) t += `\n\n(${past} already passed this school year.)`;
    }

    return mk(t, 'list_occurrences', 'list', [this.urls.calendar], 0.92, sid || '');
  };

  AnswerEngine.prototype.rCalendarList = function (ctx) {
    const slot = ctx.date || { start: ctx.today, end: addDays(ctx.today, 13), isRange: true, phrase: 'the next two weeks' };
    const sid = ctx.school ? ctx.school.id : null;
    const a = isoOf(slot.start), b = isoOf(slot.end);

    const rows = (this.pack.calendar || []).filter((e) => {
      const en = e.endDate || e.date;
      if (en < a || e.date > b) return false;
      if (e.scope !== 'district') {
        if (!sid || (e.schoolIds || []).indexOf(sid) < 0) return false;
      }
      return true;
    }).sort((x, y) => x.date.localeCompare(y.date)).slice(0, 12);

    if (!rows.length) {
      return mk(`Nothing is listed for ${slot.phrase}.`, 'calendar_list', 'none', [this.urls.events], 0.7);
    }
    const lines = rows.map((r) => {
      const s = fromISO(r.date), e = fromISO(r.endDate) || s;
      const d = isoOf(s) === isoOf(e) ? dateShort(s) : `${dateShort(s)}-${dateShort(e)}`;
      return `${d}: ${r.title}`;
    });
    return mk(`${slot.phrase}:\n${lines.join('\n')}`, 'calendar_list', 'list', [this.urls.events], 0.85);
  };

  AnswerEngine.prototype.rAbsence = function (ctx) {
    const terms = ['absent', 'absence', 'attendance', 'report', 'phone', 'call', 'secretary', 'email', 'sick'];
    let hits = this.factMatches(terms, ctx.school, ['absent', 'attendance', 'absence'], 2);

    if (ctx.school) {
      // Absence procedure is per school, so only that school's own page will
      // do. A district page that merely mentions "call" or "email" — the
      // parent help desk, say — is not an answer to "who do I call about
      // Lincoln", and neither is another school's attendance page.
      hits = hits.filter((h) => h.fact.schoolId === ctx.school.id);

      if (!hits.length) {
        const c = (this.pack.contacts || []).find((x) => x.schoolId === ctx.school.id);
        if (c && c.phone) {
          let t = `Call the ${ctx.school.name} office to report an absence: ${c.phone}.`;
          if ((c.emails || []).length) t += ` You can also email ${c.emails[0]}.`;
          t += `\n${ctx.school.shortName} does not publish a separate attendance page, so this is the main office line.`;
          return mk(t, 'absence_report', 'contact', [c.url], 0.7, ctx.school.id);
        }
      }
    } else if (!hits.length) {
      hits = this.factMatches(terms, ctx.school, [], 2);
    }

    if (!hits.length) {
      // Never a number from somewhere else. This used to fall back to a
      // literal - Edison's switchboard - which for a parent in any other
      // district is not merely useless but wrong, and wrong in a way they
      // would only discover by ringing a stranger. If this district's number
      // is not known, say so.
      const phone = (this.pack.district && this.pack.district.phone) || '';
      const t = phone
        ? `Report an absence by calling your child's school office. ${this.districtShort}'s main number is ${phone}.`
        : "Report an absence by calling your child's school office. I don't have the office numbers for this district yet - they are on the school's own page.";
      return mk(t, 'absence_report', 'fallback', [this.urls.site], 0.35);
    }
    const f = hits[0].fact;
    const excerpt = this.factExcerpt(f, terms);
    let t;
    if (ctx.school) t = `To report an absence at ${ctx.school.name}:\n${excerpt}`;
    else {
      t = `Absences are reported to your child's own school office. From ${f.title}:\n${excerpt}`;
      t += "\n\nTell me which school and I'll give you that office's number.";
    }
    return mk(t, 'absence_report', 'fact', [f.url], 0.85, ctx.school ? ctx.school.id : '');
  };

  AnswerEngine.prototype.rContact = function (ctx) {
    const d = this.pack.district || {};
    if (ctx.school) {
      const rec = (this.pack.contacts || []).find((c) => c.schoolId === ctx.school.id);
      const lines = [ctx.school.name];
      if (rec) {
        if (rec.address) lines.push(`Address: ${rec.address}`);
        if (rec.phone) lines.push(`Phone: ${rec.phone}`);
        if (rec.fax) lines.push(`Fax: ${rec.fax}`);
        const extra = (rec.phones || []).filter((p) => p !== rec.phone).slice(0, 2);
        if (extra.length) lines.push('Also: ' + extra.join(', '));
        const em = (rec.emails || []).slice(0, 2);
        if (em.length) lines.push('Email: ' + em.join(', '));
      }
      // Only lines that say something. For a district read live there is no
      // address, no phone and no school website, and printing the labels
      // with nothing after them ("Website:") reads as though the app has
      // lost the answer rather than never having had it.
      if (ctx.school.url) lines.push(`Website: ${ctx.school.url}`);
      if (lines.length > 1) {
        return mk(lines.join('\n'), 'contact_info', 'school', [ctx.school.url], 0.88, ctx.school.id);
      }
      const tail = d.phone
        ? `\n\n${this.districtShort}'s main line: ${d.phone}`
        : "\n\nI don't have the office numbers for this district - they are on the school's own page.";
      return mk(lines.join('\n') + tail,
                'contact_info', 'school_partial', [ctx.school.url], 0.6, ctx.school.id);
    }
    const lines = [d.name || this.districtName];
    if (d.phone) lines.push(`Phone: ${d.phone}`);
    if (d.address) lines.push(`Address: ${d.address}`);
    if (d.url) lines.push(`Website: ${d.url}`);
    return mk(lines.join('\n') + "\n\nFor a specific school, name it and I'll give you that office.",
              'contact_info', 'district', [d.url], 0.85);
  };

  AnswerEngine.prototype.rFactSearch = function (ctx) {
    const all = tokens(ctx.norm).filter((t) => t.length > 2);
    let terms = all.filter((t) => !this.stop.has(t));
    if (!terms.length) terms = all;
    if (!terms.length) {
      return mk('Ask me about school hours, closings, the calendar, absences, buses, meals or policies.',
                'fact_search', 'empty', [], 0.1);
    }
    const hits = this.factMatches(terms, ctx.school, [], 3);
    if (!hits.length) {
      // Two different answers, because they are two different situations.
      // "I looked and it isn't there" and "nobody has read this district's
      // pages" both end in no answer, but only one of them is the parent's
      // fault for asking oddly, and telling them to reword when there is
      // nothing to search would waste their morning.
      const where = this.urls.site || "the district's website";
      const t = (this.pack.facts && this.pack.facts.length)
        ? "I couldn't find that in the district's published pages. Try rewording, or check " + where
        : "I don't have " + this.districtShort + "'s pages - only its calendar and its closings. "
          + 'For policies, school hours and office numbers, check ' + where + '.';
      return mk(t, 'fact_search', 'none', [this.urls.site], 0.15);
    }
    const f = hits[0].fact;
    let t = `${f.title}:\n${this.factExcerpt(f, terms)}`;
    const srcs = [f.url];
    if (hits.length > 1) {
      const rest = hits.slice(1);
      t += '\n\nAlso relevant: ' + rest.map((h) => h.fact.title).join('; ') + '.';
      rest.forEach((h) => srcs.push(h.fact.url));
    }
    return mk(t, 'fact_search', 'fact', srcs, Math.min(0.8, 0.35 + 0.1 * hits[0].score));
  };

  // ---------------------------------------------------------------- entry

  /**
   * Is this question leaning on the one before it?
   * Either it opens like a follow-up ("what about Tuesday", "and Friday?"),
   * or it is too short to stand alone ("what time?", "Lincoln?").
   */
  /**
   * Does this question name a topic of its own?
   *
   * "What about Tuesday?" does not — it is pure reference, and means whatever
   * the last question meant. "What about transportation?" does, and must not
   * be answered as if it were still about school closing times.
   *
   * Anything left after removing filler, dates and school names counts.
   */
  AnswerEngine.prototype.namesOwnTopic = function (norm) {
    const dateish = new Set(
      Object.keys(this.rules.dateWords || {})
        .concat(Object.keys(this.rules.weekdays || {}))
        .concat(Object.keys(this.rules.months || {}))
        .concat(['week', 'month', 'day', 'today', 'tomorrow', 'next', 'this', 'last'])
    );
    const schoolWords = new Set();
    for (const s of (this.pack.schools || [])) {
      for (const term of [s.name, s.shortName].concat(s.aliases || [])) {
        for (const w of tokens(String(term).toLowerCase())) schoolWords.add(w);
      }
    }
    for (const w of tokens(norm)) {
      if (this.stop.has(w)) continue;
      if (dateish.has(w)) continue;
      if (schoolWords.has(w)) continue;
      if (/^\d+(st|nd|rd|th)?$/.test(w)) continue;
      return true;
    }
    return false;
  };

  function isFollowUpQuery(norm) {
    if (/^(what|how) about\b/.test(norm)) return true;
    if (/^(and|but|ok|okay|so)\b/.test(norm)) return true;
    if (/^what if\b/.test(norm)) return true;
    if (/^(then|also)\b/.test(norm)) return true;
    const words = tokens(norm);
    if (words.length <= 3 &&
        !/\b(is|are|do|does|can|when|where|who|how)\b.*\b(school|open|closed)\b/.test(norm)) {
      return true;
    }
    return false;
  }

  /**
   * @param previous  what the last question settled on, from the previous
   *                  answer's `context`. Lets "what time?" mean "what time on
   *                  the day we were just talking about".
   */
  AnswerEngine.prototype.answer = function (query, today, defaultSchoolId, previous) {
    const norm = normalize(query);
    const t = today || this.today();

    if (!norm) {
      const a = mk('Ask me anything about ' + this.allSchoolsLabel + ' - hours, closings, the calendar, absences.', 'empty', 'empty', [], 0);
      a.debug = { resolver: 'empty' };
      return a;
    }

    let school = this.resolveSchool(norm);
    if (!school && defaultSchoolId) {
      school = (this.pack.schools || []).find((s) => s.id === defaultSchoolId) || null;
    }

    const ctx = {
      query: query, norm: norm, today: t, school: school,
      level: this.resolveLevel(norm),
      date: this.resolveDate(norm, t),
      scheduleKind: this.resolveScheduleKind(norm),
      break_: this.resolveBreak(norm),
      counting: this.asksForCount(norm)
    };

    // "Is there school tomorrow?" then "what time?" is one conversation, not
    // two unrelated questions. A follow-up borrows whatever the last question
    // settled and this one leaves out.
    const followUp = isFollowUpQuery(norm);
    if (previous) {
      // "and the 27th?" means the 27th of the month we were just discussing.
      if (!ctx.date && previous.dateStart) {
        const ord = /(?:^|[^0-9])(\d{1,2})(?:st|nd|rd|th)(?![a-z0-9])/.exec(norm);
        const prev = fromISO(previous.dateStart);
        if (ord && prev) {
          const day = +ord[1];
          const cand = anchor(prev.getUTCFullYear(), prev.getUTCMonth() + 1, day);
          if (cand.getUTCDate() === day) {
            ctx.date = { start: cand, end: cand, isRange: false, phrase: ord[1] };
          }
        }
      }
      if (!ctx.date && followUp && previous.dateStart) {
        ctx.date = {
          start: fromISO(previous.dateStart),
          end: fromISO(previous.dateEnd) || fromISO(previous.dateStart),
          isRange: !!previous.dateIsRange,
          phrase: previous.datePhrase || ''
        };
      }
      if (!ctx.school && previous.schoolId) {
        ctx.school = (this.pack.schools || []).find((s) => s.id === previous.schoolId) || null;
      }
    }

    const scores = this.intentScores(norm);
    const top = scores[0];
    let resolver = (top && top.score >= 3) ? top.resolver : 'fact_search';

    // "What about Tuesday?" carries no topic of its own — it means whatever
    // the last question meant. Borrow only when this question showed no
    // intent at all: "what time?" names its own topic and should give the
    // times for the day we were discussing, not repeat the whole answer.
    if (followUp && previous && previous.resolver && !this.namesOwnTopic(norm)) {
      if (!top || top.score < 3) resolver = previous.resolver;
    }

    // Asking what the rules ARE is a different question from asking what
    // today is. "What is the snow day policy" was being answered "yes, school
    // is open today" — it matched on "school" and "snow" and had no date.
    if (!ctx.date &&
        /\b(policy|policies|procedure|protocol|rules? (for|about|on)|how does .{0,20}work)\b/.test(norm)) {
      resolver = 'fact_search';
    }

    if (ctx.break_ && !containsPhrase(norm, 'next')) resolver = 'break_dates';
    else if ((containsPhrase(norm, 'next') || containsPhrase(norm, 'upcoming')) && ctx.scheduleKind && !ctx.date) {
      resolver = 'next_occurrence';
    }

    // Counting or enumerating is the list question, however it is worded.
    // Without this, "how many early dismissal days are in this school year"
    // landed on day_schedule, found no date and answered about today. The
    // word list in the rules will always miss a phrasing; this does not,
    // because it keys off the shape of the question, not its vocabulary.
    if (ONE_DAY_RESOLVERS.indexOf(resolver) >= 0 && !ctx.date) {
      if (this.asksForAll(norm) && (ctx.scheduleKind || MULTI_DAY_SUBJECT.test(norm))) {
        resolver = 'list_occurrences';
      } else if (this.asksForCount(norm)) {
        // Counting something that is not on the calendar - "how many schools
        // are in the district", "how many students go to edison high". Still
        // not a question about today, and school_status was answering it
        // "Saturday, November 21 is a Saturday, so there is no school."
        resolver = 'fact_search';
      }
    }

    const fn = {
      school_status: this.rSchoolStatus, day_schedule: this.rDaySchedule,
      bell_times: this.rBellTimes, next_occurrence: this.rNextOccurrence,
      break_dates: this.rBreakDates, calendar_list: this.rCalendarList,
      list_occurrences: this.rListOccurrences,
      absence_report: this.rAbsence, contact_info: this.rContact
    }[resolver] || this.rFactSearch;

    const out = fn.call(this, ctx);
    out.debug = {
      resolver: resolver,
      topIntent: top ? top.id : '',
      topScore: top ? top.score : 0,
      dateSlot: ctx.date ? `${isoOf(ctx.date.start)}..${isoOf(ctx.date.end)} (${ctx.date.phrase})` : '',
      // ctx.school, not the local `school`: a follow-up can adopt the school
      // from the previous question after that local was set.
      schoolSlot: ctx.school ? ctx.school.id : '',
      levelSlot: ctx.level || '',
      scheduleSlot: ctx.scheduleKind || '',
      breakSlot: ctx.break_ || '',
      followUp: followUp
    };
    // Pass this back in as `previous` on the next question.
    out.context = {
      resolver: resolver,
      dateStart: ctx.date ? isoOf(ctx.date.start) : '',
      dateEnd: ctx.date ? isoOf(ctx.date.end) : '',
      dateIsRange: ctx.date ? !!ctx.date.isRange : false,
      datePhrase: ctx.date ? ctx.date.phrase : '',
      schoolId: ctx.school ? ctx.school.id : ''
    };
    return out;
  };

  // ================================================================ alerts

  function AlertParser(rules, timeZone) {
    this.rules = rules || {};
    this.tz = timeZone || 'America/New_York';
    this.engine = new AnswerEngine({ district: { timeZone: this.tz } }, rules);
  }

  /** Alerts in one live-feed post body. postedAt is an anchor date. */
  AlertParser.prototype.fromStatus = function (status, postedAt) {
    const cfg = this.rules.alerts;
    if (!cfg) return [];
    const text = htmlToText(status);
    if (!text) return [];

    const out = [];
    for (const raw of text.split('\n')) {
      const line = raw.trim();
      if (line.length < 8) continue;
      const low = line.toLowerCase();

      if ((cfg.reject || []).some((r) => low.indexOf(String(r).toLowerCase()) >= 0)) continue;

      let kind = '';
      for (const k of ['closed', 'delayed_opening', 'early_dismissal']) {
        const phrases = (cfg.kinds || {})[k] || [];
        if (phrases.some((p) => low.indexOf(String(p).toLowerCase()) >= 0)) { kind = k; break; }
      }
      if (!kind) continue;

      if ((cfg.subjectRequiredFor || []).indexOf(kind) >= 0) {
        if (!(cfg.subjects || []).some((s) => containsPhrase(low, String(s)))) continue;
      }

      const date = this.dateIn(line, postedAt);
      if (!date) continue;

      const lead = dayDiff(postedAt, date);
      if (lead < -1 || lead > (cfg.maxLeadDays || 7)) continue;

      out.push({ kind: kind, date: date, line: line });
    }
    return out;
  };

  AlertParser.prototype.dateIn = function (line, postedAt) {
    const low = line.toLowerCase();
    const months = this.rules.months || {};
    const names = Object.keys(months).sort((a, b) => b.length - a.length);
    const alt = names.map(escapeRe).join('|');

    // Tolerates the district's real punctuation: "Closed on Monday, January, 26."
    let g = capture(low, `(?:^|[^a-z])(${alt})\\.?\\s*,?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:\\s*,?\\s*(\\d{4}))?(?![0-9])`);
    if (g) {
      const d = this.engine.resolveMonthDay(months[g[1]], +g[2], g[3] ? +g[3] : 0, postedAt);
      if (d) return d;
    }
    g = capture(low, '(?:^|[^0-9])(\\d{1,2})[/.\\-](\\d{1,2})(?:[/.\\-](\\d{2,4}))?(?![0-9])');
    if (g) {
      let yr = 0;
      if (g[3]) { yr = +g[3]; if (yr < 100) yr += 2000; }
      const d = this.engine.resolveMonthDay(+g[1], +g[2], yr, postedAt);
      if (d) return d;
    }
    if (matches(low, '(?:^|[^a-z])tomorrow(?:[^a-z]|$)')) return addDays(postedAt, 1);
    if (matches(low, '(?:^|[^a-z])today(?:[^a-z]|$)')) return postedAt;
    return null;
  };

  /** Parses a /live_feeds response object into merged alerts. */
  AlertParser.prototype.fromFeed = function (json, schoolId) {
    schoolId = schoolId || '';
    const posts = (json && json.live_feeds) || [];
    if (!Array.isArray(posts)) return [];

    const freshDays = (this.rules.alerts && this.rules.alerts.freshDays) || 14;
    const nowAnchor = todayIn(this.tz);
    const found = [];

    for (const post of posts) {
      const raw = post.publishing_at || post.formatted_date || '';
      const d = new Date(String(raw).replace(' ', 'T'));
      if (isNaN(d)) continue;
      const postedAnchor = anchor(d.getFullYear(), d.getMonth() + 1, d.getDate());
      if (dayDiff(postedAnchor, nowAnchor) > freshDays) continue;

      for (const a of this.fromStatus(post.status || '', postedAnchor)) {
        found.push({
          id: `${post.id}-${a.kind}-${isoOf(a.date)}`,
          kind: a.kind, date: isoOf(a.date),
          postedAt: d.toISOString(), text: a.line,
          author: post.author_name || '',
          scope: schoolId ? 'school' : 'district',
          schoolId: schoolId || null
        });
      }
    }
    return AlertParser.merge(found);
  };

  /**
   * One alert per (school, kind, date), newest wording kept — then drop any
   * school alert that merely repeats a district one. Every school republishes
   * the district's closing posts, so without this a snow day appears 21 times.
   */
  AlertParser.merge = function (alerts) {
    const best = Object.create(null);
    for (const a of (alerts || [])) {
      const key = `${a.schoolId || ''}|${a.kind}|${a.date}`;
      const prev = best[key];
      if (prev && String(a.postedAt || '') <= String(prev.postedAt || '')) continue;
      best[key] = a;
    }
    const all = Object.keys(best).map((k) => best[k]);
    const districtKeys = new Set(all.filter((a) => !a.schoolId).map((a) => `${a.kind}|${a.date}`));
    return all
      .filter((a) => !a.schoolId || !districtKeys.has(`${a.kind}|${a.date}`))
      .sort((a, b) => b.date.localeCompare(a.date));
  };

  function friendlyDay(iso, tz) {
    const d = fromISO(iso);
    if (!d) return 'soon';
    const n = todayIn(tz);
    const diff = dayDiff(n, d);
    if (diff === 0) return 'today';
    if (diff === 1) return 'tomorrow';
    return 'on ' + fmtDate(d, { weekday: 'long', month: 'long', day: 'numeric' });
  }

  // ---------------------------------------------------------------- exports

  global.SchoolEngine = global.EdisonEngine = {
    AnswerEngine: AnswerEngine,
    AlertParser: AlertParser,
    friendlyDay: friendlyDay,
    levelLabel: levelLabel,
    // date helpers, exported for the UI and the tests
    anchor: anchor, isoOf: isoOf, fromISO: fromISO, addDays: addDays,
    dayDiff: dayDiff, weekStart: weekStart, todayIn: todayIn,
    dateLong: dateLong, dateShort: dateShort, time12: time12,
    normalize: normalize, htmlToText: htmlToText, containsPhrase: containsPhrase
  };
})(typeof window !== 'undefined' ? window : globalThis);
