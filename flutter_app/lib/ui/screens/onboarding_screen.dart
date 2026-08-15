// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import 'package:fa/services/analytics.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/ui/widgets/fa_mark.dart';

/// Onboarding matching the reference prototype pixel-by-pixel.
/// Four pages: welcome (3-col mockups), provider picker, permissions, ready.
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
  static const _labels = ['Ask', 'Think', 'Act', 'Make it yours'];
  late final PageController _pc = PageController(initialPage: widget.initialPage);
  late var _page = widget.initialPage;

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

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final last = _page == 3;
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FC),
      body: SafeArea(
        child: Column(
          children: [
            // Top bar.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  const FaMark(size: 24),
                  const SizedBox(width: 8),
                  const Text('Fa', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const Spacer(),
                  if (wide)
                    ...List.generate(7, (i) {
                      if (i.isOdd) {
                        return Container(
                          width: 32, height: 2,
                          margin: const EdgeInsets.only(bottom: 16),
                          color: i ~/ 2 < _page ? const Color(0xFF4F46E5) : const Color(0xFFE5E7EB),
                        );
                      }
                      final idx = i ~/ 2;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 20, height: 20,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: idx <= _page ? const Color(0xFF4F46E5) : const Color(0xFFE5E7EB),
                            ),
                            child: idx < _page
                                ? const Icon(Icons.check, size: 12, color: Colors.white)
                                : null,
                          ),
                          const SizedBox(height: 4),
                          Text(_labels[idx], style: TextStyle(
                            fontSize: 10,
                            color: idx == _page ? const Color(0xFF111827) : const Color(0xFF6B7280),
                            fontWeight: idx == _page ? FontWeight.w600 : FontWeight.w400,
                          )),
                        ],
                      );
                    }),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _finish(skipped: true),
                    child: const Text('Skip', style: TextStyle(color: Color(0xFF6B7280))),
                  ),
                ],
              ),
            ),
            // Pages.
            Expanded(
              child: PageView(
                controller: _pc,
                onPageChanged: (p) => setState(() => _page = p),
                children: [
                  _P1(wide: wide),
                  _P2(wide: wide),
                  _P3(wide: wide),
                  _P4(wide: wide),
                ],
              ),
            ),
            // Bottom bar.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Row(
                children: [
                  Text('${_page + 1} of 4', style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12)),
                  const Spacer(),
                  if (_page > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: OutlinedButton(
                        onPressed: () => _pc.previousPage(
                          duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFFE5E7EB)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text('Back'),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: last ? () => _finish(skipped: false) : () => _pc.nextPage(
                      duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                    icon: Icon(last ? Icons.open_in_new : Icons.arrow_forward, size: 16),
                    label: Text(last ? 'Open Fa' : 'Continue'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF4F46E5),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
// Page 1: Start with an idea — 3-column mockup layout
// ---------------------------------------------------------------------------

class _P1 extends StatelessWidget {
  const _P1({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 960 : double.infinity),
          child: Column(
            children: [
              const SizedBox(height: 16),
              const Text('Start with an idea.', style: TextStyle(
                fontSize: 28, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const SizedBox(height: 8),
              const Text('Ask a question, automate a task, or describe an app you want to use.',
                style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: _ChatMockup()),
                    const SizedBox(width: 16),
                    Expanded(flex: 4, child: Column(
                      children: [
                        _FocusTimerWidget(),
                        const SizedBox(height: 16),
                        _AppGridMockup(),
                      ],
                    )),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: _ProviderPanelMockup()),
                  ],
                )
              else ...[
                _ChatMockup(),
                const SizedBox(height: 12),
                _FocusTimerWidget(),
                const SizedBox(height: 12),
                _AppGridMockup(),
              ],
              const SizedBox(height: 24),
              const Wrap(
                spacing: 8, runSpacing: 8, alignment: WrapAlignment.center,
                children: [
                  _Pill(icon: Icons.chat_bubble_outline, label: 'Answers questions'),
                  _Pill(icon: Icons.grid_view_rounded, label: 'Uses your apps'),
                  _Pill(icon: Icons.auto_awesome, label: 'Builds new apps'),
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

// ---------------------------------------------------------------------------
// Mockup widgets (page 1)
// ---------------------------------------------------------------------------

class _ChatMockup extends StatelessWidget {
  const _ChatMockup();

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
          // User bubble.
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFEEF2FF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text('Build a focus timer with work and break sessions.',
                style: TextStyle(fontSize: 12, color: Color(0xFF111827))),
            ),
          ),
          const SizedBox(height: 8),
          // AI response with avatar.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 24, height: 24,
                decoration: const BoxDecoration(color: Color(0xFF4F46E5), shape: BoxShape.circle),
                child: const Icon(Icons.auto_awesome, size: 12, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 4, offset: const Offset(0, 1))],
                  ),
                  child: const Text('Understanding your request…\nPlanning the app, timer logic, and break sessions.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
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
                Expanded(child: Text('Ask anything…', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)))),
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

class _FocusTimerWidget extends StatelessWidget {
  const _FocusTimerWidget();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1B2E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          // Header: title + menu.
          const Row(
            children: [
              Text('Focus Timer', style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
              Spacer(),
              Icon(Icons.more_horiz, size: 16, color: Colors.white54),
            ],
          ),
          const SizedBox(height: 4),
          // Active indicator.
          const Row(
            children: [
              Icon(Icons.circle, size: 6, color: Color(0xFF34D399)),
              SizedBox(width: 4),
              Text('Active', style: TextStyle(fontSize: 10, color: Color(0xFF34D399))),
            ],
          ),
          const SizedBox(height: 12),
          // Circular progress ring with time.
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 120, height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 6),
                  ),
                ),
                SizedBox(
                  width: 120, height: 120,
                  child: CircularProgressIndicator(
                    value: 0.75,
                    strokeWidth: 6,
                    backgroundColor: Colors.transparent,
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF60A5FA)),
                  ),
                ),
                const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('25:00', style: TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white)),
                    Text('Focus time', style: TextStyle(fontSize: 11, color: Colors.white70)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Start Session button.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Center(
              child: Text('Start Session', style: TextStyle(
                fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 4),
          const Text('Work 25 min • Break 5 min', style: TextStyle(
            fontSize: 10, color: Colors.white54)),
        ],
      ),
    );
  }
}

class _AppGridMockup extends StatelessWidget {
  const _AppGridMockup();

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
          // App icons grid — colorful, matching the reference.
          Wrap(
            spacing: 10, runSpacing: 10,
            children: [
              _icon(Icons.calendar_today, 'Calendar', const Color(0xFF3B82F6)),
              _icon(Icons.note_outlined, 'Notes', const Color(0xFFF59E0B)),
              _icon(Icons.build_outlined, 'Utilities', const Color(0xFF6B7280), badge: '4'),
              _icon(Icons.folder_outlined, 'Files', const Color(0xFF3B82F6)),
              _icon(Icons.calculate_outlined, 'Calculator', const Color(0xFF111827)),
              _icon(Icons.map_outlined, 'Maps', const Color(0xFF10B981)),
              _icon(Icons.timer_outlined, 'Focus Timer', const Color(0xFF4F46E5), badge: 'New'),
              _icon(Icons.settings_outlined, 'Settings', const Color(0xFF6B7280)),
              _icon(Icons.add, 'Add app', const Color(0xFF9CA3AF)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _icon(IconData icon, String label, Color bg, {String? badge}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(11)),
              child: Icon(icon, size: 22, color: Colors.white),
            ),
            if (badge != null)
              Positioned(
                top: -2, right: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(color: const Color(0xFF4F46E5), borderRadius: BorderRadius.circular(4)),
                  child: Text(badge, style: const TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 9, color: Color(0xFF6B7280))),
      ],
    );
  }
}

class _ProviderPanelMockup extends StatelessWidget {
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
          const Text('Choose how Fa thinks.', style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
          const SizedBox(height: 12),
          _row(Icons.cloud_outlined, 'OpenRouter', 'Recommended', true),
          _row(Icons.computer, 'Ollama', 'Local', false),
          _row(Icons.auto_awesome, 'Google Gemini', null, false),
          _row(Icons.dns_outlined, 'Custom provider', null, false),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String name, String? badge, bool selected) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF4F46E5)),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: [
                Flexible(child: Text(name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                if (badge != null) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: badge == 'Recommended' ? const Color(0xFF4F46E5).withValues(alpha: 0.12) : const Color(0xFF10B981).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(badge, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600,
                      color: badge == 'Recommended' ? const Color(0xFF4F46E5) : const Color(0xFF10B981))),
                  ),
                ],
              ],
            ),
          ),
          Container(
            width: 16, height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? const Color(0xFF4F46E5) : Colors.transparent,
              border: Border.all(color: selected ? const Color(0xFF4F46E5) : const Color(0xFFE5E7EB), width: 2),
            ),
            child: selected ? const Icon(Icons.check, size: 10, color: Colors.white) : null,
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});
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
          Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 2: Choose how Fa thinks
// ---------------------------------------------------------------------------

class _P2 extends StatefulWidget {
  const _P2({required this.wide});
  final bool wide;

  @override
  State<_P2> createState() => _P2State();
}

class _P2State extends State<_P2> {
  var _sel = 'openrouter';

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.wide ? 720 : double.infinity),
          child: Column(
            children: [
              const SizedBox(height: 16),
              const Text('Choose how Fa thinks.', style: TextStyle(
                fontSize: 28, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const SizedBox(height: 8),
              const Text('Connect an AI provider to start chatting. You can switch models anytime.',
                style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (widget.wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Floating request card.
                    SizedBox(
                      width: 200,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE5E7EB)),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2))],
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Your request', style: TextStyle(fontSize: 11, color: Color(0xFF6B7280), fontWeight: FontWeight.w500)),
                            SizedBox(height: 4),
                            Row(children: [
                              Icon(Icons.auto_awesome, size: 14, color: Color(0xFF4F46E5)),
                              SizedBox(width: 4),
                              Expanded(child: Text('Build a focus timer with work and break sessions.',
                                style: TextStyle(fontSize: 11, color: Color(0xFF111827)))),
                            ]),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(child: _cards()),
                  ],
                )
              else
                _cards(),
              const SizedBox(height: 16),
              const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.lock_outline, size: 14, color: Color(0xFF6B7280)),
                SizedBox(width: 6),
                Flexible(child: Text('API keys stay in your system Keychain. Content is sent only to providers you connect.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)), textAlign: TextAlign.center)),
              ]),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cards() {
    return Column(
      children: [
        _card(Icons.cloud_outlined, 'OpenRouter', 'Recommended',
          'Access leading AI models with one connection.',
          'Default model: Auto — Fa chooses the best available model for each task.',
          'Choose a model manually',
          _sel == 'openrouter', () => setState(() => _sel = 'openrouter')),
        const SizedBox(height: 8),
        _card(Icons.computer, 'Ollama', 'Local',
          'Run compatible models on your device.', null, null,
          _sel == 'ollama', () => setState(() => _sel = 'ollama')),
        const SizedBox(height: 8),
        _card(Icons.auto_awesome, 'Google Gemini', null,
          'Connect your Gemini API key.', null, null,
          _sel == 'gemini', () => setState(() => _sel = 'gemini')),
        const SizedBox(height: 8),
        _card(Icons.dns_outlined, 'Custom provider', null,
          'Use your own compatible endpoint.', null, null,
          _sel == 'custom', () => setState(() => _sel = 'custom')),
      ],
    );
  }

  Widget _card(IconData icon, String name, String? badge, String desc, String? detail, String? link, bool sel, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: sel ? const Color(0xFFEEF2FF) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sel ? const Color(0xFF4F46E5) : const Color(0xFFE5E7EB), width: sel ? 1.5 : 1),
        ),
        child: Row(
          children: [
            Icon(icon, size: 24, color: const Color(0xFF4F46E5)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(child: Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                    if (badge != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: badge == 'Recommended' ? const Color(0xFF4F46E5).withValues(alpha: 0.12) : const Color(0xFF10B981).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(badge, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600,
                          color: badge == 'Recommended' ? const Color(0xFF4F46E5) : const Color(0xFF10B981))),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(desc, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                  if (detail != null) ...[
                    const SizedBox(height: 4),
                    Text(detail, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
                  ],
                  if (link != null) ...[
                    const SizedBox(height: 4),
                    Text(link, style: const TextStyle(fontSize: 11, color: Color(0xFF4F46E5), fontWeight: FontWeight.w500)),
                  ],
                ],
              ),
            ),
            Container(
              width: 20, height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: sel ? const Color(0xFF4F46E5) : Colors.transparent,
                border: Border.all(color: sel ? const Color(0xFF4F46E5) : const Color(0xFFE5E7EB), width: 2),
              ),
              child: sel ? const Icon(Icons.check, size: 12, color: Colors.white) : null,
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

class _P3 extends StatelessWidget {
  const _P3({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 900 : double.infinity),
          child: Column(
            children: [
              const SizedBox(height: 16),
              const Text('Give access only when it helps.', style: TextStyle(
                fontSize: 28, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const SizedBox(height: 8),
              const Text('Fa asks only when an action needs it. You can change access anytime.',
                style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: Column(children: [
                      _flow(),
                      const SizedBox(height: 16),
                      const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: _PermCard(icon: Icons.calendar_today, title: 'Calendar & Reminders', desc: 'Check your schedule and create events.')),
                        SizedBox(width: 12),
                        Expanded(child: _PermCard(icon: Icons.notifications_outlined, title: 'Notifications', desc: 'Send reminders and task updates.')),
                        SizedBox(width: 12),
                        Expanded(child: _PermCard(icon: Icons.mic_outlined, title: 'Microphone', desc: 'Talk to Fa with your voice.')),
                      ]),
                    ])),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: _preview()),
                  ],
                )
              else ...[
                _flow(),
                const SizedBox(height: 16),
                const _PermCard(icon: Icons.calendar_today, title: 'Calendar & Reminders', desc: 'Check your schedule and create events.'),
                const SizedBox(height: 8),
                const _PermCard(icon: Icons.notifications_outlined, title: 'Notifications', desc: 'Send reminders and task updates.'),
                const SizedBox(height: 8),
                const _PermCard(icon: Icons.mic_outlined, title: 'Microphone', desc: 'Talk to Fa with your voice.'),
              ],
              const SizedBox(height: 24),
              const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF10B981)),
                SizedBox(width: 6),
                Text('Nothing is enabled by default.', style: TextStyle(fontSize: 11, color: Color(0xFF10B981))),
              ]),
              const SizedBox(height: 4),
              const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.settings_outlined, size: 14, color: Color(0xFF6B7280)),
                SizedBox(width: 6),
                Text('You can manage access anytime in Settings.', style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
              ]),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _flow() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.auto_awesome, size: 16, color: Color(0xFF4F46E5)),
        SizedBox(width: 8),
        Flexible(child: Text('Build a focus timer with work and break sessions.', style: TextStyle(fontSize: 11, color: Color(0xFF111827)))),
        SizedBox(width: 8),
        Icon(Icons.arrow_forward, size: 14, color: Color(0xFF6B7280)),
        SizedBox(width: 8),
        Icon(Icons.timer_outlined, size: 16, color: Color(0xFF4F46E5)),
        SizedBox(width: 8),
        Text('Focus Timer', style: TextStyle(fontSize: 11, color: Color(0xFF111827), fontWeight: FontWeight.w600)),
        SizedBox(width: 4),
        Text('no access needed', style: TextStyle(fontSize: 10, color: Color(0xFF10B981))),
      ]),
    );
  }

  Widget _preview() {
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
          const Text('What you\'ll get', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF60A5FA), Color(0xFF3B82F6)], begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(children: [
              Icon(Icons.timer_outlined, size: 20, color: Colors.white),
              SizedBox(width: 8),
              Text('25:00', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white)),
            ]),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _mini(Icons.calendar_today, const Color(0xFF3B82F6)),
            _mini(Icons.note_outlined, const Color(0xFFF59E0B)),
            _mini(Icons.folder_outlined, const Color(0xFF3B82F6)),
            _mini(Icons.calculate_outlined, const Color(0xFF111827)),
            _mini(Icons.map_outlined, const Color(0xFF10B981)),
            _mini(Icons.timer_outlined, const Color(0xFF4F46E5)),
          ]),
        ],
      ),
    );
  }

  Widget _mini(IconData icon, Color bg) {
    return Container(
      width: 28, height: 28,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(7)),
      child: Icon(icon, size: 14, color: Colors.white),
    );
  }
}

class _PermCard extends StatelessWidget {
  const _PermCard({required this.icon, required this.title, required this.desc});
  final IconData icon;
  final String title;
  final String desc;

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
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(desc, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          const SizedBox(height: 4),
          const Text('Ask when needed', style: TextStyle(fontSize: 11, color: Color(0xFF4F46E5), fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () {},
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF4F46E5)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 6),
              ),
              child: const Text('Allow', style: TextStyle(fontSize: 11, color: Color(0xFF4F46E5))),
            )),
            const SizedBox(width: 8),
            Expanded(child: TextButton(
              onPressed: () {},
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 6)),
              child: const Text('Later', style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
            )),
          ]),
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
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 900 : double.infinity),
          child: Column(
            children: [
              const SizedBox(height: 16),
              const Text('Your sandbox is ready.', style: TextStyle(
                fontSize: 28, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const SizedBox(height: 8),
              const Text('Use apps yourself, let Fa use them for you, or ask Fa to make something new.',
                style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (wide)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _timeline()),
                  const SizedBox(width: 16),
                  Expanded(child: _grid()),
                ])
              else ...[
                _timeline(),
                const SizedBox(height: 12),
                _grid(),
              ],
              const SizedBox(height: 24),
              const Text('Try these ideas to get started', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              const SizedBox(height: 8),
              const Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                _SuggPill(label: 'Plan my day'),
                _SuggPill(label: 'Build a workout tracker'),
                _SuggPill(label: 'Create an expense app'),
              ]),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timeline() {
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
          Row(children: [
            Container(
              width: 28, height: 28,
              decoration: const BoxDecoration(color: Color(0xFF4F46E5), shape: BoxShape.circle),
              child: const Icon(Icons.auto_awesome, size: 14, color: Colors.white),
            ),
            const SizedBox(width: 8),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Focus Timer created', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Text('Fa built and added this app to your workspace.', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            ])),
          ]),
          const SizedBox(height: 12),
          const _TEntry(icon: Icons.person_outline, label: 'You asked', text: 'Build a focus timer with work and break sessions.'),
          const SizedBox(height: 8),
          const _TEntry(icon: Icons.auto_awesome, label: 'Fa delivered', text: 'Focus Timer — 25/5 focus sessions with work and break cycles.'),
        ],
      ),
    );
  }

  Widget _grid() {
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
          const Text('My Apps', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _tile(Icons.timer_outlined, 'Focus Timer', badge: 'New'),
            _tile(Icons.wb_sunny_outlined, 'Weather'),
            _tile(Icons.calendar_today, 'Calendar'),
            _tile(Icons.folder_outlined, 'Files'),
            _tile(Icons.note_outlined, 'Notes'),
            _tile(Icons.map_outlined, 'Maps'),
            _tile(Icons.calculate_outlined, 'Calc'),
            _tile(Icons.settings_outlined, 'Settings'),
            _tile(Icons.add, 'Create with Fa'),
          ]),
        ],
      ),
    );
  }

  Widget _tile(IconData icon, String label, {String? badge}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Icon(icon, size: 20, color: const Color(0xFF6B7280)),
          ),
          if (badge != null)
            Positioned(top: -2, right: -2, child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(color: const Color(0xFF4F46E5), borderRadius: BorderRadius.circular(4)),
              child: Text(badge, style: const TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.w600)),
            )),
        ]),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 9, color: Color(0xFF6B7280))),
      ],
    );
  }
}

class _TEntry extends StatelessWidget {
  const _TEntry({required this.icon, required this.label, required this.text});
  final IconData icon;
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 16, color: const Color(0xFF6B7280)),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280), fontWeight: FontWeight.w500)),
        Text(text, style: const TextStyle(fontSize: 12, color: Color(0xFF111827))),
      ])),
    ]);
  }
}

class _SuggPill extends StatelessWidget {
  const _SuggPill({required this.label});
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
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right, size: 14, color: Color(0xFF6B7280)),
      ]),
    );
  }
}
