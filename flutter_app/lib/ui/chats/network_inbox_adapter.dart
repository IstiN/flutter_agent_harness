import 'chat_list_entry.dart';

/// One item from `GET /api/inbox?limit&cursor&kinds`.
final class NetworkInboxItem {
  const NetworkInboxItem({
    required this.kind,
    required this.networkId,
    required this.id,
    required this.title,
    this.lastActivity,
    this.unreadCount,
    this.lastEnvelope,
    this.presence,
  });

  final ChatListEntryKind kind;
  final String networkId;
  final String id;
  final String title;
  final DateTime? lastActivity;

  /// Channels carry a numeric count; agents may omit it (unknown).
  final int? unreadCount;
  final NetworkEnvelopeRef? lastEnvelope;
  final ChatPresence? presence;

  factory NetworkInboxItem.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] == 'channel'
        ? ChatListEntryKind.networkChannel
        : ChatListEntryKind.networkAgent;
    return NetworkInboxItem(
      kind: kind,
      networkId: json['networkId'] as String? ?? '',
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      lastActivity: DateTime.tryParse(json['lastActivity'] as String? ?? ''),
      unreadCount: (json['unreadCount'] as num?)?.toInt(),
      lastEnvelope: json['lastEnvelope'] is Map
          ? NetworkEnvelopeRef.fromJson(
              (json['lastEnvelope'] as Map).cast<String, dynamic>(),
            )
          : null,
      presence: switch (json['presence']) {
        'live' => ChatPresence.live,
        'busy' => ChatPresence.busy,
        'offline' => ChatPresence.offline,
        _ => null,
      },
    );
  }

  ChatListEntry toEntry({String? networkName}) => ChatListEntry(
    id: ChatEntryId.network(kind, networkId: networkId, id: id),
    kind: kind,
    networkId: networkId,
    networkName: networkName,
    title: title,
    createdAt:
        lastActivity ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    lastActivity: lastActivity,
    unreadCount: unreadCount,
    presence: presence,
    lastEnvelope: lastEnvelope,
    // The aggregate payload is opaque. A preview arrives only after the
    // detail/decryption integration; it is never fabricated here.
  );
}

/// Aggregate page envelope, including the forward pagination cursor.
final class NetworkInboxPage {
  const NetworkInboxPage({required this.items, this.nextCursor});

  final List<NetworkInboxItem> items;
  final String? nextCursor;

  factory NetworkInboxPage.fromJson(Map<String, dynamic> json) =>
      NetworkInboxPage(
        items: [
          for (final item in json['items'] as List? ?? const [])
            if (item is Map)
              NetworkInboxItem.fromJson(item.cast<String, dynamic>()),
        ],
        nextCursor: json['nextCursor'] as String?,
      );
}

typedef NetworkChannelReadCall = ({
  String channelId,
  int? seq,
  String? envelopeId,
  bool all,
});

/// Typed boundary for the approved fa_network aggregate API.
///
/// HTTP transport intentionally lands separately. Implementations must not
/// connect every membership to produce this projection.
abstract interface class NetworkInboxAdapter {
  Future<NetworkInboxPage> fetchInbox({
    int? limit,
    String? cursor,
    Set<ChatListEntryKind>? kinds,
  });

  /// `PATCH /api/channels/{id}/read`, exactly one of seq/envelopeId/all.
  Future<void> markChannelRead(
    String channelId, {
    int? seq,
    String? envelopeId,
    bool all = false,
  });
}

final class NetworkInboxUnavailableException implements Exception {
  const NetworkInboxUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Explicit unavailable fixture: an error, never an empty page with invented
/// zero unread counts.
final class UnavailableNetworkInboxAdapter implements NetworkInboxAdapter {
  const UnavailableNetworkInboxAdapter();

  @override
  Future<NetworkInboxPage> fetchInbox({
    int? limit,
    String? cursor,
    Set<ChatListEntryKind>? kinds,
  }) async => throw const NetworkInboxUnavailableException(
    'The network inbox is not available yet.',
  );

  @override
  Future<void> markChannelRead(
    String channelId, {
    int? seq,
    String? envelopeId,
    bool all = false,
  }) async => throw const NetworkInboxUnavailableException(
    'The network inbox is not available yet.',
  );
}

/// Deterministic fixture for controller/widget/golden tests.
final class FixtureNetworkInboxAdapter implements NetworkInboxAdapter {
  FixtureNetworkInboxAdapter({
    List<NetworkInboxItem> items = const [],
    this.nextCursor,
    this.error,
  }) : items = List.of(items);

  List<NetworkInboxItem> items;
  String? nextCursor;
  Object? error;
  int fetchCount = 0;
  int? lastLimit;
  String? lastCursor;
  Set<ChatListEntryKind>? lastKinds;
  final List<NetworkChannelReadCall> readCalls = [];

  @override
  Future<NetworkInboxPage> fetchInbox({
    int? limit,
    String? cursor,
    Set<ChatListEntryKind>? kinds,
  }) async {
    fetchCount++;
    lastLimit = limit;
    lastCursor = cursor;
    lastKinds = kinds == null ? null : Set.of(kinds);
    final failure = error;
    if (failure != null) throw failure;
    final filtered = [
      for (final item in items)
        if (kinds == null || kinds.contains(item.kind)) item,
    ];
    return NetworkInboxPage(items: filtered, nextCursor: nextCursor);
  }

  @override
  Future<void> markChannelRead(
    String channelId, {
    int? seq,
    String? envelopeId,
    bool all = false,
  }) async {
    final failure = error;
    if (failure != null) throw failure;
    readCalls.add((
      channelId: channelId,
      seq: seq,
      envelopeId: envelopeId,
      all: all,
    ));
  }
}
