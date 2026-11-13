// The release entry point: built (not renamed) as `fa` so the bundle is
// self-consistent on every SDK. `dart build cli` derives the bundle exe
// name from this file name, and on Dart >=3.14 (native linux) also the
// companion snapshot dylib name (`libdartaot<exe>.so`) that the thin
// launcher locates from its own runtime name — the post-build `mv
// bin/fah -> bin/fa` in packaging broke that pairing (gh-2120 follow-up:
// `dartaotruntime: not an AOT snapshot`, exit 255 on v1.0.709).
// Keep this file a pure delegator: all logic lives in fah.dart / lib/.
import 'fah.dart' as app;

Future<void> main(List<String> args) => app.main(args);
