# Privacy Policy — Fa (Flutter Agent Harness)

**Effective date: October 15, 2026**

This policy covers the **Fa** applications — the mobile/desktop/web app and
the **Fa browser extension** ("fa — browser agent") — built on the
open-source Flutter Agent Harness. The short version: the products are
designed local-first — your keys, chats, and files stay on your device, and
content leaves the device only to the AI providers you explicitly connect.

This file is the repo source text; the published page is
`site/privacy.html` — keep both in sync (AGENTS.md). The `<!-- sec:<key> -->`
markers are the mechanical section anchors the compliance tests pin
(gh-1630 AC6).

## English

<!-- sec:collect -->
### 1. Data we collect

Fa has no accounts and no sign-up. Depending on how you use it, the
following data is handled by the app **on your device**:

- **Chat and conversation content** you send through fa — your prompts,
  the agent's replies, and the conversation context.
- **Provider API keys** you enter so fa can talk to your chosen AI
  provider (e.g. OpenRouter, Anthropic, or a custom endpoint).
- **Page content the agent reads** when you ask it to act on a page
  (text, screenshots, cookies needed for the flow you drive,
  history/bookmark entries you explicitly reference).
- **Local files you attach** or files the agent creates for you in its
  sandbox.
- The developer receives **none** of the above. There is no telemetry or
  analytics in the browser extension at all; in the mobile/desktop app,
  optional Firebase analytics/crash reporting is described in section 2
  and never includes message text, keys, or file contents.

<!-- sec:handle -->
### 2. How we handle data

- **On-device processing.** Prompts, tool results, and files are processed
  on your device. Nothing is proxied through the developer: fa operates no
  servers that receive your conversation content, keys, or files.
- **AI requests.** When you chat with the agent, the relevant prompt and
  context are sent — directly from your device — to the AI providers
  **you** configure (your keys, your base URLs). Those providers process
  your data under their own privacy policies.
- **Analytics (app only).** Where the platform makes it available, the
  mobile/desktop app sends Firebase Analytics events with metadata only
  (event names, provider/model identifiers, coarse buckets) and Firebase
  Crashlytics crash reports (stack traces, device model, OS version) —
  never API keys, message text, prompts, or file contents. **The browser
  extension sends no analytics and no crash reports.**
- **Website analytics.** The landing page (fa1.dev) uses Google Analytics
  4 with IP anonymization to count page views and outbound clicks. It sets
  no advertising cookies and tracks nothing inside the app you run from
  the page.

<!-- sec:storage -->
### 3. Data storage

- Everything fa keeps — chats, sessions, settings, provider keys, sandbox
  files — is stored **locally on your device or in your browser**: the
  platform Keychain / secure store for keys (app), `chrome.storage` and
  extension storage for extension state, OPFS/IndexedDB for web sandboxes
  and downloaded model caches.
- Nothing is stored cloud-side by the extension or the developer. There is
  no fa account and no fa cloud.
- On-device model files you choose to download (e.g. small LLM weights)
  are stored in your browser's storage and are never uploaded.

<!-- sec:sharing -->
### 4. Data sharing

- We do **not sell** your data, and we do not share it with third parties
  for marketing.
- The only third parties that receive your content are the **model
  providers you explicitly configure** (your requests go directly to their
  endpoints).
- **Native messaging.** When you pair the extension with a local fa CLI
  helper, the extension and that local helper exchange messages between
  themselves on your machine — this traffic does not involve the developer
  or any server.
- Optional system permissions (notifications, microphone, calendar,
  contacts, health, home) are requested only in context for features you
  invoke, and the data they touch is processed on-device only.

<!-- sec:retention -->
### 5. Retention & deletion

- Local data persists until **you** delete it: clear a chat/session inside
  the app, clear the extension's data via browser settings, or uninstall —
  uninstalling the app or extension removes its locally stored data.
- Downloaded model weights and web-sandbox files live in your browser
  storage and can be cleared the same way (site data / extension data).
- Firebase analytics/crash data (app only), where enabled, is retained per
  Google's standard Firebase retention and contains no message content.

<!-- sec:security -->
### 6. Security

- **Keys.** Provider API keys are stored in the platform Keychain
  (iOS/macOS) or the local secure store / browser storage of the app
  sandbox, and are transmitted only to the provider they belong to.
- **Redaction.** A layered secret-redaction pipeline masks credentials and
  token-shaped strings in logs, session files, and tool output before they
  are persisted, so secrets do not leak into recorded sessions.
- **Approvals.** Sensitive agent actions (running commands, opening pages,
  sending data out of the browser) pass an approval gate you control, from
  ask-per-action to fully unattended modes.
- The extension loads all interpreter/LLM engine code **from inside the
  package** (no remotely hosted code), and its permissions are limited to
  what its features call.

<!-- sec:children -->
### 7. Children's privacy

The app and the extension are not directed at children under 13 (or the
equivalent minimum age in your jurisdiction), and we do not knowingly
collect personal data from them.

<!-- sec:changes -->
### 8. Changes to this policy

Changes are posted at this URL with a new effective date.

- **October 15, 2026** — restructured into the nine Chrome Web Store
  mandatory sections; added the browser extension (local engine code,
  native messaging, no telemetry).
- **July 29, 2026** — first published version.

<!-- sec:contact -->
### 9. Contact

Questions, requests, or reports: open an issue at
[github.com/IstiN/flutter_agent_harness/issues](https://github.com/IstiN/flutter_agent_harness/issues).

---

## Русский

*Дата вступления в силу: 15 октября 2026 г.*

Эта политика распространяется на приложения **Fa** — мобильное
/desktop/web-приложение и **расширение для браузера** («fa — browser
agent»), построенные на открытом Flutter Agent Harness. Коротко: продукты
спроектированы local-first — ключи, чаты и файлы остаются на вашем
устройстве, а наружу уходит только то, что вы сами отправляете выбранным
AI-провайдерам.

<!-- sec:collect -->
### 1. Какие данные мы обрабатываем

В fa нет аккаунтов и регистрации. В зависимости от использования приложение
обрабатывает **на вашем устройстве**:

- **Содержимое чатов**, которое вы отправляете через fa: ваши запросы,
  ответы агента и контекст диалога.
- **API-ключи провайдеров**, которые вы вводите, чтобы fa мог обращаться к
  выбранному AI-провайдеру (например OpenRouter, Anthropic или собственный
  endpoint).
- **Содержимое страниц, которое агент читает** по вашей просьбе (текст,
  скриншоты, cookies, нужные для управляемого вами сценария, записи
  истории/закладок, на которые вы явно ссылаетесь).
- **Локальные файлы**, которые вы прикладываете, или файлы, которые агент
  создаёт для вас в песочнице.
- Разработчик **не получает** ничего из перечисленного. В расширении нет
  ни телеметрии, ни аналитики вовсе; в мобильном/desktop-приложении
  опциональные Firebase-аналитика и отчёты о сбоях описаны в разделе 2 и
  никогда не содержат текстов сообщений, ключей или содержимого файлов.

<!-- sec:handle -->
### 2. Как мы обрабатываем данные

- **Обработка на устройстве.** Запросы, результаты инструментов и файлы
  обрабатываются на вашем устройстве. Ничего не проксируется через
  разработчика: у fa нет серверов, получающих содержимое ваших диалогов,
  ключи или файлы.
- **Запросы к AI.** Когда вы общаетесь с агентом, соответствующий запрос и
  контекст отправляются — напрямую с вашего устройства — тем
  AI-провайдерам, которых **вы** настроили (ваши ключи, ваши base URL).
  Эти провайдеры обрабатывают данные по своим политикам
  конфиденциальности.
- **Аналитика (только приложение).** Если доступна на платформе,
  мобильное/desktop-приложение отправляет события Firebase Analytics
  только с метаданными (имена событий, идентификаторы провайдера/модели,
  грубые диапазоны) и отчёты о сбоях Firebase Crashlytics (стек-трейсы,
  модель устройства, версия ОС) — никогда API-ключи, тексты сообщений,
  промпты или содержимое файлов. **Расширение не отправляет ни аналитику,
  ни отчёты о сбоях.**
- **Аналитика сайта.** Лендинг (fa1.dev) использует Google Analytics 4 с
  анонимизацией IP для подсчёта просмотров и исходящих кликов. Рекламные
  cookies не используются, а приложение, которое вы запускаете со страницы,
  не отслеживается.

<!-- sec:storage -->
### 3. Хранение данных

- Всё, что хранит fa, — чаты, сессии, настройки, ключи, файлы песочницы —
  хранится **локально на устройстве или в браузере**: Keychain платформы /
  защищённое хранилище для ключей (приложение), `chrome.storage` и
  хранилище расширения для его состояния, OPFS/IndexedDB для веб-песочниц
  и скачанных моделей.
- Ничего не хранится в облаке ни расширением, ни разработчиком. Нет
  аккаунта fa и облачной службы fa.
- Скачанные вами файлы моделей (например веса небольших LLM) хранятся в
  хранилище браузера и никуда не загружаются.

<!-- sec:sharing -->
### 4. Передача данных третьим лицам

- Мы **не продаём** ваши данные и не передаём их третьим лицам в
  маркетинговых целях.
- Единственные третьи лица, получающие ваш контекст, — **модели-провайдеры,
  которых вы явно настроили** (запросы уходят напрямую на их endpoint'ы).
- **Native messaging.** При сопряжении расширения с локальным помощником
  fa CLI расширение и этот помощник обмениваются сообщениями между собой
  на вашей машине — разработчик и какие-либо серверы в этом обмене не
  участвуют.
- Опциональные системные разрешения (уведомления, микрофон, календарь,
  контакты, здоровье, дом) запрашиваются только в контексте вызываемых
  вами функций, а данные, к которым они дают доступ, обрабатываются только
  на устройстве.

<!-- sec:retention -->
### 5. Срок хранения и удаление

- Локальные данные хранятся, пока **вы** их не удалите: очистите
  чат/сессию в приложении, данные расширения через настройки браузера или
  удалите его — удаление приложения или расширения удаляет и его локальные
  данные.
- Скачанные модели и файлы веб-песочниц живут в хранилище браузера и
  очищаются там же (данные сайта / данные расширения).
- Данные Firebase-аналитики/сбоев (только приложение), если включены,
  хранятся по стандартным срокам Firebase и не содержат текстов сообщений.

<!-- sec:security -->
### 6. Безопасность

- **Ключи.** API-ключи провайдеров хранятся в Keychain платформы
  (iOS/macOS) или в локальном защищённом хранилище / хранилище браузера
  песочницы приложения и передаются только тому провайдеру, которому
  принадлежат.
- **Редактирование секретов.** Многослойный конвейер маскирует учётные
  данные и похожие на токены строки в логах, файлах сессий и выводе
  инструментов до записи на диск, чтобы секреты не попадали в сохранённые
  сессии.
- **Подтверждения.** Чувствительные действия агента (запуск команд,
  открытие страниц, вывод данных из браузера) проходят настраиваемый вами
  шлюз подтверждений — от запроса на каждое действие до полностью
  автономных режимов.
- Расширение загружает весь код интерпретаторов и LLM-движков **из самого
  пакета** (без удалённо размещаемого кода), а его разрешения ограничены
  тем, что реально вызывают его функции.

<!-- sec:children -->
### 7. Конфиденциальность детей

Приложение и расширение не предназначены для детей младше 13 лет (или
эквивалентного минимального возраста в вашей юрисдикции), и мы не собираем
их персональные данные осознанно.

<!-- sec:changes -->
### 8. Изменения этой политики

Изменения публикуются по этому адресу с новой датой вступления в силу.

- **15 октября 2026 г.** — структура приведена к девяти обязательным
  разделам Chrome Web Store; добавлено расширение для браузера (локальный
  код движков, native messaging, отсутствие телеметрии).
- **29 июля 2026 г.** — первая опубликованная версия.

<!-- sec:contact -->
### 9. Контакты

Вопросы, запросы и сообщения о проблемах — через issues:
[github.com/IstiN/flutter_agent_harness/issues](https://github.com/IstiN/flutter_agent_harness/issues).
