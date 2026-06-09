import os
import asyncio
from dotenv import load_dotenv
from firebase_config import get_firestore, initialize_firebase

load_dotenv()

async def migrate_alerts():
    initialize_firebase()
    db = get_firestore()
    users_ref = db.collection("users").stream()
    
    updated_count = 0
    for user_doc in users_ref:
        uid = user_doc.id
        alerts_ref = db.collection("users").document(uid).collection("alerts").stream()
        
        for alert_doc in alerts_ref:
            alert = alert_doc.to_dict()
            t = alert.get("type")
            msg = alert.get("message", "").lower()
            
            # If type is not 'expense' and not 'income', we migrate it
            if t not in ("expense", "income"):
                new_type = "expense"
                new_msg = alert.get("message")
                
                # Deduce type from message
                if "income saved" in msg or "income added" in msg:
                    new_type = "income"
                    if "expense saved" in msg:
                        new_msg = alert.get("message").replace("expense saved", "income added").replace("Expense saved", "Income added")
                elif "expense saved" in msg:
                    new_type = "expense"
                elif "budget" in msg:
                    new_type = "budget"
                
                db.collection("users").document(uid).collection("alerts").document(alert_doc.id).update({
                    "type": new_type,
                    "message": new_msg
                })
                updated_count += 1
                print(f"Updated alert {alert_doc.id} for user {uid} to type {new_type}")

    print(f"Migration complete. Updated {updated_count} alerts.")

if __name__ == "__main__":
    asyncio.run(migrate_alerts())
