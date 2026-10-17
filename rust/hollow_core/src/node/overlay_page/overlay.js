// Hollow stream overlay page. Everything it draws arrives already validated from
// the app; names come from other people, so they only ever go in via textContent.
(function () {
  'use strict';

  var segs = location.pathname.split('/').filter(Boolean);
  var token = segs[0];
  var view = segs[1] === 'p' ? 'p/' + segs[2] : segs[1];
  var root = document.getElementById('overlay');
  var LOOK_STATES = ['idle', 'talking', 'muted', 'deafened', 'blink', 'loud'];
  var BLINK_MS = 150;
  var SVG_NS = 'http://www.w3.org/2000/svg';
  var ICONS = {
    mic: [
      'M2 2 22 22', 'M18.89 13.23A7.12 7.12 0 0 0 19 12v-2', 'M5 10v2a7 7 0 0 0 12 5',
      'M15 9.34V5a3 3 0 0 0-5.68-1.33', 'M9 9v3a3 3 0 0 0 5.12 2.12', 'M12 19v3'
    ],
    ears: [
      'M21 14h-1.343', 'M9.128 3.47A9 9 0 0 1 21 12v3.343', 'M2 2 22 22',
      'M20.414 20.414A2 2 0 0 1 19 21h-1a2 2 0 0 1-2-2v-3',
      'M3 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a9 9 0 0 1 2.636-6.364'
    ]
  };

  var people = new Map();
  var layout = null;
  var selfActive = true;

  function el(tag, cls) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    return e;
  }

  function icon(kind) {
    var svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('class', kind);
    ICONS[kind].forEach(function (d) {
      var path = document.createElementNS(SVG_NS, 'path');
      path.setAttribute('d', d);
      svg.appendChild(path);
    });
    return svg;
  }

  function mark(e, key, on) {
    if (on) e.dataset[key] = '';
    else delete e.dataset[key];
  }

  function unitRandom() {
    return crypto.getRandomValues(new Uint32Array(1))[0] / 4294967296;
  }

  function textOn(hex) {
    var n = Number.parseInt(hex.slice(1), 16);
    var lum = 0.299 * ((n >> 16) & 255) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255);
    return lum > 150 ? '#111111' : '#ffffff';
  }

  function initialsOf(name) {
    var out = name.trim().split(/\s+/).filter(Boolean).slice(0, 2)
      .map(function (w) { return Array.from(w)[0] || ''; }).join('');
    return (out || '?').toUpperCase();
  }

  function Person(slot) {
    this.slot = slot;
    this.data = null;
    this.state = 'idle';
    this.level = 0;
    this.talkUntil = 0;
    this.loudUntil = 0;
    this.blinking = false;
    this.blinkTimer = 0;
    this.holdTimer = 0;
    this.layers = new Map();

    this.el = el('div', 'person');
    this.el.dataset.slot = String(slot);
    this.el.dataset.state = 'idle';
    this.stage = el('div', 'stage');
    this.look = el('div', 'look');
    this.frame = el('div', 'frame');
    this.initials = el('div', 'initials');
    this.badge = el('div', 'badge');
    this.name = el('div', 'name');
    this.badge.appendChild(icon('mic'));
    this.badge.appendChild(icon('ears'));
    this.frame.appendChild(this.initials);
    this.look.appendChild(this.frame);
    this.stage.appendChild(this.look);
    this.stage.appendChild(this.badge);
    this.el.appendChild(this.stage);
    this.el.appendChild(this.name);
  }

  Person.prototype.effects = function () {
    return (this.data.look && this.data.look.effects) || layout.defaults;
  };

  Person.prototype.states = function () {
    return (this.data.look && this.data.look.states) || {};
  };

  Person.prototype.setData = function (d) {
    this.data = d;
    var e = this.el;
    var fx = this.effects();
    var st = this.states();
    mark(e, 'self', d.self);
    mark(e, 'added', d.added);
    e.style.setProperty('--c', d.colour);
    e.style.setProperty('--on-c', textOn(d.colour));
    this.name.textContent = d.name;
    this.initials.textContent = initialsOf(d.name);
    e.dataset.talkingEffect = fx.talking;
    e.dataset.idleEffect = fx.idle;
    e.dataset.transition = fx.transition;
    e.dataset.shadow = fx.shadow;
    mark(e, 'mirror', fx.mirror);
    mark(e, 'scaleVoice', fx.scale_with_voice);

    // Every image the person can show sits in the frame already, so a state change
    // never waits on a load.
    var urls = new Set();
    LOOK_STATES.forEach(function (k) { if (st[k]) urls.add(st[k]); });
    if (d.avatar) urls.add(d.avatar);
    var layers = this.layers;
    layers.forEach(function (img, url) {
      if (!urls.has(url)) {
        img.remove();
        layers.delete(url);
      }
    });
    var frame = this.frame;
    layers.forEach(function (img, url) { img.classList.toggle('avatar', url === d.avatar); });
    urls.forEach(function (url) {
      if (layers.has(url)) return;
      var img = el('img', url === d.avatar ? 'layer avatar' : 'layer');
      img.alt = '';
      img.draggable = false;
      img.decoding = 'async';
      img.src = url;
      frame.appendChild(img);
      layers.set(url, img);
    });
    this.render();
  };

  Person.prototype.visible = function (shown) {
    var d = this.data;
    if (d.self && !selfActive && layout.self_when_inactive === 'hidden') return false;
    if (layout.only_added && !d.added && !d.self) return false;
    return !(layout.only_talking && shown !== 'talking');
  };

  Person.prototype.render = function () {
    if (!this.data || !layout) return;
    var now = performance.now();
    var d = this.data;
    var fx = this.effects();
    var st = this.states();

    var talking = this.state === 'talking';
    if (talking) this.talkUntil = now + fx.hold_ms;
    var showTalk = talking || (this.state === 'idle' && now < this.talkUntil);
    var loudNow = talking && this.level >= fx.loud_threshold;
    if (loudNow) this.loudUntil = now + fx.hold_ms;
    var loud = showTalk && (loudNow || now < this.loudUntil);
    var shown = showTalk ? 'talking' : this.state;

    var idleImg = st.idle || d.avatar || '';
    var img = idleImg;
    var standIn = false;
    if (shown === 'talking') {
      img = (loud && st.loud) || st.talking || idleImg;
    } else if (shown === 'muted' || shown === 'deafened') {
      img = st[shown] || idleImg;
      standIn = !st[shown];
    } else if (this.blinking && st.blink) {
      img = st.blink;
    }

    var e = this.el;
    e.dataset.state = shown;
    e.dataset.kind = !img ? 'initials' : (img === d.avatar ? 'avatar' : 'look');
    mark(e, 'loud', loud);
    mark(e, 'blink', this.blinking && shown === 'idle');
    mark(e, 'fallback', standIn);
    if (standIn) e.dataset.badge = shown;
    else delete e.dataset.badge;
    e.style.setProperty('--amp', fx.scale_with_voice ? Math.min(1.3, 0.3 + this.level).toFixed(3) : '1');
    this.layers.forEach(function (layer, url) { layer.classList.toggle('on', url === img); });
    mark(e, 'hidden', !this.visible(shown));

    // Re-draw when a hold ends with no new update to trigger it.
    clearTimeout(this.holdTimer);
    var until = Math.max(showTalk && !talking ? this.talkUntil : 0, loud && !loudNow ? this.loudUntil : 0);
    if (until > now) {
      var me = this;
      this.holdTimer = setTimeout(function () { me.render(); }, until - now + 5);
    }
    this.scheduleBlink(shown === 'idle' && !!st.blink, fx);
  };

  Person.prototype.scheduleBlink = function (wanted, fx) {
    if (!wanted) {
      clearTimeout(this.blinkTimer);
      this.blinkTimer = 0;
      this.blinking = false;
      return;
    }
    if (this.blinkTimer) return;
    var me = this;
    var wait = fx.blink_every_s * 1000 * (0.6 + unitRandom() * 0.8);
    this.blinkTimer = setTimeout(function () {
      me.blinkTimer = 0;
      me.blinking = true;
      me.render();
      setTimeout(function () {
        me.blinking = false;
        me.render();
      }, BLINK_MS);
    }, wait);
  };

  Person.prototype.destroy = function () {
    clearTimeout(this.holdTimer);
    clearTimeout(this.blinkTimer);
    this.el.remove();
  };

  function blank() {
    people.forEach(function (p) { p.destroy(); });
    people.clear();
    layout = null;
    root.textContent = '';
  }

  function applySnapshot(s) {
    layout = s.layout;
    root.dataset.direction = layout.direction;
    root.dataset.align = layout.align;
    root.dataset.names = layout.names;
    root.style.setProperty('--size', layout.size + 'px');
    root.style.setProperty('--gap', layout.gap + 'px');
    var keep = new Set();
    s.people.forEach(function (d) {
      keep.add(d.slot);
      var p = people.get(d.slot);
      if (!p) {
        p = new Person(d.slot);
        people.set(d.slot, p);
      }
      p.setData(d);
      root.appendChild(p.el);
    });
    people.forEach(function (p, slot) {
      if (!keep.has(slot)) {
        p.destroy();
        people.delete(slot);
      }
    });
  }

  function applyLive(l) {
    selfActive = l.self_active !== false;
    var bySlot = new Map();
    l.people.forEach(function (x) { bySlot.set(x.slot, x); });
    people.forEach(function (p, slot) {
      var x = bySlot.get(slot);
      p.state = x ? x.state : 'idle';
      p.level = x ? x.level : 0;
      p.render();
    });
  }

  function parse(text) {
    try {
      return JSON.parse(text);
    } catch (_) {
      return null;
    }
  }

  function connect() {
    var es = new EventSource('/' + token + '/events?view=' + encodeURIComponent(view));
    es.addEventListener('snapshot', function (ev) {
      var s = parse(ev.data);
      if (s) applySnapshot(s);
    });
    es.addEventListener('live', function (ev) {
      var l = parse(ev.data);
      if (l && layout) applyLive(l);
    });
    es.addEventListener('locked', blank);
    // Whatever cut the stream (lock, wipe, the server turned off), the page shows
    // nothing until a fresh snapshot arrives.
    es.onerror = function () {
      blank();
      if (es.readyState === EventSource.CLOSED) {
        es.close();
        setTimeout(connect, 3000);
      }
    };
  }

  connect();
})();
