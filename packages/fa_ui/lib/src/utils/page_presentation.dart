// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

/// Presents [page] modally, adapting to the available canvas: a centered,
/// width/height-constrained dialog when there is room (desktop / tablet,
/// where a full-screen editor stretches into an unreadable strip), and a
/// classic full-screen [MaterialPageRoute] on narrow (phone) canvases.
///
/// The result contract is identical in both modes: the page pops its
/// navigator with the result, which is returned to the caller.
Future<T?> pushFaPage<T>(BuildContext context, Widget page) {
  final size = MediaQuery.sizeOf(context);
  if (size.width >= 840) {
    // Desktop/tablet: a centered dialog, constrained so it doesn't stretch
    // into an unreadable full-height strip. Height caps at 80% of the
    // window so it never feels like a mobile full-screen page.
    return showDialog<T>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: size.height * 0.8,
          ),
          child: page,
        ),
      ),
    );
  }
  return Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));
}
