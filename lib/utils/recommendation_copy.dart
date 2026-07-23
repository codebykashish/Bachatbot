/// Shared wording for a `primaryRecommendation` object returned by
/// GET /financial-recommendations. Extracted out of HealthScreen so
/// ProfileScreen (and any future consumer) render the identical copy
/// for the same recommendation code instead of inventing their own.
({String headline, String detail}) recommendationCopy(Map<String, dynamic> rec) {
  final code = rec['code'] as String?;
  final category = rec['category'] as String?;
  final goalName = rec['goalName'] as String?;
  final actionValue = rec['actionValue'];
  final actionUnit = rec['actionUnit'] as String?;
  final amount = (actionValue is num) ? actionValue.round() : null;
  final perDay = actionUnit == 'per_day' && amount != null ? 'Rs $amount/day' : null;

  switch (code) {
    case 'INCREASE_GOAL_CONTRIBUTION':
      return (
        headline: goalName != null ? '$goalName may fall behind' : 'A goal may fall behind',
        detail: amount != null
            ? "You're projected to be Rs $amount short of this month's target."
            : "This goal's pace has slipped below its monthly target.",
      );
    case 'STOP_CATEGORY_SPENDING':
      return (
        headline: 'Your $category budget is used up',
        detail: 'Try to avoid more $category spending this month.',
      );
    case 'REDUCE_CATEGORY_SPENDING':
      return (
        headline: 'Ease up on $category',
        detail: perDay != null
            ? 'Try keeping it around $perDay for the rest of the month.'
            : 'Try spending less on it for the rest of the month.',
      );
    case 'MONITOR_CATEGORY_SPENDING':
      return (headline: 'Keep an eye on $category', detail: "It's trending toward pressure.");
    case 'LIMIT_DAILY_SPENDING':
      return (
        headline: 'Slow your daily spending',
        detail: perDay != null ? 'Try to stay under $perDay a day.' : 'Try to spend a bit less each day.',
      );
    case 'START_RECOVERY_PLAN':
      return (headline: 'Your savings need a boost', detail: 'Worth reviewing your spending this week.');
    case 'ACCEPT_REDUCED_SAVINGS':
      return (headline: "Full recovery isn't possible", detail: 'Spending less now still helps.');
    case 'REVIEW_MULTIPLE_CATEGORIES':
      return (headline: 'A few categories need attention', detail: 'Worth a full review.');
    case 'SLOW_SPENDING_PACE':
      return (headline: "You're spending faster than planned", detail: 'Slowing down this week will help.');
    case 'KEEP_CURRENT_HABITS':
    default:
      return (headline: "You're on track", detail: 'Keep your current pace.');
  }
}
