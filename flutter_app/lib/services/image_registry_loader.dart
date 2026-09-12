/// Resolves the `images:` section for the app (session image registry,
/// issue #171): `~/.fah/config.yaml` `registry` kill switch and
/// `maxPerRequest` cap. IO platforms read the real config; the stub
/// (web) returns null (registry stays on with core defaults).
library;

export 'image_registry_loader_stub.dart'
    if (dart.library.io) 'image_registry_loader_io.dart';
