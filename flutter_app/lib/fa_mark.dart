// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The Fa brand mark: a four-pointed "magic" sparkle with a companion star,
/// gradient indigo → teal. Used anywhere the plain `Fa` text chip appeared
/// (floating app button, in-app work bar).
class FaMark extends StatelessWidget {
  const FaMark({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(kFaMarkSvg, fit: BoxFit.contain),
    );
  }
}

/// Inline markup for the Fa sparkle (24×24).
const String kFaMarkSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <defs>
    <linearGradient id="fa-g" x1="2" y1="22" x2="22" y2="2" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#818cf8"/>
      <stop offset="1" stop-color="#2dd4bf"/>
    </linearGradient>
  </defs>
  <path fill="url(#fa-g)" d="M12 1.6c.6 0 1 .3 1.2.8l1.8 5.3c.1.3.4.6.7.7l5.3 1.8c.5.2.8.6.8 1.2s-.3 1-.8 1.2l-5.3 1.8c-.3.1-.6.4-.7.7l-1.8 5.3c-.2.5-.6.8-1.2.8s-1-.3-1.2-.8l-1.8-5.3c-.1-.3-.4-.6-.7-.7l-5.3-1.8c-.5-.2-.8-.6-.8-1.2s.3-1 .8-1.2l5.3-1.8c.3-.1.6-.4.7-.7l1.8-5.3c.2-.5.6-.8 1.2-.8z"/>
  <path fill="#2dd4bf" d="M19.5 12.4c.3 0 .5.2.6.4l.8 2.3c0 .2.2.3.3.3l2.3.8c.2.1.4.3.4.6s-.2.5-.4.6l-2.3.8c-.1 0-.3.2-.3.3l-.8 2.3c-.1.2-.3.4-.6.4s-.5-.2-.6-.4l-.8-2.3c0-.1-.2-.3-.3-.3l-2.3-.8c-.2-.1-.4-.3-.4-.6s.2-.5.4-.6l2.3-.8c.1 0 .3-.2.3-.3l.8-2.3c.1-.2.3-.4.6-.4z" opacity=".9"/>
  <circle cx="5" cy="19" r="1.6" fill="#818cf8" opacity=".9"/>
</svg>
''';
