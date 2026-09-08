/// The dart:io binding for the DAP/1 hub: an HTTP/WebSocket server
/// ([DapHubServer]) and atomic file persistence ([AtomicFileStore]).
/// This is the only `dart:io` entry point of the package.
library;

export 'src/io/atomic_file_store.dart';
export 'src/io/server.dart';
