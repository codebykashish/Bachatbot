import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../api_service.dart';
import '../main.dart';
import '../screens/activity_feed_screen.dart';

/// Must be a top-level (or static) function, and re-registered on every
/// app start (spec Phase 5.8's own note: this fires in a separate
/// background isolate with no access to any state built up in main()).
/// It does no work of its own — the OS already shows the notification
/// for a data+notification payload; this only exists to satisfy the
/// plugin's requirement that a background handler be registered.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

/// Wires this device into the backend's Delivery layer (spec Phase 5.8)
/// and displays incoming pushes while the app is in the foreground.
///
/// Registration is best-effort and silent on failure — a user who denies
/// notification permission, or whose token registration call fails, still
/// gets the in-app Activity Feed (ActivityFeedService's own Firestore
/// listener) unaffected; push is one delivery channel, never the only
/// way a notification reaches the user.
class PushNotificationService {
  static final PushNotificationService _instance =
      PushNotificationService._internal();

  factory PushNotificationService() => _instance;

  PushNotificationService._internal();

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  int _notifId = 5000;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await _localNotifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/launcher_icon'),
      ),
      onDidReceiveNotificationResponse: (_) => _openNotificationCenter(),
    );

    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      return;
    }

    await _registerToken(await messaging.getToken());
    messaging.onTokenRefresh.listen(_registerToken);

    FirebaseMessaging.onMessage.listen(_showForegroundNotification);
    FirebaseMessaging.onMessageOpenedApp.listen((_) => _openNotificationCenter());

    // App was opened by tapping a push while fully terminated.
    final initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) _openNotificationCenter();
  }

  Future<void> _registerToken(String? token) async {
    if (token == null) return;
    try {
      await ApiService.post('/notifications/device-token', {'fcmToken': token});
    } catch (e) {
      // Silent — see class doc. The token registers again on the next
      // app start or the next onTokenRefresh firing.
    }
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final title = message.notification?.title ?? message.data['title'];
    final body = message.notification?.body ?? message.data['body'];
    if (title == null && body == null) return;

    await _localNotifications.show(
      _notifId++,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'generated_notifications',
          'Notifications',
          channelDescription: 'BachatBot notifications',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }

  void _openNotificationCenter() {
    rootNavigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => const ActivityFeedScreen()),
    );
  }
}
