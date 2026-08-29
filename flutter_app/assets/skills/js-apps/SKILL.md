---
name: js-apps
description: Create JS apps (jsr.render UI) that run inside Fa's Apps section — manifest.json + widget.js in the apps/ folder
---

# Fa JS App Development Skill

> **For the Fa coding agent**: This is the authoritative guide for creating JS apps that run inside the Fa Flutter app. Read the **Quick Start** first — it shows the minimal workflow.

---

## ⛔ HARD RULES (never break these)

1. **NEVER hardcode API keys, tokens, or provider endpoints in app code.** Apps get credentials from the host: read one with `jsr.fa.keys.get('NAME')`, ask the user for a missing one with `jsr.fa.keys.request('NAME', reason)` (declare `"keys": true` in `manifest.json`). A key a user granted lands in their Fa Keys store — reuse it, never paste it into `widget.js`.
2. **ALL model calls go through the host bridges** — LLM via `jsr.fa.llm` / `jsr.fa.llm.chat` / `jsr.fa.llm.stream`, media via `jsr.fa.media.*`. NEVER fetch a model provider's API directly (no `api.openai.com` etc. in `jsr.fetchJson`): the user's configured models and media slots are the ones to reuse, and their keys never belong in app code.
3. **Build JS apps on THIS platform** — `manifest.json` + `widget.js` in `apps/<id>/`. Do NOT scaffold Python/Node/web servers or separate Flutter projects: they cannot run here. Everything an app needs is a `jsr.*` bridge, `jsr.fetchJson`, or `jsr.exec` (allow-listed).

## 📱 Platform (what this environment IS and IS NOT)

The current Fa host platform is **`{{FA_PLATFORM}}`**. App manifests can use
`"platforms"` to opt into specific hosts; never create or recommend an app or
bridge that is unavailable on this platform.

Apps are **declarative JS widgets** rendered natively by the Fa host (single-page model: one `widget.js` tree, optional live home-screen tile `widget_tile.js`, permissions-gated bridges). This is NOT a general-purpose compute sandbox:

- **No servers / daemons / long-running processes.** An app runs while visible; there is no `node server.js`, no background loop beyond `jsr.setInterval` timers.
- **No raw sockets, no listening ports, no FFI/native modules.** Network = `jsr.fetchJson` only (HTTPS, permission-gated).
- **Python exists for short one-shot scripts via `jsr.exec` only** (wasm build, no network stack, no pip installs) — never for hosting an app. If you catch yourself writing `http.server`, `flask`, `express` — stop: build the JS widget instead.
- **iOS/Android constraints apply** — no JIT outside the provided JS engine, no dynamic native code. Anything the platform can't do must go through a `jsr.fa.*` bridge; if no bridge exists, say so instead of working around it.

---

## ⚡ Quick Start (Minimal Workflow)

JS apps live in the sandbox env folder `apps/<id>/`. You create and edit them with your normal file tools (write/edit) — no CLI involved.

```
1. write apps/my-app/manifest.json    metadata + permissions
2. write apps/my-app/widget.js        ES5-style IIFE, jsr.* API
3. open it for the user: open_app(id="my-app") — or tell them to open it in Fa's Apps section
```

### Opening apps for the user — the `open_app` tool

You can open any installed app for the user with the `open_app` tool: pass the app id (its `apps/<id>` folder name) and the host navigates straight to the app. Use it when the user asks to see an app, or right after you create/fix one — "I've opened it for you" beats instructions. Unknown ids come back with the list of available ids.

### After editing — reload is automatic

The host **watches the app files and reloads the running app automatically** as soon as you write/edit them. The user can also hit the Reload button. There is no CLI reload step — just write the file and the app picks it up.

### Validating JS — do it right

QuickJS **compiles the whole file before running it**, so a plain file run IS the syntax check — use it on every app you write:

```sh
qjs apps/my-app/widget.js
```

- `SyntaxError: <message>` → the file is broken; the message names the line. Nothing executed.
- `ReferenceError: jsr is not defined` (or any other runtime error) → **syntax is fine** — it parsed and started running; only the host APIs are missing outside the app.

Avoid these traps (they cost real debugging time):

- **Never `qjs -e '...'` with regexes/backslashes** — the shell eats `\`, producing nonsense like `invalid regular expression flags` / `expecting ')'`. Write the snippet to a file with `write` and run `qjs file.js` instead.
- **There is no `load()`, no `require()`, no `std.loadFile` in the sandbox qjs.** Widget files are self-contained IIFEs; sharing code means concatenating files yourself (or one `lib/` file you inline via the app manifest).
- `qjs file.js` RUNS the file — for widget code that means it hits `jsr is not defined` immediately after parsing (expected, see above).

### Critical rules

1. **Write files with your write/edit tools** — never shell out to `printf`/`cat` heredocs; the sandbox `apps/` folder is just a normal directory for your file tools.
2. **Always wrap `widget.js` in an IIFE** — `(function(){ ... })()`.
3. **Register `jsr.onEvent`** — even if you handle few events.
4. **Set the permissions the app actually needs** in `manifest.json`, and tell the user they may also need to enable them at runtime in the app's permissions dialog.
5. **Never hand-edit `apps/<id>/storage.json`** — that file is owned by `jsr.storage`.
6. **Study the available demo apps first** — Fa filters bundled examples by the current host platform. Read the closest visible app's source before building something similar.

---

## What is a Fa JS App?

A Fa JS app is a self-contained mini-application that runs in Fa's Apps section: **`widget.js`** (ES5-style JavaScript driving UI and logic) plus **`manifest.json`** (metadata and permissions). Apps run in a sandboxed JavaScript engine (JavaScriptCore on macOS/iOS) and talk to the Flutter host via the `jsr.*` API.

```
apps/
└── my-app/
    ├── manifest.json
    ├── widget.js
    └── storage.json      (created by jsr.storage — never edit by hand)
```

---

## JavaScript Constraints — ES5 Style Only

The engine is JavaScriptCore with no transpilation. Write **ES5-style code**:

- `var` + `function` — **no classes, no template literals, no async/await**
- All async APIs return Promises — use `.then()` / `.catch()`
- `let`/`const`/arrow functions are tolerated, but prefer `var`/`function` for consistency

---

## manifest.json

```json
{
  "id": "my-app",
  "name": "My App",
  "description": "Short description shown in the app picker",
  "version": "1.0.0",
  "platforms": ["ios", "macos"],
  "icon": "🚀",
  "network": true,
  "allowedCommands": [],
  "llm": false,
  "homekit": false,
  "health": false,
  "contacts": false,
  "calendar": false,
  "microphone": false,
  "notifications": false,
  "media": false,
  "keys": false
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `id` | ✅ | Unique identifier, kebab-case, matches folder name |
| `name` | ✅ | Display name shown in UI |
| `description` | ✅ | Short description |
| `version` | ✅ | Semver string |
| `platforms` | ❌ | Host allowlist: `web`, `android`, `ios`, `macos`, `windows`, `linux`, `fuchsia`. Omit for every platform. Apps outside the current platform are hidden and cannot start. |
| `icon` | ✅ | App-picker icon: an emoji, inline SVG markup (`"<svg …>"`), or an SVG filename inside the app folder (see below) |
| `network` | ❌ | `true` to allow `jsr.fetchJson` (default: false) |
| `allowedCommands` | ❌ | Array of shell commands allowed via `jsr.exec` (default: none) |
| `llm` | ❌ | `true` to allow `jsr.fa.llm` / `jsr.fa.llm.chat` / `jsr.fa.llm.stream` (default: false) |
| `homekit` | ❌ | `true` to allow `jsr.fa.home.*` (and legacy `jsr.fa.homekit`) — HomeKit home control (default: false) | <!-- fa-platforms: ios -->
| `health` | ❌ | `true` to allow `jsr.fa.health.summary` — read-only HealthKit data (default: false) | <!-- fa-platforms: ios,macos -->
| `contacts` | ❌ | `true` to allow `jsr.fa.contacts.*` — system contacts access (search + create/update/delete + call/sms; default: false) | <!-- fa-platforms: ios,macos -->
| `calendar` | ❌ | `true` to allow `jsr.fa.calendar` — system calendar access (read + create/update/delete; default: false) | <!-- fa-platforms: ios,macos -->
| `microphone` | ❌ | `true` to allow `jsr.fa.asr.*` — microphone recording + speech-to-text (default: false) | <!-- fa-platforms: ios,macos -->
| `notifications` | ❌ | `true` to allow `jsr.fa.notify.*` — schedule/cancel local system notifications (default: false) | <!-- fa-platforms: ios,macos -->
| `media` | ❌ | `true` to allow `jsr.fa.media.*` — image / TTS / music generation + video reading on the configured media endpoints (default: false) |
| `keys` | ❌ | `true` to allow `jsr.fa.keys.*` — read the user's saved host API keys and request new ones via the native secret prompt (default: false) |

All permissions default to false/absent. The user can also toggle them at runtime in the app's permissions dialog — so when you create an app, set the permissions it needs in the manifest **and** tell the user they may need to enable them.

### App icons (emoji or SVG)

The `icon` field accepts three forms:

1. **Emoji** — `"icon": "🚀"` (simplest).
2. **Inline SVG markup** — `"icon": "<svg xmlns=…>…</svg>"`.
3. **SVG file in the app folder** — `"icon": "icon.svg"`, resolved as `apps/<id>/icon.svg`. Create the file with your write tool alongside the manifest. Prefer this for anything non-trivial; keep the SVG small, single-color friendly (`stroke`/`fill` with a hex color), `viewBox` 24×24.

SVG icons render in the sidebar, the apps grid, the app bar and the permissions dialog. Inside the app UI itself, use the `svg` node (`{"type": "svg", "data": "<svg …>", "width": 24, "color": "#818cf8"}`) for inline vector graphics.

### Live launcher tiles (the `widget` section)

An app can render **live mini-content inside its launcher home-grid tile** (like an iOS/Android home-screen widget — think a weather tile showing the current temperature) instead of the static icon + label. Opt in with a `"widget"` section in `manifest.json` plus a separate tile entry file:

```json
"widget": { "entry": "widget_tile.js", "size": "4x2", "refreshSeconds": 900 }
```

| Field | Required | Description |
|-------|----------|-------------|
| `entry` | ❌ | Tile JS file inside the app folder (default: `widget_tile.js`) |
| `size` | ❌ | Tile span as `"WxH"` in **icon-slot cells** (default: `"2x2"`). W clamps to 2–4, H to 1–4; anything unparsable falls back to 2x2. The three iOS-style presets: `"2x2"` (small, 4 cells), `"4x2"` (medium, 8 cells — full width on a phone), `"4x4"` (large, 16 cells) |
| `refreshSeconds` | ❌ | Host-side refresh cadence — the tile host fires a `tile.refresh` event every N seconds (omit it and use your own `setInterval` if you prefer) |

Tile-JS rules (see the `weather` (4x2) / `reminders` (2x2) demo `widget_tile.js`):

1. **Canvas size = the declared cells** — the grid unit is the app-icon slot: 56 px icon square + 20 px label strip, 16 px gaps. A WxH tile canvas is `W*72 − 16` px wide × `H*76 + (H−1)*16` px tall — e.g. `"2x2"` ≈ 128×168, `"4x2"` ≈ 272×168, `"4x4"` ≈ 272×368. The tile gives your root node tight bounds (fill it; don't center a fixed-size box). Render a compact layout for the span you declared: a 2x2 fits a few rows or one big value + label; a 4x2 fits a horizontal split (glyph + label | value + sublabel). No forms, no scrolling.
2. **Display-only** — any tap on the tile opens the full app; tile JS must not rely on its own buttons/inputs (there is no in-tile interaction in v1).
3. **`tile.refresh` event** — when the manifest sets `refreshSeconds`, the host calls your `jsr.onEvent` handler with `actionId === 'tile.refresh'`; refetch/re-read data there.
4. **`jsr.theme` colors** — same theming rules as full apps: read `jsr.theme` fresh on every render and re-render from `jsr._onThemeChange`.
5. **Storage is shared** — the tile engine uses the same `apps/<id>/storage.json` as the full app: read what the app writes (e.g. the reminders tile shows the app's `reminders` list), and cache your last fetched payload for an instant first paint.
6. **Foreground only** — the tile engine lives only while the launcher is visible; there is no background execution.

#### Reconfiguring the home grid (`launcher_layout.json`)

The launcher's layout lives in the sandbox root as `launcher_layout.json` — you (the agent) can edit it with your regular file tools when the user asks to reconfigure the home screen ("change the grid", "make the weather widget bigger"); the launcher re-reads the file live. Schema v2:

```json
{
  "version": 2,
  "order": ["app:weather", "app:notes", "system:settings", "system:files"],
  "folders": [{ "id": "folder-1-…", "name": "Tools", "tiles": ["app:calc"] }],
  "grid": { "columns": 4 },
  "tileSizes": { "weather": "4x2", "reminders": "2x2" }
}
```

- `grid.columns` — column-count override (clamped 3–8; omit or `null` for the width-based default: 4 on phones, 6 on wide screens).
- `tileSizes` — per-app live-tile size overrides as `"WxH"` icon-slot cells (W 2–4, H 1–4); overrides the manifest's `widget.size` at render time. Delete an entry to reset to the manifest default.
- `order` / `folders` — top-level tile order and folder groupings (tile keys: `app:<id>`, `system:settings`, `system:files`, `folder:<id>`; folder ids referenced from `order` must exist in `folders` or the whole file is treated as corrupt).

Keep the file valid JSON with `"version": 2` — a corrupt file is ignored (defaults), and the launcher rewrites it on every user mutation.

---

## widget.js — Code Structure

Always wrap your app in an IIFE to avoid polluting the global scope:

```javascript
(function() {
  // Your app code here

  function render() {
    jsr.render({ /* UI tree */ });
  }

  function handleEvent(actionId, payload) {
    // Handle button taps, textField submissions, etc.
  }

  jsr.onEvent(handleEvent);
  render();
})();
```

---

## The `jsr` API

### `jsr.render(tree)`
Replaces the entire app UI with a new widget tree (JSON).

```javascript
jsr.render({
  type: 'column',
  children: [
    { type: 'text', data: 'Hello World' },
    { type: 'button', label: 'Click me', onPressed: 'btn_click' }
  ]
});
```

### `jsr.onEvent(handler)`
Register a handler for all UI events (button taps, textField changes, etc.).

```javascript
jsr.onEvent(function(actionId, payload) {
  if (actionId === 'btn_click') {
    // handle it
  }
});
```

`actionId` — string you put in `onTap`, `onPressed`, `onSubmit`, `onChange`
`payload` — optional object with extra data (e.g. `{ value: 'text typed' }`)

### `jsr.onBack` — Back Navigation Contract
Register a handler for the host's back gesture (iOS edge swipe, Android
system back, the app-bar back arrow). Return `true` to consume it for
in-app navigation (e.g. card → list); return anything else — or never
register it — and the host closes the app.

```javascript
jsr.onBack = function() {
  if (scene === 'detail') {
    scene = 'list';
    renderList();
    return true;   // consumed — the app stays open
  }
  return false;    // declined — the host pops the route
};
```

While a handler is registered the native swipe-to-go-back is disabled and
the route never pops on its own — every back attempt (system back button,
app-bar arrow) reaches `jsr.onBack` first, so make sure your UI offers its
own back affordance for internal navigation. Requires `jsr.onEvent` (the
back event rides the same dispatch); `back` is a reserved actionId and
never reaches your `jsr.onEvent` handler. Clear it with `jsr.onBack = null`
to hand back control to the host.

### `jsr.fetchJson(url, opts)` → Promise
HTTP fetch via Dart (bypasses CORS, uses native networking). Requires `"network": true` in manifest.json.

```javascript
jsr.fetchJson('https://api.example.com/data', {
  method: 'GET',           // 'GET' | 'POST' | 'PUT' | 'DELETE'
  headers: { 'Authorization': 'Bearer token' }
}).then(function(data) {
  // data is already parsed JSON
  render(data);
}).catch(function(err) {
  jsr.showError('Failed: ' + err);
});
```

**Error convention**: failures come back as an object with an `__error` field — e.g. `{ __error: "HTTP 404" }`. Check for it before using the data:

```javascript
jsr.fetchJson(url).then(function(data) {
  if (data && data.__error) { jsr.showError(data.__error); return; }
  render(data);
});
```

### `jsr.storage` — Persistent Storage
Per-app persistent storage. Survives reloads and restarts; persisted by the host in `apps/<id>/storage.json` (**never edit that file by hand**). Plain JSON values.

```javascript
jsr.storage.set('city', 'London');
jsr.storage.set('settings', { theme: 'dark', count: 42 });

jsr.storage.get('city').then(function(city) {   // get returns a Promise
  if (city) render(city);
});

jsr.storage.delete('city');
```

### `jsr.secrets` — Secure Storage
Per-app encrypted secure storage (platform Keychain/Keystore), for API keys/tokens/passwords. Same shape as `jsr.storage`: `set(key, value)`, `get(key)` → Promise, `delete(key)`.

### `jsr.locale` — Host UI Language
Read-only string with the host's UI language code (`'en'`, `'ru'`, …), set before your code runs. Localize by branching on it with your own dictionary — do NOT hardcode one language:

```js
var T = {
  en: {title: 'Weather', refresh: 'Refresh'},
  ru: {title: 'Погода', refresh: 'Обновить'}
};
function t(key) { return (T[jsr.locale] || T.en)[key] || T.en[key]; }
// then render: {type: 'text', data: t('title'), ...}
```

Fall back to English for unknown locales (as above). Dates/numbers: format per `jsr.locale` (e.g. `new Date(ts).toLocaleString(jsr.locale)`).

### `jsr.theme` — Current Theme Colors
Reactive theme object, injected by the Fa host from its own palette. **Always use these colors instead of hardcoded hex values** — the theme follows the app's light/dark mode live, and hardcoded palettes look broken in one of the two modes.

All color values are `'#RRGGBB'` strings (uppercase, no alpha — layer translucency yourself via node `opacity` if needed):

| Key | Value |
|-----|-------|
| `brightness` | `'dark'` or `'light'` |
| `dark` | `true` in dark mode (boolean) |
| `background` | page background |
| `surface` | card/panel surface |
| `surfaceAlt` | raised panel / sunken input fill |
| `border` | card borders |
| `borderBright` | hover/emphasis borders |
| `text` | primary text |
| `muted` | dimmed/secondary text |
| `accent` | teal accent (success, links, highlights) |
| `accent2` | indigo accent (primary actions) |
| `onAccent` | text/icons on top of accent fills |
| `error` | error text/icons |
| `userBubble` | user chat bubble fill |
| `userBubbleBorder` | user chat bubble border |
| `codeBg` | inline-code background |

(`isDark` and `bg` also exist as legacy aliases of `dark` and `background` — prefer the canonical keys in new code.)

```javascript
var t = jsr.theme;
// Read jsr.theme fresh on every render — the object is REPLACED on theme
// change, so a cached reference goes stale.
```

### `jsr._onThemeChange` — Theme Change Hook
When the user toggles dark/light mode, the host replaces `jsr.theme` and then calls `jsr._onThemeChange(jsr.theme)` if it is set. Assign it (directly or via the `jsr.onThemeChange(fn)` sugar) and re-render:

```javascript
jsr._onThemeChange = function(theme) {
  render(); // re-render with the new colors
};
```

### `jsr.setTitle(title)`
Update the app header title: `jsr.setTitle('Weather — London');`

### `jsr.exportState(object)`
Export structured app state that the host can see. This is **essential in Fa**: when the user talks to the agent from inside an app (the Fa floating button), the agent receives the user's message plus this exported state plus a screenshot. Always export meaningful state.

```javascript
jsr.exportState({
  loading: false,
  city: 'Moscow',
  tempC: '18',
  description: 'Partly cloudy'
});
```

### `jsr.showError(message)`
Display an error overlay in the app: `jsr.showError('Failed to load data');`

### `jsr.loadAsset(path)` → Promise\<string|null\>
Reads a file from the app's folder and returns its text content (supports subdirectories); `null` if not found. Useful for SVGs, JSON config, templates, or any bundled static asset.

```javascript
jsr.loadAsset('assets/config.json').then(function(json) {
  var config = JSON.parse(json);
});
```

### `jsr.exec(cmd)` → Promise
Run a shell command from the app. Returns `{ stdout, stderr, exitCode }`. **Security: only commands listed in the manifest's `allowedCommands` are allowed.**

```javascript
jsr.exec('ls').then(function(result) {
  console.log(result.stdout);   // command output
  console.log(result.exitCode); // 0 = success
});
```

### Globals: console, timers, animation frame
- `console.log / console.warn / console.error` — output is visible in the app's logs view in Fa. Log liberally for debugging.
- `setTimeout / setInterval / clearTimeout / clearInterval` — standard timers. Save interval IDs and clear them when done.
- `requestAnimationFrame(fn)` / `cancelAnimationFrame(id)` — vsync-driven frame callback (~60fps); `fn` receives elapsed ms. Use for smooth animations and game loops:

```javascript
function gameLoop(elapsed) {
  updatePhysics(elapsed);
  renderFrame();
  requestAnimationFrame(gameLoop); // schedule next frame
}
requestAnimationFrame(gameLoop);
```

---

## The Fa Bridge — `jsr.fa.*`

Fa-specific bridge APIs that connect apps to the host.

### `jsr.fa.llm(prompt)` → Promise\<string\>
One-shot completion from the LLM the Fa host is connected to. Requires `"llm": true` in the manifest (and the runtime permission toggle).

```javascript
jsr.fa.llm('Summarize this text: ' + noteText).then(function(summary) {
  if (summary && summary.__error) { jsr.showError(summary.__error); return; }
  renderSummary(summary);
});
```

Use it for summarization, tagging, smart suggestions — anything that benefits from the user's connected model. Keep prompts self-contained (the call is stateless; there is no chat history — use `jsr.fa.llm.chat` when you need one).

### `jsr.fa.llm.chat(messages)` → Promise\<string\>
Multi-turn completion. `messages` is an array of `{role: 'user'|'assistant'|'system', content: '...'}` — `system` entries steer the model, `user`/`assistant` entries replay the conversation (end with a `user` message). Resolves with the assistant's reply text; rejects with an actionable error (permission off, or no model connected — tell the user to connect one in the Fa settings).

```javascript
var history = [];
function ask(text) {
  history.push({role: 'user', content: text});
  return jsr.fa.llm.chat(history).then(function(reply) {
    history.push({role: 'assistant', content: reply});
    return reply;
  });
}
```

### `jsr.fa.llm.stream(messages, onDelta)` → Promise\<string\>
Same as `chat`, but while the model generates, `onDelta(partialText)` fires per delta with the ACCUMULATED text so far (replace your UI text with it, don't append). The promise resolves with the full reply. `onDelta` is optional. Example — a notes app with an "AI summary" button that streams:

```javascript
var note = {title: 'Week 30', body: 'Shipped the beta. Fixed sync bugs. ...'};
jsr.onEvent(function(actionId, payload) {
  if (actionId === 'summarize') {
    render({type: 'text', data: 'Summarizing…', style: {color: jsr.theme.muted}});
    jsr.fa.llm.stream([
      {role: 'system', content: 'Summarize the note in 3 bullet points.'},
      {role: 'user', content: note.title + '\n\n' + note.body}
    ], function(partial) {
      render({type: 'text', data: partial, style: {color: jsr.theme.text}});
    }).then(function(full) {
      render({type: 'text', data: full, style: {color: jsr.theme.text}});
    }, function(error) {
      jsr.showError(String(error));
    });
  }
});
```

<!-- fa-platforms: ios,macos -->
### `jsr.fa.calendar(args)` → Promise
Access to the user's system calendar (macOS/iOS). Requires `"calendar": true` in the manifest (and the runtime permission toggle); the first call also triggers the OS calendar-access prompt. `args` is optional: `{date: 'YYYY-MM-DD', days: N}` — defaults to today, 1 day (max 31).

```javascript
jsr.fa.calendar({ date: '2026-07-25', days: 1 }).then(function(result) {
  if (result && result.__error) { jsr.showError(result.__error); return; }
  // result.events: [{ id, title, startMs, endMs, allDay, calendar?, location?, notes? }]
  renderEvents(result.events);
});
```

**Write methods** (same `calendar` permission):

```javascript
// Create — returns { id }. Hours are local; endHour defaults to startHour + 1.
jsr.fa.calendar.create({
  title: 'Dentist', date: '2026-07-25', startHour: 14, endHour: 15,
  // allDay: false, location: '…', notes: '…'
}).then(function(result) { /* result.id or result.__error */ });

// Update — only the supplied fields change; id comes from the events list.
jsr.fa.calendar.update({ id: eventId, title: 'Dentist (moved)', startHour: 16 });

// Delete — permanent; confirm with the user first.
jsr.fa.calendar.delete({ id: eventId });
```

The Fa agent has matching tools (`calendar_add` / `calendar_update` / `calendar_delete`, plus read-only `calendar_events`), so users can also manage events by chatting — the write tools follow a list-then-confirm flow.

### `jsr.fa.contacts.search(args)` → Promise
Access to the user's system contacts (macOS/iOS). Requires `"contacts": true` in the manifest (and the runtime permission toggle); the first call also triggers the OS contacts-access prompt. `args` is optional: `{query: 'anna'}` — a case-insensitive name match; a query with 3+ digits also matches phone numbers (handy for dedup-by-number). An empty query lists the WHOLE address book — page it with `{query: '', limit: 200, offset: 0}`.

```javascript
jsr.fa.contacts.search({ query: 'anna' }).then(function(result) {
  if (result && result.__error) { jsr.showError(result.__error); return; }
  // result.contacts: [{ id, name, phones: [...], emails: [...] }]
  renderContacts(result.contacts);
});
```

**Write methods** (same `contacts` permission):

```javascript
// Create — returns { id }. phones/emails are string lists.
jsr.fa.contacts.create({
  name: 'Anna Ivanova', phones: ['+1 555 0100'], emails: ['anna@example.com'],
  // note: '…'
}).then(function(result) { /* result.id or result.__error */ });

// Update — only the supplied fields change; a supplied phones/emails list
// REPLACES the existing entries. id comes from the search results.
jsr.fa.contacts.update({ id: contactId, phones: ['+1 555 0199'] });

// Delete — permanent; confirm with the user first.
jsr.fa.contacts.delete({ id: contactId });
```

**Call / SMS triggers** (same permission; they open the system dialer / Messages app — the user still confirms there):

```javascript
// Pass the phone from the search results (or {id: contactId}).
jsr.fa.contacts.call({ phone: '+1 555 0100' });
jsr.fa.contacts.sms({ phone: '+1 555 0100', text: 'Running late, sorry!' });
```

The Fa agent has matching tools (`contacts_search`, plus write-tier `contacts_add` / `contacts_call` / `contacts_sms`), so users can also reach their contacts by chatting — the call/SMS tools follow a search-then-confirm flow.
<!-- /fa-platforms -->

<!-- fa-platforms: ios,macos -->
### `jsr.fa.health.summary(args)` → Promise
Read-only HealthKit data (iOS and macOS 14+). Requires `"health": true` in the manifest (and the runtime permission toggle); the first call also triggers the OS health-access prompt. `args` is optional: `{days: 7}` — how many days back to summarize (1–31, default 7).

```javascript
jsr.fa.health.summary({ days: 7 }).then(function(result) {
  if (result && result.__error) { jsr.showError(result.__error); return; }
  // result.steps:            [{ date: '2026-07-25', value: 8432 }, ...]
  // result.restingHeartRate: [{ date, value }] — daily bpm averages
  // result.sleepHours:       [{ date, value }] — night attributed to its morning
  renderDashboard(result);
});
```

Days without data are omitted from each series. The Fa agent has a matching read-tier tool (`health_summary`), so users can also ask about their health data by chatting.
<!-- /fa-platforms -->

<!-- fa-platforms: ios -->
### `jsr.fa.home.*` → Promise
Home control via HomeKit (iOS). Requires `"homekit": true` in the manifest (and the runtime permission toggle); the first call also triggers the OS home-data prompt. All methods share the same permission:

```javascript
// Homes and rooms.
jsr.fa.home.homes();              // { homes: [{ id, name, primary, roomCount, accessoryCount }] }
jsr.fa.home.rooms({ homeId });    // { rooms: [{ id, name, homeName, accessoryCount }] } — homeId optional

// List accessories (homeId / roomId filters optional).
jsr.fa.home.list().then(function(result) {
  if (result && result.__error) { jsr.showError(result.__error); return; }
  // result.accessories: [{ id, name, room, homeName, category, reachable,
  //   isOn?, brightness?, targetTemperature?, services: [{ type, name,
  //   characteristics: [{ type, value?, readable, writable }] }] }]
  // category is 'lightbulb' | 'switch' | 'outlet' | 'thermostat' (or the raw
  // HomeKit category); values are read for reachable accessories.
  renderRooms(result.accessories);
});

// Fresh values for one accessory.
jsr.fa.home.read({ id: accessoryId });  // { accessory: …same shape… }

// Write ANY writable characteristic by its HomeKit type string.
jsr.fa.home.write({ id: accessoryId, type: 'powerState', value: true });  // { written: true }

// Scenes (HomeKit action sets).
jsr.fa.home.scenes({ homeId });         // { scenes: [{ id, name, homeName, actionCount, executing }] }
jsr.fa.home.executeScene({ id: sceneId });  // { executed: true }

// Convenience writes — id comes from the list. setPower answers {on},
// setBrightness {brightness}, setTemperature {temperature}; failures come
// back as {__error}. Every write accepts optional name/room from the
// listed accessory — pass them: bridge sub-devices can share one id, and
// the native side narrows by name+room.
jsr.fa.home.setPower({ id: accessoryId, on: true, name: a.name, room: a.room });
jsr.fa.home.setBrightness({ id: accessoryId, value: 60 });   // 0–100
jsr.fa.home.setTemperature({ id: accessoryId, celsius: 21.5 }); // °C
```

The legacy `jsr.fa.homekit(action, args)` form still works for the same actions (`'list'`/`'listDevices'`, `'setPower'`, `'setBrightness'`, `'setTemperature'`) — new apps should use `jsr.fa.home.*`. The Fa agent has matching tools (read-tier `home_devices`, write-tier `home_turn_on` / `home_turn_off` / `home_set`), so users can also control their home by chatting.

**Error convention**: bridge failures (permission denied, unsupported platform, platform error) come back as an object with an `__error` field — the same convention as `jsr.fetchJson`. Always check `result.__error` before using a result:

```javascript
jsr.fa.home.list().then(function(result) {
  if (result && result.__error) { jsr.showError(result.__error); return; }
  renderDevices(result.accessories);
});
```
<!-- /fa-platforms -->

<!-- fa-platforms: ios,macos -->
### `jsr.fa.asr.*` → Promise
Microphone capture + speech-to-text (macOS/iOS). Requires `"microphone": true` in the manifest (and the runtime permission toggle); the first call also triggers the OS microphone-access prompt. Both methods share the same permission:

```javascript
// Record — resolves with { path, durationMs, sampleRate }: a temporary
// .m4a take of `seconds` (1–120, default 10).
jsr.fa.asr.record({ seconds: 5 }).then(function(rec) {
  if (rec && rec.__error) { jsr.showError(rec.__error); return; }
  // Transcribe — resolves with { text }. Transcription rides the provider
  // connected in the Fa settings when it is an OpenAI-compatible endpoint
  // (Whisper /audio/transcriptions); without one the call answers with an
  // actionable __error telling the user to configure an ASR-capable endpoint.
  jsr.fa.asr.transcribe({ path: rec.path }).then(function(result) {
    if (result && result.__error) { jsr.showError(result.__error); return; }
    renderTranscript(result.text);
  });
});
```

The Fa agent has a matching write-tier tool (`mic_record`, which stages takes into the sandbox `recordings/` folder) plus the read-tier `transcribe_audio` tool, so users can also dictate and transcribe by chatting — the chat composer has a mic button riding the same bridge.

### `jsr.fa.notify.*` → Promise
Local system notifications (macOS/iOS — LOCAL only, no remote pushes): the notification reaches the user even when Fa is in the background. Requires `"notifications": true` in the manifest (and the runtime permission toggle); the first call also triggers the OS notification-access prompt.

```javascript
// Schedule — resolves with { id }. delaySeconds is optional (default: fire
// immediately); triggers never repeat.
jsr.fa.notify.schedule({
  title: 'Build finished', body: 'flutter build macos succeeded',
  delaySeconds: 300,
}).then(function(result) {
  if (result && result.__error) { jsr.showError(result.__error); return; }
  rememberId(result.id);
});

// Cancel — resolves with { cancelled: true }.
jsr.fa.notify.cancel({ id: notificationId });
```

The Fa agent has a matching write-tier tool (`notify`), so users can also ask for notifications by chatting — both are steered to fire sparingly (long-running/background-relevant updates only, never per-turn chatter).
<!-- /fa-platforms -->

### `jsr.fa.media.*` → Promise
Media generation: images, text-to-speech, and music — plus video reading. Requires `"media": true` in the manifest (and the runtime permission toggle). Endpoints resolve from `media_models.json` per-modality slots (`imageGeneration`, `audioTts`, `musicGeneration`, `vision`), falling back to the connected provider when it is OpenAI-compatible. Errors (permission off, no usable endpoint, provider failure) REJECT the promise with an actionable message — always pass an error handler. Every generation method saves the file into the sandbox `generated/` folder and resolves with `{ path, bytes, detail }` — render it with a `file:<path>` source in `image` / `audio` nodes:

```javascript
// Image — args: {prompt, size?} (size like '1024x1024', provider-dependent).
jsr.fa.media.generateImage({ prompt: 'a teal robot mascot, flat vector' }).then(function(result) {
  jsr.render({ type: 'image', url: 'file:' + result.path, width: 256, height: 256 });
}, function(error) {
  jsr.showError(String(error));
});

// Speech — args: {text, voice?} (voice default 'alloy', provider-dependent).
jsr.fa.media.speak({ text: 'Build finished', voice: 'nova' }).then(function(result) {
  jsr.render({ type: 'audio', src: 'file:' + result.path, title: 'TTS' });
}, function(error) {
  jsr.showError(String(error));
});

// Music — args: {prompt, seconds?} (default 30). Music has no OpenAI
// standard, so this only works with a musicGeneration slot configured in
// media_models.json; the endpoint must accept POST {baseUrl}/music/generations
// with {model, prompt, duration} and answer {"data": [{"b64_json": "..."}]}
// or {"data": [{"url": "..."}]}.
jsr.fa.media.generateMusic({ prompt: 'lo-fi hip hop loop', seconds: 20 });

// Video — args: {path, frames?, question?} (frames default 6, max 12;
// macOS/iOS). Extracts evenly spaced frames from a sandbox video file and
// sends them to the configured vision model (media_models.json `vision`
// slot, or the connected model when it accepts images); resolves with
// {description} — the model's timeline-labeled account of the video. The
// frames themselves never leave the host.
jsr.fa.media.readVideo({ path: 'generated/clip.mp4', question: 'What happens?' }).then(function(result) {
  jsr.render({ type: 'text', data: result.description });
}, function(error) {
  jsr.showError(String(error));
});
```

The Fa agent has matching tools (`generate_image`, `speak`, `generate_music` — write-tier; `read_video` — read-tier), so users can also generate media and read videos by chatting — both surfaces resolve endpoints identically.

### `jsr.fa.keys.*` → Promise
Host keys: the API credentials the user saved in Fa (the settings Keys section / `.env`). This is THE way an app gets a key — never hardcode one. Requires `"keys": true` in the manifest (and the runtime permission toggle).

```javascript
// List — resolves with { keys: ['OPENAI_API_KEY', ...] } — NAMES ONLY.
jsr.fa.keys.list().then(function(result) {
  if (result && result.__error) { jsr.showError(result.__error); return; }
  renderKeyNames(result.keys);
});

// Get — resolves with { name, value } for ONE exact name; an unknown name
// comes back as an __error telling you to list first or request the key.
jsr.fa.keys.get('WEATHER_API_KEY').then(function(result) {
  if (result && result.__error) {
    // Unknown key? Ask the user for it through the native secret prompt:
    jsr.fa.keys.request('WEATHER_API_KEY', 'Needed to call the weather API').then(function(granted) {
      if (granted && granted.__error) { jsr.showError(granted.__error); return; } // user declined
      startApp(granted.value);
    });
    return;
  }
  startApp(result.value);
});
```

`keys.request(name, reason)` opens the same native secret sheet the Fa agent's `request_secret` tool uses (prefilled with `name`); a grant is persisted into the user's Fa Keys store and resolves with `{name, value}`, a decline/cancel comes back as an `__error`. Prefer requesting over failing: the user grants once and every app can then `keys.get` it.

### `scene3d` — real 3D scenes (games!)

Renders an interactive 3D scene. Two paths:

1. **Software mesh path (pure Dart, no host engine)** — give the node a `meshes` prop: `[{vertices: [[x,y,z],…], faces: [[i,j,k],…], color: '#hex'}]`. Perspective-projected, flat-shaded, ≤ ~500 triangles at interactive rates. Animate by re-rendering with a new `rotation` on a raf/timer tick. Great for low-poly models, dice, simple 3D charts.
2. **Host engine path (for games)** — omit `meshes` and drive the scene imperatively through the `jsr.scene3d.*` bridge (the Fa host wires the runtime's dispatcher: `flutter_cube` for procedural primitives and OBJ models, `flame_3d` for `.glb`/`.gltf`). Primitives: `cube`, `sphere`, `torus`, `city`. **A GLB/GLTF scene MUST pass `engine: 'flame'` in `jsr.scene3d.create(sceneId, {engine: 'flame', ...})`** — the dispatcher binds the scene to a host on the FIRST create call (no `src` in the config → cube host), and a later `.glb` `addModel` into a cube-bound scene fails parsing it as OBJ.

```javascript
// Node (in the render tree): { type: 'scene3d', id: sceneId }
// — fill it via `expanded`; width/height props optional.

jsr.scene3d.create(sceneId, {
  camera: { position: [0, 12, 14], target: [0, 0, -4], fov: 55 },
  light: { position: [5, 10, 8], color: '#ffffff', ambient: 0.5, diffuse: 0.7 },
});
jsr.scene3d.addModel(sceneId, {
  modelId: 'player', primitive: 'cube', color: '#22d3ee',
  position: [0, 0, 2], scale: [1.2, 1.2, 1.2],
});
// ONE batched transform message per frame — never N separate calls:
jsr.scene3d.setTransforms(sceneId, [
  { modelId: 'player', position: [x, 0, 2] },
  { modelId: 'block-1', position: [1, 0, -6] },
]);
jsr.scene3d.removeModel(sceneId, 'block-1');
jsr.scene3d.setCamera(sceneId, { position: [0, 12, 14], target: [0, 0, -4] });
jsr.scene3d.destroy(sceneId);
```

- **Scene id** — namespace it: `'game-' + (jsr.instanceId || 'app') + '-' + Math.floor(Math.random()*1e9)` (several engines can run the same app; controllers are shared per sceneId).
- **Input** — touch: overlay a transparent `gestureDetector` (`onPanUpdate` fires `{x,y,dx,dy}`) on top of the scene in a `stack`, like the `3d-game` demo. Tap picking: `jsr.scene3d.onTap(sceneId, fn)` receives `{modelId, point:[x,y,z]}` (nearest hit) or `{modelId: null}`. Keyboard (`jsr.onKey`) only where the host has keys.
- **Perf rules** — game loop on `requestAnimationFrame`; mutate the scene via `setTransforms` batches, keep `jsr.render` (HUD) to a few times per second, never rebuild the whole tree per frame. Study `apps/3d-game/widget.js` (dodge-the-blocks) before writing your own.

---

## The Fa Floating Button

Inside any app, the user can tap the Fa floating button and talk to you (the agent) directly. When that happens you receive:

- the user's message,
- the app's **exported state** (whatever the app last passed to `jsr.exportState`),
- a **screenshot** of the app.

You can then edit the app's files with your normal tools — the app reloads automatically.

**Consequence for app authors (i.e. you, when creating apps): always call `jsr.exportState` with meaningful, up-to-date state.** Without it the agent has to guess what the app is showing when the user asks for a change.

---

## UI Node Types (Widget Tree)

All nodes are plain JSON objects with a `type` field.

### Layout

| Type | Key props | Description |
|------|-----------|-------------|
| `column` | `children`, `mainAxisAlignment`, `crossAxisAlignment`, `mainAxisSize` | Vertical stack |
| `row` | `children`, `mainAxisAlignment`, `crossAxisAlignment` | Horizontal stack |
| `wrap` | `children`, `spacing`, `runSpacing`, `alignment` | Flow-wrap to the next row |
| `stack` | `children`, `alignment`, `fit` (`expand`/`loose`) | Overlapping layers; children may use `positioned: {left, top, right, bottom}` |
| `overlay` | `children` | Stack layer supporting `positioned` children |
| `center` | `child` | Center child |
| `align` | `child`, `alignment` | Align child within available space |
| `padding` | `child`, `padding: [left, top, right, bottom]` | Add padding |
| `expanded` | `child`, `flex` | Flex expand inside row/column |
| `flexible` | `child`, `flex`, `fit` (`tight`/`loose`) | Flex without forcing the size |
| `spacer` | `flex` | Empty flex space in row/column |
| `sizedBox` | `width`, `height`, `child` | Fixed size box |
| `safeArea` | `child` | Insets for notches/bars |
| `aspectRatio` | `child`, `aspectRatio` | Force aspect ratio |
| `clipRRect` | `child`, `borderRadius` | Clip child to rounded corners |
| `scroll` | `child` | Single-child scroll view |
| `listView` | `children`, `shrinkWrap`, `scrollDirection`, `physics` | Scrollable list (set `shrinkWrap: false` + bounded height for long lists) |
| `gridView` | `children`, `crossAxisCount`, `crossAxisSpacing`, `mainAxisSpacing`, `childAspectRatio`, `padding` | Fixed-column grid | (`shrinkWrap` default true, `physics` `never`\|`always`\|`platform` to enable scrolling)

### Display

| Type | Key props | Description |
|------|-----------|-------------|
| `text` | `data`, `style` | Text label |
| `markdown` | `data` | Markdown-formatted text (`**bold**`, lists, …) |
| `icon` | `name`, `color`, `size` | Material icon by name |
| `svg` | `data` (inline SVG markup), `width`, `height`, `color` | Custom vector mark; `color` tints via srcIn — the SVG must paint pixels (stroked icons need an explicit `stroke`) |
| `divider` | `color`, `height`, `thickness` | Horizontal line |
| `circleAvatar` | `text` or `image`, `radius` | Round avatar |
| `chip` | `label`, `avatar?`, `color` | Material chip |
| `badge` | `label`, `child` | M3 badge over a child |
| `linearProgressIndicator` | `value` (0..1, null = indeterminate) | Progress bar |
| `circularProgressIndicator` | — | Spinner |
| `image` | `url`, `asset:<path>`, `file:<path>`, `fit`, `width`, `height` | Image |

### Containers

| Type | Key props | Description |
|------|-----------|-------------|
| `container` | `child`, `color`, `decoration` (`color`, `borderRadius`, `border`, `boxShadows`, `gradient`), `padding`, `margin`, `width`, `height`, `alignment`, `clip`, `transform`, `blur` | Styled box |
| `card` | `child`, `color`, `elevation`, `borderRadius` | Material card |
| `inkWell` | `child`, `onTap`, `borderRadius` | Tappable area (ripple effect) |

### Interactive

| Type | Key props | Description |
|------|-----------|-------------|
| `button` | `label`, `onPressed`, `icon`, `color`, `textColor` | Elevated button |
| `textButton` | `label`, `onPressed` | Flat text button |
| `outlinedButton` | `label`, `onPressed`, `icon` | Outlined button |
| `iconButton` | `icon`, `onTap`, `tooltip?` | Icon-only button |
| `textField` | `hint`, `value`, `onSubmit`, `onChange`, `obscure` | Text input field |
| `textArea` | `value`, `hint`, `minLines` (3), `maxLines` (8), `onChange`, `onSubmit` | Multiline text input (expands, then scrolls) |
| `switch` | `value`, `onChanged` → `{value: bool}` | Toggle |
| `checkbox` | `value`, `label?`, `onChanged` → `{value: bool}` | Checkbox |
| `slider` | `value`, `min`, `max`, `divisions`, `onChanged` → `{value: num}` | Slider |
| `dropdown` | `items` (strings or `{value, label}`), `value`, `onChanged` | Dropdown picker |
| `gestureDetector` | `child`, `onTap`, `onTapDown`, `onTapUp`, `onPanStart`, `onPanUpdate`, `onPanEnd`, `onLongPress` | Touch/gesture input with local coordinates |

### Material 3

| Type | Key props | Events |
|------|-----------|--------|
| `appBar` | `title`, `leading: {icon, onTap}`, `actions: [{icon, onTap, tooltip}]`, `color` | taps |
| `navigationBar` / `navigationRail` | `destinations: [{icon, label}]`, `selectedIndex`, `onChanged` | `{value: index}` |
| `tabBar` | `tabs: [string]`, `children: [node]` | none (self-contained) |
| `fab` | `icon?`, `label?` (extended), `mini?`, `onTap` | tap |
| `segmentedButton` | `segments: [{value, label, icon?}]`, `selected: [...]`, `multiSelect?`, `onChanged` | `{value}` or `{value: [...]}` |
| `radio` | `value`, `groupValue`, `label?`, `onChanged` | `{value}` |
| `searchBar` | `hint`, `onChanged`, `onSubmitted` | `{value: text}` |
| `tooltip` | `message`, `child` | — |
| `popupMenu` | `items: [{value, label, icon?}]`, `icon?`, `onSelected` | `{value}` |
| `banner` | `message`, `icon?`, `actions: [{label, onTap}]` | taps |
| `bottomAppBar` | `children`, `color?`, `height?` | — |
| `carousel` | `children`, `itemExtent?` (200), `shrinkExtent?` (0) | — |
| `drawer` | `drawer: node`, `child: node` — wraps child in a nested Scaffold with a Drawer; an `appBar` inside gets the hamburger automatically | — |

### Overlays (modal surfaces)

Zero-size driver nodes: they open a modal surface when they ENTER the tree and close it when they leave. Pattern: keep `state.overlay = null | 'sheet' | ...`, render the node conditionally, and on its dismiss event set `state.overlay = null` + re-render.

| Type | Key props | Events |
|------|-----------|--------|
| `bottomSheet` | `child`, `height?`, `color?`, `dismissible?` (true), `onDismiss?` | dismiss → `onDismiss ?? 'bottomSheetDismiss'` |
| `dialog` | `title?`, `message?` or `child?`, `actions: [{label, onTap}]`, `dismissible?`, `onDismiss?` | action tap = pop + its `onTap`; barrier → `onDismiss ?? 'dialogDismiss'` |
| `snackBar` | `message`, `actionLabel?`, `onAction?`, `durationMs?` | `onAction` |
| `datePicker` | `initialDate?`/`firstDate?`/`lastDate?` ('YYYY-MM-DD'), `onSelected`, `onDismiss?` | `{value: 'YYYY-MM-DD'}` |
| `timePicker` | `initialTime?` ('HH:MM'), `onSelected`, `onDismiss?` | `{value: 'HH:MM'}` (24h) |

### Animated (Implicit Animations)

| Type | Key props | Description |
|------|-----------|-------------|
| `animatedContainer` | same as `container` + `duration` (ms), `curve`, `transform` | Animates size/color/decoration changes |
| `animatedOpacity` | `child`, `opacity`, `duration`, `curve` | Smooth fade in/out |
| `animatedPositioned` | `child`, `left`, `top`, `right`, `bottom`, `width`, `height`, `duration`, `curve` | Animates position inside a `stack` |
| `entrance` | `child`, `animation`, `delay` (ms), `duration` (ms), `curve` | One-shot mount animation — plays once, then rests |
| `animatedSwitcher` | `child`, `switchKey`, `animation`, `duration` (ms), `curve` | View transition — changing `switchKey` animates old child out, new one in |

**Curves**: `linear`, `easeIn`, `easeOut`, `easeInOut`, `bounce`, `bounceIn`, `elastic`, `elasticIn`, `decelerate`, `fastOutSlowIn`, plus M3 motion tokens (approximated): `emphasized`, `emphasizedAccelerate`, `emphasizedDecelerate`, `standard`, `standardAccelerate`, `standardDecelerate`

**Transform** (on `animatedContainer`): `{translateX, translateY, scale, rotate}` — rotate in radians.

**Animation variants** (the `animation` prop — `type` stays the node discriminator, so the variant can't live there; unknown values fall back to `fade`):
- `entrance`: `fade`, `slideUp`, `slideDown`, `slideLeft`, `slideRight`, `scale`, `fadeScale`
- `animatedSwitcher`: `fade`, `slideLeft`, `slideRight`, `slideUp`, `scale`, `fadeScale`

```javascript
// Staggered list entrance — delay holds the hidden start state, so i * 60
// cascades the rows in one after another.
{type:'listView', children: items.map(function(it, i) {
  return {type:'entrance', animation:'slideUp', delay:i*60, duration:300,
    child: row(it)};
})}

// List → detail transition — keep switchKey stable to update in place,
// change it to animate the swap.
{type:'animatedSwitcher', switchKey: selected ? 'card:'+selected.id : 'list',
  animation:'slideLeft', duration:300, child: viewNode}
```

### Data Viz

| Type | Key props | Description |
|------|-----------|-------------|
| `flChart` | `chartType` + per-type props (below) | Full charts via fl_chart — prefer over `chart` for anything user-facing |
| `chart` | `data`, `chartType` (`line`\|`bar`), `color`, `fillColor`, `strokeWidth`, `height` | Legacy sparkline/bar painter |
| `map` | `center {lat,lng}`, `zoom`, `markers [{id,lat,lng,label?,color?}]`, `polylines`, `fitBounds`, `width`, `height` | OpenStreetMap (needs `network`) — `onTap` fires `{lat,lng}`, `onMarkerTap` fires `{id}`; `center`/`zoom` apply on creation only, so re-create the node to move the camera |
| `path` | `path` (SVG path data), `progress`, `color`, `strokeWidth`, `cap`, `join` | SVG path stroke |
| `absoluteFill` / `fill` | `color`, `child` | Expand to fill parent |
| `video` | `src`, `autoPlay`, `loop`, `controls`, `fit`, `width`, `height` | Video player |
| `audio` | `src`, `autoPlay`, `loop`, `title` | Audio player |

**`flChart` per chartType:**

- `'line'`: `{series: [{label?, color?, points: [y...]}], minY?, maxY?, showGrid? (true), curved? (true)}`
- `'bar'`: `{values: [y...], color?}`
- `'pie'`: `{sections: [{label?, value, color?}], centerSpaceRadius? (32)}`
- `'radar'`: `{features: [names], entries: [{label?, color?, values}]}` (≥3 features; short value lists are zero-padded)
- `'scatter'`: `{points: [{x, y, radius?, color?}], minX?/maxX?/minY?/maxY?}`

Default palette cycles `#818cf8 #a78bfa #22d3ee #f59e0b #ef4444`.

**Universal effect props** (any node): `offsetX`, `offsetY`, `scale`, `rotation` (radians), `opacity`, `blur`.

### Alignment values

```
mainAxisAlignment: 'start' | 'end' | 'center' | 'spaceBetween' | 'spaceAround' | 'spaceEvenly'
crossAxisAlignment: 'start' | 'end' | 'center' | 'stretch' | 'baseline'
mainAxisSize: 'max' | 'min'
```

### GestureDetector events

The `gestureDetector` node fires events with coordinates:

| Event | Payload |
|-------|---------|
| `onTap` | `{}` |
| `onTapDown` | `{x, y}` — local position |
| `onTapUp` | `{x, y}` |
| `onPanStart` | `{x, y}` |
| `onPanUpdate` | `{x, y, dx, dy}` — position + delta |
| `onPanEnd` | `{velocityX, velocityY}` |
| `onLongPress` | `{}` |

```javascript
jsr.render({
  type: 'gestureDetector',
  onTapDown: 'tap',
  onPanUpdate: 'drag',
  child: {type: 'container', width: 300, height: 200}
});

jsr.onEvent(function(action, payload) {
  if (action === 'drag') {
    playerX = payload.x;
    playerY = payload.y;
    render();
  }
});
```

---

## Node Reference — Key Props

### `text`
```javascript
{
  type: 'text',
  data: 'Hello',
  style: {
    color: '#ffffff',
    fontSize: 14,
    fontWeight: 'w600',    // w100–w900, bold, normal
    fontStyle: 'italic',
    textAlign: 'center',   // left, center, right, justify
    letterSpacing: 1.2,
  },
  maxLines: 1,
  overflow: 'ellipsis',   // ellipsis, clip, fade, visible
}
```

### `container`
```javascript
{
  type: 'container',
  width: 200,
  height: 100,
  padding: [16, 8, 16, 8],    // [left, top, right, bottom]
  margin: [0, 4, 0, 4],
  alignment: 'center',         // center, topLeft, bottomRight, etc.
  decoration: {
    color: '#1e293b',
    borderRadius: 12,          // number OR [tl, tr, br, bl]
    border: { color: '#334155', width: 1 },
    gradient: {
      type: 'linear',          // linear | radial
      colors: ['#1e293b', '#0f172a'],
    },
  },
  child: { type: 'text', data: 'hi' },
}
```

### `inkWell`
```javascript
{
  type: 'inkWell',
  onTap: 'my_action',          // fires handleEvent('my_action', {})
  borderRadius: 8,
  child: { type: 'text', data: 'Tap me' },
}
```

### `button`
```javascript
{
  type: 'button',
  label: 'Submit',
  onPressed: 'btn_submit',     // fires handleEvent('btn_submit', {})
  icon: 'send',                // optional Material icon name
  color: '#2563eb',
  textColor: '#ffffff',
}
```

### `textField`
```javascript
{
  type: 'textField',
  hint: 'Enter city...',
  value: currentCity,          // pre-fill
  onSubmit: 'city_submit',     // fires handleEvent('city_submit', { value: 'London' })
  onChange: 'city_change',     // fires on every keystroke
  obscure: false,              // true for passwords
}
```

### `chart`
```javascript
{
  type: 'chart',
  data: [1.2, 2.5, 1.8, 3.0, 2.1],   // array of numbers
  color: '#22c55e',                    // line color
  fillColor: '#22c55e33',              // fill under line (semi-transparent)
  strokeWidth: 2,
  height: 60,
}
```
Bar variant: `{type:'chart', chartType:'bar', data:[3,7,4], color:'#0ea5e9', height:60}`

### `icon`
```javascript
{
  type: 'icon',
  name: 'settings',     // Material icon name (snake_case)
  color: '#94a3b8',
  size: 24,
}
```

### `flChart`
```javascript
{
  type: 'flChart',
  chartType: 'line',                    // line | bar | pie | radar | scatter
  series: [
    { label: '2024', color: '#818cf8', points: [1.2, 2.5, 1.8, 3.0] },
    { label: '2025', color: '#22d3ee', points: [1.8, 2.1, 2.9, 3.6] },
  ],
  height: 160,
}
```
Pie: `{type:'flChart', chartType:'pie', sections:[{label:'A', value:40},{label:'B', value:60}], height:180}`

### `segmentedButton` (Material 3)
```javascript
{
  type: 'segmentedButton',
  segments: [
    {value: 'day', label: 'Day'},
    {value: 'week', label: 'Week'},
    {value: 'month', label: 'Month'},
  ],
  selected: [state.range],
  onChanged: 'range_changed',   // fires handleEvent('range_changed', {value: ['week']})
}
```

### `bottomSheet` (overlay)
```javascript
// Render conditionally; the sheet opens while the node is in the tree and
// closes when it leaves. Always clear the state on dismiss.
if (state.overlay === 'settings') {
  children.push({
    type: 'bottomSheet',
    height: 320,
    onDismiss: 'close_overlay',   // or omit → 'bottomSheetDismiss'
    child: settingsPanel(),
  });
}
// jsr.onEvent: on 'close_overlay'/'bottomSheetDismiss' → state.overlay = null; render();
```

---

## Full Example: Hello World (Counter)

```javascript
(function() {
  var count = 0;
  var t = jsr.theme;

  function render() {
    jsr.render({
      type: 'center',
      child: {
        type: 'column',
        mainAxisSize: 'min',
        children: [
          {
            type: 'text',
            data: 'Count: ' + count,
            style: { color: t.text, fontSize: 32, fontWeight: 'bold' }
          },
          { type: 'sizedBox', height: 16 },
          {
            type: 'button',
            label: 'Tap me!',
            onPressed: 'increment',
            color: t.accent
          }
        ]
      }
    });
    jsr.exportState({ count: count });
  }

  jsr.onEvent(function(actionId) {
    if (actionId === 'increment') {
      count++;
      jsr.storage.set('count', count);
      render();
    }
  });

  jsr.onThemeChange(function(theme) {
    t = theme;
    render();
  });

  jsr.setTitle('Counter');

  // Restore saved count
  jsr.storage.get('count').then(function(saved) {
    if (saved !== null) count = saved;
    render();
  });
})();
```

---

## Debugging

There is no CLI debugger — use these:

1. **Read the app source back** with your file tools and check the syntax mentally. Remember: ES5-style only (`var` + `function`, no template literals, no classes, no async/await); all async APIs return Promises — chain with `.then()`.
2. **`console.log`** — output is visible in the app's logs view in Fa. Log liberally.
3. **`jsr.showError(message)`** — surfaces an error overlay directly in the app UI.
4. **`jsr.exportState`** — the exported state is visible to the host, and when the user messages you via the Fa floating button you receive it along with a screenshot. Keep it current and meaningful.
5. After a fix, just write the file — the app reloads automatically.

Common failures: UI not updating after an edit → syntax error (read the file back, check logs); `jsr.render()` not showing → missing IIFE wrapper; button dead → missing `jsr.onEvent`; `fetchJson` / `jsr.fa.llm` failing → permission off in manifest or the runtime permissions dialog.

---

## Testing Your App (do this BEFORE showing it to the user)

Always write a test for a non-trivial app and run it before handing over. Tests live in `test/apps/<id>_test.dart` in the app repo and run with `flutter test test/apps/`. Two proven recipes:

### 1. Headless logic test (fast — no widgets)

Boots the real JS engine against a `MemoryExecutionEnv`, drives events directly, and asserts on `exportedState` and the render tree. Use this for game logic, state machines, data transforms.

```dart
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('my app logic', (tester) async {
    final env = MemoryExecutionEnv();
    await env.writeFile('apps/myapp/widget.js', myWidgetJsSource);
    final engine = JsAppEngine(
      app: JsAppInfo.fromManifest(
        const {'id': 'myapp', 'name': 'My App'},
        bundled: false,
        fallbackId: 'myapp',
      ),
      env: env,
      permissions: const AppPermissions(), // match the manifest
    );
    try {
      // The JS backend needs the REAL event loop: run everything
      // engine-related inside tester.runAsync. Fake-time pump() would
      // starve the bridge (and dart:io reads hang outside runAsync).
      await tester.runAsync(() async {
        await engine.start();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(engine.tree.value, isNotNull);
        expect(engine.exportedState?['ready'], isTrue);

        await engine.callEvent('increment');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(engine.exportedState?['count'], 1);
      });
    } finally {
      await tester.runAsync(engine.dispose);
    }
  });
}
```

### 2. UI tap test (events through the real renderer)

Renders the JS tree with `JsonWidgetRenderer` and taps actual widgets — catches dead-button and hit-test bugs.

```dart
await tester.pumpWidget(
  MaterialApp(
    home: ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: engine.tree,
      builder: (context, tree, _) {
        if (tree == null) return const SizedBox.shrink();
        return JsonWidgetRenderer(
          theme: JsonWidgetTheme.fromAccent(
            Theme.of(context).colorScheme.primary,
          ),
          onEvent: (id, payload) => engine.callEvent(id, payload),
        ).build(tree, context);
      },
    ),
  ),
);
await tester.tap(find.text('7'));
// Let the tap travel: microtask → engine → render → exportedState.
await tester.runAsync(
  () => Future<void>.delayed(const Duration(milliseconds: 300)),
);
expect(engine.exportedState?['expression'], '7');
```

Rules of thumb:
- Boot the engine inside `tester.runAsync`; never read files with dart:io outside it.
- Poll `engine.exportedState` with small real delays instead of assuming instant delivery.
- Assert both the exported state AND the tree (`engine.tree.value`) — a render that never fires is a bug even when logic is right.
- Reference implementations to copy: `test/apps/js_app_engine_test.dart` (recipe 1), `test/apps/js_app_tap_test.dart` (recipe 2), `test/apps/js_app_view_test.dart` (full render of the calculator demo).
- Pure render-tree checks (no engine needed) can build a hand-written tree through `JsonWidgetRenderer` directly — handy for layout tweaks.

---

## Demo Apps — Study References

Real-world examples shipped in the `apps/` folder. Read their source before building something similar.

| ID | Name | Description | Network |
|----|------|-------------|---------|
| `calculator` | Calculator | Scientific calculator — animated button press | ❌ |
| `weather` | Weather | Current weather via wttr.in API, animated transitions | ✅ |
| `crypto` | Crypto Prices | Live BTC/ETH/SOL via CoinGecko, animated rows | ✅ |
| `stocks` | Stock Prices | Real-time stock quotes, textField + fetch | ✅ |
| `yolo-hello` | Hello Animated | Interactive demo: bounce, gradient, gestures, RAF | ❌ |
| `animation-showcase` | Animation Showcase | 7 animation demos: fade, morph, bounce, cards, drag, pulse, colors | ❌ |
| `calendar` | Calendar | System calendar events via `jsr.fa.calendar`, day navigation, add/edit/delete forms + permission states | ❌ | <!-- fa-platforms: ios,macos -->
| `contacts` | Contacts | System contacts via `jsr.fa.contacts.*`, search, detail card with call/SMS, add form + permission states | ❌ | <!-- fa-platforms: ios,macos -->
| `map` | Map | OSM `map` node: preset markers, tap-to-pin, zoom controls | ✅ |
| `health` | Health | HealthKit dashboard via `jsr.fa.health.summary` (steps/HR/sleep cards + charts), demo fallback | ❌ | <!-- fa-platforms: ios,macos -->
| `homekit` | Home | HomeKit control via `jsr.fa.home.*` — rooms, accessory cards, power/brightness/temperature controls + demo fallback | ❌ | <!-- fa-platforms: ios -->
| `voice-notes` | Voice Notes | Microphone record + transcript list via `jsr.fa.asr.*`, persisted via `jsr.storage` | ❌ | <!-- fa-platforms: ios,macos -->
| `reminders` | Reminders | Local notifications via `jsr.fa.notify.*` — schedule in N minutes, list + cancel per row, persisted via `jsr.storage` | ❌ | <!-- fa-platforms: ios,macos -->

**Tip**: Before building a new app, always read the source of the most similar demo — especially for network fetch, storage, and theming patterns.

---

## Tips for the Fa Agent

1. **Always use `jsr.theme` colors** — never hardcode hex. Users switch dark/light mode and `jsr.theme` follows it live (re-render from `jsr._onThemeChange`).
2. **Wrap everything in an IIFE** — `(function(){ ... })()` — functions inside are NOT global.
3. **`jsr.onEvent` is mandatory** — register it even if you handle few events.
4. **Storage is async** — `jsr.storage.get()` returns a Promise. Always use `.then()` before using the value.
5. **`jsr.render()` replaces everything** — not additive; always render the complete UI tree.
6. **After editing files, do nothing** — the app reloads automatically; the user can also hit Reload.
7. **Network requires the manifest flag** — set `"network": true` or `fetchJson` fails; same for `llm`/`allowedCommands` and the `calendar`/`homekit`/`health`/`contacts`/`microphone`/`notifications`/`media` bridges. Tell the user to enable permissions in the app's permissions dialog when needed.
8. **Always check `__error`** on results from `jsr.fetchJson` and the `jsr.fa.*` bridges before using the data.
9. **Always call `jsr.exportState`** with meaningful state — it's what you (the agent) receive when the user talks to you from inside the app.
10. **Timer cleanup** — save `setInterval` IDs and `clearInterval` when done.
11. **Never hand-edit `apps/<id>/storage.json`** — it's owned by `jsr.storage`.
12. **Write files with your write/edit tools** — never shell heredocs.
13. **Study CANONICAL sources first** — run `apps_catalog` action `get-source` with the closest matching id (unpacks reference code into `.fah/widget-sources/<id>/`), then read those files. Installed copies in `apps/` may be user-modified — never learn patterns from them. Browse the full gallery at https://fa1.dev/widgets. To publish your widget for everyone: open a PR adding `widgets/<id>/` to https://github.com/IstiN/fa_widgets (CI validates and republishes automatically).
14. **Open apps for the user** — the `open_app` tool navigates the Fa UI to an app by id; use it after creating or fixing an app instead of telling the user where to tap.
