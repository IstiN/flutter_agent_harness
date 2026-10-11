# Chrome Web Store listing — fa — browser agent

Machine-consumable copy for the CWS listing (uploaded manually first,
CI/CD later — see below). Field limits are from the CWS developer
dashboard (2026-10).

## Package identity

- Title (from manifest): `fa — browser agent`
- Summary (from manifest): `fa — your agent in this browser: the full fa app in the side panel, page powers for the agent.`
- Store item ID: `ojifmmomfgobjnamkpgmihbhlfiijdak` (draft)

## Metadata

- Category: **Productivity**
- Language: **English** (primary; add Russian localization as a follow-up
  via `_locales`)
- Official URL: `https://fa1.dev` (verify ownership via Google Search
  Console to link)
- Homepage URL: `https://fa1.dev`
- Support URL: `https://github.com/IstiN/flutter_agent_harness/issues`
- Mature content: **No**
- Promo video: none (optional)

## Graphic assets (this directory)

| Asset | File | CWS spec |
|---|---|---|
| Store icon | `icon-128.png` | 128×128 PNG |
| Screenshot 1 — Chat | `screenshot-1-chat.png` | 1280×800, 24-bit PNG |
| Screenshot 2 — Apps | `screenshot-2-apps.png` | 1280×800 |
| Screenshot 3 — Media | `screenshot-3-media.png` | 1280×800 |
| Screenshot 4 — Providers | `screenshot-4-providers.png` | 1280×800 |
| Screenshot 5 — In-app web | `screenshot-5-inapp.png` | 1280×800 |
| Small promo tile | `promo-small-440x280.png` | 440×280, 24-bit PNG |
| Marquee promo tile | `promo-marquee-1400x560.png` | 1400×560, 24-bit PNG |

Screenshots are the product's own App Store goldens
(`flutter_app/test/goldens/store/en/mac/*.png`, committed and
golden-tested) downscaled to the exact CWS frame — the extension's side
panel runs the same fa app UI, so they are representative. Replaced by
real Chrome side-panel captures whenever the store team wants
browser-chrome framing (the golden source of truth stays in the repo).

## Description (EN, ≤16000 chars)

```
fa puts your AI agent right inside the browser.

The full fa app lives in Chrome's side panel: chat with frontier and
local models, run multi-step tasks, and let the agent work with the
pages you are on — reading page content, automating forms, watching
tabs, and driving the browser with your permission, all from one panel.

What you get:

• The complete fa experience in the side panel — sessions, apps,
  widgets, memory, and settings stay in sync with your fa setup.
• Page powers for the agent: read and interact with the current page,
  manage tabs, capture screenshots, and automate repetitive browser
  work — always under your control, with explicit permissions.
• Your models, your keys: bring your own provider (OpenAI, Anthropic,
  Google, OpenRouter, and more) or run on-device models locally.
  Keys stay on your machine.
• Privacy by design: the agent acts only where you allow it, every
  sensitive action is gated, and nothing leaves your browser without
  your say.

fa is open source: https://github.com/IstiN/flutter_agent_harness
```

## Description (RU, for the future _locales pass)

```
fa — ваш AI-агент прямо в браузере.

Полное приложение fa живёт в боковой панели Chrome: чат с фронтирными и
локальными моделями, многошаговые задачи, работа с открытыми страницами —
чтение контента, автоматизация форм, наблюдение за вкладками — всё с
вашего явного разрешения.

• Полный fa в боковой панели: сессии, приложения, виджеты, память и
  настройки синхронны с вашей установкой fa.
• Возможности страниц для агента: чтение и взаимодействие с текущей
  страницей, управление вкладками, скриншоты, автоматизация рутины.
• Ваши модели, ваши ключи: OpenAI, Anthropic, Google, OpenRouter и
  другие — или локальные on-device модели. Ключи не покидают машину.
• Приватность по дизайну: агент действует только там, где вы разрешили.

fa — open source: https://github.com/IstiN/flutter_agent_harness
```

## CI/CD note (next step)

The manual flow this pack serves becomes a `publish-extension.yml`
workflow later: package via `scripts/build_browser_ext.sh` (already
CWS-strict post #1549), assert `browser_ext/store/` completeness in the
same guard, upload via the Chrome Web Store publish API (OAuth refresh
token in `CWS_*` secrets). Track under the store-automation card.
