import Foundation

/// JavaScript the preview injects into pages. It runs in the page's own world, because framework internals
/// (React fibers, Vue instances) are not visible from an isolated one. Everything lives on `window.__viber`.
public enum PreviewScripts {
    /// The name of the WKScriptMessageHandler the page posts to.
    public static let handler = "viber"

    /// Installed at document start, and re-run (harmlessly) before every tool call in case the page loaded before it.
    public static let bootstrap = #"""
    (() => {
      if (window.__viber) return;
      const post = (m) => { try { window.webkit.messageHandlers.viber.postMessage(m); } catch (_) {} };
      const V = window.__viber = { refs: new Map(), nextRef: 1, pending: new Map(), nextReq: 1, lastMutation: Date.now(), picking: false };
      const squash = (s, n) => { s = String(s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n) + '…' : s; };
      V.squash = squash;

      // Console, uncaught errors, failed requests.
      const fmt = (a) => {
        if (a instanceof Error) return (a.name || 'Error') + ': ' + a.message + (a.stack ? '\n' + a.stack : '');
        if (typeof a === 'string') return a;
        if (typeof Node !== 'undefined' && a instanceof Node) return a.outerHTML ? a.outerHTML.slice(0, 300) : String(a);
        try { const s = JSON.stringify(a); return s === undefined ? String(a) : s; } catch (_) { return String(a); }
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = function (...args) {
          try {
            let shown = args;
            if (typeof args[0] === 'string' && args[0].includes('%c')) {
              const n = (args[0].match(/%c/g) || []).length;
              shown = [args[0].replace(/%c/g, '')].concat(args.slice(1 + n));
            }
            post({ type: 'console', level, text: shown.map(fmt).join(' ').slice(0, 4000) });
          } catch (_) {}
          return original.apply(this, args);
        };
      }
      addEventListener('error', (e) => {
        const t = e.target;
        if (t && t !== window && t.tagName) {
          post({ type: 'console', level: 'error', text: 'Failed to load ' + t.tagName.toLowerCase() + ' ' + (t.currentSrc || t.src || t.href || '') });
        } else {
          // Errors from code WebKit injects (like a tool's script) arrive sanitized, with nothing to go on.
          if (e.message === 'Script error.' && !e.filename) return;
          const where = e.filename ? ' (' + e.filename + ':' + e.lineno + ':' + e.colno + ')' : '';
          post({ type: 'console', level: 'error', text: 'Uncaught ' + (e.message || 'error') + where + (e.error && e.error.stack ? '\n' + e.error.stack : '') });
        }
      }, true);
      addEventListener('unhandledrejection', (e) => post({ type: 'console', level: 'error', text: 'Unhandled promise rejection: ' + fmt(e.reason) }));

      const track = () => { const id = V.nextReq++; V.pending.set(id, Date.now()); return id; };
      const untrack = (id) => V.pending.delete(id);
      if (window.fetch) {
        const original = window.fetch;
        window.fetch = function (input, init) {
          const url = typeof input === 'string' ? input : (input && input.url) || String(input);
          const method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
          const id = track();
          let p;
          try { p = original.apply(this, arguments); } catch (err) { untrack(id); throw err; }
          return p.then((r) => {
            untrack(id);
            if (!r.ok) post({ type: 'console', level: 'error', text: method + ' ' + url + ' → ' + r.status + ' ' + r.statusText });
            return r;
          }, (err) => {
            untrack(id);
            if (!(err && err.name === 'AbortError')) post({ type: 'console', level: 'error', text: method + ' ' + url + ' failed: ' + err });
            throw err;
          });
        };
      }
      const xopen = XMLHttpRequest.prototype.open, xsend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) { this.__viberInfo = (method || 'GET').toUpperCase() + ' ' + url; return xopen.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        const id = track(), info = this.__viberInfo || 'XHR';
        this.addEventListener('load', () => { if (this.status >= 400) post({ type: 'console', level: 'error', text: info + ' → ' + this.status + ' ' + this.statusText }); });
        this.addEventListener('error', () => post({ type: 'console', level: 'error', text: info + ' failed' }));
        this.addEventListener('loadend', () => untrack(id));
        return xsend.apply(this, arguments);
      };

      // When the page last changed, for "wait until it settles".
      new MutationObserver((records) => {
        if (records.some((r) => !(r.target.closest && r.target.closest('[data-viber-ui]')))) V.lastMutation = Date.now();
      }).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      V.quiet = () => {
        const now = Date.now();
        let inflight = 0;
        for (const started of V.pending.values()) if (now - started < 5000) inflight++;
        return { ready: document.readyState, inflight, idle: now - V.lastMutation };
      };

      // Error overlays drawn by dev servers.
      V.overlay = () => {
        const text = (el) => el ? squash(el.innerText || el.textContent, 1500) : '';
        const vite = document.querySelector('vite-error-overlay');
        if (vite && vite.shadowRoot) return 'Vite error overlay: ' + text(vite.shadowRoot.querySelector('.window') || vite.shadowRoot.firstElementChild);
        const next = document.querySelector('nextjs-portal');
        if (next && next.shadowRoot) {
          const dialog = next.shadowRoot.querySelector('[data-nextjs-dialog], [data-nextjs-dialog-content]');
          if (dialog) return 'Next.js error overlay: ' + text(dialog);
        }
        const frame = document.getElementById('webpack-dev-server-client-overlay');
        if (frame) { try { return 'webpack error overlay: ' + text(frame.contentDocument.body); } catch (_) { return 'webpack error overlay is showing'; } }
        return '';
      };

      // Roles and names, close enough to the accessibility tree for an agent to find its way.
      const implicitRole = (el) => {
        const tag = el.tagName.toLowerCase();
        switch (tag) {
          case 'a': return el.hasAttribute('href') ? 'link' : null;
          case 'button': case 'summary': return 'button';
          case 'input': {
            const t = (el.getAttribute('type') || 'text').toLowerCase();
            if (['button', 'submit', 'reset', 'image'].includes(t)) return 'button';
            if (t === 'checkbox' || t === 'radio') return t;
            if (t === 'range') return 'slider';
            if (t === 'hidden') return null;
            return t === 'search' ? 'searchbox' : 'textbox';
          }
          case 'textarea': return 'textbox';
          case 'select': return el.multiple ? 'listbox' : 'combobox';
          case 'option': return 'option';
          case 'img': return el.getAttribute('alt') === '' ? null : 'img';
          case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
          case 'nav': return 'navigation';
          case 'main': return 'main';
          case 'header': return 'banner';
          case 'footer': return 'contentinfo';
          case 'aside': return 'complementary';
          case 'form': return 'form';
          case 'dialog': return 'dialog';
          case 'ul': case 'ol': return 'list';
          case 'li': return 'listitem';
          case 'table': return 'table';
          case 'tr': return 'row';
          case 'td': return 'cell';
          case 'th': return 'columnheader';
          case 'p': return 'paragraph';
          case 'iframe': return 'iframe';
          case 'section': return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : null;
        }
        if (el.isContentEditable && el.hasAttribute('contenteditable')) return 'textbox';
        return null;
      };
      const LEAF = new Set(['button', 'link', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox', 'listbox', 'option', 'slider',
        'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'spinbutton', 'img', 'clickable', 'iframe']);
      const role = (el) => {
        const r = el.getAttribute('role') || implicitRole(el);
        if (r) return r;
        const style = getComputedStyle(el), parent = el.parentElement;
        if (style.cursor === 'pointer' && !(parent && getComputedStyle(parent).cursor === 'pointer')) return 'clickable';
        return null;
      };
      const name = (el) => {
        const aria = el.getAttribute('aria-label');
        if (aria) return aria;
        const by = el.getAttribute('aria-labelledby');
        if (by) {
          const t = by.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => n.innerText).join(' ');
          if (t.trim()) return t;
        }
        if (el.tagName === 'IMG') return el.alt || el.title || '';
        if (el.tagName === 'IFRAME') return el.title || el.src || '';
        if (['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName)) {
          if (el.id) { const l = document.querySelector('label[for="' + CSS.escape(el.id) + '"]'); if (l) return l.innerText; }
          const wrap = el.closest('label');
          if (wrap) return wrap.innerText;
          if (['submit', 'button', 'reset'].includes(el.type)) return el.value;
          return el.placeholder || el.title || el.name || '';
        }
        return el.title || '';
      };
      const describe = (el) => {
        const r = role(el) || el.tagName.toLowerCase();
        const n = squash(name(el) || el.innerText || '', 40);
        return n ? r + ' "' + n + '"' : r;
      };
      V.describe = describe;
      const hidden = (el) => {
        if (el.hidden || el.getAttribute('aria-hidden') === 'true' || el.hasAttribute('data-viber-ui')) return true;
        const s = getComputedStyle(el);
        return s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse';
      };
      const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'META', 'LINK', 'HEAD', 'svg', 'SVG', 'PATH', 'BR']);
      const refOf = (el) => {
        if (!el.__viberRef) { el.__viberRef = 'e' + V.nextRef++; V.refs.set(el.__viberRef, new WeakRef(el)); }
        return el.__viberRef;
      };
      const ownText = (el) => {
        let t = '';
        for (const n of el.childNodes) if (n.nodeType === 3) t += n.textContent;
        return squash(t, 120);
      };
      V.snapshot = (selector, maxChars) => {
        const root = selector ? document.querySelector(selector) : document.body;
        if (!root) throw new Error('Nothing matches ' + selector + '.');
        const lines = [];
        let size = 0, truncated = false;
        const emit = (depth, text) => {
          if (truncated) return;
          const line = '  '.repeat(depth) + '- ' + text;
          if (size + line.length > maxChars) { truncated = true; return; }
          lines.push(line); size += line.length + 1;
        };
        const walk = (el, depth) => {
          if (truncated || SKIP.has(el.tagName) || hidden(el)) return;
          const r = role(el);
          if (r && LEAF.has(r)) {
            let label = squash(name(el) || el.innerText || '', 100);
            let extra = ' [ref=' + refOf(el) + ']';
            if (r === 'link') { const href = el.getAttribute('href'); if (href) extra += ' href="' + squash(href, 80) + '"'; }
            if ('value' in el && ['textbox', 'searchbox', 'combobox', 'slider', 'spinbutton'].includes(r) && el.value) extra += ' value="' + squash(el.value, 60) + '"';
            if (el.checked) extra += ' [checked]';
            if (el.disabled || el.getAttribute('aria-disabled') === 'true') extra += ' [disabled]';
            if (el.getAttribute('aria-expanded')) extra += ' [expanded=' + el.getAttribute('aria-expanded') + ']';
            emit(depth, r + (label ? ' "' + label.replace(/"/g, "'") + '"' : '') + extra);
            return;
          }
          let childDepth = depth;
          if (r) {
            const label = squash(name(el) || ownText(el), 120);
            const level = r === 'heading' ? ' [level=' + el.tagName.slice(1) + ']' : '';
            const text = r === 'heading' ? squash(el.innerText, 120) : label;
            emit(depth, r + (text ? ' "' + text.replace(/"/g, "'") + '"' : '') + level);
            if (r === 'heading') return;
            childDepth = depth + 1;
          } else {
            const text = ownText(el);
            if (text) emit(depth, 'text: "' + text.replace(/"/g, "'") + '"');
          }
          for (const child of el.children) walk(child, childDepth);
          if (el.shadowRoot) for (const child of el.shadowRoot.children) walk(child, childDepth);
        };
        walk(root, 0);
        if (truncated) lines.push('… (truncated: pass a selector to look at part of the page)');
        return lines.join('\n');
      };

      // Finding and acting on elements.
      const visible = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && !hidden(el); };
      V.resolve = (t) => {
        if (t.ref) {
          const w = V.refs.get(t.ref), el = w && w.deref();
          if (!el || !el.isConnected) throw new Error('No element with ref ' + t.ref + ' on the page now. Take a new preview_snapshot.');
          return el;
        }
        if (t.selector) {
          let el;
          try { el = document.querySelector(t.selector); } catch (_) { throw new Error('Invalid selector: ' + t.selector); }
          if (!el) throw new Error('Nothing matches ' + t.selector + '.');
          return el;
        }
        if (t.text) {
          const want = squash(t.text, 500).toLowerCase();
          const labelled = [...document.querySelectorAll('[aria-label], [placeholder], [title], input[type=submit], input[type=button]')]
            .filter((el) => visible(el) && squash(el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || el.value, 500).toLowerCase() === want);
          if (labelled.length) return labelled[0];
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          let exact = null, partial = null;
          for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            const text = squash(n.textContent, 500).toLowerCase();
            if (!text || !text.includes(want)) continue;
            let el = n.parentElement;
            if (!el || !visible(el)) continue;
            const action = el.closest('a[href], button, [role=button], [role=link], [role=tab], [role=menuitem], label, summary');
            if (action) el = action;
            if (text === want || squash(el.innerText, 500).toLowerCase() === want) { exact = el; break; }
            if (!partial) partial = el;
          }
          if (exact || partial) return exact || partial;
          throw new Error('No visible element shows the text "' + t.text + '".');
        }
        throw new Error('Pass ref, selector or text to say which element.');
      };
      V.flash = (el) => {
        const r = el.getBoundingClientRect();
        const box = document.createElement('div');
        box.setAttribute('data-viber-ui', '');
        box.setAttribute('data-viber-flash', '');
        box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #ff9f0a;background:rgba(255,159,10,.18);border-radius:3px;transition:opacity .4s;'
          + 'left:' + (r.left - 2) + 'px;top:' + (r.top - 2) + 'px;width:' + (r.width + 4) + 'px;height:' + (r.height + 4) + 'px';
        document.documentElement.appendChild(box);
        setTimeout(() => { box.style.opacity = '0'; }, 500);
        setTimeout(() => box.remove(), 950);
      };
      V.rect = (t) => {
        const el = V.resolve(t);
        el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
        const r = el.getBoundingClientRect();
        return { x: r.left, y: r.top, width: r.width, height: r.height, viewportWidth: innerWidth, viewportHeight: innerHeight };
      };
      V.click = (t) => {
        const el = V.resolve(t);
        el.scrollIntoView({ block: 'center', inline: 'center' });
        const r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
        const hit = document.elementFromPoint(x, y);
        const covered = hit && hit !== el && !el.contains(hit) && !hit.contains(el) && !hit.hasAttribute('data-viber-ui');
        V.flash(el);
        const opts = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0, view: window };
        const pointer = Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, opts);
        el.dispatchEvent(new PointerEvent('pointerdown', pointer));
        el.dispatchEvent(new MouseEvent('mousedown', opts));
        if (typeof el.focus === 'function') el.focus({ preventScroll: true });
        el.dispatchEvent(new PointerEvent('pointerup', pointer));
        el.dispatchEvent(new MouseEvent('mouseup', opts));
        el.click();
        return 'Clicked ' + describe(el) + (covered ? '. Note: ' + describe(hit) + ' covers its centre, so a real click would land on that instead.' : '.');
      };
      V.type = (t, text, clear, submit) => {
        const el = V.resolve(t);
        el.scrollIntoView({ block: 'center' });
        V.flash(el);
        if (typeof el.focus === 'function') el.focus({ preventScroll: true });
        if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
          const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, (clear ? '' : el.value) + text);
          el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        } else if (el instanceof HTMLSelectElement) {
          const option = [...el.options].find((o) => o.value === text || o.text.trim() === text);
          if (!option) throw new Error('No option "' + text + '". Options: ' + squash([...el.options].map((o) => o.text.trim()).join(', '), 300));
          el.value = option.value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        } else if (el.isContentEditable) {
          if (clear) document.execCommand('selectAll', false);
          document.execCommand('insertText', false, text);
        } else {
          throw new Error(describe(el) + ' is not a text field.');
        }
        if (submit) {
          const key = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
          const proceed = el.dispatchEvent(new KeyboardEvent('keydown', key));
          el.dispatchEvent(new KeyboardEvent('keypress', key));
          el.dispatchEvent(new KeyboardEvent('keyup', key));
          if (proceed && el.form) { if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit(); }
        }
        return 'Typed into ' + describe(el) + (submit ? ' and pressed Enter.' : '.');
      };

      // Where an element comes from in the source, as far as the framework's dev build says.
      const frame = (stack) => {
        for (const line of String(stack).split('\n')) {
          const m = line.match(/((?:https?|file|webpack):\/\/[^\s)]+?):(\d+):(\d+)/);
          if (m && !/node_modules|\/@vite\/|\/@react-refresh|react-dom|react_jsx|jsx-dev-runtime|\/_next\/static\/chunks\/(?!app\/|pages\/)/.test(m[1])) return { file: m[1], line: Number(m[2]) };
        }
        return null;
      };
      V.source = (el) => {
        const out = { components: [], file: null, line: null };
        for (let n = el; n && n.nodeType === 1 && !out.file; n = n.parentElement) {
          const path = n.getAttribute('data-insp-path') || n.getAttribute('data-source') || n.getAttribute('data-inspector-path');
          if (path) { const m = path.match(/^(.*?):(\d+)(?::\d+)?$/); out.file = m ? m[1] : path; out.line = m ? Number(m[2]) : null; }
        }
        let host = el, key = null;
        while (host && !(key = Object.keys(host).find((k) => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$')))) host = host.parentElement;
        if (key) {
          let f = host[key];
          for (let hops = 0; f && hops < 80 && out.components.length < 3; hops++, f = f.return) {
            if (!out.file && f._debugSource) { out.file = f._debugSource.fileName; out.line = f._debugSource.lineNumber; }
            if (!out.file && f._debugStack && f._debugStack.stack) { const s = frame(f._debugStack.stack); if (s) { out.file = s.file; out.line = s.line; } }
            const t = f.type;
            if (t && typeof t !== 'string') {
              const n = t.displayName || t.name || (t.render && (t.render.displayName || t.render.name)) || (t.type && (t.type.displayName || t.type.name));
              if (n && !/^(Fragment|Suspense|StrictMode|Provider|Consumer|Context|Anonymous)$/.test(n) && !out.components.includes(n)) out.components.push(n);
            }
          }
          return out;
        }
        for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
          let vue = n.__vueParentComponent;
          if (vue) {
            for (; vue && out.components.length < 3; vue = vue.parent) {
              const t = vue.type || {};
              const nm = t.name || t.__name || (t.__file ? t.__file.split('/').pop().replace(/\.vue$/, '') : null);
              if (nm && !out.components.includes(nm)) out.components.push(nm);
              if (!out.file && t.__file) out.file = t.__file;
            }
            return out;
          }
          const svelte = n.__svelte_meta;
          if (svelte && svelte.loc) { out.file = svelte.loc.file; out.line = svelte.loc.line; return out; }
        }
        return out;
      };

      // The element picker: hover outlines, a click picks, Escape cancels. Clicks never reach the page.
      const selectorFor = (el) => {
        const unique = (s) => { try { return document.querySelectorAll(s).length === 1; } catch (_) { return false; } };
        if (el.id && unique('#' + CSS.escape(el.id))) return '#' + CSS.escape(el.id);
        for (const attr of ['data-testid', 'data-test', 'data-cy', 'name', 'aria-label']) {
          const v = el.getAttribute(attr);
          if (v) { const s = el.tagName.toLowerCase() + '[' + attr + '="' + CSS.escape(v) + '"]'; if (unique(s)) return s; }
        }
        const parts = [];
        for (let node = el; node && node.nodeType === 1 && node !== document.documentElement; node = node.parentElement) {
          if (node !== el && node.id && unique('#' + CSS.escape(node.id))) { parts.unshift('#' + CSS.escape(node.id)); break; }
          let part = node.tagName.toLowerCase();
          const classes = [...node.classList].filter((c) => /^[A-Za-z][\w-]*$/.test(c) && c.length < 30).slice(0, 2);
          if (classes.length) part += '.' + classes.map((c) => CSS.escape(c)).join('.');
          const parent = node.parentElement;
          if (parent) {
            const same = [...parent.children].filter((c) => c.tagName === node.tagName);
            if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')';
          }
          parts.unshift(part);
          if (unique(parts.join(' > '))) break;
        }
        return parts.join(' > ');
      };
      const pickPayload = (el) => {
        const r = el.getBoundingClientRect(), s = getComputedStyle(el), src = V.source(el);
        let html = el.outerHTML || '';
        if (html.length > 600) {
          const open = html.slice(0, html.indexOf('>') + 1);
          html = open + squash(el.innerText, 200) + '…</' + el.tagName.toLowerCase() + '>';
        }
        const styles = {};
        for (const p of ['color', 'background-color', 'font-size', 'font-weight', 'padding', 'margin', 'border-radius']) {
          const v = s.getPropertyValue(p);
          if (v && !['0px', 'none', 'normal', 'rgba(0, 0, 0, 0)', '400'].includes(v)) styles[p] = v;
        }
        return { url: location.href, selector: selectorFor(el), tag: el.tagName.toLowerCase(), text: squash(el.innerText || name(el), 200), html,
          rect: { x: Math.round(r.left), y: Math.round(r.top), width: Math.round(r.width), height: Math.round(r.height) },
          styles, components: src.components, file: src.file, line: src.line };
      };
      const deepest = (x, y) => {
        let el = document.elementFromPoint(x, y);
        while (el && el.shadowRoot) { const inner = el.shadowRoot.elementFromPoint(x, y); if (!inner || inner === el) break; el = inner; }
        return el;
      };
      V.pick = {
        start() {
          if (V.picking) return;
          V.picking = true;
          const box = document.createElement('div'), tag = document.createElement('div');
          box.setAttribute('data-viber-ui', ''); tag.setAttribute('data-viber-ui', '');
          box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #0a84ff;background:rgba(10,132,255,.12);border-radius:2px;display:none';
          tag.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;background:#0a84ff;color:#fff;font:11px/1.4 -apple-system,sans-serif;padding:2px 6px;border-radius:4px;white-space:nowrap;display:none';
          document.documentElement.append(box, tag);
          let current = null;
          const move = (e) => {
            const el = deepest(e.clientX, e.clientY);
            if (!el || el === current || el.hasAttribute('data-viber-ui')) return;
            current = el;
            const r = el.getBoundingClientRect(), src = V.source(el);
            Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
            let label = el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (el.classList[0] ? '.' + el.classList[0] : '') + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
            if (src.components[0]) label += '  ·  ' + src.components[0];
            tag.textContent = label;
            Object.assign(tag.style, { display: 'block', left: Math.max(2, r.left) + 'px', top: (r.top > 24 ? r.top - 22 : r.bottom + 4) + 'px' });
          };
          const block = (e) => { e.preventDefault(); e.stopImmediatePropagation(); };
          const stop = () => {
            V.picking = false; box.remove(); tag.remove();
            removeEventListener('mousemove', move, true);
            for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) removeEventListener(type, block, true);
            removeEventListener('click', click, true);
            removeEventListener('keydown', key, true);
            V.pick.cancel = null;
          };
          const click = (e) => {
            block(e);
            const el = deepest(e.clientX, e.clientY) || current;
            stop();
            if (el) post({ type: 'pick', payload: pickPayload(el) }); else post({ type: 'pickEnd' });
          };
          const key = (e) => { if (e.key === 'Escape') { block(e); stop(); post({ type: 'pickEnd' }); } };
          addEventListener('mousemove', move, true);
          for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) addEventListener(type, block, true);
          addEventListener('click', click, true);
          addEventListener('keydown', key, true);
          V.pick.cancel = stop;
        },
        stop() { if (V.pick.cancel) V.pick.cancel(); },
      };
    })();
    """#
}
