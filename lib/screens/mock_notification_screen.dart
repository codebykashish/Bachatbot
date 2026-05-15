import 'package:flutter/material.dart';
import '../api_service.dart';

class MockNotificationScreen extends StatefulWidget {
  const MockNotificationScreen({super.key});

  @override
  State<MockNotificationScreen> createState() => _MockNotificationScreenState();
}

class _MockNotificationScreenState extends State<MockNotificationScreen> {
  static const Color _primary = Color(0xFF2DBE7F);
  static const Color _bg = Color(0xFFF6F7F9);

  // ── State ─────────────────────────────────────────────────────────────────
  String _selectedSourceApp = 'eSewa';
  final TextEditingController _msgController = TextEditingController();

  bool _isSending = false;
  bool _isConfirming = false;
  bool _isRejecting = false;

  String? _botReply;
  bool _needsConfirmation = false;
  String? _transactionId;

  // ── Static data ───────────────────────────────────────────────────────────
  static const List<String> _sourceApps = ['eSewa', 'Khalti', 'Nabil Bank', 'NIC Asia'];

  static const Map<String, List<String>> _sampleMessages = {
    'eSewa': [
      'eSewa: Payment of Rs 500 to Bhatbhateni',
      'eSewa: Rs 1500 sent to 9841XXXXXX',
    ],
    'Khalti': [
      'Khalti: Rs 1200 received from Ram',
      'Khalti: Payment of Rs 800 to Foodmandu',
    ],
    'Nabil Bank': [
      'Nabil Bank: Rs 350 debited at POS',
      'Nabil Bank: Salary credit Rs 45000',
    ],
    'NIC Asia': [
      'NIC Asia: Rs 2000 withdrawn from ATM',
      'NIC Asia: Rs 500 debited for bill payment',
    ],
  };

  @override
  void dispose() {
    _msgController.dispose();
    super.dispose();
  }

  // ── Actions ───────────────────────────────────────────────────────────────
  Future<void> _sendMockNotification() async {
    final text = _msgController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a notification message.')),
      );
      return;
    }

    setState(() {
      _isSending = true;
      _botReply = null;
      _needsConfirmation = false;
      _transactionId = null;
    });

    try {
      final response = await ApiService.post('/chat', {
        'message': text,
        'source': 'notification',
        'sourceApp': _selectedSourceApp,
        'originalMessageId': 'mock-${DateTime.now().millisecondsSinceEpoch}',
      });

      if (!mounted) return;

      final data = response['data'];
      final reply = data?['reply'] as String? ?? response['message'] as String? ?? 'No reply from server.';
      final needsConf = data?['needsConfirmation'] == true;
      final txnId = data?['transaction']?['id']?.toString();

      setState(() {
        _botReply = reply;
        _needsConfirmation = needsConf;
        _transactionId = txnId;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _botReply = 'Error: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _confirm() async {
    if (_transactionId == null) return;
    setState(() => _isConfirming = true);
    try {
      await ApiService.post('/confirm-transaction/$_transactionId', {});
      if (!mounted) return;
      setState(() {
        _needsConfirmation = false;
        _transactionId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Transaction confirmed'),
          backgroundColor: Color(0xFF2DBE7F),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Confirm failed: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isConfirming = false);
    }
  }

  Future<void> _reject() async {
    if (_transactionId == null) return;
    setState(() => _isRejecting = true);
    try {
      await ApiService.post('/reject-transaction/$_transactionId', {});
      if (!mounted) return;
      setState(() {
        _needsConfirmation = false;
        _transactionId = null;
        _botReply = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ Transaction rejected'),
          backgroundColor: Colors.orange,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reject failed: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isRejecting = false);
    }
  }

  // ── UI helpers ─────────────────────────────────────────────────────────────
  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.black54,
            letterSpacing: 0.5,
          ),
        ),
      );

  Widget _card({required Widget child}) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final samples = _sampleMessages[_selectedSourceApp] ?? [];

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: const Text(
          '🧪 Mock Notification Test',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0.5,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Dev badge ──────────────────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3CD),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFFCB2B).withValues(alpha: 0.5)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.bug_report, size: 16, color: Color(0xFF856404)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Development only — simulates a financial app notification to test transaction parsing.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF856404)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Source App dropdown ────────────────────────────────────────
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionLabel('SOURCE APP'),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: _bg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedSourceApp,
                        isExpanded: true,
                        style: const TextStyle(fontSize: 14, color: Colors.black87),
                        items: _sourceApps
                            .map((app) => DropdownMenuItem(value: app, child: Text(app)))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() {
                              _selectedSourceApp = v;
                              _botReply = null;
                              _needsConfirmation = false;
                              _transactionId = null;
                            });
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Message text field ─────────────────────────────────────────
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionLabel('NOTIFICATION TEXT'),
                  TextField(
                    controller: _msgController,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'e.g. eSewa: Payment of Rs 500 to Bhatbhateni',
                      hintStyle: const TextStyle(fontSize: 13, color: Colors.black38),
                      filled: true,
                      fillColor: _bg,
                      contentPadding: const EdgeInsets.all(12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.grey.shade200),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.grey.shade200),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: _primary, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _sectionLabel('QUICK FILL'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final sample in samples)
                        _QuickFillChip(
                          label: sample.length > 30 ? '${sample.substring(0, 30)}…' : sample,
                          onTap: () => setState(() => _msgController.text = sample),
                        ),
                    ],
                  ),
                ],
              ),
            ),

            // ── Send button ────────────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _isSending ? null : _sendMockNotification,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 2,
                ),
                icon: _isSending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
                label: Text(
                  _isSending ? 'Sending…' : 'Send Mock Notification',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ── Bot reply ──────────────────────────────────────────────────
            if (_botReply != null)
              _card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: _primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.smart_toy_outlined, color: _primary, size: 18),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'BachatBot Reply',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAFAF3),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _primary.withValues(alpha: 0.2)),
                      ),
                      child: Text(
                        _botReply!,
                        style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5),
                      ),
                    ),

                    // ── Confirm / Reject ─────────────────────────────────
                    if (_needsConfirmation && _transactionId != null) ...[
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 8),
                      const Text(
                        'Transaction needs confirmation:',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.black54,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 46,
                              child: ElevatedButton.icon(
                                onPressed: (_isConfirming || _isRejecting) ? null : _confirm,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _primary,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                icon: _isConfirming
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            color: Colors.white, strokeWidth: 2),
                                      )
                                    : const Icon(Icons.check_circle_outline, size: 18),
                                label: Text(
                                  _isConfirming ? 'Confirming…' : 'Confirm',
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SizedBox(
                              height: 46,
                              child: OutlinedButton.icon(
                                onPressed: (_isConfirming || _isRejecting) ? null : _reject,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.red,
                                  side: const BorderSide(color: Colors.red),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                icon: _isRejecting
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            color: Colors.red, strokeWidth: 2),
                                      )
                                    : const Icon(Icons.cancel_outlined, size: 18),
                                label: Text(
                                  _isRejecting ? 'Rejecting…' : 'Reject',
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Small chip for quick-fill sample messages ─────────────────────────────────
class _QuickFillChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _QuickFillChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFEAFAF3),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF2DBE7F).withValues(alpha: 0.3)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF2DBE7F),
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
