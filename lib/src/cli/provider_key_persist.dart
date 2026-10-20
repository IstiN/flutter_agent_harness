/// The gh-1679 secure-key persistence step of the custom-provider wizard:
/// [_persistSetupKey] (the loud save-failure surface, parity with `/key
/// set`) and [_offerDefaultKeychainRepair] (the explicit `[y/N]` macOS
/// default-keychain repair offer). Split out of `provider_commands.dart`
/// to keep that file under the repo's 2800-line size gate. Same library
/// (a `part of`), so the extension sees the class's private members.
part of 'agent_cli.dart';

/// The result of [_persistSetupKey]: the secure-store key name the entry
/// should carry (null = keyless) and whether the typed token FAILED to
/// reach the durable store (gh-1679 — the entry then carries the
/// `keyNotPersisted` marker for the next boot's degradation note).
typedef SetupKeyResult = ({String? keyName, bool keyNotPersisted});

/// Implementation members of [AgentCli] for the wizard's key persistence.
extension on AgentCli {
  /// The key-name/persistence step of [_applyCustomProviderSetup]: returns
  /// the secure-store key name the entry should carry plus whether the key
  /// actually reached the durable store ([SetupKeyResult.keyNotPersisted]
  /// is true when a typed token degraded to session-only). Without a fresh
  /// token the edit keeps the entry's existing key name.
  Future<SetupKeyResult> _persistSetupKey(
    CustomProviderSetup setup,
    String? editName,
  ) async {
    final registry = config.customProviders;
    final token = setup.token;
    if (token == null) {
      // No fresh token: no save is attempted, so the entry's degradation
      // marker must CARRY OVER (gh-1679 review) — only a later successful
      // save of the slot may clear it. An unconditional `false` here let a
      // model-only (or rename) edit silently un-flag an entry whose key
      // never reached the store, re-hiding the boot degradation note.
      final existing = editName != null ? registry?.find(editName) : null;
      return (
        keyName: existing?.keyName,
        keyNotPersisted: existing?.keyNotPersisted ?? false,
      );
    }
    final keyName = _setupKeyName(setup, editName);
    final keys = config.secureKeys;
    if (keys != null && keys.available) {
      if (await keys.save(keyName, token)) {
        config.onSecretStored?.call(keyName, token);
        return (keyName: keyName, keyNotPersisted: false);
      }
      // gh-1679: a failing write must be LOUD on the spot — parity with
      // `/key set` — naming the slot, the store label, and the diagnostic
      // (never the value). The entry is still recorded (the typed token
      // rides this session's switch) but carries the `keyNotPersisted`
      // flag so the next boot surfaces the degradation. Slots and
      // diagnostics only — no byte of the key ever renders.
      _printLoudSaveFailure(keyName, keys);
      if (isMissingDefaultKeychainError(
        keys.lastSaveError ?? 'the write failed',
      )) {
        io.writeln(missingDefaultKeychainAdvisory());
        if (await _offerDefaultKeychainRepair()) {
          if (await keys.save(keyName, token)) {
            config.onSecretStored?.call(keyName, token);
            io.writeln('saved $keyName to ${keys.label}');
            return (keyName: keyName, keyNotPersisted: false);
          }
          // The retry failed after the repair — never mute (gh-1679
          // review): "retrying the save" followed by silence would read
          // as success. The same loud line as the first failure, with
          // the fresh diagnostic.
          _printLoudSaveFailure(keyName, keys);
        }
      }
      return (keyName: keyName, keyNotPersisted: true);
    }
    // No secure store: the key still applies to this session via the
    // switch below, but cannot persist with the entry.
    io.writeln(
      'could not save the key to the secure store (unavailable, locked, '
      'or managed) — it applies to this session only and is not saved '
      'with the provider',
    );
    return (keyName: null, keyNotPersisted: false);
  }

  /// The loud save-failure line shared by the first failure and the
  /// post-repair retry (gh-1679): slot + store label + diagnostic + retry
  /// command, `/key set`-parity wording. Slots and diagnostics only —
  /// never a byte of the key.
  void _printLoudSaveFailure(String keyName, SecureKeyCache keys) {
    final diagnostic = keys.lastSaveError ?? 'the write failed';
    io.writeln(
      'could not save $keyName to ${keys.label}: the write failed '
      '($diagnostic) — the key applies to this session only and is not '
      'saved with the provider; fix the store, then /key set $keyName '
      '<value>',
    );
  }

  /// The macOS default-keychain repair offer (gh-1679 AC7): offered after
  /// the loud save failure names the missing default keychain. Runs the
  /// system remedy ONLY on an explicit `y` — fa never changes system
  /// keychain settings on its own — then reports the outcome. Returns true
  /// when the repair command exited 0 and the caller should retry the
  /// save; false on `n`/cancel, a failed repair, or an unavailable shell.
  Future<bool> _offerDefaultKeychainRepair() async {
    const repairCommand =
        'security default-keychain -s ~/Library/Keychains/login.keychain-db';
    io.writeln('repair the default keychain now? runs: $repairCommand [y/N]');
    final answer = await _promptLine('> ');
    if (answer == null || answer.trim().toLowerCase() != 'y') {
      io.writeln(
        'skipped — the entry is recorded without its key; restore the '
        'default keychain, then /key set with the slot name above',
      );
      return false;
    }
    final result = await config.env.exec(repairCommand);
    switch (result) {
      case Ok(value: final shellResult) when shellResult.exitCode == 0:
        io.writeln('default keychain restored — retrying the save');
        return true;
      case Ok(value: final shellResult):
        io.writeln(
          'the repair command failed (exit ${shellResult.exitCode}) — '
          '${missingDefaultKeychainAdvisory()}',
        );
        return false;
      case Err():
        io.writeln(
          'could not run the repair command on this host — '
          '${missingDefaultKeychainAdvisory()}',
        );
        return false;
    }
  }
}
