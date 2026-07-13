/// Cross-platform AI agent harness for Dart and Flutter.
///
/// Ported architecture of pi-mono (`packages/ai` + `packages/agent`):
/// streaming provider adapters with an errors-as-events contract, an agent
/// loop with native tool calling, JSONL session persistence, and context
/// compaction. See GOAL.md for the full roadmap.
library;

export 'src/agent/agent_loop.dart';
export 'src/cancel_token.dart';
export 'src/context.dart';
export 'src/event_stream.dart';
export 'src/exceptions.dart';
export 'src/model.dart';
export 'src/overflow.dart';
export 'src/providers/anthropic.dart';
export 'src/providers/google.dart';
export 'src/providers/openai_completions.dart';
export 'src/sse_decoder.dart';
export 'src/types.dart';
export 'src/usage_summary.dart';
