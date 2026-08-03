# Privacy Policy — Fa (Flutter Agent Harness)

**Effective date: July 29, 2026**

This policy covers the **Fa** mobile/desktop/web application ("the app"),
built on the open-source Flutter Agent Harness. The short version: the app
is designed local-first — your keys, chats, and files stay on your device,
and content leaves the device only to the AI providers you explicitly
connect.

## English

### 1. What stays on your device

- **API keys and secrets** are stored in the platform Keychain (iOS/macOS)
  or the local secure store of the app sandbox. They are never transmitted
  anywhere except directly to the provider they belong to.
- **Chats, sessions, settings, and files** (including files the agent
  creates for you) are stored locally on your device.
- **Calendar, contacts, health, and smart-home data** is read (and written)
  on-device only, for the features you invoke. It is never uploaded.

### 2. What leaves your device, and where

- **AI requests.** When you chat with the agent or generate media
  (images, music, video), the relevant prompts and conversation context are
  sent — directly from your device — to the AI providers **you** configure
  (for example OpenRouter, or a custom endpoint you enter). Those
  providers process your data under their own privacy policies. The app
  has no server of its own and proxies nothing.
- **Analytics.** If available on your platform, the app sends Firebase
  Analytics events containing metadata only: event names (e.g. "app
  started", "message sent"), provider/model identifiers, and coarse
  buckets (message-length ranges, counts). Analytics **never** includes
  API keys, message text, prompts, file contents, or paths.
- **Website analytics.** The landing page (fa1.dev) uses Google Analytics
  4 with IP anonymization to count page views and outbound clicks (for
  example the TestFlight and web-demo links). It sets no advertising
  cookies and tracks nothing inside the app you run from the page.
- **Crash reports.** If available on your platform, the app sends crash
  reports (stack traces, device model, OS version) via Firebase
  Crashlytics so we can fix bugs. Reports contain no message text, API
  keys, or file contents.

### 3. Permissions

All system permissions are **optional** and requested only in context, when
a feature needs them: notifications (reminders and agent alerts),
microphone (voice input), calendar (event planning), contacts (call/text
actions), health (activity summaries), and home (smart-home control). The
core app works without any of them, and you can revoke them anytime in
your device's Settings.

### 4. No accounts, no ads, no sale of data

The app requires no account, shows no ads, and does not sell, rent, or
share your personal data with third parties for their marketing. There is
no tracking beyond the analytics described above.

### 5. Children's privacy

The app is not directed at children under 13 and does not knowingly
collect personal data from them.

### 6. Changes and contact

Changes to this policy are posted at this URL. Questions: open an issue at
<https://github.com/IstiN/flutter_agent_harness/issues>.

---

## Русский

**Дата вступления в силу: 29 июля 2026 г.**

Эта политика распространяется на приложение **Fa** (мобильное, desktop и
web), построенное на открытом Flutter Agent Harness. Коротко: приложение
спроектировано local-first — ключи, чаты и файлы остаются на устройстве,
а наружу уходит только то, что вы сами отправляете выбранным AI-провайдерам.

### 1. Что остаётся на устройстве

- **API-ключи и секреты** хранятся в Keychain платформы (iOS/macOS) или в
  локальном защищённом хранилище приложения. Они никуда не передаются,
  кроме как напрямую тому провайдеру, которому принадлежат.
- **Чаты, сессии, настройки и файлы** (включая файлы, которые агент
  создаёт для вас) хранятся локально на устройстве.
- **Календарь, контакты, здоровье и умный дом** читаются (и изменяются)
  только на устройстве и только для функций, которые вы вызываете. Эти
  данные никогда не загружаются.

### 2. Что покидает устройство и куда

- **Запросы к AI.** Когда вы общаетесь с агентом или генерируете медиа
  (изображения, музыку, видео), соответствующие промпты и контекст диалога
  отправляются — напрямую с устройства — тем AI-провайдерам, которых **вы**
  настроили (например OpenRouter или собственный endpoint). Эти провайдеры
  обрабатывают данные по своим политикам конфиденциальности. У приложения
  нет собственного сервера, и оно ничего не проксирует.
- **Аналитика.** Если доступна на вашей платформе, приложение отправляет
  события Firebase Analytics только с метаданными: имена событий (например
  «приложение запущено», «сообщение отправлено»), идентификаторы
  провайдера/модели и грубые диапазоны (длина сообщения, счётчики).
  Аналитика **никогда** не включает API-ключи, тексты сообщений, промпты,
  содержимое файлов или пути.
- **Аналитика сайта.** Лендинг (fa1.dev) использует Google Analytics 4 с
  анонимизацией IP для подсчёта просмотров страницы и исходящих кликов
  (например по ссылкам TestFlight и веб-демо). Рекламные cookies не
  используются, а приложение, которое вы запускаете со страницы, не
  отслеживается.
- **Отчёты о сбоях.** Если доступно на вашей платформе, приложение
  отправляет отчёты о сбоях (стек-трейсы, модель устройства, версия ОС)
  через Firebase Crashlytics, чтобы мы могли чинить ошибки. Отчёты не
  содержат текстов сообщений, API-ключей или содержимого файлов.

### 3. Разрешения

Все системные разрешения **опциональны** и запрашиваются только в
контексте, когда функции они нужны: уведомления (напоминания и алерты
агента), микрофон (голосовой ввод), календарь (планирование событий),
контакты (звонки/сообщения), здоровье (сводки активности) и дом
(умный дом). Приложение полностью работает и без них, а отозвать их можно
в любой момент в настройках устройства.

### 4. Без аккаунтов, рекламы и продажи данных

Приложение не требует аккаунта, не показывает рекламу и не продаёт, не
сдаёт в аренду и не передаёт ваши персональные данные третьим лицам для
их маркетинга. Никакого трекинга, кроме описанной выше аналитики, нет.

### 5. Конфиденциальность детей

Приложение не предназначено для детей младше 13 лет и не собирает
осознанно их персональные данные.

### 6. Изменения и контакты

Изменения политики публикуются по этому же адресу. Вопросы — через issues:
<https://github.com/IstiN/flutter_agent_harness/issues>.
