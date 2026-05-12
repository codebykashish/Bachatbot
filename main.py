import os
import logging
from dotenv import load_dotenv
load_dotenv()
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from firebase_config import initialize_firebase

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
    datefmt="%H:%M:%S"
)
logger = logging.getLogger("bachatbot")

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


# ── Request Logging Middleware ──────────────────────────────────────────────
from auth import get_current_user

@app.middleware("http")
async def log_requests(request: Request, call_next):
    uid = "anonymous"
    try:
        current_user = await get_current_user(request)
        uid = current_user.get("uid", "unknown")
    except Exception:
        pass

    if request.method == "POST":
        body_bytes = await request.body()
        # Re-inject the body so downstream handlers can read it
        async def receive():
            return {"type": "http.request", "body": body_bytes}
        request._receive = receive
        try:
            body_str = body_bytes.decode("utf-8")
        except Exception:
            body_str = str(body_bytes)
        print(f"[REQ] {request.method} {request.url.path} uid={uid} body={body_str}")
    else:
        print(f"[REQ] {request.method} {request.url.path} uid={uid}")

    response = await call_next(request)
    print(f"[RES] {response.status_code} {request.url.path} uid={uid}")
    return response


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
from routes.verification import router as verification_router

app.include_router(signup_router)
app.include_router(profile_router)
app.include_router(chat_router)
app.include_router(transactions_router)
app.include_router(confirm_router)
app.include_router(budgets_router)
app.include_router(reports_router)
app.include_router(alerts_router)
app.include_router(messages_router)
app.include_router(verification_router)


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
