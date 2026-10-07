# Emacs native patches

Emacs 31.1 with xwidgets. Local patches are listed in `.config/emacs-plus/build.yml`.

## Build on a Mac

Run from the dotfiles checkout:

```sh
brew install stow
brew tap d12frosted/emacs-plus
stow --target="$HOME" emacs-plus
brew install emacs-plus@31 --with-xwidgets
```

For an existing installation, quit Emacs and rebuild:

```sh
brew reinstall emacs-plus@31 --with-xwidgets
```

Launch the rebuilt app from `$(brew --prefix emacs-plus@31)/Emacs.app`. Replace any copied app in `/Applications` after rebuilding.

## Sync another Mac

Pull this repository, run the Stow command, and install or rebuild Emacs. The configuration uses relative patch paths. Each Mac builds its own binary.

## Update a patch

Keep one feature per patch. After editing a patch, update its `sha256` in `build.yml`:

```sh
shasum -a 256 emacs-plus/.config/emacs-plus/patches/xwidget-user-agent.patch
```

Commit the patch and configuration together. Rebuild and check the feature on one Mac before updating the others.

## Update Emacs

The `"31"` entry applies only to Emacs 31. Test each patch against a new release before enabling it for that version. Delete patches included upstream.

## Patches

- `xwidget-user-agent`: adds a default user agent and per-session overrides.
- `xwidget-snapshot`: captures the viewport to PNG at its CSS-pixel dimensions.
- `xwidget-viewport`: sets an independent viewport and scales its preview into the pane.
- `xwidget-callbacks`: protects asynchronous callbacks during garbage collection.
- `xwidget-clipping`: clips native browser drawing and paints unused space with the frame background.
- `xwidget-focus`: routes keyboard input to the selected Emacs pane when the browser is not selected.
- `xwidget-sessions`: adds named data stores and native cookie controls.
- `xwidget-downloads`: downloads URLs through the page's WebKit session.
- `xwidget-input`: sends native clicks and text insertion without selecting the browser pane.

Apply patches in the order listed in `build.yml`.

## Browser controls

`xwidget-webkit-user-agent` sets the default for new sessions. Nil selects WebKit's native user agent. The browser configuration reads the installed Safari version for its default.

```elisp
(setq xwidget-webkit-user-agent "My browser user agent")
(xwidget-webkit-set-user-agent (xwidget-webkit-current-session) nil)
(xwidget-webkit-set-viewport (xwidget-webkit-current-session) 1920 1080)
(xwidget-webkit-set-viewport (xwidget-webkit-current-session) nil nil)
```

Reload a page after changing its user agent directly through Lisp.

MCP `emacs_browser_open` accepts `user_agent` and `viewport` before navigation:

```json
{
  "url": "http://localhost:3000",
  "user_agent": "My mobile user agent",
  "viewport": {"width": 390, "height": 844}
}
```

`emacs_browser_configure` changes an existing page. Omitted fields keep their values. Null restores native defaults. A user-agent change reloads the page. `emacs_browser_capabilities` reports native support in the running Emacs.

Viewports are limited to 1..4096 CSS pixels per dimension. Screenshots include the entire viewport, including regions beyond the pane. They support hidden pages and require no Screen Recording permission.

## Emacs commands

`M-x browser-open-profile` opens a URL in a named temporary profile. A prefix argument selects a persistent profile.

In a browser pane, `SPC ov` sets viewport dimensions and `SPC oU` sets the user agent. A prefix argument restores native defaults.

Each workspace uses one dedicated browser pane. MCP pages open in the calling agent's workspace and preserve the focused workspace. Page tabs stay within their workspace. Click a tab to select it or `+` to open a new tab with an empty URL prompt. In a browser pane, `o` prompts for a URL without prefilling it. `q` closes the current tab; the pane stays open while other workspace tabs remain. File display commands use other panes.

## Sessions and state

New pages accept a profile:

```json
{
  "url": "https://example.com",
  "profile": {"name": "qa", "persistent": false},
  "viewport": {"width": 390, "height": 844}
}
```

Pages with the same profile share cookies and website data. Temporary profiles last until Emacs exits. Persistent profiles retain website data across restarts. Profile names have stable data-store identifiers. Profile data stays on each Mac.

| MCP tool | Controls |
| --- | --- |
| `emacs_browser_cookies` | Get, set and clear profile cookies, including HttpOnly; exact name/domain filters |
| `emacs_browser_session` | Read profile persistence and editor focus; clear all profile website data |
| `emacs_browser_storage` | Export state; import into the same origin; clear current-origin local/session storage |
| `emacs_browser_download` | List queued download links; download a URL to a new file; cancel a pending download |
| `emacs_browser_input` | Native click, fill and text insertion in a visible page |
| `emacs_browser_dialogs` | Set current-document confirm and prompt responses |

Storage export returns `state` with profile cookies and the current origin's local/session storage. Import upserts cookies and replaces local/session storage. IndexedDB is not exported. Storage state includes cookie values.

Session clear affects every page sharing that profile. Reload pages after clearing their website data.

Native input targets use main-document locators or viewport click coordinates. Click and input events are trusted. Text insertion does not emit keyboard events. Native fill supports text inputs, textareas and contenteditable elements. Other form types and synthesized keys use `emacs_browser_act`. Native input restores editor focus.

Managed pages queue download links without a save prompt. Native downloads use profile cookies, reject existing files and allow one pending download per page. Dialog response policies reset on navigation.

Synthetic clicks reject hidden and covered targets. Home and End move the text caret; Shift extends the selection. Snapshots report clipped text and omitted descendants with `truncated: true`. Full text is available through `emacs_browser_get`.

Contenteditable fields support Home, End and Shift selection at line boundaries. Typing with no selection places the caret at the end of the target. Label matching excludes embedded controls and uses the full label text.

Long data URLs in response metadata are shortened and marked `url_truncated: true`. `emacs_browser_get` with `what: "url"` returns the full URL. `emacs_browser_configure` exposes `page`, `user_agent` and `viewport`; at least one setting is required.

New-window links and `window.open()` navigate the current page. `emacs_browser_capabilities` reports `new_windows: false`. Opener handles are unsupported.

Codex launches from Emacs preapprove browser capabilities, get, list, screenshot and snapshot, plus editor context, diagnostics, documentation, selection, symbols and xref tools. Actions, JavaScript evaluation and cookie/storage access retain the configured approval policy. These inspection tools advertise MCP read-only annotations. Launcher changes apply to new agent sessions.

## QA coverage

| Capability | Support |
| --- | --- |
| HTTP user agent and `navigator.userAgent` | Per page, default, override, reset |
| Viewport and responsive breakpoints | Fixed dimensions, pane scaling, reset |
| Screenshots | Exact CSS dimensions, hidden pages, fresh content |
| Navigation and DOM inspection | Snapshots, refs, selectors, state, styles, text |
| Forms and uploads | Fill, click, check, select, file content |
| Shadow DOM and frames | Open shadow roots and same-origin frames |
| Console and waits | Recorded messages, conditions, load state |
| Input | Trusted native clicks and text insertion; synthesized keys; no native hover |
| Device emulation | No mobile OS, touch hardware, or device-pixel-ratio override |
| Session automation | Named temporary/persistent profiles, HttpOnly cookies, storage state and authenticated downloads |
| Network automation | No interception, offline mode, or request tracing |

## Verify

Start a separate patched Emacs from the checkout:

```sh
emacs -Q --fg-daemon=webkit-qa -l emacs/.config/emacs/site-lisp/webkit-agent/tests/qa-init.el
```

In another terminal:

```sh
emacsclient -s webkit-qa -c -n -d ns
python3 emacs/.config/emacs/site-lisp/webkit-agent/tests/test_browser.py
emacsclient -s webkit-qa --eval '(kill-emacs)'
```

Tests default to `webkit-qa`. Set `EMACS_SERVER_NAME` for another isolated server. Tests cover HTTP headers, form actions, uploads, exact-size screenshots, native input, editor focus, cookie isolation, storage state, downloads and bounded garbage collection. They close their pages afterward.

The isolated Emacs 31.1 build passed 13 integration tests. Persistent cookies and localStorage survived a server restart; temporary profiles restarted empty.
