// l10n:ignore-file — part of onboarding_screen.dart, which carries the
// exemption (marketing copy mirrors the EN reference prototype).
part of 'onboarding_screen.dart';

// Mockup widgets for the onboarding pages (chat bubbles, the Focus Timer
// card, app tiles, the My Apps widgets) — split out to keep
// onboarding_screen.dart under the repo's 2800-line file limit.

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
