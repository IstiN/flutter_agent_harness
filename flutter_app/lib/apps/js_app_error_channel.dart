// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1164 Part B: the app-wide JS-app error channel — the single gate
/// every [JsAppEngine] reports render/runtime/load errors into, and the
/// single bus the session side (AgentService) subscribes for delivery.
///
/// Two jobs, both "anti-spam by construction" (ticket AC4 + item 6):
///
/// 1. **Dedup gate** (`reportAppError`): one report per (app, error
///    fingerprint) until the app's source revision changes — per-frame
///    animation errors collapse to the first occurrence; after N
///    unacted identical reports a per-app circuit breaker silences the
///    key entirely. An app edit (new source revision) re-arms everything.
/// 2. **Delivery bus** (`onDeliver` / `publish`): a NEW report becomes a
///    [JsAppErrorNotice] with a bounded payload (E2: first frames, size
///    cap, truncation marked); the bound AgentService routes it to the
///    app-bound session (live run → failure the agent reacts to; idle →
///    system note + inbox entry).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Parses one raw engine-log line into a [JsAppErrorEvent] when it is a
/// structured `faAppError:{json}` record (the marker the bootstrap emits);
/// returns null for every other line. Exported for the engine's log tap
/// and for tests.
///
/// The record's `{` must be the first non-whitespace character after the
/// marker — both wire shapes put it there (the plain
/// `[E] faAppError:{json}` and the iid envelope `{id: "[E] faAppError:{…}"}`
/// the engine's transport wraps console lines in by the time they reach
/// Dart; flutter_js jsonDecodes the sendMessage payload before the channel
/// callback, so the wrap survives routing — gh-1307). The object is then
/// decoded as the first balanced `{…}` from that brace (string-literal
/// aware — NOT the exact rest of the line, whose trailing envelope brace
/// used to make the payload malformed JSON and silently blind the whole
/// capture surface). A marker mention inside a plain log line — with or
/// without unrelated JSON after it — returns null.
JsAppErrorEvent? parseJsAppErrorLogLine(String line) {
  const marker = 'faAppError:';
  final index = line.indexOf(marker);
  if (index < 0) return null;
  final payload = _balancedJsonObjectAfter(line, index + marker.length);
  if (payload == null) return null;
  try {
    final decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) {
      return JsAppErrorEvent.fromLogJson(decoded);
    }
  } on Object {
    // Not our record — a stray console line mentioning the marker.
  }
  return null;
}

/// The balanced `{…}` object whose `{` is the first non-whitespace
/// character at or after [from] (the position right after the
/// `faAppError:` marker), honoring string literals and backslash escapes
/// so braces inside message/stack text never cut the record short. Null
/// when anything but whitespace precedes the record's `{` (a plain log
/// line mentioning the marker) or no balanced object exists (a truncated
/// record).
String? _balancedJsonObjectAfter(String line, int from) {
  var start = from;
  while (start < line.length && line[start].trim().isEmpty) {
    start++;
  }
  if (start >= line.length || line[start] != '{') return null;
  var depth = 0;
  var inString = false;
  for (var i = start; i < line.length; i++) {
    final ch = line[i];
    if (inString) {
      if (ch == r'\') {
        i++; // skip the escaped character verbatim
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return line.substring(start, i + 1);
    }
  }
  return null; // unbalanced — truncated record
}

/// One dedup-gate decision: whether a report is new enough to deliver,
/// and the bounded notice text when it is.
class JsAppErrorFeedback {
  const JsAppErrorFeedback({
    required this.deliver,
    required this.key,
    required this.notice,
  });

  /// True only for the FIRST occurrence of a key per source revision.
  final bool deliver;

  /// The dedup key this decision was made for.
  final String key;

  /// The bounded notice text (empty when [deliver] is false).
  final String notice;
}

/// A gated, bounded error report ready for session delivery.
class JsAppErrorNotice {
  const JsAppErrorNotice({
    required this.event,
    required this.appId,
    required this.surface,
    required this.sourceRevision,
    required this.notice,
  });

  final JsAppErrorEvent event;
  final String appId;

  /// Which viewport the error surfaced on: `app` (the default entry) or
  /// `tile` (a launcher-tile entry).
  final String surface;

  /// Content revision of the app source the error was captured against —
  /// the dedup boundary (an edit re-arms reporting).
  final String sourceRevision;

  /// The bounded, agent-readable notice text.
  final String notice;
}

/// The app-wide error channel (gh-1164). Engines report through the
/// gate; exactly one owner (AgentService) subscribes [onDeliver] and
/// routes notices into the app-bound session.
class JsAppErrorChannel {
  JsAppErrorChannel._();

  /// The app-wide channel: engines report here; the bound AgentService
  /// subscribes [onDeliver].
  static final JsAppErrorChannel instance = JsAppErrorChannel._();

  /// A detached channel for tests (the [instance] gate state is global).
  factory JsAppErrorChannel.test() => JsAppErrorChannel._();

  /// After this many unacted identical reports the per-app circuit
  /// breaker silences the key (the agent has the notice; spam adds
  /// nothing).
  static const breakerThreshold = 5;

  /// Bounded-notice caps (E2).
  static const maxMessageChars = 500;
  static const maxStackFrames = 5;
  static const maxStackChars = 800;

  final _deliverController = StreamController<JsAppErrorNotice>.broadcast();
  final Map<String, _AppGate> _gates = {};

  /// Delivered notices (broadcast). Agents subscribe at session bind.
  Stream<JsAppErrorNotice> get onDeliver => _deliverController.stream;

  /// Reports one captured error from app [appId]. Returns the gate
  /// decision: `null` when the circuit breaker has silenced this key;
  /// otherwise a [JsAppErrorFeedback] — `deliver` is true only for the
  /// first occurrence of the key at this [sourceRevision].
  JsAppErrorFeedback? reportAppError(
    JsAppErrorEvent event, {
    required String appId,
    required String surface,
    required String sourceRevision,
  }) {
    var gate = _gates[appId];
    if (gate == null || gate.revision != sourceRevision) {
      gate = _AppGate(revision: sourceRevision);
      _gates[appId] = gate;
    }
    final key = event.dedupKey;
    final seen = gate.counts[key] ?? 0;
    if (seen >= breakerThreshold) return null; // circuit breaker
    gate.counts[key] = seen + 1;
    if (seen > 0) {
      return JsAppErrorFeedback(deliver: false, key: key, notice: '');
    }
    final notice = _boundedNotice(event, appId: appId, surface: surface);
    return JsAppErrorFeedback(deliver: true, key: key, notice: notice);
  }

  /// Publishes one gated notice to subscribers. Returns false when
  /// nothing is subscribed (e.g. host without a session) — the record is
  /// still a log line there (E3: inert, never an exception).
  bool publish(JsAppErrorNotice notice) {
    if (!_deliverController.hasListener) return false;
    _deliverController.add(notice);
    return true;
  }

  /// Clears all gate state (tests, session rebinding).
  void disposeAndReset() {
    _gates.clear();
  }

  String _boundedNotice(
    JsAppErrorEvent event, {
    required String appId,
    required String surface,
  }) {
    final buf = StringBuffer()
      ..writeln("App '$appId' ($surface) reported a ${event.kind.name} error:")
      ..writeln(_cap(event.message, maxMessageChars));
    if (event.stack.isNotEmpty) {
      final frames = event.stack
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .take(maxStackFrames)
          .join('\n');
      buf.writeln(_cap(frames, maxStackChars));
    }
    return buf.toString().trimRight();
  }

  static String _cap(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}… [truncated]';

  /// Shared excerpt cap for LLM-facing failure text (gh-1164 review): the
  /// `open_app` pre-flight gate bounds its excerpts with the SAME cap the
  /// notices use, so a pathological JS error (huge payload, generated
  /// string) can never balloon the tool result the agent reads.
  static String capExcerpt(String text, [int max = maxMessageChars]) =>
      _cap(text, max);
}

class _AppGate {
  _AppGate({required this.revision});

  final String revision;
  final Map<String, int> counts = {};
}
