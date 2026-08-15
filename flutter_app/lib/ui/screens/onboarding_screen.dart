// l10n:ignore-file — onboarding marketing copy mirrors the EN reference
// prototype pixel-perfectly; localization is a deliberate follow-up.
// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa_ui/fa_ui.dart' as faui;
import 'package:fa/services/agent_service.dart' show AgentConfig;
import 'package:fa/services/analytics.dart';
import 'package:fa/services/chatgpt_oauth_flow.dart';
import 'package:fa/services/codemie_sso_flow.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/services/openrouter_oauth_coordinator.dart';
import 'package:fa/ui/widgets/fa_mark.dart';

/// Onboarding matching the reference prototype pixel-by-pixel.
/// Four pages: welcome (chat/apps mockups), provider picker, permissions,
/// ready. Light marketing design on both platforms (the reference is
/// light-only).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    this.onboardingStore,
    this.initialPage = 0,
    this.onFinished,
    this.registry,
    this.lastConnectionStore,
  });

  final OnboardingStore? onboardingStore;
  final int initialPage;
  final void Function({required bool skipped})? onFinished;

  /// The shared provider registry (the page-2 list is the app's Add
  /// Provider list; a tap opens the real provider config flow). When null
  /// (tests) page 2 renders the list but the mandatory gate stays off.
  final faui.ProviderRegistry? registry;

  /// Where the configured provider is persisted as the restorable last
  /// connection (the boot then auto-connects right after onboarding).
  final LastConnectionStore? lastConnectionStore;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

// Design tokens sampled from the reference prototype.
const _kBg = Color(0xFFF7F8FC);
const _kInk = Color(0xFF172033);
const _kPrimary = Color(0xFF3566FF);
const _kGray = Color(0xFF6B768B);
const _kGrayLight = Color(0xFF9AA0B4);
const _kBorder = Color(0xFFE5EAF2);
const _kBubble = Color(0xFFE9EBFC);
const _kSelBg = Color(0xFFEEF1FE);
const _kNavy = Color(0xFF191B2E);
const _kGreen = Color(0xFF10B981);
const _kCardShadow = [
  BoxShadow(color: Color(0x0A172033), blurRadius: 10, offset: Offset(0, 3)),
];

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _labels = ['Ask', 'Think', 'Act', 'Make it yours'];
  late final PageController _pc = PageController(
    initialPage: widget.initialPage,
  );
  late var _page = widget.initialPage;

  /// Set when the user finished a provider config flow on page 2 — the
  /// provider step is mandatory: Continue/Skip stay locked until then.
  var _providerConfigured = false;

  /// The provider gate applies only in the real app (a registry is wired);
  /// tests pumping the bare screen keep the walkthrough skippable.
  bool get _providerGateActive =>
      widget.registry != null && !_providerConfigured;

  @override
  void initState() {
    super.initState();
    AppAnalytics.instance.onboardingStarted();
    AppAnalytics.instance.screenOpened('onboarding');
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _finish({required bool skipped}) {
    if (skipped) {
      AppAnalytics.instance.onboardingSkipped(_page);
    } else {
      AppAnalytics.instance.onboardingCompleted();
    }
    unawaited(widget.onboardingStore?.markSeen() ?? Future<void>.value());
    widget.onFinished?.call(skipped: skipped);
  }

  void _next() => _pc.nextPage(
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeOut,
  );
  void _back() => _pc.previousPage(
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeOut,
  );

  /// A provider flow completed on page 2: unlock the step and slide on.
  void _providerDone() {
    setState(() => _providerConfigured = true);
    if (_page == 1) _next();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 920;
    final last = _page == 3;
    final gated = _page == 1 && _providerGateActive;
    final primaryLabel = switch (_page) {
      2 => 'Continue without access',
      3 => 'Open Fa',
      _ => 'Continue',
    };
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              page: _page,
              labels: _labels,
              wide: wide,
              // The provider step is mandatory — no skipping past it.
              onSkip: gated ? null : () => _finish(skipped: true),
            ),
            Expanded(
              child: PageView(
                controller: _pc,
                onPageChanged: (p) => setState(() => _page = p),
                children: [
                  _P1(wide: wide),
                  _P2(
                    wide: wide,
                    registry: widget.registry,
                    lastConnectionStore: widget.lastConnectionStore,
                    onConfigured: _providerDone,
                  ),
                  _P3(wide: wide),
                  _P4(wide: wide),
                ],
              ),
            ),
            _Footer(
              page: _page,
              wide: wide,
              primaryLabel: primaryLabel,
              primaryEnabled: !gated,
              onPrimary: last ? () => _finish(skipped: false) : _next,
              onBack: _page > 0 ? _back : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header: logo + step tabs + Skip
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.page,
    required this.labels,
    required this.wide,
    required this.onSkip,
  });

  final int page;
  final List<String> labels;
  final bool wide;

  /// Null hides Skip (the mandatory provider step cannot be skipped).
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final steps = _Steps(page: page, labels: labels);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 12, 0),
      child: wide
          ? Row(
              children: [
                const _Logo(),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: steps,
                  ),
                ),
                if (onSkip != null) _SkipButton(onTap: onSkip!),
              ],
            )
          : Column(
              children: [
                Row(
                  children: [
                    const _Logo(),
                    const Spacer(),
                    if (onSkip != null) _SkipButton(onTap: onSkip!),
                  ],
                ),
                const SizedBox(height: 14),
                steps,
              ],
            ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    // The brand app tile (light form — the onboarding is a light design).
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FaBrandTile(size: 30, dark: false),
        SizedBox(width: 8),
        Text(
          'Fa',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: _kInk,
          ),
        ),
      ],
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      child: const Text(
        'Skip',
        style: TextStyle(
          fontSize: 13,
          color: _kGray,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// Step tabs: dots on a connecting line, labels under the dots. Completed
/// steps show a white check in a filled blue circle, the current step is a
/// filled blue dot, future steps are hollow.
class _Steps extends StatelessWidget {
  const _Steps({required this.page, required this.labels});

  final int page;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        const dot = 18.0;
        final seg = w / labels.length;
        return SizedBox(
          height: 44,
          child: Stack(
            children: [
              Positioned(
                left: seg / 2,
                right: seg / 2,
                top: dot / 2 - 1,
                child: Container(height: 2, color: const Color(0xFFE3E5EE)),
              ),
              Row(
                children: [
                  for (var i = 0; i < labels.length; i++)
                    Expanded(
                      child: Column(
                        children: [
                          Container(
                            width: dot,
                            height: dot,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i <= page ? _kPrimary : Colors.white,
                              border: Border.all(
                                color: i <= page
                                    ? _kPrimary
                                    : const Color(0xFFD6D9E4),
                                width: 2,
                              ),
                            ),
                            child: i < page
                                ? const Icon(
                                    Icons.check,
                                    size: 11,
                                    color: Colors.white,
                                  )
                                : null,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            labels[i],
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: i == page
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: i == page ? _kPrimary : _kGrayLight,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Footer: page counter + progress + Back + primary button
// ---------------------------------------------------------------------------

class _Footer extends StatelessWidget {
  const _Footer({
    required this.page,
    required this.wide,
    required this.primaryLabel,
    required this.onPrimary,
    required this.onBack,
    this.primaryEnabled = true,
  });

  final int page;
  final bool wide;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final VoidCallback? onBack;

  /// False greys out the primary button (mandatory provider step).
  final bool primaryEnabled;

  @override
  Widget build(BuildContext context) {
    final counter = Text(
      '${page + 1} of 4',
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: _kInk,
      ),
    );
    final back = TextButton(
      onPressed: onBack,
      child: const Text(
        'Back',
        style: TextStyle(
          fontSize: 13.5,
          color: _kGray,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
    const privacy = _PrivacyLink();
    if (wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(28, 10, 28, 22),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Row(
              children: [
                counter,
                const SizedBox(width: 14),
                _ProgressBar(fraction: (page + 1) / 4, width: 200),
                const Spacer(),
                if (onBack != null) ...[back, const SizedBox(width: 16)],
                SizedBox(
                  width: 250,
                  child: _PrimaryButton(
                    label: primaryLabel,
                    onTap: onPrimary,
                    enabled: primaryEnabled,
                  ),
                ),
              ],
            ),
            // Pinned to the footer center: the Back button appearing on
            // later pages must not shift the link horizontally.
            const Center(child: privacy),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        children: [
          Text(
            '${page + 1} of 4',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: _kPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (onBack != null) ...[back, const SizedBox(width: 12)],
              Expanded(
                child: _PrimaryButton(
                  label: primaryLabel,
                  onTap: onPrimary,
                  showArrow: false,
                  enabled: primaryEnabled,
                ),
              ),
            ],
          ),
          privacy,
        ],
      ),
    );
  }
}

/// Link to the published privacy policy (fa1.dev/privacy.html).
class _PrivacyLink extends StatelessWidget {
  const _PrivacyLink();

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => url_launcher.launchUrl(
        Uri.parse('https://fa1.dev/privacy.html'),
        mode: url_launcher.LaunchMode.externalApplication,
      ),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text(
        'Privacy Policy',
        style: TextStyle(
          fontSize: 11,
          color: _kGrayLight,
          decoration: TextDecoration.underline,
          decorationColor: _kGrayLight,
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.fraction, required this.width});

  final double fraction;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 3,
      decoration: BoxDecoration(
        color: const Color(0xFFECECF3),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: fraction,
          child: Container(
            decoration: BoxDecoration(
              color: _kPrimary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.onTap,
    this.showArrow = true,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;
  final bool showArrow;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled ? _kPrimary : const Color(0xFFB9C2D8),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 52,
          child: Stack(
            children: [
              Center(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              if (showArrow)
                const Positioned(
                  right: 18,
                  top: 0,
                  bottom: 0,
                  child: Icon(
                    Icons.arrow_forward,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared building blocks
// ---------------------------------------------------------------------------

class _TitleBlock extends StatelessWidget {
  const _TitleBlock(this.title, this.subtitle, {this.compact = false});

  final String title;
  final String subtitle;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: compact ? 24 : 34,
            fontWeight: FontWeight.w800,
            color: _kInk,
            letterSpacing: -0.5,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: compact ? 13 : 15,
            color: _kGray,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

Widget _card({
  required Widget child,
  EdgeInsets padding = const EdgeInsets.all(16),
}) {
  return Container(
    padding: padding,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: _kBorder),
    ),
    child: child,
  );
}

/// Wide-viewport wrapper: centers the page content vertically (and caps its
/// width) so large screens don't leave the content glued to the top.
class _WideFit extends StatelessWidget {
  const _WideFit({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1060),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Narrow-viewport wrapper: scales the whole page content down uniformly so
/// the full page fits the viewport without scrolling, matching the reference
/// prototype proportions on phones.
class _NarrowFit extends StatelessWidget {
  const _NarrowFit({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth > 460 ? 460.0 : constraints.maxWidth;
        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: w,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The lavender user chat bubble from the reference.
class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              decoration: BoxDecoration(
                color: _kBubble,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Build a focus timer with work and break sessions.',
                    style: TextStyle(fontSize: 13, color: _kInk, height: 1.35),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        wide ? 'Just now' : '9:41 AM',
                        style: const TextStyle(
                          fontSize: 10,
                          color: _kGrayLight,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.done_all, size: 12, color: _kPrimary),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fa "typing" response: navy avatar + title + typing dots in a light bubble.
class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6FA),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            children: [
              _FaAvatar(size: 26),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Understanding your request…',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _kInk,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _dot(const Color(0xFF293FF2)),
              _dot(const Color(0xFF7C88F7)),
              _dot(const Color(0xFFC3C9FB)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dot(Color c) {
    return Container(
      width: 8,
      height: 8,
      margin: const EdgeInsets.only(right: 6, left: 2),
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
  }
}

class _FaAvatar extends StatelessWidget {
  const _FaAvatar({this.size = 26});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _kNavy,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(
        Icons.auto_awesome,
        size: size * 0.5,
        color: const Color(0xFF5B8DEF),
      ),
    );
  }
}

/// Chat input mockup: "+ Ask anything…" and a blue send button.
class _ChatInput extends StatelessWidget {
  const _ChatInput();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F5FA),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          const Icon(Icons.add, size: 18, color: _kGrayLight),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Ask anything…',
              style: TextStyle(fontSize: 12.5, color: _kGrayLight),
            ),
          ),
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(
              color: _kPrimary,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.send_rounded,
              size: 14,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// The dark Focus Timer card.
class _FocusCard extends StatelessWidget {
  const _FocusCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kNavy,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            children: [
              Text(
                'Focus Timer',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              Spacer(),
              Icon(Icons.more_horiz, size: 16, color: Colors.white54),
            ],
          ),
          const SizedBox(height: 4),
          const Row(
            children: [
              Icon(Icons.circle, size: 6, color: Color(0xFF34D399)),
              SizedBox(width: 5),
              Text(
                'Active',
                style: TextStyle(
                  fontSize: 10.5,
                  color: Color(0xFF34D399),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _FocusRing(size: 128, timeSize: 30),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Center(
              child: Text(
                'Start Session',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Work 25 min • Break 5 min',
            style: TextStyle(fontSize: 10, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

class _FocusRing extends StatelessWidget {
  const _FocusRing({required this.size, required this.timeSize});

  final double size;
  final double timeSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: 0.75,
              strokeWidth: size * 0.05,
              backgroundColor: Colors.white.withValues(alpha: 0.12),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF5B8DEF)),
              strokeCap: StrokeCap.round,
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '25:00',
                  style: TextStyle(
                    fontSize: timeSize,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  'Focus time',
                  style: TextStyle(
                    fontSize: timeSize * 0.38,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// App tiles (iOS-style icons)
// ---------------------------------------------------------------------------

enum _AppKind {
  calendar,
  notes,
  utilities,
  files,
  calculator,
  maps,
  focusTimer,
  settings,
  addApp,
  habitGarden,
  createWithFa,
}

class _AppTile extends StatelessWidget {
  const _AppTile(this.kind, this.label, {this.badge, this.size = 48});

  final _AppKind kind;
  final String label;
  final String? badge;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: _tileBg,
            borderRadius: BorderRadius.circular(size * 0.28),
            boxShadow: _kCardShadow,
          ),
          child: Center(child: _glyph(size / 48)),
        ),
        if (badge != null)
          Positioned(
            top: -4,
            right: -4,
            child: badge == '1'
                ? Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: _kPrimary,
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: Text(
                        '1',
                        style: TextStyle(
                          fontSize: 9,
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                : Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: badge == 'Demo'
                          ? const Color(0xFF9AA0B4)
                          : _kPrimary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      badge!,
                      style: const TextStyle(
                        fontSize: 7.5,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
          ),
      ],
    );
    if (label.isEmpty) return icon;
    return SizedBox(
      width: size + 18,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(height: 5),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 9.5,
              color: _kGray,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Color get _tileBg => switch (kind) {
    _AppKind.files => const Color(0xFF2F7CF6),
    _AppKind.calculator => const Color(0xFF1B1D2A),
    _AppKind.focusTimer => _kNavy,
    _AppKind.settings => const Color(0xFFEEF0F5),
    _AppKind.addApp || _AppKind.createWithFa => const Color(0xFFF3F4F8),
    _AppKind.habitGarden => const Color(0xFFE8F9F1),
    _ => Colors.white,
  };

  Widget _glyph(double s) => switch (kind) {
    _AppKind.calendar => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20 * s,
          height: 4 * s,
          decoration: BoxDecoration(
            color: const Color(0xFF2F7CF6),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        SizedBox(height: 2 * s),
        Text(
          '31',
          style: TextStyle(
            fontSize: 15 * s,
            fontWeight: FontWeight.w800,
            color: const Color(0xFF2F7CF6),
            height: 1,
          ),
        ),
      ],
    ),
    _AppKind.notes => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22 * s,
          height: 6 * s,
          decoration: BoxDecoration(
            color: const Color(0xFFFBBF24),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        SizedBox(height: 3 * s),
        for (var i = 0; i < 3; i++)
          Container(
            width: 18 * s,
            height: 2 * s,
            margin: EdgeInsets.symmetric(vertical: 1.4 * s),
            decoration: BoxDecoration(
              color: const Color(0xFFD8DBE6),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
      ],
    ),
    _AppKind.utilities => Wrap(
      spacing: 2.5 * s,
      runSpacing: 2.5 * s,
      children: [
        for (final c in const [
          Color(0xFF5B8DEF),
          Color(0xFFFBBF24),
          Color(0xFF2EBD9E),
          Color(0xFF9AA0B4),
        ])
          Container(
            width: 9 * s,
            height: 9 * s,
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(2.5 * s),
            ),
          ),
      ],
    ),
    _AppKind.files => Icon(Icons.folder, size: 24 * s, color: Colors.white),
    _AppKind.calculator => Wrap(
      spacing: 2 * s,
      runSpacing: 2 * s,
      children: [
        for (var i = 0; i < 9; i++)
          Container(
            width: 5 * s,
            height: 5 * s,
            decoration: BoxDecoration(
              color: i == 7 ? const Color(0xFFF59E0B) : const Color(0xFF8A8FA8),
              borderRadius: BorderRadius.circular(1.2 * s),
            ),
          ),
      ],
    ),
    _AppKind.maps => Icon(
      Icons.place,
      size: 24 * s,
      color: const Color(0xFFEA4335),
    ),
    _AppKind.focusTimer => SizedBox(
      width: 24 * s,
      height: 24 * s,
      child: CircularProgressIndicator(
        value: 0.75,
        strokeWidth: 2.5 * s,
        backgroundColor: Colors.white.withValues(alpha: 0.2),
        valueColor: const AlwaysStoppedAnimation(Color(0xFF5B8DEF)),
      ),
    ),
    _AppKind.settings => Icon(
      Icons.settings,
      size: 24 * s,
      color: const Color(0xFF7A7F96),
    ),
    _AppKind.addApp || _AppKind.createWithFa => Icon(
      Icons.add,
      size: 24 * s,
      color: const Color(0xFF9AA0B4),
    ),
    _AppKind.habitGarden => Icon(
      Icons.eco,
      size: 22 * s,
      color: const Color(0xFF10B981),
    ),
  };
}

// ---------------------------------------------------------------------------
// Page 1: Start with an idea
// ---------------------------------------------------------------------------

class _P1 extends StatelessWidget {
  const _P1({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: wide ? 20 : 12),
        _TitleBlock(
          'Start with an idea.',
          'Ask a question, automate a task, or describe an app you want to use.',
          compact: !wide,
        ),
        SizedBox(height: wide ? 24 : 18),
        if (wide) _wideBody() else _narrowBody(),
        SizedBox(height: wide ? 24 : 18),
        _FeaturesRow(wide: wide),
        SizedBox(height: wide ? 28 : 20),
      ],
    );
    if (!wide) return _NarrowFit(child: body);
    return _WideFit(child: body);
  }

  Widget _wideBody() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 26),
                child: _card(
                  padding: const EdgeInsets.all(26),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Expanded(flex: 12, child: _ChatColumn()),
                      const SizedBox(width: 24),
                      const Expanded(flex: 8, child: _FocusCard()),
                      const SizedBox(width: 24),
                      Expanded(
                        flex: 11,
                        child: _AppsGrid(
                          columns: 3,
                          kinds: const [
                            (_AppKind.calendar, 'Calendar', null),
                            (_AppKind.notes, 'Notes', null),
                            (_AppKind.utilities, 'Utilities', null),
                            (_AppKind.files, 'Files', null),
                            (_AppKind.calculator, 'Calculator', null),
                            (_AppKind.maps, 'Maps', null),
                            (_AppKind.focusTimer, 'Focus Timer', '1'),
                            (_AppKind.settings, 'Settings', null),
                            (_AppKind.addApp, 'Add app', null),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Positioned(top: 0, left: 380, child: _IdeaPill()),
            ],
          ),
        ),
        const SizedBox(width: 20),
        const Opacity(
          opacity: 0.45,
          child: IgnorePointer(
            child: SizedBox(width: 230, child: _ProviderGhost()),
          ),
        ),
      ],
    );
  }

  Widget _narrowBody() {
    return Column(
      children: [
        _card(
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _UserBubble(wide: false),
              SizedBox(height: 12),
              _TypingBubble(),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // "Your idea" card + mini step indicator (like the reference).
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: _kCardShadow,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _kSelBg,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.lightbulb_outline,
                        size: 18,
                        color: _kPrimary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Your idea',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: _kInk,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Build a focus timer with work and break sessions.',
                            style: TextStyle(
                              fontSize: 12,
                              color: _kGray,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            const _MiniSteps(),
          ],
        ),
      ],
    );
  }
}

/// Floating idea pill above the desktop page-1 panel.
class _IdeaPill extends StatelessWidget {
  const _IdeaPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1410132B),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 15, color: _kPrimary),
          SizedBox(width: 8),
          Text(
            'Build a focus timer\nwith work and break sessions.',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: _kInk,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Mini 3-dot step indicator next to the idea card (mobile page 1).
class _MiniSteps extends StatelessWidget {
  const _MiniSteps();

  static const _labels = ['Think', 'Act', 'Yours'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      height: 40,
      child: Stack(
        children: [
          const Positioned(
            left: 25,
            right: 25,
            top: 5,
            child: Divider(height: 2, thickness: 2, color: Color(0xFFE3E5EE)),
          ),
          Row(
            children: [
              for (var i = 0; i < _labels.length; i++)
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == 0 ? _kPrimary : Colors.white,
                          border: Border.all(
                            color: i == 0 ? _kPrimary : const Color(0xFFD6D9E4),
                            width: 2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _labels[i],
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: i == 0
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: i == 0 ? _kInk : _kGrayLight,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChatColumn extends StatelessWidget {
  const _ChatColumn();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _UserBubble(wide: true),
        SizedBox(height: 14),
        _TypingBubble(),
        SizedBox(height: 16),
        _ChatInput(),
      ],
    );
  }
}

class _AppsGrid extends StatelessWidget {
  const _AppsGrid({required this.columns, required this.kinds});

  final int columns;
  final List<(_AppKind, String, String?)> kinds;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 14,
      children: [
        for (final (kind, label, badge) in kinds)
          _AppTile(kind, label, badge: badge),
      ],
    );
  }
}

class _FeaturesRow extends StatelessWidget {
  const _FeaturesRow({required this.wide});
  final bool wide;

  static const _items = [
    (Icons.chat_bubble, 'Answers questions', Color(0xFF5B63F0)),
    (Icons.grid_view_rounded, 'Uses your apps', Color(0xFF2EBD9E)),
    (Icons.auto_awesome, 'Builds new apps', Color(0xFF5B63F0)),
  ];

  @override
  Widget build(BuildContext context) {
    if (wide) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final (icon, label, color) in _items) ...[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: _kGray,
              ),
            ),
            const SizedBox(width: 36),
          ],
        ],
      );
    }
    return Row(
      children: [
        for (final (icon, label, color) in _items) ...[
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _kBorder),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: _kInk,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (label != _items.last.$2) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

/// Faded "Choose how Fa thinks." preview shown on page 1 (desktop).
class _ProviderGhost extends StatelessWidget {
  const _ProviderGhost();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Choose how Fa thinks.',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: _kInk,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Connect a provider to start chatting.',
          style: TextStyle(fontSize: 11.5, color: _kGray),
        ),
        const SizedBox(height: 16),
        _ghostRow(
          Icons.autorenew,
          'OpenRouter',
          'Recommended',
          'Access 100+ models from top AI providers.',
        ),
        _ghostRow(
          Icons.cruelty_free,
          'Ollama',
          'Local',
          'Run open-source models on your device.',
        ),
        _ghostRow(
          Icons.auto_awesome,
          'Google Gemini',
          null,
          "Google's latest models with advanced reasoning.",
        ),
        _ghostRow(
          Icons.code,
          'Custom provider',
          null,
          'Connect any OpenAI-compatible API.',
        ),
      ],
    );
  }

  Widget _ghostRow(IconData icon, String name, String? badge, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: _kGrayLight),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: _kInk,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 6),
                      _Badge(badge),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: _kGray,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final rec = text == 'Recommended';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: rec ? const Color(0xFFE5EAFE) : const Color(0xFFE3F7EE),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: rec ? _kPrimary : const Color(0xFF0E9F6E),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 2: Choose how Fa thinks
// ---------------------------------------------------------------------------

class _P2 extends StatefulWidget {
  const _P2({
    required this.wide,
    this.registry,
    this.lastConnectionStore,
    this.onConfigured,
  });

  final bool wide;

  /// The shared provider registry; null renders the list inert (tests).
  final faui.ProviderRegistry? registry;

  /// Persists the configured provider as the restorable last connection.
  final LastConnectionStore? lastConnectionStore;

  /// Fired once a provider config flow completes successfully.
  final VoidCallback? onConfigured;

  @override
  State<_P2> createState() => _P2State();
}

class _P2State extends State<_P2> {
  /// The preset key that completed its config flow (gets the check).
  String? _configuredKey;
  var _busy = false;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: widget.wide ? 20 : 12),
        _TitleBlock(
          'Choose how Fa thinks.',
          'Connect a provider to start chatting.\nYou can switch models anytime.',
          compact: !widget.wide,
        ),
        SizedBox(height: widget.wide ? 24 : 18),
        if (widget.wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(width: 220, child: _RequestCard()),
              const SizedBox(width: 24),
              Expanded(child: _cards()),
              const SizedBox(width: 24),
              const Opacity(
                opacity: 0.45,
                child: IgnorePointer(
                  child: SizedBox(width: 220, child: _AccessGhost()),
                ),
              ),
            ],
          )
        else ...[
          const _RequestConfirmedCard(),
          const SizedBox(height: 14),
          _cards(),
        ],
        const SizedBox(height: 18),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F8),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_outlined, size: 15, color: _kGrayLight),
                SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'API keys stay in your system Keychain.\nContent is sent only to providers you connect.',
                    style: TextStyle(fontSize: 11, color: _kGray, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: widget.wide ? 28 : 20),
      ],
    );
    // The full provider list is taller than a phone viewport: scroll it
    // instead of the scale-to-fit used by the other pages.
    if (!widget.wide) {
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: body,
          ),
        ),
      );
    }
    return _WideFit(child: body);
  }

  Widget _cards() {
    // The SAME list the app's "Add provider" picker shows.
    return Column(
      children: [
        for (final preset in faui.defaultAddProviderPresets) ...[
          _ProviderCard(
            preset: preset,
            configured: _configuredKey == preset.key,
            onTap: _busy ? null : () => _configure(preset),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  /// Routes a preset tap to the provider's real config flow (the same
  /// routing as the app's Add Provider picker): SSO/OAuth flows for
  /// CodeMie/ChatGPT, the editor for key-based presets and Custom.
  Future<void> _configure(faui.AddProviderPreset preset) async {
    final registry = widget.registry;
    if (registry == null) return;
    setState(() => _busy = true);
    var ok = false;
    try {
      switch (preset.key) {
        case 'codemie':
          ok = await runCodemieSsoFlow(
            context: context,
            registry: registry,
            service: null, // no live service during onboarding
            lastConnectionStore:
                widget.lastConnectionStore ?? LastConnectionStore.inMemory(),
          );
        case 'chatgpt':
          ok = await runChatGptOAuthFlow(
            context: context,
            registry: registry,
            service: null,
            lastConnectionStore:
                widget.lastConnectionStore ?? LastConnectionStore.inMemory(),
          );
        case 'custom':
          final provider = await faui.pushProviderEditor(
            context,
            registry,
            title: preset.name,
          );
          ok = provider != null;
          if (ok) {
            await _saveConnection(provider.baseUrl, provider.modelId, '');
          }
        default:
          ok = await _configureKeyBased(preset, registry);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (ok && mounted) {
      setState(() => _configuredKey = preset.key);
      widget.onConfigured?.call();
    }
  }

  /// Key-based preset: the editor pre-filled with the preset endpoint,
  /// then persist the provider, its key, and the last connection.
  Future<bool> _configureKeyBased(
    faui.AddProviderPreset preset,
    faui.ProviderRegistry registry,
  ) async {
    final presetMode = switch (preset.key) {
      'openrouter' => faui.ProviderPreset.openrouter,
      'ollama' => faui.ProviderPreset.ollamaCloud,
      'google' => faui.ProviderPreset.gemini,
      'dial' => faui.ProviderPreset.dial,
      _ => faui.ProviderPreset.custom,
    };
    final editable =
        preset.key != 'dial' && presetMode == faui.ProviderPreset.custom;
    final result = await faui.pushFaPage<faui.ProviderEditorResult>(
      context,
      faui.ProviderEditorPage(
        title: preset.name,
        preset: editable ? null : presetMode,
        prefillName: editable ? preset.name : null,
        prefillBaseUrl: editable ? preset.baseUrl : null,
        keyHelpUrl: preset.keyHelpUrl,
        registry: registry,
        openRouterOAuthCallbackUrl:
            OpenRouterOAuthCoordinator.instance.platformCallbackUrl,
        openRouterOAuthCapture: OpenRouterOAuthCoordinator.instance.capture,
      ),
    );
    if (result == null || result.deleted) return false;
    final provider = await registry.add(
      name: result.name,
      baseUrl: result.baseUrl,
      modelId: result.modelId,
    );
    if (result.apiKey.isNotEmpty) {
      registry.rememberKey(provider.id, result.apiKey);
    }
    await _saveConnection(result.baseUrl, result.modelId, result.apiKey);
    return true;
  }

  /// Persists the fresh connection so the boot auto-connects straight to
  /// chat after onboarding (the key itself resolves via the registry).
  Future<void> _saveConnection(String baseUrl, String modelId, String apiKey) {
    final store = widget.lastConnectionStore;
    if (store == null) return Future<void>.value();
    return store.saveFromConfig(
      AgentConfig(
        providerKind: 'openai-completions',
        modelId: modelId,
        baseUrl: baseUrl,
        apiKey: apiKey,
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.preset,
    required this.configured,
    required this.onTap,
  });

  final faui.AddProviderPreset preset;
  final bool configured;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: configured ? _kSelBg : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: configured ? _kPrimary : _kBorder,
              width: configured ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: configured ? Colors.white : const Color(0xFFF3F4F8),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  preset.icon,
                  size: 20,
                  color: configured ? _kPrimary : _kGray,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preset.name,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: _kInk,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preset.description,
                      style: const TextStyle(fontSize: 12, color: _kGray),
                    ),
                  ],
                ),
              ),
              if (configured)
                Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                    color: _kPrimary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, size: 13, color: Colors.white),
                )
              else
                const Icon(Icons.chevron_right, size: 20, color: _kGrayLight),
            ],
          ),
        ),
      ),
    );
  }
}

/// Floating "Your request" card (desktop page 2).
class _RequestCard extends StatelessWidget {
  const _RequestCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kBorder),
        boxShadow: _kCardShadow,
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Your request',
            style: TextStyle(
              fontSize: 11,
              color: _kGray,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.auto_awesome, size: 15, color: _kPrimary),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Build a focus timer with work and break sessions.',
                  style: TextStyle(fontSize: 11.5, color: _kInk, height: 1.35),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact confirmed-request card (mobile page 2).
class _RequestConfirmedCard extends StatelessWidget {
  const _RequestConfirmedCard();

  @override
  Widget build(BuildContext context) {
    return _card(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
              color: Color(0xFFE3F7EE),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check, size: 17, color: _kGreen),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Build a focus timer with work and break sessions.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _kInk,
                height: 1.3,
              ),
            ),
          ),
          const Icon(Icons.auto_awesome, size: 18, color: _kPrimary),
        ],
      ),
    );
  }
}

/// Faded "Give access" preview shown on page 2 (desktop).
class _AccessGhost extends StatelessWidget {
  const _AccessGhost();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Fa can take action for you.',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: _kInk,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Fa asks only when an action needs it.',
          style: TextStyle(fontSize: 11, color: _kGray),
        ),
        const SizedBox(height: 14),
        for (final (icon, label) in const [
          (Icons.calendar_month, 'Calendar & Reminders'),
          (Icons.notifications, 'Notifications'),
          (Icons.mic, 'Microphone'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Icon(icon, size: 16, color: _kGrayLight),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: _kInk,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Text(
                  'Ask when needed',
                  style: TextStyle(
                    fontSize: 9.5,
                    color: _kPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Page 3: Give access only when it helps
// ---------------------------------------------------------------------------

class _P3 extends StatelessWidget {
  const _P3({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: wide ? 20 : 12),
        _TitleBlock(
          'Give access only when it helps.',
          'Fa asks only when an action needs it.\nYou can change access anytime.',
          compact: !wide,
        ),
        SizedBox(height: wide ? 24 : 16),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    const _FlowDiagram(),
                    const SizedBox(height: 16),
                    const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _PermCard(
                            icon: Icons.calendar_month,
                            tint: Color(0xFFEF4444),
                            tintBg: Color(0xFFFDECEC),
                            title: 'Calendar & Reminders',
                            desc: 'Check your schedule and create events.',
                            vertical: true,
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: _PermCard(
                            icon: Icons.notifications,
                            tint: Color(0xFF3B82F6),
                            tintBg: Color(0xFFEAF2FE),
                            title: 'Notifications',
                            desc: 'Send reminders and task updates.',
                            vertical: true,
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: _PermCard(
                            icon: Icons.mic,
                            tint: Color(0xFF8B5CF6),
                            tintBg: Color(0xFFF1EDFE),
                            title: 'Microphone',
                            desc: 'Talk to Fa with your voice.',
                            vertical: true,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              const Expanded(flex: 2, child: _WhatYouGet()),
            ],
          )
        else ...[
          const _FlowCard(),
          const SizedBox(height: 10),
          const _PermCard(
            icon: Icons.calendar_month,
            tint: Color(0xFFEF4444),
            tintBg: Color(0xFFFDECEC),
            title: 'Calendar & Reminders',
            desc: 'Check your schedule and create events.',
          ),
          const SizedBox(height: 8),
          const _PermCard(
            icon: Icons.notifications,
            tint: Color(0xFF3B82F6),
            tintBg: Color(0xFFEAF2FE),
            title: 'Notifications',
            desc: 'Send reminders and task updates.',
          ),
          const SizedBox(height: 8),
          const _PermCard(
            icon: Icons.mic,
            tint: Color(0xFF8B5CF6),
            tintBg: Color(0xFFF1EDFE),
            title: 'Microphone',
            desc: 'Talk to Fa with your voice.',
          ),
        ],
        SizedBox(height: wide ? 18 : 12),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.verified_user_outlined,
              size: 16,
              color: Color(0xFF5B63F0),
            ),
            SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Nothing is enabled by default.',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _kInk,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'You can manage access anytime in Settings.',
                    style: TextStyle(fontSize: 11, color: _kGray),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (!wide) ...[const SizedBox(height: 12), const _MyAppsMini()],
        SizedBox(height: wide ? 28 : 20),
      ],
    );
    if (!wide) return _NarrowFit(child: body);
    return _WideFit(child: body);
  }
}

class _FlowCard extends StatelessWidget {
  const _FlowCard();

  @override
  Widget build(BuildContext context) {
    return _card(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: Color(0xFFE3F7EE),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check, size: 18, color: _kGreen),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Build a focus timer with work and break sessions.',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _kInk,
                    height: 1.3,
                  ),
                ),
                SizedBox(height: 5),
                Row(
                  children: [
                    Icon(Icons.timer_outlined, size: 13, color: _kGray),
                    SizedBox(width: 5),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'Focus Timer',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: _kInk,
                              ),
                            ),
                            TextSpan(
                              text: '  ·  No access needed',
                              style: TextStyle(
                                fontSize: 11,
                                color: _kGreen,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Desktop page-3 flow: request pill → arrow → app pill (like the reference).
class _FlowDiagram extends StatelessWidget {
  const _FlowDiagram();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _card(
            padding: const EdgeInsets.all(12),
            child: const Row(
              children: [
                Icon(Icons.auto_awesome, size: 16, color: _kPrimary),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Build a focus timer with work and break sessions.',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: _kInk,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Icon(Icons.arrow_forward, size: 18, color: _kGrayLight),
        ),
        Expanded(
          child: _card(
            padding: const EdgeInsets.all(12),
            child: const Row(
              children: [
                Icon(Icons.timer_outlined, size: 16, color: _kPrimary),
                SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Focus Timer',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _kInk,
                        ),
                      ),
                      Text(
                        'no access needed',
                        style: TextStyle(
                          fontSize: 10,
                          color: _kGreen,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.check_circle, size: 16, color: _kGreen),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PermCard extends StatelessWidget {
  const _PermCard({
    required this.icon,
    required this.tint,
    required this.tintBg,
    required this.title,
    required this.desc,
    this.vertical = false,
  });

  final IconData icon;
  final Color tint;
  final Color tintBg;
  final String title;
  final String desc;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final iconBox = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: tintBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, size: 21, color: tint),
    );
    final askPill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _kSelBg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: const Text(
        'Ask when needed',
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          color: _kPrimary,
        ),
      ),
    );
    final allow = Container(
      width: 62,
      height: 30,
      decoration: BoxDecoration(
        color: _kSelBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Center(
        child: Text(
          'Allow',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: _kPrimary,
          ),
        ),
      ),
    );
    final later = Container(
      width: 62,
      height: 30,
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Center(
        child: Text(
          'Later',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: _kGray,
          ),
        ),
      ),
    );

    if (vertical) {
      return _card(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            iconBox,
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _kInk,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              desc,
              style: const TextStyle(fontSize: 11, color: _kGray, height: 1.35),
            ),
            const SizedBox(height: 8),
            askPill,
            const SizedBox(height: 12),
            Row(children: [allow, const SizedBox(width: 8), later]),
          ],
        ),
      );
    }
    return _card(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          iconBox,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: _kInk,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  desc,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: _kGray,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 7),
                askPill,
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(children: [allow, const SizedBox(height: 8), later]),
        ],
      ),
    );
  }
}

/// Right "What you'll get" panel (desktop page 3).
class _WhatYouGet extends StatelessWidget {
  const _WhatYouGet();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          "What you'll get",
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: _kGray,
          ),
        ),
        const SizedBox(height: 10),
        _card(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '25:00',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: _kInk,
                      letterSpacing: -0.5,
                    ),
                  ),
                  Text('Focus', style: TextStyle(fontSize: 11, color: _kGray)),
                ],
              ),
              const Spacer(),
              Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                  color: _kPrimary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow,
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'My Apps',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: _kGray,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _mini(_AppKind.calendar), _mini(_AppKind.files),
            _mini(_AppKind.notes), _mini(_AppKind.maps),
            _mini(_AppKind.calculator), _mini(_AppKind.focusTimer),
            // Weather chip.
            Container(
              width: 56,
              height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF60A5FA), Color(0xFF3B82F6)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Center(
                child: Text(
                  '24°',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _mini(_AppKind kind) {
    return SizedBox(
      width: 32,
      height: 32,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: _AppTile(kind, '', size: 32),
      ),
    );
  }
}

/// Bottom "My Apps" mini panel (mobile page 3).
class _MyAppsMini extends StatelessWidget {
  const _MyAppsMini();

  @override
  Widget build(BuildContext context) {
    return _card(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          // Mini focus widget.
          Container(
            width: 92,
            height: 104,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _kNavy,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Focus Timer',
                  style: TextStyle(fontSize: 7.5, color: Colors.white54),
                ),
                SizedBox(height: 4),
                _FocusRing(size: 40, timeSize: 12),
                SizedBox(height: 4),
                Icon(Icons.play_circle, size: 16, color: Color(0xFF5B8DEF)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Text(
                      'My Apps',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: _kInk,
                      ),
                    ),
                    Spacer(),
                    Icon(Icons.tune, size: 11, color: _kGrayLight),
                    SizedBox(width: 3),
                    Text(
                      'Customize',
                      style: TextStyle(fontSize: 9, color: _kGrayLight),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final k in const [
                      _AppKind.calendar,
                      _AppKind.files,
                      _AppKind.notes,
                      _AppKind.maps,
                      _AppKind.calculator,
                      _AppKind.settings,
                      _AppKind.utilities,
                      _AppKind.addApp,
                    ])
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: FittedBox(child: _AppTile(k, '', size: 24)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 4: Your sandbox is ready
// ---------------------------------------------------------------------------

class _P4 extends StatelessWidget {
  const _P4({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: wide ? 20 : 12),
        _TitleBlock(
          'Your sandbox is ready.',
          'Use apps yourself, let Fa use them for you,\nor ask Fa to make something new.',
          compact: !wide,
        ),
        SizedBox(height: wide ? 24 : 16),
        if (wide)
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: _CreatedColumn()),
              SizedBox(width: 20),
              Expanded(flex: 6, child: _MyAppsPanel()),
            ],
          )
        else ...const [
          _CreatedCard(),
          SizedBox(height: 10),
          _MyAppsPanel(compact: true),
        ],
        SizedBox(height: wide ? 22 : 14),
        const Text(
          'Try these ideas to get started',
          style: TextStyle(fontSize: 12, color: _kGray),
        ),
        const SizedBox(height: 8),
        _Suggestions(wide: wide),
        SizedBox(height: wide ? 28 : 20),
      ],
    );
    if (!wide) return _NarrowFit(child: body);
    return _WideFit(child: body);
  }
}

class _CreatedColumn extends StatelessWidget {
  const _CreatedColumn();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [_TimelineCard(), SizedBox(height: 14), _NavyAppCard()],
    );
  }
}

/// Desktop page-4 left card: 3 timeline entries with "Just now" stamps.
class _TimelineCard extends StatelessWidget {
  const _TimelineCard();

  static const _entries = [
    (
      Icons.auto_awesome,
      'Focus Timer created',
      'Fa built and added this app to your workspace.',
    ),
    (
      Icons.person_outline,
      'You asked',
      'Build a focus timer with work and break sessions.',
    ),
    (
      Icons.auto_awesome,
      'Fa delivered',
      'Focus Timer — 25/5 focus sessions with work and break cycles.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return _card(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _entries.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: i == 1 ? const Color(0xFFF3F4F8) : _kSelBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _entries[i].$1,
                    size: 16,
                    color: i == 1 ? _kGray : _kPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _entries[i].$2,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _kInk,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _entries[i].$3,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: _kGray,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Just now',
                  style: TextStyle(fontSize: 10, color: _kGrayLight),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CreatedCard extends StatelessWidget {
  const _CreatedCard();

  @override
  Widget build(BuildContext context) {
    return _card(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _kSelBg,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.event_available,
                  size: 20,
                  color: _kPrimary,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Focus Timer created',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: _kInk,
                      ),
                    ),
                    SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(Icons.circle, size: 6, color: _kGreen),
                        SizedBox(width: 5),
                        Text(
                          'Completed',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _kGreen,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4FE),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Build a focus timer with work and break sessions.',
                    style: TextStyle(fontSize: 12, color: _kInk, height: 1.35),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: _kGreen, width: 1.5),
                  ),
                  child: const Icon(Icons.check, size: 12, color: _kGreen),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _kPrimary, width: 1.2),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.open_in_new, size: 14, color: _kPrimary),
                SizedBox(width: 6),
                Text(
                  'Open Focus Timer',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _kPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Navy app card under the created card (desktop page 4).
class _NavyAppCard extends StatelessWidget {
  const _NavyAppCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kNavy,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              value: 0.75,
              strokeWidth: 3.5,
              backgroundColor: Color(0x33FFFFFF),
              valueColor: AlwaysStoppedAnimation(Color(0xFF5B8DEF)),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Focus Timer',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '25/5 focus sessions with work and break cycles.',
                  style: TextStyle(fontSize: 10.5, color: Colors.white60),
                ),
              ],
            ),
          ),
          const Row(
            children: [
              Text(
                'Open',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              SizedBox(width: 2),
              Icon(Icons.arrow_forward, size: 13, color: Colors.white),
            ],
          ),
        ],
      ),
    );
  }
}

class _MyAppsPanel extends StatelessWidget {
  const _MyAppsPanel({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tileSize = compact ? 44.0 : 48.0;
    return _card(
      padding: EdgeInsets.all(compact ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            children: [
              Text(
                'My Apps',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _kInk,
                ),
              ),
              Spacer(),
              Icon(Icons.tune, size: 14, color: _kGrayLight),
              SizedBox(width: 4),
              Text(
                'Customize',
                style: TextStyle(
                  fontSize: 11,
                  color: _kGray,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 10 : 14),
          // Widgets row: Focus timer, Weather, Upcoming.
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 10, child: _FocusWidget()),
              SizedBox(width: 10),
              Expanded(flex: 10, child: _WeatherWidget()),
              SizedBox(width: 10),
              Expanded(flex: 13, child: _UpcomingWidget()),
            ],
          ),
          SizedBox(height: compact ? 12 : 16),
          Wrap(
            spacing: 4,
            runSpacing: compact ? 8 : 12,
            children: [
              _AppTile(_AppKind.calendar, 'Calendar', size: tileSize),
              _AppTile(_AppKind.files, 'Files', size: tileSize),
              _AppTile(_AppKind.notes, 'Notes', size: tileSize),
              _AppTile(_AppKind.maps, 'Maps', size: tileSize),
              _AppTile(_AppKind.utilities, 'Utilities', size: tileSize),
              _AppTile(_AppKind.calculator, 'Calculator', size: tileSize),
              _AppTile(_AppKind.settings, 'Settings', size: tileSize),
              _AppTile(_AppKind.focusTimer, 'Focus Timer', size: tileSize),
              _AppTile(
                _AppKind.habitGarden,
                'Habit Garden',
                badge: 'Demo',
                size: tileSize,
              ),
              _AppTile(_AppKind.createWithFa, 'Create with Fa', size: tileSize),
            ],
          ),
        ],
      ),
    );
  }
}

class _FocusWidget extends StatelessWidget {
  const _FocusWidget();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 114,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _kNavy,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  'Focus Timer',
                  style: TextStyle(fontSize: 8.5, color: Colors.white54),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.auto_awesome, size: 8, color: Colors.white38),
            ],
          ),
          Spacer(),
          Center(child: _FocusRing(size: 50, timeSize: 15)),
          Spacer(),
          Center(
            child: Icon(Icons.play_circle, size: 20, color: Color(0xFF5B8DEF)),
          ),
        ],
      ),
    );
  }
}

class _WeatherWidget extends StatelessWidget {
  const _WeatherWidget();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 114,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF60A5FA), Color(0xFF3B82F6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wb_sunny, size: 12, color: Colors.white),
              Spacer(),
              Icon(Icons.auto_awesome, size: 8, color: Colors.white38),
            ],
          ),
          Spacer(),
          Text(
            '24°',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1,
            ),
          ),
          Text('Sunny', style: TextStyle(fontSize: 10, color: Colors.white)),
          SizedBox(height: 2),
          Text(
            '↑ 26°  ↓ 15°',
            style: TextStyle(fontSize: 8.5, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _UpcomingWidget extends StatelessWidget {
  const _UpcomingWidget();

  static const _events = [
    (Color(0xFF5B8DEF), 'Design review', '10:00 AM'),
    (Color(0xFFF59E0B), 'Lunch with team', '12:30 PM'),
    (Color(0xFF2EBD9E), 'Project sync', '3:00 PM'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 114,
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Upcoming',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: _kGray,
            ),
          ),
          const SizedBox(height: 6),
          for (final (c, title, time) in _events)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(top: 3),
                    decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w600,
                            color: _kInk,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          time,
                          style: const TextStyle(
                            fontSize: 7.5,
                            color: _kGrayLight,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.wide});
  final bool wide;

  static const _items = [
    (Icons.auto_awesome, 'Plan my day', Color(0xFFF59E0B)),
    (Icons.fitness_center, 'Build a workout tracker', Color(0xFF5B8DEF)),
    (Icons.credit_card, 'Create an expense app', Color(0xFF2EBD9E)),
  ];

  @override
  Widget build(BuildContext context) {
    final cards = [
      for (final (icon, label, color) in _items)
        Container(
          width: wide ? 180 : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _kBorder),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _kInk,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
    if (wide) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            cards[i],
          ],
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: cards[i]),
        ],
      ],
    );
  }
}
