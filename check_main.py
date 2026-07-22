import sys
sys.path.insert(0, '.')
from firebase_config import get_firestore, initialize_firebase
from services.financial_engine import get_summary

initialize_firebase()
db = get_firestore()
UID = 'BDpx6it7MeSZSrUJEBu9Bbwfp8l1'
month_key = '2026-07'

summary = get_summary(db, UID, month_key)

print('=== TOP LEVEL summary fields ===')
for k, v in summary.items():
    if k != 'categoryRemaining' and k != 'goalProgress' and k != 'decisionLog':
        print(k + ' = ' + str(v))

print()
print('=== categoryRemaining ===')
total_limit = 0
total_spent = 0
for cat, info in summary.get('categoryRemaining', {}).items():
    limit = info['limit']
    spent = info['spent']
    total_limit += limit
    total_spent += spent
    print(cat + ': limit=' + str(limit) + ' spent=' + str(spent))

print()
print('Sum of all category limits = ' + str(total_limit))
print('Sum of all category spent  = ' + str(total_spent))
print()
print('=== savings / income ===')
print('totalIncome       = ' + str(summary.get('totalIncome')))
print('totalBudgeted     = ' + str(summary.get('totalBudgeted')))
print('totalSpent        = ' + str(summary.get('totalSpent')))
print('savingsPool       = ' + str(summary.get('savingsPool')))
print('savingsUsed       = ' + str(summary.get('savingsUsed')))
print('netSavings        = ' + str(summary.get('netSavings')))
print('overallRemaining  = ' + str(summary.get('overallRemaining')))
