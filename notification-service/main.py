import asyncio
import json
import os
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
import redis.asyncio as aioredis

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))


class ConnectionManager:
    def __init__(self):
        self.active_connections: list[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)
        logger.info(f"WebSocket client connected. Total: {len(self.active_connections)}")

    def disconnect(self, websocket: WebSocket):
        if websocket in self.active_connections:
            self.active_connections.remove(websocket)
        logger.info(f"WebSocket client disconnected. Total: {len(self.active_connections)}")

    async def broadcast(self, message: str):
        disconnected = []
        for connection in self.active_connections:
            try:
                await connection.send_text(message)
            except Exception:
                disconnected.append(connection)
        for conn in disconnected:
            self.disconnect(conn)


manager = ConnectionManager()


async def redis_subscriber():
    """
    Subscribes to Redis channel 'order_events' and broadcasts
    each received message to all connected WebSocket clients.
    Automatically reconnects on failure.
    """
    while True:
        try:
            redis = aioredis.from_url(f"redis://{REDIS_HOST}:{REDIS_PORT}")
            pubsub = redis.pubsub()
            await pubsub.subscribe("order_events")
            logger.info(f"[Redis Subscriber] Connected to redis://{REDIS_HOST}:{REDIS_PORT}, listening on 'order_events'...")

            async for message in pubsub.listen():
                if message["type"] == "message":
                    data = json.loads(message["data"])
                    log_msg = f"[Redis Subscriber] Đã nhận đơn hàng #{data['orderId']} cho khách hàng {data['customerName']}"
                    logger.info(log_msg)
                    await manager.broadcast(json.dumps(data))

        except Exception as e:
            logger.error(f"[Redis Subscriber] Connection error: {e}. Retrying in 5s...")
            await asyncio.sleep(5)


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(redis_subscriber())
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


app = FastAPI(title="Notification Service", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health():
    return {"status": "ok", "service": "notification-service"}


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            # Keep connection alive, receive any client pings
            await websocket.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(websocket)
