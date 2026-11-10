/// The `/provider export` + `/provider import` REPL family (issue #2090):
///
/// - UC1 `/provider export cicd [path] [--yes]` — the CURRENT
///   provider as CI/CD-ready JSON with the embedded secret, and
///   `/provider export cicd auth [path|--stdout]` — the bare
///   secret (`ENV_NAME=<value>` for api-keys, the blob plus a slot-naming
///   comment for OAuth/SSO). `--stdout` is the ONLY surface that prints a
///   secret; every confirmation line carries name/kind/size only.
/// - UC2 `/provider export` / `/provider import` — a passphrase-encrypted
///   one-provider container (the CURRENT provider's config + credential)
///   in the existing `.fahx` envelope, copied via the clipboard and
///   imported on another machine through the existing storage/switch
///   paths. Absorbs the gh-1606 Copilot-only token export (the container
///   path carries any provider type, current provider only).
///
/// Split from `provider_commands.dart` to keep that file under the
/// 2800-line gate. Same library (a `part of`), so the extension sees the
/// class's private members.
part of 'agent_cli.dart';

/// The current-provider identity the transfer commands export.
typedef _TransferSubject = ({
  ProviderSpec spec,
  CustomProviderEntry? entry,
  String baseUrl,
});

/// The resolved credential for a transfer subject.
typedef _TransferKey = ({
  ProviderTransferKeyKind kind,
  String slot,
  String value,
});

extension on AgentCli {
  /// The `/provider export ...` branch: usage + dispatch into the UC1/UC2
  /// flows. Returns true when the command targeted the export family.
  bool _startProviderExportArg(List<String> args) {
    if (args.first != 'export') return false;
    final rest = args.sublist(1);
    if (rest.isNotEmpty &&
        rest.first != 'cicd' &&
        !rest.first.startsWith('--')) {
      io.writeln(
        'usage: /provider export [cicd [auth] [path|--stdout]] '
        '[--yes] [--path <p>]',
      );
      return true;
    }
    if (rest.isNotEmpty && rest.first == 'cicd') {
      final tail = rest.sublist(1);
      final auth = tail.isNotEmpty && tail.first == 'auth';
      final operands = auth ? tail.sublist(1) : tail;
      unawaited(
        _handleProviderTransferCommand(
          () => _runCicdExport(authOnly: auth, args: operands),
        ),
      );
      return true;
    }
    unawaited(
      _handleProviderTransferCommand(() => _startProviderTransferExport(rest)),
    );
    return true;
  }

  /// The `/provider import [--force | <path>]` branch (UC2). Returns true
  /// when the command targeted the import.
  bool _startProviderImportArg(List<String> args) {
    if (args.first != 'import') return false;
    final parsed = _splitTransferArgs(args.sublist(1));
    if (parsed.operands.length > 1 ||
        parsed.flags.contains('--force') && parsed.operands.isNotEmpty ||
        parsed.flags.difference(const {'--force'}).isNotEmpty) {
      io.writeln('usage: /provider import [--force | <path>]');
      return true;
    }
    unawaited(
      _handleProviderTransferCommand(
        () => _runProviderTransferImport(
          force: parsed.flags.contains('--force'),
          path: parsed.operands.isEmpty ? null : parsed.operands.first,
        ),
      ),
    );
    return true;
  }

  /// The shared provider-flow gate: export/import need the REPL answering
  /// lines (passphrase prompts, gates), and must never interleave with a
  /// connect wizard (the established `_providerFlowActive` refusal).
  Future<void> _handleProviderTransferCommand(
    Future<void> Function() run,
  ) async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      await run();
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
  }

  /// Splits flow operands (paths) from `--flag` tokens.
  ({List<String> operands, Set<String> flags}) _splitTransferArgs(
    List<String> args,
  ) {
    final operands = <String>[];
    final flags = <String>{};
    for (final arg in args) {
      if (arg.startsWith('--')) {
        flags.add(arg);
      } else {
        operands.add(arg);
      }
    }
    return (operands: operands, flags: flags);
  }

  /// The CURRENT provider (AC8): the entry pinned by the live model when
  /// one is active, else the catalog spec behind `_agent.state.model`'s
  /// provider. Null when neither resolves (`fake:` and other non-exportable
  /// providers) — both export commands refuse.
  ({ProviderSpec spec, CustomProviderEntry? entry, String baseUrl})?
  _transferSubject() {
    final active = _activeCustomName;
    final entry = active == null ? null : config.customProviders?.find(active);
    final model = _agent.state.model;
    final spec = entry?.spec ?? catalogProvider(model.provider);
    if (spec == null) return null;
    return (
      spec: spec,
      entry: entry,
      baseUrl: model.baseUrl.isEmpty ? spec.defaultBaseUrl : model.baseUrl,
    );
  }

  /// Copies [text] to the host clipboard. Resolves to null on success, the
  /// named failure reason otherwise (the text itself never surfaces).
  Future<String?> _copyToClipboard(String text) async {
    final injected = config.clipboardWrite;
    if (injected != null) return injected(text);
    final result = await writeClipboardText(text);
    return switch (result) {
      PasteboardWriteOk() => null,
      PasteboardWriteUnavailable(:final reason) => reason,
    };
  }

  /// The credential kind the CURRENT provider carries: CodeMie entries are
  /// SSO-cookie or JWT by their `authMethod` (the URL marker routes the
  /// switch), ChatGPT/Copilot are OAuth blobs, everything else is a plain
  /// api-key/JWT secret.
  ProviderTransferKeyKind _transferKeyKind(
    ProviderSpec spec,
    CustomProviderEntry? entry,
  ) {
    if (entry != null && entry.baseUrl.contains('/code-assistant-api/')) {
      return entry.authMethod == CustomProviderAuthMethod.sso
          ? ProviderTransferKeyKind.sso
          : ProviderTransferKeyKind.apiKey;
    }
    switch (spec.name) {
      case 'chatgpt':
      case 'copilot':
        return ProviderTransferKeyKind.oauth;
      default:
        return ProviderTransferKeyKind.apiKey;
    }
  }

  /// The credential of the CURRENT provider through the EXISTING key
  /// resolution (`_providerKeyFor` — env → endpoint-scoped store → entry
  /// slot → legacy), plus the slot name a fresh machine can resolve it
  /// under (an env-readable store key name). Null when no credential is
  /// stored — the exports refuse rather than emit an empty placeholder.
  ({ProviderTransferKeyKind kind, String slot, String value})? _transferKeyFor(
    ProviderSpec spec,
    CustomProviderEntry? entry,
    String baseUrl,
  ) {
    final value = _providerKeyFor(spec, baseUrl);
    if (value == null || value.isEmpty) return null;
    final slot =
        entry?.keyName ??
        (baseUrl == spec.defaultBaseUrl
            ? spec.apiKeyEnvNames.first
            : CustomProviderRegistry.keyNameFor(baseUrl));
    return (kind: _transferKeyKind(spec, entry), slot: slot, value: value);
  }

  /// The refusal both export UCs print when the current provider has no
  /// stored credential (never export an empty placeholder silently).
  void _printNoCredentialRefusal(ProviderSpec spec) {
    io.writeln(
      'no credential stored for ${spec.name} — run the auth flow first '
      '(/provider ${spec.name}), then re-run the export',
    );
  }

  /// The refusal both export UCs print when the current provider is not an
  /// exportable provider at all (`fake:` runs, unknown ids).
  void _printNonExportableRefusal() {
    io.writeln(
      'nothing to export: the current provider '
      '("${_agent.state.model.provider}") is not an exportable provider',
    );
  }

  /// The UC1 `/provider export cicd [auth] ...` flow: parse args,
  /// resolve the subject, build the content, gate, deliver.
  Future<void> _runCicdExport({
    required bool authOnly,
    required List<String> args,
  }) async {
    final parsed = _parseCicdArgs(authOnly: authOnly, args: args);
    if (parsed == null) return;
    final resolved = _resolveExportSubject();
    if (resolved == null) return;
    final (subject, key) = resolved;
    final (what, content, slotComment) = authOnly
        ? _cicdSecretPresentation(key)
        : _cicdJsonContent(subject, key, _agent.state.model);
    if (!await _confirmTransferGate(
      '${subject.spec.name}: $what',
      parsed.destination,
      yes: parsed.yes,
    )) {
      io.writeln('export cancelled — nothing written');
      return;
    }
    await _deliverTransferContent(
      content,
      paths: parsed.operands,
      stdout: parsed.stdout,
      slotComment: slotComment,
    );
  }

  /// The `cicd auth` presentation: the bare secret value for the secrets
  /// store — `SLOT=<value>` for an api key, the raw blob otherwise. The
  /// third field names the secret's slot for the transcript comment
  /// (blob arms only).
  (String, String, String?) _cicdSecretPresentation(_TransferKey key) {
    if (key.kind == ProviderTransferKeyKind.apiKey) {
      return ('${key.slot}=<value>', '${key.slot}=${key.value}', null);
    }
    return ('the ${key.kind.wireName} blob', key.value, key.slot);
  }

  /// The full `cicd` JSON: the current provider's config with the
  /// embedded secret under `auth`.
  (String, String, String?) _cicdJsonContent(
    _TransferSubject subject,
    _TransferKey key,
    Model model,
  ) {
    final content = const JsonEncoder.withIndent('  ').convert({
      'v': 1,
      'provider': subject.spec.name,
      'baseUrl': subject.baseUrl,
      'model': model.id,
      'kind': subject.spec.kind,
      'api': model.api,
      'contextWindow': model.contextWindow,
      'maxTokens': model.maxTokens,
      'auth': {'type': key.kind.wireName, 'env': key.slot, 'value': key.value},
    });
    return ('the cicd JSON', content, null);
  }

  /// Parses the cicd args: `--yes` skips the gate, `--stdout` (auth arm
  /// only) prints instead of copying, at most one path operand. Null =
  /// usage was printed.
  ({bool yes, bool stdout, String destination, List<String> operands})?
  _parseCicdArgs({required bool authOnly, required List<String> args}) {
    final parsed = _splitTransferArgs(args);
    final yes = parsed.flags.remove('--yes');
    final stdout = authOnly && parsed.flags.remove('--stdout');
    if (parsed.flags.isNotEmpty || parsed.operands.length > 1) {
      io.writeln(
        'usage: /provider export cicd${authOnly ? ' auth' : ''} '
        '[path${authOnly ? '|--stdout' : ''}] [--yes]',
      );
      return null;
    }
    return (
      yes: yes,
      stdout: stdout,
      destination: parsed.operands.isNotEmpty
          ? parsed.operands.first
          : stdout
          ? 'stdout'
          : 'the clipboard',
      operands: parsed.operands,
    );
  }

  /// Parses the UC2 export args and runs the flow: a bare path operand
  /// writes the file directly, `--path <p>` keeps clipboard-first with the
  /// file as fallback, `--yes` skips the gate.
  Future<void> _startProviderTransferExport(List<String> args) async {
    String? direct;
    String? fallback;
    var yes = false;
    var bad = false;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--yes') {
        yes = true;
      } else if (arg == '--path') {
        if (i + 1 >= args.length) {
          bad = true;
          break;
        }
        fallback = args[++i];
      } else if (arg == '--clipboard') {
        // Explicit clipboard destination — already the default.
      } else if (direct == null) {
        direct = arg;
      } else {
        bad = true;
        break;
      }
    }
    if (bad) {
      io.writeln('usage: /provider export [--yes] [--path <p>] [--clipboard]');
      return;
    }
    if (!await _transferExportGateAndDeliver(
      direct: direct,
      fallback: fallback,
      yes: yes,
    )) {
      return;
    }
  }

  /// The subject + key + passphrase + gate + delivery of the UC2 export.
  /// Returns false when nothing was written (refusal/cancel/clipboard
  /// failure without fallback). Each stage is a helper: resolution,
  /// passphrase, container build, delivery.
  Future<bool> _transferExportGateAndDeliver({
    required String? direct,
    required String? fallback,
    required bool yes,
  }) async {
    final resolved = _resolveExportSubject();
    if (resolved == null) return false;
    final (subject, key) = resolved;
    final passphrase = await _readExportPassphrases();
    if (passphrase == null) return false;
    final (container, name, bytes) = _buildTransferContainer(
      subject: subject,
      key: key,
      passphrase: passphrase,
    );
    return _deliverTransferContainer(
      container: container,
      name: name,
      bytes: bytes,
      kindWireName: key.kind.wireName,
      direct: direct,
      fallback: fallback,
      yes: yes,
    );
  }

  /// The UC2 subject + credential, with the loud refusals printed. Null
  /// when the current provider is not exportable or has no credential.
  (_TransferSubject, _TransferKey)? _resolveExportSubject() {
    final subject = _transferSubject();
    if (subject == null) {
      _printNonExportableRefusal();
      return null;
    }
    final key = _transferKeyFor(subject.spec, subject.entry, subject.baseUrl);
    if (key == null) {
      _printNoCredentialRefusal(subject.spec);
      return null;
    }
    _warnExpiredOAuthBlob(key);
    return (subject, key);
  }

  /// The export double prompt: empty or mismatched pair cancels loudly.
  /// Null = cancelled, nothing written.
  Future<String?> _readExportPassphrases() async {
    final passphrase = await _askLine('export passphrase: ', secret: true);
    if (passphrase == null || passphrase.isEmpty) {
      io.writeln('export cancelled — nothing written');
      return null;
    }
    final confirm = await _askLine('confirm passphrase: ', secret: true);
    if (confirm != passphrase) {
      io.writeln('passphrases do not match — export cancelled');
      return null;
    }
    return passphrase;
  }

  /// Encrypts the current provider's transfer bundle into the clipboard
  /// container; returns the container text, the subject label, and the
  /// byte size the transcript may quote (never the secret).
  (String, String, int) _buildTransferContainer({
    required _TransferSubject subject,
    required _TransferKey key,
    required String passphrase,
  }) {
    final bundle = ProviderTransferBundle(
      entry: subject.entry,
      catalog: subject.entry == null ? subject.spec.name : null,
      baseUrl: subject.entry == null ? subject.baseUrl : null,
      modelId: _agent.state.model.id,
      key: ProviderTransferKey(
        name: key.slot,
        kind: key.kind,
        value: key.value,
      ),
      exportedAt: DateTime.now().toUtc().toIso8601String(),
    );
    final container =
        '${jsonEncode(encryptFahxEnvelope(jsonEncode(bundle.toJson()), passphrase))}\n';
    return (
      container,
      subject.entry?.name ?? subject.spec.name,
      utf8.encode(container).length,
    );
  }

  /// The UC2 delivery arms: direct file operand, clipboard (with the
  /// `--path` fallback on clipboard failure). Returns whether anything
  /// was written; the transcript names provider, kind, and bytes only.
  Future<bool> _deliverTransferContainer({
    required String container,
    required String name,
    required int bytes,
    required String kindWireName,
    required String? direct,
    required String? fallback,
    required bool yes,
  }) async {
    if (!await _confirmTransferGate(
      '$name ($kindWireName, $bytes bytes)',
      direct != null ? 'file $direct' : 'the clipboard',
      yes: yes,
    )) {
      io.writeln('export cancelled — nothing written');
      return false;
    }
    if (direct != null) {
      await _writeTransferFileAsync(container, direct);
      return true;
    }
    final failure = await _copyToClipboard(container);
    if (failure == null) {
      io.writeln(
        'container copied to clipboard: $name ($kindWireName, $bytes bytes)',
      );
      return true;
    }
    // Clipboard-set failure: fall back to the --path file when one was
    // given; never dump the container to stdout.
    if (fallback != null) {
      await _writeTransferFileAsync(container, fallback);
      return true;
    }
    io.writeln(
      'could not copy to the clipboard: $failure — re-run with a path '
      'operand or --path <p> to write the container to a file instead',
    );
    return false;
  }

  /// The UC2 `/provider import [--force] [path]` flow: reads the container
  /// (clipboard default, path operand file), decrypts LOUDLY (zero writes
  /// on wrong passphrase/tamper), then applies through the existing
  /// storage paths and offers the switch. Each stage is its own helper so
  /// a failure reports and aborts before any mutation.
  Future<void> _runProviderTransferImport({
    required bool force,
    required String? path,
  }) async {
    final container = await _readTransferContainer(path: path);
    if (container == null) return;
    final envelope = _decodeTransferEnvelope(container);
    if (envelope == null) return;
    final passphrase = await _askLine('container passphrase: ', secret: true);
    if (passphrase == null || passphrase.isEmpty) {
      io.writeln('import cancelled — nothing written');
      return;
    }
    final payload = _unlockTransferPayload(envelope, passphrase);
    if (payload == null) return;
    final ProviderTransferBundle bundle;
    try {
      bundle = ProviderTransferBundle.parse(payload);
    } on FahxException catch (error) {
      io.writeln('import failed: ${error.message} — nothing was written');
      return;
    }
    // Every failure above is loud with zero writes; from here the apply
    // path is allowed to mutate.
    try {
      if (bundle.entry != null) {
        await _applyImportedEntry(bundle.entry!, bundle.key, force: force);
        return;
      }
      await _applyImportedCatalogPreset(bundle);
    } on ConfigException catch (error) {
      io.writeln('import failed: ${error.message}');
    }
  }

  /// Import stage 1 — the raw container text: the `path` operand file, or
  /// the clipboard default. Null = reported failure; nothing written.
  Future<String?> _readTransferContainer({required String? path}) async {
    if (path != null) {
      final home = config.homeDir ?? config.env.cwd;
      switch (await config.env.readTextFile(_expandHomePath(path, home))) {
        case Ok(:final value):
          return value;
        case Err(:final error) when error.code == FileErrorCode.notFound:
          io.writeln('container file not found: $path');
          return null;
        case Err(:final error):
          io.writeln('cannot read $path: $error');
          return null;
      }
    }
    switch (await (config.clipboardRead?.call() ?? readPasteboardText())) {
      case PasteboardText(:final text):
        return text;
      case PasteboardUnavailable(:final reason):
        io.writeln(
          'clipboard holds no container ($reason) — pass the container '
          'path: /provider import <path>',
        );
        return null;
      case PasteboardImage():
        io.writeln(
          'clipboard holds an image, not a container — pass the '
          'container path: /provider import <path>',
        );
        return null;
    }
  }

  /// Import stage 2 — the envelope JSON: a truncated body or a non-object
  /// document is not a container. Null = reported failure.
  Map<String, dynamic>? _decodeTransferEnvelope(String container) {
    try {
      final decoded = jsonDecode(container);
      if (decoded is! Map<String, dynamic>) {
        throw const FahxException('not a provider export container');
      }
      return decoded;
    } on FormatException {
      io.writeln(
        'import failed: not a provider export container — nothing was '
        'written',
      );
      return null;
    } on FahxException catch (error) {
      io.writeln('import failed: ${error.message} — nothing was written');
      return null;
    }
  }

  /// Import stage 3 — passphrase + decrypt + payload decode. A wrong
  /// passphrase, a tampered envelope, or a malformed decrypted payload
  /// all fail loudly; null = reported failure, nothing written.
  Object? _unlockTransferPayload(
    Map<String, dynamic> envelope,
    String passphrase,
  ) {
    try {
      return jsonDecode(decryptFahxEnvelope(envelope, passphrase, version: 1));
    } on FahxException catch (error) {
      io.writeln('import failed: ${error.message} — nothing was written');
      return null;
    } on FormatException {
      io.writeln(
        'import failed: container payload is malformed — nothing was '
        'written',
      );
      return null;
    }
  }

  /// Applies an imported CUSTOM entry: per-name conflict prompt (keep
  /// local / take bundle, never silent overwrite), registry add FIRST
  /// (the persist callback lands the entry in the config immediately —
  /// even a declined switch keeps it), then the key write into the
  /// entry's slot. The pin/activation happens only in the ACCEPTED
  /// switch offer; a decline leaves the entry present-but-inactive and
  /// the current provider untouched.
  Future<void> _applyImportedEntry(
    CustomProviderEntry entry,
    ProviderTransferKey? key, {
    required bool force,
  }) async {
    final registry = config.customProviders;
    if (registry == null) {
      io.writeln(
        'this build has no provider registry — cannot import a saved '
        'entry',
      );
      return;
    }
    final existing = registry.find(entry.name);
    if (existing != null && !force) {
      final sameShape =
          existing.apiType == entry.apiType &&
          sameEndpoint(existing.baseUrl, entry.baseUrl);
      final choice = await _pickOption(
        'provider "${entry.name}" already exists'
        '${sameShape ? '' : ' (a DIFFERENT provider kind — taking the '
                  'bundle replaces it, never merges)'}',
        [
          ('keep', 'keep local', 'skip the bundled provider'),
          ('take', 'take bundle', 'overwrite the local entry and its key'),
        ],
      );
      if (choice != 'take') {
        io.writeln(
          'kept the local provider "${existing.name}" — nothing written',
        );
        return;
      }
    }
    final spec = resolveCliProviderSpec(entry.apiType);
    if (spec == null) {
      io.writeln(
        'import failed: apiType "${entry.apiType}" is not available in '
        'this build — nothing was written',
      );
      return;
    }
    // Registry add FIRST: a reserved-name container fails the add before
    // any key slot is written (no partial import). The keyName rides the
    // entry so the store write lands in the slot the added entry reads.
    if (key != null) {
      entry.keyName =
          entry.keyName ?? CustomProviderRegistry.keyNameFor(entry.baseUrl);
    }
    registry.add(entry);
    // Persist the new entry right away (the executable writes the
    // customProviders: config section on this callback): a declined
    // switch must not LOSE the import on quit while its keychain slot
    // survives. The pin/active state is NOT touched here.
    await config.onProviderChanged?.call(_providerKind, _apiKey);
    if (key != null) {
      await _storeProviderToken(
        spec,
        entry.baseUrl,
        key.value,
        keyName: entry.keyName!,
      );
    }
    // NOT active yet: activation (the pin) happens only when the switch
    // offer below is ACCEPTED — a decline leaves the imported entry
    // present-but-inactive and the current provider untouched.
    io.writeln(
      'imported provider ${entry.name} '
      '(${key == null ? 'keyless' : key.kind.wireName})',
    );
    await _offerImportedSwitch(
      label: entry.name,
      switchFn: () => _switchToSavedProvider(entry),
    );
  }

  /// Applies an imported CATALOG preset: the key lands in the slot the
  /// resolution chain reads (the spec's primary env name on the default
  /// endpoint, the endpoint-scoped `FA_KEY_<HOST>` otherwise), then the
  /// switch offer. No registry write — the preset stays a catalog choice.
  Future<void> _applyImportedCatalogPreset(
    ProviderTransferBundle bundle,
  ) async {
    final catalog = bundle.catalog!;
    final spec = catalogProvider(catalog);
    if (spec == null) {
      io.writeln(
        'import failed: provider "$catalog" is not available in this build '
        '— nothing was written',
      );
      return;
    }
    final baseUrl = bundle.baseUrl ?? spec.defaultBaseUrl;
    final key = bundle.key;
    if (key != null) {
      final slot = baseUrl == spec.defaultBaseUrl
          ? spec.apiKeyEnvNames.first
          : key.name;
      await _storeProviderToken(spec, baseUrl, key.value, keyName: slot);
    }
    io.writeln(
      'imported catalog provider ${spec.name} '
      '(${key == null ? 'keyless' : key.kind.wireName})',
    );
    await _offerImportedSwitch(
      label: spec.name,
      switchFn: () => _switchProvider(spec, baseUrl, bundle.modelId),
    );
  }

  /// The import's immediate switch offer (Enter = switch, the flow's last
  /// step — a decline leaves the provider present but inactive).
  Future<void> _offerImportedSwitch({
    required String label,
    required Future<void> Function() switchFn,
  }) async {
    final answer = await _askLine('switch to $label now? [Y/n] ');
    if (answer != null) {
      final normalized = answer.trim().toLowerCase();
      if (normalized.isNotEmpty && normalized != 'y' && normalized != 'yes') {
        io.writeln('keeping the current provider — /provider $label switches');
        return;
      }
    }
    try {
      await switchFn();
    } on Object catch (error) {
      io.writeln('provider switch failed: $error');
    }
  }

  /// Writes [content] to [path] through the host env; prints the result
  /// line (success or failure). Never throws.
  Future<void> _writeTransferFileAsync(String content, String path) async {
    switch (await config.env.writeFile(path, content)) {
      case Err(:final error):
        io.writeln('cannot write $path: $error');
      case Ok():
        io.writeln('wrote $path (${utf8.encode(content).length} bytes)');
    }
  }

  /// Delivers UC1 content to its destination: file operand, else explicit
  /// `--stdout` (the ONLY secret-printing surface; an OAuth/SSO blob gets
  /// a comment naming its slot first), else the clipboard. The transcript
  /// confirmation carries destination + size only.
  Future<void> _deliverTransferContent(
    String content, {
    required List<String> paths,
    required bool stdout,
    String? slotComment,
  }) async {
    if (paths.isNotEmpty) {
      await _writeTransferFileAsync(content, paths.first);
      return;
    }
    if (stdout) {
      if (slotComment != null) {
        io.writeln(
          '# paste this blob into the secrets store slot '
          '$slotComment',
        );
      }
      io.writeln(content);
      return;
    }
    final failure = await _copyToClipboard(content);
    io.writeln(
      failure == null
          ? 'copied to the clipboard (${utf8.encode(content).length} bytes)'
          : 'could not copy to the clipboard: $failure',
    );
  }

  /// The confirmation gate: names subject + destination; `--yes` skips it
  /// (headless), a decline writes nothing.
  Future<bool> _confirmTransferGate(
    String what,
    String destination, {
    required bool yes,
  }) async {
    if (yes) return true;
    final answer = await _askLine('export $what to $destination? [y/N] ');
    if (answer == null) return false;
    final normalized = answer.trim().toLowerCase();
    return normalized == 'y' || normalized == 'yes';
  }

  /// The expired-OAuth-blob warning (border case): export proceeds with a
  /// visible "expired — re-auth" note when the ChatGPT blob's access token
  /// is at/past its expiry skew.
  void _warnExpiredOAuthBlob(
    ({ProviderTransferKeyKind kind, String slot, String value}) key,
  ) {
    if (key.kind != ProviderTransferKeyKind.oauth) return;
    final credentials = tryDecodeChatGptCredentials(key.value);
    if (credentials == null) return;
    if (credentials.needsRefresh(DateTime.now())) {
      io.writeln(
        'warning: the access token looks expired — re-auth '
        '(/provider chatgpt oauth) before relying on this export',
      );
    }
  }
}
