/*
 * district.js — builds a district's information in the app itself.
 *
 * The app ships with one district collected in full: its pages, its bell
 * times, its office numbers. That collection takes an hour of crawling and
 * produces most of a megabyte, so it cannot be done for every district, and
 * certainly not in a phone.
 *
 * But the part parents ask about most — is there school, is it a half day,
 * when is the break, is it closed for snow — comes from feeds that every
 * district on this platform publishes openly, keyed only by a number. Those
 * can be read on the spot, in a few seconds, from the phone itself.
 *
 * So a district the app has never seen still answers the questions that get
 * asked at 6:45am. It just cannot answer "what is the dress code", because
 * nobody has read that district's pages. The app says so rather than
 * guessing.
 *
 * Everything here mirrors ingest/lib/Calendar.ps1, deliberately and line for
 * line where it can: the same calendar read two ways has to mean the same
 * thing, or the stored district and a live one would disagree.
 */
(function (global) {
  'use strict';

  const API = 'https://thrillshare-cmsv2.services.thrillshare.com/api/v4/o';

  // ================================================================ iCal

  /** RFC 5545 line unfolding: a line break followed by a space continues. */
  function unfold(text) {
    return String(text || '').replace(/\r?\n[ \t]/g, '');
  }

  function unescapeText(s) {
    if (!s) return '';
    return String(s)
      .replace(/\\[nN]/g, '\n')
      .replace(/\\,/g, ',')
      .replace(/\\;/g, ';')
      .replace(/\\\\/g, '\\')
      .trim();
  }

  function propRaw(body, name) {
    const m = new RegExp('^' + name + '([^:\\r\\n]*):(.*)$', 'm').exec(body);
    if (!m) return null;
    return { params: m[1], value: m[2].trim() };
  }

  function prop(body, name) {
    const r = propRaw(body, name);
    return r ? r.value : '';
  }

  /** "20261126" or "20261126T143000Z" -> {y, m, d}. Null if unparseable. */
  function parseIcsDate(v) {
    const m = /^(\d{4})(\d{2})(\d{2})/.exec(String(v || '').trim());
    if (!m) return null;
    const y = +m[1], mo = +m[2], d = +m[3];
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return { y: y, m: mo, d: d };
  }

  function iso(p) {
    return p.y + '-' + String(p.m).padStart(2, '0') + '-' + String(p.d).padStart(2, '0');
  }

  function addDaysIso(p, n) {
    const t = new Date(Date.UTC(p.y, p.m - 1, p.d + n));
    return { y: t.getUTCFullYear(), m: t.getUTCMonth() + 1, d: t.getUTCDate() };
  }

  /**
   * Parses VEVENT blocks into plain records.
   *
   * The one thing worth stating twice: for an all-day event the iCalendar
   * end date is EXCLUSIVE. A day off covering only the 26th is written
   * DTSTART 26th, DTEND 27th. Stored as-is, every break in the app would run
   * a day long. The end is converted to the last day actually covered, so a
   * one-day event has the same start and end.
   */
  function parseIcs(text) {
    const body = unfold(text);
    const out = [];
    const re = /BEGIN:VEVENT([\s\S]*?)END:VEVENT/g;
    let m;
    while ((m = re.exec(body)) !== null) {
      const b = m[1];
      const startRaw = propRaw(b, 'DTSTART');
      if (!startRaw) continue;

      const allDay = /VALUE=DATE(?!-TIME)/.test(startRaw.params) || /^\d{8}$/.test(startRaw.value);
      const start = parseIcsDate(startRaw.value);
      if (!start) continue;

      let end = start;
      const endRaw = propRaw(b, 'DTEND');
      if (endRaw && endRaw.value) {
        let e = parseIcsDate(endRaw.value);
        if (e) {
          if (allDay) {
            e = addDaysIso(e, -1);
            if (iso(e) < iso(start)) e = start;
          }
          end = e;
        }
      }

      out.push({
        uid: prop(b, 'UID'),
        summary: unescapeText(prop(b, 'SUMMARY')),
        description: unescapeText(prop(b, 'DESCRIPTION')),
        date: iso(start),
        endDate: iso(end),
        allDay: !!allDay
      });
    }
    return out;
  }

  /** The timezone the district publishes its calendar in. */
  function icsTimeZone(text) {
    const m = /TZID:([^\r\n;]+)/.exec(String(text || ''));
    return m ? m[1].trim() : '';
  }

  // ================================================== what an entry means

  const DEFAULT_KINDS = [
    { kind: 'delayed_opening', pattern: 'delayed\\s+opening|late\\s+start|delayed\\s+start|2\\s*hour\\s+delay' },
    { kind: 'early_dismissal', pattern: 'early\\s+dismissal|early\\s+release|minimum\\s+day' },
    { kind: 'single_session', pattern: 'single\\s+session' },
    { kind: 'break', pattern: '\\b(recess|break)\\b' },
    { kind: 'no_school_students', pattern: 'no\\s+school\\s+for\\s+students|students?\\s+do\\s+not\\s+report|staff\\s+(only|development|in-?service)|professional\\s+development\\s+day' },
    { kind: 'closed', pattern: 'schools?\\s+closed|school\\s+closed|closed\\b|no\\s+school' },
    { kind: 'last_day', pattern: 'last\\s+day\\s+of\\s+school' },
    { kind: 'first_day', pattern: 'first\\s+day\\s+of\\s+school|schools?\\s+open\\b' }
  ];

  /**
   * What a calendar entry means — decided from its title and nothing else.
   *
   * The description used to count too, and it cost us a real wrong answer.
   * Clarksville's theatre evening, "All The Ways the World Will End But Not
   * You", came with a description that was a slab of pasted Microsoft Word
   * markup; buried in the stylesheet was "page-break", which matched the
   * rule for a school break. The app would have told a parent their child
   * had the day off to watch a play.
   *
   * Descriptions are whatever somebody pasted in. The title is the entry.
   * Missing a closing that was only ever mentioned in the description is a
   * miss; inventing one is a parent keeping a child at home.
   */
  function eventKind(rules, summary) {
    const list = (rules && rules.eventKinds && rules.eventKinds.length) ? rules.eventKinds : DEFAULT_KINDS;
    const hay = String(summary || '').toLowerCase();
    for (const r of list) {
      try { if (new RegExp(r.pattern).test(hay)) return r.kind; } catch (e) { /* skip a bad rule */ }
    }
    return 'event';
  }

  function cleanTitle(rules, summary) {
    let s = String(summary || '');
    const pats = (rules && rules.titlePrefixes) || [];
    for (const p of pats) {
      try { s = s.replace(new RegExp(p, 'i'), ''); } catch (e) { /* skip a bad rule */ }
    }
    return s.trim();
  }

  // ================================================================ ids

  function slug(s) {
    return String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40);
  }

  /**
   * A guess at what kind of school this is, from its name alone.
   *
   * Only used for a district whose pages nobody has read. It is a guess and
   * it is treated as one: nothing that matters hangs off it, because a
   * district read this way has no bell times to attach to a level anyway.
   */
  function guessLevel(name) {
    const raw = cleanSectionName(name);
    const n = raw.toLowerCase();
    if (/pre-?k|preschool|early (learning|childhood)|kindergarten/.test(n)) return 'preschool';
    if (/\bhigh\b|senior\b/.test(n)) return 'high';
    if (/\bmiddle\b|junior|\bjr\b|intermediate/.test(n)) return 'middle';
    if (/\belementary\b|primary/.test(n)) return 'elementary';
    // Districts abbreviate their own schools and expect parents to know:
    // BHS, BMS, BES. The initial is the town; the rest is the level.
    const m = /^[A-Z]{1,4}(HS|MS|ES|JHS|JH)$/.exec(raw.replace(/[^A-Za-z]/g, ''));
    if (m) {
      if (m[1] === 'HS') return 'high';
      if (m[1] === 'MS' || m[1] === 'JHS' || m[1] === 'JH') return 'middle';
      if (m[1] === 'ES') return 'elementary';
    }
    return '';
  }

  /**
   * A district names its calendars for its own staff: "BHS Events",
   * "Lincoln Elementary Calendar". The trailing word is noise on a list of
   * schools a parent is picking from.
   */
  function cleanSectionName(name) {
    return String(name || '')
      .replace(/\s*[-–—]?\s*\b(events?|calendar|activities|athletics?)\s*$/i, '')
      .replace(/\s+/g, ' ')
      .trim() || String(name || '').trim();
  }

  /** Which section is the whole district rather than one school. */
  function isDistrictSection(name) {
    return /\b(district|districtwide|all schools|division)\b/i.test(String(name || '')) ||
           /^\s*(events|calendar|main)\s*$/i.test(String(name || ''));
  }

  // ================================================================ fetch

  async function getJson(url) {
    const r = await fetch(url, { mode: 'cors', credentials: 'omit' });
    if (!r.ok) throw new Error(url + ' returned ' + r.status);
    return r.json();
  }

  async function getText(url) {
    const r = await fetch(url, { mode: 'cors', credentials: 'omit' });
    if (!r.ok) throw new Error(url + ' returned ' + r.status);
    return r.text();
  }

  /** The district's calendar sections. One per school, plus a districtwide one. */
  async function fetchSections(orgId) {
    // page_no far past the end: the sections come back in the summary, and
    // the twenty events we would otherwise download do not.
    const j = await getJson(API + '/' + orgId + '/cms/events?page_no=9999');
    return ((j.meta && j.meta.sections) || []).map((s) => ({
      id: String(s.id), name: String(s.name || '').trim(), slug: s.slug || ''
    })).filter((s) => s.name);
  }

  // ================================================================ build

  /**
   * Builds the same shape of information file the stored district uses, so
   * the answer engine cannot tell the difference. The parts that need a
   * crawl - bell times, office numbers, page text - come back empty, and the
   * engine already says it does not know rather than inventing them.
   *
   * @param info   {orgId, name, shortName, url, timeZone} as far as known
   * @param rules  window.RULES, for what a calendar entry means
   * @param onStep optional progress callback, for a screen that says what it
   *               is doing while a parent waits
   */
  async function build(info, rules, onStep) {
    const step = onStep || function () {};
    const orgId = info.orgId;

    step('Finding the schools');
    const sections = await fetchSections(orgId);
    if (!sections.length) throw new Error('That district publishes no calendar.');

    const districtSections = sections.filter((s) => isDistrictSection(s.name));
    const schoolSections = sections.filter((s) => !isDistrictSection(s.name));

    const schools = schoolSections.map((s) => {
      const label = cleanSectionName(s.name);
      return {
        id: slug(s.name),
        name: label,
        shortName: label,
        level: guessLevel(s.name),
        aliases: [label.toLowerCase(), s.name.toLowerCase()].filter((v, i, a) => a.indexOf(v) === i),
        orgId: null,
        host: '',
        url: '',
        sectionId: s.id
      };
    });

    // One request per calendar: the district's own first, then each
    // school's. A few at a time rather than all at once - a large district
    // has a hundred schools, and a hundred simultaneous requests is both
    // rude to a service that costs nobody anything to use and liable to be
    // throttled by the phone's own browser.
    step('Reading the calendar');
    const wanted = districtSections.concat(schoolSections);
    const feeds = [];
    const AT_ONCE = 6;
    for (let i = 0; i < wanted.length; i += AT_ONCE) {
      const batch = wanted.slice(i, i + AT_ONCE);
      const got = await Promise.all(batch.map(async (s) => {
        try {
          const t = await getText(API + '/' + orgId + '/cms/events/generate_ical?section_ids=' + s.id);
          return { section: s, text: t };
        } catch (e) {
          return { section: s, text: '' };   // one school's calendar missing is not a failure
        }
      }));
      for (const g of got) feeds.push(g);
      if (wanted.length > AT_ONCE) {
        step('Reading the calendar (' + Math.min(i + AT_ONCE, wanted.length) + ' of ' + wanted.length + ')');
      }
    }

    let timeZone = info.timeZone || '';
    const parsed = [];
    for (const f of feeds) {
      if (!f.text) continue;
      if (!timeZone) timeZone = icsTimeZone(f.text);
      const districtWide = isDistrictSection(f.section.name);
      for (const ev of parseIcs(f.text)) {
        parsed.push({ ev: ev, districtWide: districtWide, section: f.section });
      }
    }

    // Some districts keep no districtwide calendar at all - every date is
    // published under each school. Without a stand-in, a parent who has not
    // picked a school yet would be told nothing is on the calendar, which is
    // false and looks broken.
    //
    // So where there is no districtwide calendar, a date that several
    // schools publish identically IS the district's: that is what a
    // districtwide closing looks like when it is written out school by
    // school. A date only one school lists stays that school's.
    const haveDistrictSection = parsed.some((p) => p.districtWide);
    const shared = new Set();
    if (!haveDistrictSection) {
      const bySection = new Map();
      for (const p of parsed) {
        const key = p.ev.date + '|' + p.ev.summary.toLowerCase();
        if (!bySection.has(key)) bySection.set(key, new Set());
        bySection.get(key).add(p.section.id);
      }
      for (const [key, ids] of bySection) if (ids.size >= 2) shared.add(key);
    }

    const calendar = [];
    const seen = new Set();
    for (const p of parsed) {
      const ev = p.ev;
      const key = ev.date + '|' + ev.summary.toLowerCase();
      const isDistrict = p.districtWide || shared.has(key);

      // Schools republish the district's dates, so the same day arrives
      // several times. The district's copy wins, exactly as it does for a
      // stored district, and a date promoted to districtwide is only kept
      // once however many schools listed it.
      if (seen.has(key)) continue;
      if (isDistrict) seen.add(key);

      calendar.push({
        date: ev.date,
        endDate: ev.endDate,
        title: cleanTitle(rules, ev.summary),
        rawTitle: ev.summary,
        kind: eventKind(rules, ev.summary),
        scope: isDistrict ? 'district' : 'school',
        schoolIds: isDistrict ? [] : [slug(p.section.name)],
        allDay: ev.allDay,
        startTime: null,
        url: ''
      });
    }
    calendar.sort((a, b) => a.date.localeCompare(b.date));

    // Some entries repeat weekly with no end, so the feed hands back every
    // occurrence to the year 2099: nine and a half thousand entries for a
    // district with about three hundred real dates. Nothing past the end of
    // this school year is any use to a parent, and keeping it would fill the
    // phone's storage with picture days in 2074.
    const now = new Date();
    const endYear = now.getMonth() >= 7 ? now.getFullYear() + 1 : now.getFullYear();
    const horizon = endYear + '-08-31';
    const trimmed = calendar.filter((c) => c.date <= horizon);

    const site = String(info.url || '').replace(/\/+$/, '');
    return {
      schemaVersion: 1,
      generatedAt: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
      builtInApp: true,
      district: {
        name: info.name || 'Your district',
        shortName: info.shortName || '',
        url: site,
        orgId: orgId,
        phone: '',
        address: '',
        timeZone: timeZone || 'America/New_York',
        pages: site ? { calendar: site + '/events/', events: site + '/events/',
                        hours: site, feed: site + '/live-feed/' }
                    : { calendar: '', events: '', hours: '', feed: '' }
      },
      schools: schools,
      bells: [],
      calendar: trimmed,
      facts: [],
      contacts: [],
      alertFeedUrl: API + '/' + orgId + '/cms/live_feeds',
      schoolFeedUrls: {},
      alerts: []
    };
  }

  global.DistrictData = {
    build: build,
    fetchSections: fetchSections,
    parseIcs: parseIcs,
    icsTimeZone: icsTimeZone,
    eventKind: eventKind,
    cleanTitle: cleanTitle,
    guessLevel: guessLevel,
    cleanSectionName: cleanSectionName,
    isDistrictSection: isDistrictSection,
    slug: slug,
    API: API
  };
})(window);
