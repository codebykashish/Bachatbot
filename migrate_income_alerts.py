import os
import firebase_admin
from firebase_admin import credentials, firestore
from google.cloud.firestore_v1.base_query import FieldFilter

def migrate_income_alerts():
    # Initialize Firebase if not already initialized
    if not firebase_admin._apps:
        # Assuming credentials are provided via environment or serviceAccountKey.json
        cred_path = "serviceAccountKey.json"
        if os.path.exists(cred_path):
            cred = credentials.Certificate(cred_path)
            firebase_admin.initialize_app(cred)
        else:
            firebase_admin.initialize_app()
    
    db = firestore.client()
    
    print("Starting migration: Fixing income notification messages...")
    
    # 1. Get all users
    users_ref = db.collection("users")
    users = users_ref.stream()
    
    total_fixed = 0
    
    for user in users:
        uid = user.id
        # 2. Query alerts for this user where type == 'income'
        alerts_ref = db.collection("users").document(uid).collection("alerts")
        income_alerts = (
            alerts_ref
            .where(filter=FieldFilter("type", "==", "income"))
            .stream()
        )
        
        for alert_doc in income_alerts:
            alert_data = alert_doc.to_dict()
            message = alert_data.get("message", "")
            
            # Check if it incorrectly mentions "expense saved"
            if "expense saved" in message:
                new_message = message.replace("expense saved", "income added")
                
                # Update the document
                alert_doc.reference.update({
                    "message": new_message
                })
                
                print(f"Fixed alert {alert_doc.id} for user {uid}: '{message}' -> '{new_message}'")
                total_fixed += 1
            
            # Also handle "confirmed from notification" for income
            elif "confirmed from notification" in message:
                 new_message = message.replace("confirmed from notification", "added from notification")
                 
                 # Update the document
                 alert_doc.reference.update({
                     "message": new_message
                 })
                 
                 print(f"Fixed alert {alert_doc.id} for user {uid}: '{message}' -> '{new_message}'")
                 total_fixed += 1

    print(f"Migration complete. Total alerts fixed: {total_fixed}")

if __name__ == "__main__":
    migrate_income_alerts()
