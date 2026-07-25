import 'package:flutter/material.dart';
import '../widgets/chat_fab.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const Color _primary = Color(0xFF2DBE7F);

  // ── Quick tips shown as horizontal scroll cards at the top ───────────────
  static const List<Map<String, String>> _tips = [
    {
      'icon': 'chat',
      'title': 'Chat to log',
      'body': 'Type naturally — "Momo 250" or "Bus 40 gayo" — BachatBot handles the rest',
    },
    {
      'icon': 'edit_note',
      'title': 'Add manually',
      'body': 'Categories → tap any category → Add Expense form for quick manual entry',
    },
    {
      'icon': 'bar_chart',
      'title': 'View reports',
      'body': 'Tap Reports in the bottom bar for your full monthly breakdown',
    },
    {
      'icon': 'notifications',
      'title': 'Tap alerts',
      'body': 'Each notification card links directly to its category page',
    },
    {
      'icon': 'undo',
      'title': 'Undo entries',
      'body': 'Tap the orange Undo button on any expense or income card to reverse it instantly',
    },
  ];

  // ── Help items ───────────────────────────────────────────────────────────
  static const List<Map<String, String>> _items = [
    // Getting Started
    {
      'section': 'Getting Started',
      'icon': 'edit_note',
      'title': 'Log your first expense',
      'content':
          'Open the Chat screen and type naturally:\n'
          '• "Momo 250"\n'
          '• "Bus bhada 40 tiryo"\n'
          '• "Bhatbhateni ma 3400 shopping gareko"\n\n'
          'BachatBot confirms the amount and category, then saves it. '
          'That\'s it — no forms, no dropdowns.',
    },
    {
      'section': 'Getting Started',
      'icon': 'attach_money',
      'title': 'Declare your monthly income',
      'content':
          'Go to the Income screen (Profile → My Income, or tap the Income card on Home).\n\n'
          'Enter how much you earn — in hand, in bank, or via online banking. '
          'This lets BachatBot calculate your true net savings on the Categories screen.',
    },
    {
      'section': 'Getting Started',
      'icon': 'tune',
      'title': 'Set up your first budget',
      'content':
          'Two ways:\n'
          '1. Chat: "Set my food budget to 5000" or "Change rent to 12k"\n'
          '2. Categories screen → tap any category → tap the Edit button\n\n'
          'Once set, BachatBot will alert you when you\'re approaching the limit.',
    },
    // Chat & Transactions
    {
      'section': 'Chat & Transactions',
      'icon': 'undo',
      'title': 'Undo a logged expense',
      'content':
          'In the chat, say:\n'
          '• "Undo last expense"\n'
          '• "Food ko last kharcha hatau"\n'
          '• "Delete last"\n\n'
          'BachatBot finds and removes the most recent matching transaction. '
          'You can also delete any transaction by long-pressing it in the Transactions screen.',
    },
    {
      'section': 'Chat & Transactions',
      'icon': 'hourglass_empty',
      'title': 'Understanding pending transactions',
      'content':
          'When a bank SMS arrives (eSewa, Khalti, etc.), the transaction shows as pending until you confirm.\n\n'
          '• Say "Yes" or "Ho" to confirm → saved and counted in your budget\n'
          '• Say "No" to reject → discarded\n\n'
          'Pending transactions do not affect your budget until confirmed.',
    },
    {
      'section': 'Chat & Transactions',
      'icon': 'format_list_bulleted',
      'title': 'Log multiple expenses at once',
      'content':
          'You can mention multiple expenses in one message:\n'
          '• "200 momo, 20 bus ma kharcha bhayo"\n'
          '• "Lunch 350 ra coffee 80"\n\n'
          'BachatBot extracts each transaction separately and shows a confirmation for each one.',
    },
    // Categories & Budgets
    {
      'section': 'Categories & Budgets',
      'icon': 'edit',
      'title': 'Edit or update a budget',
      'content':
          'Tap any category on the Categories screen → tap the green Edit button.\n\n'
          'The sheet shows:\n'
          '• Current spending for this month\n'
          '• Available to save (how much you haven\'t budgeted yet)\n\n'
          'You cannot set a budget lower than what you\'ve already spent this month.',
    },
    {
      'section': 'Categories & Budgets',
      'icon': 'savings',
      'title': 'Understanding your savings',
      'content':
          'The savings banner at the bottom of Categories shows your true net savings:\n\n'
          '• With declared income: Savings = Declared Income − Total Spent\n'
          '• Without income: Savings = Total Budget − Total Spent\n\n'
          'To get accurate savings, always declare your income in the Income screen.',
    },
    {
      'section': 'Categories & Budgets',
      'icon': 'pie_chart_outline',
      'title': 'Available to save explained',
      'content':
          'When you open the budget edit sheet, it shows "Available Rs X". '
          'This is your declared income minus all other category budgets you\'ve already set.\n\n'
          'It helps you see how much you still have left to allocate across categories.',
    },
    // Reports & Insights
    {
      'section': 'Reports & Insights',
      'icon': 'bar_chart',
      'title': 'View your monthly report',
      'content':
          'Tap "Reports" in the bottom navigation bar.\n\n'
          'You\'ll see:\n'
          '• Total income & total expense\n'
          '• Net savings for the month\n'
          '• Spending breakdown by category\n'
          '• Overall spending status (Low / Medium / High)\n\n'
          'Use the arrow buttons to navigate between months.',
    },
    {
      'section': 'Reports & Insights',
      'icon': 'traffic',
      'title': 'What Low / Medium / High means',
      'content':
          'Your overall spending status is color-coded:\n\n'
          '🟢 Low (green) — spending is well within budget, keep it up!\n'
          '🟡 Medium (yellow) — getting close to your limits, stay mindful\n'
          '🔴 High / Overspent (red) — at or over budget, time to review\n\n'
          'This appears on the Reports screen as the "Overall Status" card.',
    },
    // Notifications & Alerts
    {
      'section': 'Notifications & Alerts',
      'icon': 'notifications',
      'title': 'Use the Activity feed',
      'content':
          'The Activity screen (bell icon in the top bar) shows all your alerts:\n\n'
          '• Tap any card to mark it as read\n'
          '• Budget and expense alerts take you directly to that category\n'
          '• Income alerts are just marked read\n\n'
          'Use the filters at the top to narrow by type, time, or category.',
    },
    {
      'section': 'Notifications & Alerts',
      'icon': 'sms',
      'title': 'Set up bank notification sync',
      'content':
          'BachatBot listens to SMS from eSewa, Khalti, IME Pay, and Nepali banks in the background.\n\n'
          'Grant notification access when prompted at app launch. '
          'Once enabled, all digital payments are auto-detected and sent to the chat for confirmation.',
    },
    // Account & Privacy
    {
      'section': 'Account & Privacy',
      'icon': 'camera_alt',
      'title': 'Change your profile photo',
      'content':
          'Go to Profile → tap the camera icon on your avatar.\n\n'
          'Choose:\n'
          '• "Upload from Gallery" — pick an existing photo\n'
          '• "Take Photo" — use your camera\n\n'
          'The photo is saved to your account and appears everywhere in the app.',
    },
    {
      'section': 'Account & Privacy',
      'icon': 'badge',
      'title': 'Update your name',
      'content':
          'Go to Profile → tap "Edit Profile".\n\n'
          'You can update both First Name and Last Name. Tap "Save Changes" when done. '
          'Your updated name appears immediately in the profile header.',
    },
    {
      'section': 'Account & Privacy',
      'icon': 'logout',
      'title': 'Log out',
      'content':
          'Scroll to the bottom of the Profile screen and tap "Logout" (shown in red).\n\n'
          'You\'ll be signed out and returned to the login screen. '
          'Your data is safely stored and will be there when you log back in.',
    },
  ];

  IconData _iconFor(String name) {
    switch (name) {
      case 'chat':                return Icons.chat_bubble_outline_rounded;
      case 'edit_note':           return Icons.edit_note_rounded;
      case 'attach_money':        return Icons.attach_money_rounded;
      case 'tune':                return Icons.tune_rounded;
      case 'undo':                return Icons.undo_rounded;
      case 'hourglass_empty':     return Icons.hourglass_empty_rounded;
      case 'format_list_bulleted': return Icons.format_list_bulleted_rounded;
      case 'edit':                return Icons.edit_outlined;
      case 'savings':             return Icons.savings_outlined;
      case 'pie_chart_outline':   return Icons.pie_chart_outline_rounded;
      case 'bar_chart':           return Icons.bar_chart_rounded;
      case 'traffic':             return Icons.traffic_outlined;
      case 'notifications':       return Icons.notifications_outlined;
      case 'sms':                 return Icons.sms_outlined;
      case 'camera_alt':          return Icons.camera_alt_outlined;
      case 'badge':               return Icons.badge_outlined;
      case 'logout':              return Icons.logout_rounded;
      default:                    return Icons.help_outline;
    }
  }

  Color _sectionColor(String s) {
    switch (s) {
      case 'Getting Started':         return _primary;
      case 'Chat & Transactions':     return const Color(0xFF7C4DFF);
      case 'Categories & Budgets':    return const Color(0xFF2196F3);
      case 'Reports & Insights':      return const Color(0xFFF59E0B);
      case 'Notifications & Alerts':  return const Color(0xFFEF6C00);
      default:                        return const Color(0xFF009688);
    }
  }

  IconData _sectionIcon(String s) {
    switch (s) {
      case 'Getting Started':         return Icons.rocket_launch_outlined;
      case 'Chat & Transactions':     return Icons.chat_bubble_outline_rounded;
      case 'Categories & Budgets':    return Icons.account_balance_wallet_outlined;
      case 'Reports & Insights':      return Icons.bar_chart_rounded;
      case 'Notifications & Alerts':  return Icons.notifications_outlined;
      default:                        return Icons.shield_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Group items preserving original section order
    final sections = <String>[];
    final grouped = <String, List<Map<String, String>>>{};
    for (final item in _items) {
      final s = item['section']!;
      if (!grouped.containsKey(s)) {
        sections.add(s);
        grouped[s] = [];
      }
      grouped[s]!.add(item);
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('Help & Guide',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          // ── Quick Tips banner ─────────────────────────────────────────────
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 12, 0, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 16, bottom: 10),
                  child: Row(
                    children: [
                      const Text(
                        'Quick Tips',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF22252A)),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: _primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 118,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _tips.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (ctx, i) {
                      final tip = _tips[i];
                      return Container(
                        width: 155,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _primary.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: _primary.withValues(alpha: 0.15)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Icon(_iconFor(tip['icon']!), size: 16, color: _primary),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    tip['title']!,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF22252A),
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              tip['body']!,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade600,
                                height: 1.5,
                              ),
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // ── Sections ──────────────────────────────────────────────────────
          ...sections.map((section) {
            final items = grouped[section]!;
            final color = _sectionColor(section);
            final sIcon = _sectionIcon(section);

            return Padding(
              padding:
                  const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Section header
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 8, top: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(sIcon, color: color, size: 16),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          section,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Help items card
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Theme(
                      data: Theme.of(context)
                          .copyWith(dividerColor: Colors.transparent),
                      child: Column(
                        children: items.asMap().entries.map((e) {
                          final isLast = e.key == items.length - 1;
                          final item = e.value;
                          final itemIcon = _iconFor(item['icon'] ?? 'help');

                          return Column(
                            children: [
                              ExpansionTile(
                                leading: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.10),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(itemIcon, color: color, size: 17),
                                ),
                                title: Text(
                                  item['title']!,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF22252A),
                                  ),
                                ),
                                iconColor: color,
                                collapsedIconColor: Colors.grey.shade400,
                                expandedAlignment: Alignment.topLeft,
                                childrenPadding:
                                    const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                children: [
                                  Divider(height: 1, color: Colors.grey.shade100),
                                  const SizedBox(height: 10),
                                  Text(
                                    item['content']!,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: Colors.grey.shade600,
                                      height: 1.75,
                                    ),
                                  ),
                                ],
                              ),
                              if (!isLast)
                                Divider(
                                    height: 1,
                                    indent: 16,
                                    endIndent: 16,
                                    color: Colors.grey.shade100),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),

          const SizedBox(height: 16),
        ],
      ),
      floatingActionButton: const ChatFab(),
    );
  }
}
