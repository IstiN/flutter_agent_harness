// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/widgets.dart';

/// The UI strings of every fa_ui widget.
///
/// The package ships English ([FaUiStringsEn]) and Russian ([FaUiStringsRu])
/// defaults, resolved from the ambient locale by [FaUiStrings.of]; a host
/// app overrides them (full rebrand, more locales) by wrapping its tree in a
/// [FaUiStringsScope] with its own [FaUiStrings] implementation.
abstract class FaUiStrings {
  /// Creates strings.
  const FaUiStrings();

  /// Resolves the strings for [context]: the nearest [FaUiStringsScope]
  /// when one is installed, otherwise the built-in defaults for the ambient
  /// locale (English outside a `Localizations` subtree).
  static FaUiStrings of(BuildContext context) {
    final scoped = context
        .dependOnInheritedWidgetOfExactType<FaUiStringsScope>()
        ?.strings;
    if (scoped != null) return scoped;
    final locale = Localizations.maybeLocaleOf(context);
    return forLocale(locale ?? const Locale('en'));
  }

  /// The built-in defaults for [locale] (Russian or English).
  static FaUiStrings forLocale(Locale locale) => locale.languageCode == 'ru'
      ? const FaUiStringsRu()
      : const FaUiStringsEn();

  /// Settings section title above the provider list.
  String get settingsProvidersSectionTitle;

  /// Settings section title above the on-device/local provider list.
  String get settingsLocalProvidersSectionTitle;

  /// The "Add provider" row/button label.
  String get settingsAddProvider;

  /// App bar title of the provider editor in edit mode.
  String get settingsEditProviderTitle;

  /// Settings section title of the default-chat-model row.
  String get settingsDefaultChatModelTitle;

  /// App bar title of the provider picker step.
  String get settingsPickProviderTitle;

  /// App bar title of the model picker step.
  String get settingsPickModelTitle;

  /// The Apply button (default-chat-model flow).
  String get settingsApplyButton;

  /// The Save button.
  String get settingsSaveButton;

  /// The Cancel button.
  String get settingsCancelButton;

  /// The Delete button.
  String get settingsDeleteButton;

  /// Validation error: the name field is empty.
  String get settingsNameRequired;

  /// Validation error: the base URL field is empty.
  String get settingsBaseUrlRequired;

  /// Validation error: the model id field is empty.
  String get settingsModelIdRequired;

  /// Validation error: the API key field is empty.
  String get settingsApiKeyRequired;

  /// Label of the provider name field.
  String get settingsProviderNameLabel;

  /// Hint of the provider name field.
  String get settingsProviderNameHint;

  /// Label of the base URL field.
  String get settingsBaseUrlLabel;

  /// Helper under the base URL field.
  String get settingsBaseUrlHelper;

  /// Label of the model id field.
  String get settingsModelIdLabel;

  /// Label of the optional model id field (provider editor).
  String get settingsModelIdOptionalLabel;

  /// Label of the optional API key field.
  String get settingsApiKeyOptionalLabel;

  /// Helper noting an empty key field keeps the saved key.
  String get settingsEditorKeepKeyNote;

  /// Helper noting the key is optional for local servers.
  String get settingsApiKeyLocalHelper;

  /// Key-storage note for hosted providers (in-memory wording).
  String get settingsKeyNoteHosted;

  /// Key-storage note for hosted providers (secure-storage wording).
  String get settingsKeyNoteHostedSecure;

  /// Key-storage note of the provider editor (in-memory wording).
  String get settingsEditorKeyNote;

  /// Key-storage note of the provider editor (secure-storage wording).
  String get settingsEditorKeyNoteSecure;

  /// CORS note of the Ollama Cloud preset.
  String get settingsCorsNoteOllama;

  /// CORS note of a custom endpoint.
  String get settingsCorsNoteCustom;

  /// Label of the OpenRouter preset.
  String get settingsPresetOpenrouter;

  /// Label of the "Authorize with OpenRouter" OAuth button.
  String get settingsOpenRouterOAuthButton;

  /// Title of the OpenRouter OAuth code-paste bottom sheet.
  String get settingsOpenRouterOAuthSheetTitle;

  /// Body text of the OpenRouter OAuth code-paste bottom sheet.
  String get settingsOpenRouterOAuthSheetBody;

  /// Label of the authorization-code field.
  String get settingsOpenRouterOAuthCodeLabel;

  /// Label of the confirm button on the OAuth code-paste sheet.
  String get settingsOpenRouterOAuthConfirmButton;

  /// Error message when OAuth code exchange fails; [message] is the backend
  /// or network error text.
  String settingsOpenRouterOAuthError(String message);

  /// Label of the Ollama Cloud preset.
  String get settingsPresetOllama;

  /// Label of the Google Gemini preset.
  String get settingsPresetGemini;
  String get settingsPresetDial;

  /// Label of the ad-hoc custom preset.
  String get settingsPresetCustom;

  /// Label of the on-device WebLLM preset.
  String get settingsPresetWebllm;

  /// Label of the on-device Gemma preset.
  String get settingsPresetGemma;

  /// Label of the on-device transformers.js preset.
  String get settingsPresetTransformersJs;

  /// Helper shown while the `/models` fetch is in flight.
  String get settingsModelsFetching;

  /// The "Same as main connection" media slot row.
  String get mediaModelsMainConnection;

  /// Note above the capability hint chips.
  String get mediaModelsCapabilitiesNote;

  /// Label of the TTS voice field (audioTts slot editor).
  String get mediaModelsVoiceLabel;

  /// Hint of the TTS voice field (audioTts slot editor).
  String get mediaModelsVoiceHint;

  /// Label of the image-generation media slot.
  String get mediaModelsSlotImageGeneration;

  /// Label of the text-to-speech media slot.
  String get mediaModelsSlotAudioTts;

  /// Label of the music-generation media slot.
  String get mediaModelsSlotMusicGeneration;

  /// Label of the video-generation media slot.
  String get mediaModelsSlotVideoGeneration;

  /// Label of the vision media slot.
  String get mediaModelsSlotVision;

  /// Label of the transcription media slot.
  String get mediaModelsSlotTranscription;

  /// Settings section title above the media slot list.
  String get mediaModelsSectionTitle;

  /// Note under the media models section title.
  String get mediaModelsSectionNote;

  /// The row summary of a slot without an override.
  String get mediaModelsFallbackSummary;

  /// Title of the provider-delete confirmation dialog (`Delete {name}?`).
  String settingsDeleteProviderTitle(String name);

  /// Body of the provider-delete confirmation dialog.
  String get settingsDeleteProviderBody;

  /// The active-connection summary (`{model} · {provider}`).
  String settingsProviderModelSummary(String model, String provider);

  /// The endpoint summary of a provider/media-slot row
  /// (`{modelId} · {host}`).
  String mediaModelsOverrideSummary(String host, String modelId);

  /// App bar title of the media slot editor (`Edit {slot}`).
  String mediaModelsEditTitle(String slot);
}

/// The English [FaUiStrings] defaults.
class FaUiStringsEn extends FaUiStrings {
  /// Creates the English strings.
  const FaUiStringsEn();

  @override
  String get settingsProvidersSectionTitle => 'Providers';
  @override
  String get settingsLocalProvidersSectionTitle => 'Local models';
  @override
  String get settingsAddProvider => 'Add provider';
  @override
  String get settingsEditProviderTitle => 'Edit provider';
  @override
  String get settingsDefaultChatModelTitle => 'Default chat model';
  @override
  String get settingsPickProviderTitle => 'Choose provider';
  @override
  String get settingsPickModelTitle => 'Choose model';
  @override
  String get settingsApplyButton => 'Apply';
  @override
  String get settingsSaveButton => 'Save';
  @override
  String get settingsCancelButton => 'Cancel';
  @override
  String get settingsDeleteButton => 'Delete';
  @override
  String get settingsNameRequired => 'Name is required';
  @override
  String get settingsBaseUrlRequired => 'Base URL is required';
  @override
  String get settingsModelIdRequired => 'Model id is required';
  @override
  String get settingsApiKeyRequired => 'API key is required';
  @override
  String get settingsProviderNameLabel => 'Name';
  @override
  String get settingsProviderNameHint => 'My provider';
  @override
  String get settingsBaseUrlLabel => 'Base URL';
  @override
  String get settingsBaseUrlHelper => 'OpenAI-compatible endpoint';
  @override
  String get settingsModelIdLabel => 'Model id';
  @override
  String get settingsModelIdOptionalLabel => 'Model id (optional)';
  @override
  String get settingsApiKeyOptionalLabel => 'API key (optional)';
  @override
  String get settingsEditorKeepKeyNote =>
      'A key is saved for this provider — leave the field empty to keep it.';
  @override
  String get settingsApiKeyLocalHelper =>
      'Leave empty for local servers (llama.cpp, Ollama, LM Studio)';
  @override
  String get settingsKeyNoteHosted =>
      'In-memory only: your key is never persisted and is gone on reload. '
      'Calls go straight from your browser to the provider — nothing is '
      'proxied or stored.';
  @override
  String get settingsKeyNoteHostedSecure =>
      'Saved keys are stored in the Keychain on this device; a key only '
      'typed into the form stays in memory for this session. Calls go '
      'straight from the app to the provider — nothing is proxied.';
  @override
  String get settingsEditorKeyNote =>
      'Name, URL and model are saved; the key is kept in memory for this '
      'session only — never persisted.';
  @override
  String get settingsEditorKeyNoteSecure =>
      'Name, URL and model are saved; the key is stored in the Keychain on '
      'this device.';
  @override
  String get settingsCorsNoteOllama =>
      'Calls go straight from your browser to ollama.com, which currently '
      'does not send CORS headers — browser calls fail. Use OpenRouter here, '
      'or pick Ollama from the mobile/desktop app instead.';
  @override
  String get settingsCorsNoteCustom =>
      'Any OpenAI-compatible endpoint. The provider must allow browser '
      '(CORS) requests — api.anthropic.com does not, so reach Anthropic '
      'models via OpenRouter instead.';
  @override
  String get settingsPresetOpenrouter => 'OpenRouter';
  @override
  String get settingsOpenRouterOAuthButton => 'Authorize with OpenRouter';
  @override
  String get settingsOpenRouterOAuthSheetTitle => 'OpenRouter authorization';
  @override
  String get settingsOpenRouterOAuthSheetBody =>
      'After authorizing on the OpenRouter page, paste the code shown on '
      'screen below.';
  @override
  String get settingsOpenRouterOAuthCodeLabel => 'Authorization code';
  @override
  String get settingsOpenRouterOAuthConfirmButton => 'Connect';
  @override
  String settingsOpenRouterOAuthError(String message) =>
      'OpenRouter authorization failed: $message';
  @override
  String get settingsPresetOllama => 'Ollama';
  @override
  String get settingsPresetGemini => 'Google Gemini';
  @override
  String get settingsPresetDial => 'DIAL';
  @override
  String get settingsPresetCustom => 'Custom';
  @override
  String get settingsPresetWebllm => 'On-device (WebLLM)';
  @override
  String get settingsPresetGemma => 'On-device (Gemma)';
  @override
  String get settingsPresetTransformersJs =>
      'On-device (Gemma, transformers.js)';
  @override
  String get settingsModelsFetching => 'Fetching models from the endpoint…';
  @override
  String get mediaModelsMainConnection => 'Main connection';
  @override
  String get mediaModelsCapabilitiesNote =>
      "This endpoint's models suggest support for:";
  @override
  String get mediaModelsVoiceLabel => 'Voice (optional)';
  @override
  String get mediaModelsVoiceHint => 'alloy / af_heart / nova';
  @override
  String get mediaModelsSlotImageGeneration => 'Image generation';
  @override
  String get mediaModelsSlotAudioTts => 'Text-to-speech';
  @override
  String get mediaModelsSlotMusicGeneration => 'Music generation';
  @override
  String get mediaModelsSlotVideoGeneration => 'Video generation';
  @override
  String get mediaModelsSlotVision => 'Vision (image reading)';
  @override
  String get mediaModelsSlotTranscription => 'Transcription';
  @override
  String get mediaModelsSectionTitle => 'Media models';
  @override
  String get mediaModelsSectionNote =>
      'Image, audio, video and transcription calls use the main connection '
      'unless a slot overrides it.';
  @override
  String get mediaModelsFallbackSummary => 'Same as main connection';

  @override
  String settingsDeleteProviderTitle(String name) => 'Delete $name?';
  @override
  String get settingsDeleteProviderBody =>
      'The provider is removed from the picker. The current connection is '
      'not affected.';
  @override
  String settingsProviderModelSummary(String model, String provider) =>
      '$model · $provider';
  @override
  String mediaModelsOverrideSummary(String host, String modelId) =>
      '$modelId · $host';
  @override
  String mediaModelsEditTitle(String slot) => 'Edit $slot';
}

/// The Russian [FaUiStrings] defaults.
class FaUiStringsRu extends FaUiStrings {
  /// Creates the Russian strings.
  const FaUiStringsRu();

  @override
  String get settingsProvidersSectionTitle => 'Провайдеры';
  @override
  String get settingsLocalProvidersSectionTitle => 'Локальные модели';
  @override
  String get settingsAddProvider => 'Добавить провайдера';
  @override
  String get settingsEditProviderTitle => 'Изменить провайдера';
  @override
  String get settingsDefaultChatModelTitle => 'Модель чата по умолчанию';
  @override
  String get settingsPickProviderTitle => 'Выбор провайдера';
  @override
  String get settingsPickModelTitle => 'Выбор модели';
  @override
  String get settingsApplyButton => 'Применить';
  @override
  String get settingsSaveButton => 'Сохранить';
  @override
  String get settingsCancelButton => 'Отмена';
  @override
  String get settingsDeleteButton => 'Удалить';
  @override
  String get settingsNameRequired => 'Требуется имя';
  @override
  String get settingsBaseUrlRequired => 'Требуется базовый URL';
  @override
  String get settingsModelIdRequired => 'Требуется ID модели';
  @override
  String get settingsApiKeyRequired => 'Требуется ключ API';
  @override
  String get settingsProviderNameLabel => 'Имя';
  @override
  String get settingsProviderNameHint => 'Мой провайдер';
  @override
  String get settingsBaseUrlLabel => 'Базовый URL';
  @override
  String get settingsBaseUrlHelper => 'OpenAI-совместимая конечная точка';
  @override
  String get settingsModelIdLabel => 'ID модели';
  @override
  String get settingsModelIdOptionalLabel => 'ID модели (необязательно)';
  @override
  String get settingsApiKeyOptionalLabel => 'Ключ API (необязательно)';
  @override
  String get settingsEditorKeepKeyNote =>
      'Для этого провайдера сохранён ключ — оставьте поле пустым, чтобы не '
      'менять его.';
  @override
  String get settingsApiKeyLocalHelper =>
      'Оставьте пустым для локальных серверов (llama.cpp, Ollama, LM Studio)';
  @override
  String get settingsKeyNoteHosted =>
      'Только в памяти: ваш ключ нигде не сохраняется и исчезает после '
      'перезагрузки. Запросы идут напрямую из браузера к провайдеру — ничего '
      'не проксируется и не хранится.';
  @override
  String get settingsKeyNoteHostedSecure =>
      'Сохранённые ключи хранятся в Keychain на этом устройстве; ключ, '
      'только введённый в форму, остаётся в памяти на этот сеанс. Запросы '
      'идут напрямую из приложения к провайдеру — ничего не проксируется.';
  @override
  String get settingsEditorKeyNote =>
      'Имя, URL и модель сохраняются; ключ хранится в памяти только для '
      'этого сеанса — он не записывается на диск.';
  @override
  String get settingsEditorKeyNoteSecure =>
      'Имя, URL и модель сохраняются; ключ хранится в Keychain на этом '
      'устройстве.';
  @override
  String get settingsCorsNoteOllama =>
      'Запросы идут напрямую из браузера на ollama.com, который сейчас не '
      'отправляет заголовки CORS, — вызовы из браузера завершаются ошибкой. '
      'Используйте здесь OpenRouter или выберите Ollama в мобильном/'
      'десктопном приложении.';
  @override
  String get settingsCorsNoteCustom =>
      'Любая OpenAI-совместимая конечная точка. Провайдер должен разрешать '
      'браузерные (CORS) запросы — api.anthropic.com их не разрешает, '
      'поэтому к моделям Anthropic обращайтесь через OpenRouter.';
  @override
  String get settingsPresetOpenrouter => 'OpenRouter';
  @override
  String get settingsOpenRouterOAuthButton => 'Авторизоваться через OpenRouter';
  @override
  String get settingsOpenRouterOAuthSheetTitle => 'Авторизация OpenRouter';
  @override
  String get settingsOpenRouterOAuthSheetBody =>
      'После авторизации на странице OpenRouter вставьте показанный код ниже.';
  @override
  String get settingsOpenRouterOAuthCodeLabel => 'Код авторизации';
  @override
  String get settingsOpenRouterOAuthConfirmButton => 'Подключить';
  @override
  String settingsOpenRouterOAuthError(String message) =>
      'Ошибка авторизации OpenRouter: $message';
  @override
  String get settingsPresetOllama => 'Ollama';
  @override
  String get settingsPresetGemini => 'Google Gemini';
  @override
  String get settingsPresetDial => 'DIAL';
  @override
  String get settingsPresetCustom => 'Пользовательский';
  @override
  String get settingsPresetWebllm => 'На устройстве (WebLLM)';
  @override
  String get settingsPresetGemma => 'На устройстве (Gemma)';
  @override
  String get settingsPresetTransformersJs =>
      'На устройстве (Gemma, transformers.js)';
  @override
  String get settingsModelsFetching => 'Загрузка списка моделей с эндпоинта…';
  @override
  String get mediaModelsMainConnection => 'Основное подключение';
  @override
  String get mediaModelsCapabilitiesNote =>
      'Модели этого эндпоинта поддерживают:';
  @override
  String get mediaModelsVoiceLabel => 'Голос (необязательно)';
  @override
  String get mediaModelsVoiceHint => 'alloy / af_heart / nova';
  @override
  String get mediaModelsSlotImageGeneration => 'Генерация изображений';
  @override
  String get mediaModelsSlotAudioTts => 'Синтез речи';
  @override
  String get mediaModelsSlotMusicGeneration => 'Генерация музыки';
  @override
  String get mediaModelsSlotVideoGeneration => 'Генерация видео';
  @override
  String get mediaModelsSlotVision => 'Зрение (чтение изображений)';
  @override
  String get mediaModelsSlotTranscription => 'Транскрипция';
  @override
  String get mediaModelsSectionTitle => 'Медиамодели';
  @override
  String get mediaModelsSectionNote =>
      'Запросы изображений, аудио, видео и транскрипции используют основное '
      'подключение, если слот не переопределён.';
  @override
  String get mediaModelsFallbackSummary => 'Как основное подключение';

  @override
  String settingsDeleteProviderTitle(String name) => 'Удалить $name?';
  @override
  String get settingsDeleteProviderBody =>
      'Провайдер удаляется из списка выбора. Текущее подключение не '
      'затрагивается.';
  @override
  String settingsProviderModelSummary(String model, String provider) =>
      '$model · $provider';
  @override
  String mediaModelsOverrideSummary(String host, String modelId) =>
      '$modelId · $host';
  @override
  String mediaModelsEditTitle(String slot) => 'Изменить: $slot';
}

/// Exposes a host-provided [FaUiStrings] implementation to the widget tree;
/// [FaUiStrings.of] prefers it over the built-in locale defaults.
class FaUiStringsScope extends InheritedWidget {
  /// Creates a scope exposing [strings].
  const FaUiStringsScope({
    super.key,
    required this.strings,
    required super.child,
  });

  /// The strings every fa_ui widget below resolves.
  final FaUiStrings strings;

  @override
  bool updateShouldNotify(FaUiStringsScope oldWidget) =>
      strings != oldWidget.strings;
}
