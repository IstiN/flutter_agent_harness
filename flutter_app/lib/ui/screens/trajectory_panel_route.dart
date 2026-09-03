// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/agent_service.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// Opens the trajectory ledger for the app's active [AgentService].
///
/// Thin wrapper over the shared [openTrajectoryPanel]: wide canvases get the
/// dialog page, narrow ones the full-height bottom sheet. All user-visible
/// copy lives in fa_ui ([TrajectoryStrings] / [FaChatStrings]) — nothing to
/// localize here.
void openAppTrajectoryPanel(BuildContext context, AgentService service) {
  openTrajectoryPanel(context, service: service);
}
