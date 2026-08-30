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

  /// No description provided for @attachedEmpty.
  ///
  /// In en, this message translates to:
  /// **'No messages yet — say something below'**
  String get attachedEmpty;

  /// No description provided for @attachedToCli.
  ///
  /// In en, this message translates to:
  /// **'attached to fa cli'**
  String get attachedToCli;

  /// No description provided for @sendToCli.
  ///
  /// In en, this message translates to:
  /// **'Message the fa cli session…'**
  String get sendToCli;

  /// No description provided for @sessionFolderPersonal.
  ///
  /// In en, this message translates to:
  /// **'Personal'**
  String get sessionFolderPersonal;

  /// No description provided for @sessionInfoNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Session name'**
  String get sessionInfoNameLabel;

  /// No description provided for @newSessionFolderTitle.
  ///
  /// In en, this message translates to:
  /// **'New session — folder'**
  String get newSessionFolderTitle;

  /// No description provided for @newSessionCurrentFolder.
  ///
  /// In en, this message translates to:
  /// **'Current folder ({folder})'**
  String newSessionCurrentFolder(Object folder);

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

  /// No description provided for @appsChatEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet — ask Fa about this app.'**
  String get appsChatEmptyHint;

  /// No description provided for @appsCollapseChatTooltip.
  ///
  /// In en, this message translates to:
  /// **'Collapse chat'**
  String get appsCollapseChatTooltip;

  /// No description provided for @appsDismissReplyTooltip.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get appsDismissReplyTooltip;

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

  /// No description provided for @widgetsCatalogInstallFailed.
  ///
  /// In en, this message translates to:
  /// **'Install failed: {error}'**
  String widgetsCatalogInstallFailed(Object error);

  /// No description provided for @widgetsCatalogOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline — showing the last known catalog.'**
  String get widgetsCatalogOffline;

  /// No description provided for @widgetsCatalogLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load the widgets catalog.\n{error}'**
  String widgetsCatalogLoadFailed(Object error);

  /// No description provided for @widgetsCatalogRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get widgetsCatalogRetry;

  /// No description provided for @appsOpenChatTooltip.
  ///
  /// In en, this message translates to:
  /// **'Open chat'**
  String get appsOpenChatTooltip;

  /// No description provided for @appsOpenFullChatTooltip.
  ///
  /// In en, this message translates to:
  /// **'Open full chat'**
  String get appsOpenFullChatTooltip;

  /// No description provided for @appsPermissionCalendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar'**
  String get appsPermissionCalendar;

  /// No description provided for @appsPermissionCalendarDesc.
  ///
  /// In en, this message translates to:
  /// **'jsr.fa.calendar — read your system calendar events'**
  String get appsPermissionCalendarDesc;

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

  /// No description provided for @appsPermissionKeys.
  ///
  /// In en, this message translates to:
  /// **'Host keys'**
  String get appsPermissionKeys;

  /// No description provided for @appsPermissionKeysDesc.
  ///
  /// In en, this message translates to:
  /// **'jsr.fa.keys — read the API keys saved in Fa and request new ones'**
  String get appsPermissionKeysDesc;

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

  /// No description provided for @appsPermissionMedia.
  ///
  /// In en, this message translates to:
  /// **'Media'**
  String get appsPermissionMedia;

  /// No description provided for @appsPermissionMediaDesc.
  ///
  /// In en, this message translates to:
  /// **'jsr.fa.media — generate images, speech, and music'**
  String get appsPermissionMediaDesc;

  /// No description provided for @appsPermissionMicrophone.
  ///
  /// In en, this message translates to:
  /// **'Microphone'**
  String get appsPermissionMicrophone;

  /// No description provided for @appsPermissionMicrophoneDesc.
  ///
  /// In en, this message translates to:
  /// **'jsr.fa.asr — record audio and transcribe speech'**
  String get appsPermissionMicrophoneDesc;

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

  /// No description provided for @appsPermissionNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get appsPermissionNotifications;

  /// No description provided for @appsPermissionNotificationsDesc.
  ///
  /// In en, this message translates to:
  /// **'jsr.fa.notify — schedule local notifications'**
  String get appsPermissionNotificationsDesc;

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

  /// No description provided for @appsCloseTooltip.
  ///
  /// In en, this message translates to:
  /// **'Close app'**
  String get appsCloseTooltip;

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

  /// No description provided for @chatMicDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone access was denied. Enable it in the system privacy settings (Privacy & Security → Microphone), then try again.'**
  String get chatMicDenied;

  /// No description provided for @chatMicError.
  ///
  /// In en, this message translates to:
  /// **'Voice input failed: {error}'**
  String chatMicError(Object error);

  /// No description provided for @chatMicStopTooltip.
  ///
  /// In en, this message translates to:
  /// **'Stop recording'**
  String get chatMicStopTooltip;

  /// No description provided for @chatMicTooltip.
  ///
  /// In en, this message translates to:
  /// **'Voice input'**
  String get chatMicTooltip;

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
  /// **'Fa is typing...'**
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

  /// No description provided for @filePreviewEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get filePreviewEdit;

  /// No description provided for @filePreviewSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get filePreviewSave;

  /// No description provided for @filePreviewSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get filePreviewSaved;

  /// No description provided for @filePreviewSaveError.
  ///
  /// In en, this message translates to:
  /// **'Save failed'**
  String get filePreviewSaveError;

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

  /// No description provided for @filesFolderPickerError.
  ///
  /// In en, this message translates to:
  /// **'Could not open folder picker: {error}'**
  String filesFolderPickerError(Object error);

  /// No description provided for @filesICloudSyncDone.
  ///
  /// In en, this message translates to:
  /// **'Synced {files} files ({size}) — last sync {when}'**
  String filesICloudSyncDone(Object files, Object size, Object when);

  /// No description provided for @filesICloudSyncFailed.
  ///
  /// In en, this message translates to:
  /// **'iCloud sync failed: {error}'**
  String filesICloudSyncFailed(Object error);

  /// No description provided for @filesICloudSyncTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sync sessions and apps with iCloud'**
  String get filesICloudSyncTooltip;

  /// No description provided for @filesICloudSyncUnavailable.
  ///
  /// In en, this message translates to:
  /// **'iCloud sync is unavailable — enable iCloud Drive for Fa in Settings → Apple ID → iCloud'**
  String get filesICloudSyncUnavailable;

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

  /// No description provided for @keysAddButton.
  ///
  /// In en, this message translates to:
  /// **'Add key'**
  String get keysAddButton;

  /// No description provided for @keysAddDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Add key'**
  String get keysAddDialogTitle;

  /// No description provided for @keysAddNameDuplicate.
  ///
  /// In en, this message translates to:
  /// **'A key with this name already exists.'**
  String get keysAddNameDuplicate;

  /// No description provided for @keysAddNameHint.
  ///
  /// In en, this message translates to:
  /// **'GITHUB_TOKEN'**
  String get keysAddNameHint;

  /// No description provided for @keysAddNameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Use A–Z, 0–9 and underscores, starting with a letter.'**
  String get keysAddNameInvalid;

  /// No description provided for @keysAddNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get keysAddNameLabel;

  /// No description provided for @keysDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'The saved value is removed from this device. A value from the .env file, if any, applies again.'**
  String get keysDeleteBody;

  /// No description provided for @keysDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}?'**
  String keysDeleteTitle(Object name);

  /// No description provided for @keysSectionNote.
  ///
  /// In en, this message translates to:
  /// **'Values are never displayed. Saved keys persist on this device; session keys are gone on reload.'**
  String get keysSectionNote;

  /// No description provided for @keysSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Keys'**
  String get keysSectionTitle;

  /// No description provided for @keysSetButton.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get keysSetButton;

  /// No description provided for @keysSetDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Set {name}'**
  String keysSetDialogTitle(Object name);

  /// No description provided for @keysSourceEnv.
  ///
  /// In en, this message translates to:
  /// **'env file'**
  String get keysSourceEnv;

  /// No description provided for @keysSourceNone.
  ///
  /// In en, this message translates to:
  /// **'not set'**
  String get keysSourceNone;

  /// No description provided for @keysSourceProviderSession.
  ///
  /// In en, this message translates to:
  /// **'provider key · this session'**
  String get keysSourceProviderSession;

  /// No description provided for @keysSourceSaved.
  ///
  /// In en, this message translates to:
  /// **'saved'**
  String get keysSourceSaved;

  /// No description provided for @keysValueHint.
  ///
  /// In en, this message translates to:
  /// **'Paste the key value'**
  String get keysValueHint;

  /// No description provided for @keysValueLabel.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get keysValueLabel;

  /// No description provided for @launcherChatActionsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Chat actions'**
  String get launcherChatActionsTooltip;

  /// No description provided for @launcherChatEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet — ask Fa anything.'**
  String get launcherChatEmptyHint;

  /// No description provided for @launcherDissolveFolder.
  ///
  /// In en, this message translates to:
  /// **'Remove folder'**
  String get launcherDissolveFolder;

  /// No description provided for @launcherFolderDefaultName.
  ///
  /// In en, this message translates to:
  /// **'Folder'**
  String get launcherFolderDefaultName;

  /// No description provided for @launcherFolderNameHint.
  ///
  /// In en, this message translates to:
  /// **'Folder name'**
  String get launcherFolderNameHint;

  /// No description provided for @launcherOpenAppError.
  ///
  /// In en, this message translates to:
  /// **'Could not open the app: {error}'**
  String launcherOpenAppError(Object error);

  /// No description provided for @launcherRenameFolderTooltip.
  ///
  /// In en, this message translates to:
  /// **'Rename folder'**
  String get launcherRenameFolderTooltip;

  /// No description provided for @launcherRestoreDemoApp.
  ///
  /// In en, this message translates to:
  /// **'Restore reference version'**
  String get launcherRestoreDemoApp;

  /// No description provided for @launcherRestoreDemoAppDone.
  ///
  /// In en, this message translates to:
  /// **'App code restored (your data was kept)'**
  String get launcherRestoreDemoAppDone;

  /// No description provided for @launcherRemoveWidget.
  ///
  /// In en, this message translates to:
  /// **'Remove widget'**
  String get launcherRemoveWidget;

  /// No description provided for @launcherRemoveWidgetTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove {name}?'**
  String launcherRemoveWidgetTitle(String name);

  /// No description provided for @launcherRemoveWidgetBody.
  ///
  /// In en, this message translates to:
  /// **'The widget files are deleted; its saved data (storage.json) is kept, so reinstalling restores its state.'**
  String get launcherRemoveWidgetBody;

  /// No description provided for @launcherSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search widgets…'**
  String get launcherSearchHint;

  /// No description provided for @launcherTabWidgets.
  ///
  /// In en, this message translates to:
  /// **'Widgets'**
  String get launcherTabWidgets;

  /// No description provided for @settingsResetApps.
  ///
  /// In en, this message translates to:
  /// **'Reset apps'**
  String get settingsResetApps;

  /// No description provided for @settingsResetAppsHint.
  ///
  /// In en, this message translates to:
  /// **'Restore the widget apps to their initial state'**
  String get settingsResetAppsHint;

  /// No description provided for @settingsResetAppsConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset all apps?'**
  String get settingsResetAppsConfirmTitle;

  /// No description provided for @settingsResetAppsConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This deletes EVERY widget you downloaded from the catalog or created here, together with ALL its data (saved state, settings, storage). The apps grid returns to a clean slate — re-download anything from Get widgets. This cannot be undone.'**
  String get settingsResetAppsConfirmBody;

  /// No description provided for @settingsResetAppsDone.
  ///
  /// In en, this message translates to:
  /// **'Apps reset — {count} widget(s) removed'**
  String settingsResetAppsDone(int count);

  /// No description provided for @appsCatalogCreatedByMe.
  ///
  /// In en, this message translates to:
  /// **'Created by me'**
  String get appsCatalogCreatedByMe;

  /// No description provided for @commonError.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get commonError;

  /// No description provided for @launcherTabGetWidgets.
  ///
  /// In en, this message translates to:
  /// **'Get widgets'**
  String get launcherTabGetWidgets;

  /// No description provided for @launcherRestoreDemoAppFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not restore the app'**
  String get launcherRestoreDemoAppFailed;

  /// No description provided for @launcherSeedErrorCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy error'**
  String get launcherSeedErrorCopy;

  /// No description provided for @launcherSeedErrorHint.
  ///
  /// In en, this message translates to:
  /// **'Send this error to Fa — it can fix the app.'**
  String get launcherSeedErrorHint;

  /// No description provided for @launcherSeedErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'App failed to install'**
  String get launcherSeedErrorTitle;

  /// No description provided for @launcherTileSizeLarge.
  ///
  /// In en, this message translates to:
  /// **'Large (4×4)'**
  String get launcherTileSizeLarge;

  /// No description provided for @launcherTileSizeMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium (4×2)'**
  String get launcherTileSizeMedium;

  /// No description provided for @launcherTileSizeReset.
  ///
  /// In en, this message translates to:
  /// **'Reset to default'**
  String get launcherTileSizeReset;

  /// No description provided for @launcherTileSizeSmall.
  ///
  /// In en, this message translates to:
  /// **'Small (2×2)'**
  String get launcherTileSizeSmall;

  /// No description provided for @mediaFileMissing.
  ///
  /// In en, this message translates to:
  /// **'Media file not found'**
  String get mediaFileMissing;

  /// No description provided for @mediaModelsApiKeyNameHelper.
  ///
  /// In en, this message translates to:
  /// **'Name of a saved key (see Keys) — never the key itself. Empty reuses the main connection\'s key.'**
  String get mediaModelsApiKeyNameHelper;

  /// No description provided for @mediaModelsApiKeyNameLabel.
  ///
  /// In en, this message translates to:
  /// **'API key name (optional)'**
  String get mediaModelsApiKeyNameLabel;

  /// No description provided for @mediaModelsCapabilitiesNote.
  ///
  /// In en, this message translates to:
  /// **'This endpoint\'s models suggest support for:'**
  String get mediaModelsCapabilitiesNote;

  /// No description provided for @mediaModelsClearButton.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get mediaModelsClearButton;

  /// No description provided for @mediaModelsEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit {slot}'**
  String mediaModelsEditTitle(Object slot);

  /// No description provided for @mediaModelsFallbackSummary.
  ///
  /// In en, this message translates to:
  /// **'Same as main connection'**
  String get mediaModelsFallbackSummary;

  /// No description provided for @mediaModelsMainConnection.
  ///
  /// In en, this message translates to:
  /// **'Main connection'**
  String get mediaModelsMainConnection;

  /// No description provided for @mediaModelsOverrideSummary.
  ///
  /// In en, this message translates to:
  /// **'{modelId} · {host}'**
  String mediaModelsOverrideSummary(Object host, Object modelId);

  /// No description provided for @mediaModelsSectionNote.
  ///
  /// In en, this message translates to:
  /// **'Image, audio, video and transcription calls use the main connection unless a slot overrides it.'**
  String get mediaModelsSectionNote;

  /// No description provided for @mediaModelsSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Media models'**
  String get mediaModelsSectionTitle;

  /// No description provided for @mediaModelsSlotAudioTts.
  ///
  /// In en, this message translates to:
  /// **'Text-to-speech'**
  String get mediaModelsSlotAudioTts;

  /// No description provided for @mediaModelsSlotImageGeneration.
  ///
  /// In en, this message translates to:
  /// **'Image generation'**
  String get mediaModelsSlotImageGeneration;

  /// No description provided for @mediaModelsSlotMusicGeneration.
  ///
  /// In en, this message translates to:
  /// **'Music generation'**
  String get mediaModelsSlotMusicGeneration;

  /// No description provided for @mediaModelsSlotTranscription.
  ///
  /// In en, this message translates to:
  /// **'Transcription'**
  String get mediaModelsSlotTranscription;

  /// No description provided for @mediaModelsSlotVideoGeneration.
  ///
  /// In en, this message translates to:
  /// **'Video generation'**
  String get mediaModelsSlotVideoGeneration;

  /// No description provided for @mediaModelsSlotVision.
  ///
  /// In en, this message translates to:
  /// **'Vision (image reading)'**
  String get mediaModelsSlotVision;

  /// No description provided for @mediaMuteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get mediaMuteTooltip;

  /// No description provided for @mediaPauseTooltip.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get mediaPauseTooltip;

  /// No description provided for @mediaPlayTooltip.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get mediaPlayTooltip;

  /// No description provided for @mediaUnmuteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get mediaUnmuteTooltip;

  /// No description provided for @mediaVideoUnsupportedWeb.
  ///
  /// In en, this message translates to:
  /// **'Video playback is not supported in the web build'**
  String get mediaVideoUnsupportedWeb;

  /// No description provided for @modelPresetBudgetDescription.
  ///
  /// In en, this message translates to:
  /// **'Cheapest solid combo for every day — fast chat plus all media on OpenRouter'**
  String get modelPresetBudgetDescription;

  /// No description provided for @modelPresetBudgetName.
  ///
  /// In en, this message translates to:
  /// **'Budget optimal'**
  String get modelPresetBudgetName;

  /// No description provided for @modelPresetQualityDescription.
  ///
  /// In en, this message translates to:
  /// **'Top-tier chat plus flagship image generation — the strongest combo on OpenRouter'**
  String get modelPresetQualityDescription;

  /// No description provided for @modelPresetQualityName.
  ///
  /// In en, this message translates to:
  /// **'Quality'**
  String get modelPresetQualityName;

  /// No description provided for @modelPresetsApplied.
  ///
  /// In en, this message translates to:
  /// **'Applied'**
  String get modelPresetsApplied;

  /// No description provided for @modelPresetsChatLabel.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get modelPresetsChatLabel;

  /// No description provided for @modelPresetsKeyMissing.
  ///
  /// In en, this message translates to:
  /// **'This preset needs an API key for {provider}.'**
  String modelPresetsKeyMissing(Object provider);

  /// No description provided for @modelPresetsSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Model presets'**
  String get modelPresetsSectionTitle;

  /// No description provided for @modelPresetsSetKey.
  ///
  /// In en, this message translates to:
  /// **'Set key'**
  String get modelPresetsSetKey;

  /// No description provided for @onboardingAiDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'Answers come from third-party AI providers you connect. AI can be wrong or incomplete — always verify important information.'**
  String get onboardingAiDisclaimer;

  /// No description provided for @onboardingAiDisclaimerTitle.
  ///
  /// In en, this message translates to:
  /// **'AI can make mistakes'**
  String get onboardingAiDisclaimerTitle;

  /// No description provided for @onboardingFeatureApps.
  ///
  /// In en, this message translates to:
  /// **'Builds real mini-apps with live widgets right on your home grid'**
  String get onboardingFeatureApps;

  /// No description provided for @onboardingFeatureAutomation.
  ///
  /// In en, this message translates to:
  /// **'Automates your calendar, reminders and smart home'**
  String get onboardingFeatureAutomation;

  /// No description provided for @onboardingFeatureMedia.
  ///
  /// In en, this message translates to:
  /// **'Generates images, music and video on demand'**
  String get onboardingFeatureMedia;

  /// No description provided for @onboardingGetStarted.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get onboardingGetStarted;

  /// No description provided for @onboardingModelsBody.
  ///
  /// In en, this message translates to:
  /// **'One tap applies a full combo — chat plus image, music and video models. You can change everything later in Settings.'**
  String get onboardingModelsBody;

  /// No description provided for @onboardingModelsSetUpLater.
  ///
  /// In en, this message translates to:
  /// **'Set up later'**
  String get onboardingModelsSetUpLater;

  /// No description provided for @onboardingModelsTitle.
  ///
  /// In en, this message translates to:
  /// **'Pick your models'**
  String get onboardingModelsTitle;

  /// No description provided for @onboardingNext.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get onboardingNext;

  /// No description provided for @onboardingPermissionCalendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar'**
  String get onboardingPermissionCalendar;

  /// No description provided for @onboardingPermissionCalendarDesc.
  ///
  /// In en, this message translates to:
  /// **'Event planning'**
  String get onboardingPermissionCalendarDesc;

  /// No description provided for @onboardingPermissionContacts.
  ///
  /// In en, this message translates to:
  /// **'Contacts'**
  String get onboardingPermissionContacts;

  /// No description provided for @onboardingPermissionContactsDesc.
  ///
  /// In en, this message translates to:
  /// **'Call and message actions'**
  String get onboardingPermissionContactsDesc;

  /// No description provided for @onboardingPermissionHealth.
  ///
  /// In en, this message translates to:
  /// **'Health'**
  String get onboardingPermissionHealth;

  /// No description provided for @onboardingPermissionHealthDesc.
  ///
  /// In en, this message translates to:
  /// **'Activity summaries'**
  String get onboardingPermissionHealthDesc;

  /// No description provided for @onboardingPermissionHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get onboardingPermissionHome;

  /// No description provided for @onboardingPermissionHomeDesc.
  ///
  /// In en, this message translates to:
  /// **'Smart home control'**
  String get onboardingPermissionHomeDesc;

  /// No description provided for @onboardingPermissionMicrophone.
  ///
  /// In en, this message translates to:
  /// **'Microphone'**
  String get onboardingPermissionMicrophone;

  /// No description provided for @onboardingPermissionMicrophoneDesc.
  ///
  /// In en, this message translates to:
  /// **'Voice input'**
  String get onboardingPermissionMicrophoneDesc;

  /// No description provided for @onboardingPermissionNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get onboardingPermissionNotifications;

  /// No description provided for @onboardingPermissionNotificationsDesc.
  ///
  /// In en, this message translates to:
  /// **'Reminders and alerts'**
  String get onboardingPermissionNotificationsDesc;

  /// No description provided for @onboardingPermissionsBody.
  ///
  /// In en, this message translates to:
  /// **'All of these are optional — core chat works without any of them. Fa asks only in context, when a feature actually needs it, and you can change your mind anytime in the system Settings.'**
  String get onboardingPermissionsBody;

  /// No description provided for @onboardingPermissionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Permissions, on your terms'**
  String get onboardingPermissionsTitle;

  /// No description provided for @onboardingPrivacyKeysDesc.
  ///
  /// In en, this message translates to:
  /// **'API keys live in the platform Keychain (iOS/macOS) or the local secure store — never in chat logs.'**
  String get onboardingPrivacyKeysDesc;

  /// No description provided for @onboardingPrivacyKeysTitle.
  ///
  /// In en, this message translates to:
  /// **'Keys stay locked away'**
  String get onboardingPrivacyKeysTitle;

  /// No description provided for @onboardingPrivacyOnDeviceDesc.
  ///
  /// In en, this message translates to:
  /// **'Your conversations and files stay on this device.'**
  String get onboardingPrivacyOnDeviceDesc;

  /// No description provided for @onboardingPrivacyOnDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Chats and files stay on device'**
  String get onboardingPrivacyOnDeviceTitle;

  /// No description provided for @onboardingPrivacyPolicyLink.
  ///
  /// In en, this message translates to:
  /// **'Privacy policy'**
  String get onboardingPrivacyPolicyLink;

  /// No description provided for @onboardingPrivacyProvidersDesc.
  ///
  /// In en, this message translates to:
  /// **'Content is sent only to the AI providers you explicitly connect.'**
  String get onboardingPrivacyProvidersDesc;

  /// No description provided for @onboardingPrivacyProvidersTitle.
  ///
  /// In en, this message translates to:
  /// **'You choose the providers'**
  String get onboardingPrivacyProvidersTitle;

  /// No description provided for @onboardingPrivacyTitle.
  ///
  /// In en, this message translates to:
  /// **'Your data stays yours'**
  String get onboardingPrivacyTitle;

  /// No description provided for @onboardingSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get onboardingSkip;

  /// No description provided for @onboardingWelcomeBody.
  ///
  /// In en, this message translates to:
  /// **'Chat with an AI agent that does real work, not just talk.'**
  String get onboardingWelcomeBody;

  /// No description provided for @onboardingWelcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Meet Fa'**
  String get onboardingWelcomeTitle;

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

  /// No description provided for @secretRequestInvalidName.
  ///
  /// In en, this message translates to:
  /// **'Use UPPER_SNAKE: A–Z, 0–9, _, starting with a letter'**
  String get secretRequestInvalidName;

  /// No description provided for @secretRequestNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Key name'**
  String get secretRequestNameLabel;

  /// No description provided for @secretRequestNotNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get secretRequestNotNow;

  /// No description provided for @secretRequestSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get secretRequestSave;

  /// No description provided for @secretRequestTitle.
  ///
  /// In en, this message translates to:
  /// **'Fa needs a key'**
  String get secretRequestTitle;

  /// No description provided for @secretRequestValueLabel.
  ///
  /// In en, this message translates to:
  /// **'Key value'**
  String get secretRequestValueLabel;

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

  /// No description provided for @settingsCopyDebugLogs.
  ///
  /// In en, this message translates to:
  /// **'Copy debug logs'**
  String get settingsCopyDebugLogs;

  /// No description provided for @settingsSendTestCrashReport.
  ///
  /// In en, this message translates to:
  /// **'Send test crash report'**
  String get settingsSendTestCrashReport;

  /// No description provided for @settingsTestCrashReportNoFirebase.
  ///
  /// In en, this message translates to:
  /// **'Crashlytics not initialized on this device'**
  String get settingsTestCrashReportNoFirebase;

  /// No description provided for @settingsTestCrashReportSent.
  ///
  /// In en, this message translates to:
  /// **'Test report sent — check the Firebase console in a few minutes'**
  String get settingsTestCrashReportSent;

  /// No description provided for @settingsDebugLogsCopied.
  ///
  /// In en, this message translates to:
  /// **'Debug logs copied to clipboard'**
  String get settingsDebugLogsCopied;

  /// No description provided for @settingsCorsNoteOllama.
  ///
  /// In en, this message translates to:
  /// **'Calls go straight from your browser to ollama.com, which currently does not send CORS headers — browser calls fail. Use OpenRouter here, or pick Ollama from the mobile/desktop app instead.'**
  String get settingsCorsNoteOllama;

  /// No description provided for @settingsDefaultChatModelTitle.
  ///
  /// In en, this message translates to:
  /// **'Default chat model'**
  String get settingsDefaultChatModelTitle;

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

  /// No description provided for @settingsEditorKeyNoteSecure.
  ///
  /// In en, this message translates to:
  /// **'Name, URL and model are saved; the key is stored in the Keychain on this device.'**
  String get settingsEditorKeyNoteSecure;

  /// No description provided for @settingsEditorKeepKeyNote.
  ///
  /// In en, this message translates to:
  /// **'A key is saved for this provider — leave the field empty to keep it.'**
  String get settingsEditorKeepKeyNote;

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

  /// No description provided for @settingsKeyNoteCustomSecure.
  ///
  /// In en, this message translates to:
  /// **'The provider definition (name, URL, model) is saved — no secrets. Saved keys are stored in the Keychain on this device; an unsaved key stays in memory for this session only.'**
  String get settingsKeyNoteCustomSecure;

  /// No description provided for @settingsKeyNoteHosted.
  ///
  /// In en, this message translates to:
  /// **'In-memory only: your key is never persisted and is gone on reload. Calls go straight from your browser to the provider — nothing is proxied or stored.'**
  String get settingsKeyNoteHosted;

  /// No description provided for @settingsKeyNoteHostedSecure.
  ///
  /// In en, this message translates to:
  /// **'Saved keys are stored in the Keychain on this device; a key only typed into the form stays in memory for this session. Calls go straight from the app to the provider — nothing is proxied.'**
  String get settingsKeyNoteHostedSecure;

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

  /// No description provided for @settingsModelIdOptionalLabel.
  ///
  /// In en, this message translates to:
  /// **'Model id (optional)'**
  String get settingsModelIdOptionalLabel;

  /// No description provided for @settingsModelIdRequired.
  ///
  /// In en, this message translates to:
  /// **'Model id is required'**
  String get settingsModelIdRequired;

  /// No description provided for @settingsModelsFetching.
  ///
  /// In en, this message translates to:
  /// **'Fetching models from the endpoint…'**
  String get settingsModelsFetching;

  /// No description provided for @settingsModelsGroupTitle.
  ///
  /// In en, this message translates to:
  /// **'Models'**
  String get settingsModelsGroupTitle;

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

  /// No description provided for @settingsPickModelTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose model'**
  String get settingsPickModelTitle;

  /// No description provided for @settingsPickProviderTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose provider'**
  String get settingsPickProviderTitle;

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

  /// No description provided for @settingsProviderModelSummary.
  ///
  /// In en, this message translates to:
  /// **'{model} · {provider}'**
  String settingsProviderModelSummary(Object model, Object provider);

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

  /// No description provided for @settingsProvidersSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Providers'**
  String get settingsProvidersSectionTitle;

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

  /// No description provided for @settingsSkillsAccess.
  ///
  /// In en, this message translates to:
  /// **'Skills access'**
  String get settingsSkillsAccess;

  /// No description provided for @settingsSkillsAccessHint.
  ///
  /// In en, this message translates to:
  /// **'Reuse skills Claude, Copilot or Codex left in the project folder (.claude, .github, .codex)'**
  String get settingsSkillsAccessHint;

  /// No description provided for @skillsAccessAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask'**
  String get skillsAccessAsk;

  /// No description provided for @skillsAccessAllowed.
  ///
  /// In en, this message translates to:
  /// **'Allowed'**
  String get skillsAccessAllowed;

  /// No description provided for @skillsAccessDenied.
  ///
  /// In en, this message translates to:
  /// **'Denied'**
  String get skillsAccessDenied;

  /// No description provided for @skillsAccessDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Reuse existing agent skills?'**
  String get skillsAccessDialogTitle;

  /// No description provided for @skillsAccessDialogBody.
  ///
  /// In en, this message translates to:
  /// **'This project may contain skills from Claude, Copilot or Codex (.claude, .github, .codex folders) — instructions other tools placed on this machine. Fa can reuse them for your tasks.'**
  String get skillsAccessDialogBody;

  /// No description provided for @skillsAccessAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get skillsAccessAllow;

  /// No description provided for @skillsAccessNotNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get skillsAccessNotNow;

  /// No description provided for @settingsThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsThemeDark;

  /// No description provided for @settingsThemeLabel.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get settingsThemeLabel;

  /// No description provided for @settingsThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsThemeSystem;

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

  /// No description provided for @taskModelSameAsMain.
  ///
  /// In en, this message translates to:
  /// **'Same as main'**
  String get taskModelSameAsMain;

  /// No description provided for @taskModelSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get taskModelSave;

  /// No description provided for @taskModelSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Task models'**
  String get taskModelSectionTitle;

  /// No description provided for @taskModelSmolDescription.
  ///
  /// In en, this message translates to:
  /// **'For summaries and subagents'**
  String get taskModelSmolDescription;

  /// No description provided for @taskModelSmolTitle.
  ///
  /// In en, this message translates to:
  /// **'Quick model'**
  String get taskModelSmolTitle;

  /// No description provided for @taskModelUseMain.
  ///
  /// In en, this message translates to:
  /// **'Use main model'**
  String get taskModelUseMain;

  /// No description provided for @setupAppBarTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect to Fa'**
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

  /// No description provided for @sidebarRenameClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get sidebarRenameClear;

  /// No description provided for @sidebarRenameDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename session'**
  String get sidebarRenameDialogTitle;

  /// No description provided for @sidebarRenameHint.
  ///
  /// In en, this message translates to:
  /// **'An empty name restores the default one.'**
  String get sidebarRenameHint;

  /// No description provided for @sidebarRenameNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get sidebarRenameNameLabel;

  /// No description provided for @sidebarRenameSessionTooltip.
  ///
  /// In en, this message translates to:
  /// **'Rename session'**
  String get sidebarRenameSessionTooltip;

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

  /// No description provided for @settingsIconsPerRow.
  ///
  /// In en, this message translates to:
  /// **'Icons per row'**
  String get settingsIconsPerRow;

  /// No description provided for @settingsIconsPerRowHint.
  ///
  /// In en, this message translates to:
  /// **'Home grid columns; Auto is 4 on phone, 6 on wide screens'**
  String get settingsIconsPerRowHint;

  /// No description provided for @settingsIconsPerRowAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get settingsIconsPerRowAuto;

  /// No description provided for @settingsShowOnboarding.
  ///
  /// In en, this message translates to:
  /// **'Show welcome tour'**
  String get settingsShowOnboarding;

  /// No description provided for @chatSteerTooltip.
  ///
  /// In en, this message translates to:
  /// **'Send now (interrupt)'**
  String get chatSteerTooltip;

  /// No description provided for @bootstrapSessionStartError.
  ///
  /// In en, this message translates to:
  /// **'Could not start a session: {error}'**
  String bootstrapSessionStartError(Object error);

  /// No description provided for @bootstrapRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get bootstrapRetry;

  /// No description provided for @workspaceDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Session'**
  String get workspaceDialogTitle;

  /// No description provided for @workspaceDialogChangeFolder.
  ///
  /// In en, this message translates to:
  /// **'Change folder…'**
  String get workspaceDialogChangeFolder;

  /// No description provided for @workspaceDialogClearFolder.
  ///
  /// In en, this message translates to:
  /// **'Use Personal folder'**
  String get workspaceDialogClearFolder;

  /// No description provided for @workspaceDialogClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get workspaceDialogClose;

  /// No description provided for @workspaceDialogCurrentFolder.
  ///
  /// In en, this message translates to:
  /// **'Session folder'**
  String get workspaceDialogCurrentFolder;

  /// No description provided for @workspaceDialogHostPath.
  ///
  /// In en, this message translates to:
  /// **'Host path'**
  String get workspaceDialogHostPath;

  /// No description provided for @workspaceDialogMountHint.
  ///
  /// In en, this message translates to:
  /// **'Files at /project/... in the agent map to this folder on your Mac.'**
  String get workspaceDialogMountHint;

  /// No description provided for @workspaceDialogUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Project folders are only available on macOS right now.'**
  String get workspaceDialogUnsupported;

  /// No description provided for @workspaceDialogPersonal.
  ///
  /// In en, this message translates to:
  /// **'Personal (no folder mounted)'**
  String get workspaceDialogPersonal;

  /// No description provided for @workspaceDialogMailbox.
  ///
  /// In en, this message translates to:
  /// **'Your mailbox'**
  String get workspaceDialogMailbox;

  /// No description provided for @workspaceDialogMailboxHint.
  ///
  /// In en, this message translates to:
  /// **'Other Fa agents can message this session at this address.'**
  String get workspaceDialogMailboxHint;

  /// No description provided for @workspaceDialogMailboxCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get workspaceDialogMailboxCopy;

  /// No description provided for @workspaceDialogMailboxCopied.
  ///
  /// In en, this message translates to:
  /// **'Mailbox address copied'**
  String get workspaceDialogMailboxCopied;

  /// No description provided for @workspaceDialogRestrictTools.
  ///
  /// In en, this message translates to:
  /// **'Restrict tools to this folder'**
  String get workspaceDialogRestrictTools;

  /// No description provided for @workspaceDialogRestrictToolsHint.
  ///
  /// In en, this message translates to:
  /// **'Disable anything that would read or write outside the mounted folder. Off-project attempts will be blocked (and a dialog will ask you to approve them once that flow is wired up).'**
  String get workspaceDialogRestrictToolsHint;
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
