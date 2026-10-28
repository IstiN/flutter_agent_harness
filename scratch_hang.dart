import 'dart:io';
import 'package:flutter_agent_harness/io.dart';

Future<void> main(List<String> args) async {
  if (args.first == 'sync-wedge') {
    // The WIP gate's mechanism: Process.runSync — no timeout exists.
    final r = Process.runSync(
      'security',
      ['add-generic-password', '-s', 's', '-a', 'a', '-w', 'p', '-U'],
    );
    print('runSync returned rc=${r.exitCode}');
  } else {
    // The new gate's mechanism: the bounded runner.
    secureKeyProcessTimeout = const Duration(seconds: 2);
    final sw = Stopwatch()..start();
    final dk = await secureKeyProcessRunner('security', ['default-keychain']);
    final add = await secureKeyProcessRunner('security', [
      'add-generic-password',
      '-s',
      's',
      '-a',
      'a',
      '-w',
      'p',
      '-U',
    ]);
    print(
      'bounded runner: dk=${dk.exitCode} add=${add.exitCode} '
      'timedOut=${add.timedOut} after ${sw.elapsed.inSeconds}s',
    );
  }
}
