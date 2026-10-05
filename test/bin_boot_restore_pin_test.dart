// gh-1000 round-3 review (T6/T4): the BOOT-side pin resolution lives in
// bin/fah_boot_restore.dart — its E1 degradation (a state naming an entry
// that no longer exists) is pinned here, mirroring the session-restore
// tests in test/cli/agent_cli_folder_model_restore_test.dart.
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../bin/fah_boot_restore.dart';

void main() {
  const kimiUrl = 'https://api.kimi.com/coding/v1';
  final registry = [
    CustomProviderEntry(
      name: 'ira-1',
      apiType: 'kimi',
      baseUrl: kimiUrl,
      modelId: 'k3-256k',
      keyName: 'FA_KEY_API_KIMI_COM_IRA_1',
    ),
    CustomProviderEntry(
      name: 'kimi_me',
      apiType: 'openai',
      baseUrl: kimiUrl,
      modelId: 'k3-256k',
      keyName: 'FA_KEY_API_KIMI_COM_KIMI_ME',
    ),
  ];

  test('a state naming a live entry resolves THAT entry', () {
    final pin = resolveBootFolderPin(
      state: FolderModelState(
        providerKind: 'openai-completions',
        modelId: 'k3-256k',
        baseUrl: kimiUrl,
        customProvider: 'kimi_me',
      ),
      entries: registry,
    );
    expect(pin.entry?.name, 'kimi_me');
    expect(pin.note, isNull);
  });

  test('a state naming a deleted entry degrades with the E1 note', () {
    final pin = resolveBootFolderPin(
      state: FolderModelState(
        providerKind: 'openai-completions',
        modelId: 'k3-256k',
        baseUrl: kimiUrl,
        customProvider: 'gone-provider',
      ),
      entries: registry,
    );
    expect(pin.entry, isNull);
    expect(pin.note, allOf(contains('gone-provider'), contains('no longer')));
  });

  test('a pre-pin state (no provider name) resolves nothing, no note', () {
    final pin = resolveBootFolderPin(
      state: const FolderModelState(
        providerKind: 'openai-completions',
        modelId: 'k3-256k',
        baseUrl: kimiUrl,
      ),
      entries: registry,
    );
    expect(pin.entry, isNull);
    expect(pin.note, isNull);
  });
  test('a null state (nothing saved) resolves nothing, no note', () {
    final pin = resolveBootFolderPin(state: null, entries: registry);
    expect(pin.entry, isNull);
    expect(pin.note, isNull);
  });

  // Sanity: the helper's home compiles against the executable's own
  // imports (bin/fah.dart imports it).
  //
  // gh-1232: bin/fah.dart was split into bin/ part files; the pin
  // resolution call moved into one of them (fah_runapp.dart). The
  // import stays pinned to the primary file, the call site to the
  // executable library as a whole (primary + its part files) — the
  // same guard-update mechanism bin_main_wiring_reg_test documents.
  test('fah.dart still imports the helper (wiring guard companion)', () {
    final fah = File('bin/fah.dart').readAsStringSync();
    expect(fah, contains("import 'fah_boot_restore.dart';"));
    final library = StringBuffer(fah);
    for (final match in RegExp(
      "^part '(fah_[^']+\\.dart)';",
      multiLine: true,
    ).allMatches(fah)) {
      library.write('\n${File('bin/${match[1]}').readAsStringSync()}');
    }
    expect(library.toString(), contains('resolveBootFolderPin('));
  });
}
