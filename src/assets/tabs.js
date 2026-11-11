// zkdocs content tabs. Markdown `=== "Label"` groups render as
// .tabbed-set blocks (see renderTabGroup in markdown.zig) with the first tab
// selected. Clicking a label selects that label in every group on the page,
// so choosing "Python" once switches every snippet, and the choice is
// remembered across pages. Groups without that label keep their selection.
(function () {
  'use strict';

  var STORAGE_KEY = 'zkdocs-tab';

  function select(set, label) {
    var labels = set.querySelectorAll(':scope > .tabbed-labels > .tabbed-label');
    var found = false;
    labels.forEach(function (l) { if (l.dataset.tab === label) found = true; });
    if (!found) return;
    labels.forEach(function (l) {
      var on = l.dataset.tab === label;
      l.classList.toggle('active', on);
      l.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    set.querySelectorAll(':scope > .tabbed-block').forEach(function (p) {
      p.hidden = p.dataset.tab !== label;
    });
  }

  function selectEverywhere(label) {
    document.querySelectorAll('.tabbed-set').forEach(function (set) { select(set, label); });
  }

  document.addEventListener('click', function (e) {
    var btn = e.target.closest('.tabbed-label');
    if (!btn) return;
    // Groups above the clicked one can change height when they switch, so
    // keep the clicked label where it was on screen.
    var before = btn.getBoundingClientRect().top;
    selectEverywhere(btn.dataset.tab);
    window.scrollBy(0, btn.getBoundingClientRect().top - before);
    try { localStorage.setItem(STORAGE_KEY, btn.dataset.tab); } catch (_) { /* storage blocked */ }
  });

  function restore() {
    var saved = null;
    try { saved = localStorage.getItem(STORAGE_KEY); } catch (_) { /* storage blocked */ }
    if (saved) selectEverywhere(saved);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', restore);
  } else {
    restore();
  }
})();
