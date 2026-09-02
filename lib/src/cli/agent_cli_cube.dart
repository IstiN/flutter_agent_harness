part of 'agent_cli.dart';

// The `/cube` command family (fa_cube Phase 1): line-mode status and live
// management of the session's sandbox profile over [_cubeEnv]. Output is
// plain `io.writeln` lines, styled like the other info commands — no TUI
// picker. The settings-hub Cube sandbox flow shares the resolve/apply/
// deactivate helpers below so the switch logic lives in one place.

/// Usage line printed for an unknown `/cube` subcommand.
const String _cubeUsage =
    'usage: /cube [list | use <name-or-path> | off | reload | '
    'cache status | cache clear]';

/// The `/cube` command family on [AgentCli].
extension CubeCommands on AgentCli {
  /// Dispatches `/cube` and its subcommands.
  Future<void> _handleCubeCommand(String rest) async {
    final parts = rest.isEmpty ? const <String>[] : rest.split(RegExp(r'\s+'));
    final sub = parts.isEmpty ? null : parts.first;
    switch (sub) {
      case null:
        _printCubeStatus();
      case 'list':
        await _cubeList();
      case 'use':
        await _cubeUse(parts.skip(1).join(' '));
      case 'off':
        _cubeOff();
      case 'reload':
        await _cubeReload();
      case 'cache' when parts.length > 1 && parts[1] == 'clear':
        await _cubeCacheClear();
      case 'cache':
        _printCubeCacheStatus();
      default:
        io.writeln(_cubeUsage);
    }
  }

  /// The bare `/cube` branch: the active profile's identity, backend,
  /// policy summary and cache — or the disabled note.
  void _printCubeStatus() {
    final spec = _cubeEnv.activeSpec;
    if (spec == null) {
      io.writeln('cube: disabled (full host access)');
      return;
    }
    final description = spec.description;
    io.writeln(
      'cube: ${spec.name}${description == null ? '' : ' — $description'}',
    );
    final osName = config.osName;
    io.writeln(
      '  backend: '
      '${osName == null ? 'host passthrough' : cubeBackendForPlatform(osName).describe()}',
    );
    final allow = spec.tools.allow.toList()..sort();
    io.writeln(
      '  tools allow: ${allow.isEmpty ? '(none — every command denied)' : allow.join(', ')}',
    );
    final deny = spec.tools.deny.toList()..sort();
    if (deny.isNotEmpty) io.writeln('  tools deny: ${deny.join(', ')}');
    final hosts = [for (final rule in spec.network.allow) rule.host];
    io.writeln(
      '  network allow: ${hosts.isEmpty ? '(none — all network denied)' : hosts.join(', ')}',
    );
    io.writeln('  cache: ${_cubeCacheLine(spec)}');
  }

  /// `/cube list` — the cube manifests available for this project.
  Future<void> _cubeList() async {
    final dir = '${_env.cwd}/.fah/cubes';
    final names = await _projectCubeNames();
    if (names == null) {
      io.writeln('cube: no cubes directory ($dir)');
      return;
    }
    if (names.isEmpty) {
      io.writeln('cube: no cubes in $dir');
      return;
    }
    for (final name in names) {
      io.writeln('  $name');
    }
  }

  /// `/cube use <name-or-path>` — resolve a manifest and enforce it from now
  /// on. A target containing `/` is a path, anything else a cube name.
  Future<void> _cubeUse(String target) async {
    if (target.isEmpty) {
      io.writeln('usage: /cube use <name-or-path>');
      return;
    }
    final spec = await _resolveCubeTarget(target);
    if (spec == null) return;
    await _activateCube(spec, target);
    io.writeln('cube: ${spec.name} active');
  }

  /// `/cube off` — leave sandbox mode; every operation forwards untouched.
  void _cubeOff() {
    if (_cubeEnv.activeSpec == null) {
      io.writeln('cube: already off (full host access)');
      return;
    }
    _deactivateCube();
    io.writeln('cube: off (full host access)');
  }

  /// `/cube reload` — re-resolve the remembered source (boot flag/config or
  /// the last `/cube use`) and enforce it again.
  Future<void> _cubeReload() async {
    final source = _cubeSource;
    if (source == null) {
      io.writeln('cube: no source to reload (use /cube use <name-or-path>)');
      return;
    }
    final spec = await _resolveCubeTarget(source);
    if (spec == null) return;
    await _activateCube(spec, source);
    io.writeln('cube: ${spec.name} reloaded');
  }

  /// `/cube cache status` — key, root and policy of the active cube's cache.
  void _printCubeCacheStatus() {
    final spec = _cubeEnv.activeSpec;
    if (spec == null) {
      io.writeln('cube: no cube active');
      return;
    }
    final manager = CubeCacheManager(_cubeEnv, spec);
    io.writeln('cube cache key: ${manager.cacheKey}');
    io.writeln('  root: ${manager.cacheRoot}');
    io.writeln('  ${_cubeCacheLine(spec)}');
  }

  /// `/cube cache clear` — drop the active cube's cache entry.
  Future<void> _cubeCacheClear() async {
    final spec = _cubeEnv.activeSpec;
    if (spec == null) {
      io.writeln('cube: no cube active');
      return;
    }
    final manager = CubeCacheManager(_cubeEnv, spec);
    await manager.clear();
    io.writeln('cube cache cleared (${manager.cacheRoot})');
  }

  /// Best-effort cache restore: one warning line on failure, never a crash.
  Future<void> _cubeRestoreQuietly(CubeSpec spec) async {
    try {
      await CubeCacheManager(_cubeEnv, spec).restoreIfNeeded();
    } on Object catch (error) {
      io.writeln('cube: cache restore failed: $error');
    }
  }

  /// One-line cache summary: content key plus enabled/restore/ttl.
  String _cubeCacheLine(CubeSpec spec) {
    final ttl = spec.cache.ttl;
    return 'key ${CubeCacheManager(_cubeEnv, spec).cacheKey}, '
        '${spec.cache.enabled ? 'enabled' : 'disabled'}, '
        'restore ${spec.cache.restore ? 'on' : 'off'}'
        '${ttl == null ? '' : ', ttl ${ttl.inSeconds}s'}';
  }

  /// The cube names under `<cwd>/.fah/cubes/*.yaml`, sorted. Null when the
  /// directory is missing, empty when it holds no manifests — shared by
  /// `/cube list` and the settings-hub Cube sandbox flow.
  Future<List<String>?> _projectCubeNames() async {
    final listing = await _env.listDir('${_env.cwd}/.fah/cubes');
    switch (listing) {
      case Err():
        return null;
      case Ok(:final value):
        return [
          for (final entry in value)
            if (entry.kind == FileKind.file && entry.name.endsWith('.yaml'))
              entry.name.substring(0, entry.name.length - '.yaml'.length),
        ]..sort();
    }
  }

  /// Resolves a cube name-or-path to a spec: a target containing `/` is a
  /// manifest path, anything else a cube name. Returns null (after printing
  /// the resolver error) when the manifest cannot be loaded — shared by
  /// `/cube use`, `/cube reload` and the settings-hub Cube sandbox flow.
  Future<CubeSpec?> _resolveCubeTarget(String target) async {
    try {
      final isPath = target.contains('/');
      return await CubeResolver.resolve(
        env: _env,
        path: isPath ? target : null,
        name: isPath ? null : target,
        homeDir: config.homeDir,
      );
    } on ConfigException catch (error) {
      io.writeln(error.message);
      return null;
    }
  }

  /// Enforces [spec] from now on: swaps the sandbox spec, remembers
  /// [source] for `/cube reload` and restores the cache — shared by
  /// `/cube use`, `/cube reload` and the settings-hub Cube sandbox flow.
  Future<void> _activateCube(CubeSpec spec, String source) async {
    _cubeEnv.updateSpec(spec);
    _cubeSource = source;
    await _cubeRestoreQuietly(spec);
  }

  /// Leaves sandbox mode: every operation forwards untouched — shared by
  /// `/cube off` and the settings-hub Cube sandbox flow.
  void _deactivateCube() {
    _cubeEnv.clearSpec();
  }

  /// The current sandbox state as a short label: the active cube name or
  /// the disabled note (settings-hub row and the line-mode summary).
  String _cubeStatusLabel() {
    final spec = _cubeEnv.activeSpec;
    return spec == null ? 'disabled (full host access)' : spec.name;
  }

  /// Settings → Cube sandbox: pick disabled, one of the project's
  /// `.fah/cubes/*.yaml` manifests, or a custom path. The pick applies live
  /// through the same helpers as `/cube use`/`/cube off` and persists as
  /// the startup default (`cube:` section) in the user config.
  Future<void> startCubeSandboxFlow() async {
    final picked = await _pickOption(
      'cube sandbox',
      await _cubeSandboxOptions(),
    );
    if (picked == null) return;
    if (picked == _cubePickCustom) {
      final path = await _askLine('cube manifest path (empty cancels): ');
      final trimmed = path?.trim() ?? '';
      if (trimmed.isEmpty) return;
      await _applyCubeSelection(trimmed);
      return;
    }
    await _applyCubeSelection(picked == _cubePickOff ? null : picked);
  }

  /// The Cube sandbox picker rows: disabled, every project manifest (the
  /// key is the relative path the default saves, the label the file stem),
  /// and the custom-path escape.
  Future<List<(String, String, String)>> _cubeSandboxOptions() async {
    final active = _cubeEnv.activeSpec?.name;
    final names = await _projectCubeNames();
    return [
      (
        _cubePickOff,
        'disabled (full host access)',
        active == null ? 'current' : 'currently $active',
      ),
      if (names != null)
        for (final name in names)
          ('.fah/cubes/$name.yaml', name, 'project cube manifest'),
      (_cubePickCustom, 'custom path...', 'enter a manifest path'),
    ];
  }

  /// Applies a Cube sandbox selection end to end: [target] null disables
  /// the sandbox, anything else resolves (name or path) and enforces it —
  /// then either way the choice persists as the startup default.
  Future<void> _applyCubeSelection(String? target) async {
    if (target == null) {
      _deactivateCube();
      io.writeln('cube: off (full host access)');
    } else {
      final spec = await _resolveCubeTarget(target);
      if (spec == null) return;
      await _activateCube(spec, target);
      io.writeln('cube: ${spec.name} active');
    }
    await _persistCubeDefault(target);
  }

  /// Records [target] as the saved `cube:` startup default (null records
  /// `enabled: false`) through the host's persistence hook. Hosts without
  /// one (tests, web) keep the change session-only.
  Future<void> _persistCubeDefault(String? target) async {
    final persist = config.onCubeSettingsChanged;
    config.cubeSettings = target == null
        ? const CubeSettings(enabled: false)
        : CubeSettings(configPath: target);
    if (persist == null) {
      io.writeln('cube: default kept for this session only (no user config)');
      return;
    }
    await persist();
    io.writeln('cube: saved default ${target ?? '(disabled)'}');
  }
}

/// Picker keys of the settings-hub Cube sandbox flow (cube rows are keyed
/// by their relative manifest path, so no key can collide).
const String _cubePickOff = 'off';

const String _cubePickCustom = 'custom';
