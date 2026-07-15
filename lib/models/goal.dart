class Goal {
  final String id;
  final String name;
  final double targetAmount;
  final int timeframeMonths;
  final double savedSoFar;
  final double remaining;
  final double monthlyTarget;
  final double percentComplete;
  final String status; // active | completed

  Goal({
    required this.id,
    required this.name,
    required this.targetAmount,
    required this.timeframeMonths,
    required this.savedSoFar,
    required this.remaining,
    required this.monthlyTarget,
    required this.percentComplete,
    required this.status,
  });

  factory Goal.fromJson(Map<String, dynamic> json) {
    return Goal(
      id: json['id']?.toString() ?? '',
      name: json['name'] as String? ?? 'Goal',
      targetAmount: (json['targetAmount'] as num?)?.toDouble() ?? 0,
      timeframeMonths: (json['timeframeMonths'] as num?)?.toInt() ?? 1,
      savedSoFar: (json['savedSoFar'] as num?)?.toDouble() ?? 0,
      remaining: (json['remaining'] as num?)?.toDouble() ?? 0,
      monthlyTarget: (json['monthlyTarget'] as num?)?.toDouble() ?? 0,
      percentComplete: (json['percentComplete'] as num?)?.toDouble() ?? 0,
      status: json['status'] as String? ?? 'active',
    );
  }
}
