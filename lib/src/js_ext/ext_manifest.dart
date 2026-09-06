/// Manifest model for JS extensions: extension kinds, hook events, platform
/// tags, capability declarations, and a strict parser that accumulates every
/// problem into a single [ExtManifestException] (never half-loads).
library;

/// Pattern a valid extension name must match (`^[a-z][a-z0-9-]{1,63}$`).
const String kExtNamePattern = r'^[a-z][a-z0-9-]{1,63}$';

/// What form an extension takes.
enum ExtKind {
  /// Headless CLI-only extension.
  cliExtension,

  /// Widget-style extension (the default for manifests without a `kind`).
  widget,

  /// Both CLI and widget surfaces.
  hybrid,
}

/// JSON name of [kind] (`'cli-extension'` | `'widget'` | `'hybrid'`).
String extKindJson(ExtKind kind) => switch (kind) {
  ExtKind.cliExtension => 'cli-extension',
  ExtKind.widget => 'widget',
  ExtKind.hybrid => 'hybrid',
};

/// Parses a JSON kind name; returns `null` for unknown values.
ExtKind? extKindFromJsonName(String value) => switch (value) {
  'cli-extension' => ExtKind.cliExtension,
  'widget' => ExtKind.widget,
  'hybrid' => ExtKind.hybrid,
  _ => null,
};

/// Lifecycle events an extension can hook into.
enum ExtHookEvent {
  /// Fired when a session starts.
  sessionStart,

  /// Fired when a session ends.
  sessionEnd,

  /// Fired before a tool call executes (can block).
  beforeToolCall,

  /// Fired after a tool call completed (can append output).
  afterToolCall,

  /// Fired while preparing the next turn (can enqueue follow-ups).
  prepareNextTurn,

  /// Fired on user steering input.
  onSteering,
}

/// JSON name of [event] (hook callbacks are `on<EventJsonName>`).
String extHookEventJson(ExtHookEvent event) => switch (event) {
  ExtHookEvent.sessionStart => 'onSessionStart',
  ExtHookEvent.sessionEnd => 'onSessionEnd',
  ExtHookEvent.beforeToolCall => 'beforeToolCall',
  ExtHookEvent.afterToolCall => 'afterToolCall',
  ExtHookEvent.prepareNextTurn => 'prepareNextTurn',
  ExtHookEvent.onSteering => 'onSteering',
};

/// Parses a JSON hook-event name; returns `null` for unknown values.
ExtHookEvent? extHookEventFromJsonName(String value) => switch (value) {
  'onSessionStart' => ExtHookEvent.sessionStart,
  'onSessionEnd' => ExtHookEvent.sessionEnd,
  'beforeToolCall' => ExtHookEvent.beforeToolCall,
  'afterToolCall' => ExtHookEvent.afterToolCall,
  'prepareNextTurn' => ExtHookEvent.prepareNextTurn,
  'onSteering' => ExtHookEvent.onSteering,
  _ => null,
};

/// Runtime platform an extension may target.
enum ExtPlatformTag { cli, macos, ios, android, web, linux, windows }

/// Parses a JSON platform name (case-insensitive); `null` for unknown values.
ExtPlatformTag? extPlatformTagFromJsonName(String value) {
  final lower = value.toLowerCase();
  for (final tag in ExtPlatformTag.values) {
    if (tag.name == lower) return tag;
  }
  return null;
}

/// Declared capabilities of an extension: what the host is asked to expose.
///
/// Everything defaults to denied/empty; an extension must declare what it
/// needs and the user grants it at trust time.
final class ExtCapabilities {
  /// Whether the extension may make network requests.
  final bool network;

  /// Command prefixes the extension may execute (first-token prefix match).
  final Set<String> allowedCommands;

  /// Whether the extension may request stored keys by name (never values).
  final bool keys;

  /// Whether the read-only fs bridge is available.
  final bool fs;

  /// Whether the extension may register agent tools.
  final bool tools;

  /// Whether the extension may register provider flows (menus).
  final bool menus;

  /// Hook events the extension registers callbacks for.
  final Set<ExtHookEvent> hooks;

  /// Creates a capability set; every field defaults to denied/empty.
  const ExtCapabilities({
    this.network = false,
    this.allowedCommands = const {},
    this.keys = false,
    this.fs = false,
    this.tools = false,
    this.menus = false,
    this.hooks = const {},
  });

  /// Strict parse: unknown keys are ignored (forward-compat), wrong value
  /// types become problems on [problems]. Accepts both the nested form
  /// (`exec.allowedCommands`, `fs.read`) and flat booleans.
  factory ExtCapabilities.fromJson(Map<String, dynamic> json) {
    final problems = <String>[];
    final caps = parseExtCapabilities(json, problems);
    if (problems.isNotEmpty) throw ExtManifestException(problems);
    return caps;
  }

  /// Serializes to the canonical flat JSON shape (sorted lists).
  Map<String, dynamic> toJson() => {
    'network': network,
    'allowedCommands': allowedCommands.toList()..sort(),
    'keys': keys,
    'fs': fs,
    'tools': tools,
    'menus': menus,
    'hooks': hooks.map(extHookEventJson).toList()..sort(),
  };

  @override
  bool operator ==(Object other) =>
      other is ExtCapabilities &&
      other.network == network &&
      other.keys == keys &&
      other.fs == fs &&
      other.tools == tools &&
      other.menus == menus &&
      other.allowedCommands.length == allowedCommands.length &&
      other.allowedCommands.containsAll(allowedCommands) &&
      other.hooks.length == hooks.length &&
      other.hooks.containsAll(hooks);

  @override
  int get hashCode => Object.hash(
    network,
    keys,
    fs,
    tools,
    menus,
    Object.hashAllUnordered(allowedCommands),
    Object.hashAllUnordered(hooks),
  );
}

/// Accumulating parse of a capabilities object; problems are appended to
/// [problems] so the manifest parser can report everything at once.
ExtCapabilities parseExtCapabilities(
  Map<String, dynamic> json,
  List<String> problems,
) {
  var network = false;
  var keys = false;
  var fs = false;
  var tools = false;
  var menus = false;
  final allowed = <String>{};
  final hooks = <ExtHookEvent>{};

  void readBool(String key, void Function(bool value) apply) {
    final value = json[key];
    if (value == null) return;
    if (value is! bool) {
      problems.add('capabilities.$key must be a boolean');
      return;
    }
    apply(value);
  }

  void readCommands(String label, Object? value) {
    if (value == null) return;
    if (value is! List) {
      problems.add('$label must be a list of strings');
      return;
    }
    for (final entry in value) {
      if (entry is! String) {
        problems.add('$label entries must be strings');
        continue;
      }
      allowed.add(entry);
    }
  }

  readBool('network', (v) => network = v);
  readBool('keys', (v) => keys = v);
  readBool('tools', (v) => tools = v);
  readBool('menus', (v) => menus = v);

  final fsValue = json['fs'];
  if (fsValue is bool) {
    fs = fsValue;
  } else if (fsValue is Map<String, dynamic>) {
    final read = fsValue['read'];
    if (read != null && read is! bool) {
      problems.add('capabilities.fs.read must be a boolean');
    } else if (read == true) {
      fs = true;
    }
  } else if (fsValue != null) {
    problems.add('capabilities.fs must be a boolean or an object');
  }

  final execValue = json['exec'];
  if (execValue is Map<String, dynamic>) {
    readCommands(
      'capabilities.exec.allowedCommands',
      execValue['allowedCommands'],
    );
  } else if (execValue != null) {
    problems.add('capabilities.exec must be an object');
  }
  readCommands('capabilities.allowedCommands', json['allowedCommands']);

  final hooksValue = json['hooks'];
  if (hooksValue != null) {
    if (hooksValue is! List) {
      problems.add('capabilities.hooks must be a list');
    } else {
      for (final entry in hooksValue) {
        if (entry is! String) {
          problems.add('capabilities.hooks entries must be strings');
          continue;
        }
        final event = extHookEventFromJsonName(entry);
        if (event == null) {
          problems.add('unknown hook event: $entry');
          continue;
        }
        hooks.add(event);
      }
    }
  }

  return ExtCapabilities(
    network: network,
    allowedCommands: Set.of(allowed),
    keys: keys,
    fs: fs,
    tools: tools,
    menus: menus,
    hooks: Set.of(hooks),
  );
}

/// Parsed `manifest.json` of a JS extension.
final class ExtensionManifest {
  /// Unique extension name matching [kExtNamePattern].
  final String name;

  /// What form the extension takes (absent in JSON => [ExtKind.widget]).
  final ExtKind kind;

  /// Required, non-empty version string.
  final String version;

  /// Optional human-readable description.
  final String? description;

  /// Platforms the extension supports; `null`/absent => all platforms.
  final Set<ExtPlatformTag>? platforms;

  /// Declared capabilities (absent in JSON => all-defaults).
  final ExtCapabilities capabilities;

  /// Creates a manifest; prefer [ExtensionManifest.fromJson] for parsing.
  const ExtensionManifest({
    required this.name,
    this.kind = ExtKind.widget,
    required this.version,
    this.description,
    this.platforms,
    this.capabilities = const ExtCapabilities(),
  });

  /// Strict parse that accumulates EVERY problem, then throws a single
  /// [ExtManifestException] if any were found. Invalid JSON text is handled
  /// by the caller (this takes an already-decoded map).
  factory ExtensionManifest.fromJson(Map<String, dynamic> json) {
    final problems = <String>[];

    final nameValue = json['name'] ?? json['id'];
    String? name;
    if (nameValue == null) {
      problems.add('name is required');
    } else if (nameValue is! String) {
      problems.add('name must be a string');
    } else if (RegExp(kExtNamePattern).hasMatch(nameValue)) {
      name = nameValue;
    } else {
      problems.add('invalid name "$nameValue": must match $kExtNamePattern');
    }

    var kind = ExtKind.widget;
    final kindValue = json['kind'];
    if (kindValue != null) {
      if (kindValue is! String) {
        problems.add('kind must be a string');
      } else {
        final parsed = extKindFromJsonName(kindValue);
        if (parsed == null) {
          problems.add('unknown kind: $kindValue');
        } else {
          kind = parsed;
        }
      }
    }

    var version = '';
    final versionValue = json['version'];
    if (versionValue == null) {
      problems.add('version is required');
    } else if (versionValue is! String) {
      problems.add('version must be a string');
    } else if (versionValue.isEmpty) {
      problems.add('version must be non-empty');
    } else {
      version = versionValue;
    }

    String? description;
    final descriptionValue = json['description'];
    if (descriptionValue != null) {
      if (descriptionValue is! String) {
        problems.add('description must be a string');
      } else {
        description = descriptionValue;
      }
    }

    Set<ExtPlatformTag>? platforms;
    final platformsValue = json['platforms'];
    if (platformsValue != null) {
      if (platformsValue is! List) {
        problems.add('platforms must be a list');
      } else {
        final parsed = <ExtPlatformTag>{};
        for (final entry in platformsValue) {
          if (entry is! String) {
            problems.add('platforms entries must be strings');
            continue;
          }
          final tag = extPlatformTagFromJsonName(entry);
          if (tag == null) {
            problems.add('unknown platform: $entry');
            continue;
          }
          parsed.add(tag);
        }
        platforms = parsed;
      }
    }

    var capabilities = const ExtCapabilities();
    final capabilitiesValue = json['capabilities'];
    if (capabilitiesValue != null) {
      if (capabilitiesValue is! Map<String, dynamic>) {
        problems.add('capabilities must be an object');
      } else {
        capabilities = parseExtCapabilities(capabilitiesValue, problems);
      }
    }

    if (problems.isNotEmpty) throw ExtManifestException(problems);
    return ExtensionManifest(
      name: name!,
      kind: kind,
      version: version,
      description: description,
      platforms: platforms,
      capabilities: capabilities,
    );
  }

  /// Serializes to the canonical JSON shape (`kind` always written,
  /// `platforms` omitted when the extension supports all platforms).
  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': extKindJson(kind),
    'version': version,
    if (description != null) 'description': description,
    if (platforms != null)
      'platforms': platforms!.map((tag) => tag.name).toList(),
    'capabilities': capabilities.toJson(),
  };

  /// Whether the extension declares support for platform [p].
  bool supportsPlatform(ExtPlatformTag p) =>
      platforms == null || platforms!.contains(p);
}

/// Accumulates EVERY manifest problem (E12) — never half-loads.
class ExtManifestException implements Exception {
  /// All problems found, in field order.
  final List<String> problems;

  /// Creates an exception carrying [problems].
  ExtManifestException(this.problems);

  @override
  String toString() => 'invalid extension manifest: ${problems.join('; ')}';
}
