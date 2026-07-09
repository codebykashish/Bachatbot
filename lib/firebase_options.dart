
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
///
/// Example:
/// ```dart
/// import 'firebase_options.dart';
/// // ...
/// await Firebase.initializeApp(
///   options: DefaultFirebaseOptions.currentPlatform,
/// );
/// ```
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
        return windows;
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBqvmStcdC84niv_TNwxRqeg36WwGZZMCQ',
    appId: '1:778584838320:android:f194d32be6ca82d3632b75',
    messagingSenderId: '778584838320',
    projectId: 'bachatbot2-64e23',
    storageBucket: 'bachatbot2-64e23.firebasestorage.app',
  );
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCOeSyiTn-zIAQ80qEsMYSel9S4HzyNuiM',
    appId: '1:778584838320:web:e91be64b42500162632b75',
    messagingSenderId: '778584838320',
    projectId: 'bachatbot2-64e23',
    authDomain: 'bachatbot2-64e23.firebaseapp.com',
    storageBucket: 'bachatbot2-64e23.firebasestorage.app',
    measurementId: 'G-M2M96DZ01C',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyCOeSyiTn-zIAQ80qEsMYSel9S4HzyNuiM',
    appId: '1:778584838320:web:ea3a001e1ede7de1632b75',
    messagingSenderId: '778584838320',
    projectId: 'bachatbot2-64e23',
    authDomain: 'bachatbot2-64e23.firebaseapp.com',
    storageBucket: 'bachatbot2-64e23.firebasestorage.app',
    measurementId: 'G-Q26S0G7N5P',
  );
  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyCejo1mPRqvQZU1dadNq4X5zhdo1PUUnU8',
    appId: '1:778584838320:ios:a63444fbfb849430632b75',
    messagingSenderId: '778584838320',
    projectId: 'bachatbot2-64e23',
    storageBucket: 'bachatbot2-64e23.firebasestorage.app',
    iosBundleId: 'com.example.bachatbot',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyCejo1mPRqvQZU1dadNq4X5zhdo1PUUnU8',
    appId: '1:778584838320:ios:a63444fbfb849430632b75',
    messagingSenderId: '778584838320',
    projectId: 'bachatbot2-64e23',
    storageBucket: 'bachatbot2-64e23.firebasestorage.app',
    iosBundleId: 'com.example.bachatbot',
  );
}
