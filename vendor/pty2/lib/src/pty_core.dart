// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'dart:typed_data';

abstract interface class PtyCore {
  Uint8List? read();

  int? exitCodeNonBlocking();

  int exitCodeBlocking();

  /// The spawned child's OS pid. Exposed by the vendored fork (upstream
  /// keeps this commented out) so embedders can SIGKILL-escalate a child
  /// that ignored the cooperative `kill()` — the gh-2208 CI wedge class:
  /// pty2's blocking `waitpid` isolate cannot die while the child lives,
  /// and it wedges the Dart VM's exit handshake ("Attempt:N waiting for
  /// isolate _waitForExitCode to check in").
  int get pid;

  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);

  void resize(int width, int height);

  // int get pid;

  void write(List<int> data);

  PtyCoreWorker get worker;
}

abstract interface class PtyCoreWorker {
  Uint8List? read();
  int exitCodeBlocking();
  void free();
}
