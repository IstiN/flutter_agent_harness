/// gh-1409 app-host publication tests (review round 2):
///
/// - BLOCKING: `AgentService.create` must publish the boot discovery's
///   enabled skills ([AgentService.operativeSkills]) — before the fix the
///   enabled-skills element of `_discoverPromptSuffix` was dropped and the
///   whole pin mechanism was a silent no-op in the app host until a
///   settings change re-published it.
/// - P4/P5/P6: pin notices reach the app log — never silent.
library;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/app_log.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

AgentConfig _config() => AgentConfig(
  providerKind: 'openai-completions',
  modelId: 'test-model',
  baseUrl: 'https://example.test',
  apiKey: '[REDACTED:Sensitive Value]',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'create() publishes the discovered operative skills at boot (review '
    'round 2 BLOCKING — the app host is not silently inert)',
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.createDir('/work/.fah/skills/fleet');
      await env.writeFile(
        '/work/.fah/skills/fleet/SKILL.md',
        '---\n'
            'name: fleet\n'
            'description: fleet skill.\n'
            'operative:\n'
            '  - "use fleet_sweep.sh"\n'
            '---\n'
            'Body.\n',
      );
      final service = await AgentService.create(
        config: _config(),
        env: env,
        streamFunction: _singleTextResponse('ok'),
      );
      addTearDown(service.dispose);

      // The pin registry's source set must be live at boot: before this
      // fix only a consent/toggle change published it, so app requests
      // and app compaction prompts never carried pins.
      expect(
        service.operativeSkills.map((skill) => skill.name),
        contains('fleet'),
      );
    },
  );

  test(
    'pin notices reach the app log, never silent (P4/P5/P6, review '
    'round 2)',
    () async {
      AppLog.reset();
      final service = await AgentService.create(
        config: _config(),
        env: MemoryExecutionEnv(cwd: '/'),
        streamFunction: _singleTextResponse('ok'),
      );
      addTearDown(service.dispose);

      expect(operativePinNotice, isNotNull);
      operativePinNotice!(
        'skill pin restored from registry: "use fleet_sweep.sh" - pinned '
        'from skill `fleet`',
      );
      expect(AppLog.dump(), contains('use fleet_sweep.sh'));
    },
  );
}
