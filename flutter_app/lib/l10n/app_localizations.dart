import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// Application title shown in the window title bar.
  ///
  /// In en, this message translates to:
  /// **'Fa'**
  String get appTitle;

  /// No description provided for @approvalAllowOnce.
  ///
  /// In en, this message translates to:
  /// **'Allow once'**
  String get approvalAllowOnce;

  /// No description provided for @approvalAllowToolTitle.
  ///
  /// In en, this message translates to:
  /// **'Allow {tool}?'**
  String approvalAllowToolTitle(Object tool);

  /// No description provided for @approvalAlwaysAllow.
  ///
  /// In en, this message translates to:
  /// **'Always allow'**
  String get approvalAlwaysAllow;

  /// No description provided for @approvalDeny.
  ///
  /// In en, this message translates to:
  /// **'Deny'**
  String get approvalDeny;

  /// No description provided for @approvalModeAlwaysAsk.
  ///
  /// In en, this message translates to:
  /// **'Always ask'**
  String get approvalModeAlwaysAsk;

  /// No description provided for @approvalModeAlwaysAskHint.
  ///
  /// In en, this message translates to:
  /// **'Every tool call asks for approval.'**
  String get approvalModeAlwaysAskHint;

  /// No description provided for @approvalModeTitle.
  ///
  /// In en, this message translates to:
  /// **'Tool approvals'**
  String get approvalModeTitle;

  /// No description provided for @approvalModeWrite.
  ///
  /// In en, this message translates to:
  /// **'Write'**
  String get approvalModeWrite;

  /// No description provided for @approvalModeWriteHint.
  ///
  /// In en, this message translates to:
  /// **'File reads run freely; writes, edits and shell commands ask for approval.'**
  String get approvalModeWriteHint;

  /// No description provided for @approvalModeYolo.
  ///
  /// In en, this message translates to:
  /// **'YOLO'**
  String get approvalModeYolo;

  /// No description provided for @approvalModeYoloHint.
  ///
  /// In en, this message translates to:
  /// **'All tools run without asking (destructive shell commands still ask).'**
  String get approvalModeYoloHint;

  /// No description provided for @approvalTierLabel.
  ///
  /// In en, this message translates to:
  /// **'Tier: {tier}'**
  String approvalTierLabel(Object tier);

  /// No description provided for @appsAskFaAbout.
  ///
  /// In en, this message translates to:
  /// **'Ask Fa about {name}'**
  String appsAskFaAbout(Object name);

  /// No description provided for @appsAskFaHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. make the buttons bigger and purple'**
  String get appsAskFaHint;

  /// No description provided for @appsAskFaSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Fa gets your message, the app state and a screenshot.'**
  String get appsAskFaSubtitle;

  /// No description provided for @appsAskFaTooltip.
  ///
  /// In en, this message translates to:
  /// **'Ask Fa about this app'**
  String get appsAskFaTooltip;

  /// No description provided for @appsEmptyState.
  ///
  /// In en, this message translates to:
  /// **'No apps yet. Ask Fa to build one —\nit will land in the apps/ folder.'**
  String get appsEmptyState;

  /// No description provided for @appsFaStatusThinking.
  ///
  /// In en, this message translates to:
  /// **'thinking…'**
  String get appsFaStatusThinking;

  /// No description provided for @appsFaStatusWorking.
  ///
  /// In en, this message translates to:
  /// **'Fa is working…'**
  String get appsFaStatusWorking;

  /// No description provided for @appsFaStatusWriting.
  ///
  /// In en, this message translates to:
  /// **'writing…'**
  String get appsFaStatusWriting;

  /// No description provided for @appsFollowUpHint.
  ///
  /// In en, this message translates to:
  /// **'Follow up…'**
  String get appsFollowUpHint;

  /// No description provided for @appsGridTitle.
  ///
  /// In en, this message translates to:
  /// **'Apps'**
  String get appsGridTitle;

  /// No description provided for @appsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load apps: {error}'**
  String appsLoadError(Object error);

  /// No description provided for @appsOpenChatTooltip.
  ///
  /// In en, this message translates to:
  /// **'Open chat'**
  String get appsOpenChatTooltip;

  /// No description provided for @appsPermissionContacts.
  ///
  /// In en, this message translates to:
  /// **'Contacts'**
  String get appsPermissionContacts;

  /// No description provided for @appsPermissionContactsDesc.
  ///
  /// In en, this message translates to:
  /// **'jsr.fa.contacts — address book (coming soon)'**
  String get appsPermissionContactsDesc;

  /// No description provided for @appsPermissionHealth.
  ///
  /// In en, this message translates to:
  /// **'Health'**
  String get appsPermissionHealth;

  /// No description provided for @appsPermissionHealthDesc.
  ///
  /// In en, this message translates to:
  /// **'jsr.fa.health — health data (coming soon)'**
  String get appsPermissionHealthDesc;

  /// No description provided for @appsPermissionHomekit.
  ///
  /// In en, this message translates to:
  /// **'HomeKit'**
  String get appsPermissionHomekit;

  /// No description provided for @appsPermissionHomekitDesc.
  ///
  /// In en, this message translates to:
  /// **'jsr.fa.homekit — smart home devices (coming soon)'**
  String get appsPermissionHomekitDesc;

  /// No description provided for @appsPermissionLlm.
  ///
  /// In en, this message translates to:
  /// **'LLM'**
  String get appsPermissionLlm;

  /// No description provided for @appsPermissionLlmDesc.
  ///
  /// In en, this message translates to:
  /// **'jsr.fa.llm — let the app ask the connected model'**
  String get appsPermissionLlmDesc;

  /// No description provided for @appsPermissionNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get appsPermissionNetwork;

  /// No description provided for @appsPermissionNetworkDesc.
  ///
  /// In en, this message translates to:
  /// **'jsr.fetchJson — let the app call HTTP APIs'**
  String get appsPermissionNetworkDesc;

  /// No description provided for @appsPermissionsDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get appsPermissionsDone;

  /// No description provided for @appsPermissionsTitle.
  ///
  /// In en, this message translates to:
  /// **'{name} permissions'**
  String appsPermissionsTitle(Object name);

  /// No description provided for @appsPermissionsTooltip.
  ///
  /// In en, this message translates to:
  /// **'App permissions'**
  String get appsPermissionsTooltip;

  /// No description provided for @appsRefreshTooltip.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get appsRefreshTooltip;

  /// No description provided for @appsReloadTooltip.
  ///
  /// In en, this message translates to:
  /// **'Reload app'**
  String get appsReloadTooltip;

  /// No description provided for @appsSendToFa.
  ///
  /// In en, this message translates to:
  /// **'Send to Fa'**
  String get appsSendToFa;

  /// No description provided for @appsSendTooltip.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get appsSendTooltip;

  /// No description provided for @appsStartError.
  ///
  /// In en, this message translates to:
  /// **'Failed to start {name}:\n{error}'**
  String appsStartError(Object error, Object name);

  /// No description provided for @appsStopTooltip.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get appsStopTooltip;

  /// No description provided for @askAnswerAction.
  ///
  /// In en, this message translates to:
  /// **'Answer'**
  String get askAnswerAction;

  /// No description provided for @askBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get askBack;

  /// No description provided for @askCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get askCancel;

  /// No description provided for @askNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get askNext;

  /// No description provided for @askOtherLabel.
  ///
  /// In en, this message translates to:
  /// **'Other (type your own)'**
  String get askOtherLabel;

  /// No description provided for @askQuestionProgress.
  ///
  /// In en, this message translates to:
  /// **'Question {index} of {total}'**
  String askQuestionProgress(Object index, Object total);

  /// No description provided for @askQuestionTitle.
  ///
  /// In en, this message translates to:
  /// **'Question'**
  String get askQuestionTitle;

  /// No description provided for @askRecommended.
  ///
  /// In en, this message translates to:
  /// **'Recommended'**
  String get askRecommended;

  /// No description provided for @askYourAnswerLabel.
  ///
  /// In en, this message translates to:
  /// **'Your answer'**
  String get askYourAnswerLabel;

  /// No description provided for @cacheBrowserSubtitle.
  ///
  /// In en, this message translates to:
  /// **'On-device model weights cached in your browser. Deleting frees space; a model re-downloads on next use.'**
  String get cacheBrowserSubtitle;

  /// No description provided for @cacheDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}?'**
  String cacheDeleteTitle(Object name);

  /// No description provided for @cacheDeleteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}'**
  String cacheDeleteTooltip(Object name);

  /// No description provided for @cacheDeleteWeightsBrowser.
  ///
  /// In en, this message translates to:
  /// **'Removes the downloaded weights ({size}) from the browser cache. The model downloads again the next time you use it.'**
  String cacheDeleteWeightsBrowser(Object size);

  /// No description provided for @cacheEntryCached.
  ///
  /// In en, this message translates to:
  /// **'{size} · {bytes} cached'**
  String cacheEntryCached(Object bytes, Object size);

  /// No description provided for @cacheNoModels.
  ///
  /// In en, this message translates to:
  /// **'No models downloaded yet.'**
  String get cacheNoModels;

  /// No description provided for @cacheNoticeDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete {name}: {error}'**
  String cacheNoticeDeleteFailed(Object error, Object name);

  /// No description provided for @cacheNoticeDeleted.
  ///
  /// In en, this message translates to:
  /// **'Deleted {name}.'**
  String cacheNoticeDeleted(Object name);

  /// No description provided for @cacheNoticeLoadedModel.
  ///
  /// In en, this message translates to:
  /// **'{name} was the loaded model — it downloads again on next use.'**
  String cacheNoticeLoadedModel(Object name);

  /// No description provided for @chatAbortTooltip.
  ///
  /// In en, this message translates to:
  /// **'Abort'**
  String get chatAbortTooltip;

  /// No description provided for @chatAttachError.
  ///
  /// In en, this message translates to:
  /// **'Could not attach {name}: {error}'**
  String chatAttachError(Object error, Object name);

  /// No description provided for @chatAttachFile.
  ///
  /// In en, this message translates to:
  /// **'Attach file'**
  String get chatAttachFile;

  /// No description provided for @chatAttachNoName.
  ///
  /// In en, this message translates to:
  /// **'Could not attach \"{name}\": no usable file name.'**
  String chatAttachNoName(Object name);

  /// No description provided for @chatAttachTooltip.
  ///
  /// In en, this message translates to:
  /// **'Attach'**
  String get chatAttachTooltip;

  /// No description provided for @chatCamera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get chatCamera;

  /// No description provided for @chatCollapse.
  ///
  /// In en, this message translates to:
  /// **'Collapse'**
  String get chatCollapse;

  /// No description provided for @chatCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Session copied to clipboard'**
  String get chatCopiedToClipboard;

  /// No description provided for @chatCopySessionTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy session'**
  String get chatCopySessionTooltip;

  /// No description provided for @chatFilesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get chatFilesTooltip;

  /// No description provided for @chatGallery.
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get chatGallery;

  /// No description provided for @chatInputHint.
  ///
  /// In en, this message translates to:
  /// **'Type a message'**
  String get chatInputHint;

  /// No description provided for @chatRemoveAttachment.
  ///
  /// In en, this message translates to:
  /// **'Remove attachment'**
  String get chatRemoveAttachment;

  /// No description provided for @chatSendError.
  ///
  /// In en, this message translates to:
  /// **'Could not send: {error}'**
  String chatSendError(Object error);

  /// No description provided for @chatSendTooltip.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get chatSendTooltip;

  /// No description provided for @chatSessionsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sessions & model'**
  String get chatSessionsTooltip;

  /// No description provided for @chatSettingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Connection settings'**
  String get chatSettingsTooltip;

  /// No description provided for @chatShowAll.
  ///
  /// In en, this message translates to:
  /// **'Show all ({count})'**
  String chatShowAll(Object count);

  /// No description provided for @chatTyping.
  ///
  /// In en, this message translates to:
  /// **'fah is typing...'**
  String get chatTyping;

  /// No description provided for @chatUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Upload failed: {error}'**
  String chatUploadFailed(Object error);

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// No description provided for @filePreviewCannotRead.
  ///
  /// In en, this message translates to:
  /// **'Cannot read file'**
  String get filePreviewCannotRead;

  /// No description provided for @filePreviewCannotStat.
  ///
  /// In en, this message translates to:
  /// **'Cannot stat file'**
  String get filePreviewCannotStat;

  /// No description provided for @filePreviewDecodeError.
  ///
  /// In en, this message translates to:
  /// **'Could not decode image'**
  String get filePreviewDecodeError;

  /// No description provided for @filePreviewLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load file'**
  String get filePreviewLoadError;

  /// No description provided for @filePreviewNoPreview.
  ///
  /// In en, this message translates to:
  /// **'No preview available'**
  String get filePreviewNoPreview;

  /// No description provided for @filePreviewTabPreview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get filePreviewTabPreview;

  /// No description provided for @filePreviewTabSource.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get filePreviewTabSource;

  /// No description provided for @filePreviewTooLarge.
  ///
  /// In en, this message translates to:
  /// **'File too large to preview'**
  String get filePreviewTooLarge;

  /// No description provided for @filePreviewTruncated.
  ///
  /// In en, this message translates to:
  /// **'Showing the first {size} — truncated'**
  String filePreviewTruncated(Object size);

  /// No description provided for @filesBackTooltip.
  ///
  /// In en, this message translates to:
  /// **'Back to files'**
  String get filesBackTooltip;

  /// No description provided for @filesEmptyFileName.
  ///
  /// In en, this message translates to:
  /// **'(empty file name)'**
  String get filesEmptyFileName;

  /// No description provided for @filesEmptyFolder.
  ///
  /// In en, this message translates to:
  /// **'Empty folder'**
  String get filesEmptyFolder;

  /// No description provided for @filesFolderAccessDenied.
  ///
  /// In en, this message translates to:
  /// **'Could not get access to that folder.'**
  String get filesFolderAccessDenied;

  /// No description provided for @filesListFolderError.
  ///
  /// In en, this message translates to:
  /// **'Could not list folder'**
  String get filesListFolderError;

  /// No description provided for @filesMountUnavailableTooltip.
  ///
  /// In en, this message translates to:
  /// **'Previously used folder is unavailable: {path} — tap to pick again'**
  String filesMountUnavailableTooltip(Object path);

  /// No description provided for @filesOpenFolderError.
  ///
  /// In en, this message translates to:
  /// **'Could not open folder'**
  String get filesOpenFolderError;

  /// No description provided for @filesOpenProjectFolderTooltip.
  ///
  /// In en, this message translates to:
  /// **'Open project folder…'**
  String get filesOpenProjectFolderTooltip;

  /// No description provided for @filesPanelTitle.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get filesPanelTitle;

  /// No description provided for @filesRefreshTooltip.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get filesRefreshTooltip;

  /// No description provided for @filesRetryButton.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get filesRetryButton;

  /// No description provided for @filesUnmountTooltip.
  ///
  /// In en, this message translates to:
  /// **'Unmount {path}'**
  String filesUnmountTooltip(Object path);

  /// No description provided for @filesUpTooltip.
  ///
  /// In en, this message translates to:
  /// **'Up'**
  String get filesUpTooltip;

  /// No description provided for @filesUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Upload failed: {error}'**
  String filesUploadFailed(Object error);

  /// No description provided for @filesUploadFailures.
  ///
  /// In en, this message translates to:
  /// **', {count} failed: {names}'**
  String filesUploadFailures(Object count, Object names);

  /// No description provided for @filesUploadSummary.
  ///
  /// In en, this message translates to:
  /// **'{uploaded, plural, =1{Uploaded 1 file} other{Uploaded {uploaded} files}}{failures}'**
  String filesUploadSummary(Object failures, num uploaded);

  /// No description provided for @filesUploadTooltip.
  ///
  /// In en, this message translates to:
  /// **'Upload files here'**
  String get filesUploadTooltip;

  /// No description provided for @gemmaCacheDeleteOrphan.
  ///
  /// In en, this message translates to:
  /// **'Removes the file ({size}) from {storage}. Installed models are not affected.'**
  String gemmaCacheDeleteOrphan(Object size, Object storage);

  /// No description provided for @gemmaCacheDeleteWeights.
  ///
  /// In en, this message translates to:
  /// **'Removes the downloaded weights ({size}) from {storage}. The model downloads again the next time you use it.'**
  String gemmaCacheDeleteWeights(Object size, Object storage);

  /// No description provided for @gemmaCacheMobileOnly.
  ///
  /// In en, this message translates to:
  /// **'On-device (Gemma) models are available in the iOS/Android builds only (on web the transformers.js provider covers on-device Gemma).'**
  String get gemmaCacheMobileOnly;

  /// No description provided for @gemmaCacheScanError.
  ///
  /// In en, this message translates to:
  /// **'Could not scan the model cache: {error}'**
  String gemmaCacheScanError(Object error);

  /// No description provided for @gemmaCacheSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Gemma weights stored {storage}. Deleting frees space; a model re-downloads on next use.'**
  String gemmaCacheSubtitle(Object storage);

  /// No description provided for @gemmaCacheTitle.
  ///
  /// In en, this message translates to:
  /// **'On-device models (Gemma)'**
  String get gemmaCacheTitle;

  /// No description provided for @gemmaStorageFromBrowser.
  ///
  /// In en, this message translates to:
  /// **'the browser storage'**
  String get gemmaStorageFromBrowser;

  /// No description provided for @gemmaStorageFromDevice.
  ///
  /// In en, this message translates to:
  /// **'the device'**
  String get gemmaStorageFromDevice;

  /// No description provided for @gemmaStorageInBrowser.
  ///
  /// In en, this message translates to:
  /// **'in your browser'**
  String get gemmaStorageInBrowser;

  /// No description provided for @gemmaStorageOnDevice.
  ///
  /// In en, this message translates to:
  /// **'on this device'**
  String get gemmaStorageOnDevice;

  /// No description provided for @quickStartCachedLabel.
  ///
  /// In en, this message translates to:
  /// **'{size} · {bytes} cached'**
  String quickStartCachedLabel(Object bytes, Object size);

  /// No description provided for @quickStartLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading model…'**
  String get quickStartLoading;

  /// No description provided for @quickStartSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Already on this device — one tap, no API key needed.'**
  String get quickStartSubtitle;

  /// No description provided for @quickStartTitle.
  ///
  /// In en, this message translates to:
  /// **'Downloaded models'**
  String get quickStartTitle;

  /// No description provided for @quickStartUse.
  ///
  /// In en, this message translates to:
  /// **'Use'**
  String get quickStartUse;

  /// No description provided for @settingsAddProvider.
  ///
  /// In en, this message translates to:
  /// **'Add provider'**
  String get settingsAddProvider;

  /// No description provided for @settingsApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Paste your provider key'**
  String get settingsApiKeyHint;

  /// No description provided for @settingsApiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get settingsApiKeyLabel;

  /// No description provided for @settingsApiKeyLocalHelper.
  ///
  /// In en, this message translates to:
  /// **'Leave empty for local servers (llama.cpp, Ollama, LM Studio)'**
  String get settingsApiKeyLocalHelper;

  /// No description provided for @settingsApiKeyOptionalLabel.
  ///
  /// In en, this message translates to:
  /// **'API key (optional)'**
  String get settingsApiKeyOptionalLabel;

  /// No description provided for @settingsApiKeyRequired.
  ///
  /// In en, this message translates to:
  /// **'API key is required'**
  String get settingsApiKeyRequired;

  /// No description provided for @settingsApplyButton.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get settingsApplyButton;

  /// No description provided for @settingsBaseUrlHelper.
  ///
  /// In en, this message translates to:
  /// **'OpenAI-compatible endpoint'**
  String get settingsBaseUrlHelper;

  /// No description provided for @settingsBaseUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Base URL'**
  String get settingsBaseUrlLabel;

  /// No description provided for @settingsBaseUrlRequired.
  ///
  /// In en, this message translates to:
  /// **'Base URL is required'**
  String get settingsBaseUrlRequired;

  /// No description provided for @settingsCancelButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get settingsCancelButton;

  /// No description provided for @settingsCoderBadge.
  ///
  /// In en, this message translates to:
  /// **'coder'**
  String get settingsCoderBadge;

  /// No description provided for @settingsCorsNoteCustom.
  ///
  /// In en, this message translates to:
  /// **'Any OpenAI-compatible endpoint. The provider must allow browser (CORS) requests — api.anthropic.com does not, so reach Anthropic models via OpenRouter instead.'**
  String get settingsCorsNoteCustom;

  /// No description provided for @settingsCorsNoteOllama.
  ///
  /// In en, this message translates to:
  /// **'Calls go straight from your browser to ollama.com, which currently does not send CORS headers — browser calls fail. Use OpenRouter here, or pick Ollama from the mobile/desktop app instead.'**
  String get settingsCorsNoteOllama;

  /// No description provided for @settingsDeleteButton.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get settingsDeleteButton;

  /// No description provided for @settingsDeleteProviderBody.
  ///
  /// In en, this message translates to:
  /// **'The provider is removed from the picker. The current connection is not affected.'**
  String get settingsDeleteProviderBody;

  /// No description provided for @settingsDeleteProviderTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}?'**
  String settingsDeleteProviderTitle(Object name);

  /// No description provided for @settingsDownloadingWeights.
  ///
  /// In en, this message translates to:
  /// **'Downloading model weights…'**
  String get settingsDownloadingWeights;

  /// No description provided for @settingsEditButton.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get settingsEditButton;

  /// No description provided for @settingsEditProviderTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit provider'**
  String get settingsEditProviderTitle;

  /// No description provided for @settingsEditorKeyNote.
  ///
  /// In en, this message translates to:
  /// **'Name, URL and model are saved; the key is kept in memory for this session only — never persisted.'**
  String get settingsEditorKeyNote;

  /// No description provided for @settingsHfTokenHint.
  ///
  /// In en, this message translates to:
  /// **'hf_… — needed if the repo is gated'**
  String get settingsHfTokenHint;

  /// No description provided for @settingsHfTokenLabel.
  ///
  /// In en, this message translates to:
  /// **'HuggingFace token (optional)'**
  String get settingsHfTokenLabel;

  /// No description provided for @settingsKeyNoteCustom.
  ///
  /// In en, this message translates to:
  /// **'The provider definition (name, URL, model) is saved — no secrets. The API key stays in memory for this session only and is gone on reload.'**
  String get settingsKeyNoteCustom;

  /// No description provided for @settingsKeyNoteHosted.
  ///
  /// In en, this message translates to:
  /// **'In-memory only: your key is never persisted and is gone on reload. Calls go straight from your browser to the provider — nothing is proxied or stored.'**
  String get settingsKeyNoteHosted;

  /// No description provided for @settingsLoadingModel.
  ///
  /// In en, this message translates to:
  /// **'Loading model…'**
  String get settingsLoadingModel;

  /// No description provided for @settingsModelIdLabel.
  ///
  /// In en, this message translates to:
  /// **'Model id'**
  String get settingsModelIdLabel;

  /// No description provided for @settingsModelIdRequired.
  ///
  /// In en, this message translates to:
  /// **'Model id is required'**
  String get settingsModelIdRequired;

  /// No description provided for @settingsNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Name is required'**
  String get settingsNameRequired;

  /// No description provided for @settingsOnDeviceModelLabel.
  ///
  /// In en, this message translates to:
  /// **'On-device model'**
  String get settingsOnDeviceModelLabel;

  /// No description provided for @settingsPresetCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get settingsPresetCustom;

  /// No description provided for @settingsPresetGemma.
  ///
  /// In en, this message translates to:
  /// **'On-device (Gemma)'**
  String get settingsPresetGemma;

  /// No description provided for @settingsPresetOllama.
  ///
  /// In en, this message translates to:
  /// **'Ollama'**
  String get settingsPresetOllama;

  /// No description provided for @settingsPresetOpenrouter.
  ///
  /// In en, this message translates to:
  /// **'OpenRouter'**
  String get settingsPresetOpenrouter;

  /// No description provided for @settingsPresetTransformersJs.
  ///
  /// In en, this message translates to:
  /// **'On-device (Gemma, transformers.js)'**
  String get settingsPresetTransformersJs;

  /// No description provided for @settingsPresetWebllm.
  ///
  /// In en, this message translates to:
  /// **'On-device (WebLLM)'**
  String get settingsPresetWebllm;

  /// No description provided for @settingsProviderLabel.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get settingsProviderLabel;

  /// No description provided for @settingsProviderNameHint.
  ///
  /// In en, this message translates to:
  /// **'My provider'**
  String get settingsProviderNameHint;

  /// No description provided for @settingsProviderNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get settingsProviderNameLabel;

  /// No description provided for @settingsSaveButton.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get settingsSaveButton;

  /// No description provided for @settingsStaleModelCache.
  ///
  /// In en, this message translates to:
  /// **'The previously used model ({model}) was removed from the cache — pick a model to download it again.'**
  String settingsStaleModelCache(Object model);

  /// No description provided for @settingsStaleModelDevice.
  ///
  /// In en, this message translates to:
  /// **'The previously used model ({model}) was removed from this device — pick a model to download it again.'**
  String settingsStaleModelDevice(Object model);

  /// No description provided for @settingsStartChat.
  ///
  /// In en, this message translates to:
  /// **'Start chat'**
  String get settingsStartChat;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsToolsBadge.
  ///
  /// In en, this message translates to:
  /// **'tools via prompt'**
  String get settingsToolsBadge;

  /// No description provided for @settingsTransformersJsNote.
  ///
  /// In en, this message translates to:
  /// **'Runs fully offline after download · needs WebGPU (Chrome/Edge/newer Safari) · weights download once from HuggingFace (public repo, no token) and are cached in your browser'**
  String get settingsTransformersJsNote;

  /// No description provided for @settingsVisionBadge.
  ///
  /// In en, this message translates to:
  /// **'vision'**
  String get settingsVisionBadge;

  /// No description provided for @settingsWebllmNote.
  ///
  /// In en, this message translates to:
  /// **'Runs fully offline after download · needs WebGPU (Chrome/Edge/newer Safari) · weights ~0.5-4 GB cached in your browser'**
  String get settingsWebllmNote;

  /// No description provided for @setupAppBarTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect to fah'**
  String get setupAppBarTitle;

  /// No description provided for @sidebarAllApps.
  ///
  /// In en, this message translates to:
  /// **'All apps ({count})'**
  String sidebarAllApps(Object count);

  /// No description provided for @sidebarAppsHeader.
  ///
  /// In en, this message translates to:
  /// **'Apps'**
  String get sidebarAppsHeader;

  /// No description provided for @sidebarCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get sidebarCancel;

  /// No description provided for @sidebarDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get sidebarDelete;

  /// No description provided for @sidebarDeletePersistedContent.
  ///
  /// In en, this message translates to:
  /// **'Session {id}'**
  String sidebarDeletePersistedContent(Object id);

  /// No description provided for @sidebarDeleteSessionContent.
  ///
  /// In en, this message translates to:
  /// **'This removes the saved session permanently.'**
  String get sidebarDeleteSessionContent;

  /// No description provided for @sidebarDeleteSessionFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not delete session: {error}'**
  String sidebarDeleteSessionFailed(Object error);

  /// No description provided for @sidebarDeleteSessionTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete session?'**
  String get sidebarDeleteSessionTitle;

  /// No description provided for @sidebarDeleteSessionTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete session'**
  String get sidebarDeleteSessionTooltip;

  /// No description provided for @sidebarLoadSessionsError.
  ///
  /// In en, this message translates to:
  /// **'Could not load sessions'**
  String get sidebarLoadSessionsError;

  /// No description provided for @sidebarModelHeader.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get sidebarModelHeader;

  /// No description provided for @sidebarNewSessionTooltip.
  ///
  /// In en, this message translates to:
  /// **'New session'**
  String get sidebarNewSessionTooltip;

  /// No description provided for @sidebarNoActiveSession.
  ///
  /// In en, this message translates to:
  /// **'No active session'**
  String get sidebarNoActiveSession;

  /// No description provided for @sidebarNoModel.
  ///
  /// In en, this message translates to:
  /// **'no model'**
  String get sidebarNoModel;

  /// No description provided for @sidebarNoSessions.
  ///
  /// In en, this message translates to:
  /// **'No sessions yet'**
  String get sidebarNoSessions;

  /// No description provided for @sidebarOnThisDevice.
  ///
  /// In en, this message translates to:
  /// **'On this device'**
  String get sidebarOnThisDevice;

  /// No description provided for @sidebarOpenAppsGridTooltip.
  ///
  /// In en, this message translates to:
  /// **'Open apps grid'**
  String get sidebarOpenAppsGridTooltip;

  /// No description provided for @sidebarProviderAnthropic.
  ///
  /// In en, this message translates to:
  /// **'Anthropic'**
  String get sidebarProviderAnthropic;

  /// No description provided for @sidebarProviderGoogle.
  ///
  /// In en, this message translates to:
  /// **'Google'**
  String get sidebarProviderGoogle;

  /// No description provided for @sidebarProviderOnDeviceWebllm.
  ///
  /// In en, this message translates to:
  /// **'On-device (WebLLM)'**
  String get sidebarProviderOnDeviceWebllm;

  /// No description provided for @sidebarProviderOpenaiCompatible.
  ///
  /// In en, this message translates to:
  /// **'OpenAI-compatible API'**
  String get sidebarProviderOpenaiCompatible;

  /// No description provided for @sidebarRefreshAppsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Refresh apps'**
  String get sidebarRefreshAppsTooltip;

  /// No description provided for @sidebarRefreshSessionsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Refresh sessions'**
  String get sidebarRefreshSessionsTooltip;

  /// No description provided for @sidebarRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get sidebarRetry;

  /// No description provided for @sidebarSessionTitle.
  ///
  /// In en, this message translates to:
  /// **'session {id}'**
  String sidebarSessionTitle(Object id);

  /// No description provided for @sidebarSessionsHeader.
  ///
  /// In en, this message translates to:
  /// **'Sessions'**
  String get sidebarSessionsHeader;

  /// No description provided for @tjsCacheTitle.
  ///
  /// In en, this message translates to:
  /// **'Downloaded models (transformers.js)'**
  String get tjsCacheTitle;

  /// No description provided for @tjsCacheWebOnly.
  ///
  /// In en, this message translates to:
  /// **'On-device (transformers.js) models are available in the web build only.'**
  String get tjsCacheWebOnly;

  /// No description provided for @uploadTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Upload is too large: {total} exceeds the {max} per-batch limit.'**
  String uploadTooLarge(Object max, Object total);

  /// No description provided for @webllmCacheManagedByOs.
  ///
  /// In en, this message translates to:
  /// **'On-device models are managed by the OS/app storage on this platform.'**
  String get webllmCacheManagedByOs;

  /// No description provided for @webllmCacheTitle.
  ///
  /// In en, this message translates to:
  /// **'Downloaded models'**
  String get webllmCacheTitle;

  /// No description provided for @settingsVisionLabel.
  ///
  /// In en, this message translates to:
  /// **'Supports images (vision)'**
  String get settingsVisionLabel;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
