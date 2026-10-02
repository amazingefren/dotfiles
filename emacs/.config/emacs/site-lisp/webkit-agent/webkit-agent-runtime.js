/**
 * Page runtime for webkit-agent.
 *
 * The file is one arrow function.  Called with a version string, it installs
 * the runtime as `window.__webkitAgent` unless that version is already
 * installed, and returns it.  `invoke(method, args)` always returns a JSON
 * string: {value}, {error}, or {async: token} for a pending promise, whose
 * outcome `invoke("take", {token})` returns as {value}, {error} or {pending}.
 */
(version) => {
  const installed = window.__webkitAgent;
  if (installed && installed.version === version) return installed;

  const MAX_CONSOLE_ENTRIES = 1000;
  const MAX_SNAPSHOT_LINES = 3000;
  const INTERACTIVE_ROLES = new Set([
    'button', 'checkbox', 'combobox', 'link', 'listbox', 'menuitem', 'menuitemcheckbox',
    'menuitemradio', 'option', 'radio', 'searchbox', 'slider', 'spinbutton', 'switch', 'tab',
    'textbox', 'treeitem',
  ]);
  const STRUCTURAL_ROLES = new Set([
    'alert', 'alertdialog', 'article', 'banner', 'cell', 'columnheader', 'complementary',
    'contentinfo', 'dialog', 'figure', 'form', 'grid', 'group', 'heading', 'iframe', 'img', 'list',
    'listitem', 'main', 'menu', 'menubar', 'meter', 'navigation', 'paragraph', 'progressbar',
    'radiogroup', 'region', 'row', 'rowheader', 'search', 'separator', 'status', 'table', 'tablist',
    'tabpanel', 'toolbar', 'tree',
  ]);
  const NAME_FROM_CONTENT = new Set([
    'button', 'cell', 'checkbox', 'columnheader', 'generic', 'heading', 'link', 'menuitem',
    'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'rowheader', 'switch', 'tab',
    'treeitem',
  ]);
  const CONTROL_SELECTOR = 'a[href], button, input, select, textarea, [role=button], [role=link], [role=checkbox], [role=tab], [role=menuitem]';
  const SKIPPED_TAGS = new Set(['head', 'link', 'meta', 'noscript', 'script', 'style', 'template', 'title']);
  const NAMED_KEYS = {
    ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, ArrowUp: 38, Backspace: 8, Delete: 46, End: 35,
    Enter: 13, Escape: 27, Home: 36, PageDown: 34, PageUp: 33, Tab: 9,
  };
  const KEY_ALIASES = { Esc: 'Escape', Return: 'Enter', Space: ' ', Spacebar: ' ' };
  const MODIFIERS = { Alt: 'altKey', Control: 'ctrlKey', Ctrl: 'ctrlKey', Meta: 'metaKey', Shift: 'shiftKey' };

  const consoleEntries = installed ? installed.consoleEntries : [];
  const asyncResults = new Map();
  let refs = new Map();
  let refCount = 0;
  let asyncCount = 0;

  /** Returns TEXT with runs of whitespace collapsed and ends trimmed. */
  const normalize = (text) => String(text ?? '').replace(/\s+/g, ' ').trim();

  /** Returns TEXT cut to LIMIT characters, marking the cut with an ellipsis. */
  const truncate = (text, limit) => (text.length > limit ? `${text.slice(0, limit)}…` : text);

  /** Returns TEXT as a double-quoted string cut to LIMIT characters. */
  const quote = (text, limit) => JSON.stringify(truncate(text, limit));

  /** Returns a readable message for a thrown ERROR. */
  const errorText = (error) => {
    if (!(error instanceof Error)) return String(error);
    return error.name === 'Error' ? error.message : `${error.name}: ${error.message}`;
  };

  /** Returns a short tag#id.class description of element EL. */
  const describe = (el) => {
    const id = el.id ? `#${el.id}` : '';
    const classes = typeof el.className === 'string'
      ? el.className.split(/\s+/).filter(Boolean).slice(0, 2).map((name) => `.${name}`).join('')
      : '';
    return `${el.localName}${id}${classes}`;
  };

  /** Returns VALUE converted to JSON-safe data, describing DOM nodes, cycles and functions. */
  const toJSONValue = (value, seen = new WeakSet(), depth = 0) => {
    if (value === undefined || value === null) return null;
    if (typeof value === 'boolean' || typeof value === 'string') return value;
    if (typeof value === 'number') return Number.isFinite(value) ? value : String(value);
    if (typeof value === 'bigint') return `${value}n`;
    if (typeof value === 'function') return `[Function ${value.name || 'anonymous'}]`;
    if (typeof value === 'symbol') return value.toString();
    if (value instanceof Element) return `[Element ${describe(value)}]`;
    if (value instanceof Node) return `[${value.nodeName}]`;
    if (value instanceof Error) return errorText(value);
    if (value instanceof Date) return value.toISOString();
    if (seen.has(value)) return '[Circular]';
    if (depth > 20) return '[Nested too deeply]';
    seen.add(value);
    if (Array.isArray(value) || value instanceof NodeList || value instanceof HTMLCollection || value instanceof Set) {
      return Array.from(value, (item) => toJSONValue(item, seen, depth + 1));
    }
    if (value instanceof Map) {
      return Object.fromEntries(Array.from(value, ([key, item]) => [String(key), toJSONValue(item, seen, depth + 1)]));
    }
    return Object.fromEntries(Object.keys(value).map((key) => [key, toJSONValue(value[key], seen, depth + 1)]));
  };

  /** Returns the focused element, descending into shadow roots and same-origin frames. */
  const deepActiveElement = () => {
    let active = document.activeElement;
    while (active) {
      const inner = active.shadowRoot?.activeElement
        ?? (active.localName === 'iframe' ? frameDocument(active)?.activeElement : null);
      if (!inner || inner === active) break;
      active = inner;
    }
    return active;
  };

  /** Returns the document of same-origin IFRAME, or null. */
  const frameDocument = (iframe) => {
    try {
      return iframe.contentDocument;
    } catch {
      return null;
    }
  };

  /** Returns the child nodes of NODE in the composed (rendered) tree. */
  const composedChildren = (node) => {
    if (node.shadowRoot) return Array.from(node.shadowRoot.childNodes);
    if (node.localName === 'slot') {
      const assigned = node.assignedNodes({ flatten: true });
      if (assigned.length) return assigned;
    }
    if (node.localName === 'iframe') {
      const body = frameDocument(node)?.body;
      return body ? [body] : [];
    }
    return Array.from(node.childNodes);
  };

  /** Returns every element under ROOT, including open shadow roots and same-origin frames. */
  const allElements = (root = document) => {
    const elements = [];
    const walk = (node) => {
      for (const child of composedChildren(node)) {
        if (child.nodeType !== Node.ELEMENT_NODE) continue;
        elements.push(child);
        walk(child);
      }
    };
    walk(root.nodeType === Node.DOCUMENT_NODE ? root.documentElement : root);
    return elements;
  };

  /** Returns elements matching CSS SELECTOR in the document, open shadow roots and same-origin frames. */
  const deepQueryAll = (selector) => {
    const scopes = [document, ...allElements().flatMap((el) => {
      const scope = el.shadowRoot ?? (el.localName === 'iframe' ? frameDocument(el) : null);
      return scope ? [scope] : [];
    })];
    try {
      return scopes.flatMap((scope) => Array.from(scope.querySelectorAll(selector)));
    } catch {
      throw new Error(`Invalid CSS selector: ${selector}`);
    }
  };

  /** Returns whether EL has a rendered box and is not visibility-hidden. */
  const isVisible = (el) => {
    const style = el.ownerDocument.defaultView.getComputedStyle(el);
    if (style.visibility === 'hidden' || style.visibility === 'collapse') return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };

  /** Returns the implicit ARIA role of input element EL. */
  const inputRole = (el) => {
    switch (el.type) {
      case 'button': case 'file': case 'image': case 'reset': case 'submit': return 'button';
      case 'checkbox': return 'checkbox';
      case 'hidden': return null;
      case 'number': return 'spinbutton';
      case 'radio': return 'radio';
      case 'range': return 'slider';
      case 'search': return el.list ? 'combobox' : 'searchbox';
      default: return el.list ? 'combobox' : 'textbox';
    }
  };

  /** Returns the ARIA role of EL, explicit or implicit, or null for generic elements. */
  const roleOf = (el) => {
    const explicit = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
    if (explicit === 'none' || explicit === 'presentation') return null;
    if (explicit) return explicit;
    const tag = el.localName;
    if (/^h[1-6]$/.test(tag)) return 'heading';
    switch (tag) {
      case 'a': case 'area': return el.hasAttribute('href') ? 'link' : null;
      case 'article': return 'article';
      case 'aside': return 'complementary';
      case 'button': case 'summary': return 'button';
      case 'details': case 'fieldset': return 'group';
      case 'dialog': return 'dialog';
      case 'figure': return 'figure';
      case 'footer': return el.closest('article, aside, main, nav, section') ? null : 'contentinfo';
      case 'form': return 'form';
      case 'header': return el.closest('article, aside, main, nav, section') ? null : 'banner';
      case 'hr': return 'separator';
      case 'iframe': return 'iframe';
      case 'img': return el.getAttribute('alt') === '' ? null : 'img';
      case 'input': return inputRole(el);
      case 'li': return 'listitem';
      case 'main': return 'main';
      case 'menu': case 'ol': case 'ul': return 'list';
      case 'meter': return 'meter';
      case 'nav': return 'navigation';
      case 'option': return 'option';
      case 'p': return 'paragraph';
      case 'progress': return 'progressbar';
      case 'search': return 'search';
      case 'section': return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : null;
      case 'select': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
      case 'table': return 'table';
      case 'td': return 'cell';
      case 'textarea': return 'textbox';
      case 'th': return 'columnheader';
      case 'tr': return 'row';
      default: break;
    }
    if (el.isContentEditable && !el.parentElement?.isContentEditable) return 'textbox';
    return null;
  };

  /** Returns the accessible name of EL with ROLE, at most 120 characters. */
  const accessibleName = (el, role) => {
    const labelledBy = el.getAttribute('aria-labelledby');
    if (labelledBy) {
      const labels = labelledBy.split(/\s+/).map((id) => el.ownerDocument.getElementById(id)).filter(Boolean);
      const text = normalize(labels.map((label) => label.innerText || label.textContent).join(' '));
      if (text) return truncate(text, 120);
    }
    const ariaLabel = normalize(el.getAttribute('aria-label'));
    if (ariaLabel) return truncate(ariaLabel, 120);
    if (el.labels?.length) {
      const text = normalize(Array.from(el.labels, (label) => label.innerText).join(' '));
      if (text) return truncate(text, 120);
    }
    if (el.localName === 'input' && ['button', 'reset', 'submit'].includes(el.type)) {
      return truncate(normalize(el.value) || (el.type === 'reset' ? 'Reset' : el.type === 'submit' ? 'Submit' : ''), 120);
    }
    if (el.localName === 'img' || el.localName === 'area' || (el.localName === 'input' && el.type === 'image')) {
      return truncate(normalize(el.getAttribute('alt')), 120);
    }
    const caption = { fieldset: 'legend', figure: 'figcaption', table: 'caption' }[el.localName];
    if (caption) {
      const text = normalize(el.querySelector(`:scope > ${caption}`)?.innerText);
      if (text) return truncate(text, 120);
    }
    if (NAME_FROM_CONTENT.has(role)) {
      const text = normalize(el.innerText ?? el.textContent);
      if (text) return truncate(text, 120);
      const labelled = el.querySelector('[aria-label], img[alt], svg title');
      const inner = normalize(labelled?.getAttribute('aria-label') ?? labelled?.getAttribute('alt') ?? labelled?.textContent);
      if (inner) return truncate(inner, 120);
    }
    return truncate(normalize(el.getAttribute('title') || el.getAttribute('placeholder')), 120);
  };

  /**
   * Returns whether EL with ROLE and computed STYLE accepts clicks or input.
   * Elements without an interactive role count only when they contain no
   * native controls, which keeps clickable containers out.
   */
  const isInteractive = (el, role, style, parentCursor) => {
    if (INTERACTIVE_ROLES.has(role)) return true;
    const clickable = (el.hasAttribute('tabindex') && el.tabIndex >= 0) || el.onclick || el.hasAttribute('onclick')
      || (style.cursor === 'pointer' && parentCursor !== 'pointer');
    return Boolean(clickable) && !el.querySelector(CONTROL_SELECTOR);
  };

  /** Returns the snapshot tags ([checked], [level=2], ...) describing EL's state. */
  const stateTags = (el, role) => {
    const tags = [];
    if (role === 'heading') tags.push(`level=${el.getAttribute('aria-level') || (/^h[1-6]$/.test(el.localName) ? el.localName[1] : 2)}`);
    const checked = el.localName === 'input' && ['checkbox', 'radio'].includes(el.type)
      ? (el.indeterminate ? 'mixed' : String(el.checked))
      : el.getAttribute('aria-checked');
    if (checked === 'true') tags.push('checked');
    if (checked === 'mixed') tags.push('checked=mixed');
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') tags.push('disabled');
    const expanded = el.getAttribute('aria-expanded') ?? (el.localName === 'details' ? String(el.open) : null);
    if (expanded) tags.push(`expanded=${expanded}`);
    if (el.selected || el.getAttribute('aria-selected') === 'true') tags.push('selected');
    const pressed = el.getAttribute('aria-pressed');
    if (pressed) tags.push(`pressed=${pressed}`);
    if (el.required || el.getAttribute('aria-required') === 'true') tags.push('required');
    if (el.localName === 'input' && el.type === 'file') tags.push('type=file');
    if (el.readOnly) tags.push('readonly');
    if (el === deepActiveElement()) tags.push('focused');
    return tags;
  };

  /** Returns the current value of form control EL for display, or null. */
  const displayValue = (el) => {
    if (el.localName === 'select') return Array.from(el.selectedOptions, (option) => normalize(option.label)).join(', ');
    if (el.localName === 'textarea' || (el.localName === 'input' && !['button', 'checkbox', 'file', 'hidden', 'image', 'radio', 'reset', 'submit'].includes(el.type))) {
      if (!el.value) return null;
      return el.type === 'password' ? '•'.repeat(Math.min(el.value.length, 12)) : el.value;
    }
    return null;
  };

  /** Returns link EL's href, relative when it is on the page's origin. */
  const displayHref = (el) => {
    try {
      const url = new URL(el.href, location.href);
      return url.origin === location.origin ? `${url.pathname}${url.search}${url.hash}` : url.href;
    } catch {
      return el.getAttribute('href');
    }
  };

  /** Records EL under a fresh ref and returns the ref. */
  const assignRef = (el) => {
    refCount += 1;
    const ref = `e${refCount}`;
    refs.set(ref, el);
    return ref;
  };

  /**
   * Returns snapshot tree nodes for NODE: {text} or {role, name, ref, tags, value, url, children}.
   * Generic elements are flattened into their children.
   */
  const buildNodes = (node, context) => {
    if (node.nodeType === Node.TEXT_NODE) {
      const text = normalize(node.textContent);
      return text && context.showText && context.visible ? [{ text }] : [];
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return [];
    const el = node;
    if (SKIPPED_TAGS.has(el.localName) || el.hidden || el.getAttribute('aria-hidden') === 'true') return [];
    const style = el.ownerDocument.defaultView.getComputedStyle(el);
    if (style.display === 'none') return [];
    const visible = style.visibility !== 'hidden' && style.visibility !== 'collapse';
    const rect = el.getBoundingClientRect();
    const hasBox = visible && rect.width > 0 && rect.height > 0;
    const role = roleOf(el);
    const interactive = hasBox && isInteractive(el, role, style, context.cursor);
    const labelsControl = el.localName === 'label' && el.control;
    const childContext = { ...context, cursor: style.cursor, showText: context.showText && !labelsControl, visible };
    const emitted = interactive || (!context.interactiveOnly && visible && STRUCTURAL_ROLES.has(role));
    if (!emitted) return composedChildren(el).flatMap((child) => buildNodes(child, childContext));
    const shownRole = role ?? 'generic';
    const entry = { name: accessibleName(el, shownRole), role: shownRole, tags: stateTags(el, shownRole) };
    if (interactive) entry.ref = assignRef(el);
    const value = displayValue(el);
    if (value) entry.value = value;
    if (shownRole === 'link' && el.href) entry.url = displayHref(el);
    if (el.localName === 'iframe' && !frameDocument(el)) entry.name = entry.name || el.src;
    if (el.localName === 'select') entry.options = Array.from(el.options, (option) => normalize(option.label));
    const childrenContext = { ...childContext, showText: childContext.showText && !NAME_FROM_CONTENT.has(shownRole) };
    const leaf = el.localName === 'select' || el.localName === 'textarea';
    entry.children = leaf ? [] : mergeText(composedChildren(el).flatMap((child) => buildNodes(child, childrenContext)));
    return context.interactiveOnly ? [{ ...entry, children: [] }, ...entry.children] : [entry];
  };

  /** Returns NODES with adjacent text nodes joined. */
  const mergeText = (nodes) => nodes.reduce((merged, node) => {
    const previous = merged[merged.length - 1];
    if (node.text !== undefined && previous?.text !== undefined) previous.text = `${previous.text} ${node.text}`;
    else merged.push(node);
    return merged;
  }, []);

  /** Appends the YAML-like lines for NODES at DEPTH to LINES, honoring MAX_DEPTH. */
  const renderNodes = (nodes, depth, lines, maxDepth) => {
    for (const node of nodes) {
      if (lines.length >= MAX_SNAPSHOT_LINES) return;
      const indent = '  '.repeat(depth);
      if (node.text !== undefined) {
        lines.push(`${indent}- text: ${quote(node.text, 300)}`);
        continue;
      }
      const name = node.name ? ` ${quote(node.name, 120)}` : '';
      const tags = [node.ref && `ref=${node.ref}`, ...node.tags].filter(Boolean).map((tag) => ` [${tag}]`).join('');
      const value = node.value ? ` value=${quote(node.value, 120)}` : '';
      const url = node.url ? ` url=${truncate(node.url, 160)}` : '';
      const options = node.options ? ` options=${JSON.stringify(node.options.slice(0, 25))}${node.options.length > 25 ? '…' : ''}` : '';
      const onlyText = node.children.length === 1 && node.children[0].text !== undefined && !node.name;
      if (onlyText) {
        lines.push(`${indent}- ${node.role}${tags}${value}${url}${options}: ${quote(node.children[0].text, 300)}`);
        continue;
      }
      lines.push(`${indent}- ${node.role}${name}${tags}${value}${url}${options}`);
      if (maxDepth === undefined || depth < maxDepth) renderNodes(node.children, depth + 1, lines, maxDepth);
    }
  };

  /** Returns NODES without unnamed, childless, ref-less structural nodes. */
  const prune = (nodes) => nodes.flatMap((node) => {
    if (node.text !== undefined) return [node];
    const children = prune(node.children);
    if (!node.ref && !node.name && !children.length && !['img', 'separator'].includes(node.role)) return [];
    return [{ ...node, children }];
  });

  /** Returns the elements LOCATOR (a ref, CSS selector or locator object) matches, visible ones first. */
  const locate = (locator) => {
    if (typeof locator === 'string') {
      const ref = locator.replace(/^@/, '');
      if (/^e\d+$/.test(ref)) {
        const el = refs.get(ref);
        if (!el || !el.isConnected) throw new Error(`Ref ${ref} is unknown or stale; take a new snapshot`);
        return [el];
      }
      return sortVisibleFirst(deepQueryAll(locator));
    }
    if (!locator || typeof locator !== 'object') throw new Error('target must be a ref, a CSS selector, or a locator object');
    const exact = locator.exact === true;
    const matches = (value, wanted) => {
      const text = normalize(value);
      return exact ? text === normalize(wanted) : text.toLowerCase().includes(normalize(wanted).toLowerCase());
    };
    let candidates = locator.css ? deepQueryAll(locator.css) : allElements();
    if (locator.role) candidates = candidates.filter((el) => roleOf(el) === locator.role || (locator.role === 'generic' && !roleOf(el)));
    if (locator.name !== undefined) candidates = candidates.filter((el) => matches(accessibleName(el, roleOf(el) ?? 'generic'), locator.name));
    if (locator.label !== undefined) {
      candidates = candidates.filter((el) => ('labels' in el || el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby'))
        && matches(accessibleName(el, roleOf(el)), locator.label));
    }
    if (locator.placeholder !== undefined) candidates = candidates.filter((el) => el.hasAttribute('placeholder') && matches(el.getAttribute('placeholder'), locator.placeholder));
    if (locator.alt !== undefined) candidates = candidates.filter((el) => el.hasAttribute('alt') && matches(el.getAttribute('alt'), locator.alt));
    if (locator.title !== undefined) candidates = candidates.filter((el) => el.hasAttribute('title') && matches(el.getAttribute('title'), locator.title));
    if (locator.testid !== undefined) candidates = candidates.filter((el) => el.getAttribute('data-testid') === locator.testid);
    if (locator.text !== undefined) {
      const containing = candidates.filter((el) => matches(el.innerText ?? el.textContent, locator.text));
      const containingSet = new Set(containing);
      candidates = containing.filter((el) => !Array.from(el.children).some((child) => containingSet.has(child)));
    }
    return sortVisibleFirst(candidates);
  };

  /** Returns ELEMENTS with visible ones first, otherwise in document order. */
  const sortVisibleFirst = (elements) => [...elements.filter(isVisible), ...elements.filter((el) => !isVisible(el))];

  /** Returns the single element TARGET (with optional NTH) resolves to, or throws a diagnostic error. */
  const resolve = (target, nth = 0) => {
    const elements = locate(target);
    if (elements.length <= nth) {
      const shown = typeof target === 'string' ? target : JSON.stringify(target);
      throw new Error(`No element matches ${shown}${nth ? ` at index ${nth}` : ''} (${elements.length} found) on ${location.href}; take a snapshot to find a ref`);
    }
    return elements[nth];
  };

  /** Returns TARGET's element, or the focused element when TARGET is absent. */
  const resolveOrActive = (args) => {
    if (args.target !== undefined) return resolve(args.target, args.nth);
    const active = deepActiveElement();
    if (!active || active === document.body) throw new Error('No target given and nothing is focused');
    return active;
  };

  /** Scrolls EL into the viewport's center when it is outside the viewport. */
  const reveal = (el) => {
    const rect = el.getBoundingClientRect();
    const view = el.ownerDocument.defaultView;
    if (rect.top < 0 || rect.left < 0 || rect.bottom > view.innerHeight || rect.right > view.innerWidth) {
      el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'center' });
    }
  };

  /** Returns EL's center point in its frame's viewport coordinates. */
  const centerOf = (el) => {
    const rect = el.getBoundingClientRect();
    return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
  };

  /** Dispatches a mouse or pointer event TYPE at EL; returns false when it was cancelled. */
  const mouseEvent = (el, type, point, extra = {}) => {
    const view = el.ownerDocument.defaultView;
    const bubbles = !type.endsWith('enter') && !type.endsWith('leave');
    const init = {
      bubbles, button: 0, buttons: 0, cancelable: bubbles, clientX: point.x, clientY: point.y, composed: true,
      detail: 1, screenX: point.x, screenY: point.y, view, ...extra,
    };
    const event = type.startsWith('pointer')
      ? new view.PointerEvent(type, { isPrimary: true, pointerId: 1, pointerType: 'mouse', ...init })
      : new view.MouseEvent(type, init);
    return el.dispatchEvent(event);
  };

  /** Dispatches the events of moving the mouse onto EL. */
  const hoverElement = (el, point) => {
    for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) {
      mouseEvent(el, type, point);
    }
  };

  /** Returns a description of the element covering EL's center, or null when EL is on top. */
  const coveringElement = (el, point) => {
    const top = el.getRootNode().elementFromPoint?.(point.x, point.y) ?? el.ownerDocument.elementFromPoint(point.x, point.y);
    if (!top || top === el || el.contains(top) || top.contains(el)) return null;
    if (el.labels && Array.from(el.labels).some((label) => label.contains(top))) return null;
    return describe(top);
  };

  /** Throws when EL is disabled. */
  const assertEnabled = (el) => {
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') throw new Error(`${describe(el)} is disabled`);
  };

  /** Clicks EL COUNT times with pointer, mouse and focus events; returns warnings. */
  const clickElement = (el, count = 1) => {
    assertEnabled(el);
    reveal(el);
    const point = centerOf(el);
    const covered = coveringElement(el, point);
    hoverElement(el, point);
    for (let click = 1; click <= count; click += 1) {
      mouseEvent(el, 'pointerdown', point, { buttons: 1, detail: click });
      const focusAllowed = mouseEvent(el, 'mousedown', point, { buttons: 1, detail: click });
      if (focusAllowed) el.closest('a[href], button, input, select, summary, textarea, [contenteditable], [tabindex]')?.focus({ preventScroll: true });
      mouseEvent(el, 'pointerup', point, { detail: click });
      mouseEvent(el, 'mouseup', point, { detail: click });
      mouseEvent(el, 'click', point, { detail: click });
    }
    if (count === 2) mouseEvent(el, 'dblclick', point, { detail: 2 });
    return covered ? { covered_by: covered } : {};
  };

  /** Focuses EL, scrolling it into view first. */
  const focusElement = (el) => {
    reveal(el);
    el.focus({ preventScroll: true });
  };

  /** Returns whether EL accepts typed text. */
  const isEditable = (el) => el.isContentEditable || el.localName === 'textarea'
    || (el.localName === 'input' && ['combobox', 'searchbox', 'spinbutton', 'textbox'].includes(inputRole(el)));

  /** Sets form control EL's value through the native setter and dispatches input. */
  const setNativeValue = (el, value) => {
    const prototype = Object.getPrototypeOf(el);
    const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
    if (setter) setter.call(el, value);
    else el.value = value;
    el.dispatchEvent(new (el.ownerDocument.defaultView.InputEvent)('input', { bubbles: true, composed: true, data: value, inputType: 'insertText' }));
  };

  /** Inserts TEXT at EL's caret as typing would; EL must be focused. */
  const insertText = (el, text) => {
    const doc = el.ownerDocument;
    if (doc.execCommand('insertText', false, text)) return;
    if (el.isContentEditable) throw new Error(`Could not insert text into ${describe(el)}`);
    const start = el.selectionStart ?? el.value.length;
    const end = el.selectionEnd ?? el.value.length;
    setNativeValue(el, `${el.value.slice(0, start)}${text}${el.value.slice(end)}`);
  };

  /** Replaces the contents of text field EL with TEXT. */
  const fillElement = (el, text) => {
    assertEnabled(el);
    if (el.localName === 'select') throw new Error(`${describe(el)} is a select; use the select action`);
    if (!isEditable(el)) throw new Error(`${describe(el)} is not a text field`);
    focusElement(el);
    const doc = el.ownerDocument;
    if (el.isContentEditable) {
      const range = doc.createRange();
      range.selectNodeContents(el);
      const selection = doc.defaultView.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      if (text) insertText(el, text);
      else doc.execCommand('delete');
      return;
    }
    try {
      el.select();
    } catch {
      // Some input types have no text selection.
    }
    const inserted = text ? doc.execCommand('insertText', false, text) : doc.execCommand('delete');
    if (!inserted || el.value !== text) setNativeValue(el, text);
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };

  /** Returns KeyboardEvent fields for key NAME (a named key or one character). */
  const keyFields = (name) => {
    const key = KEY_ALIASES[name] ?? name;
    if (NAMED_KEYS[key]) return { code: key, key, keyCode: NAMED_KEYS[key] };
    if (/^F([1-9]|1[0-2])$/.test(key)) return { code: key, key, keyCode: 111 + Number(key.slice(1)) };
    if ([...key].length !== 1) throw new Error(`Unknown key ${name}`);
    const upper = key.toUpperCase();
    const code = /[a-z]/i.test(key) ? `Key${upper}` : /\d/.test(key) ? `Digit${key}` : key === ' ' ? 'Space' : '';
    return { code, key, keyCode: upper.charCodeAt(0) };
  };

  /** Parses a key COMBO like "Shift+Tab" into key fields and modifier flags. */
  const parseCombo = (combo) => {
    const parts = combo === '+' ? ['+'] : combo.split('+').map((part) => part || '+');
    const keyName = parts.pop();
    const modifiers = { altKey: false, ctrlKey: false, metaKey: false, shiftKey: false };
    for (const part of parts) {
      if (!MODIFIERS[part]) throw new Error(`Unknown modifier ${part} in ${combo}`);
      modifiers[MODIFIERS[part]] = true;
    }
    return { ...keyFields(keyName), ...modifiers };
  };

  /** Dispatches keyboard event TYPE for KEY at EL; returns false when it was cancelled. */
  const keyEvent = (el, type, key) => {
    const view = el.ownerDocument.defaultView;
    const event = new view.KeyboardEvent(type, { bubbles: true, cancelable: true, composed: true, view, ...key });
    Object.defineProperties(event, {
      charCode: { get: () => (type === 'keypress' ? key.key.charCodeAt(0) : 0) },
      keyCode: { get: () => key.keyCode },
      which: { get: () => key.keyCode },
    });
    return el.dispatchEvent(event);
  };

  /** Returns the focusable elements of EL's document in tab order. */
  const tabOrder = (el) => {
    const focusable = Array.from(el.ownerDocument.querySelectorAll(
      'a[href], area[href], button, input, select, summary, textarea, iframe, [contenteditable], [tabindex]',
    )).filter((candidate) => candidate.tabIndex >= 0 && !candidate.disabled && isVisible(candidate));
    const positive = focusable.filter((candidate) => candidate.tabIndex > 0).sort((a, b) => a.tabIndex - b.tabIndex);
    return [...positive, ...focusable.filter((candidate) => candidate.tabIndex === 0)];
  };

  /** Performs the browser's default action for KEY pressed in EL. */
  const keyDefault = (el, key) => {
    const textField = isEditable(el) && !el.readOnly;
    const command = key.ctrlKey || key.metaKey;
    if (key.key === 'Tab') {
      const order = tabOrder(el);
      const index = order.indexOf(el);
      const next = order[(index + (key.shiftKey ? -1 : 1) + order.length) % order.length];
      next?.focus();
    } else if (key.key === 'Enter') {
      if (el.localName === 'textarea' || el.isContentEditable) insertText(el, '\n');
      else if (el.form && el.localName === 'input') {
        const submitter = el.form.querySelector('button:not([type]), button[type=submit], input[type=submit], input[type=image]');
        if (submitter) clickElement(submitter);
        else el.form.requestSubmit();
      } else if (['a', 'button', 'summary'].includes(el.localName) || roleOf(el) === 'button' || roleOf(el) === 'link') clickElement(el);
    } else if (key.key === ' ' && !textField && ['button', 'checkbox', 'radio', 'switch', 'tab', 'menuitem', 'option'].includes(roleOf(el))) {
      clickElement(el);
    } else if (key.key === 'Backspace' && textField) {
      el.ownerDocument.execCommand('delete');
    } else if (key.key === 'Delete' && textField) {
      el.ownerDocument.execCommand('forwardDelete');
    } else if (command && key.key.toLowerCase() === 'a' && textField) {
      if (el.select) el.select();
      else el.ownerDocument.execCommand('selectAll');
    } else if (!command && [...key.key].length === 1 && textField) {
      insertText(el, key.key);
    }
  };

  /** Presses key COMBO in EL: keydown, keypress, default action, keyup. */
  const pressKey = (el, combo) => {
    const key = parseCombo(combo);
    const allowed = keyEvent(el, 'keydown', key);
    const printable = [...key.key].length === 1 || key.key === 'Enter';
    const pressAllowed = allowed && printable && !key.ctrlKey && !key.metaKey ? keyEvent(el, 'keypress', key) : allowed;
    if (allowed && pressAllowed) keyDefault(el, key);
    keyEvent(deepActiveElement() ?? el, 'keyup', key);
  };

  /** Selects the options of select EL whose value or label is in VALUES. */
  const selectOptions = (el, values) => {
    if (el.localName !== 'select') throw new Error(`${describe(el)} is not a select; click its options instead`);
    assertEnabled(el);
    const wanted = Array.isArray(values) ? values : [values];
    const options = Array.from(el.options);
    const chosen = wanted.map((value) => {
      const option = options.find((candidate) => candidate.value === value || normalize(candidate.label) === normalize(value));
      if (!option) {
        const available = options.slice(0, 30).map((candidate) => JSON.stringify(normalize(candidate.label))).join(', ');
        throw new Error(`${describe(el)} has no option ${JSON.stringify(value)}; options: ${available}`);
      }
      return option;
    });
    if (!el.multiple && chosen.length > 1) throw new Error(`${describe(el)} accepts one option`);
    for (const option of options) option.selected = chosen.includes(option);
    el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return chosen.map((option) => option.value);
  };

  /** Returns whether checkbox-like EL is checked. */
  const isChecked = (el) => (el.localName === 'input' ? el.checked : el.getAttribute('aria-checked') === 'true');

  /** Clicks EL until its checked state is WANTED, or throws. */
  const setChecked = (el, wanted) => {
    const control = el.localName === 'label' && el.control ? el.control : el;
    if (isChecked(control) !== wanted) clickElement(control);
    if (isChecked(control) !== wanted) throw new Error(`${describe(control)} did not become ${wanted ? 'checked' : 'unchecked'}`);
  };

  /** Sets file input EL's files to FILES ({name, type, base64}) and dispatches change. */
  const uploadFiles = (el, files) => {
    if (el.localName !== 'input' || el.type !== 'file') throw new Error(`${describe(el)} is not a file input`);
    const view = el.ownerDocument.defaultView;
    const transfer = new view.DataTransfer();
    for (const file of files) {
      const bytes = Uint8Array.from(atob(file.base64), (char) => char.charCodeAt(0));
      transfer.items.add(new view.File([bytes], file.name, { type: file.type }));
    }
    el.files = transfer.files;
    el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };

  /** Returns page and scroll metadata. */
  const pageInfo = () => ({
    ready_state: document.readyState,
    scroll: { x: window.scrollX, y: window.scrollY },
    title: document.title,
    url: location.href,
    viewport: { height: window.innerHeight, width: window.innerWidth },
  });

  /** Returns the visibility, enabled, checked, focus and editability state of EL. */
  const elementState = (el) => ({
    checked: isChecked(el),
    editable: isEditable(el) && !el.readOnly && !el.disabled,
    enabled: !el.disabled && el.getAttribute('aria-disabled') !== 'true',
    focused: el === deepActiveElement(),
    visible: isVisible(el),
  });

  /** Appends a console entry of LEVEL with TEXT, dropping the oldest past the limit. */
  const record = (level, text) => {
    const entries = window.__webkitAgent?.consoleEntries ?? consoleEntries;
    entries.push({ level, text, time: new Date().toISOString() });
    if (entries.length > MAX_CONSOLE_ENTRIES) entries.splice(0, entries.length - MAX_CONSOLE_ENTRIES);
  };

  /** Returns console ARGS formatted as one line. */
  const formatArgs = (args) => args.map((arg) => (typeof arg === 'string' ? arg : JSON.stringify(toJSONValue(arg)))).join(' ');

  /** Records console methods, errors and dialogs once per page; confirm accepts and prompt takes its default. */
  const hookPage = () => {
    if (window.__webkitAgentHooked) return;
    window.__webkitAgentHooked = true;
    for (const level of ['debug', 'error', 'info', 'log', 'warn']) {
      const original = console[level].bind(console);
      console[level] = (...args) => {
        record(level, formatArgs(args));
        original(...args);
      };
    }
    window.addEventListener('error', (event) => record('error', `${event.message} (${event.filename}:${event.lineno}:${event.colno})`));
    window.addEventListener('unhandledrejection', (event) => record('error', `Unhandled rejection: ${formatArgs([event.reason])}`));
    window.alert = (message) => record('dialog', `alert: ${message ?? ''}`);
    window.confirm = (message) => {
      record('dialog', `confirm: ${message ?? ''} -> true`);
      return true;
    };
    window.prompt = (message, defaultValue) => {
      const answer = defaultValue ?? '';
      record('dialog', `prompt: ${message ?? ''} -> ${JSON.stringify(answer)}`);
      return answer;
    };
  };

  /** Returns whether wait condition ARGS holds now, with the observed detail. */
  const checkCondition = (args) => {
    if (args.target !== undefined) {
      const elements = locate(args.target);
      const state = args.state ?? 'visible';
      const visible = elements.some(isVisible);
      const met = { attached: elements.length > 0, detached: elements.length === 0, hidden: !visible, visible }[state];
      if (met === undefined) throw new Error(`Unknown state ${state}`);
      return { detail: `${elements.length} matching, ${visible ? 'visible' : 'none visible'}`, met };
    }
    if (args.text !== undefined) {
      const met = normalize(document.body?.innerText).includes(normalize(args.text));
      return { detail: met ? 'text present' : 'text absent', met: args.state === 'hidden' ? !met : met };
    }
    if (args.url_contains !== undefined) return { detail: location.href, met: location.href.includes(args.url_contains) };
    if (args.function !== undefined) {
      const value = (0, eval)(args.function);
      return { detail: JSON.stringify(toJSONValue(value)), met: Boolean(value) };
    }
    const order = ['loading', 'interactive', 'complete'];
    const wanted = args.load_state ?? 'complete';
    if (!order.includes(wanted)) throw new Error(`Unknown load_state ${wanted}`);
    return { detail: document.readyState, met: order.indexOf(document.readyState) >= order.indexOf(wanted) };
  };

  const methods = {
    /** Performs ARGS.action on ARGS.target and returns its outcome. */
    act: (args) => {
      const { action } = args;
      if (action === 'scroll') {
        const dy = args.dy ?? (args.dx === undefined ? Math.round(window.innerHeight * 0.8) : 0);
        const scroller = args.target !== undefined ? resolve(args.target, args.nth) : null;
        (scroller ?? window).scrollBy({ behavior: 'instant', left: args.dx ?? 0, top: dy });
        return { scroll: scroller ? { x: scroller.scrollLeft, y: scroller.scrollTop } : { x: window.scrollX, y: window.scrollY } };
      }
      const el = ['press', 'type'].includes(action) ? resolveOrActive(args) : resolve(args.target, args.nth);
      const result = { target: describe(el) };
      switch (action) {
        case 'check': setChecked(el, true); break;
        case 'clear': fillElement(el, ''); break;
        case 'click': Object.assign(result, clickElement(el)); break;
        case 'dblclick': Object.assign(result, clickElement(el, 2)); break;
        case 'fill':
          if (typeof args.text !== 'string') throw new Error('fill needs text');
          fillElement(el, args.text);
          break;
        case 'focus': focusElement(el); break;
        case 'hover': reveal(el); hoverElement(el, centerOf(el)); break;
        case 'press':
          if (!args.key) throw new Error('press needs key');
          if (args.target !== undefined) focusElement(el);
          pressKey(el, args.key);
          break;
        case 'scroll_into_view': el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'center' }); break;
        case 'select': result.selected = selectOptions(el, args.values); break;
        case 'type':
          if (typeof args.text !== 'string') throw new Error('type needs text');
          if (args.target !== undefined) focusElement(el);
          for (const char of args.text) pressKey(deepActiveElement() ?? el, char === '\n' ? 'Enter' : char);
          break;
        case 'uncheck': setChecked(el, false); break;
        case 'upload': uploadFiles(el, args.files ?? []); break;
        default: throw new Error(`Unknown action ${action}`);
      }
      return { ...result, url: location.href };
    },

    /** Returns whether wait condition ARGS currently holds. */
    check: checkCondition,

    /** Returns recorded console entries after index ARGS.since; ARGS.clear empties the log. */
    console: (args) => {
      const entries = consoleEntries.slice(args.since ?? 0);
      const total = consoleEntries.length;
      if (args.clear) consoleEntries.length = 0;
      return { entries, total };
    },

    /** Evaluates ARGS.script in the page's global scope and returns its completion value. */
    evaluate: (args) => (0, eval)(args.script),

    /** Returns ARGS.what (url, title, text, html, value, attr, count, box, state, styles) of ARGS.target or the page. */
    get: (args) => {
      const { what } = args;
      if (what === 'count') return locate(args.target).length;
      if (what === 'title') return document.title;
      if (what === 'url') return location.href;
      const el = args.target !== undefined ? resolve(args.target, args.nth) : null;
      const limit = args.max_chars ?? (what === 'html' ? 50000 : 20000);
      switch (what) {
        case 'attr':
          if (!el || !args.name) throw new Error('attr needs target and name');
          return el.getAttribute(args.name);
        case 'box': {
          if (!el) throw new Error('box needs target');
          const rect = el.getBoundingClientRect();
          return { height: rect.height, width: rect.width, x: rect.x, y: rect.y };
        }
        case 'html': {
          const html = (el ?? document.documentElement).outerHTML;
          return { text: html.slice(0, limit), total_chars: html.length, truncated: html.length > limit };
        }
        case 'state':
          if (!el) throw new Error('state needs target');
          return elementState(el);
        case 'styles': {
          if (!el || !Array.isArray(args.names)) throw new Error('styles needs target and names');
          const style = el.ownerDocument.defaultView.getComputedStyle(el);
          return Object.fromEntries(args.names.map((name) => [name, style.getPropertyValue(name)]));
        }
        case 'text': {
          const text = (el ?? document.body).innerText ?? '';
          return { text: text.slice(0, limit), total_chars: text.length, truncated: text.length > limit };
        }
        case 'value':
          if (!el) throw new Error('value needs target');
          return el.localName === 'select' && el.multiple ? Array.from(el.selectedOptions, (option) => option.value) : el.value;
        default: throw new Error(`Unknown get ${what}`);
      }
    },

    /** Returns page metadata. */
    info: pageInfo,

    /** Returns a snapshot of the page or of ARGS.selector, assigning fresh refs to interactive elements. */
    snapshot: (args) => {
      refs = new Map();
      refCount = 0;
      const roots = args.selector ? deepQueryAll(args.selector) : [document.body ?? document.documentElement];
      if (!roots.length) throw new Error(`No element matches ${args.selector}`);
      const context = { cursor: 'auto', interactiveOnly: args.interactive === true, showText: args.interactive !== true, visible: true };
      const nodes = prune(mergeText(roots.flatMap((root) => buildNodes(root, context))));
      const lines = [];
      renderNodes(nodes, 0, lines, args.max_depth);
      const truncated = lines.length >= MAX_SNAPSHOT_LINES;
      if (truncated) lines.push('- … truncated; pass selector or max_depth');
      return { ...pageInfo(), refs: refCount, snapshot: lines.join('\n'), truncated };
    },
  };

  /** Runs METHOD with ARGS and returns the JSON reply described in the file comment. */
  const invoke = (method, args) => {
    try {
      if (method === 'take') {
        const outcome = asyncResults.get(args.token);
        if (!outcome) return JSON.stringify({ error: 'The page navigated or reloaded before the script finished' });
        if (outcome.pending) return JSON.stringify({ pending: true });
        asyncResults.delete(args.token);
        return JSON.stringify(outcome);
      }
      const handler = methods[method];
      if (!handler) throw new Error(`Unknown method ${method}`);
      const value = handler(args ?? {});
      if (value && typeof value.then === 'function') {
        asyncCount += 1;
        const token = `a${asyncCount}`;
        asyncResults.set(token, { pending: true });
        value.then(
          (resolved) => asyncResults.set(token, { value: toJSONValue(resolved) }),
          (error) => asyncResults.set(token, { error: errorText(error) }),
        );
        return JSON.stringify({ async: token });
      }
      return JSON.stringify({ value: toJSONValue(value) });
    } catch (error) {
      return JSON.stringify({ error: errorText(error) });
    }
  };

  const agent = { consoleEntries, invoke, version };
  window.__webkitAgent = agent;
  hookPage();
  return agent;
}
