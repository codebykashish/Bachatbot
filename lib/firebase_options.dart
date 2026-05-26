
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
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for ios - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.macOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for macos - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
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
    apiKey: 'AIzaSyCUxtV2BUlHDWp70Xm3tEDW4i8YsAnGHDo',
    appId: '1:660413510452:android:6f705b39321b260d386b61',
    messagingSenderId: '660413510452',
    projectId: 'bachatbot-innovation',
    storageBucket: 'bachatbot-innovation.firebasestorage.app',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyA020nbTlhoeckygTY9_cVs3Ac_MtpLvjE',
    appId: '1:660413510452:web:66ec2b9d086e0ac4386b61',
    messagingSenderId: '660413510452',
    projectId: 'bachatbot-innovation',
    authDomain: 'bachatbot-innovation.firebaseapp.com',
    storageBucket: 'bachatbot-innovation.firebasestorage.app',
    measurementId: 'G-XSP4H9ZPV4',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyA020nbTlhoeckygTY9_cVs3Ac_MtpLvjE',
    appId: '1:660413510452:web:c239ed897564a575386b61',
    messagingSenderId: '660413510452',
    projectId: 'bachatbot-innovation',
    authDomain: 'bachatbot-innovation.firebaseapp.com',
    storageBucket: 'bachatbot-innovation.firebasestorage.app',
    measurementId: 'G-B11SME3LMS',
  );

}