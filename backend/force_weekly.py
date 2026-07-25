import os
import sys
from datetime import datetime, date, timedelta, timezone
import firebase_admin
from firebase_admin import credentials, firestore

# Initialize Firebase
cred = credentials.Certificate(r'serviceAccountKey.json')
try:
    firebase_admin.get_app()
except ValueError:
    firebase_admin.initialize_app(cred)

db = firestore.client()
uid = 'kWfWSHeVu1gy6CibG48IJlET5aZ2'

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from services.weekly_reflection_service import generate_weekly_reflection

today = date.today()
this_monday = today - timedelta(days=today.weekday())

# Generate for LAST week (what the live API endpoint currently looks for)
last_week_start = this_monday - timedelta(days=7)
last_week_end = last_week_start + timedelta(days=6)

# Also generate for THIS week (what the patched API will look for after restart)
this_week_start = this_monday
this_week_end = this_week_start + timedelta(days=6)

print(f"Today: {today}, This Monday: {this_monday}")
print(f"Generating for LAST week: {last_week_start} to {last_week_end}")
print(f"Generating for THIS week: {this_week_start} to {this_week_end}")

for ws, we, label in [(last_week_start, last_week_end, "Last week"), (this_week_start, this_week_end, "This week")]:
    try:
        result = generate_weekly_reflection(db, uid, ws, we)
        print(f"[OK] {label} ({ws}): reflection generated/found")
    except Exception as e:
        print(f"[FAIL] {label} ({ws}): {e}")

print("Done! Both week reflections are now in Firestore.")
