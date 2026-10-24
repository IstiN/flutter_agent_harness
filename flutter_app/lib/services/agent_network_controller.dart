// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'agent_network_store.dart';
import 'agent_network_transport.dart';
import 'dap_enrollment_service.dart';
import 'project_mount_env.dart';

/// The app agent's membership in the DAP hub network (issue #402 AC3).
///
/// Owns the opt-in settings ([AgentNetworkStore]) and the
/// [HubMessagingRepository] lifecycle; composes the hub repository OVER
/// the app's swappable file fabric through [FallbackMessagingRepository]
/// (the exact shape the CLI's `buildAgentFabric` builds), so the agent's
/// existing inbox probe drains hub mail with no further plumbing. Opting
/// out swaps back to the bare file layer.
///
/// Failure honesty (E4): an unreachable hub boots the app fully usable on
/// the file fabric; the link retries in the background and [state] says
/// what is really going on.
class AgentNetworkController extends ChangeNotifier {
  /// Creates a controller. [fileLayer] is the app's file messaging
  /// repository (the fallback side of the composition) and [fileFabric]
  /// the swappable wrapper the agent actually uses — [start] swaps the
  /// composite in. [transport] and the identity loader come from the
  /// platform seam — null where the network is unsupported (web).
  AgentNetworkController({
    required this._env,
    required this._fileLayer,
    required this._fileFabric,
    HubTransport? transport,
    Future<HubIdentity?> Function(String? path)? loadIdentity,
    DapEnrollmentStore? enrollmentStore,
    String? projectCwd,
  }) : _transport = transport ?? platformHubTransport,
       _loadIdentity = loadIdentity ?? loadOrCreateIdentity,
       // ignore: prefer_initializing_formals
       _enrollmentStore = enrollmentStore,
       // ignore: prefer_initializing_formals
       _projectCwd = projectCwd {
    _store = AgentNetworkStore.inMemory();
  }

  final ExecutionEnv _env;
  final FileMessagingRepository _fileLayer;
  final SwappableMessagingRepository _fileFabric;
  final HubTransport? _transport;
  final Future<HubIdentity?> Function(String? path)? _loadIdentity;
  final String? _projectCwd;
  DapEnrollmentStore? _enrollmentStore;

  late AgentNetworkStore _store;
  HubMessagingRepository? _hub;
  StreamSubscription<HubLinkState>? _linkSub;
  bool _disposed = false;

  /// The platform seam answers (false on web).
  bool get supported => _transport != null && _loadIdentity != null;

  AgentNetworkStore get store => _store;

  /// The live link state (null = not joined).
  HubLinkState? get state => _hub?.state;

  /// This agent's hub address (null = not joined / still connecting).
  String? get agentId => _hub?.agentId;

  /// Loads the persisted settings; joins when enabled. Call once at boot
  /// (the service construction path).
  Future<void> start() async {
    _store = await AgentNetworkStore.load(_env);
    _enrollmentStore ??= await DapEnrollmentStore.load(
      _env,
      projectCwd: _effectiveProjectCwd,
    );
    if (_store.enabled) await _joinSaved();
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    await _store.setEnabled(value);
    if (_disposed) return;
    if (value) {
      await _joinSaved();
    } else {
      await _leave();
    }
    notifyListeners();
  }

  String get _effectiveProjectCwd => _projectCwd ?? _env.sessionCwd;

  Future<DapEnrollmentStore> _enrollments() async => _enrollmentStore ??=
      await DapEnrollmentStore.load(_env, projectCwd: _effectiveProjectCwd);

  /// Boot/toggle reconnect: a failed dial stays owned by the repository's
  /// reconnect loop; settings interactions never surface a raw hub error.
  Future<void> _joinSaved() async {
    try {
      final enrollment = (await _enrollments()).enrollment;
      if (enrollment != null) {
        await _join(enrollment: enrollment);
      } else {
        await _join();
      }
    } on Object {
      // The live repository keeps retrying with the persisted membership.
    }
  }

  /// Persists a connection change; a live link restarts onto the new
  /// settings (the /settings flow).
  Future<void> saveConnection({
    String? url,
    String? token,
    String? name,
  }) async {
    // Saving the manual settings form explicitly leaves invite enrollment;
    // otherwise the next boot would unexpectedly restore the old hub.
    final enrollments = await _enrollments();
    if (enrollments.enrollment != null) await enrollments.clear();
    await _store.setConnection(url: url, token: token, name: name);
    if (_disposed) return;
    if (_store.enabled) {
      await _leave();
      await _join();
    }
    notifyListeners();
  }

  /// The fabric directory (the roster view). Empty when not joined —
  /// callers render the file-fabric-only world.
  Future<List<MailboxEntry>> peers() async {
    final hub = _hub;
    if (hub == null || !hub.isConnected) return const [];
    try {
      return await hub.directory();
    } on Object {
      return const [];
    }
  }

  /// Connects the SAME repository used by the agent fabric to an invited
  /// channel, imports its keys, and persists the scoped reconnect record.
  /// The credential goes only to the bearer transport and secure store —
  /// never to [SecretsExecutionEnv], session records, or model context.
  Future<void> joinEnrollment(DapJoinBundle bundle) async {
    if (!supported) throw StateError('DAP enrollment is unsupported');
    final normalized = _normalizeEnrollment(bundle);
    if ((normalized.invite.pub == null) != (normalized.invite.priv == null)) {
      throw const FormatException('incomplete channel keypair');
    }
    final enrollments = await _enrollments();
    await enrollments.save(normalized);
    await _store.setConnection(
      url: normalized.hubUrl,
      name: normalized.agentName,
    );
    await _store.setEnabled(true);
    if (_disposed) return;
    await _leave();
    await _join(enrollment: normalized);
    notifyListeners();
  }

  /// Sends a DM through the composite fabric: hub-resolvable targets go
  /// hub-ward, everything else lands in the file inbox (offline carrier).
  Future<void> sendDm(String toId, String text) async {
    await _fileFabric.send(
      AgentMessage(
        id: 'dm-${DateTime.now().microsecondsSinceEpoch}',
        fromId: 'main',
        toId: toId,
        text: text,
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  Future<void> _join({DapJoinBundle? enrollment}) async {
    if (!supported || _hub != null) return;
    final enrolled = enrollment != null;
    final identityPath = enrolled
        ? identityPathFor(
            '${_env.appStorageCwd}/dap/'
            '${dapEnrollmentProjectScope(_effectiveProjectCwd)}',
          )
        : identityPathFor(_env.cwd);
    final identity = await _loadIdentity!(identityPath);
    final hub = HubMessagingRepository(
      url: Uri.parse(enrollment?.hubUrl ?? _store.url),
      transport: _transport!,
      identity: identity,
      token: enrolled
          ? null
          : _store.token.isEmpty
          ? null
          : _store.token,
      clientSecret: enrollment?.clientSecret,
      name: enrollment?.agentName ?? _store.name,
      onLog: (line) => debugPrint('[agent-network] $line'),
    );
    _hub = hub;
    _linkSub = hub.stateChanges.listen((_) => notifyListeners());
    await hub.start();
    // Composite over the file layer (the CLI buildAgentFabric shape).
    final composite = FallbackMessagingRepository(
      primary: hub,
      fallback: _fileLayer,
    );
    composite.primaryMailbox = () => 'main';
    _fileFabric.swap(composite);
    if (enrollment != null) {
      final pub = enrollment.invite.pub;
      final priv = enrollment.invite.priv;
      await hub.joinChannel(
        enrollment.invite.channel,
        keys: pub == null || priv == null
            ? null
            : HubChannelKeys(pub: pub, priv: priv),
      );
    }
  }

  static DapJoinBundle _normalizeEnrollment(DapJoinBundle bundle) =>
      DapJoinBundle(
        invite: DapInviteImport(
          hubUrl: _normalizeHubUrl(bundle.invite.hubUrl),
          channel: bundle.invite.channel,
          pub: bundle.invite.pub,
          priv: bundle.invite.priv,
        ),
        hubUrl: _normalizeHubUrl(bundle.hubUrl),
        clientSecret: bundle.clientSecret,
        agentName: bundle.agentName,
      );

  static String _normalizeHubUrl(String value) {
    final uri = Uri.parse(value).removeFragment();
    final query = Map<String, String>.from(uri.queryParameters)
      ..remove('channel');
    final normalized = uri.replace(queryParameters: query).toString();
    return normalized.endsWith('?')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }

  Future<void> _leave() async {
    final hub = _hub;
    _hub = null;
    await _linkSub?.cancel();
    _linkSub = null;
    // Back to the bare file layer BEFORE the hub stops: no drain window
    // where mail would hit a stopped primary.
    _fileFabric.swap(_fileLayer);
    await hub?.stop();
    await hub?.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_leave());
    super.dispose();
  }
}
