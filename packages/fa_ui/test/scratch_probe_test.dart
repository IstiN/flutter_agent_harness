import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'fake_chat_service.dart';

class _ProbeService extends FakeChatService {
  bool streaming = false;
  List<FaChatMessage> msgs = const [];

  @override
  bool get isStreaming => streaming;
  @override
  List<FaChatMessage> get messages => msgs;

  void append(int count) {
    final base = msgs.length;
    msgs = [
      ...msgs,
      for (var i = 0; i < count; i++)
        FaChatMessage(
          role: (base + i).isEven ? 'user' : 'assistant',
          content: 'm${base + i}',
        ),
    ];
    notifyListeners();
  }

  void prepend(int count) {
    final old = msgs;
    msgs = [
      for (var i = 0; i < count; i++)
        FaChatMessage(role: i.isEven ? 'user' : 'assistant', content: 'old$i'),
      ...old,
    ];
    notifyListeners();
  }
}

List<FaChatMessage> _msgs(int n) => [
  for (var i = 0; i < n; i++)
    FaChatMessage(role: i.isEven ? 'user' : 'assistant', content: 'm$i'),
];

Future<void> _pump(WidgetTester tester, _ProbeService service) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: FaChatScreen(service: service)));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('probe: trace the flush', (tester) async {
    final service = _ProbeService()
      ..msgs = _msgs(30)
      ..streaming = true;
    await _pump(tester, service);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    service.append(3);
    await tester.pump(const Duration(milliseconds: 100));
    debugPrint('PROBE after append: pill='
        '${find.byKey(const ValueKey('faChatJumpToLivePill')).evaluate().length}');

    debugPrint('PROBE ---- prepend now ----');
    service.prepend(25);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    debugPrint('PROBE end: pill='
        '${find.byKey(const ValueKey('faChatJumpToLivePill')).evaluate().length}');
  });
}
