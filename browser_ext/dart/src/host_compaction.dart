// Compatibility shim: the compaction parity module moved under lib/src so
// the barrel (and the flutter_app parity test) can import it through the
// package's public library (gh-2059, same pattern as ui_protocol.dart).
export '../lib/src/host_compaction.dart';
