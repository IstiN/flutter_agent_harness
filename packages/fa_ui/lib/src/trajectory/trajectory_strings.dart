// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/widgets.dart';

/// The trajectory UI strings (toolbar, ledger rows, timeline, request
/// details). Same resolution pattern as the chat strings: built-in
/// English/Russian defaults, host override via [TrajectoryStringsScope].
abstract class TrajectoryStrings {
  /// Creates trajectory strings.
  const TrajectoryStrings();

  /// Resolves the strings for [context].
  static TrajectoryStrings of(BuildContext context) {
    final scoped = context
        .dependOnInheritedWidgetOfExactType<TrajectoryStringsScope>()
        ?.strings;
    if (scoped != null) return scoped;
    final locale = Localizations.maybeLocaleOf(context);
    return forLocale(locale ?? const Locale('en'));
  }

  /// The built-in defaults for [locale] (Russian or English).
  static TrajectoryStrings forLocale(Locale locale) =>
      locale.languageCode == 'ru'
      ? const TrajectoryStringsRu()
      : const TrajectoryStringsEn();

  String get viewTrajectory;
  String get viewNoRecords;

  String get toolbarAria;
  String get toolbarDuration;
  String get toolbarUseActualDuration;
  String get toolbarUseEqualWidth;
  String get toolbarActualTime;
  String get toolbarTurns;
  String get toolbarExpandTurns;
  String get toolbarCollapseTurns;
  String get toolbarCalls;
  String get toolbarExpandCalls;
  String get toolbarCollapseCalls;
  String get toolbarSearch;
  String get toolbarSearchPlaceholder;
  String get searchNoMatches;

  String get kindSystem;
  String get kindUser;
  String get kindContext;
  String get kindCompacted;
  String get kindMessage;
  String get kindAssistant;
  String get kindTool;
  String get kindSubtool;

  String turnLabel(int turn);
  String get sectionBetweenTurns;

  String get groupMessage;
  String groupStep(int step);
  String groupCompaction(int seq);

  String get statusFailed;
  String get statusPending;
  String get statusCompleted;

  String get timingNotAvailable;
  String get timingDurationTooShort;
  String get timingShowLocalTime;
  String get timingShowUnixTimestamp;
  String get timingStarted;
  String get timingTotalDuration;
  String get timingTtft;
  String get timingGeneration;
  String get timingThroughput;
  String get timingDuration;
  String get timingSource;
  String get timingSessionTimestamps;
  String get timingSessionTimestampsRunning;
  String get timingRequest;

  String unitMilliseconds(String value);
  String unitSeconds(String value);
  String unitTokens(String value);
  String unitTokensPerSecond(String value);

  String get usageTokens;
  String get usageReasoning;
  String get usageContent;
  String get usageNotReported;
  String get usageInput;
  String get usageCached;
  String get usageCacheCreated;
  String get usageOther;
  String get usageOutput;
  String get usageThisRequest;
  String get usageSessionCumulative;

  String get sourceUnknown;
  String get sourceUser;
  String get sourceNotRecorded;

  String get tabSummary;
  String get tabRawOutput;
  String get tabPreview;
  String get tabRaw;
  String get tabSource;
  String get tabPayload;
  String get tabResult;
  String get tabSchema;
  String get tabTiming;
  String get tabDiff;
  String get tabSystemPrompt;
  String get tabTools;
  String get tabUsage;

  String get recordToolCallOnly;
  String get recordNoContent;
  String get recordNoResult;
  String get recordNoOutput;
  String get recordSchemaUnavailable;
  String get recordParameters;
  String get recordResultJson;
  String get recordThinking;
  String get recordSystemPromptMissing;
  String get recordToolsMissing;

  String get historyLoadingTrajectory;
  String get historyLoadingEarlier;
  String get historyLoadEarlier;

  String requestLabel(int request);
  String requestLabelCompaction(int request);

  String summaryToolCalls(int count);
  String summarySteps(int count);

  String get detailsEvent;
  String get detailsStatus;
  String get detailsProvider;
  String get detailsModel;
  String get detailsToolCalls;
  String get detailsError;
  String get detailsFailureAuth;
  String get detailsRetry;
  String get detailsSource;
  String get detailsHierarchy;

  String get timelineAria;
  String get timelineNoTimingData;
  String timelineTotal(String duration);
  String timelineStarted(String time);
  String timelineTtftDecoding(String ttft, String decoding);

  String get layoutCompacting;
  String get layoutCompactionFailed;
  String get layoutCompacted;
  String get layoutToolCallOnly;
  String layoutImageOnly(int count);
  String get layoutInitialSystemPrompt;
  String get layoutSystemPromptUpdated;
  String get layoutToolsUpdated;
  String get layoutSystemPromptAndToolsUpdated;
  String get layoutCompactionInterrupted;

  String get headerAria;
  String headerSession(String when);
  String get headerClose;
  String statsTurns(int count);
  String statsDuration(String value);
  String statsTokensIn(String value);
  String statsTokensOut(String value);
  String searchMatchPosition(int current, int total);
  String get searchPreviousMatch;
  String get searchNextMatch;
  String get filterMessages;
  String get filterTools;
  String get filterErrors;
  String get filterSystem;
  String get switcherChat;
  String get switcherTrajectory;
  String get detailsPanePlaceholder;
  String get tabRequest;
  String get requestSystemPrompt;
  String get requestMessages;
  String unitChars(int count);

  String get detailsCopy;
  String get detailsEmptyResponse;
  String get detailsStopReason;
  String get stopReasonToolUse;
  String get stopReasonNotRecorded;
  String get recordResultPending;
  String detailsShowContent(String size);
  String metaStep(int step);
  String metaTokens(String value);
  String get rowExpand;
  String get rowCollapse;
}

/// Built-in English trajectory strings.
class TrajectoryStringsEn extends TrajectoryStrings {
  /// Creates English trajectory strings.
  const TrajectoryStringsEn();

  @override
  String get viewTrajectory => 'Trajectory';
  @override
  String get viewNoRecords => 'No records yet';

  @override
  String get toolbarAria => 'Trajectory toolbar';
  @override
  String get toolbarDuration => 'Duration';
  @override
  String get toolbarUseActualDuration => 'Use actual duration';
  @override
  String get toolbarUseEqualWidth => 'Use equal-width operations';
  @override
  String get toolbarActualTime => 'Actual time';
  @override
  String get toolbarTurns => 'Turns';
  @override
  String get toolbarExpandTurns => 'Expand turns';
  @override
  String get toolbarCollapseTurns => 'Collapse turns';
  @override
  String get toolbarCalls => 'Calls';
  @override
  String get toolbarExpandCalls => 'Expand calls';
  @override
  String get toolbarCollapseCalls => 'Collapse calls';
  @override
  String get toolbarSearch => 'Search trajectory';
  @override
  String get toolbarSearchPlaceholder => 'Search';
  @override
  String get searchNoMatches => 'No matches';

  @override
  String get kindSystem => 'SYSTEM';
  @override
  String get kindUser => 'USER';
  @override
  String get kindContext => 'CONTEXT';
  @override
  String get kindCompacted => 'COMPACTED';
  @override
  String get kindMessage => 'Message';
  @override
  String get kindAssistant => 'ASSISTANT';
  @override
  String get kindTool => 'TOOL';
  @override
  String get kindSubtool => 'SUBTOOL';

  @override
  String turnLabel(int turn) => 'Turn $turn';
  @override
  String get sectionBetweenTurns => 'Between turns';

  @override
  String get groupMessage => 'Message';
  @override
  String groupStep(int step) => 'Step $step';
  @override
  String groupCompaction(int seq) => 'Compaction $seq';

  @override
  String get statusFailed => 'Failed';
  @override
  String get statusPending => 'Pending';
  @override
  String get statusCompleted => 'Completed';

  @override
  String get timingNotAvailable => 'Not available';
  @override
  String get timingDurationTooShort => 'Duration too short';
  @override
  String get timingShowLocalTime => 'Show local time';
  @override
  String get timingShowUnixTimestamp => 'Show Unix timestamp';
  @override
  String get timingStarted => 'Started';
  @override
  String get timingTotalDuration => 'Total duration';
  @override
  String get timingTtft => 'TTFT';
  @override
  String get timingGeneration => 'Generation';
  @override
  String get timingThroughput => 'Throughput';
  @override
  String get timingDuration => 'Duration';
  @override
  String get timingSource => 'Timing source';
  @override
  String get timingSessionTimestamps => 'Session timestamps';
  @override
  String get timingSessionTimestampsRunning => 'Session timestamps (running)';
  @override
  String get timingRequest => 'Request Timing';

  @override
  String unitMilliseconds(String value) => '$value ms';
  @override
  String unitSeconds(String value) => '$value s';
  @override
  String unitTokens(String value) => '$value tok';
  @override
  String unitTokensPerSecond(String value) => '$value tok/s';

  @override
  String get usageTokens => 'Tokens';
  @override
  String get usageReasoning => 'Reasoning';
  @override
  String get usageContent => 'Content';
  @override
  String get usageNotReported => 'Usage not reported';
  @override
  String get usageInput => 'Input';
  @override
  String get usageCached => 'Cached';
  @override
  String get usageCacheCreated => 'Cache created';
  @override
  String get usageOther => 'Other';
  @override
  String get usageOutput => 'Output';
  @override
  String get usageThisRequest => 'This request';
  @override
  String get usageSessionCumulative => 'Session cumulative';

  @override
  String get sourceUnknown => 'Unknown';
  @override
  String get sourceUser => 'User';
  @override
  String get sourceNotRecorded => 'Source not recorded';

  @override
  String get tabSummary => 'Summary';
  @override
  String get tabRawOutput => 'Raw Output';
  @override
  String get tabPreview => 'Preview';
  @override
  String get tabRaw => 'Raw';
  @override
  String get tabSource => 'Source';
  @override
  String get tabPayload => 'Payload';
  @override
  String get tabResult => 'Result';
  @override
  String get tabSchema => 'Schema';
  @override
  String get tabTiming => 'Timing';
  @override
  String get tabDiff => 'Diff';
  @override
  String get tabSystemPrompt => 'System Prompt';
  @override
  String get tabTools => 'Tools';
  @override
  String get tabUsage => 'Usage';

  @override
  String get recordToolCallOnly => '(tool call only)';
  @override
  String get recordNoContent => 'No content';
  @override
  String get recordNoResult => 'No result captured';
  @override
  String get recordNoOutput => 'No output';
  @override
  String get recordSchemaUnavailable => 'Schema unavailable';
  @override
  String get recordParameters => 'Parameters';
  @override
  String get recordResultJson => 'Result JSON';
  @override
  String get recordThinking => 'Thinking';
  @override
  String get recordSystemPromptMissing => 'No system prompt in this request';
  @override
  String get recordToolsMissing => 'No tools in this request';

  @override
  String get historyLoadingTrajectory => 'Loading trajectory…';
  @override
  String get historyLoadingEarlier => 'Loading earlier history…';
  @override
  String get historyLoadEarlier => 'Load earlier history';

  @override
  String requestLabel(int request) => 'Request #$request';
  @override
  String requestLabelCompaction(int request) =>
      'Request #$request · Compaction';

  @override
  String summaryToolCalls(int count) =>
      count == 1 ? '1 tool call' : '$count tool calls';
  @override
  String summarySteps(int count) => count == 1 ? '1 step' : '$count steps';

  @override
  String get detailsEvent => 'Event details';
  @override
  String get detailsStatus => 'Status';
  @override
  String get detailsProvider => 'Provider';
  @override
  String get detailsModel => 'Model';
  @override
  String get detailsToolCalls => 'Tool calls';
  @override
  String get detailsError => 'Error';
  @override
  String get detailsFailureAuth => 'API key is invalid';
  @override
  String get detailsRetry => 'Retry';
  @override
  String get detailsSource => 'Source';
  @override
  String get detailsHierarchy => 'Hierarchy';

  @override
  String get timelineAria => 'Trajectory timeline';
  @override
  String get timelineNoTimingData => 'No timing data';
  @override
  String timelineTotal(String duration) => 'Total $duration';
  @override
  String timelineStarted(String time) => 'Started $time';
  @override
  String timelineTtftDecoding(String ttft, String decoding) =>
      'TTFT $ttft · Decoding $decoding';

  @override
  String get layoutCompacting => 'Compacting context…';
  @override
  String get layoutCompactionFailed => 'Compaction failed';
  @override
  String get layoutCompacted => 'Context compacted';
  @override
  String get layoutToolCallOnly => 'Tool call only';
  @override
  String layoutImageOnly(int count) => 'Images ×$count';
  @override
  String get layoutInitialSystemPrompt => 'Initial System Prompt';
  @override
  String get layoutSystemPromptUpdated => 'System Prompt Updated';
  @override
  String get layoutToolsUpdated => 'Tools Updated';
  @override
  String get layoutSystemPromptAndToolsUpdated =>
      'System Prompt and Tools Updated';
  @override
  String get layoutCompactionInterrupted =>
      'Compaction was interrupted before completion.';
  @override
  String get headerAria => 'Trajectory header';
  @override
  String headerSession(String when) => 'Session $when';
  @override
  String get headerClose => 'Close trajectory';
  @override
  String statsTurns(int count) => count == 1 ? '1 turn' : '$count turns';
  @override
  String statsDuration(String value) => 'Total $value';
  @override
  String statsTokensIn(String value) => 'In $value';
  @override
  String statsTokensOut(String value) => 'Out $value';
  @override
  String searchMatchPosition(int current, int total) => '$current of $total';
  @override
  String get searchPreviousMatch => 'Previous match';
  @override
  String get searchNextMatch => 'Next match';
  @override
  String get filterMessages => 'Messages';
  @override
  String get filterTools => 'Tools';
  @override
  String get filterErrors => 'Errors';
  @override
  String get filterSystem => 'System';
  @override
  String get switcherChat => 'Chat';
  @override
  String get switcherTrajectory => 'Trajectory';
  @override
  String get tabRequest => 'Request';
  @override
  String get requestSystemPrompt => 'System prompt';
  @override
  String get requestMessages => 'Messages';
  @override
  String unitChars(int count) => '$count chars';

  @override
  String get detailsCopy => 'Copy to clipboard';
  @override
  String get detailsEmptyResponse => 'Empty response';
  @override
  String get detailsStopReason => 'Stop reason';
  @override
  String get stopReasonToolUse => 'Tool use';
  @override
  String get stopReasonNotRecorded => 'Not recorded';
  @override
  String get recordResultPending => 'Result pending';
  @override
  String metaStep(int step) => 'step $step';
  @override
  String metaTokens(String value) => '$value tok';
  @override
  String get rowExpand => 'Expand row';
  @override
  String get rowCollapse => 'Collapse row';
  @override
  String detailsShowContent(String size) => 'Show content ($size)';
  @override
  String get detailsPanePlaceholder => 'Select a record to inspect';
}

/// Built-in Russian trajectory strings.
class TrajectoryStringsRu extends TrajectoryStrings {
  /// Creates Russian trajectory strings.
  const TrajectoryStringsRu();

  @override
  String get viewTrajectory => 'Траектория';
  @override
  String get viewNoRecords => 'Пока нет записей';

  @override
  String get toolbarAria => 'Панель траектории';
  @override
  String get toolbarDuration => 'Длительность';
  @override
  String get toolbarUseActualDuration => 'Использовать реальную длительность';
  @override
  String get toolbarUseEqualWidth => 'Использовать равную ширину операций';
  @override
  String get toolbarActualTime => 'Реальное время';
  @override
  String get toolbarTurns => 'Ходы';
  @override
  String get toolbarExpandTurns => 'Развернуть ходы';
  @override
  String get toolbarCollapseTurns => 'Свернуть ходы';
  @override
  String get toolbarCalls => 'Вызовы';
  @override
  String get toolbarExpandCalls => 'Развернуть вызовы';
  @override
  String get toolbarCollapseCalls => 'Свернуть вызовы';
  @override
  String get toolbarSearch => 'Поиск по траектории';
  @override
  String get toolbarSearchPlaceholder => 'Поиск';
  @override
  String get searchNoMatches => 'Нет совпадений';

  // Kind badges stay as the compact English tags (technical labels).
  @override
  String get kindSystem => 'SYSTEM';
  @override
  String get kindUser => 'USER';
  @override
  String get kindContext => 'CONTEXT';
  @override
  String get kindCompacted => 'COMPACTED';
  @override
  String get kindMessage => 'Сообщение';
  @override
  String get kindAssistant => 'ASSISTANT';
  @override
  String get kindTool => 'TOOL';
  @override
  String get kindSubtool => 'SUBTOOL';

  @override
  String turnLabel(int turn) => 'Ход $turn';
  @override
  String get sectionBetweenTurns => 'Между ходами';

  @override
  String get groupMessage => 'Сообщение';
  @override
  String groupStep(int step) => 'Шаг $step';
  @override
  String groupCompaction(int seq) => 'Сжатие $seq';

  @override
  String get statusFailed => 'Ошибка';
  @override
  String get statusPending => 'Выполняется';
  @override
  String get statusCompleted => 'Завершено';

  @override
  String get timingNotAvailable => 'Недоступно';
  @override
  String get timingDurationTooShort => 'Слишком короткий период';
  @override
  String get timingShowLocalTime => 'Показать локальное время';
  @override
  String get timingShowUnixTimestamp => 'Показать Unix-время';
  @override
  String get timingStarted => 'Начало';
  @override
  String get timingTotalDuration => 'Общая длительность';
  @override
  String get timingTtft => 'TTFT';
  @override
  String get timingGeneration => 'Генерация';
  @override
  String get timingThroughput => 'Скорость генерации';
  @override
  String get timingDuration => 'Длительность';
  @override
  String get timingSource => 'Источник таймингов';
  @override
  String get timingSessionTimestamps => 'Тайминги сессии';
  @override
  String get timingSessionTimestampsRunning => 'Тайминги сессии (выполняется)';
  @override
  String get timingRequest => 'Тайминги запроса';

  @override
  String unitMilliseconds(String value) => '$value мс';
  @override
  String unitSeconds(String value) => '$value с';
  @override
  String unitTokens(String value) => '$value ток.';
  @override
  String unitTokensPerSecond(String value) => '$value ток/с';

  @override
  String get usageTokens => 'Токены';
  @override
  String get usageReasoning => 'Рассуждения';
  @override
  String get usageContent => 'Контент';
  @override
  String get usageNotReported => 'Использование не сообщается';
  @override
  String get usageInput => 'Ввод';
  @override
  String get usageCached => 'Из кэша';
  @override
  String get usageCacheCreated => 'Создано в кэше';
  @override
  String get usageOther => 'Прочее';
  @override
  String get usageOutput => 'Вывод';
  @override
  String get usageThisRequest => 'Этот запрос';
  @override
  String get usageSessionCumulative => 'Накопительно за сессию';

  @override
  String get sourceUnknown => 'Неизвестно';
  @override
  String get sourceUser => 'Пользователь';
  @override
  String get sourceNotRecorded => 'Источник не записан';

  @override
  String get tabSummary => 'Сводка';
  @override
  String get tabRawOutput => 'Сырой вывод';
  @override
  String get tabPreview => 'Предпросмотр';
  @override
  String get tabRaw => 'Исходник';
  @override
  String get tabSource => 'Источник';
  @override
  String get tabPayload => 'Payload';
  @override
  String get tabResult => 'Результат';
  @override
  String get tabSchema => 'Схема';
  @override
  String get tabTiming => 'Тайминги';
  @override
  String get tabDiff => 'Diff';
  @override
  String get tabSystemPrompt => 'System Prompt';
  @override
  String get tabTools => 'Инструменты';
  @override
  String get tabUsage => 'Использование';

  @override
  String get recordToolCallOnly => '(только вызов инструмента)';
  @override
  String get recordNoContent => 'Нет содержимого';
  @override
  String get recordNoResult => 'Результат не зафиксирован';
  @override
  String get recordNoOutput => 'Нет вывода';
  @override
  String get recordSchemaUnavailable => 'Схема недоступна';
  @override
  String get recordParameters => 'Параметры';
  @override
  String get recordResultJson => 'JSON результата';
  @override
  String get recordThinking => 'Размышления';
  @override
  String get recordSystemPromptMissing =>
      'В этом запросе нет системного промпта';
  @override
  String get recordToolsMissing => 'В этом запросе нет инструментов';

  @override
  String get historyLoadingTrajectory => 'Загрузка траектории…';
  @override
  String get historyLoadingEarlier => 'Загрузка ранней истории…';
  @override
  String get historyLoadEarlier => 'Загрузить раннюю историю';

  @override
  String requestLabel(int request) => 'Запрос #$request';
  @override
  String requestLabelCompaction(int request) => 'Запрос #$request · Сжатие';

  @override
  String summaryToolCalls(int count) => _ruPlural(
    count,
    'вызов инструмента',
    'вызова инструмента',
    'вызовов инструмента',
  );
  @override
  String summarySteps(int count) => _ruPlural(count, 'шаг', 'шага', 'шагов');

  @override
  String get detailsEvent => 'Детали события';
  @override
  String get detailsStatus => 'Статус';
  @override
  String get detailsProvider => 'Провайдер';
  @override
  String get detailsModel => 'Модель';
  @override
  String get detailsToolCalls => 'Вызовы инструментов';
  @override
  String get detailsError => 'Ошибка';
  @override
  String get detailsFailureAuth => 'API-ключ недействителен';
  @override
  String get detailsRetry => 'Повтор';
  @override
  String get detailsSource => 'Источник';
  @override
  String get detailsHierarchy => 'Иерархия';

  @override
  String get timelineAria => 'Шкала траектории';
  @override
  String get timelineNoTimingData => 'Нет данных таймингов';
  @override
  String timelineTotal(String duration) => 'Всего $duration';
  @override
  String timelineStarted(String time) => 'Начало $time';
  @override
  String timelineTtftDecoding(String ttft, String decoding) =>
      'TTFT $ttft · Декодирование $decoding';

  @override
  String get layoutCompacting => 'Сжатие контекста…';
  @override
  String get layoutCompactionFailed => 'Сжатие не удалось';
  @override
  String get layoutCompacted => 'Контекст сжат';
  @override
  String get layoutToolCallOnly => 'Только вызов инструмента';
  @override
  String layoutImageOnly(int count) => 'Изображений ×$count';
  @override
  String get layoutInitialSystemPrompt => 'Initial System Prompt';
  @override
  String get layoutSystemPromptUpdated => 'System Prompt обновлён';
  @override
  String get layoutToolsUpdated => 'Инструменты обновлены';
  @override
  String get layoutSystemPromptAndToolsUpdated =>
      'System Prompt и инструменты обновлены';
  @override
  String get layoutCompactionInterrupted =>
      'Сжатие было прервано до завершения.';

  @override
  String get headerAria => 'Заголовок траектории';
  @override
  String headerSession(String when) => 'Сессия $when';
  @override
  String get headerClose => 'Закрыть траекторию';
  @override
  String statsTurns(int count) => _ruPlural(count, 'ход', 'хода', 'ходов');
  @override
  String get tabRequest => 'Запрос';
  @override
  String get requestSystemPrompt => 'Системный промпт';
  @override
  String get requestMessages => 'Сообщения';
  @override
  String unitChars(int count) =>
      _ruPlural(count, 'символ', 'символа', 'символов');

  @override
  String get detailsCopy => 'Копировать в буфер обмена';
  @override
  String get detailsEmptyResponse => 'Пустой ответ';
  @override
  String get detailsStopReason => 'Причина остановки';
  @override
  String get stopReasonToolUse => 'Вызов инструмента';
  @override
  String get stopReasonNotRecorded => 'Не записана';
  @override
  String get recordResultPending => 'Результат ожидается';
  @override
  String detailsShowContent(String size) => 'Показать содержимое ($size)';
  @override
  String statsDuration(String value) => 'Всего $value';
  @override
  String statsTokensIn(String value) => 'Ввод $value';
  @override
  String statsTokensOut(String value) => 'Вывод $value';
  @override
  String searchMatchPosition(int current, int total) => '$current из $total';
  @override
  String get searchPreviousMatch => 'Предыдущее совпадение';
  @override
  String get searchNextMatch => 'Следующее совпадение';
  @override
  String get filterMessages => 'Сообщения';
  @override
  String get filterTools => 'Инструменты';
  @override
  String get filterErrors => 'Ошибки';
  @override
  String get filterSystem => 'Система';
  @override
  String get switcherChat => 'Чат';
  @override
  String get switcherTrajectory => 'Траектория';
  @override
  String get detailsPanePlaceholder => 'Выберите запись для просмотра';
  @override
  String metaStep(int step) => 'шаг $step';
  @override
  String metaTokens(String value) => '$value ток.';
  @override
  String get rowExpand => 'Развернуть строку';
  @override
  String get rowCollapse => 'Свернуть строку';
}

/// Russian plural forms: one / few / many.
String _ruPlural(int count, String one, String few, String many) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) return '$count $one';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return '$count $few';
  }
  return '$count $many';
}

/// Installs a custom [TrajectoryStrings] implementation above the
/// trajectory view.
class TrajectoryStringsScope extends InheritedWidget {
  /// Creates a scope.
  const TrajectoryStringsScope({
    required this.strings,
    required super.child,
    super.key,
  });

  /// The strings visible below this scope.
  final TrajectoryStrings strings;

  @override
  bool updateShouldNotify(TrajectoryStringsScope oldWidget) =>
      strings != oldWidget.strings;
}
