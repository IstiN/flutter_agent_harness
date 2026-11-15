/// Google Play feature graphic (issue #289): the 1024×500 store-listing
/// banner, golden-rendered straight into the fastlane supply tree.
///
/// The brand lockup and the chat-built dashboard tell the same story as the
/// screenshot sequence. Both share [StoreBackdrop] with the store frames.
library;

import 'package:fa_ui/fa_ui.dart' show FaLogo;
import 'package:flutter/material.dart';

import 'store_marketing_frame.dart';

/// Localized feature-graphic tagline per language (`en` is the fallback).
const kPlayFeatureTagline = <String, String>{
  'en': 'Your own apps, built by chat',
  'ru': 'Свои приложения — прямо из чата',
};

/// The 1024×500 Play feature graphic.
class PlayFeatureGraphic extends StatelessWidget {
  const PlayFeatureGraphic({super.key, this.lang = 'en'});

  final String lang;

  @override
  Widget build(BuildContext context) {
    final tagline = kPlayFeatureTagline[lang] ?? kPlayFeatureTagline['en']!;
    final ru = lang == 'ru';
    return StoreBackdrop(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: w * 0.062,
              vertical: h * 0.095,
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 12,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _FeaturePill(
                        label: ru
                            ? 'ПЕРСОНАЛЬНЫЙ AI-АГЕНТ'
                            : 'PERSONAL AI AGENT',
                      ),
                      SizedBox(height: h * 0.035),
                      Row(
                        children: [
                          FaLogo(size: h * 0.18),
                          SizedBox(width: w * 0.018),
                          Text(
                            'Fa',
                            style: TextStyle(
                              fontFamily: 'Manrope',
                              fontSize: h * 0.19,
                              fontWeight: FontWeight.w800,
                              height: 1,
                              letterSpacing: -3,
                              color: const Color(0xFF12171C),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: h * 0.035),
                      Text(
                        tagline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Manrope',
                          fontSize: h * 0.061,
                          fontWeight: FontWeight.w600,
                          height: 1.18,
                          color: const Color(0xFF46505B),
                        ),
                      ),
                      SizedBox(height: h * 0.035),
                      Text(
                        ru
                            ? 'ЧАТ  →  ПРИЛОЖЕНИЯ  →  ВИДЖЕТЫ'
                            : 'CHAT  →  APPS  →  WIDGETS',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: h * 0.024,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                          color: const Color(0xFF1D6B65),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: w * 0.035),
                Expanded(flex: 5, child: _FeatureDashboardArt(lang: lang)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _FeaturePill extends StatelessWidget {
  const _FeaturePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: const Color(0xFFD5DCE3)),
    ),
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
        color: Color(0xFF1D6B65),
      ),
    ),
  );
}

/// A compact vector dashboard vignette — decorative artwork, not a fake
/// application screenshot. It echoes the Fa Craft app built in frame one.
class _FeatureDashboardArt extends StatelessWidget {
  const _FeatureDashboardArt({required this.lang});

  final String lang;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: const Color(0xFFD5DCE3)),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF1D6B65).withValues(alpha: 0.12),
          blurRadius: 36,
          spreadRadius: -8,
          offset: const Offset(0, 16),
        ),
      ],
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            const FaLogo(size: 20, semanticLabel: ''),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 5,
                decoration: BoxDecoration(
                  color: const Color(0xFFD5DCE3),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.auto_awesome_rounded,
              size: 17,
              color: const Color(0xFF1D6B65),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFF6F8FA), Color(0xFFD3E7E4)],
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFD5DCE3)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.sports_esports_rounded,
                        color: Color(0xFF3E8C5D),
                        size: 30,
                      ),
                      const SizedBox(height: 7),
                      Text(
                        'Fa Craft',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF46505B),
                        ),
                      ),
                    ],
                  ),
                ),
                const Text(
                  '3D',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 38,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.5,
                    color: Color(0xFF12171C),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _FeatureAppIcon(Icons.notes_rounded, Color(0xFF6366F1)),
            _FeatureAppIcon(Icons.check_rounded, Color(0xFF22C55E)),
            _FeatureAppIcon(Icons.calendar_month_rounded, Color(0xFF3B82F6)),
            _FeatureAppIcon(Icons.show_chart_rounded, Color(0xFF10B981)),
          ],
        ),
      ],
    ),
  );
}

class _FeatureAppIcon extends StatelessWidget {
  const _FeatureAppIcon(this.icon, this.color);

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    height: 38,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.32)),
    ),
    child: Icon(icon, color: color, size: 20),
  );
}
