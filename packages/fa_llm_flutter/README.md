# fa_llm_flutter

Flutter-specific LLM providers that extend the pure-Dart [`fa_llm`](../fa_llm)
package.

This package is intended for providers that require Flutter-only plugins, such
as on-device inference through [`flutter_gemma`](https://pub.dev/packages/flutter_gemma).

## Providers

### `FlutterGemmaProvider`

Wraps a `flutter_gemma` [InferenceChat] so it can be used through the
`LlmProvider` interface.

```dart
import 'package:fa_llm_flutter/fa_llm_flutter.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as gemma;

final inferenceChat = await gemma.FlutterGemma().createChat(
  modelType: gemma.ModelType.gemma4,
  tools: [],
);

final provider = FlutterGemmaProvider(
  defaultModel: 'gemma4-31b',
  chat: inferenceChat,
);

final response = await provider.chat('Explain CRAP in software testing.');
print(response);
```

## Testing

Because this package depends on Flutter plugins, most tests should be run with
`flutter test` rather than `dart test`.
