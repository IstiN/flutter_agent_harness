// Generated file: placeholder values. Replace by running:
//   flutterfire configure --project=<your-firebase-project>
// after creating a Firebase project and registering apps with bundle IDs:
//   iOS: dev.fa1.ios, Android: dev.fa1.app (was dev.fa1.android before
//   issue #289 — Firebase console registration must match), macOS:
//   dev.fa1.macos, Web: fa1.dev
//
// The real firebase_options.dart produced by FlutterFire contains private API
// keys; treat it like a secret and do not commit the real version to a public
// repository.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    final options = optionsFor(defaultTargetPlatform);
    if (options != null) return options;
    throw UnsupportedError(_unsupportedMessage(defaultTargetPlatform));
  }

  /// The configured options for a native platform, or null when the project
  /// has no Firebase registration for it.
  static FirebaseOptions? optionsFor(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      default:
        return null;
    }
  }

  /// The per-platform explanation for a missing Firebase registration.
  static String _unsupportedMessage(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.windows:
        return 'Firebase is not configured for Windows in this project.';
      case TargetPlatform.linux:
        return 'Firebase is not configured for Linux in this project.';
      default:
        return 'Firebase is not supported on $platform.';
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'YOUR_WEB_API_KEY',
    appId: 'YOUR_WEB_APP_ID',
    messagingSenderId: 'YOUR_SENDER_ID',
    projectId: 'YOUR_PROJECT_ID',
    authDomain: 'YOUR_PROJECT_ID.firebaseapp.com',
    storageBucket: 'YOUR_PROJECT_ID.appspot.com',
    measurementId: 'G-0Z3SW38FYC',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'YOUR_ANDROID_API_KEY',
    appId: 'YOUR_ANDROID_APP_ID',
    messagingSenderId: 'YOUR_SENDER_ID',
    projectId: 'YOUR_PROJECT_ID',
    storageBucket: 'YOUR_PROJECT_ID.appspot.com',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'YOUR_IOS_API_KEY',
    appId: 'YOUR_IOS_APP_ID',
    messagingSenderId: 'YOUR_SENDER_ID',
    projectId: 'YOUR_PROJECT_ID',
    storageBucket: 'YOUR_PROJECT_ID.appspot.com',
    iosBundleId: 'dev.fa1.ios',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'YOUR_MACOS_API_KEY',
    appId: 'YOUR_MACOS_APP_ID',
    messagingSenderId: 'YOUR_SENDER_ID',
    projectId: 'YOUR_PROJECT_ID',
    storageBucket: 'YOUR_PROJECT_ID.appspot.com',
    iosBundleId: 'dev.fa1.macos',
  );
}
