// Public surface of the fa_office_agent package (issue #182): the
// Office.js bridge the fa Flutter app embeds when it runs as the Outlook
// taskpane. The pane IS the app now — the dart2js bootstrap agent of #94
// is gone; what remains is the typed [OfficeApi] facade, its js_interop
// adapter, the outlook.* tool family, the quarantine fence, the manifest
// validator and the fake the tests drive.
//
// office_api_js.dart is exported for web builds only: it is the one file
// that imports dart:js_interop. VM consumers (the package's own tests,
// flutter_app's VM tests) see the pure-Dart surface only.
library;

export 'src/email_quarantine.dart';
export 'src/fake_office.dart';
export 'src/manifest.dart';
export 'src/office_api.dart';
export 'src/_web_empty.dart' if (dart.library.html) 'src/office_api_js.dart';
export 'src/outlook_tools.dart';
