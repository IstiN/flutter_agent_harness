// ponytail: hand-rolled fetch http.Client — MV3 service workers have fetch
// but no XHR, so package:http's default BrowserClient cannot work here.
// Drop this file when package:http ships a fetch-based client.
//
// Conditional import: the pure registry logic in providers.dart must stay
// VM-testable, so the js_interop implementation only loads on the web.
export 'fetch_client_stub.dart'
    if (dart.library.js_interop) 'fetch_client_web.dart';
