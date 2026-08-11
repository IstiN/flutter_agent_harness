import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// The sessions list for the wide-screen sidebar: shows every live session
/// (from [manager]) with its derived or custom title, the active session
/// highlighted with a teal dot, and a "New session" button at the top.
class SidebarSessionsList extends StatefulWidget {
  const SidebarSessionsList({
    super.key,
    required this.manager,
    this.sessionNamesStore,
    this.onNewSession,
    this.onSessionTap,
  });

  final FlutterSessionManager manager;
  final SessionNamesStore? sessionNamesStore;
  final VoidCallback? onNewSession;

  /// Called after a session is tapped and [manager.switchTo] has run.
  final VoidCallback? onSessionTap;

  @override
  State<SidebarSessionsList> createState() => _SidebarSessionsListState();
}

class _SidebarSessionsListState extends State<SidebarSessionsList> {
  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onChanged);
    widget.sessionNamesStore?.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onChanged);
    widget.sessionNamesStore?.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final sessions = widget.manager.sessions;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Text(
                context.l10n.sidebarSessionsHeader.toUpperCase(),
                style: TextStyle(
                  color: colors.dim,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: widget.onNewSession,
                tooltip: context.l10n.sidebarNewSessionTooltip,
                iconSize: 20,
                color: colors.dim,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
        ),
        Expanded(
          child: sessions.isEmpty
              ? const SizedBox.shrink()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: sessions.length,
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    final isActive = widget.manager.active?.id == session.id;
                    final title =
                        widget.sessionNamesStore?.titleFor(session.id) ??
                        derivedSessionTitle(
                          context,
                          id: session.id,
                          createdAt: session.createdAt,
                        );
                    return _SessionTile(
                      title: title,
                      isActive: isActive,
                      onTap: () {
                        widget.manager.switchTo(session.id);
                        widget.onSessionTap?.call();
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.title,
    required this.isActive,
    required this.onTap,
  });

  final String title;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Material(
        color: isActive ? colors.panelAlt : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                if (isActive)
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: colors.teal,
                      shape: BoxShape.circle,
                    ),
                  )
                else
                  const SizedBox(width: 8),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isActive ? colors.text : colors.dim,
                      fontSize: 13,
                    ),
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
