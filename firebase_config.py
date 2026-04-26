import firebase_admin
from firebase_admin import credentials, firestore
import os
import json

_app = None

def initialize_firebase():
    global _app
    if _app is None:
        cred = None
        
        # Local FIRST
        if os.path.exists("serviceAccountKey.json"):
            cred = credentials.Certificate("serviceAccountKey.json")
            print("✅ Local serviceAccountKey.json")
        
        # Railway SECOND
        elif os.getenv("FIREBASE_SERVICE_ACCOUNT"):
            service_account = json.loads(os.getenv("FIREBASE_SERVICE_ACCOUNT"))
            cred = credentials.Certificate(service_account)
            print("✅ Railway env")
        
        if cred is None:
            raise Exception("Missing serviceAccountKey.json or FIREBASE_SERVICE_ACCOUNT env")
        
        _app = firebase_admin.initialize_app(cred)
        print("✅ Firebase initialized")

def get_firestore():
    # Returns Firestore database client
    return firestore.client()