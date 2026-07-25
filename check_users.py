import firebase_admin
from firebase_admin import credentials, firestore
try:
    firebase_admin.get_app()
except ValueError:
    cred = credentials.Certificate(r'backend\serviceAccountKey.json')
    firebase_admin.initialize_app(cred)

db = firestore.client()
users = list(db.collection('users').stream())
print(f'Found {len(users)} users')
for u in users:
    d = u.to_dict()
    name = d.get('firstName', d.get('name', 'Unknown'))
    income = d.get('income', {})
    total = income.get('inHand', 0) + income.get('inBank', 0) + income.get('onlineBanking', 0)
    print(f'User: {name}, ID: {u.id}, Total Income: {total}')
