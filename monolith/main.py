"""
FlashOrder Monolith - Python FastAPI
Single-process, synchronous order handling with SQLite in-memory DB.
Used as comparison baseline against the microservices architecture.
"""

import sqlite3
import uuid
import time
from contextlib import contextmanager
from datetime import datetime
from typing import List, Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------

app = FastAPI(
    title="FlashOrder Monolith",
    description="Synchronous monolith for architecture comparison",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# In-memory SQLite database
# ---------------------------------------------------------------------------

DB_PATH = ":memory:"

# Use a module-level connection so the in-memory DB persists across requests
_conn: sqlite3.Connection = sqlite3.connect(DB_PATH, check_same_thread=False)
_conn.row_factory = sqlite3.Row


def init_db() -> None:
    with _conn:
        _conn.execute(
            """
            CREATE TABLE IF NOT EXISTS orders (
                id          TEXT PRIMARY KEY,
                customerName TEXT NOT NULL,
                productName  TEXT NOT NULL,
                amount       REAL NOT NULL,
                status       TEXT NOT NULL DEFAULT 'PENDING',
                createdAt    TEXT NOT NULL
            )
            """
        )


@contextmanager
def get_db():
    try:
        yield _conn
    except Exception:
        _conn.rollback()
        raise


# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------


class OrderRequest(BaseModel):
    customerName: str = Field(..., min_length=1, example="Nguyen Van A")
    productName: str = Field(..., min_length=1, example="iPhone 15 Pro")
    amount: float = Field(..., gt=0, example=29990000.0)


class OrderResponse(BaseModel):
    id: str
    customerName: str
    productName: str
    amount: float
    status: str
    createdAt: str


class HealthResponse(BaseModel):
    status: str
    service: str
    timestamp: str
    uptime_seconds: float


# ---------------------------------------------------------------------------
# Startup / shutdown
# ---------------------------------------------------------------------------

_start_time = time.time()


@app.on_event("startup")
def startup_event():
    init_db()
    print("[MonolithDB] SQLite in-memory database initialised ✓")


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/health", response_model=HealthResponse, tags=["ops"])
def health():
    return HealthResponse(
        status="UP",
        service="flashorder-monolith",
        timestamp=datetime.utcnow().isoformat() + "Z",
        uptime_seconds=round(time.time() - _start_time, 2),
    )


@app.post("/orders", response_model=OrderResponse, status_code=201, tags=["orders"])
def create_order(payload: OrderRequest):
    """
    Synchronous order creation — no message queue, no async workers.
    Everything happens in one transaction inside one process.
    """
    order_id = str(uuid.uuid4())
    created_at = datetime.utcnow().isoformat() + "Z"

    with get_db() as db:
        db.execute(
            """
            INSERT INTO orders (id, customerName, productName, amount, status, createdAt)
            VALUES (?, ?, ?, ?, 'PENDING', ?)
            """,
            (order_id, payload.customerName, payload.productName, payload.amount, created_at),
        )
        db.commit()

    return OrderResponse(
        id=order_id,
        customerName=payload.customerName,
        productName=payload.productName,
        amount=payload.amount,
        status="PENDING",
        createdAt=created_at,
    )


@app.get("/orders", response_model=List[OrderResponse], tags=["orders"])
def list_orders(limit: int = 50, offset: int = 0):
    """Return all orders, newest first."""
    with get_db() as db:
        rows = db.execute(
            "SELECT * FROM orders ORDER BY createdAt DESC LIMIT ? OFFSET ?",
            (limit, offset),
        ).fetchall()

    return [
        OrderResponse(
            id=row["id"],
            customerName=row["customerName"],
            productName=row["productName"],
            amount=row["amount"],
            status=row["status"],
            createdAt=row["createdAt"],
        )
        for row in rows
    ]


@app.get("/orders/{order_id}", response_model=OrderResponse, tags=["orders"])
def get_order(order_id: str):
    with get_db() as db:
        row = db.execute(
            "SELECT * FROM orders WHERE id = ?", (order_id,)
        ).fetchone()

    if not row:
        raise HTTPException(status_code=404, detail=f"Order {order_id} not found")

    return OrderResponse(
        id=row["id"],
        customerName=row["customerName"],
        productName=row["productName"],
        amount=row["amount"],
        status=row["status"],
        createdAt=row["createdAt"],
    )


# ---------------------------------------------------------------------------
# Entry point (for local dev without Docker)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8090, reload=True)
