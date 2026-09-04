// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../chat/fa_chat_service.dart';
import '../chat/fa_chat_screen.dart';
import 'trajectory_controller.dart';
import 'trajectory_strings.dart';
import 'trajectory_view.dart';

/// The trajectory ledger over a live `FaChatService.trajectory` stream.
///
/// Subscribes [trajectory], feeds a [TrajectoryController], and renders a
/// [TrajectoryView]. Shows a loading state until the first snapshot arrives;
/// hosts that replay their latest snapshot on listen (see
/// [TrajectoryServiceFeed]) skip it entirely.
class FaTrajectoryPanel extends StatefulWidget {
  /// Creates a panel subscribing to [trajectory].
  const FaTrajectoryPanel({super.key, required this.trajectory});

  /// The snapshot stream to render (typically `service.trajectory`).
  final Stream<TrajectorySnapshot> trajectory;

  @override
  State<FaTrajectoryPanel> createState() => _FaTrajectoryPanelState();
}

class _FaTrajectoryPanelState extends State<FaTrajectoryPanel> {
  final TrajectoryController _controller = TrajectoryController();
  StreamSubscription<TrajectorySnapshot>? _subscription;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.trajectory.listen(_onSnapshot);
  }

  @override
  void didUpdateWidget(covariant FaTrajectoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trajectory != widget.trajectory) {
      _subscription?.cancel();
      _subscription = widget.trajectory.listen(_onSnapshot);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onSnapshot(TrajectorySnapshot snapshot) {
    _controller.updateSnapshot(snapshot);
    if (_loaded) return;
    // Swap the loading state out once; afterwards [TrajectoryView] owns
    // the rendering and reacts to the controller itself.
    _loaded = true;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(TrajectoryStrings.of(context).historyLoadingTrajectory),
          ],
        ),
      );
    }
    return TrajectoryView(controller: _controller);
  }
}

/// Opens the trajectory ledger for [service], adapting to the canvas:
///
/// - Wide (>= [kWideLayoutBreakpoint]): a centered dialog page holding the
///   panel. A true persistent side panel split against the chat is host
///   shell business (the host mounts [FaTrajectoryPanel] itself); the
///   shared screen keeps the simple dialog.
/// - Narrow: a full-height modal bottom sheet.
void openTrajectoryPanel(
  BuildContext context, {
  required FaChatService service,
}) {
  final panel = FaTrajectoryPanel(trajectory: service.trajectory);
  if (MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint) {
    final size = MediaQuery.sizeOf(context);
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 840,
            maxHeight: size.height * 0.85,
          ),
          child: panel,
        ),
      ),
    );
    return;
  }
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => SizedBox.expand(child: panel),
  );
}
