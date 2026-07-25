import sys
sys.path.insert(0, '.')
from firebase_config import get_firestore, initialize_firebase
from services.financial_engine import recompute, RecomputeReason, get_summary

initialize_firebase()
db = get_firestore()
UID = 'BDpx6it7MeSZSrUJEBu9Bbwfp8l1'
month_key = '2026-07'

print('Force-recomputing financialSummary from raw budgets...')
result = recompute(db, UID, month_key, reason=RecomputeReason.MANUAL)

print()
print('=== Updated cached summary ===')
for cat, info in result.get('categoryRemaining', {}).items():
    print(cat + ': limit=' + str(info['limit']) + ' spent=' + str(info['spent']) + ' remaining=' + str(info['remaining']))

print()
print('Verifying Health limit is now correct (should be 4910):')
health = result.get('categoryRemaining', {}).get('Health', {})
print('Health limit=' + str(health.get('limit')) + ' spent=' + str(health.get('spent')))
if health.get('limit') == 4910.0:
    print('PASS - Health limit correctly shows 4910')
else:
    print('STILL WRONG - Health limit is ' + str(health.get('limit')))
