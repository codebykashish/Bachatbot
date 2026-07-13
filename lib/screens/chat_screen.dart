import 'package:flutter/material.dart';
import 'dart:convert';
import '../api_service.dart';
import '../models/pending_transaction.dart';
import '../services/month_event_service.dart';
import '../widgets/rebalance_confirm_dialog.dart';
import 'notification_screen.dart';

/// Callback signature for chat intent-based refresh.
/// [refreshHome] and [refreshCategories] are flags indicating what to refresh.
typedef ChatRefreshCallback = void Function({
  bool refreshHome,
  bool refreshCategories,
});

// ─── Pending card display state ────────────────────────────────────────────

enum _PendingCardState { pending, confirmed, cancelled, editing }

enum MessageStatus { pending, sent }

/// Internal card model held in memory while chat is open.
class _PendingCard {
  final String localId; // UUID for widget key
  final List<PendingTransaction> items;
  _PendingCardState state = _PendingCardState.pending;
  bool isLoading = false;

  _PendingCard({
    required this.localId,
    required this.items,
  });
}

// ─── Available expense categories ─────────────────────────────────────────

const List<String> _kCategories = [
  'Food',
  'Transport',
  'Rent',
  'Education',
  'Shopping',
  'Health',
  'Entertainment',
  'Bills',
  'Others',
];

// ──────────────────────────────────────────────────────────────────────────

class ChatScreen extends StatefulWidget {
  final ChatRefreshCallback? onRefreshNeeded;

  const ChatScreen({super.key, this.onRefreshNeeded});

  /// Set to true when the user successfully sends a message this session.
  /// ChatBotPage reads this to decide whether to pop(true) for refresh.
  static bool messageSent = false;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<Map<String, dynamic>> _messages = [];
  bool _isLoading = false;
  bool _isHistoryLoaded = false;
  bool _isFirstMessage = true;

  // ── Pending confirmation cards (transient in-memory state) ───────────────
  // Keyed by the assistant message ID they follow.
  final Map<String, _PendingCard> _pendingCards = {};

  // ── Budget prompt cards: assistantId → category name ────────────────────
  final Map<String, String> _budgetPromptCategories = {};

  // ── Month event listener ─────────────────────────────────────────────────
  late final VoidCallback _monthEventListener;

  static const Color _primary = Color(0xFF2DBE7F);
  static const Color _pageBg = Color(0xFFF6F7F9);

  // Intents that require refreshing Home and/or Categories
  static const _refreshHomeIntents = {
    'expense_log',
    'income_log',
    'undo_last_expense',
  };

  static const _refreshCategoriesIntents = {
    'expense_log',
    'income_log',
    'set_budget',
    'undo_last_expense',
  };

  @override
  void initState() {
    super.initState();
    ChatScreen.messageSent = false; // reset each time chat opens
    _loadHistory();

    // ── Listen for month events and inject as chat messages ─────────────────
    _monthEventListener = () {
      final event = MonthEventService.chatMessageNotifier.value;
      if (event != null) _injectMonthEventMessage(event);
    };
    MonthEventService.chatMessageNotifier.addListener(_monthEventListener);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    MonthEventService.chatMessageNotifier.removeListener(_monthEventListener);
    super.dispose();
  }

  // ── Month event chat injection ───────────────────────────────────────────

  void _injectMonthEventMessage(MonthEvent event) {
    final String content;
    final String intent;

    if (event.type == MonthEventType.preNewMonth) {
      content =
          'Naya mahina aaudaichha.\n\nPaila ko mahina ma jati kharcha garnu bhayo, tesko base ma agami mahina ko budget set garnu hola.\n\nBudget set gari sakepachi ma timro kharcha haru thik budget ra category ma base ra track gardinchu.';
      intent = 'pre_new_month_reminder';
    } else {
      content =
          'Naya mahina suru bhayo! 🎉\n\nPaila ko mahina ma jati kharcha garnu bhayo, tesai lai yo mahina ko starting budget banako chhu.\n\nYedi timi lai yo budget change garnu chha bhane, budget section ma gaera edit gara, ya "budget change gara" bhani lekha.';
      intent = 'new_month_started';
    }

    // In-memory dedup: skip if already shown this session.
    if (_messages.any((m) => m['intent'] == intent)) return;

    if (!mounted) return;
    setState(() {
      _messages.add({
        'role': 'assistant',
        'content': content,
        'intent': intent,
        'status': MessageStatus.sent,
        'id': 'month_$intent',
        'isMonthEvent': true,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      });
    });
    _scrollToBottom();
  }

  // ── History loading ──────────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    try {
      final response = await ApiService.get('/messages?limit=50');
      if (!mounted) return;

      final data = response['data'] as Map<String, dynamic>?;
      final msgs = data?['messages'] as List? ?? [];

      final loaded = <Map<String, dynamic>>[];
      for (int i = 0; i < msgs.length; i++) {
        final msg = msgs[i];
        final rawRole = (msg['role'] as String?) ?? 'user';
        final role = rawRole == 'model' ? 'assistant' : rawRole;

        final parts = msg['parts'] as List?;
        final content = parts != null && parts.isNotEmpty
            ? (parts.first['text'] as String? ?? '')
            : (msg['content'] as String? ?? '');

        if (content.isEmpty) continue;

        final intent = (msg['intent'] as String?) ?? 'general_chat';
        String? createdAt;
        final rawTs = msg['createdAt'];
        if (rawTs is String) {
          createdAt = rawTs;
        } else if (rawTs is Map) {
          final secs = rawTs['_seconds'] as int?;
          if (secs != null) {
            createdAt = DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true).toIso8601String();
          }
        }
        loaded.add({
          'role': role,
          'content': content,
          'intent': intent,
          'status': MessageStatus.sent,
          'id': (msg['id'] as String?) ?? 'hist_$i',
          'isMonthEvent':
              intent == 'new_month_started' || intent == 'pre_new_month_reminder',
          if (createdAt != null) 'createdAt': createdAt,
        });
      }

      final pendingAction = data?['pendingAction'] as Map<String, dynamic>?;

      setState(() {
        _messages
          ..clear()
          ..addAll(loaded);
        _isFirstMessage = loaded.isEmpty;
      });

      if (pendingAction != null && msgs.isNotEmpty) {
        _restorePendingAction(pendingAction, msgs);
      }

      _scrollToBottom();
    } catch (e) {
      debugPrint('[ChatScreen] History load failed: $e');
    } finally {
      if (mounted) setState(() => _isHistoryLoaded = true);
    }
  }

  /// Restores a pending confirmation card from the backend's pendingAction.
  /// Called on chat screen open so confirmation UI survives app restarts.
  void _restorePendingAction(
    Map<String, dynamic> pendingAction,
    List msgs,
  ) {
    try {
      final pendingTxIds =
          (pendingAction['pendingTxIds'] as List?)?.cast<String>() ?? [];
      if (pendingTxIds.isEmpty) return;

      // actions[] is saved alongside pendingTxIds[] in the same order —
      // each holds the real amount/category/type for the matching id.
      final actions = (pendingAction['actions'] as List?) ?? [];
      final source = (pendingAction['source'] as String?) ?? 'chat';

      final lastAssistantId = msgs.isNotEmpty
          ? (msgs.last['id'] as String? ?? 'restored_pending')
          : 'restored_pending';

      if (_pendingCards.containsKey(lastAssistantId)) return;

      final items = <PendingTransaction>[];
      for (var i = 0; i < pendingTxIds.length; i++) {
        final action = i < actions.length ? actions[i] as Map<String, dynamic>? : null;
        final amount = (action?['amount'] as num?)?.toDouble() ?? 0;
        final category = action?['category'] as String?;
        items.add(PendingTransaction(
          id: pendingTxIds[i],
          amount: amount,
          label: category ?? 'Pending transaction',
          source: source,
          selectedCategory: category,
        ));
      }

      if (items.isEmpty) return;

      setState(() {
        _pendingCards[lastAssistantId] = _PendingCard(
          localId: lastAssistantId,
          items: items,
        );
      });
      debugPrint('[ChatScreen] Restored ${items.length} pending action(s) from history.');
    } catch (e) {
      debugPrint('[ChatScreen] _restorePendingAction failed: $e');
    }
  }

  // ── Send ─────────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isLoading) return;

    _controller.clear();

    final tempId = 'temp_${DateTime.now().millisecondsSinceEpoch}';

    // 1. Optimistic user message
    setState(() {
      _messages.add({
        'role': 'user',
        'content': text,
        'intent': 'general_chat',
        'status': MessageStatus.pending,
        'id': tempId,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      });
      _isLoading = true;
    });
    _scrollToBottom();

    try {
      debugPrint('Sending chat: "$text"');
      final res = await ApiService.postRaw('/messages', {
        'text': text,
        'isFirstMessage': _isFirstMessage,
        'source': 'chat',
      });

      debugPrint('POST /messages -> ${res.statusCode} ${res.body}');

      if (!mounted) return;

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        final data = decoded['data'];
        final reply =
            data?['reply'] ?? data?['text'] ?? 'Sorry, I could not understand that.';
        final intent = (data?['intent'] as String?) ?? 'general_chat';
        final alerts = data?['alerts'] as List?;
        // needsConfirmation: backend stores this state; user types "ho"/"yes"
        // or "hudaina"/"no" to resolve. Never block the UI with a spinner.
        final needsConfirmation = data?['needsConfirmation'] == true;

        final assistantId = 'bot_${DateTime.now().millisecondsSinceEpoch}';

        // 2. Mark user message sent, add bot reply — always clear _isLoading.
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == tempId);
          if (idx != -1) {
            _messages[idx] = {..._messages[idx], 'status': MessageStatus.sent};
          }
          _messages.add({
            'role': 'assistant',
            'content': reply,
            'intent': intent,
            'needsConfirmation': needsConfirmation,
            'id': assistantId,
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          });
          _isLoading = false;
          _isFirstMessage = false;
        });

        // 3. Attach pending confirmation card if present.
        final pendingList = data?['pending_transactions'] as List?;
        if (pendingList != null && pendingList.isNotEmpty) {
          _attachPendingCard(assistantDocId: assistantId, rawList: pendingList);
        }

        // 4. Attach budget prompt card when category has no budget set.
        if (intent == 'need_budget_before_expense') {
          final waitingCat = data?['waitingCategory'] as String?;
          if (waitingCat != null && waitingCat.isNotEmpty) {
            setState(() {
              _budgetPromptCategories[assistantId] = waitingCat;
            });
          }
        }

        if (alerts != null && alerts.isNotEmpty) {
          NotificationScreen.unreadCount.value += alerts.length;
        }

        // Overspend requiring budget from other categories — ask before
        // anything is actually moved.
        final pendingRebalance = data?['budgetUpdate']?['pendingRebalance'];
        if (pendingRebalance != null && mounted) {
          await showRebalanceConfirmDialog(
            context,
            Map<String, dynamic>.from(pendingRebalance),
          );
        }

        _triggerRefreshForIntent(intent);
        ChatScreen.messageSent = true;
      } else {
        setState(() => _isLoading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Chat error (${res.statusCode}). Please try again.'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
      _scrollToBottom();
    } catch (e, st) {
      debugPrint('Chat send error: $e\n$st');
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Network error. Please try again.'),
          duration: Duration(seconds: 3),
        ),
      );
      _scrollToBottom();
    }
  }

  /// Register a pending card in memory keyed by the assistant message doc ID.
  void _attachPendingCard({
    required String assistantDocId,
    required List rawList,
  }) {
    final items = rawList
        .map((e) => PendingTransaction.fromJson(e as Map<String, dynamic>))
        .toList();

    if (items.isEmpty) return;

    setState(() {
      _pendingCards[assistantDocId] = _PendingCard(
        localId: assistantDocId,
        items: items,
      );
    });
  }

  // ── Confirm / Cancel actions ─────────────────────────────────────────────

  Future<void> _confirmCard(_PendingCard card,
      {double? overrideAmount, String? overrideCategory}) async {
    if (card.isLoading) return;
    setState(() => card.isLoading = true);

    try {
      final ids = card.items.map((t) => t.id).toList();
      // If single item with override, pass them; otherwise bulk confirm
      final category = overrideCategory ?? card.items.first.selectedCategory;
      final amount = overrideAmount;

      await ApiService.confirmTransactions(ids,
          amount: amount, category: category);

      setState(() {
        card.state = _PendingCardState.confirmed;
        card.isLoading = false;
      });

      // Refresh home and categories after confirmation
      _triggerRefreshForIntent('expense_log');
      ChatScreen.messageSent = true;
    } catch (e) {
      debugPrint('[ChatScreen] confirm failed: $e');
      setState(() => card.isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Confirm garna sakiyena. Pheri try garnu hola.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _cancelCard(_PendingCard card) async {
    if (card.isLoading) return;
    setState(() => card.isLoading = true);

    try {
      final ids = card.items.map((t) => t.id).toList();
      await ApiService.cancelTransactions(ids);
      setState(() {
        card.state = _PendingCardState.cancelled;
        card.isLoading = false;
      });
    } catch (e) {
      debugPrint('[ChatScreen] cancel failed: $e');
      setState(() => card.isLoading = false);
    }
  }

  // ── Intent-based refresh (unchanged) ─────────────────────────────────────

  void _triggerRefreshForIntent(String intent) {
    if (widget.onRefreshNeeded == null) return;

    final needsHome = _refreshHomeIntents.contains(intent);
    final needsCategories = _refreshCategoriesIntents.contains(intent);

    if (needsHome || needsCategories) {
      widget.onRefreshNeeded!(
        refreshHome: needsHome,
        refreshCategories: needsCategories,
      );
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    const int headerCount = 1;
    final int staticGreetingCount = (_messages.isEmpty ? 1 : 0);
    final int typingCount = (_isLoading ? 1 : 0);

    // Build a flat item list: each message may be followed by a pending card.
    // We'll build a combined list of "display items" for the ListView.
    final displayItems = _buildDisplayItems(staticGreetingCount > 0);

    final int totalItems =
        headerCount + displayItems.length + typingCount;

    return Container(
      color: _pageBg,
      child: Column(
        children: [
          Expanded(
            child: !_isHistoryLoaded
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 160),
                    itemCount: totalItems,
                    itemBuilder: (context, index) {
                      if (index == 0) return _buildHeader();

                      final itemIndex = index - 1;
                      if (itemIndex < displayItems.length) {
                        return displayItems[itemIndex];
                      }
                      return _buildTypingIndicator();
                    },
                  ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  /// Produces the flat widget list for the ListView, interleaving messages
  /// with their associated pending confirmation cards.
  List<Widget> _buildDisplayItems(bool showGreeting) {
    final items = <Widget>[];

    if (showGreeting) {
      items.add(_buildWelcomeCard());
      return items;
    }

    for (int i = 0; i < _messages.length; i++) {
      final msg = _messages[i];
      final docId = msg['id'] as String? ?? '';

      items.add(_buildMessageBubble(msg, time: _formatMsgTime(msg['createdAt'] as String?)));

      // After assistant messages, check if there's a pending card to render.
      if (msg['role'] == 'assistant') {
        // Chat-initiated pending card
        final card = _pendingCards[docId];
        if (card != null) {
          items.add(_buildPendingCard(card));
        }

        // Budget prompt card when category has no budget set
        final budgetCat = _budgetPromptCategories[docId];
        if (budgetCat != null) {
          items.add(_buildBudgetPromptCard(budgetCat));
        }

        // Month event "Budget hera / change gara" button
        if (msg['isMonthEvent'] == true &&
            msg['intent'] == 'new_month_started') {
          items.add(_buildBudgetActionButton());
        }
      }
    }

    return items;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PENDING CONFIRMATION CARD (chat + notification)
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildPendingCard(_PendingCard card) {
    return Padding(
      key: ValueKey('card_${card.localId}'),
      padding: const EdgeInsets.only(left: 42, bottom: 10),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _pendingCardContent(card),
      ),
    );
  }

  Widget _pendingCardContent(_PendingCard card) {
    switch (card.state) {
      case _PendingCardState.confirmed:
        return _statusChip(
          key: const ValueKey('confirmed'),
          icon: Icons.check_circle_outline,
          label: 'Confirmed! Kharcha save bhayo. ✓',
          color: _primary,
        );
      case _PendingCardState.cancelled:
        return _statusChip(
          key: const ValueKey('cancelled'),
          icon: Icons.cancel_outlined,
          label: 'Discarded.',
          color: Colors.grey,
        );
      case _PendingCardState.editing:
        return _editCard(card);
      case _PendingCardState.pending:
        return _pendingConfirmCard(card);
    }
  }

  Widget _statusChip({
    required Key key,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    color: color,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _pendingConfirmCard(_PendingCard card) {
    final isNotification = card.items.any((t) => t.source == 'notification');

    return Container(
      key: const ValueKey('pending'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFB347).withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.orange.withValues(alpha: 0.07),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8F0),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(14)),
              border: Border(
                  bottom: BorderSide(
                      color: const Color(0xFFFFB347).withValues(alpha: 0.25))),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFB347).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.pending_actions,
                      color: Color(0xFFE08A00), size: 16),
                ),
                const SizedBox(width: 8),
                Text(
                  isNotification
                      ? 'Notification bata detect bhayo'
                      : 'Confirm garnu cha?',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFE08A00),
                  ),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFB347).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'PENDING',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFE08A00),
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Items ──
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                ...card.items.map((t) => _pendingItem(t, card)),
              ],
            ),
          ),

          // ── Actions ──
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: card.isLoading
                ? const Center(
                    child: SizedBox(
                      height: 32,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // Confirm — with category guard for notification cards
                          Expanded(
                            child: Builder(builder: (ctx) {
                              final needsCat = isNotification;
                              final hasCat = card.items.isNotEmpty &&
                                  (card.items.first.selectedCategory ?? '').isNotEmpty;
                              final confirmColor =
                                  (needsCat && !hasCat) ? Colors.grey.shade300 : _primary;
                              return _actionButton(
                                label: 'Confirm',
                                icon: Icons.check,
                                color: confirmColor,
                                onTap: () {
                                  if (needsCat && !hasCat) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: const Row(
                                          children: [
                                            Icon(Icons.warning_amber_rounded,
                                                color: Colors.white, size: 16),
                                            SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                'Please select a category before confirming this expense.',
                                                style: TextStyle(fontSize: 12.5),
                                              ),
                                            ),
                                          ],
                                        ),
                                        backgroundColor: const Color(0xFFE08A00),
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(10)),
                                        margin: const EdgeInsets.all(16),
                                        duration: const Duration(seconds: 3),
                                      ),
                                    );
                                    return;
                                  }
                                  _confirmCard(card);
                                },
                              );
                            }),
                          ),
                          const SizedBox(width: 8),
                          // Edit
                          Expanded(
                            child: _actionButton(
                              label: 'Edit',
                              icon: Icons.edit_outlined,
                              color: const Color(0xFF4F6CFF),
                              onTap: () =>
                                  setState(() => card.state = _PendingCardState.editing),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Discard
                          Expanded(
                            child: _actionButton(
                              label: 'Discard',
                              icon: Icons.close,
                              color: Colors.grey,
                              onTap: () => _cancelCard(card),
                            ),
                          ),
                        ],
                      ),
                      // Hint when category is missing for notification cards
                      if (isNotification &&
                          (card.items.isEmpty ||
                              (card.items.first.selectedCategory ?? '').isEmpty)) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(Icons.info_outline,
                                size: 12, color: Colors.orange.shade700),
                            const SizedBox(width: 4),
                            Text(
                              'Select a category above to confirm.',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.orange.shade700),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _pendingItem(PendingTransaction t, _PendingCard card) {
    final isNotification = t.source == 'notification';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          // Amount badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Rs ${t.amount.toStringAsFixed(0)}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Label / receiver
          Expanded(
            child: Text(
              isNotification
                  ? (t.receiverName ?? t.label)
                  : t.label,
              style: const TextStyle(
                  fontSize: 13, color: Color(0xFF22252A)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          // Category selector
          _categoryDropdown(t, card),
        ],
      ),
    );
  }

  Widget _categoryDropdown(PendingTransaction t, _PendingCard card) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7F9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE6E8EE)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _kCategories.contains(t.selectedCategory)
              ? t.selectedCategory
              : null,
          hint: const Text(
            'Category',
            style: TextStyle(fontSize: 11.5, color: Colors.grey),
          ),
          style:
              const TextStyle(fontSize: 11.5, color: Color(0xFF22252A)),
          isDense: true,
          items: _kCategories
              .map((c) => DropdownMenuItem(value: c, child: Text(c)))
              .toList(),
          onChanged: (val) => setState(() => t.selectedCategory = val),
        ),
      ),
    );
  }

  Widget _editCard(_PendingCard card) {
    // For simplicity: single-item edit. If multi-item we edit just the first.
    final t = card.items.first;
    final amountController =
        TextEditingController(text: t.amount.toStringAsFixed(0));

    return Container(
      key: const ValueKey('editing'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF4F6CFF).withValues(alpha: 0.4)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4F6CFF).withValues(alpha: 0.07),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Edit kharcha',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF4F6CFF)),
          ),
          const SizedBox(height: 10),
          // Amount field
          TextField(
            controller: amountController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Amount (Rs)',
              labelStyle:
                  const TextStyle(fontSize: 12.5, color: Colors.grey),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                    color: Colors.grey.shade300),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Category dropdown
          _categoryDropdown(t, card),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _actionButton(
                  label: 'Save',
                  icon: Icons.save_outlined,
                  color: _primary,
                  onTap: () {
                    final newAmount =
                        double.tryParse(amountController.text) ?? t.amount;
                    t.amount = newAmount;
                    _confirmCard(card,
                        overrideAmount: newAmount,
                        overrideCategory: t.selectedCategory);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _actionButton(
                  label: 'Back',
                  icon: Icons.arrow_back,
                  color: Colors.grey,
                  onTap: () =>
                      setState(() => card.state = _PendingCardState.pending),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color)),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // MONTH EVENT "Budget hera / change gara" button
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildBudgetActionButton() {
    return Padding(
      padding: const EdgeInsets.only(left: 42, bottom: 10),
      child: GestureDetector(
        onTap: () {
          // Navigate to Categories screen (Budget editing)
          // We pop the chat so MainScreen can switch tabs.
          Navigator.of(context).pop();
          // The MainScreen will re-open the same tab the user was on.
          // A cleaner UX is to pass a callback, but we keep existing nav
          // patterns intact as per requirements.
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF2DBE7F), Color(0xFF1AA86A)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF2DBE7F).withValues(alpha: 0.25),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.account_balance_wallet_outlined,
                  color: Colors.white, size: 16),
              SizedBox(width: 8),
              Text(
                'Budget hera / change gara',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // EXISTING WIDGETS (unchanged)
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.auto_awesome, color: _primary, size: 22),
          ),
          const SizedBox(height: 10),
          const Text(
            "Ask me anything about your expenses.",
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18),
            child: Text(
              "Try asking about your monthly summary or setting a new budget goal.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, height: 1.3, fontSize: 12.5),
            ),
          ),
          const SizedBox(height: 10),
          const Divider(height: 22),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> msg, {required String time}) {
    final isUser = msg['role'] == 'user';
    final content = (msg['content'] ?? '').toString();
    final status = msg['status'] as MessageStatus? ?? MessageStatus.sent;

    if (isUser) {
      return _userBubble(content: content, time: time, status: status);
    }
    return _assistantBubble(content: content, time: time);
  }

  Widget _assistantBubble({required String content, required String time}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // avatar
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  Colors.blueGrey.shade300,
                  Colors.blueGrey.shade600,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: const Center(
              child: Icon(Icons.smart_toy, size: 16, color: Colors.white),
            ),
          ),
          const SizedBox(width: 10),

          // bubble + time
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE6E8EE)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Text(
                    content,
                    style: const TextStyle(
                      fontSize: 13.8,
                      height: 1.35,
                      color: Color(0xFF22252A),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  time,
                  style: const TextStyle(fontSize: 10.5, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _userBubble(
      {required String content,
      required String time,
      MessageStatus status = MessageStatus.sent}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: _primary,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: const Color(0xFF4F6CFF), width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: _primary.withValues(alpha: 0.16),
                        blurRadius: 14,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Text(
                    content,
                    style: const TextStyle(
                      fontSize: 13.8,
                      height: 1.35,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      time,
                      style: const TextStyle(
                          fontSize: 10.5, color: Colors.grey),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      status == MessageStatus.pending
                          ? Icons.watch_later
                          : Icons.check,
                      size: 14,
                      color: Colors.grey,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 10),
      child: Row(
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 38),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE6E8EE)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dot(delayMs: 0),
                const SizedBox(width: 4),
                _dot(delayMs: 180),
                const SizedBox(width: 4),
                _dot(delayMs: 360),
                const SizedBox(width: 8),
                const Text(
                  "BachatBot is thinking...",
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot({required int delayMs}) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.25, end: 1),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeInOut,
      onEnd: () {},
      builder: (context, value, _) {
        return Opacity(
          opacity: value,
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUDGET PROMPT CARD — shown when an expense category has no budget set
  // ─────────────────────────────────────────────────────────────────────────

  static const Map<String, IconData> _categoryIcons = {
    'Food': Icons.restaurant_outlined,
    'Transport': Icons.directions_bus_outlined,
    'Rent': Icons.home_outlined,
    'Education': Icons.school_outlined,
    'Shopping': Icons.shopping_bag_outlined,
    'Health': Icons.favorite_border,
    'Entertainment': Icons.movie_outlined,
    'Bills': Icons.receipt_outlined,
    'Others': Icons.category_outlined,
  };

  Widget _buildBudgetPromptCard(String category) {
    final icon = _categoryIcons[category] ?? Icons.account_balance_wallet_outlined;
    const cardColor = Color(0xFF7E57C2);
    final suggested = _suggestedBudgets(category);

    return Padding(
      padding: const EdgeInsets.only(left: 42, bottom: 10, top: 4),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cardColor.withValues(alpha: 0.25)),
          boxShadow: [
            BoxShadow(
              color: cardColor.withValues(alpha: 0.07),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: cardColor.withValues(alpha: 0.07),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: cardColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: cardColor, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$category ko budget set garau!',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: cardColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Kati set garne? Tala click gara.',
                          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Suggested amounts
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Suggested budgets:',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ...suggested.map((amt) => _budgetChip(
                            'Rs $amt',
                            'Set $category budget $amt',
                            cardColor,
                          )),
                      _budgetChip('Skip', 'Skip budget for now', Colors.grey),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<int> _suggestedBudgets(String category) {
    const suggestions = <String, List<int>>{
      'Food': [3000, 5000, 8000],
      'Transport': [1000, 2000, 3500],
      'Rent': [5000, 10000, 15000],
      'Education': [2000, 5000, 10000],
      'Shopping': [2000, 5000, 8000],
      'Health': [1000, 3000, 5000],
      'Entertainment': [1000, 2000, 4000],
      'Bills': [2000, 5000, 8000],
      'Others': [1000, 3000, 5000],
    };
    return suggestions[category] ?? [2000, 5000, 10000];
  }

  Widget _budgetChip(String label, String message, Color color) {
    return GestureDetector(
      onTap: () {
        if (_isLoading) return;
        _controller.text = message;
        _send();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            color: color == Colors.grey ? Colors.grey.shade700 : color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // WELCOME CARD — shown only when no chat history exists (first-time user)
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildWelcomeCard() {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Bot header ──────────────────────────────────────────────────
          Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2DBE7F), Color(0xFF1B8B8E)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.auto_awesome, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 14),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Hi! I\'m BachatBot 👋',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF22252A)),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Your personal finance companion',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ── Intro text ──────────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE6E8EE)),
            ),
            child: const Text(
              'I can help you track expenses, set budgets, and understand your spending habits. Here\'s what I can do:',
              style: TextStyle(fontSize: 13, color: Color(0xFF22252A), height: 1.45),
            ),
          ),
          const SizedBox(height: 12),

          // ── Feature grid ────────────────────────────────────────────────
          Row(
            children: [
              Expanded(child: _featureTile(Icons.receipt_long_outlined, 'Expense Tracking', 'Log spending easily', const Color(0xFF2DBE7F))),
              const SizedBox(width: 10),
              Expanded(child: _featureTile(Icons.account_balance_wallet_outlined, 'Budget Setup', 'Set monthly limits', const Color(0xFF1B8B8E))),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _featureTile(Icons.bar_chart_rounded, 'Reports', 'Daily & monthly stats', const Color(0xFF7E57C2))),
              const SizedBox(width: 10),
              Expanded(child: _featureTile(Icons.lightbulb_outline, 'Smart Insights', 'Spending suggestions', const Color(0xFFFF7043))),
            ],
          ),
          const SizedBox(height: 16),

          // ── What can I help with ────────────────────────────────────────
          const Text(
            'What would you like to do?',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF22252A)),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _welcomeChip('💸 Track an expense', 'I want to track an expense'),
              _welcomeChip('📊 Today\'s report', 'How much did I spend today?'),
              _welcomeChip('🎯 Set a budget', 'Help me set a budget'),
              _welcomeChip('💡 Spending habits', 'Tell me about my spending habits this month'),
              _welcomeChip('📅 Monthly report', 'Show my monthly report'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _featureTile(IconData icon, String title, String subtitle, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 8),
          Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  Widget _welcomeChip(String label, String message) {
    return GestureDetector(
      onTap: () {
        if (_isLoading) return;
        _controller.text = message;
        _send();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _primary.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12.5, color: Color(0xFF22252A), fontWeight: FontWeight.w500),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildQuickActions() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          _quickActionButton(Icons.today_outlined, 'Today\'s spending'),
          const SizedBox(width: 10),
          _quickActionButton(Icons.bar_chart, 'Monthly report'),
          const SizedBox(width: 10),
          _quickActionButton(Icons.lightbulb_outline, 'Spending tips'),
          const SizedBox(width: 10),
          _quickActionButton(Icons.account_balance_wallet_outlined, 'Budget status'),
        ],
      ),
    );
  }

  Widget _quickActionButton(IconData icon, String text) {
    const messages = {
      'Today\'s spending': 'How much did I spend today?',
      'Monthly report': 'Show my monthly report',
      'Spending tips': 'Give me spending tips and suggestions',
      'Budget status': 'What is my current budget status?',
    };
    return GestureDetector(
      onTap: () {
        if (_isLoading) return;
        _controller.text = messages[text] ?? text;
        _send();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE6E8EE)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: _primary),
            const SizedBox(width: 8),
            Text(
              text,
              style: const TextStyle(
                  fontSize: 12.5, color: Color(0xFF22252A)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: BoxDecoration(
        color: _pageBg,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset > 0 ? 6 : 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildQuickActions(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 44,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border:
                              Border.all(color: const Color(0xFFE6E8EE)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.edit_outlined,
                                size: 18,
                                color: Colors.grey.shade500),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _controller,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) =>
                                    _isLoading ? null : _send(),
                                decoration: const InputDecoration(
                                  hintText: "Ask BachatBot...",
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _isLoading ? Colors.grey : _primary,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.send,
                            color: Colors.white, size: 18),
                        onPressed: _isLoading ? null : _send,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatMsgTime(String? createdAt) {
    if (createdAt == null) return '';
    final dt = DateTime.tryParse(createdAt)?.toLocal();
    if (dt == null) return '';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour >= 12 ? 'PM' : 'AM'}';
  }
}