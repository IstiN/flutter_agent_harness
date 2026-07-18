import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/app_theme.dart';
import 'package:flutter_agent_example/chat_screen.dart';
import 'package:flutter_agent_example/settings.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'wasm_setup_stub.dart' if (dart.library.io) 'wasm_setup_io.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setUpWasmRuntime();
  try {
    await dotenv.load(fileName: '.env');
  } on Object {
    // .env is intentionally not committed. Values can be supplied via
    // --dart-define instead.
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fah',
      theme: buildFahTheme(),
      home: const SetupScreen(),
    );
  }
}

/// First-run screen: bring-your-own-key connection form (see
/// [AgentSettingsForm]). Nothing entered here is persisted — the app keeps
/// keys in memory only, so a reload returns to this screen.
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  Future<void> _connect(BuildContext context, AgentConfig config) async {
    final service = await AgentService.create(config: config);
    await service.initialize();
    if (!context.mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ChatScreen(service: service)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to fah')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: AgentSettingsForm(
              onConnect: (config) => _connect(context, config),
            ),
          ),
        ),
      ),
    );
  }
}
