import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'native_test_guard.dart';

void main() {
  group('debug raw logs', skip: quickJsBridgeAvailable ? false : kQuickJsBridgeUnavailable, () {
    testWidgets('raw console logs', (tester) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/demo/widget.js', 'throw new Error("load blew up");');
        final engine = JsAppEngine(
          app: JsAppInfo.fromManifest(const {'id': 'demo', 'name': 'Demo'}, bundled: false, fallbackId: 'demo'),
          env: env,
          permissions: const AppPermissions(),
        );
        await engine.start();
        await Future<void>.delayed(const Duration(seconds: 1));
        for (final l in engine.peekLogs()) {
          final msg = '${l['msg']}';
          print('RAW>>${msg.replaceAll('\n', '<NL>').replaceAll('\t', '<TAB>')}<<');
        }
        await engine.dispose();
      });
    });
  });
}
