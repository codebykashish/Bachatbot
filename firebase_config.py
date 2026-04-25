import firebase_admin
from firebase_admin import credentials, firestore

import json
import os
cred = credentials.Certificate(json.loads(os.getenv('FIREBASE_SERVICE_ACCOUNT')))

# This runs only once when app starts
# It connects to your Firebase project

_app = None

def initialize_firebase():
    global _app
    if _app is None:
        cred = credentials.Certificate("serviceAccountKey.json")
        _app = firebase_admin.initialize_app(cred)
        print("✅ Firebase initialized successfully")

def get_firestore():
    # Returns Firestore database client
    return firestore.client()