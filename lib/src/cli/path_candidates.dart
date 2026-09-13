// Workspace file candidates for the composer's fuzzy path completion
// (issue #275). Conditional export: the real walker needs dart:io; the
// web build compiles against the no-op stub.
export 'path_candidates_stub.dart'
    if (dart.library.io) 'path_candidates_io.dart';
