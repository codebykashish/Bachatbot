/// Represents a pending transaction awaiting user confirmation.
/// Returned by the backend as part of a /chat response or /transactions/pending.
class PendingTransaction {
  final String id;
  double amount;
  final String label;
  final String source; // 'chat' | 'notification'
  final String? receiverName; // for notification-sourced items
  String? selectedCategory;

  PendingTransaction({
    required this.id,
    required this.amount,
    required this.label,
    required this.source,
    this.receiverName,
    this.selectedCategory,
  });

  factory PendingTransaction.fromJson(Map<String, dynamic> json) {
    return PendingTransaction(
      id: json['id']?.toString() ?? '',
      amount: (json['amount'] as num?)?.toDouble() ?? 0.0,
      label: json['label'] as String? ??
          json['receiverName'] as String? ??
          'Unknown',
      source: json['source'] as String? ?? 'chat',
      receiverName: json['receiverName'] as String?,
      selectedCategory: json['category'] as String? ??
          json['suggestedCategory'] as String?,
    );
  }
}
