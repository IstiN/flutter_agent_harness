/// Scripted OpenAI-compatible mock LLM server for integration tests.
///
/// ```dart
/// import 'package:fa_llm_mock/fa_llm_mock.dart';
///
/// final script = MockLlmScript.parseFile('mock_script.yaml');
/// final server = await MockLlmServer.start(script: script);
/// // point the CLI/app under test at server.baseUrl ...
/// await server.stop();
/// ```
///
/// See the package README for the config document reference.
library;

export 'src/mock_llm_script.dart';
export 'src/mock_llm_server.dart';
