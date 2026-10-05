import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('raw log lines', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', 'throw new Error("load blew up");');
      final engine = JsAppEngine(
        app: JsAppInfo.fromManifest(const {'id': 'demo', 'name': 'Demo'}, bundled: false, fallbackId: 'demo'),
        env: env,
        permissions: const AppPermissions(),
        onLog: (line) => print('RAWLOG>>${line.replaceAll('\n', '<NL>')}<<'),
      );
      await engine.start();
      await Future<void>.delayed(const Duration(seconds: 1));
      await engine.dispose();
    });
  });
}
