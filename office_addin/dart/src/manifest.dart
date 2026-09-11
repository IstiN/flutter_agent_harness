// Outlook add-in manifest validator (issue #89, AC1).
//
// Pure-Dart check over the MailApp XML: every resource URL is https
// under the expected host (fa1.dev, or localhost:8443 in --dev builds)
// with path prefix /outlook/, the permission ladder lands exactly on
// ReadWriteItem (⇒ derived tiers {ReadItem, ReadWriteItem}), exactly
// one Mailbox host, no mobile form factor, XML comments free of "--"
// (illegal; strict hosts reject the whole document, #131), and a
// VersionOverrides command surface that Monarch/new OWA need (#143):
// MessageReadCommandSurface + ShowTaskpane, 16/32/80 px button icons,
// MailHost type, resids that resolve. Regex-shaped on purpose: this is
// a lint pass, not a schema parser.
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

  // --- XML comments: "--" inside a comment is illegal (XML 1.0 §2.5);
  // strict hosts (Outlook upload validation) then reject the whole
  // document as malformed ("Add-in installation failed", issue #131). ---
  var cursor = 0;
  while (true) {
    final open = xml.indexOf('<!--', cursor);
    if (open < 0) break;
    final close = xml.indexOf('-->', open + 4);
    if (close < 0) {
      issues.add('unterminated XML comment');
      break;
    }
    if (xml.substring(open + 4, close).contains('--')) {
      issues.add(
        'XML comment contains "--"; Outlook rejects the document as malformed',
      );
    }
    cursor = close + 3;
  }

  // --- Compose (ItemEdit) forms: DesktopSettings allows only
  // SourceLocation; RequestedHeight there fails the Office schema
  // validation Outlook runs on upload (issue #131). ---
  for (final m in RegExp(
    r'<Form\s+xsi:type="ItemEdit">([\s\S]*?)</Form>',
  ).allMatches(xml)) {
    if (m.group(1)!.contains('RequestedHeight')) {
      issues.add('RequestedHeight is not allowed in ItemEdit (compose) forms');
    }
  }

  // --- Required presence. ---
  if (!RegExp(r'<SupportUrl\s').hasMatch(xml)) {
    issues.add('SupportUrl missing');
  }
  if (!textUrl.hasMatch(xml)) {
    issues.add('AppDomains must list at least one domain');
  }

  // --- Command surface (issue #143): new Outlook for Windows (Monarch)
  // and modern OWA render command-based add-ins only; without
  // MessageReadCommandSurface the add-in installs but never shows. ---
  final voStart = xml.indexOf('<VersionOverrides');
  final vo = voStart < 0 ? '' : xml.substring(voStart);
  if (vo.isEmpty) {
    issues.add(
      'no VersionOverrides: new Outlook (Monarch) and modern OWA render '
      'command-based add-ins only (issue #143)',
    );
  } else {
    if (!vo.contains('xsi:type="MessageReadCommandSurface"')) {
      issues.add('VersionOverrides must declare MessageReadCommandSurface');
    }
    if (!vo.contains('xsi:type="ShowTaskpane"')) {
      issues.add('VersionOverrides must contain a ShowTaskpane action');
    }
    if (vo.contains('<Host xsi:type="Mailbox"')) {
      issues.add('VersionOverrides Host must be xsi:type="MailHost"');
    }

    // Button icons: the command schema requires 16, 32 and 80 px resources.
    for (final m in RegExp(
      r'<Icon>(.*?)</Icon>',
      dotAll: true,
    ).allMatches(vo)) {
      final sizes = RegExp(r'size="(\d+)"')
          .allMatches(m.group(1)!)
          .map((s) => s.group(1)!)
          .toSet();
      for (final need in const ['16', '32', '80']) {
        if (!sizes.contains(need)) {
          issues.add('command Icon must declare a $need px bt:Image');
        }
      }
    }

    // Every resid reference must resolve to a declared resource id, else
    // the host drops the control silently.
    final declared = RegExp(r'<bt:(?:Image|Url|String)\s+id="([^"]+)"')
        .allMatches(vo)
        .map((m) => m.group(1)!)
        .toSet();
    for (final m in RegExp(r'\bresid="([^"]+)"').allMatches(vo)) {
      final id = m.group(1)!;
      if (!declared.contains(id)) {
        issues.add('unresolved resid reference: $id');
      }
    }
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
