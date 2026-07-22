import sys
sys.path.insert(0, '.')
from firebase_config import get_firestore, initialize_firebase
from services.financial_engine import get_summary

initialize_firebase()
db = get_firestore()
UID = 'BDpx6it7MeSZSrUJEBu9Bbwfp8l1'
month_key = '2026-07'

print('=== RAW budgets (source of truth) ===')
docs = db.collection('users').document(UID).collection('budgets').where('monthKey', '==', month_key).stream()
for d in docs:
    data = d.to_dict()
    cat = data.get('category')
    limit = data.get('limit', 0)
    spent = data.get('spent', 0)
    print(cat + ': limit=' + str(limit) + ' spent=' + str(spent))

print()
print('=== CACHED financialSummary (what screens actually read) ===')
summary = get_summary(db, UID, month_key)
for cat, info in summary.get('categoryRemaining', {}).items():
    print(cat + ': limit=' + str(info['limit']) + ' spent=' + str(info['spent']) + ' remaining=' + str(info['remaining']))

print()
print('=== Education rebalances (latest 5) ===')
docs = list(db.collection('users').document(UID).collection('pending_rebalances').stream())
edu_docs = [d for d in docs if d.to_dict().get('overspentCategory') == 'Education']
for d in sorted(edu_docs, key=lambda d: str(d.to_dict().get('createdAt')), reverse=True)[:5]:
    data = d.to_dict()
    print('id=' + d.id + ' status=' + str(data.get('status')) + ' oldLimit=' + str(data.get('oldLimit')) + ' covered=' + str(data.get('totalCovered')) + ' createdAt=' + str(data.get('createdAt')))
