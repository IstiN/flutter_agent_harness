// Starts a DAP/1 hub on loopback. Run with:
//
//   dart run example/main.dart
//
// Then point any DAP/1 client at ws://127.0.0.1:8080 and enroll with
// the master secret printed below.

import 'package:dap_hub/dap_hub.dart';
import 'package:dap_hub/io.dart';

Future<void> main() async {
  final hub = DapHub(config: DapHubConfig(masterSecret: 'dev-master-secret'));
  final server = await DapHubServer.start(hub);
  print('DAP/1 hub listening on ${server.url}');
  print('master secret for enroll: dev-master-secret');
}
