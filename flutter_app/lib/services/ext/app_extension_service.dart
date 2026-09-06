// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// App-side owner of the JS-extension stack (contract section 14, app wave):
/// the on-device [ExtensionStore] roots, the [JsExtensionHost] wired to the
/// platform engine, and the minimal attach surface (`host`, `tools`, hook
/// map) the AgentService wiring consumes. AgentService registration itself is
/// a later step — this service deliberately does not touch the agent.
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show AgentTool, ExecutionEnv;
import 'package:flutter_agent_harness/src/js_ext/ext_bootstrap_js.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_manifest.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_host.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';

import 'ext_runtime_factory.dart';

/// Owns the extension store, host, and loaded extensions for the app.
///
/// Store roots (v1): project scope at `<env.cwd>/.fah/js-ext` and user scope
/// under [userDir] (default `<env.cwd>/.fa-user`), so the store root becomes
/// `<env.cwd>/.fa-user/.fah/js-ext` — inside the app sandbox because the app
/// has no real HOME directory yet. When the app gains an App Group container
/// (contract section 14), pass it as [userDir].
final class AppExtensionService {
  /// Creates the service over [env].
  AppExtensionService({
    required ExecutionEnv env,
    String? userDir,
    JsrRuntime Function(StoredExtension ext)? runtimeFactory,
    ExtHostConfig config = const ExtHostConfig(),
  }) {
    store = ExtensionStore(
      env: env,
      projectDir: env.cwd,
      userDir: userDir ?? '${env.cwd}/.fa-user',
    );
    host = JsExtensionHost(
      env: env,
      store: store,
      runtimeFactory: runtimeFactory ?? defaultJsrRuntimeFactory,
      bootstrapJs: kExtBootstrapJs,
      config: config,
    );
  }

  /// Engine bootstrap every app extension evaluates: the flutter_js
  /// send-message transport + the shared engine-agnostic core.
  static const String kExtBootstrapJs =
      '$kExtTransportSendMessageJs\n;\n$kExtBootstrapCoreJs';

  /// Where installed extensions are read from (and [store.write] targets).
  late final ExtensionStore store;

  /// The loaded-extension manager; the AgentService wiring attaches from
  /// here (tools/hooks/sinks — see [JsExtensionHost]).
  late final JsExtensionHost host;

  /// Loads every already-trusted, platform-compatible extension.
  ///
  /// There is NO trust prompt in the app (v1): `trustPrompt` stays null, so
  /// untrusted extensions are tombstone-skipped with reason `untrusted` — the
  /// app gets its trust UI in a later wave. [platform] defaults to the
  /// device's [defaultTargetPlatform] (`web` builds map to
  /// [ExtPlatformTag.web]).
  Future<ExtLoadReport> load({ExtPlatformTag? platform}) {
    return host.loadAll(
      platform: platform ?? platformForDevice(),
      trustPrompt: null,
    );
  }

  /// Tools of every enabled loaded extension, ready for the agent registry
  /// sync.
  List<AgentTool> get tools => host.tools;

  /// Hook events each enabled extension registered.
  Map<String, Set<ExtHookEvent>> get hooksByExtension => host.hooksByExtension;

  /// Whether at least one loaded extension is enabled.
  bool get hasExtensions => host.hasExtensions;

  /// Delivers pending follow-ups and fires the `onSessionEnd` hooks.
  Future<void> sessionEnd() => host.sessionEnd();

  /// Disposes every engine (idempotent).
  Future<void> dispose() => host.dispose();
}

/// Maps the current Flutter host to the extension platform tag.
ExtPlatformTag platformForDevice() {
  if (kIsWeb) return ExtPlatformTag.web;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => ExtPlatformTag.android,
    TargetPlatform.iOS => ExtPlatformTag.ios,
    TargetPlatform.macOS => ExtPlatformTag.macos,
    TargetPlatform.linux => ExtPlatformTag.linux,
    TargetPlatform.windows => ExtPlatformTag.windows,
    // Fuchsia runs the mobile sandbox; treat it as Android for extension
    // platform gating.
    TargetPlatform.fuchsia => ExtPlatformTag.android,
  };
}
