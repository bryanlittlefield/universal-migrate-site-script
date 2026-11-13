/* Shared behaviour for the docs site: Technical details switch (cli.html), theme button, copy buttons. */
(function () {
  var root = document.documentElement;
  var store = {
    get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
  };

  // Technical details switch (cli.html)
  var toggle = document.getElementById('techToggle');
  function applyMode(on) {
    if (on) { root.setAttribute('data-mode', 'tech'); } else { root.removeAttribute('data-mode'); }
    toggle.checked = on;
  }
  if (toggle) { // only the CLI guide has the switch
    applyMode(store.get('ums-mode') === 'tech' || location.hash === '#tech');
    toggle.addEventListener('change', function () {
      applyMode(toggle.checked);
      store.set('ums-mode', toggle.checked ? 'tech' : 'simple');
    });
  }

  // Theme: auto -> light -> dark
  var themeBtn = document.getElementById('themeBtn');
  var themes = ['auto', 'light', 'dark'];
  function applyTheme(t) {
    if (t === 'auto') { root.removeAttribute('data-theme'); } else { root.setAttribute('data-theme', t); }
    themeBtn.textContent = 'Theme: ' + t;
  }
  var current = store.get('ums-theme') || 'auto';
  if (themes.indexOf(current) < 0) { current = 'auto'; }
  applyTheme(current);
  themeBtn.addEventListener('click', function () {
    current = themes[(themes.indexOf(current) + 1) % themes.length];
    applyTheme(current);
    store.set('ums-theme', current);
  });

  // Copy buttons
  Array.prototype.forEach.call(document.querySelectorAll('pre.code .copy'), function (btn) {
    btn.addEventListener('click', function () {
      var code = btn.parentNode.querySelector('code');
      var text = code.textContent.replace(/[ \t]+#.*$/gm, '').replace(/\n{2,}/g, '\n').trim();
      function done() { btn.textContent = 'Copied'; btn.classList.add('done'); setTimeout(function () { btn.textContent = 'Copy'; btn.classList.remove('done'); }, 1500); }
      function fallback() {
        var range = document.createRange(); range.selectNodeContents(code);
        var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range);
        btn.textContent = 'Select + copy';
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, fallback);
      } else { fallback(); }
    });
  });
})();
