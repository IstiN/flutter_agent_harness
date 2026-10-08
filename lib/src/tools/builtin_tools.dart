/// Built-in agent tools for the CLI harness: file read, file write,
/// directory listing, and shell execution — all on top of the abstract
/// [ExecutionEnv] (never `dart:io` directly), so the same tools run against
/// [MemoryExecutionEnv] in tests or a browser-storage-backed env on web.
///
/// Shaped after pi-mono's built-in tools (`packages/coding-agent/src/core/
/// tools/{read,write,ls,bash}.ts`): same tool names (`read`, `write`, `ls`,
/// `bash`), same JSON-schema parameters, same output-truncation limits
/// ([defaultToolMaxLines] lines / [defaultToolMaxBytes] bytes, whichever is
/// hit first), and the same continuation notices so the model knows how to
/// page through truncated output.
///
/// The `edit` tool additionally ports oh-my-pi's hashline patch language
/// (`packages/hashline`): the model may pass a `patch` with `[path#TAG]`
/// section headers and `SWAP`/`DEL`/`INS` ops anchored on line numbers from
/// a hashline-mode `read`; a stale tag is rejected before any write. The
/// `read` tool's `hashline` parameter emits the numbered, tag-carrying
/// output those anchors cite, and both tools share one session
/// [HashlineSnapshotStore] (see [builtinTools]).
///
/// Deliberate divergences from the TypeScript originals:
///
/// - [readFileTool] image support runs in-process on `package:image` instead
///   of pi's Photon/WASM worker; the pipeline matches pi's
///   `utils/image-process.ts` (EXIF orientation baking, pass-through within
///   limits, PNG-then-JPEG byte-budget ladder at 4.5MB base64).
/// - The `bash` tool does not spill truncated output to a temp file (pi's
///   `fullOutputPath`); the truncation notice omits the path. Streaming
///   `onUpdate` partials and pi's `commandPrefix`/spawn hooks are also
///   deferred.
/// - [writeFileTool] reports UTF-8 bytes (pi reports `String.length`, which
///   is UTF-16 code units mislabeled as bytes).
/// - The hashline port covers the line-range ops only (`SWAP`/`DEL`/`INS.*`);
///   omp's tree-sitter block ops (`SWAP.BLK`/`DEL.BLK`/`INS.BLK.POST`), file
///   ops (`REM`/`MV`), boundary-repair leniency, and diff-based stale-anchor
///   auto-remap are skipped (see `lib/src/hashline/`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart';

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../approval/bash_interceptor.dart';
import '../approval/bash_shape_redaction.dart';
import '../cancel_token.dart';
import '../config/config_tool.dart';
import '../config/config_service.dart';
import '../cube/network_gate.dart';
import '../env/execution_env.dart';
import '../hashline/hashline.dart';
import '../lsp/lsp_tool.dart';
import '../mcp/mcp_manager.dart';
import '../model.dart';
import '../prompts/prompts.g.dart';
import '../skills/builtin_skills.dart';
import '../types.dart';
import '../web_search/web_search.dart';
import 'archive_reader.dart';
import 'misuse_policy.dart';
import 'read_selector.dart';
import 'password_prompt.dart';
import 'shell_jobs.dart';
import 'sqlite/sqlite_reader.dart';
import 'tool_format.dart';

export 'tool_format.dart' show formatToolSize;

part 'builtin_tools_truncate.dart';
part 'builtin_tools_image.dart';
part 'builtin_tools_read.dart';
part 'builtin_tools_read_archive.dart';
part 'builtin_tools_read_sqlite.dart';
part 'builtin_tools_write_edit.dart';
part 'builtin_tools_ls.dart';
part 'builtin_tools_bash.dart';

/// Default line limit for tool output truncation (pi's `DEFAULT_MAX_LINES`).
const defaultToolMaxLines = 2000;

/// Default byte limit for tool output truncation (pi's `DEFAULT_MAX_BYTES`).
const defaultToolMaxBytes = 50 * 1024;

/// Default entry cap for the `ls` tool (pi's `DEFAULT_LIMIT`).
const defaultLsEntryLimit = 500;

/// Maximum shell timeout: pi clamps at the int32 max milliseconds.
const _maxTimeoutMs = 2147483647;

/// "Unbounded" line cap for truncation helpers: 2^62 as a literal because
/// dart2js shifts are 32-bit — `1 << 62` evaluates to 0 on web, which would
/// truncate everything (issue #1074).
const _unboundedMaxLines = 0x4000000000000000;

/// Transient-failure retries for foreground bash runs: timeout-class
/// failures (a hung transport, or the model's own per-call cap) are
/// retried up to this many times — 3 attempts total — before the error
/// surfaces. Aborts and real command failures never retry.
const bashToolMaxRetries = 2;

/// Backoff between bash retry attempts.
const _bashRetryBackoff = Duration(seconds: 1);

/// Output-silence window before a pending password-ask match fires the
/// sheet (issue #367); parameterized for tests.
const _bashPasswordQuiet = Duration(milliseconds: 250);

/// Creates the four built-in tools ([readFileTool], [writeFileTool],
/// [listDirTool], [shellTool]) bound to [env].
///
/// [snapshots] is the session-scoped hashline snapshot store shared by the
/// `read` and `edit` tools: hashline-mode reads mint the content tags that
/// hashline edit patches cite, and edits mint fresh tags for follow-ups.
/// Defaults to a fresh store — one per [builtinTools] call, i.e. one per
/// agent session.
///
/// When [webSearch] is provided, the `web_search` and `web_fetch` tools are
/// registered with it (provider chain resolved from the config; keyless
/// DuckDuckGo works with all defaults).
///
/// When [networkGate] is provided, it gates every model-invoked web egress
/// of the web tools (issue #682): `null` — no cube — keeps the requests on
/// the unwrapped client, byte-identical to pre-gate runs.
///
/// When [sqlite] is provided, the `read` tool resolves SQLite database
/// targets (`data.db:table`); without an engine (e.g. web hosts, where FFI
/// is unavailable) such reads return a clean "not supported" note.
///
/// When [lsp] is provided, the `lsp` tool is registered (diagnostics /
/// definition / references / rename backed by a language server). Only
/// process-capable hosts (CLI/desktop) pass it — the process transport
/// factory lives in `lib/io.dart`; web/stub construction leaves the tool
/// out.
///
/// When [config] is provided, the `config` tool is registered (the
/// `check|path|get|set` ops over [ConfigService] — issue #29 S3). Hosts
/// without a config service (tests of individual tools, minimal embeds)
/// leave it out.
///
/// When [mcp] is provided, the tools of currently CONNECTED MCP servers are
/// included (as `mcp__<server>__<tool>`); servers connect in the background
/// after startup, so the host must additionally listen to
/// `McpManager.onChanged` to re-register late arrivals (see `AgentCli`).
///
/// [model] is forwarded to [readFileTool] for the non-vision image note.
List<AgentTool> builtinTools(
  ExecutionEnv env, {
  HashlineSnapshotStore? snapshots,
  WebSearchConfig? webSearch,
  CubeNetworkGate? networkGate,
  ConfigService? config,
  Model? Function()? model,
  SqliteEngine? sqlite,
  LspToolConfig? lsp,
  McpManager? mcp,
  ShellJobRegistry? shellJobs,
  PasswordPromptCallback? onPasswordPrompt,
}) {
  final store = snapshots ?? HashlineSnapshotStore();
  return [
    readFileTool(env, snapshots: store, model: model, sqlite: sqlite),
    writeFileTool(env),
    editFileTool(env, snapshots: store),
    listDirTool(env),
    shellTool(env, jobs: shellJobs, onPasswordPrompt: onPasswordPrompt),
    if (shellJobs != null) bashJobTool(shellJobs),
    if (lsp != null) lspTool(env, config: lsp),
    if (webSearch != null) ...[
      webSearchTool(config: webSearch.withNetworkGate(networkGate)),
      webFetchTool(config: webSearch.withNetworkGate(networkGate)),
    ],
    if (config != null) configTool(config),
    ...?mcp?.tools,
  ];
}
