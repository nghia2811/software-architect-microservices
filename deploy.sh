#!/bin/bash
set -e

echo "=== Microservices Deployment ==="
echo "Registry : $REGISTRY"
echo "Image Tag: $IMAGE_TAG"
echo ""

# ── 1. Log in to GHCR ──
echo "→ Logging in to GitHub Container Registry..."
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

# ── 2. Pull latest images ──
echo "→ Pulling images..."
docker pull "$REGISTRY/order-service:$IMAGE_TAG"
docker pull "$REGISTRY/notification-service:$IMAGE_TAG"
docker pull "$REGISTRY/frontend:$IMAGE_TAG"

# ── 3. Export env vars for docker compose ──
export REGISTRY="$REGISTRY"
export IMAGE_TAG="$IMAGE_TAG"
export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"

# ── 4. Restart services (zero-downtime for stateless services) ──
echo "→ Updating services..."
docker compose -f docker-compose.yaml -f docker-compose.prod.yml up -d \
  --no-build \
  --remove-orphans

# ── 5. Wait for health checks ──
echo "→ Waiting for services to become healthy..."
sleep 15

# ── 6. Verify deployment ──
echo "→ Checking service status..."
docker compose -f docker-compose.yaml -f docker-compose.prod.yml ps

# ── 7. Clean up dangling images ──
echo "→ Cleaning up old images..."
docker image prune -f

echo ""
echo "=== Deployment complete ==="
