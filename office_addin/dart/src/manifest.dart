// Outlook add-in manifest validator (issue #89, AC1).
//
// Pure-Dart check over the classic v1 MailApp XML: every resource URL is
// https under the expected host (fa1.dev, or localhost:8443 in --dev
// builds) with path prefix /outlook/, the permission ladder lands exactly
// on ReadWriteItem (⇒ derived tiers {ReadItem, ReadWriteItem}), exactly
// one Mailbox host, no mobile form factor. Regex-shaped on purpose: this
// is a lint pass, not a schema parser.
library;

/// Verdict for one manifest document.
final class OutlookManifestReport {
  /// Human-readable problems, empty when the manifest is acceptable.
  final List<String> issues;

  const OutlookManifestReport(this.issues);

  bool get ok => issues.isEmpty;
}

/// Permission ladder of the classic manifest, lowest first.
const _ladder = <String>[
  'Restricted',
  'ReadItem',
  'ReadWriteItem',
  'ReadWriteMailbox',
];

/// Tiers the manifest must derive to: the declaration must expand to
/// exactly these (i.e. ReadWriteItem declared, nothing above).
const _requiredTiers = <String>{'ReadItem', 'ReadWriteItem'};

const _prodHost = 'fa1.dev';
const _devHost = 'localhost:8443';

OutlookManifestReport validateOutlookManifest(String xml, {bool dev = false}) {
  final issues = <String>[];
  final host = dev ? _devHost : _prodHost;
  final otherHost = dev ? _prodHost : _devHost;
  final prefix = 'https://$host/outlook/';
  final otherPrefix = 'https://$otherHost/outlook/';

  // --- URLs: attributes (DefaultValue etc.) carry full resource URLs;
  // element text carries AppDomain origins (bare host, no path). ---
  final attrUrl = RegExp(r'([\w.:-]+)\s*=\s*"(https?://[^"]*)"');
  for (final m in attrUrl.allMatches(xml)) {
    if (m.group(1)!.startsWith('xmlns')) continue;
    _checkResourceUrl(m.group(2)!, issues, prefix, otherPrefix);
  }
  final textUrl = RegExp(r'<AppDomain>([^<]+)</AppDomain>');
  for (final m in textUrl.allMatches(xml)) {
    final url = m.group(1)!;
    if (url.startsWith('http://')) {
      issues.add('non-https URL: $url');
    } else if (url != 'https://$host') {
      issues.add('AppDomain must be the bare origin https://$host: $url');
    }
  }

  // --- Permissions: expand the declared tier through the ladder. ---
  final declared = RegExp(
    r'<Permissions>([^<]*)</Permissions>',
  ).allMatches(xml).map((m) => m.group(1)!.trim()).toSet();
  final derived = <String>{};
  var tierError = false;
  for (final p in declared) {
    final i = _ladder.indexOf(p);
    if (i < 0) {
      issues.add('unknown permission: $p');
      tierError = true;
    } else if (p == 'ReadWriteMailbox' || p == 'Restricted') {
      issues.add(
        'permission outside the allowed tiers (Restricted..ReadWriteItem): $p',
      );
      tierError = true;
    } else {
      derived.addAll(_ladder.sublist(1, i + 1));
    }
  }
  if (declared.isEmpty) {
    issues.add('no <Permissions> declared');
  } else if (!tierError && derived.length != _requiredTiers.length) {
    issues.add(
      'permission tiers must derive to exactly $_requiredTiers, got $derived',
    );
  }

  // --- Hosts: exactly one Mailbox. ---
  final hosts = RegExp(
    r'<Host\s+Name="([^"]+)"',
  ).allMatches(xml).map((m) => m.group(1)!).toList();
  if (hosts.isEmpty) {
    issues.add('no <Host> declared');
  } else if (hosts.length > 1) {
    issues.add(
      'exactly one <Host> allowed (Mailbox), found ${hosts.length}: $hosts',
    );
  } else if (hosts.single != 'Mailbox') {
    issues.add('host must be Mailbox, found ${hosts.single}');
  }

  // --- Mobile form factor is out of scope for v1. ---
  if (xml.contains('MobileFormFactor')) {
    issues.add('MobileFormFactor is not allowed in v1');
  }

  // --- Required presence. ---
  if (!RegExp(r'<SupportUrl\s').hasMatch(xml)) {
    issues.add('SupportUrl missing');
  }
  if (!textUrl.hasMatch(xml)) {
    issues.add('AppDomains must list at least one domain');
  }

  return OutlookManifestReport(issues);
}

void _checkResourceUrl(
  String url,
  List<String> issues,
  String prefix,
  String otherPrefix,
) {
  if (url.startsWith('http://')) {
    issues.add('non-https URL: $url');
  } else if (url.startsWith(otherPrefix)) {
    issues.add('mixed URL shape — expected $prefix, found: $url');
  } else if (!url.startsWith(prefix)) {
    issues.add('URL outside $prefix: $url');
  }
}
