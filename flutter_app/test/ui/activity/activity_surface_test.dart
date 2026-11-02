import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/activity/activity_surface.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

AgentService _service(ExecutionEnv env) => AgentService(
  agent: Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test',
      baseUrl: 'https://example.com',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    systemPrompt: 'You are Fa.',
    streamFunction: (model, context, {cancelToken}) =>
        AssistantMessageEventStream()..end(),
    toolRegistry: ToolRegistry(const []),
  ),
  env: env,
  sessionsRoot: '/sessions',
  config: AgentConfig(
    providerKind: 'test',
    modelId: 'test-model',
    baseUrl: 'https://example.com',
    apiKey: '',
  ),
);

void main() {
  test('token notifications coalesce to activity run boundaries', () {
    final env = MemoryExecutionEnv();
    final service = _service(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('session', service);
    final controller = ActivityController(manager: manager);
    addTearDown(controller.dispose);
    addTearDown(service.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);

    service.isStreaming = true;
    service.notifyListeners();
    expect(notifications, 1, reason: 'run start updates Running');

    for (var delta = 0; delta < 20; delta++) {
      service.notifyListeners();
    }
    expect(
      notifications,
      1,
      reason: 'partial content does not rebuild every activity row',
    );

    service.isStreaming = false;
    service.notifyListeners();
    expect(notifications, 2, reason: 'run end refreshes the final preview');
  });
}
