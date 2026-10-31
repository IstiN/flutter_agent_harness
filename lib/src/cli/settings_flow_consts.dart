/// The settings-flow constants (issue #1995): the per-section menu keys,
/// status values, display labels, and provider-kind strings used by the
/// settings-hub parts (`settings_flow.dart` and siblings). Split out of
/// `settings_flow.dart` to keep that file under the repo's 2800-line size
/// gate. Same library (a `part of`), so every agent_cli part sees them.
part of 'agent_cli.dart';

/// The pick key that ends a settings menu — its status value, not the
/// row's display label.
const String _menuDoneKey = 'done';

/// The display label of the [_menuDoneKey] menu row.
const String _menuDoneLabel = 'Done';

/// The status/placeholder label for a setting with nothing configured.
const String _notConfiguredLabel = 'not configured';

/// The redaction settings section: the hub menu key, the YAML path root,
/// and the [applicationNote] section name.
const String _redactSectionKey = 'redact';

/// The per-field YAML keys of the redaction section (menu pick keys too).
const String _redactionKeyMinEntropy = 'minEntropy';
const String _redactionKeyMinLength = 'minLength';
const String _redactionKeyAllowlist = 'allowlist';
const String _redactionKeyToolAllow = 'toolAllow';

/// The images settings section: the flow key, the YAML path root, and the
/// hub menu key.
const String _imagesSectionKey = 'images';

/// The power settings section: the flow key, the YAML path root, and the
/// hub menu key.
const String _powerSectionKey = 'power';

/// The MCP server kinds: the add-server pick key, the edit-menu field
/// label, and the config kind comparison.
const String _mcpKindStdio = 'stdio';
const String _mcpKindRemote = 'remote';

/// The TTSR rule actions: enable/disable and delete.
const String _ttsrRuleActionToggle = 'toggle';
const String _ttsrRuleActionDelete = 'delete';

/// The MCP server edit-menu delete action key.
const String _mcpServerActionDelete = 'delete';

/// The toggle direction hint shown when the setting is currently off
/// (picking it turns it on).
const String _toggleDirectionOn = 'off → on';

/// The provider kind every fresh config ships as its default — the same
/// factory kind `startup.dart` pins its factory triple with. That twin is
/// library-private to startup.dart (a separate library), so this library
/// declares its own.
const String _factoryProviderKind = 'openai-completions';
