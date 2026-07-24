// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'apps_store.dart';

/// Renders a JS app's manifest icon: an emoji (the common case), inline SVG
/// markup (`"icon": "<svg …>"`), or an SVG file inside the app folder
/// (`"icon": "icon.svg"`, resolved as `apps/<id>/icon.svg` through the
/// shared env so the agent can drop icons next to the manifest).
class AppIcon extends StatelessWidget {
  const AppIcon({
    super.key,
    required this.app,
    required this.env,
    this.size = 24,
  });

  final JsAppInfo app;
  final ExecutionEnv env;
  final double size;

  static const String _fallbackIcon = '📦';

  bool get _isInlineSvg => app.icon.trimLeft().startsWith('<svg');
  bool get _isSvgFile => app.icon.toLowerCase().endsWith('.svg');

  @override
  Widget build(BuildContext context) {
    if (_isInlineSvg) return _svg(app.icon);
    if (_isSvgFile) {
      return FutureBuilder<String>(
        future: _loadSvgFile(),
        builder: (context, snapshot) => _svg(snapshot.data ?? ''),
      );
    }
    return Text(app.icon, style: TextStyle(fontSize: size * 0.9));
  }

  Future<String> _loadSvgFile() async {
    final result = await env.readTextFile('${app.dir}/${app.icon}');
    return result.valueOrNull ?? '';
  }

  Widget _svg(String markup) {
    if (markup.trim().isEmpty) {
      return Text(_fallbackIcon, style: TextStyle(fontSize: size * 0.9));
    }
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(markup, fit: BoxFit.contain),
    );
  }
}
