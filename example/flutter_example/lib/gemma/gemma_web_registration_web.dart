// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web-only manual registration of `FlutterGemmaWeb` as the
/// `FlutterGemmaPlugin` platform instance.
///
/// Normally the generated web plugin registrant does this via
/// `FlutterGemmaWeb.registerWith`, but dart2js release builds tree-shake
/// that assignment out: `FlutterGemmaPlugin._instance` is initialized with
/// a *throwing* default (`defaultFlutterGemmaInstance` — see
/// flutter_gemma_default_web.dart), so with no visible write the compiler
/// folds every read of `FlutterGemmaPlugin.instance` to "always throws".
/// That cascades: `getActiveModel` degenerates to a null return, the whole
/// LiteRT-LM web engine (`LiteRtLmWebInferenceModel`, the
/// `window.litertLmReady` handshake, `Engine.create`) is dead-coded away,
/// and the first real call fails at runtime (verified against
/// flutter_gemma 1.3.1 with dart2js -O1..-O4; debug builds are unaffected
/// because they do not tree-shake).
///
/// Re-doing the assignment here — inside code the service provably calls —
/// keeps the write alive: a static field that is both written and read in
/// the retained graph cannot be folded away. Idempotent (the registrant's
/// own assignment, when it survives, is equally harmless) and runs before
/// any model is created, so the replaced instance carries no state.
library;

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/web/flutter_gemma_web.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_web/shared_preferences_web.dart';

/// Assigns `FlutterGemmaWeb` as `FlutterGemmaPlugin.instance`. See the
/// library docstring for why this must not rely on the plugin registrant.
///
/// Also pins `SharedPreferencesPlugin` as the shared_preferences platform
/// instance: flutter_gemma's model repository (`SharedPreferences.getInstance`
/// in `ServiceRegistry.initialize`) needs the web implementation, and its
/// registrant assignment is shaken out the same way — without it the
/// platform interface falls back to the MethodChannel default, which throws
/// `MissingPluginException` on web.
void ensureGemmaWebRegistered() {
  FlutterGemmaPlugin.instance = FlutterGemmaWeb();
  SharedPreferencesStorePlatform.instance = SharedPreferencesPlugin();
}
