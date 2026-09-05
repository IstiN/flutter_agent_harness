// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'trajectory_controller.dart';
import 'trajectory_strings.dart';
import 'trajectory_view.dart';

/// The trajectory ledger over a live `FaChatService.trajectory` stream.
///
/// Subscribes [trajectory], feeds a [TrajectoryController], and renders the
/// [TrajectoryBody] shell (header + ledger, master-detail on wide canvases).
/// Shows a loading state until the first snapshot arrives; hosts that host
/// their own controller and subscription use [TrajectoryScreen] directly.
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
    // Swap the loading state out once; afterwards the body reacts to the
    // controller itself.
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
    return TrajectoryBody(controller: _controller);
  }
}

/// The full-screen trajectory surface: a real page (header, ledger, and on
/// wide canvases the persistent details pane) over a caller-owned
/// [TrajectoryController].
///
/// The chat screen pushes it as a route on wide canvases and swaps it in as
/// its body on narrow ones — either way the controller (and with it the
/// scroll position, selection, and filters) lives at the screen level, so
/// switching never loses state. [Esc] and the header close button invoke
/// [onClose]; a pushed route pops, the narrow swap returns to chat.
class TrajectoryScreen extends StatefulWidget {
  /// Creates the screen bound to [controller].
  const TrajectoryScreen({
    super.key,
    required this.controller,
    required this.onClose,
    this.loaded = true,
  });

  /// The screen-level controller holding the snapshot and interaction state.
  final TrajectoryController controller;

  /// Pops the surface (route pop / switch back to chat).
  final VoidCallback onClose;

  /// Whether the first snapshot has landed; false renders the loading state.
  final bool loaded;

  @override
  State<TrajectoryScreen> createState() => _TrajectoryScreenState();
}

class _TrajectoryScreenState extends State<TrajectoryScreen> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // autofocus alone loses the race against the route's focus-scope
    // transfer on a Navigator.push; claim focus explicitly on the first
    // frame so Esc reaches the shortcut.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.loaded) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(TrajectoryStrings.of(context).historyLoadingTrajectory),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: CallbackShortcuts(
        bindings: {
          LogicalKeySet(LogicalKeyboardKey.escape): widget.onClose,
        },
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          child: TrajectoryBody(
            controller: widget.controller,
            onClose: widget.onClose,
          ),
        ),
      ),
    );
  }
}
