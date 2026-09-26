/// Parsing and building of fa_network join links.
///
/// A join link looks like:
///
///     https://network.fa1.dev/join?network=<networkId>#pw=<password>
///
/// The fragment (`#pw=...`) is client-side only — it is never sent to the
/// server. Both the fragment and the password are optional: a link without
/// them means the password must be obtained another way (e.g. the
/// `FA_NETWORK_PASSWORD` environment variable).
library;

/// A parsed fa_network join link.
final class FanetJoinLink {
  /// Creates a join link value. [restBase] may be a [Uri] or its string
  /// form; it must be the server origin (scheme + host + optional port),
  /// without a path.
  FanetJoinLink({
    required Object restBase,
    required this.networkId,
    this.password,
  }) : restBase = restBase is String ? Uri.parse(restBase) : restBase as Uri;

  /// The REST origin of the fa_network server (scheme + host + optional
  /// port, no path) — the base URL for [FanetClient].
  final Uri restBase;

  /// The network to join.
  final String networkId;

  /// The network password carried in the link fragment, if any.
  final String? password;

  static const _fragmentPrefix = 'pw=';

  /// Parses a join link such as
  /// `https://network.fa1.dev/join?network=net-1#pw=s3cret`.
  ///
  /// Throws a [FormatException] when [link] is not a valid fa_network join
  /// link: wrong scheme, wrong path, missing `network` query parameter, or
  /// an unexpected fragment shape.
  factory FanetJoinLink.parse(String link) {
    final Uri uri;
    try {
      uri = Uri.parse(link);
    } on FormatException catch (e) {
      throw FormatException('Invalid fa_network join link: $link', e);
    }
    if (!uri.isScheme('http') && !uri.isScheme('https')) {
      throw FormatException(
        'fa_network join link must use http(s), got ${uri.scheme}: $link',
      );
    }
    if (uri.host.isEmpty) {
      throw FormatException('fa_network join link has no host: $link');
    }
    if (uri.pathSegments.length != 1 || uri.pathSegments.single != 'join') {
      throw FormatException(
        'fa_network join link must have path /join, got ${uri.path}: $link',
      );
    }
    final networkId = uri.queryParameters['network'];
    if (networkId == null || networkId.isEmpty) {
      throw FormatException(
        'fa_network join link is missing the network query parameter: $link',
      );
    }
    String? password;
    if (uri.hasFragment && uri.fragment.isNotEmpty) {
      // Uri.fragment is NOT percent-decoded (unlike queryParameters).
      final raw = uri.fragment;
      if (!raw.startsWith(_fragmentPrefix)) {
        throw FormatException(
          'fa_network join link has an unexpected fragment '
          '"$raw" (expected "pw=<password>"): $link',
        );
      }
      String decoded;
      try {
        decoded = Uri.decodeComponent(raw.substring(_fragmentPrefix.length));
      } on ArgumentError {
        throw FormatException(
          'fa_network join link fragment is not valid percent-encoding: $link',
        );
      }
      if (decoded.isNotEmpty) password = decoded;
    }
    return FanetJoinLink(
      restBase: Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      ),
      networkId: networkId,
      password: password,
    );
  }

  /// Builds the join link back, percent-encoding the network id and the
  /// password as needed. The inverse of [FanetJoinLink.parse].
  Uri toUri() => Uri(
    scheme: restBase.scheme,
    host: restBase.host,
    port: restBase.hasPort ? restBase.port : null,
    path: '/join',
    queryParameters: {'network': networkId},
    fragment: password == null ? null : '$_fragmentPrefix$password',
  );

  @override
  String toString() => toUri().toString();
}
