// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The shared skeleton of the three on-device provider stream functions
/// (gemma, transformers.js, WebLLM): turn state + partial-first event
/// emission ([OnDeviceStreamTurn]) and the per-attempt engine-call pump
/// ([pumpOnDeviceChat]).
///
/// Each provider keeps only its wire quirks: preset lookup, message
/// conversion (see `on_device_message_codec.dart`), tool-call payloads
/// (gemma), the GPU-crash retry loop (transformers.js), and error text
/// formatting — handed to the pump as small hooks.
///
/// The emitted protocol is the one the HTTP provider adapters use:
/// `StartEvent` → text (and tool-call) events with partial-first
/// snapshots → exactly one terminal `DoneEvent` or `ErrorEvent`. The turn
/// never throws: engine/config failures and aborts terminate the stream
/// with an [ErrorEvent] (errors-as-events is non-negotiable).
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Accumulating state and event emission for one streamed on-device turn.
///
/// Holds the text buffer, stop reason, and error message, and builds the
/// partial-first [AssistantMessage] snapshots every event carries. The
/// provider contributes its non-text content blocks (gemma's tool calls)
/// through [extraContent].
final class OnDeviceStreamTurn {
  /// Creates a turn. [formatError] renders a raw engine/config failure for
  /// the message's [AssistantMessage.errorMessage]; [formatUserError], when
  /// set, post-processes non-aborted error text (transformers.js maps its
  /// GPU-crash class to a recovery note there). [beforeErrorEvent] runs
  /// just before the terminal [ErrorEvent] is pushed — transformers.js
  /// drops its possibly poisoned engine there.
  OnDeviceStreamTurn({
    required this.eventStream,
    required this.model,
    required this.formatError,
    this.formatUserError,
    this.beforeErrorEvent,
    this.extraContent,
  });

  /// The stream every event is pushed to; [end] completes it exactly once.
  final AssistantMessageEventStream eventStream;

  /// The model the snapshots are stamped with (usage stays zero — the
  /// on-device engines report no token counts).
  final Model model;

  /// The provider's raw-error formatter and optional user-facing
  /// post-processor (see the constructor docs).
  final String Function(Object error) formatError;
  final String Function(String raw)? formatUserError;
  final Future<void> Function(bool aborted)? beforeErrorEvent;
  final List<ContentBlock> Function()? extraContent;

  final _timestamp = DateTime.now();
  final _text = StringBuffer();

  var _stopReason = StopReason.stop;
  String? _errorMessage;
  var _startPushed = false;
  var _textStarted = false;
  var _textEnded = false;
  var _donePushed = false;
  var _ended = false;

  /// Whether any text delta was streamed (transformers.js retries only
  /// pre-text failures; gemma infers `toolUse` from emitted calls).
  bool get hasText => _textStarted;

  /// The turn's start timestamp — the snapshots' timestamp and the stamp
  /// synthetic tool-call ids derive from.
  DateTime get timestamp => _timestamp;

  /// The accumulated text so far.
  String get text => _text.toString();

  /// A fresh snapshot of the message with ALL content accumulated so far.
  AssistantMessage snapshot() => AssistantMessage(
    content: [
      if (_text.isNotEmpty) TextContent(text: _text.toString()),
      ...?extraContent?.call(),
    ],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: _stopReason,
    errorMessage: _errorMessage,
    timestamp: _timestamp,
  );

  /// Pushes [StartEvent] exactly once per turn.
  void pushStart() {
    if (_startPushed) return;
    _startPushed = true;
    eventStream.push(StartEvent(partial: snapshot()));
  }

  /// Streams one text chunk: [TextStartEvent] on the first non-empty chunk,
  /// then [TextDeltaEvent]. Empty chunks are ignored (the engines emit
  /// empty flushes).
  void pushTextDelta(String chunk) {
    if (chunk.isEmpty) return;
    if (!_textStarted) {
      _textStarted = true;
      eventStream.push(TextStartEvent(contentIndex: 0, partial: snapshot()));
    }
    _text.write(chunk);
    eventStream.push(
      TextDeltaEvent(contentIndex: 0, delta: chunk, partial: snapshot()),
    );
  }

  /// Closes the text block ([TextEndEvent]) when any text was streamed.
  void pushTextEnd() {
    if (!_textStarted || _textEnded) return;
    _textEnded = true;
    eventStream.push(
      TextEndEvent(
        contentIndex: 0,
        content: _text.toString(),
        partial: snapshot(),
      ),
    );
  }

  /// Pushes the terminal [DoneEvent] with [reason] (once per turn).
  void pushDone(StopReason reason) {
    if (_donePushed) return;
    _donePushed = true;
    _stopReason = reason;
    eventStream.push(DoneEvent(reason: _stopReason, message: snapshot()));
  }

  /// Terminal path for every non-recovered failure: classifies aborts
  /// ([CancelledException] or the token already cancelled), formats the
  /// error text, runs [beforeErrorEvent] (the [bool] flag tells an abort
  /// apart from an engine failure — transformers.js drops its possibly
  /// poisoned engine only on real failures), and pushes the [ErrorEvent].
  Future<void> fail(Object error, {CancelToken? cancelToken}) async {
    final aborted =
        error is CancelledException || (cancelToken?.isCancelled ?? false);
    _stopReason = aborted ? StopReason.aborted : StopReason.error;
    final rawMessage = aborted ? 'Request was aborted' : formatError(error);
    final formatUser = formatUserError;
    final userMessage = formatUser != null && !aborted
        ? formatUser(rawMessage)
        : rawMessage;
    _errorMessage = userMessage;
    await beforeErrorEvent?.call(aborted);
    eventStream.push(ErrorEvent(reason: _stopReason, error: snapshot()));
  }

  /// Completes the event stream exactly once (the providers' `finally`).
  void end() {
    if (_ended) return;
    _ended = true;
    eventStream.end();
  }
}

/// The per-attempt engine-call state [pumpOnDeviceChat] drives: the done
/// gate, the engine's stream error, the finish reason, and the JS-side
/// cancel handle the engine bridge registers after starting the stream.
final class OnDeviceChatCall {
  final _done = Completer<void>();

  /// Set by the engine bridge when the engine reports a stream failure;
  /// the provider turns it into a thrown [StateError] after the pump
  /// awaits the done gate — the same error path a thrown failure takes.
  String? streamError;

  /// The engine's finish reason (`stop` / `length` / `''`), when reported.
  String finishReason = '';

  /// The engine bridge's cancel handle (interrupts the JS-side
  /// generation); null for engines without one (gemma).
  void Function()? cancelJs;

  /// The done gate's future (what [pumpOnDeviceChat] awaits).
  Future<void> get done => _done.future;

  /// Completes the done gate exactly once (idempotent — cancel, engine
  /// done, and stream error may all race).
  void complete() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// Runs one chat attempt against an on-device engine to completion:
///
/// 1. wires [cancelToken] so a cancel interrupts the engine, fires the
///    bridge's [OnDeviceChatCall.cancelJs], and completes the done gate;
/// 2. starts the engine stream through [startChat] (the provider wires the
///    engine callbacks: chunks → [OnDeviceStreamTurn.pushTextDelta], the
///    terminal callbacks → [OnDeviceChatCall]);
///
/// The cancel listener is registered per attempt: for the one provider
/// that retries (transformers.js GPU-crash recovery) stacked listeners are
/// harmless — interrupt is idempotent and completing an already-completed
/// gate is a no-op, and a cancel always ends the turn via
/// [OnDeviceStreamTurn.fail].
Future<OnDeviceChatCall> pumpOnDeviceChat({
  required OnDeviceStreamTurn turn,
  required CancelToken? cancelToken,
  required Future<void> Function() interrupt,
  required Future<void> Function(OnDeviceChatCall call) startChat,
}) async {
  final call = OnDeviceChatCall();
  if (cancelToken != null) {
    unawaited(
      cancelToken.onCancel.then((_) async {
        await interrupt();
        try {
          call.cancelJs?.call();
        } catch (_) {
          // Best effort: the interrupt above is the authoritative stop.
        }
        call.complete();
      }),
    );
  }
  await startChat(call);
  await call.done;
  return call;
}
