// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

/// The real Apps sections shared by the desktop directory and launcher.
///
/// Boards are intentionally absent: the product has no board model. Running
/// apps are presented by the shell's app panel rather than fabricated here.
enum AppsDirectorySection { myApps, widgetStore }

/// Shared section and search state for the Apps directory and overview.
final class AppLauncherController extends ChangeNotifier {
  final TextEditingController searchController = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();

  AppsDirectorySection _section = AppsDirectorySection.myApps;

  AppsDirectorySection get section => _section;

  void select(AppsDirectorySection section) {
    if (_section == section) return;
    _section = section;
    notifyListeners();
  }

  @override
  void dispose() {
    searchController.dispose();
    searchFocusNode.dispose();
    super.dispose();
  }
}
