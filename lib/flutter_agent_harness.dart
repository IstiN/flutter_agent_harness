/// Cross-platform AI agent harness for Dart and Flutter.
///
/// Ported architecture of pi-mono (`packages/ai` + `packages/agent`):
/// streaming provider adapters with an errors-as-events contract, an agent
/// loop with native tool calling, JSONL session persistence, and context
/// compaction. See GOAL.md for the full roadmap.
library;

export 'src/agent/agent.dart';
export 'src/agent/agent_loop.dart';
export 'src/agent/agent_tool.dart';
export 'src/agent/param_validator.dart';
export 'src/agent/tool_registry.dart';
export 'src/approval/approval.dart';
export 'src/approval/approval_hook.dart';
export 'src/approval/bash_interceptor.dart';
export 'src/cancel_token.dart';
export 'src/cli/agent_cli.dart';
export 'src/cli/prompt_templates.dart';
export 'src/compaction/compaction.dart';
export 'src/compaction/token_estimation.dart';
export 'src/context.dart';
export 'src/env/execution_env.dart';
export 'src/env/memory_execution_env.dart';
export 'src/env/secrets_execution_env.dart';
export 'src/event_stream.dart';
export 'src/exceptions.dart';
export 'src/model.dart';
export 'src/overflow.dart';
export 'src/providers/anthropic.dart';
export 'src/providers/google.dart';
export 'src/providers/openai_completions.dart';
export 'src/secrets/secret_redactor.dart';
export 'src/secrets/secrets_store.dart';
export 'src/session/session_record.dart';
export 'src/session/session_repo.dart';
export 'src/session/session_storage.dart';
export 'src/session/session_tree.dart';
export 'src/sse_decoder.dart';
export 'src/tools/builtin_tools.dart';
export 'src/tools/inspect_image.dart';
export 'src/plugins/plugin.dart';
export 'src/plugins/inspect_image_plugin.dart';
export 'src/prompt_tools/prompt_tools.dart';
export 'src/types.dart';
export 'src/usage_summary.dart';
