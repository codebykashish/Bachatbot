"""
Firebase Migration Script
Migrates ALL Firestore data from OLD project (bachatbot2-64e23) to NEW project (bachatbot3).

Usage:
    python migrate_firebase.py

Requirements:
    - backend/old_serviceAccountKey.json  (old project key)
    - backend/serviceAccountKey.json      (new project key)
"""
import sys
import io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import firebase_admin
from firebase_admin import credentials, firestore
import time

# Initialize OLD app
old_cred = credentials.Certificate("backend/old_serviceAccountKey.json")
old_app  = firebase_admin.initialize_app(old_cred, name="old")
old_db   = firestore.client(app=old_app)

# Initialize NEW app
new_cred = credentials.Certificate("backend/serviceAccountKey.json")
new_app  = firebase_admin.initialize_app(new_cred, name="new")
new_db   = firestore.client(app=new_app)

print("[OK] Both Firebase projects connected")
print("     OLD: bachatbot2-64e23")
print("     NEW: bachatbot3")
print()

# Subcollections to migrate per user
USER_SUBCOLLECTIONS = [
    "budgets",
    "transactions",
    "goals",
    "messages",
    "alerts",
    "notifications",
    "income",
    "reports",
    "behavior",
    "weekly_reflection",
    "daily_snapshots",
    "monthly_summaries",
]

def copy_collection(old_ref, new_ref, label=""):
    """Copy all documents from old_ref to new_ref."""
    docs = list(old_ref.stream())
    if not docs:
        return 0

    count = 0
    for doc in docs:
        data = doc.to_dict()
        new_ref.document(doc.id).set(data)
        count += 1

    print(f"   [COPIED] {label}: {count} doc(s)")
    return count


# Migrate users
print("=" * 60)
print("MIGRATING USERS (Firestore)")
print("=" * 60)

users = list(old_db.collection("users").stream())
print(f"Found {len(users)} user(s) in old project\n")

total_docs = 0

for user_doc in users:
    uid  = user_doc.id
    data = user_doc.to_dict()
    name = data.get("firstName") or data.get("name") or "Unknown"
    email = data.get("email", "")

    print(f"[USER] {name} ({email}) [{uid}]")

    # Copy user document
    new_db.collection("users").document(uid).set(data)
    total_docs += 1

    # Copy all subcollections
    for sub in USER_SUBCOLLECTIONS:
        old_sub_ref = old_db.collection("users").document(uid).collection(sub)
        new_sub_ref = new_db.collection("users").document(uid).collection(sub)
        count = copy_collection(old_sub_ref, new_sub_ref, label=sub)
        total_docs += count

    print()
    time.sleep(0.2)  # small delay to avoid rate limits


# Summary
print("=" * 60)
print(f"[DONE] MIGRATION COMPLETE -- {total_docs} total documents copied")
print("=" * 60)
print()
print("[NOTE] Firebase Auth users are NOT migrated by this script.")
print("       Users need to reset their password in the new project,")
print("       OR use Firebase CLI to export/import auth users.")
print()
print("Firebase CLI Auth migration steps:")
print("  1. npm install -g firebase-tools")
print("  2. firebase login")
print("  3. firebase auth:export users.json --project bachatbot2-64e23")
print("  4. firebase auth:import users.json --project bachatbot3")
