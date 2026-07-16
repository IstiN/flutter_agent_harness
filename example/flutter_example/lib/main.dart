import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/chat_screen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:wasm_run_flutter/wasm_run_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WasmRunLibrary.setUp(override: false);
  await dotenv.load(fileName: '.env');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fah',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const SetupScreen(),
    );
  }
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _keyController = TextEditingController(
    text: dotenv.isInitialized ? dotenv.env['OPENROUTER_API_KEY'] ?? '' : '',
  );
  final _modelController = TextEditingController(text: 'openai/gpt-4o-mini');
  final _urlController = TextEditingController(
    text: 'https://openrouter.ai/api/v1',
  );
  String _provider = 'openai-completions';
  bool _loading = false;
  String? _error;

  Future<void> _connect() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'API key is required');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = AgentConfig(
        providerKind: _provider,
        modelId: _modelController.text.trim(),
        baseUrl: _urlController.text.trim(),
        apiKey: key,
      );
      final service = await AgentService.create(config: config);
      await service.initialize();
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ChatScreen(service: service)),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to fah')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _keyController,
              decoration: const InputDecoration(labelText: 'API key'),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _modelController,
              decoration: const InputDecoration(labelText: 'Model id'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(labelText: 'Base URL'),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'openai-completions',
                  label: Text('OpenAI'),
                ),
                ButtonSegment(value: 'anthropic', label: Text('Anthropic')),
                ButtonSegment(value: 'google', label: Text('Google')),
              ],
              selected: <String>{_provider},
              onSelectionChanged: (value) =>
                  setState(() => _provider = value.first),
            ),
            const SizedBox(height: 24),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ElevatedButton(
              onPressed: _loading ? null : _connect,
              child: _loading
                  ? const CircularProgressIndicator()
                  : const Text('Start chat'),
            ),
          ],
        ),
      ),
    );
  }
}
