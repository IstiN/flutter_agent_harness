import 'dart:io';

import 'package:test/test.dart';

/// Contract between the packaging script and the panel loader: the fa web
/// app bundle must live where `panel.js` actually resolves `app/index.html`
/// — relative to `panel/panel.html`, i.e. `browser_ext/panel/app/`. The
/// first cut bundled the app at the extension ROOT, the HEAD probe 404'd
/// and every build silently fell back to the basic panel.
void main() {
  final repoRoot = Directory.current.path;

  String read(String relative) =>
      File('$repoRoot/$relative').readAsStringSync();

  test('panel.js probes the panel-relative app bundle', () {
    final panel = read('browser_ext/panel/panel.js');
    expect(panel, contains("fetch('app/index.html'"));
    // The redirect (via the injectable __faRedirect seam) targets the
    // same panel-relative path.
    expect(panel, contains("'app/index.html')"));
  });

  test('the packaging script bundles the app where the panel probes it', () {
    final script = read('scripts/build_browser_ext.sh');
    expect(script, contains('--base-href=/panel/app/'),
        reason:
            'absolute asset URLs must resolve under chrome-extension://<id>'
            '/panel/app/');
    expect(script, contains('browser_ext/panel/app'),
        reason: 'the bundle target the panel can actually see');
    // A root-level copy would be dead weight the panel never loads.
    expect(script, isNot(contains('cp -R flutter_app/build/web/. browser_ext/app/')));
    // The zip needs no separate root entry: panel/app rides in panel/.
    expect(script, isNot(contains(r'runtime="$runtime app"')));
  });
}
