// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

export 'package:fa_ui/fa_ui.dart'
    show FaRouteHeader, FaWindowChrome, faRouteAppBar;

/// Whether native macOS window controls float over Flutter content.
bool get faIsMacOSDesktop => FaWindowChrome.isMacOS;

/// App-local compatibility name for the shared [faRouteAppBar] primitive.
///
/// New shared fa_ui pages call [faRouteAppBar] directly; existing app routes
/// keep this import surface while receiving exactly the same geometry.
PreferredSizeWidget faAppBar({
  BuildContext? context,
  Widget? title,
  List<Widget>? actions,
  Widget? leading,
  bool? centerTitle,
  bool trafficLightClearance = true,
  double? toolbarHeight,
}) => faRouteAppBar(
  context: context,
  title: title,
  actions: actions,
  leading: leading,
  centerTitle: centerTitle,
  trafficLightClearance: trafficLightClearance,
  toolbarHeight: toolbarHeight,
);
