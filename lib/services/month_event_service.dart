import 'dart:async';
import 'package:flutter/material.dart';
import '../api_service.dart';

/// Types of month-boundary events emitted by the backend.
enum MonthEventType { preNewMonth, newMonthStarted }

/// A single month-boundary event payload.
class MonthEvent {
  final MonthEventType type;

  /// For [MonthEventType.newMonthStarted], the backend may return the
  /// auto-set budgets for the new month so the UI can display them.
  final List<Map<String, dynamic>> budgets;

  const MonthEvent({required this.type, this.budgets = const []});
}

/// Lightweight polling service that checks the backend for month-boundary
/// events (pre-new-month reminder and new-month-started).
///
/// Call [init] once (in MainScreen.initState).
/// Listen to [eventNotifier] to react to events in any widget.
class MonthEventService {
  static final MonthEventService _instance = MonthEventService._internal();
  factory MonthEventService() => _instance;
  MonthEventService._internal();

  /// Publicly observable current event. Null when no active event.
  static final ValueNotifier<MonthEvent?> eventNotifier =
      ValueNotifier<MonthEvent?>(null);

  /// Fired when a new chat message should be injected into Firestore
  /// (consumed by ChatScreen's Firestore listener automatically).
  static final ValueNotifier<MonthEvent?> chatMessageNotifier =
      ValueNotifier<MonthEvent?>(null);

  bool _initialized = false;
  Timer? _pollTimer;

  // How often to poll the backend for month events (30 minutes in production,
  // but the first check happens immediately on init).
  static const _pollInterval = Duration(minutes: 30);

  /// Start polling. Safe to call multiple times — only initialises once.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // First check immediately, then on a timer.
    await _check();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _check());
  }

  void dispose() {
    _pollTimer?.cancel();
    _initialized = false;
  }

  Future<void> _check() async {
    try {
      final res = await ApiService.get('/events/month');
      if (res['success'] != true) return;

      final data = res['data'];
      if (data == null) return;

      final typeRaw = data['type'] as String?;
      if (typeRaw == null) return;

      final budgets = (data['budgets'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [];

      MonthEventType? type;
      if (typeRaw == 'pre_new_month') {
        type = MonthEventType.preNewMonth;
      } else if (typeRaw == 'new_month_started') {
        type = MonthEventType.newMonthStarted;
      }

      if (type == null) return;

      final event = MonthEvent(type: type, budgets: budgets);

      // Notify banner listeners (MainScreen).
      eventNotifier.value = event;

      // Notify chat message listeners (ChatScreen will write to Firestore).
      chatMessageNotifier.value = event;

      debugPrint('[MonthEventService] Event received: $typeRaw');
    } catch (e) {
      // Backend may not have implemented this endpoint yet — fail silently.
      debugPrint('[MonthEventService] poll failed (ok if endpoint missing): $e');
    }
  }
}
