# zkdocs TODO

## Bugs
- [x] Minisearch broken on `file://` — `fetch()` blocked by browser. Fix: emit `assets/search-data.js` (sets `window.ZKDOCS_SEARCH_INDEX`) and load it as a deferred script instead of fetching JSON.

## Features
- [ ] Follow imports past the first root node, placing discovered modules on the modules sidebar (indented), but only if they are not modules/structs already seen.
