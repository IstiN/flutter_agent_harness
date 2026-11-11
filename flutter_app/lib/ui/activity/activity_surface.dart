import 'dart:math' as math;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/widgets/messenger_section_header.dart'
    show MessengerFloatingDockInsets;
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// The session activity subsets available in the messenger list.
enum ActivityFilter { all, running, recent }

/// Shared selection and filtering state for the activity list and detail.
///
/// The controller listens to the manager, the optional names store, and every
/// currently managed service. A selection survives list refreshes when its
/// session still exists. [clearSelection] is explicit: subsequent manager
/// updates do not immediately select another row, which lets compact hosts
/// return to their list without the detail fighting that navigation.
final class ActivityController extends ChangeNotifier {
  factory ActivityController({
    required FlutterSessionManager manager,
    SessionNamesStore? namesStore,
  }) => ActivityController._(manager, namesStore);

  ActivityController._(this._manager, this._namesStore) {
    _manager.addListener(_onManagerChanged);
    _namesStore?.addListener(_onActivityChanged);
    _syncServiceListeners();
    _reconcileSelection();
  }

  final FlutterSessionManager _manager;
  SessionNamesStore? _namesStore;
  final Map<AgentService, VoidCallback> _serviceListeners =
      <AgentService, VoidCallback>{};

  ActivityFilter _filter = ActivityFilter.all;
  String _query = '';
  String? _selectedId;
  bool _selectionExplicitlyCleared = false;

  /// The active list filter.
  ActivityFilter get filter => _filter;

  /// Changes the visible session subset.
  void setFilter(ActivityFilter value) {
    if (_filter == value) return;
    _filter = value;
    notifyListeners();
  }

  /// Filters the real session activity by its current title or id.
  void setSearch(String value) {
    final query = value.trim().toLowerCase();
    if (_query == query) return;
    _query = query;
    notifyListeners();
  }

  /// Sessions matching [filter], in the manager's newest-first order.
  List<FlutterManagedSession> get filteredSessions {
    final sessions = _manager.sessions;
    return List.unmodifiable(
      sessions.where((session) {
        final inFilter = switch (_filter) {
          ActivityFilter.all => true,
          ActivityFilter.running => isRunning(session),
          ActivityFilter.recent => !isRunning(session),
        };
        if (!inFilter) return false;
        if (_query.isEmpty) return true;
        final title = _namesStore?.titleFor(session.id) ?? '';
        return title.toLowerCase().contains(_query) ||
            session.id.toLowerCase().contains(_query);
      }),
    );
  }

  /// The selected session, or null after an explicit clear or when empty.
  FlutterManagedSession? get selectedSession {
    final id = _selectedId;
    if (id == null) return null;
    for (final session in _manager.sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  /// Selects a currently managed session. Unknown ids leave state unchanged.
  void select(String id) {
    if (!_manager.sessions.any((session) => session.id == id)) return;
    if (_selectedId == id && !_selectionExplicitlyCleared) return;
    _selectedId = id;
    _selectionExplicitlyCleared = false;
    notifyListeners();
  }

  /// Clears selection without allowing a later refresh to undo that action.
  void clearSelection() {
    final hadSelection = _selectedId != null;
    _selectedId = null;
    _selectionExplicitlyCleared = true;
    if (hadSelection) notifyListeners();
  }

  /// Replaces the lazily loaded title store without losing list selection.
  void updateNamesStore(SessionNamesStore? store) {
    if (identical(store, _namesStore)) return;
    _namesStore?.removeListener(_onActivityChanged);
    _namesStore = store;
    _namesStore?.addListener(_onActivityChanged);
    notifyListeners();
  }

  /// Returns the user-given title, or null so a widget can localize fallback.
  String? titleFor(FlutterManagedSession session) =>
      _namesStore?.titleFor(session.id);

  /// Whether this session currently has an agent run in flight.
  bool isRunning(FlutterManagedSession session) => session.service.isStreaming;

  void _onManagerChanged() {
    _syncServiceListeners();
    _reconcileSelection();
    notifyListeners();
  }

  void _onActivityChanged() {
    notifyListeners();
  }

  void _reconcileSelection() {
    final sessions = _manager.sessions;
    final selected = _selectedId;
    if (selected != null && sessions.any((session) => session.id == selected)) {
      return;
    }
    _selectedId = null;
    if (!_selectionExplicitlyCleared && sessions.isNotEmpty) {
      _selectedId = sessions.first.id;
    }
  }

  void _syncServiceListeners() {
    final current = _manager.sessions.map((session) => session.service).toSet();
    final removed = _serviceListeners.keys
        .where((service) => !current.contains(service))
        .toList();
    for (final service in removed) {
      service.removeListener(_serviceListeners.remove(service)!);
    }
    for (final service in current.difference(_serviceListeners.keys.toSet())) {
      var streaming = service.isStreaming;
      void onServiceChanged() {
        // Activity needs run-boundary state and the final preview, not every
        // partial token. Rebuilding all rows on every delta is O(sessions ×
        // retained messages) and makes long transcripts sluggish.
        if (streaming == service.isStreaming) return;
        streaming = service.isStreaming;
        notifyListeners();
      }

      _serviceListeners[service] = onServiceChanged;
      service.addListener(onServiceChanged);
    }
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerChanged);
    _namesStore?.removeListener(_onActivityChanged);
    for (final entry in _serviceListeners.entries) {
      entry.key.removeListener(entry.value);
    }
    _serviceListeners.clear();
    super.dispose();
  }
}

/// A flat, sectioned activity list following the Fa2 messenger wireframe.
final class ActivityListPanel extends StatelessWidget {
  const ActivityListPanel({
    super.key,
    required this.controller,
    this.compact = false,
    this.navigation,
    this.onSelect,
    this.topPadding = 0,
  });

  final ActivityController controller;
  final bool compact;
  final ValueChanged<String>? onSelect;

  /// Inset owned by a host glass header; rows scroll underneath it.
  final double topPadding;

  /// Optional host navigation below the compact Activity section heading.
  /// This is deliberately not a global brand header; the shell owns that.
  final Widget? navigation;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return ColoredBox(
      color: tokens.direction == FaVisualDirection.glass
          ? Colors.transparent
          : tokens.surface1,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final sessions = controller.filteredSessions;
          if (compact && navigation != null) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ActivitySectionHeader(title: context.l10n.wideNavActivity),
                navigation!,
                _FilterToolbar(controller: controller, count: sessions.length),
                Expanded(
                  child: sessions.isEmpty
                      ? const _ActivityListEmpty()
                      : _ActivityList(
                          controller: controller,
                          sessions: sessions,
                          onSelect: onSelect,
                          compact: compact,
                        ),
                ),
              ],
            );
          }
          final listTop = topPadding + 45;
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: sessions.isEmpty
                    ? Padding(
                        padding: EdgeInsets.only(top: listTop),
                        child: const _ActivityListEmpty(),
                      )
                    : _ActivityList(
                        controller: controller,
                        sessions: sessions,
                        onSelect: onSelect,
                        topPadding: listTop,
                      ),
              ),
              Positioned(
                top: topPadding,
                left: 0,
                right: 0,
                child: _FilterToolbar(
                  controller: controller,
                  count: sessions.length,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final class _ActivitySectionHeader extends StatelessWidget {
  const _ActivitySectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.hairline)),
      ),
      child: Text(
        title,
        style: TextStyle(
          color: tokens.ink1,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

final class _FilterToolbar extends StatelessWidget {
  const _FilterToolbar({required this.controller, required this.count});

  final ActivityController controller;
  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Container(
      height: 45,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          PopupMenuButton<ActivityFilter>(
            key: const ValueKey('activityFilter'),
            initialValue: controller.filter,
            color: tokens.surface2,
            onSelected: controller.setFilter,
            itemBuilder: (context) => [
              PopupMenuItem(
                key: const ValueKey('activityFilterOption-all'),
                value: ActivityFilter.all,
                child: Text(context.l10n.activityAll),
              ),
              PopupMenuItem(
                key: const ValueKey('activityFilterOption-running'),
                value: ActivityFilter.running,
                child: Text(context.l10n.activityRunning),
              ),
              PopupMenuItem(
                key: const ValueKey('activityFilterOption-recent'),
                value: ActivityFilter.recent,
                child: Text(context.l10n.activityRecent),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FaSectionEyebrow(
                    label: switch (controller.filter) {
                      ActivityFilter.all => context.l10n.activityAll,
                      ActivityFilter.running => context.l10n.activityRunning,
                      ActivityFilter.recent => context.l10n.activityRecent,
                    },
                    padding: EdgeInsets.zero,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: tokens.ink2,
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          Text(
            '$count',
            key: const ValueKey('activityCount'),
            style: TextStyle(color: tokens.ink2, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

final class _ActivityList extends StatelessWidget {
  const _ActivityList({
    required this.controller,
    required this.sessions,
    this.onSelect,
    this.topPadding = 0,
    this.compact = false,
  });

  final ActivityController controller;
  final List<FlutterManagedSession> sessions;
  final ValueChanged<String>? onSelect;
  final double topPadding;

  /// Compact (phone) host: the floating dock scrolls OVER this list, so the
  /// dock's occupied height is reserved as scroll padding — the final rows
  /// stay reachable above the pill. Desktop keeps the plain 4pt inset.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final running = sessions.where(controller.isRunning).toList();
    final recent = sessions
        .where((session) => !controller.isRunning(session))
        .toList();
    final selectedId = controller.selectedSession?.id;
    return ListView(
      key: const ValueKey('activityList'),
      padding: EdgeInsets.only(
        top: topPadding + 4,
        bottom: compact
            ? math.max<double>(4, MessengerFloatingDockInsets.bottomOf(context))
            : 4,
      ),
      children: [
        if (running.isNotEmpty) ...[
          _ListSectionLabel(label: context.l10n.activityRunning),
          for (final session in running)
            _ActivityRow(
              controller: controller,
              session: session,
              selected: selectedId == session.id,
              onSelect: onSelect,
            ),
        ],
        if (recent.isNotEmpty) ...[
          _ListSectionLabel(label: context.l10n.activityRecent),
          for (final session in recent)
            _ActivityRow(
              controller: controller,
              session: session,
              selected: selectedId == session.id,
              onSelect: onSelect,
            ),
        ],
      ],
    );
  }
}

final class _ListSectionLabel extends StatelessWidget {
  const _ListSectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return FaSectionEyebrow(label: label);
  }
}

final class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.controller,
    required this.session,
    required this.selected,
    this.onSelect,
  });

  final ActivityController controller;
  final FlutterManagedSession session;
  final bool selected;
  final ValueChanged<String>? onSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final running = controller.isRunning(session);
    final preview = _sessionPreview(session);
    final status = running
        ? context.l10n.activityRunning
        : context.l10n.activityRecent;
    final selectedForeground = scheme.onPrimary;
    final foreground = selected ? selectedForeground : tokens.ink1;
    final subdued = selected ? selectedForeground.withAlpha(205) : tokens.ink2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? scheme.primary : Colors.transparent,
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('activitySession-${session.id}'),
          borderRadius: BorderRadius.circular(12),
          hoverColor: selected
              ? selectedForeground.withAlpha(12)
              : tokens.surface2,
          onTap: () {
            controller.select(session.id);
            onSelect?.call(session.id);
          },
          child: Container(
            constraints: const BoxConstraints(minHeight: 68),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                _ActivityMark(running: running, selected: selected),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _sessionTitle(context, controller, session),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: foreground,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _activityTimestamp(context, session.lastUpdatedAt),
                            style: TextStyle(color: subdued, fontSize: 11),
                          ),
                        ],
                      ),
                      if (preview != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: subdued, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 3),
                      Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: subdued, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _ActivityMark extends StatelessWidget {
  const _ActivityMark({required this.running, required this.selected});

  final bool running;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final selectedForeground = scheme.onPrimary;
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: selected
            ? selectedForeground.withAlpha(28)
            : running
            ? tokens.accentSoft
            : tokens.surface2,
        border: Border.all(
          color: selected
              ? selectedForeground.withAlpha(70)
              : running
              ? tokens.accent
              : tokens.ink3,
        ),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(
        running ? Icons.play_arrow_rounded : Icons.chat_bubble_outline_rounded,
        size: 15,
        color: selected
            ? selectedForeground
            : running
            ? tokens.accent
            : tokens.ink2,
      ),
    );
  }
}

final class _ActivityListEmpty extends StatelessWidget {
  const _ActivityListEmpty();

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.monitor_heart_outlined, size: 36, color: tokens.ink3),
            const SizedBox(height: 12),
            Text(
              context.l10n.activityEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(color: tokens.ink2, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// The activity reading pane, with a compact content header and chat action.
final class ActivityDetailPanel extends StatelessWidget {
  const ActivityDetailPanel({
    super.key,
    required this.controller,
    required this.onOpenSession,
    this.onBack,
    this.compact = false,
    this.showFirstWhenUnselected = false,
  });

  final ActivityController controller;
  final ValueChanged<String> onOpenSession;
  final VoidCallback? onBack;
  final bool compact;

  /// Displays the first visible session without mutating controller selection.
  /// Compact hosts normally leave this false so back can show an empty detail.
  final bool showFirstWhenUnselected;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return ColoredBox(
      color: tokens.surface1,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          var session = controller.selectedSession;
          if (session == null && showFirstWhenUnselected) {
            final sessions = controller.filteredSessions;
            if (sessions.isNotEmpty) session = sessions.first;
          }
          if (session == null) {
            return _ActivityDetailEmpty(onBack: onBack, compact: compact);
          }
          return _ActivityDetail(
            controller: controller,
            session: session,
            onOpenSession: onOpenSession,
            onBack: onBack,
            compact: compact,
          );
        },
      ),
    );
  }
}

final class _ActivityDetailEmpty extends StatelessWidget {
  const _ActivityDetailEmpty({required this.onBack, required this.compact});

  final VoidCallback? onBack;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Column(
      children: [
        if (onBack != null)
          _DetailHeader(
            title: context.l10n.wideNavActivity,
            onBack: onBack,
            compact: compact,
          ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.monitor_heart_outlined,
                    size: 38,
                    color: tokens.ink3,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.l10n.activityChoose,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _ActivityDetail extends StatelessWidget {
  const _ActivityDetail({
    required this.controller,
    required this.session,
    required this.onOpenSession,
    required this.onBack,
    required this.compact,
  });

  final ActivityController controller;
  final FlutterManagedSession session;
  final ValueChanged<String> onOpenSession;
  final VoidCallback? onBack;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final running = controller.isRunning(session);
    final status = running
        ? context.l10n.activityRunning
        : context.l10n.activityRecent;
    final title = _sessionTitle(context, controller, session);
    final preview = _sessionPreview(session);
    return Column(
      children: [
        _DetailHeader(
          title: title,
          subtitle: status,
          onBack: onBack,
          compact: compact,
          trailing: compact
              ? null
              : Text(
                  status,
                  style: TextStyle(color: tokens.ink2, fontSize: 11),
                ),
        ),
        Expanded(
          child: SingleChildScrollView(
            key: const ValueKey('activityDetailScroll'),
            // Compact (phone): reserve the floating dock's occupied height
            // so the reading pane's tail scrolls above the pill (desktop
            // keeps the plain 18pt frame).
            padding: compact
                ? EdgeInsets.fromLTRB(18, 18, 18,
                    18 + MessengerFloatingDockInsets.bottomOf(context))
                : const EdgeInsets.all(18),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: tokens.ink1,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (preview != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        preview,
                        style: TextStyle(
                          color: tokens.ink2,
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 32,
                      runSpacing: 16,
                      children: [
                        _DetailCell(
                          label: context.l10n.activityStatus,
                          value: status,
                        ),
                        _DetailCell(
                          label: context.l10n.activityLastActivity,
                          value: _activityTimestamp(
                            context,
                            session.lastUpdatedAt,
                            includeDate: true,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        key: const ValueKey('activityOpenChat'),
                        onPressed: () => onOpenSession(session.id),
                        icon: const Icon(Icons.chat_bubble_outline, size: 16),
                        label: Text(context.l10n.appsOpenChatTooltip),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.title,
    required this.onBack,
    required this.compact,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final bool compact;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Container(
      height: compact ? 56 : 62,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.hairline)),
      ),
      child: Row(
        children: [
          if (onBack != null) ...[
            IconButton(
              key: const ValueKey('activityBack'),
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
              color: tokens.ink2,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.ink1,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tokens.ink2, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

final class _DetailCell extends StatelessWidget {
  const _DetailCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 280),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: tokens.ink2, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(color: tokens.ink1, fontSize: 13)),
        ],
      ),
    );
  }
}

String _sessionTitle(
  BuildContext context,
  ActivityController controller,
  FlutterManagedSession session,
) {
  return controller.titleFor(session) ??
      derivedSessionTitle(
        context,
        id: session.id,
        createdAt: session.createdAt,
      );
}

String? _sessionPreview(FlutterManagedSession session) {
  for (final message in session.service.messages.reversed) {
    if (message.role != 'user' && message.role != 'assistant') continue;
    final text = message.content.trim();
    if (text.isNotEmpty) return text;
  }
  return null;
}

String _activityTimestamp(
  BuildContext context,
  DateTime timestamp, {
  bool includeDate = false,
}) {
  final local = timestamp.toLocal();
  final material = MaterialLocalizations.of(context);
  final time = material.formatTimeOfDay(TimeOfDay.fromDateTime(local));
  final now = DateTime.now();
  final isToday =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  if (!includeDate && isToday) return time;
  return '${material.formatShortDate(local)} $time';
}
