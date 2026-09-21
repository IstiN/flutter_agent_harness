# LinkedIn post — 2026-09-20 — "We burned 40 billion tokens"

✅ PUBLISHED: https://www.linkedin.com/pulse/we-burned-40-billion-tokens-20k-building-harness-am-i-klyshevich-ku8of/
Canonical article: https://fa1.dev/blog/post.html?p=2026-09-20-we-burned-40-billion-tokens
Cover: posts/assets/40b-cover.png

(The text below is the pre-publish draft; the live version is on LinkedIn —
the canonical long-form now lives in posts/2026-09-20-we-burned-40-billion-tokens.md)

---

40,000,000,000 tokens. Zero lines of code written by a human. 🤯

That is the bill for building >_Fa — my open-source AI agent harness in Dart. People hear "40 billion tokens" and hear a fuckup. So let's count my money first (I know you want to):

🧮 The bill (Kimi K3, GLM-5.3, GLM-5.3-Flash, routed per task):
• Cached reads: ~24B × $0.15/1M ≈ $3,600
• Fresh input: ~14B × $0.60/1M ≈ $8,400
• Output: ~2B × $2.50/1M ≈ $5,000
• Total: ≈ $20k. A big slice burned while I slept.

For scale: the same scope quoted to a dev team is 6–12 months and $300k+. So what did $20k of tokens actually buy?

The recipe: I took the best open-source harnesses — pi, codex, kimi-code, oh-my-pi — stole the best idea from each, and merged them into one Dart core. And it all works: >_Fa builds ITSELF — my dmtools-dart factory shipped 5 releases in a single day last Saturday (v0.1.423 → v0.1.427), no human in the loop.

Timeline, for honesty: first working versions took a couple of WEEKS. Getting from "works on my machine" to 5 platforms + self-building releases + green CI took 3 MONTHS of the factory grinding. And it's open source — I'm ready to share all of it, the good commits and the embarrassing ones.

📦 Size check (macOS arm64, measured from actual npm/release artifacts):
• >_Fa: ~7 MB single binary, no runtime
• pi: ~11 MB + Node.js
• oh-my-pi: ~45 MB + Node.js
• opencode: ~138 MB (bundled Bun)
• Copilot CLI: ~143 MB (bundled Node)
• Codex CLI: ~303 MB unpacked (bundles zsh, rg, voice host…)
• DeepSeek dsh: ~282 MB node_modules + Node.js runtime

Fun fact about that last row: DeepSeek's "everything is a plugin" harness hit developer preview in August 2026. >_Fa's plugin packages, runtime widget apps (agent builds interactive UIs on the fly) and the trajectory timeline (Gantt-style replay of every run, tokens+cost per step) were running in June. Not as new as the hype cycle says — some of us just shipped it quietly, in Dart.
Same job. 40x less disk. Install takes seconds, not a Node.js ceremony.

The features:

✅ ONE harness, every device — SDK first, CLI second, apps third. Headless by default: my CI runners execute >_Fa agents on every commit and I watch them work in realtime in the Actions log. The harness reviews its own PRs.

✅ iOS & Android — shipped to the App Store. Which means: you can build your own iOS app WITHOUT publishing to the App Store. Describe it to >_Fa on your phone, it builds it inside >_Fa. Personal software, audience of one, no review process.

✅ Web — fa1.dev, bring your own key, the agent runs IN your browser tab: sandboxed shell, git, python3 & sqlite in WASM. Nothing leaves your machine.

✅ The client IS the computer — no server needed. We ported the scripting toolchain INTO the app, compiled to WASM: Python (+pip), JavaScript (QuickJS), Lua, SQLite, git, rg/sed/awk/tar/zip. "Agent, pull these 3 APIs, join the data, show me the table" — the agent writes the script and runs it right there in the sandbox, on your phone or browser tab. A harness that executes next to your data, not a chatbot that describes scripts.

✅ Chrome extension — and no, this is not Playwright. Not a script driving a browser from outside, blind to everything but hardcoded selectors. The AI lives INSIDE the browser: it sees what you see and acts with your logged-in session. You don't script it — you talk to it.

✅ Agents that talk to each other — every >_Fa agent has an inbox. Your phone agent can DM your build-server agent. Steering a running agent from another device is a text message, not an ssh session.

✅ Trajectory + runtime widgets — every run projects into an inspectable timeline (tokens & cost per step, Gantt-style), and when the agent needs to show you data it builds an interactive mini-app inside >_Fa instead of dumping a markdown table.

✅ Git-backed memory — MEMORY.md committed to the repo. Clone the repo, get its memory. A new agent starts with everything the project ever learned instead of a blank stare.

✅ Sessions as a branchable JSONL tree — fork a conversation like git. Survived a real 1.4 GB marathon session; resume takes ~1 second.

✅ Cubes out of the box — declarative YAML sandbox profiles: allowed commands, reachable hosts, touchable paths, env vars, time/disk ceilings. Dart policy engine gates every bash line (pipes and subshells included); opt-in kernel backend wraps commands in sandbox-exec (macOS) / unshare (Linux). Point an agent at a repo you don't trust — the blast radius is a file, not a promise.

And the part nobody budgets for — QUALITY:

🔬 Every feature and bugfix is tested by AGENTS, not a QA department. CRAP complexity gates on every PR (vibe-code a mess — review won't pass), main stays green all the time, store deployment pipelines (App Store, Google Play) fully automated — zero humans. At API prices that quality loop is ≈ $2,500/week. Quality control costs money — it just scales with tokens, not headcount.

Now the twist — what I ACTUALLY paid:

💸 GitHub (runners, releases, Pages): $0 — open source
💸 Kimi subscription #1: $200/mo × 3 months = $600 (≈ $10k at API prices)
💸 Kimi subscription #2: $100/mo × 3 months = $300 (≈ $5k)
💸 GLM subscription: $150/mo × 1 month = $150 (≈ $5k)
💸 Total cash: ≈ $1,050 — vs ≈ $20k list price

List price $20k. Actually paid: about a thousand dollars. The API price list is what tokens cost if you're a tourist. Subscriptions + caching + routing each task to the cheapest model that can do it — that's what tokens cost if you run a factory.

The honest math: $1,050 didn't buy code. Code is the byproduct. It bought infrastructure that works at 3am, remembers across months, and asks no permission.

🎬 Video: [YOCLIP VIDEO LINK]

Full receipt on the >_Fa blog 👇
🔗 https://fa1.dev/blog/post.html?p=2026-09-19-40-billion-tokens-later

Sessions saved. Factory running.

#AIAgents #Dart #Flutter #DevTools #BuildInPublic
