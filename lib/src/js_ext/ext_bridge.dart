/// Validated commit model (section 6 of the js-extension design): the typed
/// shapes produced by [parseExtCommit] from the `__extCommit()` payload a JS
/// extension returns after its `main.js` has been evaluated.
library;

import 'ext_manifest.dart' show ExtHookEvent, extHookEventFromJsonName;
import 'ext_protocol.dart' show ExtProtocolException, ExtTiers;

/// A tool declaration must match this pattern.
const String kExtToolNamePattern = r'^[a-z][a-z0-9_]{2,63}$';

/// A slash-command name (stored without the leading `/`) and a provider-flow
/// id must match this pattern.
const String kExtSlashNamePattern = r'^[a-z0-9-]{1,31}$';

/// One tool registered by an extension.
final class ExtToolDef {
  final String name;

  /// Empty when the extension omitted it.
  final String description;

  /// JSON-schema-ish parameter object; `{}` when absent.
  final Map<String, dynamic> parameters;

  /// One of [ExtTiers.all]; `exec` when the extension omitted it.
  final String tier;

  /// Integer handle into the JS `__extHandles` table; invoke it with
  /// `__extInvoke(handle, args)`.
  final int handle;

  const ExtToolDef({
    required this.name,
    this.description = '',
    this.parameters = const {},
    this.tier = ExtTiers.exec,
    required this.handle,
  });
}

/// One lifecycle hook registered by an extension.
final class ExtHookDef {
  final ExtHookEvent event;
  final int handle;

  const ExtHookDef({required this.event, required this.handle});
}

/// One slash command registered by an extension.
final class ExtSlashDef {
  /// Stored WITHOUT the leading `/`.
  final String name;
  final String description;
  final int handle;

  const ExtSlashDef({
    required this.name,
    this.description = '',
    required this.handle,
  });
}

/// One input field of a provider flow.
final class ExtFlowField {
  final String name;
  final String label;
  final bool secret;

  const ExtFlowField({
    required this.name,
    required this.label,
    this.secret = false,
  });
}

/// One provider flow registered via `jsr.ext.menus.registerProviderFlow`.
final class ExtFlowDef {
  final String id;
  final String title;
  final String description;
  final List<ExtFlowField> fields;
  final int handle;

  const ExtFlowDef({
    required this.id,
    this.title = '',
    this.description = '',
    required this.fields,
    required this.handle,
  });
}

/// Everything an extension registered at commit time.
final class ExtCommit {
  final List<ExtToolDef> tools;
  final List<ExtHookDef> hooks;
  final List<ExtSlashDef> slash;
  final List<ExtFlowDef> flows;

  const ExtCommit({
    this.tools = const [],
    this.hooks = const [],
    this.slash = const [],
    this.flows = const [],
  });
}

/// Parses the decoded-JSON payload `__extCommit()` returned (a `Map` of
/// `tools`/`hooks`/`slash`/`flows` lists). Accumulates EVERY problem — wrong
/// types, bad names, unknown hook events, empty flow field lists — into a
/// single [ExtProtocolException] listing them all (`'; '`-joined); never
/// half-loads. Absent `tools`/`hooks`/`slash`/`flows` keys mean "registered
/// nothing", not an error.
ExtCommit parseExtCommit(Object? payload) {
  if (payload is! Map) {
    throw const ExtProtocolException(
      'invalid extension commit: payload must be a JSON object',
    );
  }
  final problems = <String>[];
  final tools = _parseDefs(payload['tools'], 'tools', problems, _parseTool);
  final hooks = _parseDefs(payload['hooks'], 'hooks', problems, _parseHook);
  final slash = _parseDefs(payload['slash'], 'slash', problems, _parseSlash);
  final flows = _parseDefs(payload['flows'], 'flows', problems, _parseFlow);
  if (problems.isNotEmpty) {
    throw ExtProtocolException(
      'invalid extension commit: ${problems.join('; ')}',
    );
  }
  return ExtCommit(tools: tools, hooks: hooks, slash: slash, flows: flows);
}

typedef _DefParser<T> =
    T? Function(Map<Object?, Object?> entry, String at, List<String> problems);

/// Parses a top-level commit list; `null` (absent key) means empty.
List<T> _parseDefs<T>(
  Object? value,
  String kind,
  List<String> problems,
  _DefParser<T> parseEntry,
) {
  if (value == null) return const [];
  if (value is! List) {
    problems.add('$kind must be a list');
    return const [];
  }
  final defs = <T>[];
  for (var i = 0; i < value.length; i++) {
    final entry = value[i];
    if (entry is! Map) {
      problems.add('$kind[$i] must be a JSON object');
      continue;
    }
    final def = parseEntry(entry, '$kind[$i]', problems);
    if (def != null) defs.add(def);
  }
  return defs;
}

String? _stringField(
  Map<Object?, Object?> entry,
  String key,
  String at, {
  required List<String> problems,
  bool required = false,
  bool requiredNonEmpty = false,
}) {
  final value = entry[key];
  if (value == null) {
    if (required || requiredNonEmpty) {
      problems.add('$at: $key is required');
    }
    return required || requiredNonEmpty ? null : '';
  }
  if (value is! String || (requiredNonEmpty && value.isEmpty)) {
    problems.add('$at: $key must be a non-empty string');
    return null;
  }
  return value;
}

int? _handleField(
  Map<Object?, Object?> entry,
  String at,
  List<String> problems,
) {
  final value = entry['handle'];
  if (value is! int) {
    problems.add('$at: handle must be an integer');
    return null;
  }
  return value;
}

ExtToolDef? _parseTool(
  Map<Object?, Object?> entry,
  String at,
  List<String> problems,
) {
  final name = _stringField(
    entry,
    'name',
    at,
    problems: problems,
    requiredNonEmpty: true,
  );
  final handle = _handleField(entry, at, problems);
  final description =
      _stringField(entry, 'description', at, problems: problems) ?? '';
  var parameters = const <String, dynamic>{};
  final rawParameters = entry['parameters'];
  if (rawParameters != null) {
    if (rawParameters is Map) {
      parameters = rawParameters.map((k, v) => MapEntry(k.toString(), v));
    } else {
      problems.add('$at: parameters must be a JSON object');
    }
  }
  var tier = ExtTiers.exec;
  final rawTier = entry['tier'];
  if (rawTier != null) {
    if (rawTier is String && ExtTiers.all.contains(rawTier)) {
      tier = rawTier;
    } else {
      problems.add(
        '$at: tier must be one of ${ExtTiers.all.toList().join('|')}',
      );
    }
  }
  if (name == null || handle == null) return null;
  if (!RegExp(kExtToolNamePattern).hasMatch(name)) {
    problems.add('$at: tool name "$name" must match $kExtToolNamePattern');
    return null;
  }
  return ExtToolDef(
    name: name,
    description: description,
    parameters: parameters,
    tier: tier,
    handle: handle,
  );
}

ExtHookDef? _parseHook(
  Map<Object?, Object?> entry,
  String at,
  List<String> problems,
) {
  final rawEvent = entry['event'];
  final event = rawEvent is String ? extHookEventFromJsonName(rawEvent) : null;
  if (event == null) {
    problems.add('$at: event must be a known hook event name');
  }
  final handle = _handleField(entry, at, problems);
  if (event == null || handle == null) return null;
  return ExtHookDef(event: event, handle: handle);
}

ExtSlashDef? _parseSlash(
  Map<Object?, Object?> entry,
  String at,
  List<String> problems,
) {
  final name = _stringField(
    entry,
    'name',
    at,
    problems: problems,
    requiredNonEmpty: true,
  );
  final handle = _handleField(entry, at, problems);
  final description =
      _stringField(entry, 'description', at, problems: problems) ?? '';
  if (name == null || handle == null) return null;
  if (!RegExp(kExtSlashNamePattern).hasMatch(name)) {
    problems.add(
      '$at: slash name "$name" must match $kExtSlashNamePattern (no leading slash)',
    );
    return null;
  }
  return ExtSlashDef(name: name, description: description, handle: handle);
}

ExtFlowDef? _parseFlow(
  Map<Object?, Object?> entry,
  String at,
  List<String> problems,
) {
  final id = _stringField(
    entry,
    'id',
    at,
    problems: problems,
    requiredNonEmpty: true,
  );
  final handle = _handleField(entry, at, problems);
  final title = _stringField(entry, 'title', at, problems: problems) ?? '';
  final description =
      _stringField(entry, 'description', at, problems: problems) ?? '';
  // Always parsed so a broken id does not hide field problems.
  final fields = _parseFields(entry['fields'], '$at.fields', problems);
  if (id == null || handle == null) return null;
  if (!RegExp(kExtSlashNamePattern).hasMatch(id)) {
    problems.add('$at: flow id "$id" must match $kExtSlashNamePattern');
    return null;
  }
  if (fields == null) return null;
  return ExtFlowDef(
    id: id,
    title: title,
    description: description,
    fields: fields,
    handle: handle,
  );
}

List<ExtFlowField>? _parseFields(
  Object? value,
  String at,
  List<String> problems,
) {
  if (value is! List || value.isEmpty) {
    problems.add('$at must be a non-empty list');
    return null;
  }
  final fields = <ExtFlowField>[];
  for (var i = 0; i < value.length; i++) {
    final raw = value[i];
    if (raw is! Map) {
      problems.add('$at[$i] must be a JSON object');
      continue;
    }
    final name = _stringField(
      raw,
      'name',
      '$at[$i]',
      problems: problems,
      requiredNonEmpty: true,
    );
    final label = _stringField(
      raw,
      'label',
      '$at[$i]',
      problems: problems,
      requiredNonEmpty: true,
    );
    if (name == null || label == null) continue;
    fields.add(
      ExtFlowField(name: name, label: label, secret: raw['secret'] == true),
    );
  }
  return fields;
}
