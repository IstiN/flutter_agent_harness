// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/widgets.dart';

/// The chat UI strings (composer, message tiles, approval/ask/secret sheets,
/// media player). Same resolution pattern as [FaUiStrings]: built-in
/// English/Russian defaults, host override via [FaChatStringsScope].
abstract class FaChatStrings {
  /// Creates chat strings.
  const FaChatStrings();

  /// Resolves the strings for [context].
  static FaChatStrings of(BuildContext context) {
    final scoped = context
        .dependOnInheritedWidgetOfExactType<FaChatStringsScope>()
        ?.strings;
    if (scoped != null) return scoped;
    final locale = Localizations.maybeLocaleOf(context);
    return forLocale(locale ?? const Locale('en'));
  }

  /// The built-in defaults for [locale] (Russian or English).
  static FaChatStrings forLocale(Locale locale) => locale.languageCode == 'ru'
      ? const FaChatStringsRu()
      : const FaChatStringsEn();

  String get appTitle;
  String get chatAbortTooltip;
  String get chatFilesTooltip;
  String get chatCopySessionTooltip;
  String get chatSettingsTooltip;
  String get chatCopiedToClipboard;
  String get chatInputHint;
  String get chatTyping;
  String get chatSendTooltip;
  String get chatSteerTooltip;
  String get chatAttachTooltip;
  String get chatGallery;
  String get chatCamera;
  String get chatAttachFile;
  String get chatRemoveAttachment;
  String get chatMicTooltip;
  String get chatMicStopTooltip;
  String get chatMicDenied;
  String chatMicError(String error);
  String chatAttachNoName(String name);
  String chatAttachError(String error, String name);
  String chatSendError(String error);
  String chatUploadFailed(String error);
  String uploadTooLarge(String max, String total);
  String get chatCollapse;
  String chatShowAll(String count);
  String approvalAllowToolTitle(String tool);
  String approvalTierLabel(String tier);
  String get approvalDeny;
  String get approvalAllowOnce;
  String get approvalAlwaysAllow;
  String get approvalModeTitle;
  String get approvalModeAlwaysAsk;
  String get approvalModeWrite;
  String get approvalModeYolo;
  String get approvalModeAlwaysAskHint;
  String get approvalModeWriteHint;
  String get approvalModeYoloHint;
  String get askQuestionTitle;
  String askQuestionProgress(String current, String total);
  String get askCancel;
  String get askBack;
  String get askNext;
  String get askAnswerAction;
  String get askOtherLabel;
  String get askYourAnswerLabel;
  String get askRecommended;
  String get secretRequestTitle;
  String get secretRequestNameLabel;
  String get secretRequestValueLabel;
  String get secretRequestInvalidName;
  String get secretRequestSave;
  String get secretRequestNotNow;
  String get mediaPlayTooltip;
  String get mediaPauseTooltip;
  String get mediaMuteTooltip;
  String get mediaUnmuteTooltip;
  String get mediaFileMissing;
  String get mediaVideoUnsupportedWeb;
}

/// Built-in English chat strings.
class FaChatStringsEn extends FaChatStrings {
  /// Creates English chat strings.
  const FaChatStringsEn();
  @override
  String get appTitle => 'Fa';
  @override
  String get chatAbortTooltip => 'Abort';
  @override
  String get chatFilesTooltip => 'Files';
  @override
  String get chatCopySessionTooltip => 'Copy session';
  @override
  String get chatSettingsTooltip => 'Connection settings';
  @override
  String get chatCopiedToClipboard => 'Session copied to clipboard';
  @override
  String get chatInputHint => 'Type a message';
  @override
  String get chatTyping => 'Fa is typing...';
  @override
  String get chatSendTooltip => 'Send';
  @override
  String get chatSteerTooltip => 'Send now (interrupt)';
  @override
  String get chatAttachTooltip => 'Attach';
  @override
  String get chatGallery => 'Gallery';
  @override
  String get chatCamera => 'Camera';
  @override
  String get chatAttachFile => 'Attach file';
  @override
  String get chatRemoveAttachment => 'Remove attachment';
  @override
  String get chatMicTooltip => 'Voice input';
  @override
  String get chatMicStopTooltip => 'Stop recording';
  @override
  String get chatMicDenied =>
      'Microphone access was denied. Enable it in the system privacy settings (Privacy & Security → Microphone), then try again.';
  @override
  String chatMicError(String error) => 'Voice input failed: $error';
  @override
  String chatAttachNoName(String name) =>
      'Could not attach "$name": no usable file name.';
  @override
  String chatAttachError(String error, String name) =>
      'Could not attach $name: $error';
  @override
  String chatSendError(String error) => 'Could not send: $error';
  @override
  String chatUploadFailed(String error) => 'Upload failed: $error';
  @override
  String uploadTooLarge(String max, String total) =>
      'Upload is too large: $total exceeds the $max per-batch limit.';
  @override
  String get chatCollapse => 'Collapse';
  @override
  String chatShowAll(String count) => 'Show all ($count)';
  @override
  String approvalAllowToolTitle(String tool) => 'Allow $tool?';
  @override
  String approvalTierLabel(String tier) => 'Tier: $tier';
  @override
  String get approvalDeny => 'Deny';
  @override
  String get approvalAllowOnce => 'Allow once';
  @override
  String get approvalAlwaysAllow => 'Always allow';
  @override
  String get approvalModeTitle => 'Tool approvals';
  @override
  String get approvalModeAlwaysAsk => 'Always ask';
  @override
  String get approvalModeWrite => 'Write';
  @override
  String get approvalModeYolo => 'YOLO';
  @override
  String get approvalModeAlwaysAskHint => 'Every tool call asks for approval.';
  @override
  String get approvalModeWriteHint =>
      'File reads run freely; writes, edits and shell commands ask for approval.';
  @override
  String get approvalModeYoloHint =>
      'All tools run without asking (destructive shell commands still ask).';
  @override
  String get askQuestionTitle => 'Question';
  @override
  String askQuestionProgress(String current, String total) =>
      'Question $current of $total';
  @override
  String get askCancel => 'Cancel';
  @override
  String get askBack => 'Back';
  @override
  String get askNext => 'Next';
  @override
  String get askAnswerAction => 'Answer';
  @override
  String get askOtherLabel => 'Other (type your own)';
  @override
  String get askYourAnswerLabel => 'Your answer';
  @override
  String get askRecommended => 'Recommended';
  @override
  String get secretRequestTitle => 'Fa needs a key';
  @override
  String get secretRequestNameLabel => 'Key name';
  @override
  String get secretRequestValueLabel => 'Key value';
  @override
  String get secretRequestInvalidName =>
      'Use UPPER_SNAKE: A–Z, 0–9, _, starting with a letter';
  @override
  String get secretRequestSave => 'Save';
  @override
  String get secretRequestNotNow => 'Not now';
  @override
  String get mediaPlayTooltip => 'Play';
  @override
  String get mediaPauseTooltip => 'Pause';
  @override
  String get mediaMuteTooltip => 'Mute';
  @override
  String get mediaUnmuteTooltip => 'Unmute';
  @override
  String get mediaFileMissing => 'Media file not found';
  @override
  String get mediaVideoUnsupportedWeb =>
      'Video playback is not supported in the web build';
}

/// Built-in Russian chat strings.
class FaChatStringsRu extends FaChatStrings {
  /// Creates Russian chat strings.
  const FaChatStringsRu();
  @override
  String get appTitle => 'Fa';
  @override
  String get chatAbortTooltip => 'Прервать';
  @override
  String get chatFilesTooltip => 'Файлы';
  @override
  String get chatCopySessionTooltip => 'Копировать сессию';
  @override
  String get chatSettingsTooltip => 'Настройки подключения';
  @override
  String get chatCopiedToClipboard => 'Сессия скопирована в буфер обмена';
  @override
  String get chatInputHint => 'Введите сообщение';
  @override
  String get chatTyping => 'Fa печатает...';
  @override
  String get chatSendTooltip => 'Отправить';
  @override
  String get chatSteerTooltip => 'Отправить сейчас (прервать)';
  @override
  String get chatAttachTooltip => 'Прикрепить';
  @override
  String get chatGallery => 'Галерея';
  @override
  String get chatCamera => 'Камера';
  @override
  String get chatAttachFile => 'Прикрепить файл';
  @override
  String get chatRemoveAttachment => 'Удалить вложение';
  @override
  String get chatMicTooltip => 'Голосовой ввод';
  @override
  String get chatMicStopTooltip => 'Остановить запись';
  @override
  String get chatMicDenied =>
      'Доступ к микрофону запрещён. Разрешите его в системных настройках конфиденциальности (Конфиденциальность и безопасность → Микрофон) и попробуйте снова.';
  @override
  String chatMicError(String error) => 'Ошибка голосового ввода: $error';
  @override
  String chatAttachNoName(String name) =>
      'Не удалось прикрепить «$name»: нет подходящего имени файла.';
  @override
  String chatAttachError(String error, String name) =>
      'Не удалось прикрепить $name: $error';
  @override
  String chatSendError(String error) => 'Не удалось отправить: $error';
  @override
  String chatUploadFailed(String error) => 'Ошибка загрузки: $error';
  @override
  String uploadTooLarge(String max, String total) =>
      'Загрузка слишком большая: $total превышает лимит $max на один пакет.';
  @override
  String get chatCollapse => 'Свернуть';
  @override
  String chatShowAll(String count) => 'Показать все ($count)';
  @override
  String approvalAllowToolTitle(String tool) => 'Разрешить $tool?';
  @override
  String approvalTierLabel(String tier) => 'Уровень: $tier';
  @override
  String get approvalDeny => 'Запретить';
  @override
  String get approvalAllowOnce => 'Разрешить один раз';
  @override
  String get approvalAlwaysAllow => 'Всегда разрешать';
  @override
  String get approvalModeTitle => 'Разрешения инструментов';
  @override
  String get approvalModeAlwaysAsk => 'Всегда спрашивать';
  @override
  String get approvalModeWrite => 'Запись';
  @override
  String get approvalModeYolo => 'YOLO';
  @override
  String get approvalModeAlwaysAskHint =>
      'Каждый вызов инструмента требует разрешения.';
  @override
  String get approvalModeWriteHint =>
      'Чтение файлов выполняется свободно; запись, правки и команды оболочки требуют разрешения.';
  @override
  String get approvalModeYoloHint =>
      'Все инструменты запускаются без запроса (разрушительные команды оболочки всё равно спрашивают).';
  @override
  String get askQuestionTitle => 'Вопрос';
  @override
  String askQuestionProgress(String current, String total) =>
      'Вопрос $current из $total';
  @override
  String get askCancel => 'Отмена';
  @override
  String get askBack => 'Назад';
  @override
  String get askNext => 'Далее';
  @override
  String get askAnswerAction => 'Ответить';
  @override
  String get askOtherLabel => 'Другое (введите свой вариант)';
  @override
  String get askYourAnswerLabel => 'Ваш ответ';
  @override
  String get askRecommended => 'Рекомендуется';
  @override
  String get secretRequestTitle => 'Fa нужен ключ';
  @override
  String get secretRequestNameLabel => 'Имя ключа';
  @override
  String get secretRequestValueLabel => 'Значение ключа';
  @override
  String get secretRequestInvalidName =>
      'Только UPPER_SNAKE: A–Z, 0–9, _, начиная с буквы';
  @override
  String get secretRequestSave => 'Сохранить';
  @override
  String get secretRequestNotNow => 'Не сейчас';
  @override
  String get mediaPlayTooltip => 'Воспроизвести';
  @override
  String get mediaPauseTooltip => 'Пауза';
  @override
  String get mediaMuteTooltip => 'Выключить звук';
  @override
  String get mediaUnmuteTooltip => 'Включить звук';
  @override
  String get mediaFileMissing => 'Медиафайл не найден';
  @override
  String get mediaVideoUnsupportedWeb =>
      'Воспроизведение видео не поддерживается в веб-сборке';
}

/// Installs a custom [FaChatStrings] implementation above the chat.
class FaChatStringsScope extends InheritedWidget {
  /// Creates a scope.
  const FaChatStringsScope({
    required this.strings,
    required super.child,
    super.key,
  });

  /// The strings visible below this scope.
  final FaChatStrings strings;

  @override
  bool updateShouldNotify(FaChatStringsScope oldWidget) =>
      strings != oldWidget.strings;
}
