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
    }

    navBtn.addEventListener('click', function () {
      var opening = !nav.classList.contains('open');
      closeAll();
      if (opening) {
        nav.classList.add('open');
        overlay.classList.add('active');
      }
    });

    if (tocBtn && toc) {
      tocBtn.addEventListener('click', function () {
        var opening = !toc.classList.contains('open');
        closeAll();
        if (opening) {
          toc.classList.add('open');
          overlay.classList.add('active');
        }
      });
    }

    overlay.addEventListener('click', closeAll);
  }

  // ── Boot ─────────────────────────────────────────────────────────────────────

  document.addEventListener('DOMContentLoaded', function () {
    buildIndex();
    initSearch();
    initCopyButtons();
    initMobileNav();
  });

}());
