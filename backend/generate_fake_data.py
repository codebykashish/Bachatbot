import os
import sys
import random
from datetime import datetime, date, timedelta, timezone
import firebase_admin
from firebase_admin import credentials, firestore

cred = credentials.Certificate(r'serviceAccountKey.json')
try:
    firebase_admin.get_app()
except ValueError:
    firebase_admin.initialize_app(cred)

db = firestore.client()
uid = 'kWfWSHeVu1gy6CibG48IJlET5aZ2'

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from services.financial_engine import recompute as engine_recompute, RecomputeReason
from services.weekly_reflection_service import generate_weekly_reflection

month_key = "2026-07"

print("Deleting old transactions...")
tx_ref = db.collection('users').document(uid).collection('transactions')
docs = tx_ref.stream()
batch = db.batch()
for doc in docs:
    batch.delete(doc.reference)
batch.commit()
print("Cleared old transactions.")

categories = {
    "Food": [("Lunch at work", 250), ("Dinner outside", 800), ("Groceries", 1500), ("Snacks", 100), ("Coffee", 150)],
    "Transport": [("Taxi to office", 400), ("Bus fare", 50), ("Petrol", 1000)],
    "Health": [("Medicine", 500), ("Consultation", 1200)],
    "Education": [("Stationery", 200), ("Online course", 1500)]
}

# The current week is Mon July 20 to Sun July 26
week_start = date(2026, 7, 20)
week_end = date(2026, 7, 26)

batch = db.batch()
count = 0

# Insert income on Monday July 20
income_time = datetime(2026, 7, 20, 10, 0, tzinfo=timezone.utc)
doc = tx_ref.document()
batch.set(doc, {
    "amount": 25000.0,
    "category": None,
    "description": "Salary",
    "createdAt": income_time,
    "monthKey": month_key,
    "source": "manual",
    "status": "confirmed",
    "type": "income",
    "incomeSource": "inBank",
    "isDeleted": False
})

# Insert expenses from July 20 to July 25 (today)
for day_offset in range(6):
    target_date = datetime(2026, 7, 20 + day_offset, tzinfo=timezone.utc)
    num_tx = random.randint(1, 3)
    
    for _ in range(num_tx):
        cat = random.choice(list(categories.keys()))
        desc, base_amt = random.choice(categories[cat])
        amount = base_amt + random.randint(-50, 100)
        
        tx_time = target_date.replace(hour=random.randint(9, 21), minute=random.randint(0, 59))
        
        doc = tx_ref.document()
        batch.set(doc, {
            "amount": float(amount),
            "category": cat,
            "description": desc,
            "createdAt": tx_time,
            "monthKey": month_key,
            "source": "chat",
            "status": "confirmed",
            "type": "expense",
            "isDeleted": False
        })
        count += 1

batch.commit()
print(f"Inserted {count} expenses and 1 income log perfectly within July 20-26.")

print("Recomputing financial summary...")
try:
    engine_recompute(db, uid, month_key, reason=RecomputeReason.MANUAL)
    print("Recompute successful!")
except Exception as e:
    print(f"Failed to recompute: {e}")

print(f'Generating Weekly Insight for {week_start} to {week_end}...')
try:
    generate_weekly_reflection(db, uid, week_start, week_end)
    print('Successfully generated weekly reflection!')
except Exception as e:
    print(f'Failed to generate weekly reflection: {e}')
