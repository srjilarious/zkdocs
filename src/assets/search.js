(function () {
  'use strict';

  // ── Helpers ─────────────────────────────────────────────────────────────────

  function escHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // ── Search ──────────────────────────────────────────────────────────────────
  // The index is loaded from window.ZKDOCS_SEARCH_INDEX (set by search-data.js,
  // a deferred script that runs before this one). Using a JS variable instead
  // of fetch() means search works on file:// URLs without a web server.

  var ms = null;

  function buildIndex() {
    var docs = window.ZKDOCS_SEARCH_INDEX;
    if (!docs || !docs.length) return;
    ms = new MiniSearch({
      fields: ['title', 'content'],
      storeFields: ['title', 'url', 'type'],
    });
    ms.addAll(docs);
  }

  function initSearch() {
    var input = document.getElementById('search-input');
    var box   = document.getElementById('search-results');
    if (!input || !box) return;

    input.addEventListener('input', function () {
      var q = input.value.trim();
      if (!q || !ms) { box.style.display = 'none'; return; }
      var hits = ms.search(q, { boost: { title: 2 }, prefix: true, fuzzy: 0.2, limit: 12 });
      renderResults(hits, box);
    });

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') { box.style.display = 'none'; input.blur(); }
    });

    document.addEventListener('click', function (e) {
      if (!e.target.closest('.search-box')) box.style.display = 'none';
    });
  }

  function renderResults(hits, box) {
    var base = window.ZKDOCS_BASE || './';
    if (!hits.length) { box.style.display = 'none'; return; }
    box.innerHTML = hits.map(function (h) {
      return (
        '<a class="search-result" href="' + base + escHtml(h.url) + '">' +
          '<span class="sr-title">' + escHtml(h.title) + '</span>' +
          '<span class="sr-type">'  + escHtml(h.type)  + '</span>' +
        '</a>'
      );
    }).join('');
    box.style.display = 'block';
  }

  // ── Copy buttons ─────────────────────────────────────────────────────────────

  var COPY_ICON =
    '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" ' +
    'stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
    'stroke-linejoin="round" aria-hidden="true">' +
    '<rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>' +
    '<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>' +
    '</svg>';

  function initCopyButtons() {
    document.querySelectorAll('pre').forEach(function (pre) {
      var btn = document.createElement('button');
      btn.className = 'copy-btn';
      btn.title = 'Copy';
      btn.setAttribute('aria-label', 'Copy code');
      btn.innerHTML = COPY_ICON;

      btn.addEventListener('click', function () {
        var code = pre.querySelector('code') || pre;
        var text = code.textContent || '';
        if (navigator.clipboard) {
          navigator.clipboard.writeText(text).then(function () {
            btn.textContent = 'Copied!';
            setTimeout(function () { btn.innerHTML = COPY_ICON; }, 2000);
          }).catch(fallbackCopy);
        } else {
          fallbackCopy();
        }
        function fallbackCopy() {
          var ta = document.createElement('textarea');
          ta.value = text;
          ta.style.cssText = 'position:fixed;top:-9999px;left:-9999px';
          document.body.appendChild(ta);
          ta.select();
          try { document.execCommand('copy'); } catch (_) {}
          document.body.removeChild(ta);
          btn.textContent = 'Copied!';
          setTimeout(function () { btn.innerHTML = COPY_ICON; }, 2000);
        }
      });

      pre.style.position = 'relative';
      pre.appendChild(btn);
    });
  }

  // ── Mobile nav ───────────────────────────────────────────────────────────────

  function initMobileNav() {
    var navBtn  = document.getElementById('nav-toggle');
    var tocBtn  = document.getElementById('toc-toggle');
    var overlay = document.getElementById('overlay');
    var nav     = document.querySelector('nav.sidebar');
    var toc     = document.querySelector('aside.page-toc');

    if (!navBtn || !overlay || !nav) return;

    function closeAll() {
      nav.classList.remove('open');
      if (toc) toc.classList.remove('open');
      overlay.classList.remove('active');
      navBtn.setAttribute('aria-expanded', 'false');
      if (tocBtn) tocBtn.setAttribute('aria-expanded', 'false');
    }

    navBtn.addEventListener('click', function () {
      var opening = !nav.classList.contains('open');
      closeAll();
      if (opening) {
        nav.classList.add('open');
        overlay.classList.add('active');
        navBtn.setAttribute('aria-expanded', 'true');
      }
    });

    if (tocBtn && toc) {
      tocBtn.addEventListener('click', function () {
        var opening = !toc.classList.contains('open');
        closeAll();
        if (opening) {
          toc.classList.add('open');
          overlay.classList.add('active');
          tocBtn.setAttribute('aria-expanded', 'true');
        }
      });
    }

    overlay.addEventListener('click', closeAll);
  }

  // ── Collapsible symbol sections ─────────────────────────────────────────────
  // Each `.symbol` on an API page is a native <details>. Collapsed state is
  // persisted per-page (keyed by pathname) in localStorage so it survives
  // reloads, and a global "Collapse all / Expand all" pair toggles every
  // symbol on the page at once.

  function initSymbolCollapse() {
    var symbols = document.querySelectorAll('details.symbol');
    if (!symbols.length) return;

    var storageKey = 'zkdocs-collapsed:' + location.pathname;

    function loadCollapsed() {
      try {
        var raw = localStorage.getItem(storageKey);
        return raw ? JSON.parse(raw) : [];
      } catch (_) { return []; }
    }

    function saveCollapsed(ids) {
      try { localStorage.setItem(storageKey, JSON.stringify(ids)); } catch (_) {}
    }

    var collapsed = loadCollapsed();
    symbols.forEach(function (el) {
      if (el.id && collapsed.indexOf(el.id) !== -1) el.removeAttribute('open');
    });

    symbols.forEach(function (el) {
      el.addEventListener('toggle', function () {
        if (!el.id) return;
        var ids = loadCollapsed();
        var idx = ids.indexOf(el.id);
        if (el.open && idx !== -1) {
          ids.splice(idx, 1);
        } else if (!el.open && idx === -1) {
          ids.push(el.id);
        } else {
          return;
        }
        saveCollapsed(ids);
      });
    });

    var collapseBtn = document.getElementById('collapse-all-btn');
    var expandBtn   = document.getElementById('expand-all-btn');

    if (collapseBtn) {
      collapseBtn.addEventListener('click', function () {
        var ids = [];
        symbols.forEach(function (el) {
          el.removeAttribute('open');
          if (el.id) ids.push(el.id);
        });
        saveCollapsed(ids);
      });
    }
    if (expandBtn) {
      expandBtn.addEventListener('click', function () {
        symbols.forEach(function (el) { el.setAttribute('open', ''); });
        saveCollapsed([]);
      });
    }
  }

  // ── Print support ────────────────────────────────────────────────────────────
  // Force every collapsed <details> open before printing so nothing collapsed
  // is silently omitted from the printed page, then restore prior state after.

  function initPrintExpand() {
    var reopened = [];
    window.addEventListener('beforeprint', function () {
      reopened = [];
      document.querySelectorAll('details:not([open])').forEach(function (el) {
        reopened.push(el);
        el.setAttribute('open', '');
      });
    });
    window.addEventListener('afterprint', function () {
      reopened.forEach(function (el) { el.removeAttribute('open'); });
      reopened = [];
    });
  }

  // ── Boot ─────────────────────────────────────────────────────────────────────

  document.addEventListener('DOMContentLoaded', function () {
    buildIndex();
    initSearch();
    initCopyButtons();
    initMobileNav();
    initSymbolCollapse();
    initPrintExpand();
  });

}());
