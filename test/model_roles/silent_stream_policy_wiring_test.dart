// SilentStreamPolicy wired into the roles chain (gh-1395 AC4 IT): the
// ModelRolesResolver's chain entries ride the stall ladder — backoff
// (resolver's injectable sleeper = the fake clock), key rotation on the
// ring after the 2nd stall, the smol-role takeover attempt after the 3rd.
import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/event_stream.dart';
import 'package:flutter_agent_harness/src/model_roles/model_resolver.dart';
import 'package:flutter_agent_harness/src/model_roles/roles_config.dart';
import 'package:flutter_agent_harness/src/providers/transient_retry_stream.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

const idleError =
    'TimeoutException: no events from the endpoint for 300s '
    '(stream idle timeout)';

/// Stream factory the resolver builds entries with: every attempt is
/// recorded as `role:attemptKey`; attempts stall until [stallsPerKey]
/// consecutive stalls have happened on the SAME key, then serve.
StreamFunction Function(String kind, String apiKey) recordingFactory(
  List<String> log, {
  required int stallsTotal,
}) {
  var stalls = 0;
  return (kind, apiKey) {
    return (model, context, {cancelToken}) {
      log.add(apiKey);
      final out = AssistantMessageEventStream();
      if (stalls < stallsTotal) {
        stalls++;
        out.push(
          ErrorEvent(
            reason: StopReason.error,
            error: AssistantMessage(
              content: const [],
              api: model.api,
              provider: model.provider,
              model: model.id,
              usage: Usage.zero,
              stopReason: StopReason.error,
              errorMessage: idleError,
              timestamp: DateTime.now(),
            ),
          ),
        );
      } else {
        out.push(
          DoneEvent(
            reason: StopReason.stop,
            message: AssistantMessage(
              content: const [],
              api: model.api,
              provider: model.provider,
              model: model.id,
              usage: Usage.zero,
              stopReason: StopReason.stop,
              timestamp: DateTime.now(),
            ),
          ),
        );
      }
      out.end();
      return out;
    };
  };
}

void main() {
  test('AC4 IT: 3 stalls through the roles chain → backoff ladder, key '
      'rotation after the 2nd, smol takeover after the 3rd', () async {
    final log = <String>[];
    final notes = <String>[];
    final savedNotice = transientRetryNotice;
    transientRetryNotice = (attempt, max, delay, reason) => notes.add(reason);
    addTearDown(() => transientRetryNotice = savedNotice);
    final slept = <Duration>[];
    final config = ModelRolesConfig(
      roles: {
        'default': [ModelRef(provider: 'anthropic', modelId: 'claude-main')],
        'smol': [ModelRef(provider: 'anthropic', modelId: 'claude-smol')],
      },
    );
    final resolver = ModelRolesResolver(
      config: config,
      secrets: const {
        'ANTHROPIC_API_KEY': 'key-1',
        'ANTHROPIC_API_KEY_2': 'key-2',
      },
      sleeper: (delay, _) async {
        slept.add(delay);
        return true;
      },
      streamFactory: recordingFactory(log, stallsTotal: 3),
    );
    final wrapper = resolver.streamForRole('default');
    final events = await wrapper
        .call(wrapper.currentModel, const Context(messages: []))
        .toList();

    // The ladder: 2 stalls on key-1, rotation, 1 stall on key-2, then the
    // smol takeover serves the turn.
    expect(log.take(3), [
      'key-1',
      'key-1',
      'key-2',
    ], reason: 'the rotation rebuilt the stream on the 2nd stall');
    expect(slept, [
      const Duration(seconds: 5),
      const Duration(seconds: 10),
      const Duration(seconds: 20),
    ], reason: 'every ladder delay within the [5,60]s bound, doubling');
    expect(
      events.last,
      isA<DoneEvent>(),
      reason: 'the smol takeover delivered the turn',
    );
    expect(
      (events.last as DoneEvent).message.model,
      'claude-smol',
      reason: 'the takeover stream was the smol role\'s chain',
    );
    expect(
      notes.any((m) => m.contains('smol-role takeover')),
      isTrue,
      reason: 'the takeover is announced on the retry-notice surface',
    );
    expect(notes.any((m) => m.contains('rotating API key')), isTrue);
  });

  test('a healthy chain never sleeps (E2-class) and the queue/roles '
      'behavior is untouched', () async {
    final log = <String>[];
    final slept = <Duration>[];
    final config = ModelRolesConfig(
      roles: {
        'default': [ModelRef(provider: 'anthropic', modelId: 'claude-main')],
      },
    );
    final resolver = ModelRolesResolver(
      config: config,
      secrets: const {'ANTHROPIC_API_KEY': 'key-1'},
      sleeper: (delay, _) async {
        slept.add(delay);
        return true;
      },
      streamFactory: recordingFactory(log, stallsTotal: 0),
    );
    final wrapper = resolver.streamForRole('default');
    final events = await wrapper
        .call(wrapper.currentModel, const Context(messages: []))
        .toList();
    expect(slept, isEmpty);
    expect(events.last, isA<DoneEvent>());
  });

  test('E5 IT: a single-key ring SKIPS rotation (logged) and still '
      'escalates to the smol takeover — the value-vs-name rotation anchor '
      'cannot false-positive a rotate (review round 1)', () async {
    final log = <String>[];
    final notes = <String>[];
    final savedNotice = transientRetryNotice;
    transientRetryNotice = (attempt, max, delay, reason) => notes.add(reason);
    addTearDown(() => transientRetryNotice = savedNotice);
    final slept = <Duration>[];
    final config = ModelRolesConfig(
      roles: {
        'default': [ModelRef(provider: 'anthropic', modelId: 'claude-main')],
        'smol': [ModelRef(provider: 'anthropic', modelId: 'claude-smol')],
      },
    );
    final resolver = ModelRolesResolver(
      config: config,
      secrets: const {'ANTHROPIC_API_KEY': 'key-1'},
      sleeper: (delay, _) async {
        slept.add(delay);
        return true;
      },
      streamFactory: recordingFactory(log, stallsTotal: 3),
    );
    final wrapper = resolver.streamForRole('default');
    final events = await wrapper
        .call(wrapper.currentModel, const Context(messages: []))
        .toList();
    expect(
      log.take(3),
      everyElement('key-1'),
      reason: 'no phantom rotation: one key, the same credential retries',
    );
    expect(
      notes.any((m) => m.contains('rotation unavailable')),
      isTrue,
      reason: 'E5: the skip is logged, not silent',
    );
    expect(
      events.last,
      isA<DoneEvent>(),
      reason: 'the smol takeover still serves the turn',
    );
    expect(
      slept,
      [
        const Duration(seconds: 5),
        const Duration(seconds: 10),
        const Duration(seconds: 20),
      ],
      reason:
          'the ladder escalates across calls (the policy is '
          'session-scoped per chain entry — review round 1: not reset '
          'per fallback attempt)',
    );
  });
}
