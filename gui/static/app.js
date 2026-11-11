/* universal-migrate-site-script GUI — vanilla JS, no build step.
 * Talks to gui/server.py. Views: welcome/new, migration overview, setup
 * wizard, steps & hooks, runs (list + live detail), log files, user guide. */
'use strict';
(function () {

  // ---------------------------------------------------------------- helpers
  const $ = (sel, root) => (root || document).querySelector(sel);
  const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));

  // h('div', {class: 'x', onclick: fn}, 'text', child, [children]) — strings become text nodes.
  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === null || v === undefined || v === false) continue;
      if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
      else if (k === 'class') el.className = v;
      else if (k === 'value') el.value = v;
      else if (k === 'checked' || k === 'disabled' || k === 'selected' || k === 'open') el[k] = !!v;
      else if (k === 'html') el.innerHTML = v; // static, trusted strings only
      else el.setAttribute(k, v === true ? '' : v);
    }
    add(el, kids);
    return el;
  }
  function add(el, kids) {
    for (const k of kids.flat(Infinity)) {
      if (k === null || k === undefined || k === false) continue;
      el.append(k instanceof Node ? k : document.createTextNode(String(k)));
    }
    return el;
  }
  // put(el, ...kids) — replace EL's children; like add(), skips null/false and flattens arrays.
  const put = (el, ...kids) => { el.replaceChildren(); return add(el, kids); };
  const isTrue = (v) => /^(true|1|yes|y|on)$/i.test(String(v || '').trim());
  const fmtDur = (s) => {
    if (s === null || s === undefined || isNaN(s)) return '';
    s = Math.max(0, Math.round(s));
    if (s < 60) return s + 's';
    const m = Math.floor(s / 60);
    if (m < 60) return m + 'm ' + String(s % 60).padStart(2, '0') + 's';
    return Math.floor(m / 60) + 'h ' + String(m % 60).padStart(2, '0') + 'm';
  };
  const fmtTime = (t) => t ? new Date(t * 1000).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) : '';
  const fmtAgo = (t) => {
    if (!t) return '';
    const s = Date.now() / 1000 - t;
    if (s < 60) return 'just now';
    if (s < 3600) return Math.floor(s / 60) + ' min ago';
    if (s < 86400) return Math.floor(s / 3600) + ' h ago';
    return Math.floor(s / 86400) + ' d ago';
  };
  const fmtSize = (b) => b < 1024 ? b + ' B' : b < 1048576 ? (b / 1024).toFixed(1) + ' KB' : (b / 1048576).toFixed(1) + ' MB';
  const normDomain = (d) => String(d || '').replace(/^https?:\/\//i, '').replace(/\/.*$/, '');
  const basename = (p) => String(p || '').replace(/\/+$/, '').split('/').pop();

  // ---------------------------------------------------------------- api
  let TOKEN = '';
  (function initToken() {
    const m = location.hash.match(/token=([\w-]+)/);
    if (m) {
      TOKEN = m[1];
      try { sessionStorage.setItem('ums-token', TOKEN); } catch (e) { /* private mode */ }
      history.replaceState(null, '', location.pathname + '#/');
    } else {
      try { TOKEN = sessionStorage.getItem('ums-token') || ''; } catch (e) { TOKEN = ''; }
    }
  })();

  async function api(method, path, body) {
    const opts = { method, headers: { 'X-UMS-Token': TOKEN } };
    if (body !== undefined) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(path, opts);
    if (res.status === 401) { showTokenError(); throw new Error('Not authorised'); }
    const ctype = res.headers.get('Content-Type') || '';
    const data = ctype.includes('json') ? await res.json() : await res.text();
    if (!res.ok) {
      const err = new Error((data && data.error) || ('HTTP ' + res.status));
      err.status = res.status;
      throw err;
    }
    return data;
  }
  const P = (id) => '/api/profiles/' + encodeURIComponent(id);

  // ---------------------------------------------------------------- state
  const S = {
    meta: null,
    profiles: [],
    hasDefault: false,
    cache: {},    // id -> profile payload from the server
    drafts: {},   // id -> {values, hooks}
    tests: {},    // id -> {target: {state, results, seconds, output, snapshot}}
    sshKeys: null,
    seq: 0,       // bumps on every navigation; stale async work checks it
    timer: null,
    console: null,
  };

  const schemaSections = () => S.meta.schema.sections;
  const allFields = () => schemaSections().flatMap((s) => s.fields);
  const stepMeta = (id) => (S.meta.schema.steps[id] || {});
  const stepVars = () => {
    const out = new Set();
    for (const m of Object.values(S.meta.schema.steps)) { if (m.skip) out.add(m.skip); if (m.run) out.add(m.run); }
    return out;
  };
  // Keys from .env.example the schema does not place anywhere: shown under Behaviour → Other settings.
  function otherKeys(p) {
    const known = new Set(allFields().map((f) => f.key));
    S.meta.schema.hidden.forEach((k) => known.add(k));
    stepVars().forEach((k) => known.add(k));
    known.add('db_ssh_tunnels');
    const keys = S.meta.example.keys.filter((k) => !known.has(k));
    for (const k of (p && p.present) || []) if (!known.has(k) && !keys.includes(k)) keys.push(k);
    return keys;
  }

  // ---------------------------------------------------------------- drafts
  function deriveAuth(v) {
    if (v.remote_ssh_key) return 'key';
    if (v.remote_ssh_pass) return 'password';
    return v.remote_ssh_host ? 'agent' : 'key';
  }
  function makeDraft(p) {
    return {
      values: Object.assign({}, p.values, { _ssh_auth: deriveAuth(p.values) }),
      hooks: { before: p.hooks.before.content, after: p.hooks.after.content },
    };
  }
  function draft(id) {
    if (!S.drafts[id]) S.drafts[id] = makeDraft(S.cache[id]);
    return S.drafts[id];
  }
  // The values that would be saved: virtual fields removed, auth choice applied.
  function effective(id) {
    const v = Object.assign({}, draft(id).values);
    const auth = v._ssh_auth;
    delete v._ssh_auth;
    if (auth === 'key') v.remote_ssh_pass = '';
    if (auth === 'password') v.remote_ssh_key = '';
    if (auth === 'agent') { v.remote_ssh_key = ''; v.remote_ssh_pass = ''; }
    return v;
  }
  function changes(id) {
    const p = S.cache[id], d = draft(id), v = effective(id);
    const values = {};
    for (const [k, val] of Object.entries(v)) if ((p.values[k] || '') !== (val || '')) values[k] = val;
    const hooks = {};
    for (const n of ['before', 'after']) if ((p.hooks[n].content || '') !== (d.hooks[n] || '')) hooks[n] = d.hooks[n] || '';
    return { values, hooks, count: Object.keys(values).length + Object.keys(hooks).length };
  }
  const anyDirty = () => Object.keys(S.drafts).some((id) => S.cache[id] && changes(id).count > 0);
  window.addEventListener('beforeunload', (e) => { if (anyDirty()) { e.preventDefault(); e.returnValue = ''; } });

  async function loadProfile(id, force) {
    if (!S.cache[id] || force) S.cache[id] = await api('GET', P(id));
    return S.cache[id];
  }
  async function loadProfiles() {
    const r = await api('GET', '/api/profiles');
    S.profiles = r.profiles;
    S.hasDefault = r.has_default;
    renderSidebar();
  }
  async function saveProfile(id) {
    const c = changes(id);
    if (!c.count) return;
    const r = await api('PUT', P(id), { values: c.values, hooks: c.hooks });
    S.cache[id] = r.profile;
    S.drafts[id] = makeDraft(r.profile);
    toast('Saved ' + r.changed.length + ' setting' + (r.changed.length === 1 ? '' : 's') + ' to ' + r.profile.file);
    loadProfiles().catch(() => {});
  }

  // ---------------------------------------------------------------- ui bits
  function toast(msg, bad) {
    const t = h('div', { class: 'toast' + (bad ? ' bad' : ''), role: bad ? 'alert' : 'status' }, msg);
    $('#toasts').append(t);
    setTimeout(() => t.remove(), bad ? 7000 : 3500);
  }
  const fail = (e) => toast(e.message || String(e), true);

  // Info tooltips: any .info button with data-tip (and optional data-key / data-default).
  const tip = $('#tip');
  let tipPinned = null;
  function showTip(btn) {
    tip.replaceChildren(h('div', {}, btn.dataset.tip));
    const meta = [];
    if (btn.dataset.key) meta.push(h('div', {}, '.env key: ', h('code', {}, btn.dataset.key)));
    if (btn.dataset.default !== undefined && btn.dataset.default !== '') meta.push(h('div', {}, 'Default: ', h('code', {}, btn.dataset.default)));
    if (meta.length) tip.append(h('div', { class: 'tip-meta' }, meta));
    tip.hidden = false;
    const r = btn.getBoundingClientRect(), tr = tip.getBoundingClientRect();
    let top = r.bottom + 8, left = r.left + r.width / 2 - tr.width / 2;
    if (top + tr.height > innerHeight - 8) top = r.top - tr.height - 8;
    left = Math.max(16, Math.min(left, innerWidth - tr.width - 16));
    tip.style.top = Math.max(8, top) + 'px';
    tip.style.left = left + 'px';
    btn.setAttribute('aria-expanded', 'true');
    btn.setAttribute('aria-describedby', 'tip');
  }
  function hideTip() {
    tip.hidden = true;
    $$('.info[aria-expanded="true"]').forEach((b) => { b.setAttribute('aria-expanded', 'false'); b.removeAttribute('aria-describedby'); });
    tipPinned = null;
  }
  document.addEventListener('mouseover', (e) => { const b = e.target.closest && e.target.closest('.info'); if (b && !tipPinned) showTip(b); });
  document.addEventListener('mouseout', (e) => { const b = e.target.closest && e.target.closest('.info'); if (b && !tipPinned) hideTip(); });
  document.addEventListener('focusin', (e) => { if (e.target.classList && e.target.classList.contains('info')) showTip(e.target); });
  document.addEventListener('focusout', (e) => { if (e.target.classList && e.target.classList.contains('info') && !tipPinned) hideTip(); });
  document.addEventListener('click', (e) => {
    const b = e.target.closest && e.target.closest('.info');
    if (b) { e.preventDefault(); if (tipPinned === b) hideTip(); else { showTip(b); tipPinned = b; } return; }
    if (tipPinned) hideTip();
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !tip.hidden) hideTip(); });
  window.addEventListener('scroll', () => { if (!tip.hidden) hideTip(); }, true);

  function info(text, key, def) {
    return h('button', { type: 'button', class: 'info', 'aria-label': 'More information', 'aria-expanded': 'false',
      'data-tip': text, 'data-key': key || null, 'data-default': def === undefined ? null : def }, 'i');
  }

  // Modal dialog. build(form, close) fills the form; resolves with close(value).
  function modal(build, wide) {
    const dlg = $('#dialog');
    dlg.className = 'dialog' + (wide ? ' wide' : '');
    return new Promise((resolve) => {
      const form = h('form', { method: 'dialog' });
      let done = false;
      const close = (v) => { if (done) return; done = true; dlg.close(); resolve(v); };
      form.addEventListener('submit', (e) => e.preventDefault());
      dlg.replaceChildren(form);
      build(form, close);
      dlg.onclose = () => { if (!done) { done = true; resolve(undefined); } };
      dlg.showModal();
      const first = form.querySelector('input:not([type=hidden]), textarea, select');
      if (first) first.focus();
    });
  }
  function dialogHead(title, close) {
    return h('div', { class: 'd-head' }, h('h2', {}, title),
      h('button', { type: 'button', class: 'btn ghost small', 'aria-label': 'Close', onclick: () => close() }, '✕'));
  }
  function confirmTyped(title, body, word, action) {
    return modal((form, close) => {
      const input = h('input', { type: 'text', autocomplete: 'off', spellcheck: 'false', 'aria-label': 'Confirmation' });
      const go = h('button', { type: 'submit', class: 'btn danger solid', disabled: true }, action);
      input.addEventListener('input', () => { go.disabled = input.value !== word; });
      go.addEventListener('click', () => { if (input.value === word) close(true); });
      add(form, [dialogHead(title, close), h('p', {}, body),
        h('label', { class: 'field' }, h('span', { class: 'label' }, 'Type ', h('code', {}, word), ' to confirm'), input),
        h('div', { class: 'd-foot' }, h('button', { type: 'button', class: 'btn', onclick: () => close(false) }, 'Cancel'), go)]);
    });
  }
  function copyBtn(text) {
    return h('button', { type: 'button', class: 'btn small', onclick: async (e) => {
      try { await navigator.clipboard.writeText(text); e.target.textContent = 'Copied'; setTimeout(() => { e.target.textContent = 'Copy'; }, 1500); }
      catch (err) { toast('Copy failed: select the text instead', true); }
    } }, 'Copy');
  }
  const cli = (cmd) => h('div', { class: 'cli' }, h('code', {}, cmd), copyBtn(cmd));
  const statusLabel = { ok: 'Succeeded', failed: 'Failed', running: 'Running', interrupted: 'Interrupted', stopped: 'Stopped' };
  const modeLabel = { run: 'Migration', 'dry-run': 'Dry run', check: 'Check' };
  const badge = (status, text) => h('span', { class: 'badge ' + status }, text || statusLabel[status] || status);

  // ---------------------------------------------------------------- theme
  const themes = ['system', 'light', 'dark'];
  function applyTheme(t) {
    if (t === 'system') document.documentElement.removeAttribute('data-theme');
    else document.documentElement.setAttribute('data-theme', t);
    $('#theme-label').textContent = 'Theme: ' + t;
  }
  let theme = 'system';
  try { theme = localStorage.getItem('ums-theme') || 'system'; } catch (e) { /* ignore */ }
  applyTheme(theme);
  $('#theme-btn').addEventListener('click', () => {
    theme = themes[(themes.indexOf(theme) + 1) % themes.length];
    try { localStorage.setItem('ums-theme', theme); } catch (e) { /* ignore */ }
    applyTheme(theme);
  });

  // ---------------------------------------------------------------- sidebar
  function renderSidebar() {
    const cur = route().id;
    const list = $('#profile-list');
    list.replaceChildren(...S.profiles.map((p) => {
      const st = p.last_run ? p.last_run.status : '';
      return h('a', { class: 'profile-link', href: '#/m/' + p.id, 'aria-current': p.id === cur ? 'page' : null },
        h('span', { class: 'dot ' + st, title: st ? 'Last run: ' + (statusLabel[st] || st) : 'No runs yet' }),
        h('span', { class: 'pname' }, p.id === 'default' ? 'default (.env)' : p.id),
        h('span', { class: 'psub' }, p.local_domain || p.remote_domain || 'not configured yet'));
    }));
    if (!S.profiles.length) list.append(h('div', { class: 'muted small', style: 'padding:0.3rem 0.6rem' }, 'None yet'));
    $('#guide-link').setAttribute('aria-current', route().view === 'guide' ? 'page' : 'false');
  }

  // ---------------------------------------------------------------- router
  function route() {
    const parts = location.hash.replace(/^#\/?/, '').split('/').map(decodeURIComponent);
    if (parts[0] === 'm' && parts[1]) return { view: parts[2] || 'overview', id: parts[1], sub: parts[3] || '' };
    if (parts[0] === 'guide') return { view: 'guide', sub: parts[1] || '' };
    if (parts[0] === 'new') return { view: 'new' };
    return { view: 'home' };
  }
  const go = (hash) => { if (location.hash === hash) render(); else location.hash = hash; };
  window.addEventListener('hashchange', render);

  async function render() {
    const seq = ++S.seq;
    clearTimeout(S.timer);
    hideTip();
    const r = route();
    renderSidebar();
    const main = $('#main');
    try {
      if (r.view === 'home') {
        if (S.profiles.length) return go('#/m/' + S.profiles[0].id);
        return show(viewNew(true));
      }
      if (r.view === 'new') return show(viewNew(false));
      if (r.view === 'guide') { show(viewGuide()); if (r.sub) { const t = document.getElementById('g-' + r.sub); if (t) t.scrollIntoView(); } return; }
      await loadProfile(r.id, true); // cheap, and picks up hand edits and finished runs
      if (seq !== S.seq) return;
      const views = { overview: viewOverview, setup: viewSetup, steps: viewSteps, runs: viewRuns, logs: viewLogs };
      const fn = views[r.view];
      if (!fn) return go('#/m/' + r.id);
      const page = await fn(r.id, r.sub, seq);
      if (seq !== S.seq) return;
      show(page);
    } catch (e) {
      if (seq !== S.seq) return;
      show(h('div', { class: 'page' }, h('div', { class: 'callout bad' }, h('strong', {}, 'Something went wrong'), h('span', {}, e.message)),
        h('div', {}, h('a', { class: 'btn', href: '#/' }, 'Back to start'))));
    }
    function show(page) {
      main.replaceChildren(page);
      if (!['setup', 'steps'].includes(r.view) || !r.sub) main.scrollTop = 0;
      window.scrollTo(0, 0);
    }
  }

  function showTokenError() {
    $('#main').replaceChildren(h('div', { class: 'page' }, h('div', { class: 'hero' },
      h('h1', {}, 'Open the link from the terminal'),
      h('p', {}, 'This page needs the access token that ./gui.sh prints when it starts (the part after #token=). It changes every time the GUI starts, so other websites cannot talk to it.'),
      h('div', { class: 'cli' }, h('code', {}, './gui.sh')))));
  }

  // ---------------------------------------------------------------- migration header + tabs
  function header(id, tab, extraActions) {
    const p = S.cache[id];
    const tabs = [['overview', 'Overview'], ['setup', 'Setup'], ['steps', 'Steps & hooks'], ['runs', 'Runs'], ['logs', 'Log files']];
    return [
      h('div', { class: 'head' },
        h('div', { class: 'head-title' },
          h('div', { class: 'eyebrow' }, 'Migration'),
          h('h1', {}, id === 'default' ? 'default' : id),
          h('div', { class: 'muted small' }, h('code', {}, p.file), p.running ? [' · ', h('a', { href: '#/m/' + id + '/runs/' + p.running }, badge('running', 'Running now'))] : null)),
        h('div', { class: 'head-actions' }, extraActions || runButtons(id))),
      h('nav', { class: 'tabs', 'aria-label': 'Migration sections' }, tabs.map(([k, label]) =>
        h('a', { href: '#/m/' + id + '/' + k, 'aria-current': tab === k ? 'page' : null }, label))),
    ];
  }
  function runButtons(id) {
    const p = S.cache[id];
    if (p.running) return [h('a', { class: 'btn primary', href: '#/m/' + id + '/runs/' + p.running }, 'View progress')];
    return [
      h('button', { type: 'button', class: 'btn', onclick: () => startRunDialog(id, 'check') }, 'Check everything'),
      h('button', { type: 'button', class: 'btn', onclick: () => startRunDialog(id, 'dry-run') }, 'Dry run'),
      h('button', { type: 'button', class: 'btn primary', onclick: () => startRunDialog(id, 'run') }, 'Run migration ▸'),
    ];
  }

  // ---------------------------------------------------------------- new / welcome
  function viewNew(welcome) {
    const name = h('input', { type: 'text', placeholder: 'client-site', autocomplete: 'off', spellcheck: 'false', pattern: '[a-z0-9][a-z0-9_-]*', 'aria-describedby': 'name-hint' });
    const asDefault = h('input', { type: 'checkbox', checked: !S.hasDefault, disabled: S.hasDefault });
    const copyFrom = h('select', {}, h('option', { value: '' }, 'Start from .env.example (blank)'),
      S.profiles.map((p) => h('option', { value: p.id }, 'Copy settings from ' + p.id)));
    const btn = h('button', { type: 'submit', class: 'btn primary' }, 'Create and start setup ▸');
    const syncName = () => { name.disabled = asDefault.checked; if (asDefault.checked) name.value = ''; };
    asDefault.addEventListener('change', syncName);
    syncName();
    const form = h('form', { class: 'card stack', onsubmit: async (e) => {
      e.preventDefault();
      btn.disabled = true;
      try {
        const r = await api('POST', '/api/profiles', { name: name.value.trim().toLowerCase(), default: asDefault.checked, copy_from: copyFrom.value || null });
        await loadProfiles();
        toast('Created ' + (r.id === 'default' ? '.env' : 'sites/' + r.id + '.env'));
        go('#/m/' + r.id + '/setup/remote');
      } catch (err) { fail(err); btn.disabled = false; }
    } },
      h('h2', {}, welcome ? 'Create your first migration' : 'New migration'),
      h('p', { class: 'muted' }, 'A migration is one env file: one remote site copied to one local site. You can have as many as you like.'),
      h('div', { class: 'fields' },
        h('label', { class: 'field' }, h('span', { class: 'label' }, 'Name', info('Lowercase letters, numbers, - and _. Saved as sites/<name>.env and used with ./migrate.sh --env sites/<name>.env.')), name,
          h('span', { class: 'field-hint', id: 'name-hint' }, 'e.g. acme-shop, client-blog')),
        h('div', { class: 'field' }, h('span', { class: 'label' }, 'Start from', info('Copying is handy for a second environment of the same site (staging vs production): only change what differs.')), copyFrom)),
      h('label', { class: 'switch' }, asDefault, h('span', { class: 'track' }),
        h('span', { class: 's-text' }, 'Save as the default ', h('code', {}, '.env'), S.hasDefault ? ' (already exists)' : ' — what ./migrate.sh uses without --env')),
      h('div', { class: 'row' }, btn));
    const page = h('div', { class: 'page' });
    if (welcome) {
      page.append(h('div', { class: 'hero' },
        h('div', { class: 'eyebrow' }, 'universal-migrate-site-script ' + S.meta.version),
        h('h1', {}, 'Copy a live WordPress or Laravel site to this machine'),
        h('p', {}, 'This GUI writes the .env file for you, checks the SSH and database logins before anything runs, and shows each step of the migration as it happens, with the full log of every run.'),
        h('div', { class: 'steps-mini' },
          h('div', {}, h('b', {}, 'Describe the servers'), 'Remote SSH + database, local folder + database. Every field has an ⓘ explaining it.'),
          h('div', {}, h('b', {}, 'Test the connections'), 'One click checks SSH, the remote DB and the local DB with the values on screen.'),
          h('div', {}, h('b', {}, 'Choose what runs'), 'Turn steps on or off and add your own before/after hooks.'),
          h('div', {}, h('b', {}, 'Run and watch'), 'Live progress per step, the console, and logs for every run.')),
        h('div', { class: 'row' }, h('a', { href: '#/guide', class: 'btn' }, 'Read the user guide'))));
    }
    page.append(form);
    return page;
  }

  // ---------------------------------------------------------------- flow diagram
  function flowDiagram(id) {
    const v = effective(id), t = S.tests[id] || {};
    const st = (k) => (t[k] && t[k].state) || '';
    const val = (x, empty) => x ? x : h('span', { class: 'n-empty' }, empty || 'not set');
    const linkCls = (...ks) => ks.some((k) => st(k) === 'fail') ? 'fail' : ks.every((k) => st(k) === 'ok') ? 'ok' : '';
    const tunnel = v.db_export_method !== 'remote';
    const remoteUrl = v.remote_domain ? (v.remote_scheme || 'https') + '://' + normDomain(v.remote_domain) : '';
    const localUrl = v.local_domain ? (v.local_scheme || 'https') + '://' + normDomain(v.local_domain) : '';
    const node = (cls, title, dot, main, sub) => h('div', { class: 'node ' + cls },
      h('div', { class: 'n-title' }, dot ? h('span', { class: 'dot ' + dot }) : null, title), h('div', { class: 'n-main' }, main), sub ? h('div', { class: 'n-sub' }, sub) : null);
    return h('div', { class: 'flow', role: 'img', 'aria-label': 'Diagram: files and database flow from the remote server to this machine' },
      node('remote', 'Remote server', st('ssh'), val(v.remote_ssh_host ? (v.remote_ssh_user || '?') + '@' + v.remote_ssh_host + (v.remote_ssh_port && v.remote_ssh_port !== '22' ? ':' + v.remote_ssh_port : '') : '', 'host not set'),
        [val(v.remote_ssh_web_root, 'web root not set'), remoteUrl ? ' · ' + remoteUrl : '']),
      h('div', { class: 'link ' + linkCls('ssh') }, h('span', { class: 'l-label' }, 'Files'), h('span', { class: 'arrow' }),
        h('span', {}, 'rsync over SSH · ' + ({ full: 'everything', code: 'code only', uploads: 'uploads only' }[v.sync_mode] || v.sync_mode))),
      node('local', 'This machine', st('local-root'), val(v.local_web_root, 'local web root not set'), localUrl || null),
      node('remote', 'Remote database', st('remote-db'), val(v.export_db_name ? v.export_db_name : '', 'name not set'),
        (v.export_db_user || '?') + ' @ ' + (v.export_db_host || '127.0.0.1') + ':' + (v.export_db_port || '3306') + ' (as seen from the server)'),
      h('div', { class: 'link ' + linkCls('remote-db', 'local-db') }, h('span', { class: 'l-label' }, tunnel ? 'SSH tunnel' : 'Dump on server'), h('span', { class: 'arrow' }),
        h('span', {}, tunnel ? 'local mysqldump through ssh -L' : 'mysqldump | gzip over SSH')),
      node('local', 'Local database', st('local-db'), val(v.import_db_name, 'name not set'),
        [(v.import_db_user || '?') + ' @ ' + (v.import_db_host || '127.0.0.1') + ':' + (v.import_db_port || '3306'),
          isTrue(v.local_db_backup) ? ' · backed up first' : ' · NOT backed up', v.db_preserve_tables ? ' · keeps ' + v.db_preserve_tables : '']));
  }
  function rewritePreview(id) {
    const v = effective(id);
    const rd = normDomain(v.remote_domain), ld = normDomain(v.local_domain);
    if (!rd || !ld) return h('p', { class: 'muted small' }, 'Fill in both domains to see how URLs will be rewritten.');
    const rs = v.remote_scheme || 'https', ls = v.local_scheme || 'https';
    const rows = [];
    const bare = rd.replace(/^www\./, '');
    if (isTrue(v.replace_www_variant) && !rd.startsWith('www.')) rows.push(['www.' + rd, ld]);
    if (isTrue(v.replace_www_variant) && rd.startsWith('www.')) rows.push([bare, ld]);
    rows.unshift([rd, ld]);
    if (rs !== ls) rows.push([rs + '://' + ld, ls + '://' + ld]);
    return h('div', { class: 'rewrite' }, rows.map(([a, b]) => h('div', {}, h('span', { class: 'from' }, a), '→', h('span', { class: 'to' }, b))),
      h('div', { class: 'muted', style: 'font-family:var(--font-body)' }, 'WordPress: wp search-replace in every table (serialized data safe). Laravel: APP_URL in .env.'));
  }

  // ---------------------------------------------------------------- connection tests
  async function runTests(id, targets, onChange) {
    const t = S.tests[id] = S.tests[id] || {};
    const values = effective(id);
    const snapshot = JSON.stringify(values);
    targets.forEach((k) => { t[k] = Object.assign({}, t[k], { state: 'running' }); });
    onChange();
    // SSH first: the database tunnel depends on it, and failures are clearer one at a time.
    for (const k of targets) {
      try {
        const r = await api('POST', P(id) + '/test', { targets: [k], values });
        const levels = r.results.map((x) => x.level);
        t[k] = { state: levels.includes('fail') || !r.ok ? 'fail' : levels.includes('warn') ? 'warn' : 'ok', results: r.results, seconds: r.seconds, output: r.output, snapshot };
        if (!r.results.length && !r.ok) t[k].results = [{ level: 'fail', message: (r.output || '').trim().split('\n').pop() || 'Failed' }];
      } catch (e) {
        t[k] = { state: 'fail', results: [{ level: 'fail', message: e.message }], snapshot };
      }
      onChange();
    }
  }
  function testPanel(id, targets, title) {
    const box = h('div', { class: 'tests' });
    const meta = S.meta.schema.tests;
    const draw = () => {
      const t = S.tests[id] || {};
      const snap = JSON.stringify(effective(id));
      put(box, [
        h('div', { class: 'row' }, h('h3', {}, title || 'Check before you continue'),
          info('Tests use the values on screen, saved or not. They only read: nothing is changed on either server.'),
          h('span', { class: 'spacer' }),
          targets.length > 1 ? h('button', { type: 'button', class: 'btn small', onclick: () => runTests(id, targets, draw) }, 'Test all') : null),
        targets.map((k) => {
          const r = t[k] || {};
          const stale = r.snapshot && r.snapshot !== snap && r.state !== 'running';
          const icon = { ok: '✓', fail: '✕', warn: '!', info: 'i' };
          return h('div', { class: 'test' },
            h('div', { class: 'test-head' },
              h('span', { class: 'dot ' + (r.state === 'running' ? 'running' : r.state || '') }),
              h('span', { class: 't-name' }, meta[k].label), info(meta[k].help),
              r.state && r.state !== 'running' ? badge(r.state === 'fail' ? 'failed' : r.state, { ok: 'Passed', fail: 'Failed', warn: 'Passed with warnings' }[r.state]) : null,
              r.seconds !== undefined && r.state !== 'running' ? h('span', { class: 't-time' }, r.seconds + 's') : null,
              stale ? h('span', { class: 'field-hint warn' }, 'values changed since this test') : null,
              h('span', { class: 'spacer' }),
              h('button', { type: 'button', class: 'btn small', disabled: r.state === 'running', onclick: () => runTests(id, [k], draw) },
                r.state === 'running' ? [h('span', { class: 'spin' }), 'Testing…'] : r.state ? 'Test again' : 'Test')),
            r.results && r.results.length && r.state !== 'running' ? h('div', { class: 'test-lines' }, r.results.map((x) =>
              h('div', { class: 'lvl-' + x.level }, h('span', { 'aria-hidden': 'true' }, icon[x.level] || '·'), h('span', {}, x.message)))) : null,
            r.state === 'fail' ? testAdvice(k, r) : null);
        })]);
    };
    draw();
    box._redraw = draw;
    return box;
  }
  // A hint for the most common failure messages.
  function testAdvice(k, r) {
    const text = (r.results || []).map((x) => x.message).join(' ') + ' ' + (r.output || '');
    const tips = [
      [/Permission denied/i, 'The server rejected the login. Check the user, the key (the private one, not .pub) or the password. For keys, ssh-copy-id or your host\'s dashboard adds the public key to the server.'],
      [/Could not resolve hostname|Name or service not known/i, 'The SSH host name does not resolve. Check for typos, or use the IP address.'],
      [/Connection timed out|Operation timed out|No route to host/i, 'Nothing answered on that host/port. Check the port, and that your IP is allowed by the host\'s firewall.'],
      [/Connection refused/i, 'The host is up but nothing listens on that port. SSH is often on a custom port with managed hosts.'],
      [/Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED/i, 'The server\'s key does not match ~/.ssh/known_hosts. If the server was rebuilt, remove the old line with ssh-keygen -R <host>.'],
      [/UNPROTECTED PRIVATE KEY|bad permissions/i, 'The key file is readable by others. Run chmod 600 on it.'],
      [/remote_ssh_key not found/i, 'The key path does not exist on this machine.'],
      [/missing: sshpass/i, 'Password login needs sshpass. Install it, or switch to a key.'],
      [/Access denied for user/i, 'The database rejected the user or password. Copy them again from wp-config.php / .env on the server.'],
      [/Unknown database/i, 'That database name does not exist on the server.'],
      [/Can't connect to (local )?MySQL server|Connection refused.*3306|ERROR 2002|ERROR 2003/i, 'No database server answered at that host/port. Locally: is MySQL/MariaDB (or the Docker container) running? Remotely: the host is as seen from the server.'],
      [/SSL|TLS/i, 'An SSL handshake problem. Set the client SSL flag (advanced) to --skip-ssl for a MariaDB client or --ssl-mode=DISABLED for a MySQL client.'],
      [/tunnel/i, 'The SSH tunnel did not come up. The server may forbid TCP forwarding: switch the export method to "Dump on the server".'],
      [/Remote web root not found/i, 'SSH works, but the remote web root path does not exist. SSH in and run pwd inside the site folder.'],
    ];
    const hit = tips.find(([rx]) => rx.test(text));
    return hit ? h('div', { class: 'callout warn small' }, h('strong', {}, 'Likely cause'), h('span', {}, hit[1])) : null;
  }

  // ---------------------------------------------------------------- form fields
  function fieldVisible(id, f) {
    const v = draft(id).values;
    if (f.when) for (const [k, want] of Object.entries(f.when)) if ((v[k] || '') !== want) return false;
    if (f.when_filled && !v[f.when_filled]) return false;
    return true;
  }
  function fieldEl(id, f, onChange) {
    const d = draft(id);
    const def = S.meta.example.defaults[f.key];
    const set = (val) => { d.values[f.key] = val; onChange(f.key); };
    const inputId = 'f-' + f.key;
    const label = h('label', { class: 'label', for: inputId }, f.label, f.required ? h('span', { class: 'req', title: 'Required' }, '*') : null,
      info(f.help || S.meta.example.comments[f.key] || '', f.virtual ? null : f.key, f.virtual ? undefined : def),
      f.virtual ? null : h('span', { class: 'key' }, f.key));
    let control, hint = null;
    const val = d.values[f.key] === undefined ? '' : d.values[f.key];
    const opts = (f.options || []).map((o) => typeof o === 'string' ? { value: o, label: o === '' ? '(leave as is)' : o } : o);
    if (f.type === 'choice') {
      control = h('div', { class: 'choice', role: 'radiogroup', 'aria-label': f.label }, opts.map((o) =>
        h('label', {}, h('input', { type: 'radio', name: inputId, value: o.value, checked: val === o.value, onchange: () => set(o.value) }),
          h('span', { class: 'c-title' }, o.label), o.hint ? h('span', { class: 'c-hint' }, o.hint) : null)));
      label.removeAttribute('for');
    } else if (f.type === 'select') {
      if (!opts.some((o) => o.value === val)) opts.push({ value: val, label: val + ' (current)' });
      control = h('select', { id: inputId, onchange: (e) => set(e.target.value) }, opts.map((o) => h('option', { value: o.value, selected: o.value === val }, o.label)));
    } else if (f.type === 'bool') {
      control = h('label', { class: 'switch' }, h('input', { type: 'checkbox', id: inputId, checked: isTrue(val), onchange: (e) => set(e.target.checked ? 'true' : 'false') }),
        h('span', { class: 'track' }), h('span', { class: 's-text' }, isTrue(val) ? 'On' : 'Off'));
      control.querySelector('input').addEventListener('change', (e) => { control.querySelector('.s-text').textContent = e.target.checked ? 'On' : 'Off'; });
    } else if (f.type === 'password') {
      const input = h('input', { type: 'password', id: inputId, value: val, autocomplete: 'new-password', spellcheck: 'false', oninput: (e) => set(e.target.value) });
      control = h('div', { class: 'input-wrap' }, input, h('button', { type: 'button', class: 'reveal', 'aria-label': 'Show password', onclick: (e) => {
        const show = input.type === 'password';
        input.type = show ? 'text' : 'password';
        e.target.textContent = show ? 'Hide' : 'Show';
      } }, 'Show'));
    } else {
      const input = h('input', { type: f.type === 'number' ? 'text' : 'text', inputmode: f.type === 'number' ? 'numeric' : null, id: inputId, value: val,
        placeholder: f.placeholder || def || '', spellcheck: 'false', autocomplete: 'off', list: f.type === 'sshkey' ? 'ssh-keys' : null });
      hint = h('span', { class: 'field-hint' });
      const check = () => {
        const x = input.value.trim();
        hint.textContent = ''; hint.className = 'field-hint'; input.classList.remove('invalid');
        if (f.type === 'domain' && x && normDomain(x) !== x) hint.textContent = 'Saved as typed; the script uses ' + normDomain(x);
        if (f.type === 'number' && x && !/^\d+$/.test(x)) { hint.textContent = 'Numbers only'; hint.className = 'field-hint bad'; input.classList.add('invalid'); }
        if (/web_root$/.test(f.key) && x && !x.startsWith('/')) { hint.textContent = 'Use an absolute path (starting with /)'; hint.className = 'field-hint bad'; input.classList.add('invalid'); }
        if (f.key === 'local_web_root' && /^\/?[^/]*\/?$/.test(x) && x) { hint.textContent = 'That is a top-level folder: clear-web-root will refuse it'; hint.className = 'field-hint warn'; }
        if (f.type === 'sshkey' && x) {
          if (x.endsWith('.pub')) { hint.textContent = 'That is the PUBLIC key. Use the file without .pub'; hint.className = 'field-hint bad'; input.classList.add('invalid'); }
          const k = (S.sshKeys || []).find((s) => s.path === x || s.path.replace('~', S.meta.home) === x);
          if (k && k.loose) { hint.textContent = 'Permissions are ' + k.mode + '; ssh will refuse it. Run chmod 600 ' + x; hint.className = 'field-hint warn'; }
        }
      };
      input.addEventListener('input', () => { set(input.value); check(); });
      check();
      control = input;
      if (f.type === 'sshkey') {
        const dl = h('datalist', { id: 'ssh-keys' });
        const fill = () => dl.replaceChildren(...(S.sshKeys || []).map((k) => h('option', { value: k.path }, k.loose ? 'permissions ' + k.mode : '')));
        if (S.sshKeys) fill(); else api('GET', '/api/ssh-keys').then((r) => { S.sshKeys = r.keys; fill(); check(); }).catch(() => {});
        control = h('div', { class: 'stack', style: 'gap:0.3rem' }, input, dl,
          h('span', { class: 'field-hint' }, 'Keys found in ~/.ssh appear as suggestions.'));
      }
    }
    return h('div', { class: 'field' + (f.type === 'choice' ? ' wide' : ''), 'data-key': f.key, hidden: !fieldVisible(id, f) }, label, control, hint);
  }

  // ---------------------------------------------------------------- overview
  function sectionMissing(id, sec) {
    return sec.fields.filter((f) => f.required && fieldVisible(id, f) && !String(draft(id).values[f.key] || '').trim());
  }
  async function viewOverview(id, sub, seq) {
    const p = S.cache[id];
    const runs = await api('GET', P(id) + '/runs').catch(() => ({ runs: [] }));
    if (seq !== S.seq) return h('div');
    const c = changes(id);
    const testsBox = testPanel(id, ['ssh', 'remote-db', 'local-db', 'local-root', 'tools'], 'Connections');
    const diagram = h('div', {}, flowDiagram(id));
    const readiness = schemaSections().map((sec) => {
      const missing = sectionMissing(id, sec);
      return h('a', { class: 'row', href: '#/m/' + id + '/setup/' + sec.id, style: 'text-decoration:none;color:inherit' },
        h('span', { class: 'dot ' + (missing.length ? 'warn' : 'ok') }), h('span', {}, sec.title),
        h('span', { class: 'muted small' }, missing.length ? missing.length + ' required field' + (missing.length > 1 ? 's' : '') + ' missing: ' + missing.map((f) => f.label).join(', ') : 'complete'));
    });
    const recent = runs.runs.slice(0, 5);
    const page = h('div', { class: 'page' }, header(id, 'overview'),
      !p.source_ok ? h('div', { class: 'callout bad' }, h('strong', {}, 'This env file has a shell syntax error'), h('span', {}, 'bash could not load ' + p.file + ' cleanly; some values may be missing. Open it in an editor and check the quotes.')) : null,
      c.count ? h('div', { class: 'callout warn' }, h('strong', {}, c.count + ' unsaved change' + (c.count > 1 ? 's' : '')), h('span', {}, 'Runs use the saved file. ', h('a', { href: '#/m/' + id + '/setup/review' }, 'Review and save'))) : null,
      h('div', { class: 'card' }, h('div', { class: 'card-head' }, h('h2', {}, 'What this migration does'), h('a', { class: 'btn small', href: '#/m/' + id + '/setup/remote' }, 'Edit setup')),
        diagram, h('div', { style: 'margin-top:1rem' }, h('h3', {}, 'URL rewrite'), h('div', { style: 'margin-top:0.5rem' }, rewritePreview(id)))),
      h('div', { class: 'grid-2' },
        h('div', { class: 'card stack' }, testsBox),
        h('div', { class: 'card stack' }, h('h3', {}, 'Setup checklist'), readiness,
          h('div', { class: 'muted small' }, 'Turn steps on or off and add before/after hooks in ', h('a', { href: '#/m/' + id + '/steps' }, 'Steps & hooks'), '.'))),
      h('div', { class: 'card' }, h('div', { class: 'card-head' }, h('h2', {}, 'Recent runs'), h('a', { class: 'btn small', href: '#/m/' + id + '/runs' }, 'All runs')),
        recent.length ? runsTable(id, recent) : h('div', { class: 'empty' }, h('span', {}, 'No runs yet. Test the connections, then try a dry run: it shows what would happen without changing anything.'))),
      h('div', { class: 'card stack' }, h('h2', {}, 'Same thing from a terminal'),
        h('p', { class: 'muted small' }, 'The GUI only edits the env file and calls migrate.sh, so everything here also works without it.'),
        cli(p.cli + ' --check'), cli(p.cli + ' --dry-run'), cli(p.cli), cli(p.cli + ' --yes --only migrate-db,app-config,cache-refresh')),
      h('div', { class: 'card stack' }, h('h2', {}, 'Danger zone'),
        h('div', { class: 'row' }, h('span', { class: 'muted' }, 'Delete ', h('code', {}, p.file), '. Logs, dumps and hook scripts are kept.'), h('span', { class: 'spacer' }),
          h('button', { type: 'button', class: 'btn danger', onclick: async () => {
            const ok = await confirmTyped('Delete this migration?', 'This deletes ' + p.file + ' with its credentials. It cannot be undone.', id, 'Delete');
            if (!ok) return;
            try { await api('DELETE', P(id), { confirm: id }); delete S.cache[id]; delete S.drafts[id]; await loadProfiles(); toast('Deleted ' + p.file); go('#/'); } catch (e) { fail(e); }
          } }, 'Delete migration'))));
    // Keep the diagram's test dots in sync with the test panel.
    const obs = new MutationObserver(() => diagram.replaceChildren(flowDiagram(id)));
    obs.observe(testsBox, { childList: true });
    if (p.running) pollOverview(id, seq);
    return page;
  }
  function pollOverview(id, seq) {
    S.timer = setTimeout(async () => {
      if (seq !== S.seq) return;
      const p = await loadProfile(id, true).catch(() => null);
      if (seq !== S.seq) return;
      if (p && !p.running) { loadProfiles().catch(() => {}); render(); } else pollOverview(id, seq);
    }, 4000);
  }

  // ---------------------------------------------------------------- setup wizard
  function wizardSteps() { return schemaSections().map((s) => ({ id: s.id, title: s.title })).concat([{ id: 'review', title: 'Review & save' }]); }
  function viewSetup(id, sub) {
    const steps = wizardSteps();
    const cur = steps.find((s) => s.id === sub) ? sub : steps[0].id;
    const idx = steps.findIndex((s) => s.id === cur);
    const savebar = h('div', { class: 'savebar', hidden: true });
    const stepper = h('nav', { class: 'stepper', 'aria-label': 'Setup steps' });
    const drawStepper = () => stepper.replaceChildren(...steps.map((s, i) => {
      const sec = schemaSections().find((x) => x.id === s.id);
      const missing = sec ? sectionMissing(id, sec).length : 0;
      const tests = sec ? sec.tests.map((k) => (S.tests[id] || {})[k]).filter(Boolean) : [];
      const cls = sec ? (missing ? 'todo' : 'done') : '';
      return h('a', { href: '#/m/' + id + '/setup/' + s.id, class: cls, 'aria-current': s.id === cur ? 'step' : null,
        title: missing ? missing + ' required field(s) missing' : '' },
        h('span', { class: 'num' }, missing || !sec ? String(i + 1) : '✓'), s.title,
        tests.some((t) => t.state === 'fail') ? h('span', { class: 'dot fail', title: 'A test failed' }) : tests.length && tests.every((t) => t.state === 'ok') ? h('span', { class: 'dot ok', title: 'Tests passed' }) : null);
    }));
    let dynamic = () => {};
    const onChange = (key) => {
      // show/hide dependent fields, refresh the save bar, stepper and visual helpers
      const sec = schemaSections().find((x) => x.id === cur);
      if (sec) for (const f of sec.fields) { const el = $('[data-key="' + f.key + '"]', body); if (el) el.hidden = !fieldVisible(id, f); }
      drawSavebar(); drawStepper(); dynamic(key);
    };
    const drawSavebar = () => {
      const c = changes(id);
      savebar.hidden = !c.count;
      savebar.replaceChildren(h('span', {}, h('strong', {}, c.count + ' unsaved change' + (c.count === 1 ? '' : 's')), ' · tests use them already, runs need them saved'),
        h('span', { class: 'spacer' }),
        h('button', { type: 'button', class: 'btn ghost', onclick: () => { delete S.drafts[id]; render(); } }, 'Discard'),
        h('button', { type: 'button', class: 'btn primary', onclick: async () => { try { await saveProfile(id); render(); } catch (e) { fail(e); } } }, 'Save to ' + S.cache[id].file));
    };
    const body = h('div', { class: 'card stack' });
    if (cur === 'review') {
      add(body, reviewSection(id));
    } else {
      const sec = schemaSections().find((x) => x.id === cur);
      const plat = draft(id).values.platform;
      const fieldsFor = (list) => list.filter((f) => !f.platform || plat === 'auto' || f.platform === plat);
      let basic = fieldsFor(sec.fields.filter((f) => !f.advanced));
      let adv = fieldsFor(sec.fields.filter((f) => f.advanced));
      if (sec.id === 'behaviour') adv = adv.concat(otherKeys(S.cache[id]).map((k) => ({ key: k, label: k, type: 'text', help: S.meta.example.comments[k] || 'Not described in .env.example.' })));
      body.append(h('div', { class: 'stack', style: 'gap:0.35rem' }, h('h2', {}, sec.title), h('p', { class: 'lede' }, sec.lede)));
      if (sec.id === 'app') {
        const wp = basic.filter((f) => f.platform === 'wordpress'), lv = basic.filter((f) => f.platform === 'laravel');
        if (plat === 'auto') body.append(h('div', { class: 'callout' }, 'Platform is set to Detect, so both WordPress and Laravel settings are shown. Only the detected platform\'s settings are used.'));
        if (wp.length) body.append(h('h3', {}, 'WordPress'), h('div', { class: 'fields' }, wp.map((f) => fieldEl(id, f, onChange))));
        if (lv.length) body.append(h('h3', {}, 'Laravel'), h('div', { class: 'fields' }, lv.map((f) => fieldEl(id, f, onChange))));
      } else {
        body.append(h('div', { class: 'fields' }, basic.map((f) => fieldEl(id, f, onChange))));
      }
      if (adv.length) body.append(h('details', { class: 'advanced' }, h('summary', {}, 'Advanced (' + adv.length + ')'), h('div', { class: 'fields' }, adv.map((f) => fieldEl(id, f, onChange)))));
      // Visual helpers per section
      const helper = h('div', {});
      const drawHelper = () => {
        if (['remote', 'remote-db', 'local', 'local-db'].includes(sec.id)) helper.replaceChildren(h('h3', { style: 'margin-bottom:0.6rem' }, 'Where things go'), flowDiagram(id));
        if (sec.id === 'remote' || sec.id === 'local') helper.append(h('h3', { style: 'margin:1rem 0 0.5rem' }, 'URL rewrite'), rewritePreview(id));
        if (sec.id === 'remote-db' && draft(id).values.export_db_host && !/^(127\.0\.0\.1|localhost|::1)$/.test(draft(id).values.export_db_host))
          helper.append(h('div', { class: 'callout', style: 'margin-top:0.75rem' }, 'External database host: the tunnel connects from the server to ' + draft(id).values.export_db_host + '. The server must be able to reach it; your machine does not need to.'));
        if (sec.id === 'local-db' && !isTrue(draft(id).values.local_db_backup))
          helper.append(h('div', { class: 'callout warn', style: 'margin-top:0.75rem' }, 'Backup is off: the local database is dropped without a copy.'));
        if (sec.id === 'local' && draft(id).values.rsync_mode === 'mirror')
          helper.append(h('div', { class: 'callout warn', style: 'margin-top:0.75rem' }, 'Mirror deletes local files that do not exist on the server (except excluded paths).'));
      };
      drawHelper();
      if (helper.childNodes.length || ['remote', 'remote-db', 'local', 'local-db'].includes(sec.id)) body.append(h('div', { class: 'card', style: 'box-shadow:none;background:var(--bg)' }, helper));
      let tests = null;
      if (sec.tests.length) { tests = testPanel(id, sec.tests); body.append(tests); }
      dynamic = (key) => {
        drawHelper();
        if (tests) tests._redraw();
        if (key === 'platform' && sec.id === 'app') render();
      };
      if (tests) new MutationObserver(() => { drawHelper(); drawStepper(); }).observe(tests, { childList: true });
    }
    const prev = steps[idx - 1], next = steps[idx + 1];
    const nav = h('div', { class: 'wizard-nav' },
      prev ? h('a', { class: 'btn', href: '#/m/' + id + '/setup/' + prev.id }, '◂ ' + prev.title) : h('span'),
      next ? h('a', { class: 'btn primary', href: '#/m/' + id + '/setup/' + next.id }, next.title + ' ▸') : null);
    drawStepper(); drawSavebar();
    return h('div', { class: 'page' }, header(id, 'setup'), stepper, body, nav, savebar);
  }

  function reviewSection(id) {
    const c = changes(id), v = effective(id), p = S.cache[id];
    const mask = (f, x) => f.type === 'password' ? (x ? '••••••••' : '') : x;
    const rows = schemaSections().map((sec) => h('div', { class: 'stack', style: 'gap:0.4rem' },
      h('div', { class: 'row' }, h('h3', {}, sec.title), h('a', { class: 'btn small ghost', href: '#/m/' + id + '/setup/' + sec.id }, 'Edit')),
      h('div', { class: 'table-wrap' }, h('table', {}, h('tbody', {}, sec.fields.filter((f) => !f.virtual && fieldVisible(id, f) && (v[f.key] || f.required || c.values[f.key] !== undefined)).map((f) =>
        h('tr', {}, h('td', { style: 'width:40%' }, f.label, ' ', h('code', { class: 'muted' }, f.key)),
          h('td', {}, v[f.key] ? h('code', {}, mask(f, v[f.key])) : h('span', { class: f.required ? 'lvl-fail' : 'muted' }, f.required ? 'required' : 'empty'),
            c.values[f.key] !== undefined ? [' ', badge('warn', 'changed')] : null))))))));
    const missing = schemaSections().flatMap((sec) => sectionMissing(id, sec));
    return [
      h('div', { class: 'stack', style: 'gap:0.35rem' }, h('h2', {}, 'Review & save'),
        h('p', { class: 'lede' }, 'Everything below is written to ', h('code', {}, p.file), ' (mode 600, git-ignored). Values are single-quoted so spaces, # and $ survive.')),
      missing.length ? h('div', { class: 'callout warn' }, h('strong', {}, missing.length + ' required field(s) still empty'), h('span', {}, missing.map((f) => f.label).join(', '))) : h('div', { class: 'callout' }, 'All required fields are filled in.'),
      testPanel(id, ['ssh', 'remote-db', 'local-db', 'local-root', 'tools'], 'Final check'),
      rows,
      h('div', { class: 'row' }, h('span', { class: 'muted' }, c.count ? c.count + ' change(s) to save' : 'No unsaved changes'), h('span', { class: 'spacer' }),
        h('button', { type: 'button', class: 'btn primary', disabled: !c.count, onclick: async () => { try { await saveProfile(id); go('#/m/' + id); } catch (e) { fail(e); } } }, 'Save'),
        h('button', { type: 'button', class: 'btn', onclick: async () => { try { await saveProfile(id); startRunDialog(id, 'dry-run'); } catch (e) { fail(e); } } }, c.count ? 'Save and dry run' : 'Dry run')),
    ];
  }

  // ---------------------------------------------------------------- steps & hooks
  const ICONS = { hook: '⚓', trash: '🗑', cone: '🚧', files: '📁', db: '🛢', gear: '⚙', broom: '🧹', plug: '🔌', shield: '🛡', refresh: '↻', check: '✔' };
  const HOOK_TEMPLATES = {
    before: [
      ['Script header', '#!/usr/bin/env bash\n# Runs in $UMS_LOCAL_WEB_ROOT before the first step. A non-zero exit stops the run.\nset -euo pipefail\n'],
      ['Start Docker services', 'docker compose up -d\n'],
      ['Wait for the local database', 'for i in $(seq 1 30); do mysqladmin ping -h 127.0.0.1 --silent && break; sleep 1; done\n'],
      ['Commit local changes first', 'git -C "$UMS_LOCAL_WEB_ROOT" stash push -u -m "before migration $UMS_RUN_TAG" || true\n'],
      ['Notify a webhook', 'curl -fsS -X POST -H "Content-Type: application/json" \\\n  -d "{\\"text\\":\\"Copying $UMS_REMOTE_URL to $UMS_LOCAL_URL\\"}" \\\n  "https://hooks.example.com/your-webhook"\n'],
    ],
    after: [
      ['Script header', '#!/usr/bin/env bash\n# Runs in $UMS_LOCAL_WEB_ROOT after the last step. A non-zero exit marks the run failed.\nset -euo pipefail\n'],
      ['Activate dev plugins (WordPress)', 'wp plugin activate query-monitor --path="$UMS_LOCAL_WEB_ROOT"\n'],
      ['Disable mail (WordPress)', 'wp plugin activate disable-emails --path="$UMS_LOCAL_WEB_ROOT" || true\n'],
      ['Run migrations (Laravel)', 'php artisan migrate --force\n'],
      ['Build front-end assets', 'npm ci && npm run build\n'],
      ['Notify a webhook', 'curl -fsS -X POST -H "Content-Type: application/json" \\\n  -d "{\\"text\\":\\"$UMS_LOCAL_URL is ready (failed steps: ${UMS_FAILED_STEPS:-none})\\"}" \\\n  "https://hooks.example.com/your-webhook"\n'],
    ],
  };
  function stepState(id, stepId, values) {
    const v = values || effective(id);
    const m = stepMeta(stepId), s = S.meta.steps.find((x) => x.id === stepId);
    const plat = v.platform;
    const platOk = s.platforms === 'all' || plat === 'auto' || s.platforms.split(',').includes(plat);
    if (stepId === 'before-run' || stepId === 'after-run') {
      const name = stepId === 'before-run' ? 'before' : 'after';
      const has = values ? !!v[name + '_run_hook'] : !!String(draft(id).hooks[name] || '').trim();
      return { on: has, platOk, kind: 'hook', name };
    }
    const skipped = m.skip && isTrue(v[m.skip]);
    if (s.mode === 'opt-in') return { on: !skipped && isTrue(v[m.run]), platOk, kind: 'opt-in', skipped };
    return { on: !skipped, platOk, kind: 'normal', skipped };
  }
  function viewSteps(id) {
    const d = draft(id);
    const savebar = h('div', { class: 'savebar', hidden: true });
    const drawSavebar = () => {
      const c = changes(id);
      savebar.hidden = !c.count;
      savebar.replaceChildren(h('span', {}, h('strong', {}, c.count + ' unsaved change' + (c.count === 1 ? '' : 's'))), h('span', { class: 'spacer' }),
        h('button', { type: 'button', class: 'btn ghost', onclick: () => { delete S.drafts[id]; render(); } }, 'Discard'),
        h('button', { type: 'button', class: 'btn primary', onclick: async () => { try { await saveProfile(id); render(); } catch (e) { fail(e); } } }, 'Save'));
    };
    const list = h('div', { class: 'pipeline' });
    const draw = () => {
      list.replaceChildren(...S.meta.steps.map((s) => {
        const m = stepMeta(s.id), st = stepState(id, s.id);
        const platBadge = s.platforms === 'all' ? null : h('span', { class: 'badge' + (st.platOk ? '' : ' warn') }, s.platforms.replace(/wordpress/g, 'WordPress').replace(/laravel/g, 'Laravel').replace(',', ' + ') + (st.platOk ? '' : ' only'));
        let ctrl = null;
        if (st.kind !== 'hook') {
          const input = h('input', { type: 'checkbox', checked: st.on, 'aria-label': (st.on ? 'Disable ' : 'Enable ') + m.title, onchange: async (e) => {
            const on = e.target.checked;
            if (st.kind === 'opt-in') {
              if (on && m.danger) {
                const ok = await confirmTyped('Enable ' + m.title + '?', 'With this on, every run deletes everything inside ' + (d.values.local_web_root || 'the local web root') + ' before syncing. Each run still asks you to type the folder name.', 'enable', 'Enable');
                if (!ok) { e.target.checked = false; return; }
              }
              d.values[m.run] = on ? 'true' : 'false';
              if (on && m.skip) d.values[m.skip] = 'false';
            } else {
              d.values[m.skip] = on ? 'false' : 'true';
            }
            draw(); drawSavebar();
          } });
          ctrl = h('label', { class: 'switch' }, input, h('span', { class: 'track' }));
        }
        const note = [];
        if (st.kind === 'opt-in') note.push(h('span', { class: 'badge warn' }, 'opt-in'));
        if (s.id.startsWith('maintenance')) note.push(h('span', { class: 'muted small' }, 'on/off together with the other maintenance step'));
        if (!st.platOk) note.push(h('span', { class: 'muted small' }, 'skipped: platform is ' + d.values.platform));
        const item = h('div', { class: 'pstep' + (st.on && st.platOk ? ' on' : ' off') + (m.danger ? ' danger' : '') },
          h('div', { class: 'p-icon', 'aria-hidden': 'true' }, ICONS[m.icon] || '•'),
          h('div', { class: 'p-body' },
            h('div', { class: 'p-title' }, m.title || s.id, h('span', { class: 'p-id' }, s.id), platBadge, note, info(m.help || s.description, m.skip || m.run || (st.kind === 'hook' ? st.name + '_run_hook' : null))),
            h('div', { class: 'p-desc' }, s.description)),
          h('div', { class: 'p-ctrl' }, ctrl || h('span', { class: 'badge' + (st.on ? ' ok' : '') }, st.on ? 'set' : 'empty')));
        if (st.kind === 'hook') {
          // Typing must not rebuild the list (the textarea would lose focus): update in place.
          item.append(hookEditor(id, st.name, () => {
            const on = stepState(id, s.id).on;
            item.classList.toggle('on', on); item.classList.toggle('off', !on);
            const b = $('.p-ctrl .badge', item);
            b.className = 'badge' + (on ? ' ok' : ''); b.textContent = on ? 'set' : 'empty';
            drawSavebar();
          }));
        }
        return item;
      }));
    };
    draw(); drawSavebar();
    return h('div', { class: 'page' }, header(id, 'steps'),
      h('div', { class: 'card' },
        h('div', { class: 'card-head' }, h('div', { class: 'stack', style: 'gap:0.3rem' }, h('h2', {}, 'What runs, in order'),
          h('p', { class: 'lede' }, 'These switches are saved in the env file (skip_* / run_*), so the command line honours them too. You can still leave steps out of a single run when you start it.'))),
        list),
      h('div', { class: 'card stack' }, h('h3', {}, 'Variables available to hooks'),
        h('div', { class: 'table-wrap' }, h('table', {}, h('tbody', {}, [
          ['UMS_HOOK', 'before or after'], ['UMS_LOCAL_WEB_ROOT', 'local_web_root (also the working directory when it exists)'],
          ['UMS_LOCAL_URL / UMS_REMOTE_URL', 'scheme://domain of each side'], ['UMS_PLATFORM', 'wordpress, laravel or unknown'],
          ['UMS_IMPORT_DB_NAME', 'local database name'], ['UMS_ENV_FILE', 'the env file of this run'], ['UMS_LOG_FILE / UMS_RUN_TAG', 'this run\'s log and id'],
          ['UMS_DRY_RUN', 'true during a dry run (the hook is then only printed, not run)'], ['UMS_FAILED_STEPS', 'after hook: ids of failed steps (with Keep going on)'],
        ].map(([k, v]) => h('tr', {}, h('td', {}, h('code', {}, k)), h('td', { class: 'muted' }, v))))))),
      savebar);
  }
  function hookEditor(id, name, onChange) {
    const d = draft(id), p = S.cache[id], hk = p.hooks[name];
    const ta = h('textarea', { class: 'code', spellcheck: 'false', rows: 7, 'aria-label': name + '-run hook script',
      placeholder: '# Shell commands, run with bash in the local web root.\n# Leave empty to skip this step.', value: d.hooks[name] || '' });
    ta.addEventListener('input', () => { d.hooks[name] = ta.value; onChange(); });
    ta.addEventListener('keydown', (e) => { if (e.key === 'Tab' && !e.shiftKey && !e.ctrlKey) { e.preventDefault(); ta.setRangeText('  ', ta.selectionStart, ta.selectionEnd, 'end'); ta.dispatchEvent(new Event('input')); } });
    const tpl = h('select', { 'aria-label': 'Insert a template', onchange: (e) => {
      const t = HOOK_TEMPLATES[name][e.target.value];
      if (t) { ta.value = (ta.value && !ta.value.endsWith('\n') ? ta.value + '\n' : ta.value) + t[1]; d.hooks[name] = ta.value; onChange(); }
      e.target.value = '';
    } }, h('option', { value: '' }, 'Insert a template…'), HOOK_TEMPLATES[name].map((t, i) => h('option', { value: i }, t[0])));
    const where = hk.kind === 'file' ? 'Saved in ' + hk.file : hk.kind === 'command' ? 'Currently an inline command in the env file; saving moves it to hooks/' + id + '/' + name + '-run.sh' : 'Saved as hooks/' + id + '/' + name + '-run.sh (git-ignored)';
    const wrap = h('div', { class: 'hook-editor' }, ta, h('div', { class: 'row' }, tpl, h('span', { class: 'muted small' }, where)));
    return wrap;
  }

  // ---------------------------------------------------------------- run dialog
  function startRunDialog(id, mode) {
    const p = S.cache[id], v = p.values, c = changes(id);
    let curMode = mode;
    modal((form, close) => {
      const body = h('div', { class: 'stack' });
      const err = h('div', { class: 'callout bad', hidden: true });
      const checks = {};
      const confirmInput = h('input', { type: 'text', autocomplete: 'off', spellcheck: 'false' });
      const cmd = h('code', {});
      const startBtn = h('button', { type: 'submit', class: 'btn primary' });
      const compute = () => {
        const skip = [], withs = [];
        for (const s of S.meta.steps) {
          const cb = checks[s.id];
          if (!cb || cb.disabled) continue;
          const st = stepState(id, s.id, v);
          if (st.kind === 'opt-in') { if (cb.checked && !st.on) withs.push(s.id); if (!cb.checked && st.on) skip.push(s.id); }
          else if (!cb.checked && st.on) skip.push(s.id);
        }
        const clearing = curMode === 'run' && checks['clear-web-root'] && checks['clear-web-root'].checked && !checks['clear-web-root'].disabled;
        return { skip, with: withs, clearing };
      };
      const sync = () => {
        const r = compute();
        let line = p.cli + (curMode === 'check' ? ' --check' : ' --yes' + (curMode === 'dry-run' ? ' --dry-run' : ''));
        if (curMode !== 'check') { if (r.skip.length) line += ' --skip ' + r.skip.join(','); if (r.with.length) line += ' --with ' + r.with.join(','); }
        cmd.textContent = line;
        $('.clear-confirm', body) && ($('.clear-confirm', body).hidden = !r.clearing);
        startBtn.textContent = { run: 'Start migration', 'dry-run': 'Start dry run', check: 'Run checks' }[curMode];
        startBtn.className = 'btn ' + (r.clearing ? 'danger solid' : 'primary');
        startBtn.disabled = r.clearing && confirmInput.value !== basename(v.local_web_root);
      };
      const modes = h('div', { class: 'mode-cards choice', role: 'radiogroup', 'aria-label': 'Run mode' }, [
        ['run', 'Migration', 'Copies files and replaces the local database.'],
        ['dry-run', 'Dry run', 'Shows every command; changes nothing.'],
        ['check', 'Check everything', 'Preflight incl. disk space, then stops.'],
      ].map(([m, t, hint]) => h('label', {}, h('input', { type: 'radio', name: 'mode', value: m, checked: m === curMode, onchange: () => { curMode = m; drawBody(); } }),
        h('span', { class: 'c-title' }, t), h('span', { class: 'c-hint' }, hint))));
      const drawBody = () => {
        body.replaceChildren();
        if (curMode !== 'check') {
          const listEl = h('div', { class: 'checklist' });
          for (const s of S.meta.steps) {
            const st = stepState(id, s.id, v), m = stepMeta(s.id);
            let reason = '';
            if (!st.platOk) reason = s.platforms.replace(',', '/') + ' only';
            else if (st.kind === 'hook' && !st.on) reason = 'no hook set';
            else if (st.skipped) reason = 'turned off in Steps & hooks';
            const disabled = !!reason;
            const cb = checks[s.id] = h('input', { type: 'checkbox', checked: !disabled && st.on, disabled, onchange: sync });
            listEl.append(h('label', { class: disabled ? 'disabled' : '' }, cb, h('span', {}, m.title || s.id, st.kind === 'opt-in' ? h('span', { class: 'muted small' }, ' (opt-in)') : null),
              h('span', { class: 'muted small' }, reason)));
          }
          body.append(h('div', { class: 'stack', style: 'gap:0.4rem' }, h('div', { class: 'label' }, 'Steps for this run', info('Unchecking leaves a step out of this run only (--skip). Checking an opt-in step enables it for this run (--with). To change the defaults, use Steps & hooks.')), listEl));
          body.append(h('div', { class: 'clear-confirm callout bad', hidden: true },
            h('strong', {}, 'Clear local web root is on'), h('span', {}, 'Everything inside ' + v.local_web_root + ' will be deleted before the sync.'),
            h('label', { class: 'field' }, h('span', { class: 'label' }, 'Type ', h('code', {}, basename(v.local_web_root)), ' to confirm'), confirmInput)));
          if (curMode === 'run') body.append(h('div', { class: 'callout warn' }, h('span', {}, 'This replaces the local database ', h('code', {}, v.import_db_name || '?'),
            isTrue(v.local_db_backup) ? ' (a backup is taken first)' : ' (backup is OFF)', ' and updates files in ', h('code', {}, v.local_web_root || '?'), '.')));
        } else {
          body.append(h('p', { class: 'muted' }, 'Runs every preflight check (tools, local folder, SSH, remote web root, both databases, disk space) and writes a log, without touching anything.'));
        }
        body.append(h('div', { class: 'stack', style: 'gap:0.3rem' }, h('div', { class: 'label' }, 'Equivalent command'), h('div', { class: 'cli' }, cmd)));
        sync();
      };
      confirmInput.addEventListener('input', sync);
      startBtn.addEventListener('click', async () => {
        const r = compute();
        startBtn.disabled = true;
        err.hidden = true;
        try {
          const res = await api('POST', P(id) + '/runs', { mode: curMode, skip: r.skip, with: r.with, confirm_clear: r.clearing ? confirmInput.value : undefined });
          close(true);
          S.cache[id].running = res.tag;
          loadProfiles().catch(() => {});
          go('#/m/' + id + '/runs/' + res.tag);
        } catch (e) { err.textContent = e.message; err.hidden = false; startBtn.disabled = false; }
      });
      add(form, [dialogHead({ run: 'Run migration', 'dry-run': 'Dry run', check: 'Check everything' }[mode] + ' · ' + id, close),
        c.count ? h('div', { class: 'callout warn' }, h('strong', {}, 'You have ' + c.count + ' unsaved change(s)'), h('span', {}, 'Runs use the saved env file. '),
          h('div', {}, h('button', { type: 'button', class: 'btn small', onclick: async () => { try { await saveProfile(id); close(); startRunDialog(id, curMode); } catch (e) { fail(e); } } }, 'Save them first'))) : null,
        modes, body, err,
        h('div', { class: 'd-foot' }, h('button', { type: 'button', class: 'btn', onclick: () => close(false) }, 'Cancel'), startBtn)]);
      drawBody();
    });
  }

  // ---------------------------------------------------------------- runs list
  function runsTable(id, runs) {
    return h('div', { class: 'table-wrap' }, h('table', {},
      h('thead', {}, h('tr', {}, h('th', {}, 'Status'), h('th', {}, 'Started'), h('th', {}, 'Type'), h('th', {}, 'Steps'), h('th', {}, 'Duration'), h('th', {}, 'Options'))),
      h('tbody', {}, runs.map((r) => {
        const dur = r.ended ? r.ended - r.started : r.status === 'running' ? Date.now() / 1000 - r.started : null;
        const open = () => go('#/m/' + id + '/runs/' + r.tag);
        return h('tr', { class: 'click', tabindex: '0', onclick: open, onkeydown: (e) => { if (e.key === 'Enter') open(); } },
          h('td', {}, badge(r.status)),
          h('td', { class: 'nowrap' }, h('div', {}, fmtTime(r.started)), h('div', { class: 'muted small' }, fmtAgo(r.started))),
          h('td', {}, modeLabel[r.mode] || r.mode),
          h('td', {}, r.steps.length ? h('div', { class: 'mini-steps', title: r.counts.ok + ' ok, ' + r.counts.failed + ' failed, ' + r.counts.skipped + ' skipped' },
            r.steps.map((s) => h('i', { class: s.state, title: s.id + ': ' + s.state }))) : h('span', { class: 'muted small' }, r.mode === 'check' ? 'preflight' : '—')),
          h('td', { class: 'nowrap' }, fmtDur(dur)),
          h('td', {}, h('code', { class: 'small' }, (r.args || '').replace(/--env \S+ ?/, '') || '—')));
      }))));
  }
  async function viewRuns(id, sub, seq) {
    if (sub) return viewRun(id, sub, seq);
    const r = await api('GET', P(id) + '/runs');
    const page = h('div', { class: 'page' }, header(id, 'runs'),
      h('div', { class: 'card' }, h('div', { class: 'card-head' }, h('h2', {}, 'Run history'),
        h('span', { class: 'muted small' }, 'From ', h('code', {}, r.log_dir + '/*.events'), ' · terminal runs of this env file show up here too')),
        r.runs.length ? runsTable(id, r.runs) : h('div', { class: 'empty' }, h('span', {}, 'No runs yet for this migration.'), h('div', { class: 'row' }, runButtons(id)))));
    if (r.runs.some((x) => x.status === 'running')) S.timer = setTimeout(() => { if (seq === S.seq) render(); }, 3000);
    return page;
  }

  // ---------------------------------------------------------------- run detail (live)
  async function viewRun(id, tag, seq) {
    const run = await api('GET', P(id) + '/runs/' + encodeURIComponent(tag) + '?offset=-1');
    S.console = { tag, text: run.output, offset: run.offset, truncated: run.truncated, status: run.status };
    const headEl = h('div', { class: 'card stack' });
    const timeline = h('div', { class: 'card' });
    const pre = h('div', { class: 'console', tabindex: '0', role: 'log', 'aria-label': 'Run output' });
    const consoleBar = h('div', { class: 'console-bar' });
    let follow = true;
    pre.addEventListener('scroll', () => { follow = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30; });
    const page = h('div', { class: 'page' }, header(id, 'runs'),
      h('div', {}, h('a', { href: '#/m/' + id + '/runs' }, '◂ All runs')), headEl,
      h('div', { class: 'run-grid' }, timeline, h('div', { class: 'card' }, consoleBar, pre)));
    const drawConsole = () => {
      const lines = S.console.text.split('\n').map((l) => { const i = l.lastIndexOf('\r', l.length - 2); return i >= 0 ? l.slice(i + 1) : l; });
      const tail = lines.slice(-4000);
      const frag = document.createDocumentFragment();
      if (S.console.truncated || lines.length > tail.length) frag.append(h('div', { class: 'l-dim' }, '… earlier output hidden; open the full log below …'));
      for (const l of tail) {
        let cls = '';
        if (/^\s*(✅|\[OK\])/.test(l)) cls = 'l-ok';
        else if (/^\s*(❌|\[FAIL\])/.test(l)) cls = 'l-fail';
        else if (/^\s*(⚠️|\[WARN\])/.test(l)) cls = 'l-warn';
        else if (/^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\] /.test(l)) cls = 'l-sec';
        else if (/^-{20,}$|\[dry-run\]/.test(l)) cls = 'l-dim';
        frag.append(h('div', { class: cls }, l || '\u00a0'));
      }
      pre.replaceChildren(frag);
      if (follow) pre.scrollTop = pre.scrollHeight;
    };
    const draw = (r) => {
      const now = r.now || Date.now() / 1000;
      const planned = r.steps.filter((s) => s.planned === 'run');
      const n = Math.max(1, planned.length);
      const cnt = (st) => planned.filter((s) => s.state === st).length;
      const pct = (x) => (100 * x / n) + '%';
      const elapsed = (r.ended || now) - (r.started || now);
      const cur = r.steps.find((s) => s.state === 'running');
      const phase = r.status !== 'running' ? (statusLabel[r.status] || r.status)
        : cur ? 'Step ' + (planned.indexOf(cur) + 1) + ' of ' + planned.length + ': ' + cur.title
        : r.preflight && r.preflight.state === 'running' ? 'Preflight checks'
        : r.steps.length ? 'Finishing' : 'Starting';
      const files = r.files || {};
      const fileBtn = (k, label) => files[k] ? h('button', { type: 'button', class: 'btn small', onclick: () => viewFile(id, P(id) + '/runs/' + encodeURIComponent(tag) + '/files/' + k, files[k].name) },
        label, h('span', { class: 'muted' }, ' ' + fmtSize(files[k].size))) : null;
      put(headEl,
        h('div', { class: 'row' }, badge(r.status), h('h2', {}, (modeLabel[r.mode] || r.mode) + ' · ' + fmtTime(r.started)), h('span', { class: 'spacer' }),
          r.stoppable ? h('button', { type: 'button', class: 'btn danger', onclick: async (e) => {
            e.target.disabled = true;
            try { await api('POST', P(id) + '/runs/' + encodeURIComponent(tag) + '/stop'); toast('Stopping: the script cleans up (tunnel, temp files) and exits'); } catch (err) { fail(err); e.target.disabled = false; }
          } }, 'Stop') : null,
          r.status !== 'running' ? runButtons(id).slice(-1) : null),
        h('div', { class: 'progress', role: 'progressbar', 'aria-valuemin': 0, 'aria-valuemax': planned.length, 'aria-valuenow': cnt('ok') + cnt('failed') + cnt('skipped'), 'aria-label': 'Steps finished' },
          h('span', { class: 'p-ok', style: 'width:' + pct(cnt('ok')) }), h('span', { class: 'p-fail', style: 'width:' + pct(cnt('failed') + cnt('stopped')) }),
          h('span', { class: 'p-skip', style: 'width:' + pct(cnt('skipped')) }), h('span', { class: 'p-run', style: 'width:' + pct(cnt('running')) })),
        h('div', { class: 'stat-row' },
          h('div', { class: 'stat' }, h('span', { class: 's-label' }, 'Now'), h('span', { class: 's-value' }, phase)),
          h('div', { class: 'stat' }, h('span', { class: 's-label' }, 'Elapsed'), h('span', { class: 's-value' }, fmtDur(elapsed))),
          h('div', { class: 'stat' }, h('span', { class: 's-label' }, 'Steps'), h('span', { class: 's-value' }, cnt('ok') + ' ok · ' + (cnt('failed') + cnt('stopped')) + ' failed · ' + (r.steps.length - planned.length + cnt('skipped')) + ' skipped')),
          r.rsync ? h('div', { class: 'stat' }, h('span', { class: 's-label' }, 'Files transferred'), h('span', { class: 's-value' }, r.rsync.files.toLocaleString()),
            r.rsync.last && r.status === 'running' ? h('span', { class: 'muted small mono', style: 'overflow-wrap:anywhere' }, r.rsync.last) : null) : null,
          r.rc !== null ? h('div', { class: 'stat' }, h('span', { class: 's-label' }, 'Exit code'), h('span', { class: 's-value' }, String(r.rc))) : null),
        r.args ? h('div', { class: 'muted small' }, 'Options: ', h('code', {}, r.args.replace(/--env \S+ ?/, '') || '(none)')) : null,
        r.status === 'interrupted' ? h('div', { class: 'callout warn' }, 'The script stopped without writing its final event (killed, or the machine went to sleep). Check the log; the local site may still be in maintenance mode.') : null,
        r.status === 'failed' ? h('div', { class: 'callout bad' }, h('strong', {}, 'The run failed'), h('span', {}, 'The red step in the timeline shows where. Its error is in the console; lines starting with ❌ are the important ones.')) : null,
        h('div', { class: 'file-links' }, fileBtn('log', 'Full log'), fileBtn('report', 'Report'), fileBtn('rsync', 'rsync file list'), fileBtn('events', 'Events')));
      const pf = r.preflight;
      const items = [];
      if (pf || r.checks.length) {
        const fails = r.checks.filter((c) => c.level === 'fail').length, warns = r.checks.filter((c) => c.level === 'warn').length;
        items.push(h('div', { class: 'tl-item ' + (pf ? (pf.state === 'ok' ? 'ok' : pf.state === 'running' ? 'running' : 'failed') : '') },
          h('span', { class: 'tl-mark' }, pf && pf.state === 'ok' ? '✓' : pf && pf.state === 'fail' ? '✕' : ''),
          h('div', {}, h('div', { class: 'tl-title' }, 'Preflight checks'),
            h('details', {}, h('summary', { class: 'tl-sub', style: 'cursor:pointer' }, r.checks.length + ' checks' + (fails ? ', ' + fails + ' failed' : '') + (warns ? ', ' + warns + ' warning(s)' : '')),
              h('div', { class: 'test-lines', style: 'margin-top:0.3rem' }, r.checks.map((c) => h('div', { class: 'lvl-' + c.level }, h('span', {}, { ok: '✓', fail: '✕', warn: '!' }[c.level]), h('span', {}, c.message)))))),
          h('span', { class: 'tl-time' }, pf && pf.ended ? fmtDur(pf.ended - pf.started) : '')));
      }
      r.steps.forEach((s, i) => {
        const time = s.state === 'running' ? fmtDur(now - s.started) : s.elapsed !== null ? fmtDur(s.elapsed) : '';
        const mark = { ok: '✓', failed: '✕', stopped: '✕', skipped: '–', 'not-run': '' }[s.state];
        const sub = s.state === 'skipped' ? s.reason : s.state === 'failed' ? 'exit ' + s.rc : s.state === 'not-run' ? 'not reached' : s.state === 'running' && s.id === 'sync-files' && r.rsync ? r.rsync.files.toLocaleString() + ' files so far' : '';
        items.push(h('div', { class: 'tl-item ' + s.state }, h('span', { class: 'tl-mark' }, mark === undefined ? String(planned.indexOf(s) + 1 || i + 1) : mark),
          h('div', {}, h('div', { class: 'tl-title' }, s.title), sub ? h('div', { class: 'tl-sub' }, sub) : null), h('span', { class: 'tl-time' }, time)));
      });
      if (!items.length) items.push(h('p', { class: 'muted' }, r.status === 'running' ? 'Starting…' : 'This run stopped before any step was planned; see the console.'));
      timeline.replaceChildren(h('h3', { style: 'margin-bottom:0.6rem' }, 'Progress'), h('div', { class: 'timeline' }, items));
      consoleBar.replaceChildren(h('h3', {}, 'Console'), h('div', { class: 'row' },
        h('label', { class: 'switch small' }, h('input', { type: 'checkbox', checked: follow, onchange: (e) => { follow = e.target.checked; if (follow) pre.scrollTop = pre.scrollHeight; } }), h('span', { class: 'track' }), h('span', { class: 's-text small' }, 'Follow'))));
    };
    draw(run);
    drawConsole();
    const poll = async () => {
      if (seq !== S.seq) return;
      try {
        const r = await api('GET', P(id) + '/runs/' + encodeURIComponent(tag) + '?offset=' + S.console.offset);
        if (seq !== S.seq) return;
        if (r.status !== 'running' && S.console.status === 'running') {
          const full = r;
          S.cache[id].running = null;
          loadProfiles().catch(() => {});
          toast((modeLabel[full.mode] || 'Run') + ' ' + (statusLabel[full.status] || full.status).toLowerCase(), full.status !== 'ok');
          render(); // redraw with the final log and the header's run buttons back
          return;
        }
        if (r.output) {
          S.console.text += r.output;
          if (S.console.text.length > 3e6) { S.console.text = S.console.text.slice(-2e6); S.console.truncated = true; }
          drawConsole();
        }
        S.console.offset = r.offset;
        S.console.status = r.status;
        draw(r);
      } catch (e) { /* transient; keep polling */ }
      if (S.console.status === 'running') S.timer = setTimeout(poll, 1000);
    };
    if (run.status === 'running') S.timer = setTimeout(poll, 800);
    return page;
  }

  async function viewFile(id, url, name) {
    let text = '', truncated = false, size = 0;
    try {
      const res = await fetch(url, { headers: { 'X-UMS-Token': TOKEN } });
      if (!res.ok) throw new Error((await res.json()).error);
      text = await res.text();
      truncated = res.headers.get('X-Truncated') === '1';
      size = +res.headers.get('X-File-Size');
    } catch (e) { return fail(e); }
    const filter = h('input', { type: 'search', placeholder: 'Filter lines…', 'aria-label': 'Filter lines' });
    const pre = h('pre', { class: 'viewer' }, text);
    filter.addEventListener('input', () => {
      const q = filter.value.toLowerCase();
      pre.textContent = q ? text.split('\n').filter((l) => l.toLowerCase().includes(q)).join('\n') : text;
    });
    modal((form, close) => add(form, [dialogHead(name, close),
      truncated ? h('div', { class: 'callout warn small' }, 'Showing the last 2 MB of ' + fmtSize(size) + '. Download for the whole file.') : null,
      filter, pre,
      h('div', { class: 'd-foot' }, h('a', { class: 'btn', href: url + (url.includes('?') ? '&' : '?') + 'download=1&token=' + encodeURIComponent(TOKEN) }, 'Download'),
        h('button', { type: 'button', class: 'btn primary', onclick: () => close() }, 'Close'))]), true);
    setTimeout(() => { pre.scrollTop = pre.scrollHeight; }, 0);
  }

  // ---------------------------------------------------------------- log files
  async function viewLogs(id) {
    const r = await api('GET', P(id) + '/logs');
    const kind = (n) => /^migrate-report-/.test(n) ? 'Report' : /^rsync-/.test(n) ? 'rsync file list' : /\.events$/.test(n) ? 'Events' : /^migrate-.*\.log$/.test(n) ? 'Run log' : /^gui-.*\.out$/.test(n) ? 'Live output' : 'Other';
    return h('div', { class: 'page' }, header(id, 'logs'),
      h('div', { class: 'card' }, h('div', { class: 'card-head' }, h('h2', {}, 'Files in ', h('code', {}, r.log_dir)),
        h('span', { class: 'muted small' }, 'Shared by every migration that uses this log folder')),
        r.files.length ? h('div', { class: 'table-wrap' }, h('table', {},
          h('thead', {}, h('tr', {}, h('th', {}, 'File'), h('th', {}, 'Kind'), h('th', {}, 'Size'), h('th', {}, 'Modified'))),
          h('tbody', {}, r.files.map((f) => h('tr', { class: 'click', tabindex: '0', onclick: () => viewFile(id, P(id) + '/logs/' + encodeURIComponent(f.name), f.name),
            onkeydown: (e) => { if (e.key === 'Enter') viewFile(id, P(id) + '/logs/' + encodeURIComponent(f.name), f.name); } },
            h('td', {}, h('code', {}, f.name)), h('td', { class: 'muted' }, kind(f.name)), h('td', { class: 'nowrap' }, fmtSize(f.size)), h('td', { class: 'nowrap muted' }, fmtTime(f.mtime))))))) :
          h('div', { class: 'empty' }, 'No log files yet.')));
  }

  // ---------------------------------------------------------------- user guide
  function viewGuide() {
    const sections = [
      ['start', 'Getting started'], ['create', 'Create a migration'], ['setup', 'The setup wizard'], ['tests', 'Testing connections'],
      ['steps', 'Steps & hooks'], ['run', 'Running a migration'], ['progress', 'Progress, runs & logs'], ['many', 'Several sites'],
      ['cli', 'GUI and command line'], ['security', 'Security'], ['trouble', 'Troubleshooting'],
    ];
    const body = h('div', { class: 'guide-body', html: GUIDE_HTML });
    return h('div', { class: 'page' },
      h('div', { class: 'head' }, h('div', { class: 'head-title' }, h('div', { class: 'eyebrow' }, 'Help'), h('h1', {}, 'User guide'))),
      h('div', { class: 'guide' }, h('nav', { class: 'guide-toc', 'aria-label': 'Guide contents' }, sections.map(([k, t]) =>
        h('a', { href: '#/guide/' + k, onclick: (e) => { e.preventDefault(); const el = document.getElementById('g-' + k); if (el) el.scrollIntoView({ behavior: 'smooth' }); history.replaceState(null, '', '#/guide/' + k); } }, t))), body));
  }
  const GUIDE_HTML = `
<section id="g-start"><h2>Getting started</h2>
<p>The GUI is a thin layer over <code>migrate.sh</code>. It writes the env file the script reads, runs the script's own checks, starts runs and shows what the script reports. Nothing it does is GUI-only: every setting ends up in the env file, and every run can be repeated from a terminal.</p>
<pre>./gui.sh                  # opens http://127.0.0.1:8765 in your browser
./gui.sh --port 9000      # another port
./gui.sh --no-browser     # just print the URL (e.g. over SSH port forwarding)</pre>
<p>It needs <code>python3</code> 3.8 or newer and nothing else: no packages to install and no build step. Stop it with Ctrl-C in its terminal. Runs that are already going keep running and show up again when you restart the GUI.</p>
<p>Every <b>ⓘ</b> button explains its field, shows the <code>.env</code> key it writes and the default. Hover, focus or click it.</p></section>

<section id="g-create"><h2>Create a migration</h2>
<p>A <b>migration</b> is one env file describing one remote site and where its copy goes locally.</p>
<ul>
<li><b>default</b> is <code>.env</code> in the script folder, what <code>./migrate.sh</code> uses without options.</li>
<li>Any other name is saved as <code>sites/&lt;name&gt;.env</code> and run with <code>./migrate.sh --env sites/&lt;name&gt;.env</code>.</li>
<li><b>Copy settings from</b> clones an existing migration, handy for staging vs production of the same site.</li>
</ul>
<p>New files start from <code>.env.example</code>, so the comments in it are kept. Files are written with mode 600 and are git-ignored.</p></section>

<section id="g-setup"><h2>The setup wizard</h2>
<ol>
<li><b>Remote server</b>: SSH host, user, port, how you log in (key, password or ssh-agent), the remote web root and the live domain. <i>Advanced</i> holds the settings for hosts with a non-standard WordPress layout: <i>Only sync this folder</i>, <i>WP-CLI folder</i> and <i>wp-config.php path</i>.</li>
<li><b>Remote database</b>: the credentials from <code>wp-config.php</code> or Laravel's <code>.env</code> on the server, and the export method. <i>SSH tunnel</i> runs your local mysqldump through <code>ssh -L</code>; <i>Dump on the server</i> runs mysqldump remotely and downloads it compressed.</li>
<li><b>Local site</b>: the folder to sync into, the local domain, the platform, and what and how to copy.</li>
<li><b>Local database</b>: the database that is replaced. It is backed up first unless you turn that off. <i>Keep local data for tables</i> preserves, say, <code>wp_options</code> across the import.</li>
<li><b>WordPress &amp; Laravel</b>: local-only settings applied after the copy.</li>
<li><b>Behaviour</b>: whether to keep going after a failure, the database progress bars (pv) and the extra checks. Any key in <code>.env.example</code> that has no dedicated field appears under <i>Advanced</i>.</li>
<li><b>Review &amp; save</b>: everything on one page, changed values flagged, plus a final connection check.</li>
</ol>
<p>The steps are not locked: jump to any of them from the bar at the top. A number turns into ✓ when its required fields (<span style="color:var(--bad)">*</span>) are filled in. The diagram and the URL rewrite preview update as you type.</p>
<p>Changes stay in the browser until you press <b>Save</b>. The dark bar at the bottom shows how many are pending. Tests already use them, but runs always use the saved file.</p></section>

<section id="g-tests"><h2>Testing connections</h2>
<p>Each section has <b>Test</b> buttons that run the script's own preflight checks (<code>migrate.sh --test …</code>) with the values on screen, saved or not:</p>
<dl>
<dt>SSH login</dt><dd>Logs in non-interactively and checks the remote web root exists.</dd>
<dt>Remote database</dt><dd>Connects the way the run will (opening the tunnel for the tunnel method) and runs <code>SELECT 1</code>.</dd>
<dt>Local database</dt><dd>Logs in locally and checks the database exists or will be created.</dd>
<dt>Local web root / Local tools</dt><dd>The folder is writable, and ssh, rsync, mysql, wp… are installed for the steps that are on.</dd>
<dt>Disk space</dt><dd>Compares the remote site's size with free local space. Part of <b>Check everything</b>.</dd>
</dl>
<p>Tests only read. When one fails, the GUI shows the script's message and a <i>Likely cause</i> for common errors (wrong key, firewall, wrong DB host). A passed test turns the matching arrow in the diagram green. If you change a value afterwards, the result is flagged as out of date.</p>
<p>Password prompts cannot be answered from a browser. Use a key file, a password (with <code>sshpass</code> installed), or keys already loaded in <code>ssh-agent</code>.</p></section>

<section id="g-steps"><h2>Steps &amp; hooks</h2>
<p><b>Steps &amp; hooks</b> lists every step in the order it runs. The switches write <code>skip_*</code> and <code>run_*</code> into the env file, so terminal runs follow them too.</p>
<ul>
<li><b>Opt-in</b> steps (<i>Clear local web root</i>, <i>Kinsta MU plugins</i>) are off until you enable them. Clearing the web root asks for confirmation when you enable it, and again on every run.</li>
<li>Steps marked <i>WordPress only</i> or <i>Laravel only</i> are skipped on the other platform.</li>
<li>The two maintenance steps share one switch.</li>
</ul>
<h3>Before-run and after-run hooks</h3>
<p>Hooks are your own shell commands. <b>before-run</b> runs before everything else (start Docker, stash local changes, send a notification). <b>after-run</b> runs last (activate dev plugins, build assets, run Laravel migrations). Type commands into the editor or pick a template. Leave a hook empty to skip it.</p>
<ul>
<li>Saved as <code>hooks/&lt;migration&gt;/before-run.sh</code> and <code>after-run.sh</code> (git-ignored). The env file points at them through <code>before_run_hook</code> and <code>after_run_hook</code>.</li>
<li>They run with <code>bash</code> inside the local web root (the script folder if it does not exist yet), with <code>UMS_*</code> variables set. The table under the steps lists them.</li>
<li>A hook that exits non-zero fails its step like any other. If an earlier step fails and <i>Keep going after a failed step</i> is off, the after-run hook does not run.</li>
<li>During a dry run, hooks are printed, not executed.</li>
</ul></section>

<section id="g-run"><h2>Running a migration</h2>
<p>The buttons at the top of every migration page open the run dialog:</p>
<dl>
<dt>Run migration</dt><dd>The real thing: files are synced and the local database is replaced (after a backup).</dd>
<dt>Dry run</dt><dd>Runs the read-only parts (SSH, table listing, <code>rsync --dry-run</code>) and prints every command it would run. Nothing changes. A good first run.</dd>
<dt>Check everything</dt><dd>All preflight checks including disk space, then stops.</dd>
</dl>
<p>For a single run, you can untick steps or tick opt-in ones. The dialog shows the equivalent command line as you change them. GUI runs are unattended (<code>--yes</code>): nothing waits for an answer halfway through.</p></section>

<section id="g-progress"><h2>Progress, runs &amp; logs</h2>
<p>A running migration opens its live page:</p>
<ul>
<li>A <b>progress bar</b> and a <b>timeline</b> of the preflight checks and every step, with a timer on the current step. Skipped steps say why.</li>
<li>While files sync, the number of files rsync has transferred so far and the latest one.</li>
<li>The <b>console</b> streams the script's output. Turn off <i>Follow</i> to scroll back while it runs.</li>
<li><b>Stop</b> sends Ctrl-C to the script. It closes the SSH tunnel and removes temp files before exiting, and warns if maintenance mode is still on.</li>
</ul>
<p>The <b>Runs</b> tab lists every run of the migration, terminal runs included, with status, duration and a strip of step results. Open one for its timeline, console, <b>full log</b>, <b>report</b> (one line per step) and <b>rsync file list</b>. <b>Log files</b> lists everything in the log folder, older runs included. View any file there with a line filter, or download it.</p>
<p>Run history comes from the <code>.events</code> file the script writes next to each log (<code>logs/migrate-&lt;time&gt;.events</code>), so nothing extra needs to be kept.</p></section>

<section id="g-many"><h2>Several sites</h2>
<p>Create one migration per site or environment. Each has its own credentials, steps, hooks and run history. They share the <code>config/</code> list files (exclude lists, domain pairs), unless a migration points at its own files in the <i>Advanced</i> fields. One migration runs at a time; different migrations can run side by side.</p></section>

<section id="g-cli"><h2>GUI and command line</h2>
<table><thead><tr><th>In the GUI</th><th>On the command line</th></tr></thead><tbody>
<tr><td>Test SSH / databases</td><td><code>./migrate.sh --test ssh,remote-db,local-db</code></td></tr>
<tr><td>Check everything</td><td><code>./migrate.sh --check</code></td></tr>
<tr><td>Dry run</td><td><code>./migrate.sh --yes --dry-run</code></td></tr>
<tr><td>Run migration</td><td><code>./migrate.sh --yes</code></td></tr>
<tr><td>Untick a step for one run</td><td><code>--skip sync-files</code></td></tr>
<tr><td>Tick an opt-in step</td><td><code>--with clear-web-root</code></td></tr>
<tr><td>Another migration</td><td><code>--env sites/&lt;name&gt;.env</code></td></tr>
</tbody></table>
<p>You can keep editing env files by hand: the GUI rereads them every time it opens a migration, and saving changes only the lines you edited. Comments and the order of keys stay as they were.</p></section>

<section id="g-security"><h2>Security</h2>
<ul>
<li>The GUI listens on <code>127.0.0.1</code> only. Each launch creates a random token, which the browser receives in the URL and sends with every request. Other websites you visit cannot read or start anything, and requests with a foreign <code>Host</code> header are rejected.</li>
<li>Passwords stay in your env files (mode 600, git-ignored). The script passes them through stdin, environment variables or temporary option files, never on a command line.</li>
<li>To use the GUI on a remote machine, keep it bound to 127.0.0.1 and tunnel it: <code>ssh -L 8765:127.0.0.1:8765 you@box</code>, then open the printed URL locally. Avoid <code>--host 0.0.0.0</code>.</li>
</ul></section>

<section id="g-trouble"><h2>Troubleshooting</h2>
<dl>
<dt>"Open the link from the terminal"</dt><dd>The page lost its token, for example after the GUI was restarted. Open the URL that <code>./gui.sh</code> printed.</dd>
<dt>SSH test hangs, then fails</dt><dd>The GUI cannot answer password or passphrase prompts. Use a key without a passphrase, load it with <code>ssh-add</code> first, or use a password with <code>sshpass</code>.</dd>
<dt>Remote database fails with the tunnel method</dt><dd>The server may forbid TCP forwarding. Switch the export method to <i>Dump on the server</i>.</dd>
<dt>SSL errors from the database client</dt><dd>Set the SSL flag under <i>Advanced</i>: <code>--skip-ssl</code> for MariaDB clients, <code>--ssl-mode=DISABLED</code> for MySQL clients.</dd>
<dt>"Process count of N exceeded maximum allowed value"</dt><dd>The host limits how many processes your account may run and stopped the script. Turn off <i>Progress bars for the database (pv)</i> under Behaviour, log in with a key file, and run while the site is quiet.</dd>
<dt>wp-config.php not found, or WP-CLI cannot find WordPress</dt><dd>The host keeps WordPress core outside the web root. Under Remote server → <i>Advanced</i>, set <i>Only sync this folder</i> (usually <code>wp-content</code>), <i>WP-CLI folder</i> and <i>wp-config.php path</i>.</dd>
<dt>A run shows "Interrupted"</dt><dd>The script exited without its final event (killed, machine asleep). Check the log, and remove <code>.maintenance</code> or run <code>php artisan up</code> if the site is still in maintenance mode.</dd>
<dt>A setting does not seem to apply</dt><dd>Check for unsaved changes (the dark bar at the bottom), and that the key is not set twice in the env file by hand.</dd>
</dl>
<p>See the README for every setting and step in detail.</p></section>`;

  // ---------------------------------------------------------------- boot
  async function boot() {
    if (!TOKEN) return showTokenError();
    try {
      S.meta = await api('GET', '/api/meta');
    } catch (e) {
      if (e.message !== 'Not authorised') $('#main').replaceChildren(h('div', { class: 'callout bad' }, 'Could not reach the GUI server: ' + e.message + '. Is ./gui.sh still running?'));
      return;
    }
    $('#version').textContent = 'migrate.sh ' + S.meta.version;
    await loadProfiles();
    render();
  }
  boot();
})();
