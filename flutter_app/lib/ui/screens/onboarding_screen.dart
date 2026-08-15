// l10n:ignore-file — onboarding marketing copy mirrors the EN reference
// prototype pixel-perfectly; localization is a deliberate follow-up.
// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async' show Timer, unawaited;

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
import 'package:fa/ui/widgets/provider_marks.dart';

part 'onboarding_mockups.dart';

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

  /// Which preset completed its flow (the card check). Tracked here, not
  /// in the page, so it survives the PageView recycling the page state.
  String? _configuredProviderKey;

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
  void _providerDone(String presetKey) {
    setState(() {
      _providerConfigured = true;
      _configuredProviderKey = presetKey;
    });
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
                    configuredKey: _configuredProviderKey,
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
    this.configuredKey,
    this.onConfigured,
  });

  final bool wide;

  /// The shared provider registry; null renders the list inert (tests).
  final faui.ProviderRegistry? registry;

  /// Persists the configured provider as the restorable last connection.
  final LastConnectionStore? lastConnectionStore;

  /// The preset that completed its flow (its card gets the check).
  final String? configuredKey;

  /// Fired with the preset key once a config flow completes successfully.
  final ValueChanged<String>? onConfigured;

  @override
  State<_P2> createState() => _P2State();
}

class _P2State extends State<_P2> {
  var _busy = false;
  Timer? _busyTimer;

  @override
  void dispose() {
    _busyTimer?.cancel();
    super.dispose();
  }

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
            configured: widget.configuredKey == preset.key,
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
    if (registry == null || _busy) return;
    setState(() => _busy = true);
    // The busy flag is double-tap protection, NOT a flow-long lock: an SSO
    // flow waits on the system browser and may hang for minutes when the
    // user abandons it — it must never lock the whole list. The flows are
    // modal anyway, so a short window is all the protection needed.
    _busyTimer?.cancel();
    _busyTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _busy = false);
    });
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
    } on Object catch (e) {
      debugPrint('[onboarding] provider flow failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open the provider setup. Try again.'),
          ),
        );
      }
    } finally {
      _busyTimer?.cancel();
      if (mounted) setState(() => _busy = false);
    }
    if (ok && mounted) {
      widget.onConfigured?.call(preset.key);
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
              ProviderMark(preset.key, size: 40),
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
