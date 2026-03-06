# Microservices Demo — Order & Real-time Notification

A minimal microservices system demonstrating **Loose Coupling** via Redis Pub/Sub, real-time WebSocket notifications, and a health dashboard.

## Architecture

```
Browser (3000)
   │  POST /orders          WebSocket (ws://localhost:8082/ws)
   ▼                                   ▲
Order Service (8081)                   │
   │  Java Spring Boot                 │
   │  PostgreSQL                       │
   │                                   │
   └──► Redis Pub/Sub ──► Notification Service (8082)
        channel:              Python FastAPI
        order_events          Redis Subscriber
```

## Tech Stack

| Layer | Technology |
|---|---|
| Order Service | Java 21, Spring Boot 3.2, Spring Data JPA |
| Database | PostgreSQL 15 |
| Message Broker | Redis 7 (Pub/Sub) |
| Notification Service | Python 3.12, FastAPI, asyncio |
| Frontend | Next.js 14 (App Router), TypeScript |
| Infrastructure | Docker Compose |

## Project Structure

```
.
├── docker-compose.yaml
├── order-service/               # Java Spring Boot (port 8081)
│   ├── Dockerfile
│   ├── pom.xml
│   └── src/main/java/com/example/orderservice/
│       ├── controller/OrderController.java
│       ├── service/OrderService.java   <- Redis Publisher
│       ├── model/Order.java
│       ├── repository/OrderRepository.java
│       └── config/CorsConfig.java
├── notification-service/        # Python FastAPI (port 8082)
│   ├── Dockerfile
│   ├── requirements.txt
│   └── main.py                  <- Redis Subscriber + WebSocket
└── frontend/                    # Next.js (port 3000)
    ├── Dockerfile
    ├── next.config.js
    └── src/app/
        ├── page.tsx             <- Order form + Health dashboard
        └── globals.css
```

## Quick Start

```bash
docker compose up --build
```

| URL | Description |
|---|---|
| http://localhost:3000 | Frontend (order form + health dashboard) |
| http://localhost:8081/actuator/health | Order Service health |
| http://localhost:8082/health | Notification Service health |
| ws://localhost:8082/ws | WebSocket endpoint |

## API

### Create Order

```bash
curl -X POST http://localhost:8081/orders \
  -H "Content-Type: application/json" \
  -d '{"customerName":"Nguyen Van A","productName":"iPhone 15","amount":29990000}'
```

## Watch Real-time Logs

```bash
# See the full message flow: Order Service -> Redis -> Notification Service
docker compose logs -f order-service notification-service
```

Expected output:
```
order-service-1        | [Redis Publisher] Published event to 'order_events': {"orderId":1,...}
notification-service-1 | [Redis Subscriber] Da nhan don hang #1 cho khach hang Nguyen Van A
```

## Features

- `POST /orders` saves to PostgreSQL, then publishes to Redis `order_events`
- Redis Pub/Sub decouples Order Service from Notification Service
- WebSocket broadcasts events to all connected browser clients in real time
- Toast notifications appear on the frontend immediately
- Health dashboard polls service status every 5 seconds
- WebSocket client auto-reconnects on disconnect
- Docker health checks enforce correct startup order
