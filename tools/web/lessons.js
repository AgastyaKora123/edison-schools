// lessons.js - "give me a topic and a grade, get a set of questions".
//
// Two kinds of topic live in content/lessons.json. A written one carries its
// cards. A generated one names a maker in here, and the app works the
// questions out itself, which is why maths never runs out and never gets a
// fact wrong.
//
// Everything is deterministic: the same (topic, grade, count, seed) gives the
// same questions every time.
//
// The Swift copy is NOT held to producing the same numbers as this one, which
// is a deliberate departure from how the answer engine is treated. The answer
// engine must agree word for word, because a parent asking the same question
// on two devices must not be told two different things. Here the questions are
// made up on the spot, so "7 x 8" on the phone and "6 x 9" on the website are
// both perfectly good. What both sides are held to, in their own tests, is
// that every answer is arithmetically right, that a set of 20 really is 20,
// and that none of them repeat. That is what would actually hurt a child if
// it broke.
//
// Numbers are written plainly, with no thousands separators, because comma
// placement is the kind of thing that differs between languages and would show
// up as a false failure.

(function (global) {
  'use strict';

  // --- the shared number sequence -----------------------------------------
  // Xorshift32. Not for anything that matters - it exists so that two
  // languages can agree on a list of questions.
  //
  // This started as a plain multiply-and-add generator, which looked fine
  // until a set of percentage questions came back with five cards instead of
  // twenty. The low bits of that kind of generator barely change, so
  // "next() % 2" simply alternated and the same handful of questions came up
  // over and over. Xorshift mixes the whole word, so taking a remainder of a
  // small number is safe.
  function Rand(seed) {
    this.state = (seed >>> 0) || 1;
  }
  Rand.prototype.next = function () {
    var x = this.state;
    x ^= (x << 13); x >>>= 0;
    x ^= (x >>> 17);
    x ^= (x << 5);  x >>>= 0;
    this.state = x || 1;
    return this.state;
  };
  // A whole number from low to high, both ends included.
  Rand.prototype.between = function (low, high) {
    if (high <= low) return low;
    return low + (this.next() % (high - low + 1));
  };
  Rand.prototype.pick = function (list) {
    return list[this.next() % list.length];
  };

  function gcd(a, b) { while (b) { var t = a % b; a = b; b = t; } return a; }

  // A minus sign, not a hyphen. The same character is used for subtraction
  // everywhere in here, so a question and its answer look consistent.
  function neg(n) { return n < 0 ? '−' + Math.abs(n) : String(n); }

  var PLACES = ['ones', 'tens', 'hundreds', 'thousands',
                'ten thousands', 'hundred thousands'];

  // --- the makers ----------------------------------------------------------
  // Each takes (rand, params) and returns {q, a}.

  var MAKERS = {
    timesTables: function (r, p) {
      var a = r.between(p.low, p.high);
      var b = r.between(2, 12);
      return { q: a + ' × ' + b, a: String(a * b) };
    },

    division: function (r, p) {
      var by = r.between(p.low, p.high);
      var answer = r.between(2, 12);
      return { q: (by * answer) + ' ÷ ' + by, a: String(answer) };
    },

    addSubtract: function (r, p) {
      var a = r.between(10, p.max);
      var b = r.between(10, p.max);
      if (r.next() % 2 === 0) {
        return { q: a + ' + ' + b, a: String(a + b) };
      }
      var big = Math.max(a, b), small = Math.min(a, b);
      return { q: big + ' − ' + small, a: String(big - small) };
    },

    rounding: function (r, p) {
      var n = r.between(p.to, p.max);
      var name = p.to === 10 ? 'ten' : (p.to === 100 ? 'hundred' : 'thousand');
      var half = p.to / 2;
      var rounded = Math.floor((n + half) / p.to) * p.to;
      return { q: 'Round ' + n + ' to the nearest ' + name, a: String(rounded) };
    },

    placeValue: function (r, p) {
      var low = Math.pow(10, p.digits - 1);
      var high = Math.pow(10, p.digits) - 1;
      var n = r.between(low, high);
      var place = r.between(0, p.digits - 1);
      var digit = Math.floor(n / Math.pow(10, place)) % 10;
      return {
        q: 'Which digit is in the ' + PLACES[place] + ' place of ' + n + '?',
        a: String(digit)
      };
    },

    simplifyFraction: function (r, p) {
      // Build a fraction that is definitely not already in lowest terms.
      var b = r.between(2, Math.max(2, Math.floor(p.maxDenominator / 2)));
      var a = r.between(1, b - 1 > 0 ? b - 1 : 1);
      var g = gcd(a, b);
      a = a / g; b = b / g;
      if (b < 2) { a = 1; b = 2; }
      var maxK = Math.floor(p.maxDenominator / b);
      var k = r.between(2, maxK < 2 ? 2 : maxK);
      return {
        q: 'Write ' + (a * k) + '/' + (b * k) + ' in its simplest form',
        a: a + '/' + b
      };
    },

    percentOf: function (r, p) {
      var pc = r.pick(p.percents);
      var steps = Math.max(1, Math.floor(p.max / 20));
      var n = 20 * r.between(1, steps);
      return {
        q: 'What is ' + pc + '% of ' + n + '?',
        a: String((pc * n) / 100)
      };
    },

    // One step to get x on its own. Four shapes, so it is not just the
    // same sum dressed differently twenty times.
    oneStepEquations: function (r, p) {
      var x = r.between(1, p.max);
      var shape = r.next() % 4;
      if (shape === 0) {
        var add = r.between(1, p.max);
        return { q: 'Solve: x + ' + add + ' = ' + (x + add), a: String(x) };
      }
      if (shape === 1) {
        // Never more than x, so the right-hand side cannot go negative.
        // Grade 6 meets this before it meets negative numbers.
        var take = r.between(1, x);
        return { q: 'Solve: x − ' + take + ' = ' + (x - take), a: String(x) };
      }
      if (shape === 2) {
        var by = r.between(2, 12);
        return { q: 'Solve: ' + by + 'x = ' + (by * x), a: String(x) };
      }
      var div = r.between(2, 12);
      return { q: 'Solve: x ÷ ' + div + ' = ' + x, a: String(div * x) };
    },

    // The second number is always positive, so a question never reads
    // "5 + −3", which is a different skill and a different lesson.
    negativeNumbers: function (r, p) {
      var a = r.between(-p.max, p.max);
      var b = r.between(1, p.max);
      var plus = r.next() % 2 === 0;
      var result = plus ? a + b : a - b;
      return {
        q: neg(a) + (plus ? ' + ' : ' − ') + b,
        a: neg(result)
      };
    },

    exponents: function (r, p) {
      var base = r.between(p.low, p.high);
      var power = r.between(2, p.maxPower || 3);
      var value = 1;
      for (var i = 0; i < power; i++) value *= base;
      return {
        q: base + ' to the power of ' + power,
        a: String(value)
      };
    },

    volumeBox: function (r, p) {
      var a = r.between(2, p.max);
      var b = r.between(2, p.max);
      var c = r.between(2, p.max);
      return {
        q: 'A box is ' + a + ' by ' + b + ' by ' + c + '. What is its volume?',
        a: String(a * b * c)
      };
    },

    // Same denominator only. The answer is always given in its simplest
    // form, because that is what a teacher will be marking.
    addFractionsSame: function (r, p) {
      var d = r.between(3, p.maxDenominator);
      var a = r.between(1, d - 1);
      var b = r.between(1, d - a);
      var top = a + b;
      var answer;
      if (top === d) {
        answer = '1';
      } else {
        var g = gcd(top, d);
        answer = (top / g) + '/' + (d / g);
      }
      return { q: a + '/' + d + ' + ' + b + '/' + d, a: answer };
    },

    primeOrComposite: function (r, p) {
      // From 10 up, so the answer is never obvious at a glance.
      var n = r.between(10, p.max);
      var prime = true;
      for (var i = 2; i * i <= n; i++) {
        if (n % i === 0) { prime = false; break; }
      }
      return {
        q: 'Is ' + n + ' prime or composite?',
        a: prime ? 'Prime' : 'Composite'
      };
    },

    areaPerimeter: function (r, p) {
      var w = r.between(2, p.max);
      var h = r.between(2, p.max);
      if (r.next() % 2 === 0) {
        return {
          q: 'A rectangle is ' + w + ' by ' + h + '. What is its area?',
          a: String(w * h)
        };
      }
      return {
        q: 'A rectangle is ' + w + ' by ' + h + '. What is its perimeter?',
        a: String(2 * (w + h))
      };
    }
  };

  // --- the library ---------------------------------------------------------

  function all() {
    var data = global.LESSONS;
    return (data && data.topics) ? data.topics : [];
  }

  function grades() {
    var data = global.LESSONS;
    return (data && data.grades) ? data.grades : [3, 4, 5, 6, 7, 8];
  }

  function suitsGrade(topic, grade) {
    if (topic.make) return !!(topic.byGrade && topic.byGrade[String(grade)]);
    return (topic.grades || []).indexOf(grade) !== -1;
  }

  function forGrade(grade) {
    return all().filter(function (t) { return suitsGrade(t, grade); });
  }

  // Loose matching, so "frac", "Fractions" and "simplifying" all find the
  // same topic. Deliberately forgiving: a child typing a topic should not
  // have to guess the exact words.
  function search(text, grade) {
    var list = (grade === undefined || grade === null) ? all() : forGrade(grade);
    var q = String(text || '').trim().toLowerCase();
    if (!q) return list;
    var words = q.split(/\s+/);
    return list.filter(function (t) {
      var hay = (t.name + ' ' + (t.subject || '') + ' ' + (t.note || '') + ' ' + t.id).toLowerCase();
      return words.every(function (w) { return hay.indexOf(w) !== -1; });
    });
  }

  function byId(id) {
    var found = all().filter(function (t) { return t.id === id; });
    return found.length ? found[0] : null;
  }

  // Build the cards. Written topics hand back what they hold (at most
  // `count`, in order). Generated topics are worked out, skipping any
  // repeat so a set of 20 is 20 different questions.
  function make(topicId, grade, count, seed) {
    var topic = byId(topicId);
    if (!topic) return null;
    if (!suitsGrade(topic, grade)) return null;
    var want = count || 20;

    if (!topic.make) {
      return {
        topicId: topic.id,
        name: topic.name + ' · grade ' + grade,
        subject: topic.subject,
        cards: (topic.cards || []).slice(0, want)
      };
    }

    var maker = MAKERS[topic.make];
    if (!maker) return null;
    var params = topic.byGrade[String(grade)];
    var rand = new Rand((seed === undefined || seed === null) ? 1 : seed);
    var cards = [];
    var seen = {};
    var tries = 0;
    while (cards.length < want && tries < want * 40) {
      tries++;
      var card = maker(rand, params);
      if (seen[card.q]) continue;
      seen[card.q] = true;
      cards.push(card);
    }
    return {
      topicId: topic.id,
      name: topic.name + ' · grade ' + grade,
      subject: topic.subject,
      cards: cards
    };
  }

  global.Lessons = {
    all: all,
    grades: grades,
    forGrade: forGrade,
    search: search,
    byId: byId,
    suitsGrade: suitsGrade,
    make: make,
    _Rand: Rand,
    _MAKERS: MAKERS
  };
})(window);
