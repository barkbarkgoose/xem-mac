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

  // CSS follows the system appearance on its own, but mermaid bakes its theme
  // into the SVG at render time -- so re-render diagrams when it flips.
  darkQuery.addEventListener('change', function () {
    initMermaid();
    if (lastPayload) window.geenyan.render(lastPayload);
  });

  window.geenyan = {
    render: function (payload) {
      lastPayload = payload;
      var anchor = captureAnchor();
      var token = ++renderToken;

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
            if (token === renderToken) restoreAnchor(anchor);
          });
      } else {
        restoreAnchor(anchor);
      }
    }
  };
})();
