# Chrome Web Store — Privacy tab answers — fa — browser agent

Copy-paste-ready justifications (each ≤1000 chars, CWS field limit).
Ground truth: `browser_ext/dart/src/permission_matrix.dart` (the
permission⇄tool matrix, issue #137/#30) — every permission below backs a
registered agent tool. Single common frame: fa is a user-instructed AI
agent living in the side panel; the user asks in natural language and
the agent drives Chrome through a generic chrome.* bridge
(`browser_api`) to fulfill that request. No telemetry, no analytics,
nothing leaves the machine except user-instructed requests to the
user's OWN configured model provider.

## gh-1630 note (removed permissions)

`contentSettings`, `downloads`, `fontSettings`, `identity`, and
`desktopCapture` were REMOVED from the manifest (CWS review: requested-
but-unused permissions). The extension neither requests nor calls them;
the disclosures below cover only the retained set.

## Single purpose description (already filled)

`fa — your agent in this browser: the full fa app in the side panel, page powers for the agent.`

## Permission justifications

**alarms** — The agent schedules and awaits time-based work on the user's
request: reminders, delayed steps in multi-step tasks, and periodic
checks (e.g. "watch this page and ping me when the price changes").
Alarms also drive the service worker's keep-alive bookkeeping for
long-running user-started tasks.

**bookmarks** — On the user's instruction the agent reads, organizes,
creates and removes bookmarks (e.g. "bookmark all open tabs into a
folder", "clean up duplicates"). No bookmark data leaves the device
unless the user explicitly asks the agent to summarize or share it.

**browsingData** — Used only when the user asks the agent to clear
browser data ("clear cookies for this site", "wipe cache to fix this
page"). The agent never wipes data autonomously; every destructive
action requires an explicit user instruction.

**clipboardRead** — Lets the agent read clipboard content the user
explicitly refers to ("summarize what's in my clipboard", "fill this
form with my clipboard data"). Read on demand during a user-driven task
only.

**clipboardWrite** — Lets the agent place task results on the clipboard
when the user asks ("copy the answer", "put the extracted table on my
clipboard").

**contextMenus** — Adds fa's right-click entries ("Ask fa about this
selection/page/link") so the user can invoke the agent in context. One
of the primary user entry points into the extension.

**cookies** — Page automation on the user's instruction sometimes
requires reading or setting cookies (logging into a flow the user
drives, keeping a session while the agent works through a multi-step
task). Cookies are never exfiltrated; they are used locally to make the
user's own sessions work.

**debugger** — Powers the agent's page-inspection tools (DOM snapshots,
console/log capture, network observation) when the user asks it to
debug, test, or automate a page ("why does this page fail", "run
through this checkout and report"). Attached per-tab, only during
user-driven tasks, detached afterwards.

**declarativeNetRequest** — Lets the agent apply user-requested network
rules for a workflow (e.g. block trackers on a page being tested,
simulate offline, strip a header that breaks an automation the user
asked for). Rules are scoped to the user's task.

**history** — On the user's instruction the agent searches and reads
browsing history ("find that article I read yesterday", "reopen the
tabs from this morning"). History is processed locally; it is only
transmitted when the user explicitly asks the agent to summarize or
share it with the user's own model provider.

**idle** — Lets the agent detect user idleness so long-running
user-started automations pause/resume politely (don't type into a page
while the user is back and typing) and so scheduled checks fire
sensibly.

**management** — Read-only use: the agent lists installed extensions
when the user asks ("what extensions do I have", "is X installed").
Never enables/disables/uninstalls anything without an explicit user
instruction.

**nativeMessaging** — Optional bridge to the fa CLI/desktop companion
when the user installs and pairs it: lets the browser agent hand tasks
to the user's local agent (files, shell, local models) with the user's
explicit setup. Absent without the companion; nothing talks to native
hosts otherwise.

**notifications** — Tells the user when a user-started task finishes,
fails, or needs a decision ("your export is ready", "the watched page
changed"). Pure status surfacing for work the user initiated.

**offscreen** — Runs the bundled on-device ML/JS interpreter runtimes
(local models, widget sandbox) in an offscreen document — required for
MV3 since the service worker has no DOM. All runtimes ship inside the
package; nothing is fetched as code.

**power** — On user request during long automations, keeps the screen/
system awake so a user-watched task isn't killed mid-run (e.g. a
multi-minute test drive of a site). Released when the task ends.

**privacy** — Read/adjust privacy-related settings only when the user
asks (e.g. "turn off third-party cookies while you test this"). Scoped
to the user's explicit instruction.

**proxy** — On explicit user request the agent configures a proxy for a
workflow ("run this through my local proxy", debugging geo/locale
issues). Never set autonomously; restored/cleared when the task ends.

**readingList** — On user instruction the agent saves pages to and reads
from Chrome's Reading List ("save this for later", "summarize my
reading list").

**scripting** — The core page-interaction mechanism: executes the
agent's page scripts in tabs the user directs it to (read content, fill
forms, click through flows). Executed code is generated per task from
the user's instruction; it runs with the user's gesture/intent on the
pages the user names.

**search** — On user request the agent performs web searches using
Chrome's configured search provider to ground answers and find pages
the user asked about.

**sessions** — Restores and inspects recently closed tabs/windows on the
user's request ("reopen what I just closed", "what did I close
yesterday") and restores working sets for user-defined workflows.

**sidePanel** — The extension's home: the full fa app lives in the side
panel (chat, tasks, apps). This is the primary UI surface the whole
product exists as.

**storage** — Persists the user's own data locally: sessions, settings,
widget/app installs, and task state. Everything stays on the device
(chrome.storage.local); sync storage only if the user opts into Chrome
sync semantics.

**system.cpu / system.memory / system.storage / system.display** —
Read-only device capability probes the on-device model runtime uses to
pick a feasible local model/quantization and window size, and to show
the user why a local model won't fit. No metrics leave the device.

**tabCapture** — On the user's explicit request, captures a tab's
audio/video (e.g. "record this tab while you test it", transcribe a
webinar the user is watching). Capture starts only from a user-driven
task and stops when it ends.

**tabGroups** — The agent organizes tabs into groups on request ("group
my research tabs by topic", "collapse everything except this") — a core
part of multi-tab workflows.

**tabs** — The fundamental agent capability: list, read, open, close,
rearrange and focus tabs as the user instructs ("close all social
tabs", "open these five links", "watch this tab"). Nearly every agent
task touches tabs.

**tts** — Reads agent answers aloud when the user asks ("read this to
me"), using Chrome's built-in speech synthesis. Text stays on-device
with the OS/default voices.

**unlimitedStorage** — Local models (on-device LLMs), widget/app
packages, and session history exceed the default 10 MB quota. All of it
is the user's own content, stored locally, deletable via the app's
settings.

**webNavigation** — Lets the agent track navigation lifecycle of tabs it
works in (know when a page finished loading before acting, follow
redirects during a user-driven flow). Observation is scoped to tabs the
user's task involves.

**webRequest** — Observes requests of pages under user-driven automation
(diagnosing failing calls, waiting for an XHR the flow depends on).
Used for inspection/coordination, not modification; no request data
leaves the device except inside user-instructed summaries to the user's
own provider.

**pageCapture** — Saves a page as MHTML when the user asks ("archive
this page", "save a snapshot before you change it"). Snapshots are
local files in the user's Downloads.

**topSites** — Optional (second-tier, Settings-gated): suggests
automation shortcuts based on the user's most-visited sites when the
user enables it. Off by default; read-only.

**userScripts** — Optional (second-tier, Settings-gated): lets the user
install their own or catalog widget scripts that run as proper user
scripts. Off by default; every script is user-chosen and inspectable.

**Host permission justification** — An agent whose purpose is to work
with the pages the user is on cannot enumerate those pages in advance:
the user points it at arbitrary sites ("log into X and download Y",
"read this article", "test my staging deploy"). Host access is the
product's single purpose; page content is read only inside user-driven
tasks, processed locally, and is transmitted only to the model provider
the USER configured (the user's own API endpoint) as the content of the
user's own request. fa collects nothing for the developer.

## Remote code

Facts: every JS/Wasm the extension executes with extension privileges
ships inside the package (dart2js agent, vendored interpreter runtimes,
Flutter panel). The ONE gray area: user-installed **widgets** — small JS
packages fetched from the fa_widgets catalog — which run inside the
bundled sandboxed JS interpreter with **zero chrome.\* access** (the
interpreter mediates a fixed host API; widget code cannot call extension
APIs).

- Recommended answer: **"Yes"** with justification: *"User-installed
widgets (optional, user-initiated, from a reviewed catalog) are
interpreted by a bundled sandboxed interpreter with no access to
chrome.\* APIs or extension privileges; all privileged code ships in the
package. Interpreting user-chosen content is the product's documented
feature, analogous to the userScripts surface."* Answering "No" risks a
rejection later if reviewers spot runtime-fetched widget JS.
- Fallback if review stalls: ship the store build with the widget
catalog install path disabled (remote widgets off; built-in apps stay) —
then "No" is strictly true. Owner's call.

## Data usage (public disclosures)

Check honestly — the agent transmits page/task content to the **user's
own chosen model provider** as the substance of the user's request:

- [x] **Authentication information** — user-supplied API keys, stored
  locally, sent only to their own provider endpoints.
- [x] **Personal communications** — the user's chat messages are sent to
  the user's chosen model provider to produce answers.
- [x] **Web history** — read locally on instruction; included in a
  provider request only when the user asks for it.
- [x] **Website content** — page text/screenshots are sent to the user's
  chosen provider when the user asks the agent to work with a page.
- [ ] PII / Health / Financial / Location / User activity — not
  collected (no keystroke/position logging; no analytics at all).

Certifications: all three certify TRUE (transfers happen only as the
single-purpose use case — fulfilling the user's own request through the
user's own provider; nothing is sold or used for lending/credit).

## Privacy policy URL

`https://fa1.dev/privacy.html` (live, 200). Verify it covers the
provider-relay reality above (user's content → user's chosen provider)
before submitting; extend the page if it doesn't mention the extension.
