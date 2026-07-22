// Generated file: Firebase configuration for the Fa example app.
// Do not edit by hand; regenerate with `flutterfire configure` if the project
// changes. This file contains API keys that are public in the compiled app,
// but keep the source out of public repositories.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        throw UnsupportedError(
          'Firebase is not configured for Windows in this project.',
        );
      case TargetPlatform.linux:
        throw UnsupportedError(
          'Firebase is not configured for Linux in this project.',
        );
      default:
        throw UnsupportedError(
          'Firebase is not supported on $defaultTargetPlatform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCa8_GCfP-SbygXCMLdEpJw2NH4pmFKUtA',
    appId: '1:604727820287:web:02d981f1fb809ed55f71ca',
    messagingSenderId: '604727820287',
    projectId: 'fa1-mobile',
    authDomain: 'fa1-mobile.firebaseapp.com',
    storageBucket: 'fa1-mobile.firebasestorage.app',
    measurementId: 'G-YC1TJPHHC1',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBrQ9KyoxbsDu3WVquvMWHYkdGD7JsAX_s',
    appId: '1:604727820287:android:56c9af84debcd85f5f71ca',
    messagingSenderId: '604727820287',
    projectId: 'fa1-mobile',
    storageBucket: 'fa1-mobile.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDBTbVEljGTJ39--oE1Zlw0EMtfAT55AJ4',
    appId: '1:604727820287:ios:25939680b109e6445f71ca',
    messagingSenderId: '604727820287',
    projectId: 'fa1-mobile',
    storageBucket: 'fa1-mobile.firebasestorage.app',
    iosBundleId: 'dev.fa1.ios',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyDBTbVEljGTJ39--oE1Zlw0EMtfAT55AJ4',
    appId: '1:604727820287:ios:2bdd25562700404d5f71ca',
    messagingSenderId: '604727820287',
    projectId: 'fa1-mobile',
    storageBucket: 'fa1-mobile.firebasestorage.app',
    iosBundleId: 'dev.fa1.macos',
  );
}
