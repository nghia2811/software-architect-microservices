#!/bin/bash
# FlashOrder Platform - Auto Demo Launcher
# Double-click file này để khởi động demo

cd "$(dirname "$0")"

echo "=================================================="
echo "  FlashOrder Platform - Demo Launcher"
echo "=================================================="
echo ""

# Check docker
if ! docker info > /dev/null 2>&1; then
  echo "❌ Docker chưa chạy! Hãy mở Docker Desktop trước."
  read -p "Nhấn Enter để thoát..."
  exit 1
fi

echo "✅ Docker đang chạy"
echo ""
echo "📦 Đang build lại và khởi động toàn bộ stack..."
echo ""

docker compose down --remove-orphans 2>/dev/null
docker compose up --build -d

echo ""
echo "⏳ Chờ services khởi động..."
sleep 8

echo ""
echo "🔍 Kiểm tra trạng thái services..."
docker compose ps

echo ""
echo "=================================================="
echo "  ✅ Demo sẵn sàng!"
echo "=================================================="
echo ""
echo "  🌐 Frontend:            http://localhost:3000"
echo "  📦 Order Service API:   http://localhost:8081/orders"
echo "  🔔 Notification WS:     http://localhost:8082"
echo ""
echo "  💡 Để tạo đơn hàng test: bash scripts/quick-test.sh"
echo ""
echo "Nhấn Enter để chạy quick-test (tạo 5 đơn hàng demo)..."
read
bash scripts/quick-test.sh

echo ""
echo "Demo đang chạy. Nhấn Enter để DỪNG tất cả services..."
read
docker compose down
echo "✅ Đã dừng tất cả services."
