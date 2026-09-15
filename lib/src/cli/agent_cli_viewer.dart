/// Session-ownership lease + viewer mode for the CLI (#428): a drive-open
/// claims the session's `_owner.json` lease through [FileSessionLeaseStore];
/// a live lease is NEVER seized — the opener becomes a viewer that watches
/// the transcript and forwards composed input to the owner's mailbox
/// through the messaging fabric. Graceful exit releases; staleness frees.
part of 'agent_cli.dart';

/// One viewer attachment: this process opened a session whose ownership
/// lease is live. No takeover exists, so this instance only watches the
/// transcript tail and hands composer input to the owner.
final class _ViewerAttachment {
  _ViewerAttachment({
    required this.sessionId,
    required this.sessionPath,
    required this.lease,
    required this.inputChannel,
    required this.eventSource,
  });

  /// The watched session.
  final String sessionId;
  final String sessionPath;

  /// The live lease that blocked the drive — the owner's identity for
  /// the banner, refreshed when the lease flips stale.
  SessionLease lease;

  final FileSessionInputChannel inputChannel;
  final SessionEventSource eventSource;
  StreamSubscription<AttachedSessionEvent>? subscription;

  /// Whether the pre-open backlog has been printed already.
  bool sawBacklog = false;

  /// Whether the lease has gone stale since the last tick — drives the
  /// banner variant and the one-time "owner looks dead" notice.
  bool stale = false;

  Future<void> dispose() async {
    await subscription?.cancel();
    await eventSource.dispose();
  }
}

/// Transcript rows printed from the backlog before live tailing starts.
const int _viewerBacklogCap = 5;

/// AgentCli lease/viewer half (private members of the CLI library).
extension AgentCliLease on AgentCli {
  /// Claims the ownership lease for the CURRENT session after a
  /// drive-open. Free/expired → acquired (a dead owner is named in a
  /// printed warning); live → viewer mode; no store (or an unenforceable
  /// backend) → today's unleased behavior.
  Future<void> _claimSessionLease() async {
    final store = config.leaseStore;
    final session = _session;
    if (store == null || session == null || _viewer != null) return;
    final meta = await session.getMetadata();
    final result = await store.acquire(
      sessionFilePath: meta.path,
      sessionId: meta.id,
      host: 'cli',
      bootId: _leaseBootId,
      pid: config.processId ?? 0,
      sessionName: await session.getSessionName(),
    );

    switch (result) {
      case LeaseAcquired(:final replaced):
        _heldLeasePath = meta.path;
        if (replaced != null) {
          io.writeln(
            _style.yellow(
              'lease: previous owner ${leaseOwnerLabel(replaced.host)} '
              '(pid ${replaced.pid}) looks dead (stale) — driving fresh',
            ),
          );
        }
      case LeaseBlocked(:final lease):
        await _enterViewerMode(lease: lease, meta: meta);
      case LeaseUnenforced():
        // E4/E5 fail-open: a broken or non-atomic lease store never
        // blocks opening a session — drive without enforcement.
        break;
    }
  }

  /// Headless claim (E7): no viewer mode exists here — returns the
  /// owner's live lease when blocked (the caller refuses), else null.
  Future<SessionLease?> _claimSessionLeaseHeadless() async {
    final store = config.leaseStore;
    final session = _session;
    if (store == null || session == null) return null;
    final meta = await session.getMetadata();
    final result = await store.acquire(
      sessionFilePath: meta.path,
      sessionId: meta.id,
      host: 'cli',
      bootId: _leaseBootId,
      pid: config.processId ?? 0,
      sessionName: await session.getSessionName(),
    );
    switch (result) {
      case LeaseAcquired():
        _heldLeasePath = meta.path;
        return null;
      case LeaseBlocked(:final lease):
        return lease;
      case LeaseUnenforced():
        return null;
    }
  }

  /// This instance becomes a viewer: tail the transcript, route composed
  /// input to the owner's mailbox. Prints nothing here — the REPLs print
  /// the banner after their own banner ([_printViewerBannerIfAny]).
  Future<void> _enterViewerMode({
    required SessionLease lease,
    required SessionMetadata meta,
  }) async {
    final attachment = _ViewerAttachment(
      sessionId: meta.id,
      sessionPath: meta.path,
      lease: lease,
      inputChannel: FileSessionInputChannel(
        repository: FileMessagingRepository(env: _env, root: _messagesRoot),
        fromId: 'fa CLI user',
      ),
      eventSource: FileSessionEventSource(
        env: _env,
        resolvePath: (_) async => meta.path,
      ),
    );
    _viewer = attachment;
    attachment.subscription = attachment.eventSource
        .watch(meta.id)
        .listen(_onViewerRows);
  }

  /// Tail rows: the first event is the pre-open backlog (printed dimmed,
  /// capped — the transcript already lives in the session file); every
  /// later event is live content from the driving host.
  void _onViewerRows(AttachedSessionEvent event) {
    final viewer = _viewer;
    if (viewer == null) return;
    var rows = event.appended;
    var dimmed = false;
    if (!viewer.sawBacklog) {
      viewer.sawBacklog = true;
      dimmed = true;
      if (rows.length > _viewerBacklogCap) {
        io.writeln(
          _style.dim(
            '… ${rows.length - _viewerBacklogCap} earlier rows not shown '
            '— the full transcript lives in the session',
          ),
        );
      }
      rows = rows.skip(rows.length - _viewerBacklogCap).toList();
    }
    for (final row in rows) {
      _printViewerRow(row, dimmed: dimmed);
    }
  }

  void _printViewerRow(AttachedMessage row, {bool dimmed = false}) {
    switch (row.role) {
      case AttachedMessageRole.user:
        final text = 'user: ${row.text}';
        io.writeln(dimmed ? _style.dim(text) : _style.bold(text));
      case AttachedMessageRole.assistant:
        io.writeln(dimmed ? _style.dim(row.text) : row.text);
      case AttachedMessageRole.tool:
        io.writeln(_style.dim('[tool] ${row.toolName ?? ''}'));
      case AttachedMessageRole.system:
        io.writeln(_style.dim(row.text));
    }
  }

  /// The 2s viewer tick: follow the lease only — the owner's mail,
  /// presence, and orphan reclaims are theirs, never a viewer's job.
  /// A live→stale flip prints the reopen notice once.
  Future<void> _viewerTick() async {
    final viewer = _viewer;
    if (viewer == null) return;
    final store = config.leaseStore;
    if (store == null) return;
    final inspect = await store.inspect(viewer.sessionPath);
    if (inspect.state == LeaseState.live || viewer.stale) return;
    viewer.stale = true;
    viewer.lease = inspect.lease ?? viewer.lease;
    io.writeln(
      _style.yellow(
        'lease: the driving ${leaseOwnerLabel(viewer.lease.host)} '
        '(pid ${viewer.lease.pid}) looks dead — reopen this session to '
        'drive it',
      ),
    );
  }

  /// Prints the viewer banner under the boot banner when this instance
  /// opened a leased session.
  Future<void> _printViewerBannerIfAny() async {
    final viewer = _viewer;
    if (viewer == null) return;
    io.writeln(
      _style.yellow(viewerBannerText(viewer.lease, stale: viewer.stale)),
    );
  }

  /// Viewer composer line → the owner's mailbox with CLI attribution.
  /// Never touches the session file (AC3: zero bytes from a viewer).
  Future<void> _viewerSend(String text) async {
    final viewer = _viewer;
    if (viewer == null) return;
    try {
      await viewer.inputChannel.send(viewer.sessionId, text);
      io.writeln(
        _style.dim(
          '[you → ${leaseOwnerLabel(viewer.lease.host)} '
          '(pid ${viewer.lease.pid})] $text',
        ),
      );
    } on Object catch (error) {
      io.writeln(_style.red('could not deliver to the driving agent: $error'));
    }
  }

  /// Releases OUR lease (graceful exit) and tears down viewer mode.
  /// A viewer never releases the owner's lease.
  Future<void> _releaseSessionLease() async {
    final viewer = _viewer;
    if (viewer != null) {
      _viewer = null;
      await viewer.dispose();
      return;
    }
    final path = _heldLeasePath;
    _heldLeasePath = null;
    final store = config.leaseStore;
    if (path != null && store != null) {
      await store.release(path, _leaseBootId);
    }
  }

  /// Touches the live presence row for the CURRENT session and
  /// re-registers after a /session switch (the boot row belonged to the
  /// session this process opened). A viewer keeps no row at all.
  Future<void> _touchPresenceForCurrentSession() async {
    final session = _session;
    if (_viewer != null || session == null) return;
    final meta = await session.getMetadata();
    final current = _livePresence;
    if (current != null && current.sessionId == meta.id) {
      await current.store.touch(meta.id);
      return;
    }
    if (current != null) {
      await current.store.unregister(current.sessionId);
    }
    _livePresence = await _registerLivePresence();
  }

  /// Heartbeat for OUR lease (every other inbox tick ≈ 4s, inside the
  /// 15s window): false means the lease was lost (expired + re-taken by
  /// another host) — demote to viewer of the new owner.
  Future<void> _leaseHeartbeat() async {
    final path = _heldLeasePath;
    final store = config.leaseStore;
    if (path == null || store == null) return;
    final alive = await store.heartbeat(path, _leaseBootId);
    if (alive) return;
    _heldLeasePath = null;
    final session = _session;
    if (session == null) return;
    final meta = await session.getMetadata();
    final inspect = await store.inspect(path);
    await _enterViewerMode(
      lease:
          inspect.lease ??
          SessionLease(
            host: 'unknown',
            sessionId: meta.id,
            pid: 0,
            bootId: 'unknown',
            heartbeatAt: '',
            acquiredAt: '',
          ),
      meta: meta,
    );
    io.writeln(
      _style.yellow(
        'lease: lost — another host is driving this session; you are a '
        'viewer now',
      ),
    );
    await _printViewerBannerIfAny();
  }
}
