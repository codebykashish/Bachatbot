import 'package:flutter/material.dart';
import '../api_service.dart';
import 'notification_screen.dart';

/// Callback signature for chat intent-based refresh.
/// [refreshHome] and [refreshCategories] are flags indicating what to refresh.
typedef ChatRefreshCallback = void Function({
  bool refreshHome,
  bool refreshCategories,
});

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

  static const Color _primary = Color(0xFF2DBE7F);
  static const Color _pageBg = Color(0xFFF6F7F9);

  // Intents that require refreshing Home and/or Categories
  static const _refreshHomeIntents = {
    'expense_log',
    'income_log',
    'undo_last_expense',
    'notification_confirm',
  };

  static const _refreshCategoriesIntents = {
    'expense_log',
    'income_log',
    'set_budget',
    'undo_last_expense',
    'notification_confirm',
  };

  @override
  void initState() {
    super.initState();
    ChatScreen.messageSent = false; // reset each time chat opens
    _loadHistory();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final response = await ApiService.get('/messages?limit=50');
      if (!mounted) return;

      final msgs = response['data']?['messages'] as List? ?? [];
      final reversed = msgs.reversed.toList();

      setState(() {
        _messages.clear();
        for (final msg in reversed) {
          _messages.add({
            'role': msg['role'],
            'content': msg['content'],
            'intent': msg['intent'],
            // Carry transactionId if the backend included one (notification flow)
            if (msg['transactionId'] != null)
              'transactionId': msg['transactionId'],
          });
        }
        _isHistoryLoaded = true;
      });

      _scrollToBottom();
    } catch (e) {
      setState(() => _isHistoryLoaded = true);
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isLoading) return;

    _controller.clear();
    setState(() {
      _messages.add({'role': 'user', 'content': text});
      _isLoading = true;
    });

    _scrollToBottom();

    try {
      final response = await ApiService.post('/chat', {
        'message': text,
        'source': 'chat',
      });

      if (!mounted) return;

      final data = response['data'];
      final reply = data?['reply'] ?? 'Sorry, I could not understand that.';
      final intent = data?['intent'] ?? 'general_chat';
      final alerts = data?['alerts'] as List?;
      final transactionId = data?['transactionId'] as String?;

      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': reply,
          'intent': intent,
          // Only present for notification-sourced replies that need confirmation
          if (transactionId != null) 'transactionId': transactionId,
        });
        _isLoading = false;
      });

      // Update notification badge if alerts were returned
      if (alerts != null && alerts.isNotEmpty) {
        NotificationScreen.unreadCount.value += alerts.length;
      }

      // Trigger intent-based refresh
      _triggerRefreshForIntent(intent);

      ChatScreen.messageSent = true; // flag so MainScreen refreshes on pop
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': 'Something went wrong.',
        });
        _isLoading = false;
      });

      _scrollToBottom();
    }
  }

  /// Trigger selective refresh based on the chat intent
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

  // ── Notification transaction actions ─────────────────────────────────

  Future<void> _confirmTransaction(String transactionId, int messageIndex) async {
    print('[NOTIF_SYNC] Confirming transaction $transactionId');
    // Remove action buttons optimistically
    setState(() {
      _messages[messageIndex].remove('transactionId');
    });
    try {
      final res = await ApiService.post(
          '/confirm-transaction/$transactionId', {});
      print('[NOTIF_SYNC] Confirm response: $res');
      // Trigger home/categories refresh since a transaction was confirmed
      widget.onRefreshNeeded?.call(
        refreshHome: true,
        refreshCategories: true,
      );
      ChatScreen.messageSent = true;
    } catch (e) {
      print('[NOTIF_SYNC] Confirm error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not confirm transaction.')),
      );
    }
  }

  Future<void> _rejectTransaction(String transactionId, int messageIndex) async {
    print('[NOTIF_SYNC] Rejecting transaction $transactionId');
    setState(() {
      _messages[messageIndex].remove('transactionId');
    });
    try {
      final res = await ApiService.post(
          '/reject-transaction/$transactionId', {});
      print('[NOTIF_SYNC] Reject response: $res');
    } catch (e) {
      print('[NOTIF_SYNC] Reject error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not reject transaction.')),
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

  @override
  Widget build(BuildContext context) {
    // Header is always visible (like your screenshot).
    const int headerCount = 1;
    final int staticGreetingCount = (_messages.isEmpty ? 1 : 0);
    final int typingCount = (_isLoading ? 1 : 0);

    final int totalItems =
        headerCount + staticGreetingCount + _messages.length + typingCount;

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
                      // 0 => header
                      if (index == 0) return _buildHeader();

                      // optional static greeting when no messages
                      if (staticGreetingCount == 1 && index == 1) {
                        return Column(
                          children: [
                            const SizedBox(height: 14),
                            _assistantBubble(
                              content:
                                  "Hello! I'm BachatBot, your personal finance assistant. How can I help you manage your budget today?",
                              time: "10:00 AM",
                            ),
                          ],
                        );
                      }

                      final int messageStartIndex =
                          headerCount + staticGreetingCount;
                      final int messageIndex = index - messageStartIndex;

                      // messages
                      if (messageIndex >= 0 && messageIndex < _messages.length) {
                        return _buildMessageBubble(
                          _messages[messageIndex],
                          // show demo-like times without changing your logic/data
                          time: _fakeTimeForIndex(messageIndex),
                        );
                      }

                      // typing indicator at end
                      return _buildTypingIndicator();
                    },
                  ),
          ),

          // bottom composer
          _buildInputBar(),
        ],
      ),
    );
  }

  // ================= HEADER (top empty state panel) =================

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

  // ================= MESSAGE BUBBLES =================

  Widget _buildMessageBubble(Map<String, dynamic> msg, {required String time}) {
    final isUser = msg['role'] == 'user';
    final content = (msg['content'] ?? '').toString();
    final transactionId = msg['transactionId'] as String?;

    // Compute the real index of this message in _messages so we can
    // remove the transactionId after the user acts.
    final messageIndex = _messages.indexOf(msg);

    if (isUser) {
      return _userBubble(content: content, time: time);
    }
    return _assistantBubble(
      content: content,
      time: time,
      transactionId: transactionId,
      messageIndex: messageIndex,
    );
  }

  Widget _assistantBubble({
    required String content,
    required String time,
    String? transactionId,
    int messageIndex = -1,
  }) {
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

          // bubble + time + optional confirm/reject buttons
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

                // ── Confirm / Reject buttons (notification sync flow) ──
                if (transactionId != null && messageIndex >= 0) ...
                  _buildConfirmRejectRow(transactionId, messageIndex),

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

  /// Confirm / Reject action row shown below a bot bubble
  /// when the message originated from a notification sync event.
  List<Widget> _buildConfirmRejectRow(String transactionId, int messageIndex) {
    return [
      const SizedBox(height: 10),
      Row(
        children: [
          // Confirm
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () =>
                  _confirmTransaction(transactionId, messageIndex),
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('Confirm'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _primary,
                side: const BorderSide(color: _primary),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Reject
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () =>
                  _rejectTransaction(transactionId, messageIndex),
              icon: const Icon(Icons.cancel_outlined, size: 16),
              label: const Text('Reject'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade400,
                side: BorderSide(color: Colors.red.shade300),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _userBubble({required String content, required String time}) {
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
                    border: Border.all(color: const Color(0xFF4F6CFF), width: 2),
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
                      style:
                          const TextStyle(fontSize: 10.5, color: Colors.grey),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.done_all, size: 14, color: Colors.grey),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ================= THINKING =================

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 10),
      child: Row(
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 38),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
      onEnd: () {
        // keep animating by rebuilding naturally through list updates;
        // no logic changes needed
      },
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

  // ================= QUICK ACTIONS (UI only) =================

  Widget _buildQuickActions() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          _quickActionButton(Icons.add, "Add expense"),
          const SizedBox(width: 10),
          _quickActionButton(Icons.bar_chart, "Show report"),
          const SizedBox(width: 10),
          _quickActionButton(Icons.undo, "Undo last"),
        ],
      ),
    );
  }

  Widget _quickActionButton(IconData icon, String text) {
    return GestureDetector(
      onTap: () {
        // Pre-fill the text field with the action text
        _controller.text = text == "Add expense"
            ? ""
            : text == "Show report"
                ? "Show my monthly report"
                : "Undo last expense";
        if (text != "Add expense") {
          _send();
        }
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
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF22252A)),
            ),
          ],
        ),
      ),
    );
  }

  // ================= INPUT =================

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
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE6E8EE)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.edit_outlined,
                                size: 18, color: Colors.grey.shade500),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _controller,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _isLoading ? null : _send(),
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
                        icon: const Icon(Icons.send, color: Colors.white, size: 18),
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

  // purely visual (no backend logic change)
  String _fakeTimeForIndex(int i) {
    // mimic screenshot vibe: 10:02 AM etc.
    final baseMinute = 0 + (i * 2);
    final minute = (baseMinute % 60).toString().padLeft(2, '0');
    return "10:$minute AM";
  }
}