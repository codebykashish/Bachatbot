import firebase_admin
from firebase_admin import credentials, firestore
from datetime import datetime

try:
    firebase_admin.get_app()
except ValueError:
    cred = credentials.Certificate(r'backend\serviceAccountKey.json')
    firebase_admin.initialize_app(cred)

db = firestore.client()
users = list(db.collection('users').limit(1).stream())
if users:
    uid = users[0].id
    doc = users[0].to_dict()
    print('Income:', doc.get('income'))
    
    # Get current month
    now = datetime.now()
    month_key = f"{now.year}-{now.month:02d}"
    print(f'\nMonth Key: {month_key}')

    budgets = db.collection('users').document(uid).collection('budgets').where('monthKey', '==', month_key).stream()
    total_limits = 0
    print('\nBudgets:')
    for b in budgets:
        bd = b.to_dict()
        print(' -', bd.get('category'), 'limit:', bd.get('limit'))
        total_limits += float(bd.get('limit') or 0)
    print('\nTotal limits:', total_limits)
else:
    print('No users found')
