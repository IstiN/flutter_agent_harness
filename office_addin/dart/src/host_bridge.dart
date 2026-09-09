// Host dispatch seam for the fa_office_agent taskpane (issue #89 AC7):
// every Office host loads a web taskpane + Office.js, only the document
// API differs. Outlook is the v1 adapter (the outlook.* tool surface);
// Word/Excel/PowerPoint are reserved dispatch points that answer with a
// clean note — a clean, actionable message for the model, never a crash
// — until their adapters land over this same bridge.
//
// Pure Dart — dart2js-compileable, VM-testable.
library;

import 'office_api.dart';

/// The clean not-implemented note for non-Outlook hosts (AC7).
const hostBridgeNotImplementedNote =
    'host adapter not implemented yet — Outlook is the v1 adapter; '
    'Word/Excel/PowerPoint arrive as adapters over this same bridge';

/// The bridge note for [host], or null when the host has a live adapter
/// (Outlook today — the agent boots its normal tool surface). Unknown
/// hosts fold into [OfficeHostId.other] upstream and answer the note.
String? hostBridgeNote(OfficeHostId host) => switch (host) {
  OfficeHostId.outlook => null,
  OfficeHostId.word ||
  OfficeHostId.excel ||
  OfficeHostId.powerPoint ||
  OfficeHostId.other => hostBridgeNotImplementedNote,
};
