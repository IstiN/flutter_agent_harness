// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The model chip mark: a rounded silicon chip with the Fa sparkle inside,
/// gradient indigo → teal (brand). Replaces the stock `psychology` icon on
/// the sidebar's model card.
class ModelMark extends StatelessWidget {
  const ModelMark({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(kModelMarkSvg, fit: BoxFit.contain),
    );
  }
}

/// The settings sliders mark: two clean slider rows with knob rings, dim
/// stroke matching [FahPalette.dim]. Replaces the stock `tune` icon on the
/// sidebar's model card.
class TuneMark extends StatelessWidget {
  const TuneMark({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(kTuneMarkSvg, fit: BoxFit.contain),
    );
  }
}

/// Inline markup for the model chip (24×24).
const String kModelMarkSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <defs>
    <linearGradient id="mm-g" x1="2" y1="22" x2="22" y2="2" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#818cf8"/>
      <stop offset="1" stop-color="#5eead4"/>
    </linearGradient>
  </defs>
  <g stroke="url(#mm-g)" stroke-width="1.7" stroke-linecap="round" fill="none">
    <path d="M9 2.6v1.9M15 2.6v1.9M9 19.5v1.9M15 19.5v1.9M2.6 9h1.9M2.6 15h1.9M19.5 9h1.9M19.5 15h1.9"/>
  </g>
  <rect x="5.2" y="5.2" width="13.6" height="13.6" rx="3.4" fill="url(#mm-g)"/>
  <path fill="#06121a" d="M12 8.1c.3 0 .5.1.6.4l.9 2.1c0 .1.2.3.3.3l2.1.9c.3.1.4.3.4.6s-.2.5-.4.6l-2.1.9c-.1 0-.3.2-.3.3l-.9 2.1c-.1.3-.3.4-.6.4s-.5-.2-.6-.4l-.9-2.1c0-.1-.2-.3-.3-.3l-2.1-.9c-.3-.1-.4-.3-.4-.6s.2-.5.4-.6l2.1-.9c.1 0 .3-.2.3-.3l.9-2.1c.1-.3.3-.4.6-.4z"/>
</svg>
''';

/// Inline markup for the settings sliders (24×24).
const String kTuneMarkSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none">
  <g stroke="#93a1b5" stroke-width="1.8" stroke-linecap="round">
    <path d="M3.5 7h9.5M18.5 7h2"/>
    <path d="M3.5 17h4.5M13.5 17h7"/>
    <circle cx="16" cy="7" r="2.4" fill="#0d1420"/>
    <circle cx="11" cy="17" r="2.4" fill="#0d1420"/>
  </g>
</svg>
''';
