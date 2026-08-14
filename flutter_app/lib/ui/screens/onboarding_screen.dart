// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import 'package:fa/services/analytics.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/ui/widgets/fa_mark.dart';

/// The first-launch onboarding flow, redesigned to match the reference
/// prototype: four pages with rich mockups, progress dots with labels,
/// and a clean adaptive layout.
///
/// Pages:
/// 1. "Start with an idea" — hero title + chat mockup + app grid preview
/// 2. "Choose how Fa thinks" — provider cards (OpenRouter recommended,
///    Ollama local, Google Gemini, Custom)
/// 3. "Give access only when it helps" — permission cards (Calendar,
///    Notifications, Microphone) with Allow/Later buttons
/// 4. "Your sandbox is ready" — app created notification + My Apps grid
///    + suggested prompts
///
/// Completing or skipping both call [OnboardingStore.markSeen] and
/// [onFinished] — the boot flow then continues (auto-connect or setup).
class OnboardingScreen extends StatefulWidget {
  /// Creates the flow.
  const OnboardingScreen({
    super.key,
    this.onboardingStore,
    this.initialPage = 0,
    this.onFinished,
  });

  /// The seen-flag store; completing or skipping marks it. Null = nothing
  /// persists (tests).
  final OnboardingStore? onboardingStore;

  /// Page to start on (goldens/tests); production always starts at 0.
  final int initialPage;

  /// Called after the seen flag is set — the boot flow continues. [skipped]
  /// is true when the user left via the Skip button.
  final void Function({required bool skipped})? onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _pageCount = 4;
  static const _stepLabels = ['Ask', 'Think', 'Act', 'Make it yours'];

  late final PageController _pageController = PageController(
    initialPage: widget.initialPage,
  );
  late var _page = widget.initialPage;

  @override
  void initState() {
    super.initState();
    AppAnalytics.instance.onboardingStarted();
    AppAnalytics.instance.screenOpened('onboarding');
  }

  @override
  void dispose() {
    _pageController.dispose();
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

  void _nextPage() {
    unawaited(
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      ),
    );
  }

  void _prevPage() {
    unawaited(
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = _OnboardingColors.of(context);
    final isWide = MediaQuery.sizeOf(context).width >= 700;
    final isLast = _page == _pageCount - 1;

    return Scaffold(
      backgroundColor: colors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar: logo + progress + skip ──────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  // Logo.
                  const FaMark(size: 24),
                  const SizedBox(width: 8),
                  Text(
                    'Fa',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  // Progress dots with labels.
                  if (isWide) ...[
                    for (var i = 0; i < _pageCount; i++) ...[
                      _ProgressDot(
                        label: _stepLabels[i],
                        done: i < _page,
                        active: i == _page,
                        colors: colors,
                      ),
                      if (i < _pageCount - 1)
                        _ProgressLine(done: i < _page, colors: colors),
                    ],
                  ],
                  const Spacer(),
                  // Skip.
                  TextButton(
                    onPressed: () => _finish(skipped: true),
                    child: Text(
                      'Skip',
                      style: TextStyle(color: colors.dim),
                    ),
                  ),
                ],
              ),
            ),
            // ── Content ──────────────────────────────────────────────
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (page) => setState(() => _page = page),
                children: [
                  _Page1Welcome(colors: colors, isWide: isWide),
                  _Page2Provider(colors: colors, isWide: isWide),
                  _Page3Permissions(colors: colors, isWide: isWide),
                  _Page4Ready(colors: colors, isWide: isWide),
                ],
              ),
            ),
            // ── Bottom bar: progress + buttons ───────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Row(
                children: [
                  Text(
                    '${_page + 1} of $_pageCount',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.dim,
                    ),
                  ),
                  const Spacer(),
                  if (_page > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: OutlinedButton(
                        onPressed: _prevPage,
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: colors.border),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text('Back'),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed:
                        isLast ? () => _finish(skipped: false) : _nextPage,
                    icon: Icon(
                      isLast ? Icons.open_in_new : Icons.arrow_forward,
                      size: 16,
                    ),
                    label: Text(isLast ? 'Open Fa' : 'Continue'),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.indigo,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
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
}

// ---------------------------------------------------------------------------
// Colors
// ---------------------------------------------------------------------------

class _OnboardingColors {
  const _OnboardingColors._({
    required this.bg,
    required this.card,
    required this.border,
    required this.text,
    required this.dim,
    required this.indigo,
    required this.indigoLight,
    required this.green,
    required this.amber,
  });

  factory _OnboardingColors.of(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    return light ? _light : _dark;
  }

  final Color bg;
  final Color card;
  final Color border;
  final Color text;
  final Color dim;
  final Color indigo;
  final Color indigoLight;
  final Color green;
  final Color amber;

  static const _light = _OnboardingColors._(
    bg: Color(0xFFF8F9FC),
    card: Color(0xFFFFFFFF),
    border: Color(0xFFE5E7EB),
    text: Color(0xFF111827),
    dim: Color(0xFF6B7280),
    indigo: Color(0xFF4F46E5),
    indigoLight: Color(0xFFEEF2FF),
    green: Color(0xFF10B981),
    amber: Color(0xFFF59E0B),
  );

  static const _dark = _OnboardingColors._(
    bg: Color(0xFF070A10),
    card: Color(0xFF0D1420),
    border: Color(0xFF1C2637),
    text: Color(0xFFE8EEF7),
    dim: Color(0xFF93A1B5),
    indigo: Color(0xFF818CF8),
    indigoLight: Color(0xFF232B47),
    green: Color(0xFF34D399),
    amber: Color(0xFFFBBF24),
  );
}

// ---------------------------------------------------------------------------
// Progress indicators
// ---------------------------------------------------------------------------

class _ProgressDot extends StatelessWidget {
  const _ProgressDot({
    required this.label,
    required this.done,
    required this.active,
    required this.colors,
  });

  final String label;
  final bool done;
  final bool active;
  final _OnboardingColors colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done || active ? colors.indigo : colors.border,
          ),
          child: done
              ? const Icon(Icons.check, size: 12, color: Colors.white)
              : null,
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: active ? colors.text : colors.dim,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.done, required this.colors});

  final bool done;
  final _OnboardingColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 2,
      margin: const EdgeInsets.only(bottom: 16),
      color: done ? colors.indigo : colors.border,
    );
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

/// A mockup chat message bubble for onboarding previews.
class _MockChatBubble extends StatelessWidget {
  const _MockChatBubble({
    required this.text,
    required this.isUser,
    required this.colors,
  });

  final String text;
  final bool isUser;
  final _OnboardingColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isUser ? colors.indigoLight : colors.card,
        borderRadius: BorderRadius.circular(12),
        boxShadow: isUser
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: isUser ? colors.text : colors.dim,
        ),
      ),
    );
  }
}

/// A mockup app icon tile for onboarding previews.
class _MockAppTile extends StatelessWidget {
  const _MockAppTile({
    required this.icon,
    required this.label,
    required this.colors,
    this.badge,
  });

  final IconData icon;
  final String label;
  final _OnboardingColors colors;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: colors.border),
          ),
          child: Icon(icon, size: 18, color: colors.dim),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(fontSize: 9, color: colors.dim),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// A feature pill at the bottom of page 1.
class _FeaturePill extends StatelessWidget {
  const _FeaturePill({
    required this.icon,
    required this.label,
    required this.colors,
  });

  final IconData icon;
  final String label;
  final _OnboardingColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colors.indigo),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 11, color: colors.dim)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 1: Start with an idea
// ---------------------------------------------------------------------------

class _Page1Welcome extends StatelessWidget {
  const _Page1Welcome({required this.colors, required this.isWide});

  final _OnboardingColors colors;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWide ? 720 : double.infinity),
          child: Column(
            children: [
              const SizedBox(height: 24),
              // Hero title.
              Text(
                'Start with an idea.',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.text,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Ask a question, automate a task, or describe an app you want to use.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.dim,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              // Chat mockup + app grid preview.
              if (isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Chat mockup.
                    Expanded(
                      child: _buildChatMockup(theme),
                    ),
                    const SizedBox(width: 24),
                    // App grid mockup.
                    Expanded(
                      child: _buildAppGridMockup(theme),
                    ),
                  ],
                )
              else ...[
                _buildChatMockup(theme),
                const SizedBox(height: 16),
                _buildAppGridMockup(theme),
              ],
              const SizedBox(height: 24),
              // Feature pills.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _FeaturePill(
                    icon: Icons.chat_bubble_outline,
                    label: 'Answers questions',
                    colors: colors,
                  ),
                  _FeaturePill(
                    icon: Icons.grid_view_rounded,
                    label: 'Uses your apps',
                    colors: colors,
                  ),
                  _FeaturePill(
                    icon: Icons.auto_awesome,
                    label: 'Builds new apps',
                    colors: colors,
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChatMockup(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: _MockChatBubble(
              text: 'Build a focus timer with work and break sessions.',
              isUser: true,
              colors: colors,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: colors.indigo,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  size: 12,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MockChatBubble(
                  text: 'Understanding your request…\nPlanning the app, timer logic, and break sessions.',
                  isUser: false,
                  colors: colors,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAppGridMockup(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Focus Timer widget preview.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.indigoLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.timer_outlined, size: 20, color: colors.indigo),
                const SizedBox(width: 8),
                Text(
                  '25:00',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.indigo,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // App icons grid.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MockAppTile(icon: Icons.calendar_today, label: 'Calendar', colors: colors),
              _MockAppTile(icon: Icons.note_outlined, label: 'Notes', colors: colors),
              _MockAppTile(icon: Icons.folder_outlined, label: 'Files', colors: colors),
              _MockAppTile(icon: Icons.calculate_outlined, label: 'Calc', colors: colors),
              _MockAppTile(icon: Icons.map_outlined, label: 'Maps', colors: colors),
              _MockAppTile(icon: Icons.settings_outlined, label: 'Settings', colors: colors),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 2: Choose how Fa thinks
// ---------------------------------------------------------------------------

class _Page2Provider extends StatefulWidget {
  const _Page2Provider({required this.colors, required this.isWide});

  final _OnboardingColors colors;
  final bool isWide;

  @override
  State<_Page2Provider> createState() => _Page2ProviderState();
}

class _Page2ProviderState extends State<_Page2Provider> {
  var _selected = 'openrouter';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = widget.colors;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: widget.isWide ? 480 : double.infinity,
          ),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text(
                'Choose how Fa thinks.',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.text,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Connect an AI provider to start chatting. You can switch models anytime.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.dim,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              // Provider cards.
              _ProviderCard(
                icon: Icons.cloud_outlined,
                name: 'OpenRouter',
                badge: 'Recommended',
                description: 'Access leading AI models with one connection.',
                detail: 'Default model: Auto',
                selected: _selected == 'openrouter',
                onTap: () => setState(() => _selected = 'openrouter'),
                colors: colors,
              ),
              const SizedBox(height: 8),
              _ProviderCard(
                icon: Icons.computer,
                name: 'Ollama',
                badge: 'Local',
                description: 'Run compatible models on your device.',
                selected: _selected == 'ollama',
                onTap: () => setState(() => _selected = 'ollama'),
                colors: colors,
              ),
              const SizedBox(height: 8),
              _ProviderCard(
                icon: Icons.auto_awesome,
                name: 'Google Gemini',
                description: 'Connect your Gemini API key.',
                selected: _selected == 'gemini',
                onTap: () => setState(() => _selected = 'gemini'),
                colors: colors,
              ),
              const SizedBox(height: 8),
              _ProviderCard(
                icon: Icons.dns_outlined,
                name: 'Custom provider',
                description: 'Use your own compatible endpoint.',
                selected: _selected == 'custom',
                onTap: () => setState(() => _selected = 'custom'),
                colors: colors,
              ),
              const SizedBox(height: 24),
              // Privacy note.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, size: 14, color: colors.dim),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'API keys stay in your system Keychain. Content is sent only to providers you connect.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.dim,
                        fontSize: 11,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.icon,
    required this.name,
    required this.description,
    required this.selected,
    required this.onTap,
    required this.colors,
    this.badge,
    this.detail,
  });

  final IconData icon;
  final String name;
  final String? badge;
  final String description;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;
  final _OnboardingColors colors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? colors.indigoLight : colors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? colors.indigo : colors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 24, color: colors.indigo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: badge == 'Recommended'
                                ? colors.indigo.withValues(alpha: 0.12)
                                : colors.green.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            badge!,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: badge == 'Recommended'
                                  ? colors.indigo
                                  : colors.green,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.dim,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      detail!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.dim,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? colors.indigo : Colors.transparent,
                border: Border.all(
                  color: selected ? colors.indigo : colors.border,
                  width: 2,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 12, color: Colors.white)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 3: Give access only when it helps
// ---------------------------------------------------------------------------

class _Page3Permissions extends StatelessWidget {
  const _Page3Permissions({required this.colors, required this.isWide});

  final _OnboardingColors colors;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWide ? 640 : double.infinity),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text(
                'Give access only when it helps.',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.text,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Fa asks only when an action needs it. You can change access anytime.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.dim,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              // Permission cards.
              if (isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _PermissionCard(
                      icon: Icons.calendar_today,
                      title: 'Calendar & Reminders',
                      description: 'Check your schedule and create events.',
                      colors: colors,
                    )),
                    const SizedBox(width: 12),
                    Expanded(child: _PermissionCard(
                      icon: Icons.notifications_outlined,
                      title: 'Notifications',
                      description: 'Send reminders and task updates.',
                      colors: colors,
                    )),
                    const SizedBox(width: 12),
                    Expanded(child: _PermissionCard(
                      icon: Icons.mic_outlined,
                      title: 'Microphone',
                      description: 'Talk to Fa with your voice.',
                      colors: colors,
                    )),
                  ],
                )
              else ...[
                _PermissionCard(
                  icon: Icons.calendar_today,
                  title: 'Calendar & Reminders',
                  description: 'Check your schedule and create events.',
                  colors: colors,
                ),
                const SizedBox(height: 8),
                _PermissionCard(
                  icon: Icons.notifications_outlined,
                  title: 'Notifications',
                  description: 'Send reminders and task updates.',
                  colors: colors,
                ),
                const SizedBox(height: 8),
                _PermissionCard(
                  icon: Icons.mic_outlined,
                  title: 'Microphone',
                  description: 'Talk to Fa with your voice.',
                  colors: colors,
                ),
              ],
              const SizedBox(height: 24),
              // Bottom notes.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline, size: 14, color: colors.green),
                  const SizedBox(width: 6),
                  Text(
                    'Nothing is enabled by default.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.green,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.settings_outlined, size: 14, color: colors.dim),
                  const SizedBox(width: 6),
                  Text(
                    'You can manage access anytime in Settings.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.dim,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.colors,
  });

  final IconData icon;
  final String title;
  final String description;
  final _OnboardingColors colors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 24, color: colors.indigo),
          const SizedBox(height: 8),
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.dim,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Ask when needed',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.indigo,
              fontSize: 11,
              fontWeight: FontWeight.w500,
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

class _Page4Ready extends StatelessWidget {
  const _Page4Ready({required this.colors, required this.isWide});

  final _OnboardingColors colors;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWide ? 720 : double.infinity),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text(
                'Your sandbox is ready.',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.text,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Use apps yourself, let Fa use them for you, or ask Fa to make something new.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.dim,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              if (isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildTimeline(theme)),
                    const SizedBox(width: 24),
                    Expanded(child: _buildAppGrid(theme)),
                  ],
                )
              else ...[
                _buildTimeline(theme),
                const SizedBox(height: 16),
                _buildAppGrid(theme),
              ],
              const SizedBox(height: 24),
              // Suggested prompts.
              Text(
                'Try these ideas to get started',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.dim,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _SuggestionPill(label: 'Plan my day', colors: colors),
                  _SuggestionPill(label: 'Build a workout tracker', colors: colors),
                  _SuggestionPill(label: 'Create an expense app', colors: colors),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimeline(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // "Focus Timer created" notification.
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: colors.indigo,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.auto_awesome, size: 14, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Focus Timer created',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Fa built and added this app to your workspace.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.dim,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // "You asked" / "Fa delivered" timeline.
          _TimelineEntry(
            icon: Icons.person_outline,
            label: 'You asked',
            text: 'Build a focus timer with work and break sessions.',
            colors: colors,
          ),
          const SizedBox(height: 8),
          _TimelineEntry(
            icon: Icons.auto_awesome,
            label: 'Fa delivered',
            text: 'Focus Timer — 25/5 focus sessions with work and break cycles.',
            colors: colors,
          ),
        ],
      ),
    );
  }

  Widget _buildAppGrid(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'My Apps',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.dim,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MockAppTile(icon: Icons.timer_outlined, label: 'Focus Timer', colors: colors, badge: 'New'),
              _MockAppTile(icon: Icons.wb_sunny_outlined, label: 'Weather', colors: colors),
              _MockAppTile(icon: Icons.calendar_today, label: 'Calendar', colors: colors),
              _MockAppTile(icon: Icons.folder_outlined, label: 'Files', colors: colors),
              _MockAppTile(icon: Icons.note_outlined, label: 'Notes', colors: colors),
              _MockAppTile(icon: Icons.map_outlined, label: 'Maps', colors: colors),
              _MockAppTile(icon: Icons.calculate_outlined, label: 'Calc', colors: colors),
              _MockAppTile(icon: Icons.settings_outlined, label: 'Settings', colors: colors),
              _MockAppTile(icon: Icons.add, label: 'Create with Fa', colors: colors),
            ],
          ),
        ],
      ),
    );
  }
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({
    required this.icon,
    required this.label,
    required this.text,
    required this.colors,
  });

  final IconData icon;
  final String label;
  final String text;
  final _OnboardingColors colors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: colors.dim),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.dim,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.text,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SuggestionPill extends StatelessWidget {
  const _SuggestionPill({required this.label, required this.colors});

  final String label;
  final _OnboardingColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: colors.dim)),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, size: 14, color: colors.dim),
        ],
      ),
    );
  }
}
