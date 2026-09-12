// VM stand-ins for the web-only office_api_js.dart surface (see
// lib/fa_office_agent.dart): an OfficeApi factory that never produces a
// host and a JsOfficeApi type that exists only to keep VM analyze of
// web-conditional consumer files clean. Real definitions live in
// office_api_js.dart (dart:js_interop, web builds only).
library;

import 'office_api.dart';

/// Never the real adapter off the web: VM callers get no office host.
OfficeApi? createJsOfficeApi() => null;

/// VM-analyze stand-in for the web adapter class (never instantiated
/// here — web builds bind the js_interop class of the same name).
abstract final class JsOfficeApi implements OfficeApi {}
