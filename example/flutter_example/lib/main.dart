import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/app_theme.dart';
import 'package:flutter_agent_example/chat_screen.dart';
import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_agent_example/provider_registry.dart';
import 'package:flutter_agent_example/settings.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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
  // One env for the whole app: the provider registry and the agent share it
  // (on web both ride the same IndexedDB snapshot; two envs would clobber
  // each other's persisted filesystem).
  final env = await createPlatformEnv();
  final registry = await ProviderRegistry.load(env);
  runApp(MyApp(env: env, registry: registry));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.env, this.registry});

  /// The shared execution env; `null` lets [AgentService.create] build the
  /// platform one (tests never reach that path).
  final ExecutionEnv? env;

  /// The persisted custom-provider registry; `null` falls back to an
  /// in-memory one (tests).
  final ProviderRegistry? registry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fah',
      theme: buildFahTheme(),
      home: SetupScreen(env: env, registry: registry),
    );
  }
}

/// First-run screen: bring-your-own-key connection form (see
/// [AgentSettingsForm]). Keys are kept in memory only; saved custom
/// providers persist (see [ProviderRegistry]) and are offered in the picker.
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key, this.env, this.registry});

  /// The shared execution env handed to [AgentService.create].
  final ExecutionEnv? env;

  /// The persisted custom-provider registry shown in the settings form.
  final ProviderRegistry? registry;

  Future<void> _connect(BuildContext context, AgentConfig config) async {
    final service = await AgentService.create(config: config, env: env);
    await service.initialize();
    if (!context.mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ChatScreen(service: service, registry: registry),
      ),
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
              registry: registry,
              onConnect: (config) => _connect(context, config),
            ),
          ),
        ),
      ),
    );
  }
}
