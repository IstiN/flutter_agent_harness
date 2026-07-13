/// Registry of executable tools: registration, lookup, and the
/// [ToolExecutor] adapter that plugs into the agent loop.
///
/// Shaped after pi-mono's tool handling (`packages/agent`): tools are looked
/// up by name, arguments are validated against the tool's schema before
/// execution, and duplicate names are rejected at registration time
/// (pi's harness throws `invalid_argument` on duplicates).
///
/// Minimal wiring with the existing [Agent] API:
///
/// ```dart
/// final registry = ToolRegistry([myTool]);
/// final agent = Agent(
///   model: model,
///   streamFunction: myStreamFunction,
///   toolRegistry: registry, // sets tools + toolExecutor
/// );
/// ```
///
/// or, equivalently, the manual form:
///
/// ```dart
/// Agent(
///   tools: registry.tools,
///   toolExecutor: registry.executor,
///   ...
/// )
/// ```
library;

import '../cancel_token.dart';
import '../context.dart';
import '../exceptions.dart';
import '../types.dart';
import 'agent_loop.dart';
import 'agent_tool.dart';
import 'param_validator.dart';

/// A named collection of [AgentTool]s with a ready-made [executor] for the
/// agent loop.
///
/// The registry is mutable: tools can be registered and unregistered at any
/// time, and [executor] always consults the live registry. The agent loop
/// additionally checks tool existence against [Context.tools], so a tool
/// only executes when it is both registered here and listed in the agent
/// state's `tools` for that run.
final class ToolRegistry {
  /// Creates a registry pre-populated with [tools]. Throws [ConfigException]
  /// on a duplicate or empty tool name.
  ToolRegistry([Iterable<AgentTool> tools = const []]) {
    registerAll(tools);
  }

  final _tools = <String, AgentTool>{};

  /// Number of registered tools.
  int get length => _tools.length;

  /// Names of all registered tools, in registration order.
  List<String> get names => List.unmodifiable(_tools.keys);

  /// All registered tools as provider-facing [Tool]s, ready for
  /// [Context.tools] / [AgentState.tools]. Unmodifiable snapshot.
  List<Tool> get tools => List.unmodifiable(_tools.values);

  /// All registered [AgentTool]s. Unmodifiable snapshot.
  List<AgentTool> get agentTools => List.unmodifiable(_tools.values);

  /// Registers [tool]. Throws [ConfigException] if the name is empty or
  /// already registered (pi duplicate-name semantics).
  void register(AgentTool tool) {
    if (tool.name.isEmpty) {
      throw const ConfigException('Tool name must not be empty');
    }
    if (_tools.containsKey(tool.name)) {
      throw ConfigException('Duplicate tool name: ${tool.name}');
    }
    _tools[tool.name] = tool;
  }

  /// Registers every tool in [tools].
  void registerAll(Iterable<AgentTool> tools) {
    for (final tool in tools) {
      register(tool);
    }
  }

  /// Removes the tool with [name]; returns whether one was registered.
  bool unregister(String name) => _tools.remove(name) != null;

  /// Looks up a tool by name; `null` when not registered.
  AgentTool? lookup(String name) => _tools[name];

  /// Whether a tool with [name] is registered.
  bool contains(String name) => _tools.containsKey(name);

  /// Looks up a tool by name, throwing [ToolNotFoundException] when missing.
  AgentTool operator [](String name) {
    return lookup(name) ?? (throw ToolNotFoundException(name));
  }

  /// A [ToolExecutor] that validates arguments against the tool's schema
  /// and dispatches to the tool's [AgentTool.execute].
  ///
  /// Failure contract (pi semantics): an unknown tool throws
  /// [ToolNotFoundException], invalid arguments throw
  /// [ToolValidationException] — and the tool is not executed. The loop
  /// converts these throws into error [ToolResultMessage]s, so nothing
  /// escapes the loop as an exception.
  ToolExecutor get executor => _execute;

  Future<ToolExecutionResult> _execute(
    ToolCall toolCall,
    CancelToken? cancelToken,
    ToolUpdateCallback? onUpdate,
  ) async {
    final tool = lookup(toolCall.name);
    if (tool == null) throw ToolNotFoundException(toolCall.name);
    final arguments = validateToolArguments(
      arguments: toolCall.arguments,
      schema: tool.parameters,
      toolName: tool.name,
    );
    return tool.execute(arguments, cancelToken, onUpdate);
  }
}
