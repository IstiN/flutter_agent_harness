// gh-1830 AC4: the add-in storage lane.
//
// The Outlook taskpane runs the same web app against a PARTITIONED
// storage backend: the pane's sandbox FS survives only through the
// `FsSnapshotStore` record store (IndexedDB in the pane's office-origin
// partition). These tests run the two persistence flows the ticket pins
// over that backend — a record-map fake (`InMemoryFsSnapshotStore`)
// wrapped by `PersistentWebExecutionEnv`, the exact stack
// `env_factory_stub.dart` wires on web — with a "reload" simulated by
// restoring a FRESH env over the same store:
//
//   auth-save → request-inject:  keys saved in settings survive the
//     reload and the boot auto-connect composes an AgentConfig that
//     carries the key (the core adapter attaches `Authorization` —
//     pinned by test/providers/openai_completions_test.dart — and the
//     add-in transport forwards it — pinned by
//     test/web/office_relay_test.dart's gh-1830 lanes);
//   widget-install → reload:  a catalog install survives the reload and
//     lists as an installed, healthy app.
//
// Runs on the VM (no browser needed) — the store is the fake, the env is
// the real one.
library;

import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/boot/boot_config_codec.dart';
import 'package:fa/sandbox/fs_persistence.dart';
import 'package:fa/sandbox/memory_shell.dart';
import 'package:fa/sandbox/persistent_web_env.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pane's storage backend as a fake: the record map the snapshot
/// envelope lives in (IndexedDB-shaped: per-record, survives the page).
InMemoryFsSnapshotStore newPartitionedStore() => InMemoryFsSnapshotStore();

/// The pane's env stack: MemoryShell-backed FS wrapped for persistence
/// over [store] (the web wiring, with a fast debounce for tests).
Future<PersistentWebExecutionEnv> paneEnv(InMemoryFsSnapshotStore store) async {
  final shell = MemoryShell();
  final env = MemoryExecutionEnv(cwd: '/', shell: shell);
  shell.attach(env);
  return PersistentWebExecutionEnv.restore(
    env,
    store,
    persistDelay: const Duration(milliseconds: 1),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('auth-save → reload → request-inject: a key saved in the pane '
      'composes a keyed boot config after the reload', () async {
    final store = newPartitionedStore();

    // Session 1: the user saves an OpenRouter key in settings (Keys
    // section / connect-flow fallback) — then the pane is reloaded.
    final env1 = await paneEnv(store);
    await SessionKeysStore.load(env1).then((s) {
      return s.set('OPENROUTER_API_KEY', 'sk-or-v1-pane-key');
    });
    await env1.flush();

    // Session 2 (the reload): a fresh env over the SAME partitioned
    // store; the boot restores the last connection and resolves the key.
    final reloaded = await SessionKeysStore.load(await paneEnv(store));
    expect(reloaded.valueOf('OPENROUTER_API_KEY'), 'sk-or-v1-pane-key');

    final config = restorableBootConfig(
      connection: const LastConnection(
        providerKind: 'openai-completions',
        modelId: 'anthropic/claude-haiku-5.5',
        baseUrl: 'https://openrouter.ai/api/v1',
      ),
      registry: null,
      sessionKeysStore: reloaded,
    );
    expect(
      config,
      isNotNull,
      reason:
          'the key persisted — the boot auto-connect must restore, '
          'not fall back to the setup form',
    );
    expect(config!.apiKey, 'sk-or-v1-pane-key');
  });

  test('widget-install → reload: a catalog install survives the pane '
      'reload and lists healthy', () async {
    final store = newPartitionedStore();

    // Session 1: install a widget from the catalog, then reload.
    final env1 = await paneEnv(store);
    await AppsStore(env1, readAsset: _noAssets).installWidget(
      id: 'focus-timer',
      version: '1.2.0',
      files: {
        'manifest.json': utf8.encode('{"id":"focus-timer","version":"1.2.0"}'),
        'widget.js': utf8.encode('// ft'),
      },
    );
    await env1.flush();

    // Session 2 (the reload): the grid discovers the installed widget.
    final apps = await AppsStore(
      await paneEnv(store),
      readAsset: _noAssets,
    ).listApps();
    final installed = apps.where((a) => a.id == 'focus-timer').single;
    expect(
      installed.error,
      isNull,
      reason: 'a healthy install, not a broken tile',
    );
    expect(installed.version, '1.2.0');
  });
}

/// Nothing is bundled anymore (`demoAppIds` is empty) — a store under
/// test never touches assets; this reader only makes that explicit.
Future<String> _noAssets(String path) async =>
    throw StateError('no bundled assets in the add-in lane: $path');
