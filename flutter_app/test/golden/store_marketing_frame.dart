/// Marketing canvas for the App Store and Google Play screenshots.
///
/// The real application remains the hero: this frame only adds the localized
/// story, brand mark, deterministic backdrop and a restrained device treatment.
/// The output PNGs are committed goldens and upload directly to both stores.
library;

import 'package:fa_ui/fa_ui.dart' show FaLogo;
import 'package:flutter/material.dart';

/// Localized marketing copy per store screenshot: screen name → language →
/// (headline, subtitle). English is the fallback for missing languages.
///
/// Headlines are deliberately short: store thumbnails must communicate the
/// story without orphaned words or three-line titles on narrow devices.
const kStoreCopy = <String, Map<String, (String, String)>>{
  'store_chat': {
    'en': (
      'Your apps. Built in chat.',
      'Describe an app and Fa builds it, complete with a live widget',
    ),
    'ru': (
      'Свои приложения. В чате.',
      'Опишите приложение — Fa соберёт его и живой виджет',
    ),
  },
  'store_apps': {
    'en': (
      'A dashboard that is yours',
      'Live widgets from the apps Fa built for you, right on the home screen',
    ),
    'ru': (
      'Дашборд — под ваши задачи',
      'Живые виджеты ваших приложений — на домашнем экране',
    ),
  },
  'store_promo': {
    'en': (
      'One prompt. A working app.',
      'Personal software, built in conversation — with live widgets and in-app editing',
    ),
    'ru': (
      'Один запрос. Готовое приложение.',
      'Личный софт в диалоге — с живыми виджетами и правками внутри приложения',
    ),
  },
  'store_inapp': {
    'en': (
      'Fa, inside every app',
      '“Add crafting and survival hearts” — keep playing while Fa edits',
    ),
    'ru': (
      'Fa — внутри приложения',
      '«Добавь крафт и сердечки» — игра продолжается, пока Fa работает',
    ),
  },
  'store_media': {
    'en': (
      'Create. Speak.',
      'Travel wallpapers and voice itineraries — generated inline in the chat',
    ),
    'ru': (
      'Создаёт. Озвучивает.',
      'Обои путешествий и аудиомаршруты — прямо в диалоге',
    ),
  },
  'store_providers': {
    'en': (
      'Your models. Your keys.',
      'OpenRouter, local Ollama or your own endpoint — keys stay in Keychain',
    ),
    'ru': (
      'Свои модели. Свои ключи.',
      'OpenRouter, локальный Ollama или свой сервер — ключи в Keychain',
    ),
  },
};

const _storeEyebrows = <String, Map<String, String>>{
  'store_chat': {'en': 'CHAT → APP', 'ru': 'ЧАТ → ПРИЛОЖЕНИЕ'},
  'store_apps': {'en': 'LIVE DASHBOARD', 'ru': 'ЖИВОЙ ДАШБОРД'},
  'store_promo': {
    'en': 'FA • PERSONAL APP BUILDER',
    'ru': 'FA • ВАШИ ПРИЛОЖЕНИЯ',
  },
  'store_inapp': {'en': 'EDIT IN CONTEXT', 'ru': 'ПРАВКИ В КОНТЕКСТЕ'},
  'store_media': {'en': 'CREATE WITH AI', 'ru': 'ТВОРЧЕСТВО С AI'},
  'store_providers': {'en': 'YOUR MODELS', 'ru': 'ВАШИ МОДЕЛИ'},
};

/// The shared Porcelain canvas used by store frames and Play artwork.
/// Everything is vector-drawn and deterministic; no host assets or network.
class StoreBackdrop extends StatelessWidget {
  const StoreBackdrop({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFFECEFF2),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFFF8FAFB),
                    Color(0xFFECEFF2),
                    Color(0xFFD3E7E4),
                  ],
                  stops: [0, 0.52, 1],
                ),
              ),
            ),
            CustomPaint(painter: _StoreGridPainter()),
            Positioned(
              right: -w * 0.18,
              top: -h * 0.16,
              child: StoreGlow(color: const Color(0xFF3B78AD), size: w * 0.68),
            ),
            Positioned(
              left: -w * 0.24,
              bottom: -h * 0.18,
              child: StoreGlow(color: const Color(0xFF1D6B65), size: w * 0.62),
            ),
            child,
          ],
        );
      },
    ),
  );
}

/// Full-canvas marketing frame with localized copy above the real app screen.
class StoreFrame extends StatelessWidget {
  const StoreFrame({
    required this.screen,
    required this.lang,
    required this.child,
    super.key,
  });

  final String screen;
  final String lang;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final copy = kStoreCopy[screen];
    final localized = copy?[lang] ?? copy?['en'] ?? ('', '');
    final eyebrow =
        _storeEyebrows[screen]?[lang] ?? _storeEyebrows[screen]?['en'] ?? 'FA';
    if (screen == 'store_promo') {
      return _StorePromoFrame(
        title: localized.$1,
        subtitle: localized.$2,
        eyebrow: eyebrow,
        lang: lang,
        child: child,
      );
    }
    return StoreBackdrop(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final isLandscape = w > h;
          final isSquare = (w - h).abs() < 1;
          final textAreaH = h * (isLandscape ? 0.22 : 0.245);
          final titleSize =
              h * (isLandscape ? 0.046 : (isSquare ? 0.035 : 0.033));
          final subtitleSize = isLandscape
              ? titleSize * 0.48
              : titleSize * 0.51;
          final sidePad = w * (isLandscape ? 0.065 : 0.055);
          final radius = isLandscape ? w * 0.022 : w * 0.038;

          return Column(
            children: [
              SizedBox(
                width: w,
                height: textAreaH,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: sidePad),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _StoreEyebrow(label: eyebrow, compact: isLandscape),
                      SizedBox(height: h * (isLandscape ? 0.014 : 0.016)),
                      Text(
                        localized.$1,
                        style: TextStyle(
                          fontFamily: 'Manrope',
                          fontSize: titleSize,
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF12171C),
                          height: 1.08,
                          letterSpacing: -0.7,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: h * 0.011),
                      Text(
                        localized.$2,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: subtitleSize,
                          fontWeight: FontWeight.w400,
                          color: const Color(0xFF46505B),
                          height: 1.28,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    sidePad,
                    0,
                    sidePad,
                    h * (isLandscape ? 0.045 : 0.034),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(1),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white.withValues(alpha: 0.9),
                          const Color(0xFF1D6B65).withValues(alpha: 0.22),
                          const Color(0xFF3B78AD).withValues(alpha: 0.12),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFF1D6B65,
                          ).withValues(alpha: 0.12),
                          blurRadius: 54,
                          spreadRadius: -14,
                          offset: const Offset(0, 18),
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 28,
                          spreadRadius: -10,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(radius - 1),
                      child: child,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Editorial square artwork rather than another device screenshot: strong
/// typography, the prompt-to-build story and a restrained live-app preview.
class _StorePromoFrame extends StatelessWidget {
  const _StorePromoFrame({
    required this.title,
    required this.subtitle,
    required this.eyebrow,
    required this.lang,
    required this.child,
  });

  final String title;
  final String subtitle;
  final String eyebrow;
  final String lang;
  final Widget child;

  @override
  Widget build(BuildContext context) => StoreBackdrop(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(54, 42, 54, 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StoreEyebrow(label: eyebrow, compact: false),
              const Spacer(),
              Text(
                'CHAT  →  APP  →  WIDGET',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  color: Color(0xFF5A6571),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Manrope',
              fontSize: 53,
              fontWeight: FontWeight.w800,
              height: 1.04,
              letterSpacing: -1.5,
              color: Color(0xFF12171C),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 18,
              height: 1.35,
              color: Color(0xFF46505B),
            ),
          ),
          const SizedBox(height: 28),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  top: 26,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: const Color(0xFFD5DCE3)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 32,
                          spreadRadius: -12,
                          offset: const Offset(0, 18),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(27),
                      child: child,
                    ),
                  ),
                ),
                Positioned(
                  left: 22,
                  right: 22,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: const Color(0xFF1D6B65).withValues(alpha: 0.28),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFF1D6B65,
                          ).withValues(alpha: 0.12),
                          blurRadius: 22,
                          spreadRadius: -8,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const FaLogo(size: 22, semanticLabel: ''),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Text(
                            lang == 'ru'
                                ? '«Создай игру в стиле Minecraft»'
                                : '“Build a Minecraft-style voxel game”',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF12171C),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Icon(
                          Icons.check_circle_rounded,
                          size: 19,
                          color: Color(0xFF2A7A4C),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          lang == 'ru' ? 'ГОТОВО' : 'BUILT',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                            color: Color(0xFF2A7A4C),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _StoreEyebrow extends StatelessWidget {
  const _StoreEyebrow({required this.label, required this.compact});

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: compact ? 10 : 12,
      vertical: compact ? 5 : 6,
    ),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: const Color(0xFFD5DCE3)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const FaLogo(size: 17, semanticLabel: ''),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: compact ? 9.5 : 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: const Color(0xFF1D6B65),
            ),
          ),
        ),
      ],
    ),
  );
}

/// A soft radial accent glow behind the content.
class StoreGlow extends StatelessWidget {
  const StoreGlow({required this.color, required this.size, super.key});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: [color.withValues(alpha: 0.2), color.withValues(alpha: 0)],
      ),
    ),
  );
}

class _StoreGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1D6B65).withValues(alpha: 0.07);
    const step = 28.0;
    for (var y = step; y < size.height * 0.4; y += step) {
      for (var x = step; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 0.65, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StoreGridPainter oldDelegate) => false;
}
