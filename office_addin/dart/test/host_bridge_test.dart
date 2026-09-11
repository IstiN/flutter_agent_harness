// host_bridge.dart: AC7 dispatch seam — Outlook is live (null note),
// every other host answers the clean not-implemented note, never a
// crash. Issue #89.
import 'package:test/test.dart';

import '../src/host_bridge.dart';
import '../src/office_api.dart';

void main() {
  test('outlook has a live adapter: no note', () {
    expect(hostBridgeNote(OfficeHostId.outlook), isNull);
  });

  test('every non-outlook host answers the clean note (UT-hosts)', () {
    for (final host in OfficeHostId.values) {
      if (host == OfficeHostId.outlook) continue;
      expect(
        hostBridgeNote(host),
        'host adapter not implemented yet — Outlook is the v1 adapter; '
        'Word/Excel/PowerPoint arrive as adapters over this same bridge',
        reason: '$host must answer the clean not-implemented note',
      );
    }
  });
}
