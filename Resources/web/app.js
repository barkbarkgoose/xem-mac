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

  // Mermaid fences must become <pre class="mermaid"> holding the RAW source, so
  // override the fence renderer ahead of markdown-it's default.
  var defaultFence = md.renderer.rules.fence;
  md.renderer.rules.fence = function (tokens, idx, options, env, self) {
    var token = tokens[idx];
    var info = (token.info || '').trim().split(/\s+/)[0];
    if (info === 'mermaid') {
      return '<pre class="mermaid">' + escapeHtml(token.content) + '</pre>';
    }
    return defaultFence(tokens, idx, options, env, self);
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

      // The old marks die with the old DOM; reapplyFind rebuilds them below.
      findMarks = [];
      findIndex = -1;
      content.innerHTML = md.render(payload.markdown || '');
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
            if (token === renderToken) { restoreAnchor(anchor); reapplyFind(); }
          });
      } else {
        restoreAnchor(anchor);
        reapplyFind();
      }
    }
  };
})();
