/*
 * staff.js — who works at a school.
 *
 * Every district on this platform publishes a staff directory the same way it
 * publishes a calendar: an open feed, keyed only by the school's number. The
 * school's own Staff page is built from it. So the app does not need to crawl
 * anything to say who teaches science; it reads the same list the website
 * reads, for the school the parent actually picked.
 *
 * WHAT THIS DELIBERATELY DOES NOT CARRY
 *
 * The feed has an email and a phone field for each person. Across Edison's
 * twenty schools, 2,105 staff are listed and 156 have an email in the feed -
 * two elementary schools fill it in, eighteen leave it blank, and Edison High
 * School has gone further and set every one of its 275 entries to the literal
 * value "hidden". That is a district making a choice about its staff's
 * contact details, school by school, and it is not the app's to overturn.
 *
 * So names, job titles and departments are kept, and the contact fields are
 * dropped on the floor as the rows come in - see normalise(). A parent who
 * needs to email a teacher is sent to that school's own Staff page, which is
 * current, is the district's to change, and already shows an address wherever
 * the school chose to publish one. The app never holds a roster of educators'
 * email addresses, which is also the kind of compiled contact list both app
 * stores reject an app for shipping.
 *
 * WHY IT IS FETCHED RATHER THAN BUILT IN
 *
 * Those 2,105 people would add about four hundred kilobytes to a two-megabyte
 * app, go stale the first time somebody changes job, and mostly describe
 * nineteen schools the parent has no child at. One school's roster is a few
 * seconds and about ten kilobytes, so it is read for the school that was
 * picked, kept in the phone, and answered from there afterwards - including
 * with no signal. The first staff question of the fortnight needs a
 * connection; the calendar questions that get asked at 6:45am never do.
 */
(function (global) {
  'use strict';

  const API = 'https://thrillshare-cmsv2.services.thrillshare.com/api/v4/o';
  const PER_PAGE = 20;          // what the feed returns per page, not our choice
  const MAX_PAGES = 40;         // 800 people; the largest Edison school has 305
  const FRESH_MS = 7 * 24 * 60 * 60 * 1000;

  /* Storage can throw outright in a private window or with site data blocked,
   * and a roster is a convenience: without it the engine says it has not got
   * the list yet, which is true and recoverable. */
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* ignore */ } }
  };

  /* The org id in full. An earlier version of the calendar cache shortened its
   * keys and merged twenty feeds into one; a key is never worth saving bytes
   * on. */
  const keyFor = (orgId) => 'staff:' + String(orgId);

  function readCache(orgId) {
    const raw = store.get(keyFor(orgId));
    if (!raw) return null;
    try {
      const j = JSON.parse(raw);
      if (!j || !Array.isArray(j.rows)) return null;
      return { at: +j.at || 0, rows: j.rows };
    } catch (e) {
      return null;            // corrupt or half-written: fetch it again
    }
  }

  function writeCache(orgId, rows) {
    store.set(keyFor(orgId), JSON.stringify({ at: Date.now(), rows: rows }));
  }

  /**
   * One feed row -> one record, carrying only what the app will answer with.
   *
   * The feed gives first and last separately and also a full_name, and they do
   * not always agree: a few entries have the whole name in `last` and nothing
   * in `first`, and some have a full_name with the middle initial that the
   * parts leave out. Whichever is longer is the one a parent would recognise.
   */
  function normalise(row, schoolId) {
    const first = String((row && row.first) || '').trim();
    const last = String((row && row.last) || '').trim();
    const joined = (first + ' ' + last).trim();
    const full = String((row && row.full_name) || '').trim();
    const name = full.length >= joined.length ? full : joined;
    if (!name) return null;
    return {
      schoolId: String(schoolId || ''),
      name: name,
      first: first,
      last: last,
      title: String((row && row.title) || '').trim(),
      department: String((row && row.department) || '').trim()
      // email and phone_number are read and discarded here, on purpose.
      // See the note at the top of this file before adding them.
    };
  }

  async function getJson(url) {
    const r = await fetch(url, { mode: 'cors', credentials: 'omit' });
    if (!r.ok) throw new Error(url + ' returned ' + r.status);
    return r.json();
  }

  /**
   * Reads every page of one school's directory.
   *
   * The feed reports total_entries, so the number of pages is known after the
   * first request rather than guessed at by fetching until something comes
   * back empty.
   */
  async function fetchRoster(orgId, schoolId) {
    const first = await getJson(API + '/' + orgId + '/cms/directories');
    const total = (first && first.meta && first.meta.links &&
                   +first.meta.links.total_entries) || 0;
    const rows = [];

    const take = (j) => {
      const list = (j && (j.directories || j.data || j.entries)) || [];
      for (const r of list) {
        const rec = normalise(r, schoolId);
        if (rec) rows.push(rec);
      }
    };
    take(first);

    const pages = Math.min(Math.ceil(total / PER_PAGE), MAX_PAGES);
    for (let p = 2; p <= pages; p++) {
      try {
        take(await getJson(API + '/' + orgId + '/cms/directories?page_no=' + p));
      } catch (e) {
        break;    // a partial roster still answers most questions
      }
    }
    return rows;
  }

  /**
   * The roster for one school, from the phone if it is there and recent.
   *
   * Returns what it has either way: a stale list is a better answer than no
   * answer, so an expired cache is used immediately and refreshed behind the
   * question rather than made to wait for the network.
   */
  async function load(school, opts) {
    const o = opts || {};
    if (!school || !school.orgId) return [];
    const orgId = school.orgId;
    const cached = readCache(orgId);
    const fresh = cached && (Date.now() - cached.at) < FRESH_MS;

    if (cached && (fresh || o.cacheOnly)) {
      if (!fresh && !o.cacheOnly) refresh(school);
      return cached.rows;
    }
    if (o.cacheOnly) return [];

    try {
      const rows = await fetchRoster(orgId, school.id);
      if (rows.length) writeCache(orgId, rows);
      return rows;
    } catch (e) {
      return cached ? cached.rows : [];
    }
  }

  /** Fetch in the background; nothing waits on it. */
  function refresh(school) {
    if (!school || !school.orgId) return;
    fetchRoster(school.orgId, school.id)
      .then((rows) => { if (rows.length) writeCache(school.orgId, rows); })
      .catch(() => { /* the cached list stands */ });
  }

  /** Whatever is already in the phone, for the schools given. Never waits. */
  function cached(schools) {
    const out = [];
    for (const s of (schools || [])) {
      if (!s || !s.orgId) continue;
      const c = readCache(s.orgId);
      if (c) for (const r of c.rows) out.push(r);
    }
    return out;
  }

  /**
   * A district the app has never crawled knows its own number but not its
   * schools' - build() in district.js gets the calendar from section ids,
   * which are not org ids. Some districts keep one directory at district
   * level; where that is so, this finds it, and where it is not, there is
   * nothing to find and the engine says so.
   */
  async function loadDistrictWide(orgId) {
    if (!orgId) return [];
    const cached_ = readCache(orgId);
    if (cached_ && (Date.now() - cached_.at) < FRESH_MS) return cached_.rows;
    try {
      const rows = await fetchRoster(orgId, '');
      if (rows.length) writeCache(orgId, rows);
      return rows;
    } catch (e) {
      return cached_ ? cached_.rows : [];
    }
  }

  global.StaffDirectory = {
    load: load,
    loadDistrictWide: loadDistrictWide,
    cached: cached,
    refresh: refresh,
    normalise: normalise,
    API: API
  };
})(window);
