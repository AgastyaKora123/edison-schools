/*
 * practice.js - turning your own notes into questions, in the browser.
 *
 * The twin of PracticeModels.swift, NotesParser.swift and PracticeStore.swift
 * in the iPhone app. Same separators, same Leitner intervals, same rule about
 * a colon inside a time. Change one, change both: three engines that drifted
 * apart cost a day of this project already, and this is the same trap.
 *
 * Decks live in this browser's own storage and nowhere else. No account, no
 * server, nothing uploaded - the same promise the rest of the app makes.
 * Somebody's revision notes are their business.
 */
(function (global) {
  'use strict';

  // ------------------------------------------------------------- parsing

  // In order of confidence. A tab is almost always deliberate; a bare hyphen
  // almost never is, which is why it needs spaces round it to count.
  const SEPARATORS = ['\t', ' — ', ' – ', ' - ', ' = ', ': ', ' : '];

  const BULLETS = ['•', '·', '‣', '▪', '*', '–', '—', '-'];

  /**
   * Removes list decoration people type without thinking.
   *
   * Done before looking for a separator: a line starting "- Osmosis - water
   * moving" has a leading dash that is decoration and a middle one that is
   * the separator, and taking the first would leave an empty term.
   */
  function stripLeading(s) {
    let out = String(s || '').trim();
    while (out.length && BULLETS.indexOf(out[0]) >= 0) out = out.slice(1).trim();
    out = out.replace(/^([0-9]{1,3}|[a-zA-Z])[.)]\s+/, '');
    return out.trim();
  }

  /** Splits at the first separator that leaves text on both sides. */
  function split(line) {
    for (const sep of SEPARATORS) {
      let from = 0;
      for (;;) {
        const at = line.indexOf(sep, from);
        if (at < 0) break;
        const front = line.slice(0, at).trim();
        const back = line.slice(at + sep.length).trim();

        // A colon inside a time or a ratio is not a separator: "the test is
        // at 3:30" and "a 2:1 ratio" are sentences, not definitions.
        const colonish = sep.indexOf(':') >= 0;
        if (colonish && /[0-9]$/.test(front) && /^[0-9]/.test(back)) {
          from = at + sep.length;
          continue;
        }
        if (front && back && front.length <= 120) return [front, back];
        from = at + sep.length;
      }
    }
    return null;
  }

  /**
   * Most revision notes are already pairs - "Mitochondria - the powerhouse of
   * the cell" - written with no intention of becoming flashcards. So read
   * what people already write rather than asking them to type it again.
   *
   * Lines with no pair are returned, not dropped. A parser that quietly
   * ignores half your notes is worse than one that refuses them, because you
   * find out at the test.
   */
  function parse(text) {
    const cards = [];
    const skipped = [];
    for (const raw of String(text || '').split(/\r?\n/)) {
      const line = stripLeading(raw);
      if (!line) continue;
      const pair = split(line);
      if (!pair) { skipped.push(line); continue; }
      cards.push(newCard(pair[0], pair[1]));
    }
    return { cards: cards, skipped: skipped };
  }

  // ---------------------------------------------------------- scheduling

  // Today, tomorrow, later this week, next week, in three weeks. Every one
  // of these can be explained to the person using it in a sentence, which a
  // student who can see why a card came back actually trusts.
  const INTERVALS = [0, 1, 3, 7, 21];

  function todayKey(d) {
    const t = d || new Date();
    return new Date(t.getFullYear(), t.getMonth(), t.getDate()).getTime();
  }

  function newCard(front, back) {
    return {
      id: (global.crypto && global.crypto.randomUUID)
        ? global.crypto.randomUUID()
        : 'c' + Date.now() + Math.random().toString(36).slice(2),
      front: front, back: back,
      box: 1, due: 0, seen: 0, correct: 0
    };
  }

  function interval(box) {
    return INTERVALS[Math.min(Math.max(box, 1), INTERVALS.length) - 1];
  }

  function markCorrect(card, on) {
    card.seen += 1;
    card.correct += 1;
    card.box = Math.min(card.box + 1, INTERVALS.length);
    card.due = todayKey(on) + interval(card.box) * 86400000;
  }

  /**
   * Straight back to box one, not down a box. A card you have just failed is
   * a card you do not know, whatever you managed last week, and pretending
   * otherwise is how people "revise" things they cannot recall.
   */
  function markWrong(card, on) {
    card.seen += 1;
    card.box = 1;
    card.due = todayKey(on);
  }

  function isDue(card, on) {
    return (card.due || 0) <= todayKey(on);
  }

  /** Lowest box first: the hard ones while there is still attention for them. */
  function dueCards(deck, on) {
    return (deck.cards || [])
      .filter((c) => isDue(c, on))
      .sort((a, b) => a.box - b.box);
  }

  function learned(deck) {
    return (deck.cards || []).filter((c) => c.box >= 4).length;
  }

  // ------------------------------------------------------------- storage

  const KEY = 'schoolo.practice.decks';

  function load() {
    try {
      const raw = global.localStorage.getItem(KEY);
      return raw ? JSON.parse(raw) : [];
    } catch (e) {
      return [];   // a browser with storage switched off still works, emptily
    }
  }

  function save(decks) {
    try {
      global.localStorage.setItem(KEY, JSON.stringify(decks));
      return true;
    } catch (e) {
      return false;
    }
  }

  function newDeck(name, cards) {
    return {
      id: (global.crypto && global.crypto.randomUUID)
        ? global.crypto.randomUUID()
        : 'd' + Date.now() + Math.random().toString(36).slice(2),
      name: name, created: Date.now(), cards: cards || []
    };
  }

  global.Practice = {
    parse: parse, split: split, stripLeading: stripLeading,
    newCard: newCard, newDeck: newDeck,
    markCorrect: markCorrect, markWrong: markWrong,
    isDue: isDue, dueCards: dueCards, learned: learned, interval: interval,
    load: load, save: save,
    INTERVALS: INTERVALS
  };
})(window);
