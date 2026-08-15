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
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    this.onboardingStore,
    this.initialPage = 0,
    this.onFinished,
  });

  final OnboardingStore? onboardingStore;
  final int initialPage;
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
    final isWide = MediaQuery.sizeOf(context).width >= 700;
    final isLast = _page == _pageCount - 1;
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FC),
      body: SafeArea(
        child: Column(
          children: [
            // Top bar: logo + progress + skip.
            _TopBar(
              page: _page,
              pageCount: _pageCount,
              stepLabels: _stepLabels,
              isWide: isWide,
              onSkip: () => _finish(skipped: true),
            ),
            // Content.
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (page) => setState(() => _page = page),
                children: [
                  _Page1(isWide: isWide),
                  _Page2(isWide: isWide),
                  _Page3(isWide: isWide),
                  _Page4(isWide: isWide),
                ],
              ),
            ),
            // Bottom bar.
            _BottomBar(
              page: _page,
              pageCount: _pageCount,
              isLast: isLast,
              onBack: _prevPage,
              onNext: isLast ? () => _finish(skipped: false) : _nextPage,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.page,
    required this.pageCount,
    required this.stepLabels,
    required this.isWide,
    required this.onSkip,
  });

  final int page;
  final int pageCount;
  final List<String> stepLabels;
  final bool isWide;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        children: [
          const FaMark(size: 24),
          const SizedBox(width: 8),
          const Text(
            'Fa',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const Spacer(),
          if (isWide)
            ...List.generate(pageCount * 2 - 1, (i) {
              if (i.isOdd) {
                return Container(
                  width: 32,
                  height: 2,
                  margin: const EdgeInsets.only(bottom: 16),
                  color: i ~/ 2 < page
                      ? const Color(0xFF4F46E5)
                      : const Color(0xFFE5E7EB),
                );
              }
              final idx = i ~/ 2;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: idx <= page
                          ? const Color(0xFF4F46E5)
                          : const Color(0xFFE5E7EB),
                    ),
                    child: idx < page
                        ? const Icon(Icons.check, size: 12, color: Colors.white)
                        : null,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    stepLabels[idx],
                    style: TextStyle(
                      fontSize: 10,
                      color: idx == page
                          ? const Color(0xFF111827)
                          : const Color(0xFF6B7280),
                      fontWeight: idx == page
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ],
              );
            }),
          const Spacer(),
          TextButton(
            onPressed: onSkip,
            child: const Text(
              'Skip',
              style: TextStyle(color: Color(0xFF6B7280)),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom bar
// ---------------------------------------------------------------------------

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.page,
    required this.pageCount,
    required this.isLast,
    required this.onBack,
    required this.onNext,
  });

  final int page;
  final int pageCount;
  final bool isLast;
  final VoidCallback onBack;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Row(
        children: [
          Text(
            '${page + 1} of $pageCount',
            style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
          ),
          const Spacer(),
          if (page > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: OutlinedButton(
                onPressed: onBack,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFE5E7EB)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  'Back',
                ), // l10n:ignore — prototype redesign ships en-only copy for now
              ),
            ),
          FilledButton.icon(
            onPressed: onNext,
            icon: Icon(
              isLast ? Icons.open_in_new : Icons.arrow_forward,
              size: 16,
            ),
            label: Text(isLast ? 'Open Fa' : 'Continue'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF4F46E5),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared mockup widgets
// ---------------------------------------------------------------------------

class _MockChat extends StatelessWidget {
  const _MockChat();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFEEF2FF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Build a focus timer with work and break sessions.',
                style: TextStyle(fontSize: 12, color: Color(0xFF111827)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: const BoxDecoration(
                  color: Color(0xFF4F46E5),
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
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: const Text(
                    'Understanding your request…\nPlanning the app, timer logic, and break sessions.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Input bar.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              children: [
                Icon(Icons.add, size: 16, color: Color(0xFF6B7280)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Ask anything…',
                    style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                  ),
                ),
                Icon(Icons.mic_outlined, size: 16, color: Color(0xFF6B7280)),
                SizedBox(width: 8),
                Icon(Icons.arrow_upward, size: 16, color: Color(0xFF4F46E5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MockAppGrid extends StatelessWidget {
  const _MockAppGrid();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Focus Timer widget — prominent circular display like the reference.
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF60A5FA), Color(0xFF3B82F6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                // Circular timer display.
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                  child: const Center(
                    child: Text(
                      '25:00',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Focus Timer',
                  style: TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Start Session',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // App icons grid — colorful, matching the reference.
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _appIcon(
                Icons.calendar_today,
                'Calendar',
                const Color(0xFF3B82F6),
              ),
              _appIcon(Icons.note_outlined, 'Notes', const Color(0xFFF59E0B)),
              _appIcon(
                Icons.build_outlined,
                'Utilities',
                const Color(0xFF6B7280),
                badge: '4',
              ),
              _appIcon(Icons.folder_outlined, 'Files', const Color(0xFF3B82F6)),
              _appIcon(
                Icons.calculate_outlined,
                'Calculator',
                const Color(0xFF111827),
              ),
              _appIcon(Icons.map_outlined, 'Maps', const Color(0xFF10B981)),
              _appIcon(
                Icons.timer_outlined,
                'Focus Timer',
                const Color(0xFF4F46E5),
                badge: 'New',
              ),
              _appIcon(
                Icons.settings_outlined,
                'Settings',
                const Color(0xFF6B7280),
              ),
              _appIcon(Icons.add, 'Add app', const Color(0xFF9CA3AF)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _appIcon(IconData icon, String label, Color bg, {String? badge}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: Colors.white),
            ),
            if (badge != null)
              Positioned(
                top: -2,
                right: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4F46E5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    badge,
                    style: const TextStyle(
                      fontSize: 8,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 9, color: Color(0xFF6B7280)),
        ),
      ],
    );
  }
}

class _FeaturePill extends StatelessWidget {
  const _FeaturePill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF4F46E5)),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 1: Start with an idea
// ---------------------------------------------------------------------------

class _Page1 extends StatelessWidget {
  const _Page1({required this.isWide});

  final bool isWide;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWide ? 900 : double.infinity),
          child: Column(
            children: [
              const SizedBox(height: 16),
              const Text(
                'Start with an idea.',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Ask a question, automate a task, or describe an app you want to use.',
                style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              // 3-column layout: chat | app grid | provider panel.
              if (isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: _MockChat()),
                    const SizedBox(width: 16),
                    Expanded(flex: 4, child: _MockAppGrid()),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: _ProviderPanel()),
                  ],
                )
              else ...[
                _MockChat(),
                const SizedBox(height: 12),
                _MockAppGrid(),
              ],
              const SizedBox(height: 24),
              // Feature pills.
              const Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _FeaturePill(
                    icon: Icons.chat_bubble_outline,
                    label: 'Answers questions',
                  ),
                  _FeaturePill(
                    icon: Icons.grid_view_rounded,
                    label: 'Uses your apps',
                  ),
                  _FeaturePill(
                    icon: Icons.auto_awesome,
                    label: 'Builds new apps',
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

/// The right panel showing "Choose how Fa thinks." with provider list.
class _ProviderPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Choose how Fa thinks.',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 12),
          _providerRow(Icons.cloud_outlined, 'OpenRouter', 'Recommended', true),
          _providerRow(Icons.computer, 'Ollama', 'Local', false),
          _providerRow(Icons.auto_awesome, 'Google Gemini', null, false),
          _providerRow(Icons.dns_outlined, 'Custom provider', null, false),
        ],
      ),
    );
  }

  Widget _providerRow(
    IconData icon,
    String name,
    String? badge,
    bool selected,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF4F46E5)),
          const SizedBox(width: 8),
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
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 4),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: badge == 'Recommended'
                                ? const Color(
                                    0xFF4F46E5,
                                  ).withValues(alpha: 0.12)
                                : const Color(
                                    0xFF10B981,
                                  ).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            badge,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: badge == 'Recommended'
                                  ? const Color(0xFF4F46E5)
                                  : const Color(0xFF10B981),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? const Color(0xFF4F46E5) : Colors.transparent,
              border: Border.all(
                color: selected
                    ? const Color(0xFF4F46E5)
                    : const Color(0xFFE5E7EB),
                width: 2,
              ),
            ),
            child: selected
                ? const Icon(Icons.check, size: 10, color: Colors.white)
                : null,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 2: Choose how Fa thinks
// ---------------------------------------------------------------------------

class _Page2 extends StatefulWidget {
  const _Page2({required this.isWide});

  final bool isWide;

  @override
  State<_Page2> createState() => _Page2State();
}

class _Page2State extends State<_Page2> {
  var _selected = 'openrouter';

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: widget.isWide ? 720 : double.infinity,
          ),
          child: Column(
            children: [
              const SizedBox(height: 16),
              const Text(
                'Choose how Fa thinks.',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Connect an AI provider to start chatting. You can switch models anytime.',
                style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              // Wide: floating request card on the left + provider cards.
              if (widget.isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Floating "Your request" card.
                    SizedBox(
                      width: 200,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE5E7EB)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Your request',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFF6B7280),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Row(
                              children: [
                                Icon(
                                  Icons.auto_awesome,
                                  size: 14,
                                  color: Color(0xFF4F46E5),
                                ),
                                SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    'Build a focus timer with work and break sessions.',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF111827),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Provider cards.
                    Expanded(child: _buildProviderCards()),
                  ],
                )
              else
                _buildProviderCards(),
              const SizedBox(height: 16),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, size: 14, color: Color(0xFF6B7280)),
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'API keys stay in your system Keychain. Content is sent only to providers you connect.',
                      style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
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

  Widget _buildProviderCards() {
    return Column(
      children: [
        _ProviderCard(
          icon: Icons.cloud_outlined,
          name: 'OpenRouter',
          badge: 'Recommended',
          description: 'Access leading AI models with one connection.',
          detail:
              'Default model: Auto — Fa chooses the best available model for each task.',
          link: 'Choose a model manually',
          selected: _selected == 'openrouter',
          onTap: () => setState(() => _selected = 'openrouter'),
        ),
        const SizedBox(height: 8),
        _ProviderCard(
          icon: Icons.computer,
          name: 'Ollama',
          badge: 'Local',
          description: 'Run compatible models on your device.',
          selected: _selected == 'ollama',
          onTap: () => setState(() => _selected = 'ollama'),
        ),
        const SizedBox(height: 8),
        _ProviderCard(
          icon: Icons.auto_awesome,
          name: 'Google Gemini',
          description: 'Connect your Gemini API key.',
          selected: _selected == 'gemini',
          onTap: () => setState(() => _selected = 'gemini'),
        ),
        const SizedBox(height: 8),
        _ProviderCard(
          icon: Icons.dns_outlined,
          name: 'Custom provider',
          description: 'Use your own compatible endpoint.',
          selected: _selected == 'custom',
          onTap: () => setState(() => _selected = 'custom'),
        ),
      ],
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
    this.badge,
    this.detail,
    this.link,
  });

  final IconData icon;
  final String name;
  final String? badge;
  final String description;
  final String? detail;
  final String? link;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFEEF2FF) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFF4F46E5) : const Color(0xFFE5E7EB),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 24, color: const Color(0xFF4F46E5)),
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
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: badge == 'Recommended'
                                ? const Color(
                                    0xFF4F46E5,
                                  ).withValues(alpha: 0.12)
                                : const Color(
                                    0xFF10B981,
                                  ).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            badge!,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: badge == 'Recommended'
                                  ? const Color(0xFF4F46E5)
                                  : const Color(0xFF10B981),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      detail!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ],
                  if (link != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      link!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF4F46E5),
                        fontWeight: FontWeight.w500,
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
                color: selected ? const Color(0xFF4F46E5) : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? const Color(0xFF4F46E5)
                      : const Color(0xFFE5E7EB),
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

class _Page3 extends StatelessWidget {
  const _Page3({required this.isWide});

  final bool isWide;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWide ? 900 : double.infinity),
          child: Column(
            children: [
              const SizedBox(height: 16),
              const Text(
                'Give access only when it helps.',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Fa asks only when an action needs it. You can change access anytime.',
                style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              // Flow diagram + permission cards + right preview.
              if (isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Left: flow diagram + permission cards.
                    Expanded(
                      flex: 3,
                      child: Column(
                        children: [
                          _buildFlowDiagram(),
                          const SizedBox(height: 16),
                          const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: _PermissionCard(
                                  icon: Icons.calendar_today,
                                  title: 'Calendar & Reminders',
                                  description:
                                      'Check your schedule and create events.',
                                ),
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: _PermissionCard(
                                  icon: Icons.notifications_outlined,
                                  title: 'Notifications',
                                  description:
                                      'Send reminders and task updates.',
                                ),
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: _PermissionCard(
                                  icon: Icons.mic_outlined,
                                  title: 'Microphone',
                                  description: 'Talk to Fa with your voice.',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Right: "What you'll get" preview.
                    Expanded(flex: 2, child: _buildPreviewPanel()),
                  ],
                )
              else ...[
                _buildFlowDiagram(),
                const SizedBox(height: 16),
                const _PermissionCard(
                  icon: Icons.calendar_today,
                  title: 'Calendar & Reminders',
                  description: 'Check your schedule and create events.',
                ),
                const SizedBox(height: 8),
                const _PermissionCard(
                  icon: Icons.notifications_outlined,
                  title: 'Notifications',
                  description: 'Send reminders and task updates.',
                ),
                const SizedBox(height: 8),
                const _PermissionCard(
                  icon: Icons.mic_outlined,
                  title: 'Microphone',
                  description: 'Talk to Fa with your voice.',
                ),
              ],
              const SizedBox(height: 24),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 14,
                    color: Color(0xFF10B981),
                  ),
                  SizedBox(width: 6),
                  Text(
                    'Nothing is enabled by default.',
                    style: TextStyle(fontSize: 11, color: Color(0xFF10B981)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.settings_outlined,
                    size: 14,
                    color: Color(0xFF6B7280),
                  ),
                  SizedBox(width: 6),
                  Text(
                    'You can manage access anytime in Settings.',
                    style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
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

  Widget _buildFlowDiagram() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_awesome, size: 16, color: Color(0xFF4F46E5)),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              'Build a focus timer with work and break sessions.',
              style: TextStyle(fontSize: 11, color: Color(0xFF111827)),
            ),
          ),
          SizedBox(width: 8),
          Icon(Icons.arrow_forward, size: 14, color: Color(0xFF6B7280)),
          SizedBox(width: 8),
          Icon(Icons.timer_outlined, size: 16, color: Color(0xFF4F46E5)),
          SizedBox(width: 8),
          Text(
            'Focus Timer',
            style: TextStyle(
              fontSize: 11,
              color: Color(0xFF111827),
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(width: 4),
          Text(
            'no access needed',
            style: TextStyle(fontSize: 10, color: Color(0xFF10B981)),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'What you\'ll get',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B7280),
            ),
          ),
          const SizedBox(height: 12),
          // Focus Timer widget preview.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF60A5FA), Color(0xFF3B82F6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              children: [
                Icon(Icons.timer_outlined, size: 20, color: Colors.white),
                SizedBox(width: 8),
                Text(
                  '25:00',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Mini app grid.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _miniIcon(Icons.calendar_today, const Color(0xFF3B82F6)),
              _miniIcon(Icons.note_outlined, const Color(0xFFF59E0B)),
              _miniIcon(Icons.folder_outlined, const Color(0xFF3B82F6)),
              _miniIcon(Icons.calculate_outlined, const Color(0xFF111827)),
              _miniIcon(Icons.map_outlined, const Color(0xFF10B981)),
              _miniIcon(Icons.timer_outlined, const Color(0xFF4F46E5)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniIcon(IconData icon, Color bg) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, size: 14, color: Colors.white),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 24, color: const Color(0xFF4F46E5)),
          const SizedBox(height: 8),
          Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 4),
          const Text(
            'Ask when needed',
            style: TextStyle(
              fontSize: 11,
              color: Color(0xFF4F46E5),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {},
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF4F46E5)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                  ),
                  child: const Text(
                    'Allow',
                    style: TextStyle(fontSize: 11, color: Color(0xFF4F46E5)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  onPressed: () {},
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                  ),
                  child: const Text(
                    'Later',
                    style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 4: Your sandbox is ready
// ---------------------------------------------------------------------------

class _Page4 extends StatelessWidget {
  const _Page4({required this.isWide});

  final bool isWide;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWide ? 900 : double.infinity),
          child: Column(
            children: [
              const SizedBox(height: 16),
              const Text(
                'Your sandbox is ready.',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Use apps yourself, let Fa use them for you, or ask Fa to make something new.',
                style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildTimeline()),
                    const SizedBox(width: 16),
                    Expanded(child: _buildAppGrid()),
                  ],
                )
              else ...[
                _buildTimeline(),
                const SizedBox(height: 12),
                _buildAppGrid(),
              ],
              const SizedBox(height: 24),
              const Text(
                'Try these ideas to get started',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
              const SizedBox(height: 8),
              const Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _SuggestionPill(label: 'Plan my day'),
                  _SuggestionPill(label: 'Build a workout tracker'),
                  _SuggestionPill(label: 'Create an expense app'),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimeline() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  color: Color(0xFF4F46E5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  size: 14,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Focus Timer created',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Fa built and added this app to your workspace.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _TimelineEntry(
            icon: Icons.person_outline,
            label: 'You asked',
            text: 'Build a focus timer with work and break sessions.',
          ),
          const SizedBox(height: 8),
          const _TimelineEntry(
            icon: Icons.auto_awesome,
            label: 'Fa delivered',
            text:
                'Focus Timer — 25/5 focus sessions with work and break cycles.',
          ),
        ],
      ),
    );
  }

  Widget _buildAppGrid() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'My Apps',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B7280),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _appTile(Icons.timer_outlined, 'Focus Timer', badge: 'New'),
              _appTile(Icons.wb_sunny_outlined, 'Weather'),
              _appTile(Icons.calendar_today, 'Calendar'),
              _appTile(Icons.folder_outlined, 'Files'),
              _appTile(Icons.note_outlined, 'Notes'),
              _appTile(Icons.map_outlined, 'Maps'),
              _appTile(Icons.calculate_outlined, 'Calc'),
              _appTile(Icons.settings_outlined, 'Settings'),
              _appTile(Icons.add, 'Create with Fa'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _appTile(IconData icon, String label, {String? badge}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Icon(icon, size: 20, color: const Color(0xFF6B7280)),
            ),
            if (badge != null)
              Positioned(
                top: -2,
                right: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4F46E5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    badge,
                    style: const TextStyle(
                      fontSize: 8,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 9, color: Color(0xFF6B7280)),
        ),
      ],
    );
  }
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({
    required this.icon,
    required this.label,
    required this.text,
  });

  final IconData icon;
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: const Color(0xFF6B7280)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                text,
                style: const TextStyle(fontSize: 12, color: Color(0xFF111827)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SuggestionPill extends StatelessWidget {
  const _SuggestionPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 14, color: Color(0xFF6B7280)),
        ],
      ),
    );
  }
}
