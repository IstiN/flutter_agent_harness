import 'package:fa/services/asr_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Live-device probe for the mic channel: records a real 2-second take on
/// the simulator/device through the same fah/mic MethodChannel the JS
/// bridge uses, so a broken tap in voice-notes can be attributed to the
/// channel vs the JS app layer.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mic channel records a real take', (tester) async {
    final api = createAsrService();
    final available = await api.isAvailable;
    // On unsupported platforms the probe passes vacuously.
    if (!available) return;

    final granted = await api.requestAccess();
    expect(granted, isTrue, reason: 'mic permission must be granted');

    await api.startRecording();
    await Future<void>.delayed(const Duration(seconds: 2));
    final rec = await api.stopRecording();

    expect(rec.path, isNotEmpty);
    expect(rec.durationMs, greaterThan(500));
    final bytes = await api.readRecording(rec.path);
    expect(bytes.length, greaterThan(1000));
  });
}
