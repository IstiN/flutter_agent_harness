// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The agent-network mark: three agent nodes linked through a hub node,
/// gradient indigo → teal (brand). Replaces the stock `hub_outlined` icon
/// on the settings "Agent network" row and the DAP hub page.
class DapHubMark extends StatelessWidget {
  const DapHubMark({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(kDapHubMarkSvg, fit: BoxFit.contain),
    );
  }
}

/// Inline markup for the hub mark (24×24): a center hub ring with three
/// satellite agents on spokes, one of them filled as "this agent".
const String kDapHubMarkSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <defs>
    <linearGradient id="dh-g" x1="3" y1="21" x2="21" y2="3" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#818cf8"/>
      <stop offset="1" stop-color="#5eead4"/>
    </linearGradient>
  </defs>
  <g fill="none" stroke="url(#dh-g)" stroke-width="1.7" stroke-linecap="round">
    <path d="M12 12 L12 4.6"/>
    <path d="M12 12 L5.4 16.4"/>
    <path d="M12 12 L18.6 16.4"/>
    <circle cx="12" cy="12" r="2.7"/>
    <circle cx="5.4" cy="16.4" r="2.5"/>
    <circle cx="18.6" cy="16.4" r="2.5"/>
  </g>
  <circle cx="12" cy="4.3" r="2.6" fill="url(#dh-g)"/>
</svg>
''';
