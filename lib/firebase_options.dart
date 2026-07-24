
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
    apiKey: 'AIzaSyAUB7K0EloJgMkbuoJNL1Feluskb14Mjxs',
    appId: '1:269626615168:android:41daaaf024a6e39c104d65',
    messagingSenderId: '269626615168',
    projectId: 'bachatbot3',
    storageBucket: 'bachatbot3.firebasestorage.app',
  );
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBSfb8SEqwxgnQwGWTo9uLbX32eVBfoNao',
    appId: '1:269626615168:web:7360f1492ae9380e104d65',
    messagingSenderId: '269626615168',
    projectId: 'bachatbot3',
    authDomain: 'bachatbot3.firebaseapp.com',
    storageBucket: 'bachatbot3.firebasestorage.app',
    measurementId: 'G-PMC64E0DCT',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyBSfb8SEqwxgnQwGWTo9uLbX32eVBfoNao',
    appId: '1:269626615168:web:48ffe4946a3d17aa104d65',
    messagingSenderId: '269626615168',
    projectId: 'bachatbot3',
    authDomain: 'bachatbot3.firebaseapp.com',
    storageBucket: 'bachatbot3.firebasestorage.app',
    measurementId: 'G-JS6BBLYJ7F',
  );
  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyD2v4wM_NNr6MAqHPB67zabTjrgpC00CsI',
    appId: '1:269626615168:ios:d1fda03495c6b6b4104d65',
    messagingSenderId: '269626615168',
    projectId: 'bachatbot3',
    storageBucket: 'bachatbot3.firebasestorage.app',
    iosBundleId: 'com.example.bachatbot',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyD2v4wM_NNr6MAqHPB67zabTjrgpC00CsI',
    appId: '1:269626615168:ios:d1fda03495c6b6b4104d65',
    messagingSenderId: '269626615168',
    projectId: 'bachatbot3',
    storageBucket: 'bachatbot3.firebasestorage.app',
    iosBundleId: 'com.example.bachatbot',
  );
}
