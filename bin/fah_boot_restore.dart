/// The gh-1000 boot restore pin, split out of `fah.dart` (issue #1000
/// rework round 3): the per-folder state's saved-provider NAME resolution
/// and its E1 degradation note live here so the pin logic has one
/// testable home. The E2 env-vs-store note stays inline in `fah.dart` —
/// it prints later (after the boot banner) and its rule is the shared
/// `envShadowingNote` (key_status.dart).
library;

import 'package:flutter_agent_harness/src/cli/custom_providers.dart';
import 'package:flutter_agent_harness/src/cli/folder_model_state.dart';

/// The boot-side twin of the session restore's precedence-2 binding: the
/// state's saved-provider NAME pins WHICH saved entry serves the restored
/// model — two entries can share one endpoint and modelId, and
/// endpoint-keyed resolution would pick the first config match (possibly
/// the other account's key → 401). A name that no longer resolves
/// degrades to endpoint-keyed resolution with the E1 note (the model is
/// kept).
({CustomProviderEntry? entry, String? note}) resolveBootFolderPin({
  required FolderModelState? state,
  required List<CustomProviderEntry> entries,
}) {
  return folderStateProviderEntry(state, CustomProviderRegistry(entries));
}
