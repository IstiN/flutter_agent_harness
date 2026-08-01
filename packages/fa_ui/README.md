# fa_ui

Reusable Flutter UI for apps embedding the Fa agent: the Fa brand theme and
the ready-made provider/model settings widgets, with host-side theme and
string customization.

## What's inside

- **Theme** — `buildFahTheme()` / `buildFahThemeLight()` (Material 3, dark +
  light), `FahPalette` / `FahLightPalette` / `FahColors.of(context)`, and the
  `flutter_chat_ui` chat themes. Wrap your app in a `FaUiThemeProvider` with
  a `FaUiTheme` (accent colors, font family, corner radii) to re-skin
  everything; `FahColors.of(context)` picks the overrides up automatically.
- **Provider settings widgets** — `ProvidersSection`, `ProviderEditorPage`,
  `DefaultChatModelSection` with its two-step picker flow,
  `MediaSlotProviderPickerPage` / `MediaSlotModelPage`,
  `ModelIdAutocompleteField`, and the `ProviderPreset` enum + helpers.
- **Stores** — `ProviderRegistry` (custom providers, session/Keychain keys,
  preset model overrides), `MediaModelsStore` (per-modality model slots),
  `SessionKeysStore` (user-saved named keys), `KeychainStore` (iOS/macOS
  Keychain channel), all persisting through the harness `ExecutionEnv`.
- **Strings** — `FaUiStrings` with English/Russian defaults resolved from
  the ambient locale; override everything with a `FaUiStringsScope`.

## Host integration points

fa_ui never depends on your agent service or on-device engines:

- The active connection is the `FaChatConnection` interface (a `Listenable`
  with `providerKind` / `activeBaseUrl` / `modelId`) — implement it over
  your service.
- Applying a model choice calls your `onApply` with a `FaChatModelConfig`;
  map it onto your own config type.
- On-device providers (WebLLM, Gemma, …) are `FaOnDeviceRoute` entries —
  you supply the picker label and the connect-page builder.
- Named API keys resolve through `FaUiHost.keyResolver` (install once at
  startup) and the nearest `SessionKeysScope`.

## Usage

```dart
MaterialApp(
  theme: FaUiThemeProvider.darkThemeOf(context),
  home: FaUiThemeProvider(
    data: const FaUiTheme(indigo: Colors.deepOrange),
    child: Scaffold(
      body: ProvidersSection(service: myConnection, registry: registry),
    ),
  ),
);
```
