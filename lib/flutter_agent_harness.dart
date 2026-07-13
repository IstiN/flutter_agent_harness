/// Cross-platform AI agent harness for Dart and Flutter.
///
/// Ported architecture of pi-mono (`packages/ai` + `packages/agent`):
/// streaming provider adapters with an errors-as-events contract, an agent
/// loop with native tool calling, JSONL session persistence, and context
/// compaction. See GOAL.md for the full roadmap.
library;

export 'src/cancel_token.dart';
export 'src/event_stream.dart';
export 'src/sse_decoder.dart';
export 'src/types.dart';
