import 'package:flutter/material.dart';
import '../api_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<Map<String, dynamic>> _messages = [];
  bool _isLoading = false;
  bool _isHistoryLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Load previous chat messages from backend
  Future<void> _loadHistory() async {
    try {
      final response = await ApiService.get('/messages?limit=50');
      if (!mounted) return;

      final msgs = response['data']?['messages'] as List? ?? [];

      // Messages come newest first, reverse for chat display
      final reversed = msgs.reversed.toList();

      setState(() {
        _messages.clear();
        for (final msg in reversed) {
          _messages.add({
            'role': msg['role'],
            'content': msg['content'],
            'intent': msg['intent'],
          });
        }
        _isHistoryLoaded = true;
      });

      _scrollToBottom();
    } catch (e) {
      setState(() => _isHistoryLoaded = true);
      debugPrint('Error loading history: $e');
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
      final needsConfirmation = data?['needsConfirmation'] ?? false;
      final transaction = data?['transaction'];
      final budgetUpdate = data?['budgetUpdate'];

      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': reply,
          'intent': intent,
          'transaction': transaction,
          'budgetUpdate': budgetUpdate,
          'needsConfirmation': needsConfirmation,
        });
        _isLoading = false;
      });

      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': 'Sorry, something went wrong. Please try again.',
          'intent': 'error',
        });
        _isLoading = false;
      });
      _scrollToBottom();
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
    return Column(
      children: [
        // Chat messages list
        Expanded(
          child: !_isHistoryLoaded
              ? const Center(child: CircularProgressIndicator())
              : _messages.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                      itemCount: _messages.length + (_isLoading ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == _messages.length) {
                          return _buildTypingIndicator();
                        }
                        return _buildMessageBubble(_messages[index]);
                      },
                    ),
        ),

        // Input bar
        _buildInputBar(),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline,
              size: 72, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          const Text(
            'Hi! I am BachatBot 👋',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2E7D32),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tell me about your expenses!\nExample: "Momo khada Rs 250 gayo"',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, height: 1.5),
          ),
          const SizedBox(height: 24),
          // Quick action chips
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _buildChip('💸 I spent Rs 500 on food'),
              _buildChip('📊 Show my spending'),
              _buildChip('💰 What is my balance?'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChip(String label) {
    return GestureDetector(
      onTap: () {
        _controller.text = label
            .replaceAll('💸 ', '')
            .replaceAll('📊 ', '')
            .replaceAll('💰 ', '');
        _send();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF2E7D32).withOpacity(0.4)),
          borderRadius: BorderRadius.circular(20),
          color: const Color(0xFF2E7D32).withOpacity(0.05),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xFF2E7D32),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> msg) {
    final isUser = msg['role'] == 'user';
    final content = msg['content'] as String? ?? '';
    final transaction = msg['transaction'] as Map?;
    final budgetUpdate = msg['budgetUpdate'] as Map?;
    final needsConfirmation = msg['needsConfirmation'] as bool? ?? false;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Role label
          Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 4, right: 4),
            child: Text(
              isUser ? 'You' : 'BachatBot',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade500,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

          // Message bubble
          Row(
            mainAxisAlignment:
                isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isUser) ...[
                CircleAvatar(
                  radius: 16,
                  backgroundColor: const Color(0xFF2E7D32),
                  child: const Icon(Icons.savings,
                      color: Colors.white, size: 16),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isUser
                        ? const Color(0xFF2E7D32)
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isUser ? 16 : 4),
                      bottomRight: Radius.circular(isUser ? 4 : 16),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    content,
                    style: TextStyle(
                      color: isUser ? Colors.white : Colors.black87,
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              if (isUser) const SizedBox(width: 8),
            ],
          ),

          // Transaction card (if logged)
          if (!isUser && transaction != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 40),
              child: _buildTransactionCard(transaction),
            ),

          // Budget update card
          if (!isUser && budgetUpdate != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 40),
              child: _buildBudgetUpdateCard(budgetUpdate),
            ),

          // Pending confirmation buttons
          if (!isUser && needsConfirmation && transaction != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 40),
              child: _buildConfirmationButtons(transaction['id']),
            ),
        ],
      ),
    );
  }

  Widget _buildTransactionCard(Map transaction) {
    final isExpense = transaction['type'] == 'expense';
    final amount = transaction['amount'];
    final category = transaction['category'] ?? '';
    final status = transaction['status'] ?? '';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isExpense
              ? Colors.red.shade200
              : Colors.green.shade200,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isExpense ? Icons.arrow_downward : Icons.arrow_upward,
            color: isExpense ? Colors.red : Colors.green,
            size: 20,
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Rs ${amount}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isExpense ? Colors.red : Colors.green,
                  fontSize: 15,
                ),
              ),
              Text(
                '$category • $status',
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBudgetUpdateCard(Map budget) {
    final category = budget['category'] ?? '';
    final spent = budget['spent'] ?? 0;
    final limit = budget['limit'] ?? 0;
    final percent = budget['percentUsed'] ?? 0;
    final remaining = budget['remaining'] ?? 0;

    Color barColor = Colors.green;
    if (percent >= 100) {
      barColor = Colors.red;
    } else if (percent >= 80) {
      barColor = Colors.orange;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$category Budget',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: Colors.blue,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (percent / 100).clamp(0.0, 1.0),
              backgroundColor: Colors.grey.shade300,
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Rs $spent / Rs $limit ($percent%) • Rs $remaining remaining',
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmationButtons(String transactionId) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ElevatedButton.icon(
          onPressed: () => _confirmTransaction(transactionId),
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Confirm'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF2E7D32),
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 8),
            textStyle: const TextStyle(fontSize: 13),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => _rejectTransaction(transactionId),
          icon: const Icon(Icons.close, size: 16, color: Colors.red),
          label: const Text(
            'Reject',
            style: TextStyle(color: Colors.red),
          ),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Colors.red),
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 8),
            textStyle: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmTransaction(String transactionId) async {
    try {
      await ApiService.post(
          '/confirm-transaction/$transactionId', {});
      if (!mounted) return;
      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': '✅ Transaction confirmed and saved!',
          'intent': 'confirmation',
        });
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _rejectTransaction(String transactionId) async {
    try {
      await ApiService.post(
          '/reject-transaction/$transactionId', {});
      if (!mounted) return;
      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': '❌ Transaction rejected.',
          'intent': 'rejection',
        });
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: const Color(0xFF2E7D32),
            child: const Icon(Icons.savings,
                color: Colors.white, size: 16),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dot(0),
                const SizedBox(width: 4),
                _dot(150),
                const SizedBox(width: 4),
                _dot(300),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot(int delayMs) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOut,
      builder: (context, value, child) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Colors.grey.shade400,
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }

  Widget _buildInputBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        left: 16,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom > 0 ? 8 : 16,
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: 'Type your message...',
                  hintStyle: TextStyle(color: Colors.grey.shade400),
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              child: CircleAvatar(
                radius: 24,
                backgroundColor: _isLoading
                    ? Colors.grey
                    : const Color(0xFF2E7D32),
                child: IconButton(
                  icon: Icon(
                    _isLoading ? Icons.hourglass_empty : Icons.send,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: _isLoading ? null : _send,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}