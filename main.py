import os
from dotenv import load_dotenv
load_dotenv()
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from firebase_config import initialize_firebase

# Initialize Firebase when app starts
initialize_firebase()

# Create FastAPI app
app = FastAPI(
    title="BachatBot API",
    description="Backend API for BachatBot - AI expense tracker",
    version="1.0.0"
)

# Allow Flutter to call this backend
# During development this allows all origins
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Import and include all routes
from routes.signup import router as signup_router
from routes.profile import router as profile_router
from routes.chat import router as chat_router
from routes.transactions import router as transactions_router
from routes.confirm import router as confirm_router
from routes.budgets import router as budgets_router
from routes.reports import router as reports_router
from routes.alerts import router as alerts_router
from routes.messages import router as messages_router

app.include_router(signup_router)
app.include_router(profile_router)
app.include_router(chat_router)
app.include_router(transactions_router)
app.include_router(confirm_router)
app.include_router(budgets_router)
app.include_router(reports_router)
app.include_router(alerts_router)
app.include_router(messages_router)


# Health check - test if server is running
@app.get("/")
async def root():
    return {
        "success": True,
        "message": "BachatBot API is running ✅",
        "version": "1.0.0"
    }


@app.get("/health")
async def health():
    return {
        "success": True,
        "status": "healthy"
    }

