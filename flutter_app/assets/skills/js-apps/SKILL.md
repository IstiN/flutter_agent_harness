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
3. open it for the user: open_app(id="my-app") — or tell them to open it in Fa's Apps section
```

### Opening apps for the user — the `open_app` tool

You can open any installed app for the user with the `open_app` tool: pass the app id (its `apps/<id>` folder name) and the host navigates straight to the app. Use it when the user asks to see an app, or right after you create/fix one — "I've opened it for you" beats instructions. Unknown ids come back with the list of available ids.

### After editing — reload is automatic

The host **watches the app files and reloads the running app automatically** as soon as you write/edit them. The user can also hit the Reload button. There is no CLI reload step — just write the file and the app picks it up.

### Critical rules

1. **Write files with your write/edit tools** — never shell out to `printf`/`cat` heredocs; the sandbox `apps/` folder is just a normal directory for your file tools.
2. **Always wrap `widget.js` in an IIFE** — `(function(){ ... })()`.
3. **Register `jsr.onEvent`** — even if you handle few events.
4. **Set the permissions the app actually needs** in `manifest.json`, and tell the user they may also need to enable them at runtime in the app's permissions dialog.
5. **Never hand-edit `apps/<id>/storage.json`** — that file is owned by `jsr.storage`.
6. **Study the demo apps first** — the `apps/` folder ships working examples (calculator, weather, stocks, crypto, yolo-hello, animation-showcase, calendar, map, health, homekit). Read their source before building something similar.

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
  "contacts": false,
  "calendar": false
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `id` | ✅ | Unique identifier, kebab-case, matches folder name |
| `name` | ✅ | Display name shown in UI |
| `description` | ✅ | Short description |
| `version` | ✅ | Semver string |
| `icon` | ✅ | App-picker icon: an emoji, inline SVG markup (`"<svg …>"`), or an SVG filename inside the app folder (see below) |
| `network` | ❌ | `true` to allow `jsr.fetchJson` (default: false) |
| `allowedCommands` | ❌ | Array of shell commands allowed via `jsr.exec` (default: none) |
| `llm` | ❌ | `true` to allow `jsr.fa.llm` (default: false) |
| `homekit` | ❌ | `true` to allow `jsr.fa.homekit` (default: false) |
| `health` | ❌ | `true` to allow `jsr.fa.health` (default: false) |
| `contacts` | ❌ | `true` to allow `jsr.fa.contacts` (default: false) |
| `calendar` | ❌ | `true` to allow `jsr.fa.calendar` — system calendar access (read + create/update/delete; default: false) |

All permissions default to false/absent. The user can also toggle them at runtime in the app's permissions dialog — so when you create an app, set the permissions it needs in the manifest **and** tell the user they may need to enable them.

### App icons (emoji or SVG)

The `icon` field accepts three forms:

1. **Emoji** — `"icon": "🚀"` (simplest).
2. **Inline SVG markup** — `"icon": "<svg xmlns=…>…</svg>"`.
3. **SVG file in the app folder** — `"icon": "icon.svg"`, resolved as `apps/<id>/icon.svg`. Create the file with your write tool alongside the manifest. Prefer this for anything non-trivial; keep the SVG small, single-color friendly (`stroke`/`fill` with a hex color), `viewBox` 24×24.

SVG icons render in the sidebar, the apps grid, the app bar and the permissions dialog. Inside the app UI itself, use the `svg` node (`{"type": "svg", "data": "<svg …>", "width": 24, "color": "#818cf8"}`) for inline vector graphics.

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

Use it for summarization, tagging, smart suggestions — anything that benefits from the user's connected model. Keep prompts self-contained (the call is stateless; there is no chat history).

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
| `listView` | `children`, `shrinkWrap`, `scrollDirection`, `physics` | Scrollable list (set `shrinkWrap: false` + bounded height for long lists) |
| `gridView` | `children`, `crossAxisCount`, `crossAxisSpacing`, `mainAxisSpacing`, `childAspectRatio`, `padding` | Fixed-column grid | (`shrinkWrap` default true, `physics` `never`\|`always`\|`platform` to enable scrolling)

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
| `textArea` | `value`, `hint`, `minLines` (3), `maxLines` (8), `onChange`, `onSubmit` | Multiline text input (expands, then scrolls) |
| `gestureDetector` | `child`, `onTap`, `onTapDown`, `onTapUp`, `onPanStart`, `onPanUpdate`, `onPanEnd` | Touch/gesture input with local coordinates |

### Animated (Implicit Animations)

| Type | Key props | Description |
|------|-----------|-------------|
| `animatedContainer` | same as `container` + `duration` (ms), `curve`, `transform` | Animates size/color/decoration changes |
| `animatedOpacity` | `child`, `opacity`, `duration`, `curve` | Smooth fade in/out |
| `animatedPositioned` | `child`, `left`, `top`, `right`, `bottom`, `width`, `height`, `duration`, `curve` | Animates position inside a `stack` |
| `entrance` | `child`, `animation`, `delay` (ms), `duration` (ms), `curve` | One-shot mount animation — plays once, then rests |
| `animatedSwitcher` | `child`, `switchKey`, `animation`, `duration` (ms), `curve` | View transition — changing `switchKey` animates old child out, new one in |

**Curves**: `linear`, `easeIn`, `easeOut`, `easeInOut`, `bounce`, `bounceIn`, `elastic`, `elasticIn`, `decelerate`, `fastOutSlowIn`

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
| `chart` | `data`, `chartType` (`line`\|`bar`), `color`, `fillColor`, `strokeWidth`, `height` | Sparkline or bar chart |
| `map` | `center {lat,lng}`, `zoom`, `markers [{id,lat,lng,label?,color?}]`, `polylines`, `fitBounds`, `width`, `height` | OpenStreetMap (needs `network`) — `onTap` fires `{lat,lng}`, `onMarkerTap` fires `{id}`; `center`/`zoom` apply on creation only, so re-create the node to move the camera |
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
| `calendar` | Calendar | System calendar events via `jsr.fa.calendar`, day navigation, add/edit/delete forms + permission states | ❌ |
| `map` | Map | OSM `map` node: preset markers, tap-to-pin, zoom controls | ✅ |
| `health` | Health | `jsr.fa.health` bridge status + demo metrics dashboard | ❌ |
| `homekit` | Home | `jsr.fa.homekit` bridge status + demo device panel with local toggles | ❌ |

**Tip**: Before building a new app, always read the source of the most similar demo — especially for network fetch, storage, and theming patterns.

---

## Tips for the Fa Agent

1. **Always use `jsr.theme` colors** — never hardcode hex. Users switch dark/light mode and `jsr.theme` follows it live (re-render from `jsr._onThemeChange`).
2. **Wrap everything in an IIFE** — `(function(){ ... })()` — functions inside are NOT global.
3. **`jsr.onEvent` is mandatory** — register it even if you handle few events.
4. **Storage is async** — `jsr.storage.get()` returns a Promise. Always use `.then()` before using the value.
5. **`jsr.render()` replaces everything** — not additive; always render the complete UI tree.
6. **After editing files, do nothing** — the app reloads automatically; the user can also hit Reload.
7. **Network requires the manifest flag** — set `"network": true` or `fetchJson` fails; same for `llm`/`allowedCommands` and the `calendar`/`homekit`/`health`/`contacts` bridges. Tell the user to enable permissions in the app's permissions dialog when needed.
8. **Always check `__error`** on results from `jsr.fetchJson` and the `jsr.fa.*` bridges before using the data.
9. **Always call `jsr.exportState`** with meaningful state — it's what you (the agent) receive when the user talks to you from inside the app.
10. **Timer cleanup** — save `setInterval` IDs and `clearInterval` when done.
11. **Never hand-edit `apps/<id>/storage.json`** — it's owned by `jsr.storage`.
12. **Write files with your write/edit tools** — never shell heredocs.
13. **Study demo apps first** — read the closest match in `apps/` before writing new code.
14. **Open apps for the user** — the `open_app` tool navigates the Fa UI to an app by id; use it after creating or fixing an app instead of telling the user where to tap.
