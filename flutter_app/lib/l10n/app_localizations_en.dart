// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Fa';

  @override
  String get approvalAllowOnce => 'Allow once';

  @override
  String approvalAllowToolTitle(Object tool) {
    return 'Allow $tool?';
  }

  @override
  String get approvalAlwaysAllow => 'Always allow';

  @override
  String get approvalDeny => 'Deny';

  @override
  String get approvalModeAlwaysAsk => 'Always ask';

  @override
  String get approvalModeAlwaysAskHint => 'Every tool call asks for approval.';

  @override
  String get approvalModeTitle => 'Tool approvals';

  @override
  String get approvalModeWrite => 'Write';

  @override
  String get approvalModeWriteHint =>
      'File reads run freely; writes, edits and shell commands ask for approval.';

  @override
  String get approvalModeYolo => 'YOLO';

  @override
  String get approvalModeYoloHint =>
      'All tools run without asking (destructive shell commands still ask).';

  @override
  String approvalTierLabel(Object tier) {
    return 'Tier: $tier';
  }

  @override
  String appsAskFaAbout(Object name) {
    return 'Ask Fa about $name';
  }

  @override
  String get appsAskFaHint => 'e.g. make the buttons bigger and purple';

  @override
  String get appsAskFaSubtitle =>
      'Fa gets your message, the app state and a screenshot.';

  @override
  String get appsAskFaTooltip => 'Ask Fa about this app';

  @override
  String get appsEmptyState =>
      'No apps yet. Ask Fa to build one —\nit will land in the apps/ folder.';

  @override
  String get appsFaStatusThinking => 'thinking…';

  @override
  String get appsFaStatusWorking => 'Fa is working…';

  @override
  String get appsFaStatusWriting => 'writing…';

  @override
  String get appsFollowUpHint => 'Follow up…';

  @override
  String get appsGridTitle => 'Apps';

  @override
  String appsLoadError(Object error) {
    return 'Failed to load apps: $error';
  }

  @override
  String get appsOpenChatTooltip => 'Open chat';

  @override
  String get appsPermissionContacts => 'Contacts';

  @override
  String get appsPermissionContactsDesc =>
      'jsr.fa.contacts — address book (coming soon)';

  @override
  String get appsPermissionHealth => 'Health';

  @override
  String get appsPermissionHealthDesc =>
      'jsr.fa.health — health data (coming soon)';

  @override
  String get appsPermissionHomekit => 'HomeKit';

  @override
  String get appsPermissionHomekitDesc =>
      'jsr.fa.homekit — smart home devices (coming soon)';

  @override
  String get appsPermissionLlm => 'LLM';

  @override
  String get appsPermissionLlmDesc =>
      'jsr.fa.llm — let the app ask the connected model';

  @override
  String get appsPermissionNetwork => 'Network';

  @override
  String get appsPermissionNetworkDesc =>
      'jsr.fetchJson — let the app call HTTP APIs';

  @override
  String get appsPermissionsDone => 'Done';

  @override
  String appsPermissionsTitle(Object name) {
    return '$name permissions';
  }

  @override
  String get appsPermissionsTooltip => 'App permissions';

  @override
  String get appsRefreshTooltip => 'Refresh';

  @override
  String get appsReloadTooltip => 'Reload app';

  @override
  String get appsSendToFa => 'Send to Fa';

  @override
  String get appsSendTooltip => 'Send';

  @override
  String appsStartError(Object error, Object name) {
    return 'Failed to start $name:\n$error';
  }

  @override
  String get appsStopTooltip => 'Stop';

  @override
  String get askAnswerAction => 'Answer';

  @override
  String get askBack => 'Back';

  @override
  String get askCancel => 'Cancel';

  @override
  String get askNext => 'Next';

  @override
  String get askOtherLabel => 'Other (type your own)';

  @override
  String askQuestionProgress(Object index, Object total) {
    return 'Question $index of $total';
  }

  @override
  String get askQuestionTitle => 'Question';

  @override
  String get askRecommended => 'Recommended';

  @override
  String get askYourAnswerLabel => 'Your answer';

  @override
  String get cacheBrowserSubtitle =>
      'On-device model weights cached in your browser. Deleting frees space; a model re-downloads on next use.';

  @override
  String cacheDeleteTitle(Object name) {
    return 'Delete $name?';
  }

  @override
  String cacheDeleteTooltip(Object name) {
    return 'Delete $name';
  }

  @override
  String cacheDeleteWeightsBrowser(Object size) {
    return 'Removes the downloaded weights ($size) from the browser cache. The model downloads again the next time you use it.';
  }

  @override
  String cacheEntryCached(Object bytes, Object size) {
    return '$size · $bytes cached';
  }

  @override
  String get cacheNoModels => 'No models downloaded yet.';

  @override
  String cacheNoticeDeleteFailed(Object error, Object name) {
    return 'Failed to delete $name: $error';
  }

  @override
  String cacheNoticeDeleted(Object name) {
    return 'Deleted $name.';
  }

  @override
  String cacheNoticeLoadedModel(Object name) {
    return '$name was the loaded model — it downloads again on next use.';
  }

  @override
  String get chatAbortTooltip => 'Abort';

  @override
  String chatAttachError(Object error, Object name) {
    return 'Could not attach $name: $error';
  }

  @override
  String get chatAttachFile => 'Attach file';

  @override
  String chatAttachNoName(Object name) {
    return 'Could not attach \"$name\": no usable file name.';
  }

  @override
  String get chatAttachTooltip => 'Attach';

  @override
  String get chatCamera => 'Camera';

  @override
  String get chatCollapse => 'Collapse';

  @override
  String get chatCopiedToClipboard => 'Session copied to clipboard';

  @override
  String get chatCopySessionTooltip => 'Copy session';

  @override
  String get chatFilesTooltip => 'Files';

  @override
  String get chatGallery => 'Gallery';

  @override
  String get chatInputHint => 'Type a message';

  @override
  String get chatRemoveAttachment => 'Remove attachment';

  @override
  String chatSendError(Object error) {
    return 'Could not send: $error';
  }

  @override
  String get chatSendTooltip => 'Send';

  @override
  String get chatSessionsTooltip => 'Sessions & model';

  @override
  String get chatSettingsTooltip => 'Connection settings';

  @override
  String chatShowAll(Object count) {
    return 'Show all ($count)';
  }

  @override
  String get chatTyping => 'fah is typing...';

  @override
  String chatUploadFailed(Object error) {
    return 'Upload failed: $error';
  }

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonDelete => 'Delete';

  @override
  String get filePreviewCannotRead => 'Cannot read file';

  @override
  String get filePreviewCannotStat => 'Cannot stat file';

  @override
  String get filePreviewDecodeError => 'Could not decode image';

  @override
  String get filePreviewLoadError => 'Could not load file';

  @override
  String get filePreviewNoPreview => 'No preview available';

  @override
  String get filePreviewTabPreview => 'Preview';

  @override
  String get filePreviewTabSource => 'Source';

  @override
  String get filePreviewTooLarge => 'File too large to preview';

  @override
  String filePreviewTruncated(Object size) {
    return 'Showing the first $size — truncated';
  }

  @override
  String get filesBackTooltip => 'Back to files';

  @override
  String get filesEmptyFileName => '(empty file name)';

  @override
  String get filesEmptyFolder => 'Empty folder';

  @override
  String get filesFolderAccessDenied => 'Could not get access to that folder.';

  @override
  String get filesListFolderError => 'Could not list folder';

  @override
  String filesMountUnavailableTooltip(Object path) {
    return 'Previously used folder is unavailable: $path — tap to pick again';
  }

  @override
  String get filesOpenFolderError => 'Could not open folder';

  @override
  String get filesOpenProjectFolderTooltip => 'Open project folder…';

  @override
  String get filesPanelTitle => 'Files';

  @override
  String get filesRefreshTooltip => 'Refresh';

  @override
  String get filesRetryButton => 'Retry';

  @override
  String filesUnmountTooltip(Object path) {
    return 'Unmount $path';
  }

  @override
  String get filesUpTooltip => 'Up';

  @override
  String filesUploadFailed(Object error) {
    return 'Upload failed: $error';
  }

  @override
  String filesUploadFailures(Object count, Object names) {
    return ', $count failed: $names';
  }

  @override
  String filesUploadSummary(Object failures, num uploaded) {
    String _temp0 = intl.Intl.pluralLogic(
      uploaded,
      locale: localeName,
      other: 'Uploaded $uploaded files',
      one: 'Uploaded 1 file',
    );
    return '$_temp0$failures';
  }

  @override
  String get filesUploadTooltip => 'Upload files here';

  @override
  String gemmaCacheDeleteOrphan(Object size, Object storage) {
    return 'Removes the file ($size) from $storage. Installed models are not affected.';
  }

  @override
  String gemmaCacheDeleteWeights(Object size, Object storage) {
    return 'Removes the downloaded weights ($size) from $storage. The model downloads again the next time you use it.';
  }

  @override
  String get gemmaCacheMobileOnly =>
      'On-device (Gemma) models are available in the iOS/Android builds only (on web the transformers.js provider covers on-device Gemma).';

  @override
  String gemmaCacheScanError(Object error) {
    return 'Could not scan the model cache: $error';
  }

  @override
  String gemmaCacheSubtitle(Object storage) {
    return 'Gemma weights stored $storage. Deleting frees space; a model re-downloads on next use.';
  }

  @override
  String get gemmaCacheTitle => 'On-device models (Gemma)';

  @override
  String get gemmaStorageFromBrowser => 'the browser storage';

  @override
  String get gemmaStorageFromDevice => 'the device';

  @override
  String get gemmaStorageInBrowser => 'in your browser';

  @override
  String get gemmaStorageOnDevice => 'on this device';

  @override
  String quickStartCachedLabel(Object bytes, Object size) {
    return '$size · $bytes cached';
  }

  @override
  String get quickStartLoading => 'Loading model…';

  @override
  String get quickStartSubtitle =>
      'Already on this device — one tap, no API key needed.';

  @override
  String get quickStartTitle => 'Downloaded models';

  @override
  String get quickStartUse => 'Use';

  @override
  String get settingsAddProvider => 'Add provider';

  @override
  String get settingsApiKeyHint => 'Paste your provider key';

  @override
  String get settingsApiKeyLabel => 'API key';

  @override
  String get settingsApiKeyLocalHelper =>
      'Leave empty for local servers (llama.cpp, Ollama, LM Studio)';

  @override
  String get settingsApiKeyOptionalLabel => 'API key (optional)';

  @override
  String get settingsApiKeyRequired => 'API key is required';

  @override
  String get settingsApplyButton => 'Apply';

  @override
  String get settingsBaseUrlHelper => 'OpenAI-compatible endpoint';

  @override
  String get settingsBaseUrlLabel => 'Base URL';

  @override
  String get settingsBaseUrlRequired => 'Base URL is required';

  @override
  String get settingsCancelButton => 'Cancel';

  @override
  String get settingsCoderBadge => 'coder';

  @override
  String get settingsCorsNoteCustom =>
      'Any OpenAI-compatible endpoint. The provider must allow browser (CORS) requests — api.anthropic.com does not, so reach Anthropic models via OpenRouter instead.';

  @override
  String get settingsCorsNoteOllama =>
      'Calls go straight from your browser to ollama.com, which currently does not send CORS headers — browser calls fail. Use OpenRouter here, or pick Ollama from the mobile/desktop app instead.';

  @override
  String get settingsDeleteButton => 'Delete';

  @override
  String get settingsDeleteProviderBody =>
      'The provider is removed from the picker. The current connection is not affected.';

  @override
  String settingsDeleteProviderTitle(Object name) {
    return 'Delete $name?';
  }

  @override
  String get settingsDownloadingWeights => 'Downloading model weights…';

  @override
  String get settingsEditButton => 'Edit';

  @override
  String get settingsEditProviderTitle => 'Edit provider';

  @override
  String get settingsEditorKeyNote =>
      'Name, URL and model are saved; the key is kept in memory for this session only — never persisted.';

  @override
  String get settingsHfTokenHint => 'hf_… — needed if the repo is gated';

  @override
  String get settingsHfTokenLabel => 'HuggingFace token (optional)';

  @override
  String get settingsKeyNoteCustom =>
      'The provider definition (name, URL, model) is saved — no secrets. The API key stays in memory for this session only and is gone on reload.';

  @override
  String get settingsKeyNoteHosted =>
      'In-memory only: your key is never persisted and is gone on reload. Calls go straight from your browser to the provider — nothing is proxied or stored.';

  @override
  String get settingsLoadingModel => 'Loading model…';

  @override
  String get settingsModelIdLabel => 'Model id';

  @override
  String get settingsModelIdRequired => 'Model id is required';

  @override
  String get settingsNameRequired => 'Name is required';

  @override
  String get settingsOnDeviceModelLabel => 'On-device model';

  @override
  String get settingsPresetCustom => 'Custom';

  @override
  String get settingsPresetGemma => 'On-device (Gemma)';

  @override
  String get settingsPresetOllama => 'Ollama';

  @override
  String get settingsPresetOpenrouter => 'OpenRouter';

  @override
  String get settingsPresetTransformersJs =>
      'On-device (Gemma, transformers.js)';

  @override
  String get settingsPresetWebllm => 'On-device (WebLLM)';

  @override
  String get settingsProviderLabel => 'Provider';

  @override
  String get settingsProviderNameHint => 'My provider';

  @override
  String get settingsProviderNameLabel => 'Name';

  @override
  String get settingsSaveButton => 'Save';

  @override
  String settingsStaleModelCache(Object model) {
    return 'The previously used model ($model) was removed from the cache — pick a model to download it again.';
  }

  @override
  String settingsStaleModelDevice(Object model) {
    return 'The previously used model ($model) was removed from this device — pick a model to download it again.';
  }

  @override
  String get settingsStartChat => 'Start chat';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsToolsBadge => 'tools via prompt';

  @override
  String get settingsTransformersJsNote =>
      'Runs fully offline after download · needs WebGPU (Chrome/Edge/newer Safari) · weights download once from HuggingFace (public repo, no token) and are cached in your browser';

  @override
  String get settingsVisionBadge => 'vision';

  @override
  String get settingsWebllmNote =>
      'Runs fully offline after download · needs WebGPU (Chrome/Edge/newer Safari) · weights ~0.5-4 GB cached in your browser';

  @override
  String get setupAppBarTitle => 'Connect to fah';

  @override
  String sidebarAllApps(Object count) {
    return 'All apps ($count)';
  }

  @override
  String get sidebarAppsHeader => 'Apps';

  @override
  String get sidebarCancel => 'Cancel';

  @override
  String get sidebarDelete => 'Delete';

  @override
  String sidebarDeletePersistedContent(Object id) {
    return 'Session $id';
  }

  @override
  String get sidebarDeleteSessionContent =>
      'This removes the saved session permanently.';

  @override
  String sidebarDeleteSessionFailed(Object error) {
    return 'Could not delete session: $error';
  }

  @override
  String get sidebarDeleteSessionTitle => 'Delete session?';

  @override
  String get sidebarDeleteSessionTooltip => 'Delete session';

  @override
  String get sidebarLoadSessionsError => 'Could not load sessions';

  @override
  String get sidebarModelHeader => 'Model';

  @override
  String get sidebarNewSessionTooltip => 'New session';

  @override
  String get sidebarNoActiveSession => 'No active session';

  @override
  String get sidebarNoModel => 'no model';

  @override
  String get sidebarNoSessions => 'No sessions yet';

  @override
  String get sidebarOnThisDevice => 'On this device';

  @override
  String get sidebarOpenAppsGridTooltip => 'Open apps grid';

  @override
  String get sidebarProviderAnthropic => 'Anthropic';

  @override
  String get sidebarProviderGoogle => 'Google';

  @override
  String get sidebarProviderOnDeviceWebllm => 'On-device (WebLLM)';

  @override
  String get sidebarProviderOpenaiCompatible => 'OpenAI-compatible API';

  @override
  String get sidebarRefreshAppsTooltip => 'Refresh apps';

  @override
  String get sidebarRefreshSessionsTooltip => 'Refresh sessions';

  @override
  String get sidebarRetry => 'Retry';

  @override
  String sidebarSessionTitle(Object id) {
    return 'session $id';
  }

  @override
  String get sidebarSessionsHeader => 'Sessions';

  @override
  String get tjsCacheTitle => 'Downloaded models (transformers.js)';

  @override
  String get tjsCacheWebOnly =>
      'On-device (transformers.js) models are available in the web build only.';

  @override
  String uploadTooLarge(Object max, Object total) {
    return 'Upload is too large: $total exceeds the $max per-batch limit.';
  }

  @override
  String get webllmCacheManagedByOs =>
      'On-device models are managed by the OS/app storage on this platform.';

  @override
  String get webllmCacheTitle => 'Downloaded models';

  @override
  String get settingsVisionLabel => 'Supports images (vision)';
}
