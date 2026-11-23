/*
 * calfile.js - the website's answer to "tell me before it happens".
 *
 * New in 1.3. The iPhone app can schedule a notification for the evening
 * before every day off, because an app is allowed to. A web page is not: real
 * web push needs a push service, a server and a subscription per browser, and
 * this project has no backend at all - that is the whole reason it is free and
 * works offline.
 *
 * So instead of pretending, this hands the dates to something that already
 * does reminders properly: the calendar app on the phone. One download, and
 * every day off, early dismissal and late start is in there with an alarm the
 * evening before. It then works with no app installed, on Android as well as
 * iPhone, and keeps working if this website disappears.
 *
 * The exclusive-end trap, for the second time in this project: iCalendar's
 * DTEND for an all-day event is the day AFTER the last day. The ingest step
 * un-did that when reading the district's feed, so the pack holds an
 * INCLUSIVE end - and writing a file means putting the extra day back. Get it
 * wrong and every break in the file is a day short.
 */
(function (global) {
  'use strict';

  // Kinds worth putting in somebody's calendar, and what to call them.
  // Anything not listed - an ordinary event, a concert - is left out: this is
  // a file about days that change the school run.
  const LABELS = {
    closed: 'No school',
    break: 'No school',
    no_school_students: 'No school for students',
    early_dismissal: 'Early dismissal',
    single_session: 'Early dismissal',
    delayed_opening: 'Late start',
    first_day: 'First day of school',
    last_day: 'Last day of school'
  };

  const MAX_EVENTS = 300;

  // ------------------------------------------------------------ dates

  /** "2026-12-24" -> a UTC date, so no local time zone can shift the day. */
  function parseDay(iso) {
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ''));
    if (!m) return null;
    return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  }

  function addDays(d, n) {
    return new Date(d.getTime() + n * 86400000);
  }

  function stamp(d) {
    const p = (n) => String(n).padStart(2, '0');
    return d.getUTCFullYear() + p(d.getUTCMonth() + 1) + p(d.getUTCDate());
  }

  function stampUTCTime(d) {
    const p = (n) => String(n).padStart(2, '0');
    return stamp(d) + 'T' + p(d.getUTCHours()) + p(d.getUTCMinutes()) + p(d.getUTCSeconds()) + 'Z';
  }

  // ------------------------------------------------------------ text

  /** Commas and semicolons are field separators in this format. */
  function esc(s) {
    return String(s || '')
      .replace(/\\/g, '\\\\')
      .replace(/\n/g, '\\n')
      .replace(/;/g, '\\;')
      .replace(/,/g, '\\,');
  }

  /**
   * Lines must be at most 75 octets, continued with a leading space.
   *
   * Measured in octets rather than characters on purpose: a title with an
   * em dash in it is three bytes for one character, and a parser that counts
   * bytes will cut the line in the middle of it.
   */
  function fold(line) {
    const bytes = (c) => {
      const n = c.codePointAt(0);
      if (n < 0x80) return 1;
      if (n < 0x800) return 2;
      if (n < 0x10000) return 3;
      return 4;
    };
    let out = '';
    let used = 0;
    let first = true;
    for (const ch of String(line)) {
      const b = bytes(ch);
      const limit = first ? 75 : 74;           // continuations spend one on the space
      if (used + b > limit) {
        out += '\r\n ';
        used = 1;
        first = false;
      }
      out += ch;
      used += b;
    }
    return out;
  }

  function sameWords(a, b) {
    const bare = (s) => String(s || '').toLowerCase().replace(/[^a-z]/g, '');
    const x = bare(a), y = bare(b);
    if (!x || !y) return false;
    return x.indexOf(y) >= 0 || y.indexOf(x) >= 0;
  }

  /** A stable, legal UID so a second import updates rather than duplicates. */
  function uid(entry) {
    let h = 5381;
    const s = (entry.title || '') + '|' + (entry.kind || '') + '|' + (entry.date || '');
    for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
    return entry.date + '-' + entry.kind + '-' + h.toString(36) + '@schoolo';
  }

  // ------------------------------------------------------------ building

  function districtShort(pack) {
    const name = (pack && pack.district && pack.district.name) || '';
    // Same two-pass strip the rest of the app uses, kept simple here: the
    // calendar's name is cosmetic, so a missing word costs nothing.
    return name.replace(/\b(public |township |consolidated |independent )/gi, '')
               .replace(/\b(school district|schools|district|isd|usd|cusd)\b/gi, '')
               .replace(/\s+/g, ' ')
               .trim();
  }

  /**
   * Which entries belong in the file: the right kind, not already over, and
   * either district-wide or about the school this person chose.
   */
  function entriesFor(pack, opts) {
    const o = opts || {};
    // The website lets someone follow more than one school - two children at
    // two schools is the normal case - so this takes a list.
    const mineIds = (o.schoolIds && o.schoolIds.length)
      ? o.schoolIds
      : (o.schoolId ? [o.schoolId] : []);
    const from = o.from ? parseDay(isoOf(o.from)) : parseDay(isoOf(new Date()));
    const rows = (pack && pack.calendar) || [];
    const out = [];

    for (const e of rows) {
      if (!LABELS[e.kind]) continue;
      const start = parseDay(e.date);
      const end = parseDay(e.endDate || e.date) || start;
      if (!start) continue;
      if (from && end < from) continue;                  // already over

      const ids = e.schoolIds || [];
      const mine = e.scope === 'district' ||
                   ids.some((id) => mineIds.indexOf(id) >= 0);
      if (!mine) continue;

      out.push({ entry: e, start: start, end: end });
      if (out.length >= MAX_EVENTS) break;
    }
    out.sort((a, b) => a.start - b.start);
    return out;
  }

  function isoOf(d) {
    if (typeof d === 'string') return d;
    const p = (n) => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
  }

  /**
   * The whole file as text.
   *
   * `hour` is the evening-before alarm, 18 for 6pm. All-day events start at
   * midnight, so an alarm 6 hours before midnight is 6pm the previous day -
   * which is why the trigger is negative hours rather than a date.
   */
  function build(pack, opts) {
    const o = opts || {};
    const hour = (typeof o.hour === 'number' && o.hour >= 0 && o.hour <= 23) ? o.hour : 18;
    const rows = entriesFor(pack, o);
    const who = districtShort(pack) || 'School';
    const now = new Date();

    const lines = [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//Schoolo//School calendar//EN',
      'CALSCALE:GREGORIAN',
      'METHOD:PUBLISH',
      fold('X-WR-CALNAME:' + esc(who + ' - days off')),
      fold('X-WR-CALDESC:' + esc('Days off, early dismissals and late starts, from what ' +
           ((pack && pack.district && pack.district.name) || 'the district') + ' publishes. Unofficial.'))
    ];

    const tz = (pack && pack.district && pack.district.timeZone) || '';
    if (tz) lines.push('X-WR-TIMEZONE:' + tz);

    for (const row of rows) {
      const e = row.entry;
      const label = LABELS[e.kind];
      const title = String(e.title || '').trim();
      const summary = (title && !sameWords(title, label)) ? (label + ': ' + title) : label;

      lines.push('BEGIN:VEVENT');
      lines.push('UID:' + uid(e));
      lines.push('DTSTAMP:' + stampUTCTime(now));
      lines.push('DTSTART;VALUE=DATE:' + stamp(row.start));
      // The exclusive end, put back: one day after the last day.
      lines.push('DTEND;VALUE=DATE:' + stamp(addDays(row.end, 1)));
      lines.push(fold('SUMMARY:' + esc(summary)));
      // "Edison Township Public Schools's published calendar" is what the
      // obvious phrasing produces, and most district names end in s.
      lines.push(fold('DESCRIPTION:' + esc(
        'From the calendar published by ' +
        ((pack && pack.district && pack.district.name) || 'the district') +
        '. Unofficial - the district\'s own announcements are the authority.')));
      lines.push('CATEGORIES:SCHOOL');
      // A day off should not make somebody look busy to their colleagues.
      lines.push('TRANSP:TRANSPARENT');
      lines.push('SEQUENCE:0');
      lines.push('BEGIN:VALARM');
      lines.push('ACTION:DISPLAY');
      lines.push(fold('DESCRIPTION:' + esc(summary + ' tomorrow')));
      lines.push('TRIGGER:-PT' + (24 - hour) + 'H');
      lines.push('END:VALARM');
      lines.push('END:VEVENT');
    }

    lines.push('END:VCALENDAR');
    return lines.join('\r\n') + '\r\n';
  }

  function filename(pack) {
    const who = districtShort(pack) || 'school';
    return who.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') + '-days-off.ics';
  }

  /** Hands the file to the browser. No network, no server, no upload. */
  function download(text, name) {
    const blob = new Blob([text], { type: 'text/calendar;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = name || 'school-days-off.ics';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    // Revoking straight away breaks the download on some browsers.
    setTimeout(() => URL.revokeObjectURL(url), 10000);
  }

  function countFor(pack, opts) {
    return entriesFor(pack, opts).length;
  }

  global.SchoolCal = {
    build: build,
    filename: filename,
    download: download,
    count: countFor,
    entriesFor: entriesFor,
    fold: fold,
    esc: esc,
    LABELS: LABELS
  };
})(window);
