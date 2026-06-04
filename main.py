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

# ── Scheduler Setup ──────────────────────────────────────────────────────────
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
from services.budget_service import run_month_rollover, run_pre_month_end_reminder

scheduler = BackgroundScheduler()

# 1. Monthly Rollover: Run at 00:01 on the 1st day of every month
scheduler.add_job(
    run_month_rollover,
    CronTrigger(day=1, hour=0, minute=1),
    id="monthly_rollover",
    name="Compute last month spend and set new budgets",
    replace_existing=True
)

# 2. Pre-month-end Reminder: Run at 10:00 AM on the 28th of every month
# (Simple approximation of 1-2 days before month end)
scheduler.add_job(
    run_pre_month_end_reminder,
    CronTrigger(day=28, hour=10, minute=0),
    id="pre_month_reminder",
    name="Remind users to set upcoming budget",
    replace_existing=True
)

scheduler.start()
logger.info("[SCHEDULER] Started BackgroundScheduler with 2 jobs")


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
    # ── Fix 1: Normalize double-slash paths (//chat → /chat) ─────────────
    # Happens when Flutter baseUrl ends with "/" and endpoint starts with "/".
    raw_path = request.scope.get("path", "")
    if raw_path.startswith("//"):
        fixed_path = "/" + raw_path.lstrip("/")
        request.scope["path"] = fixed_path
        print(f"[MIDDLEWARE] Normalised path: '{raw_path}' → '{fixed_path}'")

    uid = "anonymous"
    try:
        current_user = await get_current_user(request)
        uid = current_user.get("uid", "unknown")
    except Exception:
        pass

    if request.method == "POST":
        # ── Fix 2: Use request.body() which caches in request._body ──────
        # Do NOT set request._receive manually — that custom closure always
        # returns http.request, breaking Starlette's disconnect detection
        # and causing: RuntimeError: Unexpected message received: http.request
        body_bytes = await request.body()   # safe to call; result is cached
        try:
            body_str = body_bytes.decode("utf-8")[:500]
        except Exception:
            body_str = str(body_bytes)[:500]
        print(f"[REQ] {request.method} {request.scope['path']} uid={uid} body={body_str}")
    else:
        print(f"[REQ] {request.method} {request.scope['path']} uid={uid}")

    response = await call_next(request)
    print(f"[RES] {response.status_code} {request.scope['path']} uid={uid}")
    return response


# Import and include all routes
from routes.signup import router as signup_router
from routes.profile import profile_router
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
        "message": "BachatBot API is running",
        "version": "1.0.0"
    }


@app.get("/health")
async def health():
    return {
        "success": True,
        "status": "healthy"
    }
