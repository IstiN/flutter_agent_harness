// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/icloud_sync_service.dart';

/// Name of the agent tool that syncs the sandbox with iCloud Drive.
const icloudSyncToolName = 'icloud_sync';

/// The guidance [icloudSyncTool] returns when the ubiquity container is
/// missing: the user-side toggle plus the developer-side capability note.
/// LLM-facing and stays literal English (not UI copy).
const icloudSyncUnavailableGuidance =
    'iCloud sync is not available: the ubiquity container could not be '
    'resolved. On the device: sign in to iCloud and enable iCloud Drive for '
    'Fa (Settings → Apple ID → iCloud → iCloud Drive → apps using iCloud → '
    'Fa). If it stays unavailable on a developer build, the App ID needs '
    'the iCloud capability: Apple Developer portal → Certificates, '
    'Identifiers & Profiles → Identifiers → dev.fa1.app → enable iCloud '
    '(iCloud Documents), create the iCloud.dev.fa1.app container under '
    'iCloud Containers and assign it, then regenerate the provisioning '
    'profile (macOS also needs the entitlements re-added — see '
    'ICloudSyncService).';

/// Renders a sync report as the tool result text:
/// `Synced N files (M KB) — last sync YYYY-MM-DD HH:MM.`
String formatICloudSyncReport(ICloudSyncReport report) {
  final kb = (report.bytesCopied / 1024).round();
  return 'Synced ${report.filesCopied} files ($kb KB) — last sync '
      '${formatICloudSyncTimestamp(report.syncedAt)}.';
}

/// Creates the `icloud_sync` tool bound to [service].
///
/// Tier write: the sync rewrites files in both the sandbox and the iCloud
/// container, so the approval gate applies. The merge is manual-trigger
/// only and last-write-wins by file mtime (see [ICloudSyncService]). The
/// description/result texts are LLM-facing and stay literal English.
AgentTool icloudSyncTool(ICloudSyncService service) {
  return AgentTool(
    name: icloudSyncToolName,
    label: icloudSyncToolName,
    tier: ApprovalTier.write,
    description:
        "Sync the app's sessions and installed apps with iCloud Drive so "
        'they follow the user across their devices. Runs one merge now '
        '(last-write-wins by file modification time; deletions are not '
        'propagated) and reports how many files were copied. Suggest it '
        'when the user asks to sync, back up, or move their sessions to '
        'another device.',
    parameters: const {'type': 'object', 'properties': {}},
    execute: (arguments, cancelToken, onUpdate) async {
      if (!await service.isAvailable()) {
        return ToolExecutionResult.text(icloudSyncUnavailableGuidance);
      }
      final report = await service.syncNow();
      return ToolExecutionResult.text(formatICloudSyncReport(report));
    },
  );
}
