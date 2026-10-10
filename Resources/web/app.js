(function () {
  'use strict';

  var darkQuery = window.matchMedia('(prefers-color-scheme: dark)');

  function initMermaid() {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: darkQuery.matches ? 'dark' : 'default',
      fontFamily: 'inherit'
    });
  }
  initMermaid();

  var md = window.markdownit({
    html: true,
    linkify: true,
    typographer: true,
    highlight: function (code, lang) {
      // Mermaid fences are passed through untouched; they are rendered as
      // diagrams after insertion, not highlighted as source.
      if (lang === 'mermaid') return null;
      if (lang && hljs.getLanguage(lang)) {
        try {
          return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
        } catch (e) { /* fall through to escaped plain text */ }
      }
      return null;
    }
  });

  md.use(window.markdownItAnchor, { permalink: false, slugify: slugify });
  if (window.markdownitTaskLists) md.use(window.markdownitTaskLists, { enabled: true });

  function slugify(s) {
    return String(s).trim().toLowerCase()
      .replace(/[^\w一-龥\- ]/g, '')
      .replace(/\s+/g, '-');
  }

  // Tag every block with its source line range ("start:end", 0-based, end
  // exclusive). Global search uses it to land on the right rendered match.
  md.core.ruler.push('source_lines', function (state) {
    state.tokens.forEach(function (token) {
      if (token.map && token.block && token.nesting !== -1 && token.type !== 'inline') {
        token.attrSet('data-line', token.map[0] + ':' + token.map[1]);
      }
    });
  });

  function tagPre(html, token) {
    if (!token.map || html.indexOf('<pre') !== 0) return html;
    return '<pre data-line="' + token.map[0] + ':' + token.map[1] + '"' + html.slice(4);
  }

  // Mermaid fences must become <pre class="mermaid"> holding the RAW source, so
  // override the fence renderer ahead of markdown-it's default.
  var defaultFence = md.renderer.rules.fence;
  md.renderer.rules.fence = function (tokens, idx, options, env, self) {
    var token = tokens[idx];
    var info = (token.info || '').trim().split(/\s+/)[0];
    if (info === 'mermaid') {
      return tagPre('<pre class="mermaid">' + escapeHtml(token.content) + '</pre>', token);
    }
    return tagPre(defaultFence(tokens, idx, options, env, self), token);
  };

  var defaultCodeBlock = md.renderer.rules.code_block;
  md.renderer.rules.code_block = function (tokens, idx, options, env, self) {
    return tagPre(defaultCodeBlock(tokens, idx, options, env, self), tokens[idx]);
  };

  function escapeHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  var content = document.getElementById('content');

  /// Remember where the reader was, by nearest heading, so a re-render on :w
  /// does not throw them back to the top. Falls back to raw scroll offset.
  function captureAnchor() {
    var headings = content.querySelectorAll('h1[id],h2[id],h3[id],h4[id],h5[id],h6[id]');
    for (var i = headings.length - 1; i >= 0; i--) {
      if (headings[i].getBoundingClientRect().top <= 8) {
        return { id: headings[i].id, delta: headings[i].getBoundingClientRect().top };
      }
    }
    return { y: window.scrollY };
  }

  function restoreAnchor(anchor) {
    if (anchor.id) {
      var el = document.getElementById(anchor.id);
      if (el) {
        window.scrollTo(0, window.scrollY + el.getBoundingClientRect().top - anchor.delta);
        return;
      }
    }
    window.scrollTo(0, anchor.y || 0);
  }

  /// Relative image sources resolve against the bundle's web root unless we
  /// rewrite them against the document's own directory first.
  function rewriteRelativePaths(root, baseDir) {
    if (!baseDir) return;
    var base = 'file://' + encodeURI(baseDir).replace(/#/g, '%23') + '/';
    root.querySelectorAll('img[src]').forEach(function (img) {
      var src = img.getAttribute('src');
      if (/^([a-z]+:|\/\/|data:|#)/i.test(src)) return;
      img.setAttribute('src', base + src.replace(/^\.\//, ''));
    });
  }

  var renderToken = 0;
  var lastPayload = null;

  // ---- Find in page ------------------------------------------------------
  // WKWebView.find only ever selects one match, so highlighting all of them is
  // done here: every match is wrapped in <mark class="xem-find">, the current
  // one also gets .xem-find-active. Colors come from --find-* in theme.css.
  var findQuery = '';
  var findMarks = [];
  var findIndex = -1;

  function clearFindMarks() {
    var parents = [];
    findMarks.forEach(function (mark) {
      var parent = mark.parentNode;
      if (!parent) return;
      parent.replaceChild(document.createTextNode(mark.textContent), mark);
      if (parents.indexOf(parent) < 0) parents.push(parent);
    });
    // Re-join the text nodes that wrapping split apart.
    parents.forEach(function (parent) { parent.normalize(); });
    findMarks = [];
    findIndex = -1;
  }

  /// Text nodes worth searching: not diagram SVG, not KaTeX's duplicated
  /// MathML/HTML trees (wrapping inside those breaks the layout).
  function findTextNodes() {
    var nodes = [];
    var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (!node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
        for (var el = node.parentElement; el && el !== content; el = el.parentElement) {
          if (el.tagName === 'svg' || el.classList.contains('katex') ||
              el.classList.contains('mermaid')) return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    while (walker.nextNode()) nodes.push(walker.currentNode);
    return nodes;
  }

  function highlightAll(query) {
    var re = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
    findTextNodes().forEach(function (node) {
      var text = node.nodeValue;
      var match, last = 0, frag = null;
      re.lastIndex = 0;
      while ((match = re.exec(text)) !== null) {
        if (!match[0].length) { re.lastIndex++; continue; }
        frag = frag || document.createDocumentFragment();
        if (match.index > last) frag.appendChild(document.createTextNode(text.slice(last, match.index)));
        var mark = document.createElement('mark');
        mark.className = 'xem-find';
        mark.textContent = match[0];
        frag.appendChild(mark);
        findMarks.push(mark);
        last = match.index + match[0].length;
      }
      if (frag) {
        if (last < text.length) frag.appendChild(document.createTextNode(text.slice(last)));
        node.parentNode.replaceChild(frag, node);
      }
    });
  }

  function setActiveMatch(index, scroll) {
    if (findIndex >= 0 && findMarks[findIndex]) findMarks[findIndex].classList.remove('xem-find-active');
    findIndex = index;
    var mark = findMarks[index];
    if (!mark) return;
    mark.classList.add('xem-find-active');
    if (scroll) mark.scrollIntoView({ block: 'center', inline: 'nearest' });
  }

  function findStatus() {
    return { count: findMarks.length, index: findIndex };
  }

  /// First match at or below `y` (document coordinates), else the first match.
  function firstMatchFrom(y) {
    for (var i = 0; i < findMarks.length; i++) {
      if (findMarks[i].getBoundingClientRect().top + window.scrollY >= y - 1) return i;
    }
    return 0;
  }

  // CSS follows the system appearance on its own, but mermaid bakes its theme
  // into the SVG at render time -- so re-render diagrams when it flips.
  darkQuery.addEventListener('change', function () {
    applyFindColors();
    initMermaid();
    if (lastPayload) window.xem.render(lastPayload);
  });

  var findColorPrefs = {};

  /// Inline custom properties on <html> beat both palettes in theme.css, so
  /// they are set for the current appearance and cleared otherwise.
  function applyFindColors() {
    var colors = findColorPrefs[darkQuery.matches ? 'dark' : 'light'] || {};
    var root = document.documentElement.style;
    [['match', '--find-bg'], ['active', '--find-active-bg']].forEach(function (pair) {
      var value = colors[pair[0]];
      if (value) root.setProperty(pair[1], value); else root.removeProperty(pair[1]);
    });
  }

  // ---- Outline sidebar ---------------------------------------------------
  var outlineEl = document.getElementById('outline');
  var outlineItems = [];
  var outlineActive = -1;

  function buildOutline() {
    outlineEl.textContent = '';
    outlineItems = [];
    outlineActive = -1;
    var headings = content.querySelectorAll('h1[id],h2[id],h3[id],h4[id],h5[id],h6[id]');
    if (!headings.length) {
      var empty = document.createElement('p');
      empty.className = 'outline-empty';
      empty.textContent = 'No headings';
      outlineEl.appendChild(empty);
      return;
    }
    var minLevel = 6;
    headings.forEach(function (h) { minLevel = Math.min(minLevel, Number(h.tagName.charAt(1))); });
    var list = document.createElement('ul');
    headings.forEach(function (h) {
      var level = Number(h.tagName.charAt(1));
      var link = document.createElement('a');
      link.textContent = h.textContent;
      link.href = '#' + h.id;
      link.style.paddingLeft = (0.9 + (level - minLevel) * 1.0) + 'em';
      link.addEventListener('click', function (e) {
        e.preventDefault();
        h.scrollIntoView({ block: 'start' });
      });
      var item = document.createElement('li');
      item.appendChild(link);
      list.appendChild(item);
      outlineItems.push({ heading: h, link: link });
    });
    outlineEl.appendChild(list);
  }

  /// Highlight the section the reader is in: the last heading at or above the
  /// top of the viewport.
  function updateOutlineActive() {
    if (!outlineItems.length || !document.body.classList.contains('outline-open')) return;
    var active = 0;
    for (var i = 0; i < outlineItems.length; i++) {
      if (outlineItems[i].heading.getBoundingClientRect().top <= 24) active = i; else break;
    }
    if (active === outlineActive) return;
    if (outlineItems[outlineActive]) outlineItems[outlineActive].link.classList.remove('active');
    outlineActive = active;
    var link = outlineItems[active].link;
    link.classList.add('active');
    link.scrollIntoView({ block: 'nearest' });
  }

  // The button asks native to flip the shared preference, so every window
  // follows; setOutlineVisible below then reflects it back.
  var outlineToggle = document.getElementById('outline-toggle');
  outlineToggle.addEventListener('click', function () { post({ type: 'toggleOutline' }); });

  var scrollQueued = false;
  window.addEventListener('scroll', function () {
    if (scrollQueued) return;
    scrollQueued = true;
    window.requestAnimationFrame(function () {
      scrollQueued = false;
      updateOutlineActive();
    });
  });

  // ---- Links and fragments -----------------------------------------------
  function scrollToId(id) {
    if (!id) return false;
    var el = document.getElementById(id);
    if (!el) return false;
    el.scrollIntoView({ block: 'start' });
    return true;
  }

  function post(message) {
    try { window.webkit.messageHandlers.xem.postMessage(message); }
    catch (e) { console.error('xem bridge:', e); }
  }

  // The page lives in the app bundle, so a relative href would resolve against
  // the bundle. Intercept clicks and resolve against the document instead.
  content.addEventListener('click', function (e) {
    if (e.defaultPrevented) return;
    var a = e.target.closest ? e.target.closest('a[href]') : null;
    if (!a || !content.contains(a)) return;
    var href = a.getAttribute('href');
    if (href.charAt(0) === '#') {
      e.preventDefault();
      var id = href.slice(1);
      try { id = decodeURIComponent(id); } catch (err) { /* keep raw */ }
      scrollToId(id);
      return;
    }
    // Real schemes (http, mailto, ...) go to the native navigation delegate.
    if (/^[a-z][a-z0-9+.-]*:/i.test(href) && !/^file:/i.test(href)) return;
    e.preventDefault();
    var baseDir = (lastPayload && lastPayload.baseDir) || '/';
    var base = 'file://' + encodeURI(baseDir).replace(/#/g, '%23') + '/';
    try {
      var url = new URL(href, base);
      post({
        type: 'openLink',
        path: decodeURIComponent(url.pathname),
        fragment: decodeURIComponent(url.hash.replace(/^#/, ''))
      });
    } catch (err) {
      console.error('xem link:', err);
    }
  });

  /// Runs once a render has fully settled (including diagrams).
  function afterRender(payloadFragment) {
    reapplyFind();
    updateOutlineActive();
    if (payloadFragment) scrollToId(payloadFragment);
  }

  /// A save re-renders the page; keep the active search alive across it.
  function reapplyFind() {
    if (!findQuery) return;
    var q = findQuery;
    findQuery = '';
    window.xem.find(q, false, true);
  }

  window.xem = {
    /// Text-only zoom. Reflowing changes every heading's offset, so keep the
    /// reader's place the same way a re-render does.
    setTextScale: function (scale) {
      var anchor = captureAnchor();
      document.documentElement.style.setProperty('--text-scale', String(scale));
      restoreAnchor(anchor);
    },
    /// Highlight every match of `query`. `restart` re-runs the search (typing,
    /// or the document changed); otherwise this steps to the next/previous
    /// match. Returns {count, index} for the find bar's "3 of 12".
    find: function (query, backwards, restart) {
      if (!query) { return window.xem.clearFind(); }
      if (restart || query !== findQuery) {
        // Stay near where the reader is: the current match if there is one.
        var from = window.scrollY;
        if (findMarks[findIndex]) from = findMarks[findIndex].getBoundingClientRect().top + window.scrollY;
        clearFindMarks();
        findQuery = query;
        highlightAll(query);
        if (findMarks.length) setActiveMatch(firstMatchFrom(from), true);
        return findStatus();
      }
      if (!findMarks.length) return findStatus();
      var n = findMarks.length;
      setActiveMatch((findIndex + (backwards ? -1 : 1) + n) % n, true);
      return findStatus();
    },
    clearFind: function () {
      clearFindMarks();
      findQuery = '';
      return findStatus();
    },
    /// Select the rendered match for source line `line` (0-based). Highlights
    /// every match, then picks the one inside the block covering that line.
    findAtSourceLine: function (query, line) {
      var status = window.xem.find(query, false, true);
      if (!findMarks.length) return status;
      var re = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
      var inside = [];       // marks whose block covers the line
      var nearest = null;    // else: last block starting at or before it
      findMarks.forEach(function (mark, i) {
        var block = mark.closest('[data-line]');
        if (!block) return;
        var range = block.getAttribute('data-line').split(':');
        var start = Number(range[0]), end = Number(range[1]);
        var entry = { index: i, start: start };
        if (start <= line && line < end) inside.push(entry);
        else if (start <= line && (!nearest || start >= nearest.start)) nearest = entry;
      });
      var group = inside;
      if (group.length) {
        var innermost = Math.max.apply(null, group.map(function (m) { return m.start; }));
        group = group.filter(function (m) { return m.start === innermost; });
      } else if (nearest) {
        group = [nearest];
      }
      if (group.length) {
        // Earlier source matches in the same block precede this one.
        var lines = ((lastPayload && lastPayload.markdown) || '').split('\n');
        var skipped = 0;
        for (var i = group[0].start; i < line && i < lines.length; i++) {
          skipped += (lines[i].match(re) || []).length;
        }
        setActiveMatch(group[Math.min(skipped, group.length - 1)].index, true);
      }
      return findStatus();
    },
    scrollToId: scrollToId,
    /// Cap on the text column: a CSS length ("60rem") or "none" for the whole
    /// window. Reflowing moves every heading, so keep the reader's place.
    setContentWidth: function (width) {
      var anchor = captureAnchor();
      document.documentElement.style.setProperty('--content-width', width || '46rem');
      restoreAnchor(anchor);
    },
    /// Interface (not document) text scale; see --ui-scale in theme.css.
    setUIScale: function (scale) {
      document.documentElement.style.setProperty('--ui-scale', String(scale));
    },
    /// Show or hide the outline sidebar, keeping the reader's place (the
    /// content column reflows when it opens).
    setOutlineVisible: function (visible) {
      var anchor = captureAnchor();
      document.body.classList.toggle('outline-open', !!visible);
      outlineToggle.setAttribute('aria-pressed', visible ? 'true' : 'false');
      restoreAnchor(anchor);
      updateOutlineActive();
    },
    /// Per-appearance overrides for --find-bg / --find-active-bg, as
    /// {light: {match, active}, dark: {match, active}}. Missing entries fall
    /// back to the theme.css defaults.
    setFindColors: function (prefs) {
      findColorPrefs = prefs || {};
      applyFindColors();
    },
    render: function (payload) {
      lastPayload = payload;
      var anchor = captureAnchor();
      var token = ++renderToken;

      // One-shot: a link to other.md#section scrolls once, not on every save.
      var fragment = payload.fragment || '';
      payload.fragment = '';
      // The old marks die with the old DOM; reapplyFind rebuilds them below.
      findMarks = [];
      findIndex = -1;
      content.innerHTML = md.render(payload.markdown || '');
      buildOutline();
      rewriteRelativePaths(content, payload.baseDir);

      try {
        renderMathInElement(content, {
          delimiters: [
            { left: '$$', right: '$$', display: true },
            { left: '\\[', right: '\\]', display: true },
            { left: '$', right: '$', display: false },
            { left: '\\(', right: '\\)', display: false }
          ],
          throwOnError: false,
          ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
        });
      } catch (e) {
        console.error('katex:', e);
      }

      var diagrams = content.querySelectorAll('pre.mermaid');
      if (diagrams.length) {
        mermaid.run({ nodes: diagrams, suppressErrors: true })
          .catch(function (e) { console.error('mermaid:', e); })
          .finally(function () {
            // A later render may have landed while mermaid was working.
            if (token === renderToken) { restoreAnchor(anchor); afterRender(fragment); }
          });
      } else {
        restoreAnchor(anchor);
        afterRender(fragment);
      }
    }
  };
})();
