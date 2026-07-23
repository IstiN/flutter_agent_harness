---
name: js-apps
description: Create JS apps (jsr.render UI) that run inside Fa's Apps section — manifest.json + widget.js in the apps/ folder
---

# Fa JS App Development Skill

> **For the Fa coding agent**: This is the authoritative guide for creating JS apps that run inside the Fa Flutter app. Read the **Quick Start** first — it shows the minimal workflow.

---

## ⚡ Quick Start (Minimal Workflow)

JS apps live in the sandbox env folder `apps/<id>/`. You create and edit them with your normal file tools (write/edit) — no CLI involved.

```
1. write apps/my-app/manifest.json    metadata + permissions
2. write apps/my-app/widget.js        ES5-style IIFE, jsr.* API
3. tell the user to open the app in Fa's Apps section
```

### After editing — reload is automatic

The host **watches the app files and reloads the running app automatically** as soon as you write/edit them. The user can also hit the Reload button. There is no CLI reload step — just write the file and the app picks it up.

### Critical rules

1. **Write files with your write/edit tools** — never shell out to `printf`/`cat` heredocs; the sandbox `apps/` folder is just a normal directory for your file tools.
2. **Always wrap `widget.js` in an IIFE** — `(function(){ ... })()`.
3. **Register `jsr.onEvent`** — even if you handle few events.
4. **Set the permissions the app actually needs** in `manifest.json`, and tell the user they may also need to enable them at runtime in the app's permissions dialog.
5. **Never hand-edit `apps/<id>/storage.json`** — that file is owned by `jsr.storage`.
6. **Study the demo apps first** — the `apps/` folder ships working examples (calculator, weather, stocks, crypto, yolo-hello, animation-showcase). Read their source before building something similar.

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
  "icon": "🚀",
  "network": true,
  "allowedCommands": [],
  "llm": false,
  "homekit": false,
  "health": false,
  "contacts": false
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `id` | ✅ | Unique identifier, kebab-case, matches folder name |
| `name` | ✅ | Display name shown in UI |
| `description` | ✅ | Short description |
| `version` | ✅ | Semver string |
| `icon` | ✅ | Emoji used in the app picker |
| `network` | ❌ | `true` to allow `jsr.fetchJson` (default: false) |
| `allowedCommands` | ❌ | Array of shell commands allowed via `jsr.exec` (default: none) |
| `llm` | ❌ | `true` to allow `jsr.fa.llm` (default: false) |
| `homekit` | ❌ | `true` to allow `jsr.fa.homekit` (default: false) |
| `health` | ❌ | `true` to allow `jsr.fa.health` (default: false) |
| `contacts` | ❌ | `true` to allow `jsr.fa.contacts` (default: false) |

All permissions default to false/absent. The user can also toggle them at runtime in the app's permissions dialog — so when you create an app, set the permissions it needs in the manifest **and** tell the user they may need to enable them.

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

### `jsr.theme` — Current Theme Colors
Reactive theme object. Always use these colors instead of hardcoded hex values so your app respects light/dark mode.

```javascript
var t = jsr.theme;
// t.isDark   — boolean
// t.bg       — main background color hex (e.g. '#0f172a')
// t.surface  — card/panel surface color
// t.border   — border color
// t.accent   — accent/primary color
// t.text     — primary text color
// t.muted    — secondary/muted text color
```

### `jsr.onThemeChange(callback)`
Subscribe to theme changes (when user toggles dark/light mode). The callback receives the same object as `jsr.theme`.

```javascript
jsr.onThemeChange(function(theme) {
  render(); // re-render with new colors
});
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

Use it for summarization, tagging, smart suggestions — anything that benefits from the user's connected model. Keep prompts self-contained (the call is stateless; there is no chat history).

### `jsr.fa.homekit(action, args)` / `jsr.fa.health(action, args)` / `jsr.fa.contacts(action, args)` → Promise
Platform bridges. Each requires its matching manifest permission (`homekit` / `health` / `contacts`). **These are currently stubs**: they resolve with an error message until implemented on the host. Do not build apps that depend on them without warning the user.

**Error convention**: bridge failures (permission denied, not implemented, platform error) come back as an object with an `__error` field — the same convention as `jsr.fetchJson`. Always check `result.__error` before using a result:

```javascript
jsr.fa.homekit('listDevices', {}).then(function(result) {
  if (result && result.__error) { jsr.showError(result.__error); return; }
  renderDevices(result);
});
```

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
| `stack` | `children`, `alignment`, `fit` (`expand`/`loose`) | Overlapping layers |
| `center` | `child` | Center child |
| `padding` | `child`, `padding: [left, top, right, bottom]` | Add padding |
| `expanded` | `child`, `flex` | Flex expand inside row/column |
| `sizedBox` | `width`, `height`, `child` | Fixed size box |
| `safeArea` | `child` | Insets for notches/bars |
| `aspectRatio` | `child`, `aspectRatio` | Force aspect ratio |
| `listView` | `children`, `shrinkWrap`, `scrollDirection` | Scrollable list |

### Display

| Type | Key props | Description |
|------|-----------|-------------|
| `text` | `data`, `style` | Text label |
| `icon` | `name`, `color`, `size` | Material icon by name |
| `divider` | `color`, `height`, `thickness` | Horizontal line |
| `image` | `url`, `asset:<path>`, `file:<path>`, `fit`, `width`, `height` | Image |

### Containers

| Type | Key props | Description |
|------|-----------|-------------|
| `container` | `child`, `color`, `decoration`, `padding`, `margin`, `width`, `height`, `alignment` | Styled box |
| `card` | `child`, `color`, `elevation`, `borderRadius` | Material card |
| `inkWell` | `child`, `onTap`, `borderRadius` | Tappable area (ripple effect) |

### Interactive

| Type | Key props | Description |
|------|-----------|-------------|
| `button` | `label`, `onPressed`, `icon`, `color`, `textColor` | Elevated button |
| `textField` | `hint`, `value`, `onSubmit`, `onChange`, `obscure` | Text input field |
| `gestureDetector` | `child`, `onTap`, `onTapDown`, `onTapUp`, `onPanStart`, `onPanUpdate`, `onPanEnd` | Touch/gesture input with local coordinates |

### Animated (Implicit Animations)

| Type | Key props | Description |
|------|-----------|-------------|
| `animatedContainer` | same as `container` + `duration` (ms), `curve`, `transform` | Animates size/color/decoration changes |
| `animatedOpacity` | `child`, `opacity`, `duration`, `curve` | Smooth fade in/out |
| `animatedPositioned` | `child`, `left`, `top`, `right`, `bottom`, `width`, `height`, `duration`, `curve` | Animates position inside a `stack` |

**Curves**: `linear`, `easeIn`, `easeOut`, `easeInOut`, `bounce`, `bounceIn`, `elastic`, `elasticIn`, `decelerate`, `fastOutSlowIn`

**Transform** (on `animatedContainer`): `{translateX, translateY, scale, rotate}` — rotate in radians.

### Data Viz

| Type | Key props | Description |
|------|-----------|-------------|
| `chart` | `data`, `color`, `fillColor`, `strokeWidth`, `height` | Sparkline chart (line graph) |
| `path` | `path` (SVG path data), `progress`, `color`, `strokeWidth`, `cap`, `join` | SVG path stroke |
| `absoluteFill` / `fill` | `color`, `child` | Expand to fill parent |
| `video` | `src`, `autoPlay`, `loop`, `controls`, `fit`, `width`, `height` | Video player |
| `audio` | `src`, `autoPlay`, `loop`, `title` | Audio player |

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

### `icon`
```javascript
{
  type: 'icon',
  name: 'settings',     // Material icon name (snake_case)
  color: '#94a3b8',
  size: 24,
}
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

**Tip**: Before building a new app, always read the source of the most similar demo — especially for network fetch, storage, and theming patterns.

---

## Tips for the Fa Agent

1. **Always use `jsr.theme` colors** — never hardcode hex. Users switch dark/light mode.
2. **Wrap everything in an IIFE** — `(function(){ ... })()` — functions inside are NOT global.
3. **`jsr.onEvent` is mandatory** — register it even if you handle few events.
4. **Storage is async** — `jsr.storage.get()` returns a Promise. Always use `.then()` before using the value.
5. **`jsr.render()` replaces everything** — not additive; always render the complete UI tree.
6. **After editing files, do nothing** — the app reloads automatically; the user can also hit Reload.
7. **Network requires the manifest flag** — set `"network": true` or `fetchJson` fails; same for `llm`/`allowedCommands` and the `homekit`/`health`/`contacts` bridges. Tell the user to enable permissions in the app's permissions dialog when needed.
8. **Always check `__error`** on results from `jsr.fetchJson` and the `jsr.fa.*` bridges before using the data.
9. **Always call `jsr.exportState`** with meaningful state — it's what you (the agent) receive when the user talks to you from inside the app.
10. **Timer cleanup** — save `setInterval` IDs and `clearInterval` when done.
11. **Never hand-edit `apps/<id>/storage.json`** — it's owned by `jsr.storage`.
12. **Write files with your write/edit tools** — never shell heredocs.
13. **Study demo apps first** — read the closest match in `apps/` before writing new code.
