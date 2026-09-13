/// Google Play feature graphic (issue #289): the 1024×500 store-listing
/// banner, rendered as a real widget so it stays golden-verified and
/// on-brand (`test/golden/play_store_assets_test.dart` snapshots it
/// straight into `fastlane/metadata/android/<locale>/images/featureGraphic.png`,
/// which the `android play_store` fastlane lane uploads).
///
/// Play placement rules shape the design: the graphic shows behind the
/// listing video / at the top of the listing, so content stays centered
/// inside a ~80% safe area (edges may crop), text is short and large, and
/// the visual language matches [StoreFrame] — the same brand gradient and
/// glow treatment the store screenshots use.
library;

import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:flutter/material.dart';

/// Localized feature-graphic tagline per language (`en` is the fallback).
const kPlayFeatureTagline = <String, String>{
  'en': 'Your own apps, built by chat',
  'ru': 'Свои приложения — прямо из чата',
};

/// The 1024×500 Play feature graphic: brand gradient + glows, the app-icon
/// tile and wordmark lockup, and the localized tagline.
class PlayFeatureGraphic extends StatelessWidget {
  const PlayFeatureGraphic({super.key, this.lang = 'en'});

  /// Language code for the tagline (`en`, `ru`).
  final String lang;

  @override
  Widget build(BuildContext context) {
    final tagline = kPlayFeatureTagline[lang] ?? kPlayFeatureTagline['en']!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final tile = h * 0.34;
        return Material(
          color: FahPalette.bg,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF101A2E), FahPalette.bg],
                    ),
                  ),
                ),
              ),
              Positioned(
                right: -w * 0.12,
                top: -h * 0.45,
                child: _Glow(color: FahPalette.indigo, size: w * 0.45),
              ),
              Positioned(
                left: -w * 0.15,
                bottom: -h * 0.55,
                child: _Glow(color: FahPalette.teal, size: w * 0.4),
              ),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FaBrandTile(dark: true, size: tile),
                        SizedBox(width: w * 0.028),
                        // The wordmark — big enough to survive the small
                        // placements (search drops, listing header).
                        Baseline(
                          baseline: h * 0.42,
                          baselineType: TextBaseline.alphabetic,
                          child: Text(
                            'Fa',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: h * 0.3,
                              fontWeight: FontWeight.w700,
                              height: 1.0,
                              color: FahPalette.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: h * 0.07),
                    Text(
                      tagline,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: h * 0.072,
                        fontWeight: FontWeight.w500,
                        color: FahPalette.dim,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A soft radial accent glow behind the content (same treatment as the
/// store marketing frame).
class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.16), color.withValues(alpha: 0)],
        ),
      ),
    );
  }
}
