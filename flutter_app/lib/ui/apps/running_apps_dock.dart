// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

import 'dart:math' as math;

import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show ExecutionEnv;

/// One running-app identity shared by the floating dock and collapsed Apps.
class RunningAppIconButton extends StatelessWidget {
  const RunningAppIconButton({
    super.key,
    required this.app,
    required this.env,
    required this.selected,
    required this.onTap,
    this.size = 40,
  });

  final JsAppInfo app;
  final ExecutionEnv env;
  final bool selected;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Tooltip(
      message: app.name,
      child: Semantics(
        button: true,
        selected: selected,
        label: app.name,
        child: Material(
          color: selected
              ? colors.indigo.withValues(alpha: .22)
              : Colors.transparent,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(size * .32),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox.square(
              dimension: size,
              child: Center(
                child: AppIcon(app: app, env: env, size: size * .72),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// macOS-like vertical task switcher for minimized and visible JS apps.
/// It owns no runtime state: the shell keeps every app mounted and this dock
/// merely changes which presentation is active.
class RunningAppsDock extends StatefulWidget {
  const RunningAppsDock({
    super.key,
    required this.apps,
    required this.activeAppId,
    required this.env,
    required this.onOpen,
  });

  final List<JsAppInfo> apps;
  final String? activeAppId;
  final ExecutionEnv env;
  final ValueChanged<JsAppInfo> onOpen;

  @override
  State<RunningAppsDock> createState() => _RunningAppsDockState();
}

final class _RunningAppsDockState extends State<RunningAppsDock> {
  bool _hovered = false;
  bool _touchOpen = false;

  void _open(JsAppInfo app) {
    setState(() => _touchOpen = false);
    widget.onOpen(app);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.apps.isEmpty) return const SizedBox.shrink();
    final expanded = _hovered || _touchOpen;
    final colors = FahColors.of(context);
    final active = widget.apps
        .where((app) => app.id == widget.activeAppId)
        .firstOrNull;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _touchOpen = false;
      }),
      child: ClipRect(
        child: AnimatedContainer(
          duration: FaMotion.reduceMotionOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          width: expanded ? 56 : 12,
          child: expanded ? _buildList(colors) : _buildHandle(colors, active),
        ),
      ),
    );
  }

  Widget _buildHandle(FahColors colors, JsAppInfo? active) {
    return Tooltip(
      message: active?.name ?? widget.apps.first.name,
      child: GestureDetector(
        key: const ValueKey('runningAppsDockHandle'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _touchOpen = !_touchOpen),
        child: FaSurface(
          glass: true,
          color: colors.panel.withValues(alpha: .72),
          borderRadius: const BorderRadius.horizontal(
            left: Radius.circular(10),
          ),
          padding: EdgeInsets.zero,
          child: SizedBox(
            height: 74,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 4,
                height: active == null ? 28 : 44,
                decoration: BoxDecoration(
                  color: active == null
                      ? colors.dim.withValues(alpha: .55)
                      : colors.indigo,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList(FahColors colors) {
    final maxHeight = math.min(420.0, MediaQuery.sizeOf(context).height * .65);
    return FaSurface(
      glass: true,
      color: colors.panel.withValues(alpha: .72),
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(20)),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          key: const ValueKey('runningAppsDockList'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final app in widget.apps) ...[
                RunningAppIconButton(
                  key: ValueKey('runningApp-${app.id}'),
                  app: app,
                  env: widget.env,
                  selected: app.id == widget.activeAppId,
                  onTap: () => _open(app),
                ),
                if (app != widget.apps.last) const SizedBox(height: 3),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
