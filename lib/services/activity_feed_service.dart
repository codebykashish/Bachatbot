import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Phase 13.2b — the persistent, app-lifetime backing service for
/// ActivityFeedScreen, mirroring AlertPopupService/MonthEventService's
/// own singleton pattern. Watches both users/{uid}/alerts (the legacy
/// system — already logs every transaction, plus budget alerts and
/// pending-transaction confirmations) and users/{uid}/generatedNotifications
/// (the Notification Engine) in real time, so the bell badge stays
/// accurate even when ActivityFeedScreen itself is never opened —
/// a widget-scoped listener (tied to initState/dispose) would only
/// update the badge while the screen was on-screen, which is exactly
/// the bug this singleton exists to avoid.
///
/// Read-only: this service never writes to either collection. Mutating
/// an item still goes through each system's own existing write path
/// (PATCH /alerts/{id}/read, POST /notifications/{id}/read|dismiss).
class ActivityFeedService {
  static final ActivityFeedService _instance = ActivityFeedService._internal();

  factory ActivityFeedService() => _instance;

  ActivityFeedService._internal();

  static final ValueNotifier<List<Map<String, dynamic>>> alerts =
      ValueNotifier([]);
  static final ValueNotifier<List<Map<String, dynamic>>> notifications =
      ValueNotifier([]);
  static final ValueNotifier<int> unreadCount = ValueNotifier(0);

  StreamSubscription<QuerySnapshot>? _alertsSub;
  StreamSubscription<QuerySnapshot>? _notificationsSub;
  bool _initialized = false;

  void init(String uid) {
    if (_initialized) return;
    _initialized = true;

    _alertsSub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('alerts')
        .orderBy('createdAt', descending: true)
        .limit(200)
        .snapshots()
        .listen((snapshot) {
      alerts.value = snapshot.docs.map((d) {
        final data = Map<String, dynamic>.from(d.data());
        data['id'] = d.id;
        data['_source'] = 'alert';
        return data;
      }).toList();
      _recomputeUnread();
    });

    _notificationsSub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('generatedNotifications')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((snapshot) {
      notifications.value = snapshot.docs.map((d) {
        final data = Map<String, dynamic>.from(d.data());
        data['_source'] = 'notification';
        return data;
      }).toList();
      _recomputeUnread();
    });
  }

  void _recomputeUnread() {
    final unreadAlerts = alerts.value.where((a) => a['isRead'] != true).length;
    final unreadNotifications = notifications.value
        .where((n) => n['status'] == 'Created' || n['status'] == 'Delivered')
        .length;
    unreadCount.value = unreadAlerts + unreadNotifications;
  }

  void dispose() {
    _alertsSub?.cancel();
    _notificationsSub?.cancel();
    _alertsSub = null;
    _notificationsSub = null;
    _initialized = false;
    alerts.value = [];
    notifications.value = [];
    unreadCount.value = 0;
  }
}
