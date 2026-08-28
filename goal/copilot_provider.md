# Goal: Copilot provider — GitHub Copilot как ещё один тип провайдера fa

Status: идея + research done, имплементация не начата
Source: <https://github.com/tonghaoch/copilot-proxy-go> (Go, MIT)
Дом протокола: `packages/fa_llm` (pure Dart) + интеграции в harness (`fa` CLI) и
`fa_ui`/`flutter_app`.
Ниже все URL/headers/семантика выписаны из исходников прокси (пути к файлам
указаны), чтобы имплементация не требовала повторного реверса.

## Идея одной строкой

Мигрировать знания протокола из `copilot-proxy-go` в `fa_llm` и добавить
`copilot` как first-class тип провайдера — доступный и Flutter-приложениям
(через `fa_llm`), и `fa` CLI (через provider catalog harness'а), с явной
поддержкой планов **individual / business / enterprise**.

## Что такое copilot-proxy-go и что мы берём

Локальный Go-прокси, который превращает подписку GitHub Copilot в
OpenAI/Anthropic/Responses-совместимые endpoints (`localhost:4141`) для
сторонних CLI (Claude Code, Codex CLI, Cursor). Он нужен сторонним клиентам,
потому что те умеют только свой API.

**Берём (это и есть «миграция»):**

- OAuth device-code flow аутентификации в GitHub;
- обмен GitHub-токена на короткоживущий Copilot API токен (тот самый
  «internal api») и его авто-refresh;
- таблицу базовых URL по типу аккаунта (individual/business/enterprise);
- обязательные заголовки Copilot API;
- семантику retry/refresh (401/403 → refresh → повтор; Retry-After);
- разбор ответа `GET /models` (capabilities, limits, supported endpoints).

**НЕ берём (в fa это уже есть или не нужно):**

- локальный HTTP-сервер-прокси — fa ходит в Copilot напрямую как провайдер;
- трансляцию API↔API (Anthropic Messages ↔ Chat Completions ↔ Responses):
  у harness уже есть нативные адаптеры `openai-completions` и `anthropic`
  (`lib/src/providers/`), Copilot сам отдаёт оба wire-формата;
- dashboard, usage-статистику, TUI выбора моделей, quota-routing;
- скрейп версии VS Code из AUR (прокси делает это для заголовка
  `Editor-Version` — мы просто пиним константу);
- embeddings (опционально, позже, если понадобится).

## Проверенные факты о Copilot API (из исходников прокси)

### Auth-цепочка

1. **GitHub OAuth device flow** (`internal/auth/device_flow.go`):
   - `POST https://github.com/login/device/code`
     с `client_id=Iv1.b507a08c87ecfe98`, `scope=read:user`
     → `{device_code, user_code, verification_uri, expires_in, interval}`;
   - poll `POST https://github.com/login/oauth/access_token`
     с `grant_type=urn:ietf:params:oauth:grant-type:device_code`;
     обрабатывать `authorization_pending` (ждать), `slow_down` (+5с к
     интервалу), `expired_token`, `access_denied`.
   - `Iv1.b507a08c87ecfe98` — публичный client id плагина VS Code Copilot Chat
     (`internal/api/config.go`). Даём возможность переопределить в конфиге.
2. **Обмен на Copilot токен** (`internal/auth/github_client.go: FetchCopilotToken`)
   — вот этот «internal api used», который виден в endpoint'ах прокси:
   - `GET https://api.github.com/copilot_internal/v2/token`
     с заголовком `Authorization: token <githubToken>` (+ editor-заголовки);
   - ответ: `{token, expires_at (unix), refresh_in (сек)}`;
   - токен короткоживущий (~30 мин); обновлять за ~2 мин до `expires_at`
     (или через `refresh_in`), но не чаще раза в 30с; при 401/403 от API —
     немедленный refresh и один повтор запроса.
3. (Опционально) `GET https://api.github.com/user` → `login` для показа
   имени аккаунта в UI.

Важно: **этот exchange endpoint один и тот же для всех типов аккаунта** —
тип аккаунта влияет только на базовый URL Copilot API (см. ниже).

### Базовые адреса Copilot API по типу аккаунта — ответ про Business

`internal/api/config.go: GetBaseURL(accountType)`:

| accountType | Base URL |
| --- | --- |
| `individual` (default) | `https://api.githubcopilot.com` |
| `business` | `https://api.business.githubcopilot.com` |
| `enterprise` | `https://api.enterprise.githubcopilot.com` |

То есть точный адрес для Business **известен и уже поддержан в прокси** —
мигрируем маппинг как есть. Требование к имплементации: помимо трёх
именованных планов хранить **явный `baseUrl` override** в конфиге, чтобы
любой новый/корпоративный адрес работал без правки кода (тот же подход, что
у openai-completions для OpenRouter).

### Заголовки запросов к Copilot API

`internal/api/config.go: BuildCopilotHeaders`:

```
Authorization: Bearer <copilotToken>
Content-Type: application/json
Copilot-Integration-Id: vscode-chat
Editor-Version: vscode/1.109.3          (пиним константу)
Editor-Plugin-Version: copilot-chat/0.37.6
User-Agent: GitHubCopilotChat/0.37.6
Openai-Intent: conversation-agent
X-Github-Api-Version: 2025-10-01
X-Request-Id: <uuid на каждый запрос>
X-Vscode-User-Agent-Library-Version: electron-fetch
```

Плюс per-request (`internal/service/copilot.go: requestHeaders`):

- `X-Initiator: user|agent` — агентный запрос, если последнее сообщение
  `assistant`/`tool`;
- `Copilot-Vision-Request: true` — для image-входа;
- `Anthropic-Beta: <...>` — только для нативного `/v1/messages`.

### Retry-семантика (`internal/service/copilot.go`)

- 401/403 → refresh токена → ровно один повтор;
- retry для 429/502/503/504: `Retry-After` уважается, ожидание ограничено
  окном (~10с у прокси), иначе ошибку отдаём наверх; backoff 200ms × attempt,
  max 3 попытки;
- сетевые ошибки — retry с тем же backoff, отмена контекста — не retry.

(В harness это ложится на существующие `retry:`/watchdog-механизмы
`model_roles`; в `fa_llm` — простая политика на инъектном http-клиенте.)

### `GET /models`

Возвращает `{data: [...]}`, где у модели есть `id`,
`capabilities.limits.max_context_window_tokens` /
`max_output_tokens` и `supported_endpoints` (перечисляет `/responses` и
пр.) — источник правды про доступные модели и их лимиты. Никаких
захардкоженных списков моделей не заводим; `/models` — единственный
источник. Наличие `/responses` в `supported_endpoints` = модель умеет
Responses API; Claude-модели имеют нативный `/v1/messages`.

### Wire endpoints Copilot API

| Путь | Формат | Кто в fa его закрывает |
| --- | --- | --- |
| `POST /chat/completions` | OpenAI Chat Completions (SSE) | адаптер `openai-completions` |
| `POST /responses` | OpenAI Responses API | опыт из `chatgpt_codex.dart` (позже) |
| `POST /v1/messages` | Anthropic Messages (SSE) | адаптер `anthropic` |
| `GET /models` | модели | `_fetchProviderModelIds` / `fa_llm.listModels` |

## Целевая архитектура

### 1. `packages/fa_llm` — протокольное ядро (source of truth)

Pure Dart (deps только `http` + `meta`, без `dart:io`/Flutter), новые файлы:

- `copilot_endpoints.dart` — `enum CopilotAccountType {individual, business,
  enterprise}` + `baseUrlFor(accountType)` + произвольный override;
- `copilot_token.dart` — device flow (`requestDeviceCode`, `pollAccessToken`),
  `fetchCopilotToken`, `CopilotToken {token, expiresAt, refreshIn}`;
- `copilot_token_manager.dart` — кэш + проактивный refresh (за 2 мин до
  expiry, мин. интервал 30с, лок от параллельных refresh) + refresh по 401;
  инъектные clock/httpClient;
- `copilot_token_store.dart` — интерфейс persist'а GitHub-токена
  (платформенные impl снаружи: IO → `SecureKeyStore`, Flutter app → его
  secure storage; fa_llm остаётся чистым);
- `copilot_provider.dart` — `LlmProvider` над `/chat/completions`
  (streaming SSE, стрим + complete), список моделей `listModels()`;
- `ProviderFactory`: `providerName: 'copilot'` (+ `accountType`, `baseUrl`).

TDD через `http.testing`-mock, реальные вызовы — только в интеграционных
тестах с тегом `integration`.

### 2. Harness (`fa` CLI) — провайдер в каталоге

- `lib/src/model_roles/provider_catalog.dart`: spec `copilot`
  (`kind: 'copilot'`, `api: 'openai-completions'`, vision on);
  прецедент нестандартного auth — `chatgpt-codex`;
- `lib/src/providers/copilot.dart` — stream function: openai-completions
  против выбранного base URL + Bearer из `CopilotTokenManager` (refresh на
  401/403 до обычного retry);
- CLI-флоу `/provider copilot` в духе `/provider chatgpt oauth`: device-code
  (показать `verification_uri` + `user_code`, поллинг; headless-friendly —
  callback-сервер не нужен), шаг выбора `accountType`
  (individual/business/enterprise/custom baseUrl), сохранение GitHub-токена в
  secure store, регистрация entry в `customProviders`/config;
- `/models` — ветка copilot в per-dialect dispatch (`_fetchProviderModelIds`).

### 3. Flutter app (`fa_ui` / `flutter_app`)

- маппинг copilot-конфига в `fa_llm`-провайдер
  (`fa_ui/lib/src/providers/llm_config_mapping.dart`);
- настройки провайдера: тот же device-code flow в шите + выбор плана,
  токен — в secure storage приложения;
- провайдер доступен и обычному чату приложения, и агентному режиму.

## Фазы

### Phase 0 — верификация Business/Enterprise (риск-съём)

Ручной smoke: device flow → exchange → `GET /models` и один
`/chat/completions` против каждого base URL. Цель: подтвердить, что
exchange-эндпоинт и токен работают одинаково для individual и business
(по коду прокси — да, но живого Business-аккаунта у нас не было).
Скрипт/интеграционный тест с тегом `integration`.

**Критерий:** зафиксированы рабочие запросы (или конкретное отличие) для
individual и business; enterprise — проверяется по аналогии при наличии
аккаунта.

### Phase 1 — `fa_llm`: протокольное ядро

Endpoints, token manager, token store interface, provider, factory-ветка,
`listModels`. Mock-тесты на device flow (pending/slow_down/expired/denied),
refresh (proactive + по 401), SSE-стрим.

**Критерий:** `CopilotProvider` проходит тесты; `dart analyze` чист;
покрытие новых файлов ≥ 90%; pure-Dart не нарушен.

### Phase 2 — harness + `fa` CLI

Catalog spec, stream function, `/provider copilot` (auth + план + baseUrl),
`/models` dispatch, конфиг-схема (`roles:`/`customProviders` примеры),
`--help`/docs.

**Критерий:** `fa --provider copilot "..."` отвечает стримом; смена плана —
без правки кода; 401 посреди стрима восстанавливается refresh'ем.

### Phase 3 — Flutter app

`fa_ui`-маппинг + настройки + secure storage; агентный режим использует того
же провайдера.

**Критерий:** в приложении можно подключить Copilot (любой план) и(chat +
агент) работают; токен переживает рестарт.

## Риски / открытые вопросы

1. **`/copilot_internal/v2/token` — недокументированный GitHub API.**
   Может измениться без предупреждения. Митигация: URL endpoint'а и
   `client_id` переопределяемы в конфиге; понятная ошибка при 401 от exchange.
2. **ToS GitHub.** client id и заголовки маскируют нас под VS Code Copilot
   Chat — так делает весь класс copilot-прокси, но формально это не
   публичный API. Пользователь должен осознавать риск блокировки аккаунта.
   В upstream прокси — MIT; порт логики с указанием source-файлов в
   комментариях, копирования кода нет.
3. **Business-специфика**: возможные org-политики (content exclusion,
   запрет моделей и т.п.) всплывут как отличия в `/models`/ошибках —
   покрывается Phase 0; адресная книга уже верна.
4. **Квоты premium requests** — 429 с `Retry-After` должен дойти до
   пользователя человекочитаемо (в harness уже есть похожий hint для
   usage-limit ошибок).
5. **Короткая жизнь токена** — обязателен и проактивный refresh, и
   refresh-on-401; параллельные refresh'и под локом.

## Открытые решения (решить на старте имплементации)

- Зависит ли harness от `fa_llm` (path-dep) с общим token manager, или
  протокол дублируется в `lib/src/providers/copilot.dart`? Рекомендация:
  один источник — path-dep на `packages/fa_llm`.
- Первый wire-формат: `/chat/completions` (Phase 1–2), нативный
  `/v1/messages` для Claude-моделей и `/responses` — следующими шагами.
- Хранение GitHub-токена в harness: отдельное имя в secure store
  (в духе `FA_KEY_GITHUB`) vs entry в `customProviders`.
