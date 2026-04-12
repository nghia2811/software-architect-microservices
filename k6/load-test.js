/**
 * FlashOrder – Load Test  (Flash Sale Simulation)
 * ──────────────────────────────────────────────────────────────
 * Ramp profile:
 *   0 → 50 users  over  1 min   (warm-up)
 *   50 → 200 users over  3 min  (peak flash sale)
 *   200 → 50 users over  1 min  (cool-down)
 *
 * Usage:
 *   # Microservices
 *   k6 run k6/load-test.js
 *   k6 run --out json=results/load-microservices.json k6/load-test.js
 *
 *   # Monolith
 *   k6 run --env BASE_URL=http://localhost:8090 \
 *          --out json=results/load-monolith.json \
 *          k6/load-test.js
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// ── Custom metrics ────────────────────────────────────────────
const errorRate   = new Rate('error_rate');
const ordersTotal = new Counter('orders_created_total');
const createTime  = new Trend('order_create_duration', true);

// ── Config ────────────────────────────────────────────────────
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8081';

export const options = {
  stages: [
    { duration: '1m',  target: 50  },   // warm-up
    { duration: '3m',  target: 200 },   // flash sale peak
    { duration: '1m',  target: 50  },   // cool-down
  ],

  thresholds: {
    http_req_duration:      ['p(95)<2000', 'p(99)<4000'],
    error_rate:             ['rate<0.05'],
    'order_create_duration': ['p(95)<2000'],
  },
};

// ── Realistic Vietnamese customer data ───────────────────────
const CUSTOMERS = [
  'Nguyễn Văn An',     'Trần Thị Bình',     'Lê Minh Cường',
  'Phạm Thị Dung',     'Hoàng Văn Em',      'Đặng Thị Phương',
  'Vũ Thị Giang',      'Đỗ Văn Hùng',       'Bùi Thị Lan',
  'Ngô Văn Minh',      'Dương Thị Ngọc',    'Lý Văn Phát',
  'Trịnh Thị Quỳnh',   'Đinh Văn Sơn',      'Mai Thị Tâm',
  'Phan Văn Uy',       'Lưu Thị Vân',       'Tạ Văn Xuân',
  'Cao Thị Yến',       'Kiều Văn Zung',
];

const PRODUCTS = [
  { name: 'iPhone 15 Pro Max 256GB',    price: 34990000 },
  { name: 'Samsung Galaxy S24 Ultra',    price: 31990000 },
  { name: 'MacBook Air M3 13-inch',      price: 28990000 },
  { name: 'iPad Pro M4 11-inch',         price: 23990000 },
  { name: 'AirPods Pro 2nd Gen',         price: 6490000  },
  { name: 'Apple Watch Series 9 45mm',   price: 11990000 },
  { name: 'Sony WH-1000XM5',             price: 7990000  },
  { name: 'Dell XPS 15 9530',            price: 42990000 },
  { name: 'ASUS ROG Zephyrus G14',       price: 38990000 },
  { name: 'Xiaomi 14 Ultra',             price: 19990000 },
];

function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

function jitter(ms) {
  return ms * (0.8 + Math.random() * 0.4);
}

// ── Main scenario ─────────────────────────────────────────────
export default function () {
  const headers = { 'Content-Type': 'application/json' };
  const product = randomItem(PRODUCTS);

  // Simulate realistic user behaviour: slight variance in amount (e.g., with promo code)
  const discountFactor = Math.random() < 0.2 ? 0.9 : 1.0;
  const amount = Math.round(product.price * discountFactor);

  const payload = JSON.stringify({
    customerName: randomItem(CUSTOMERS),
    productName:  product.name,
    amount,
  });

  const res = http.post(`${BASE_URL}/orders`, payload, {
    headers,
    tags: { name: 'POST /orders' },
  });

  createTime.add(res.timings.duration);

  const ok = check(res, {
    'status 201':      (r) => r.status === 201,
    'has order id':    (r) => r.json('id') !== undefined,
    'response < 2s':   (r) => r.timings.duration < 2000,
  });

  if (!ok) {
    errorRate.add(1);
    console.warn(`[WARN] Order failed | status=${res.status} | body=${res.body?.slice(0, 200)}`);
  } else {
    errorRate.add(0);
    ordersTotal.add(1);
  }

  // Human-like think time: 200-800 ms between orders
  sleep(jitter(0.5));
}

// ── Summary ───────────────────────────────────────────────────
export function handleSummary(data) {
  const dur   = data.metrics.http_req_duration;
  const errs  = data.metrics.error_rate;
  const rps   = data.metrics.http_reqs;
  const total = data.metrics.orders_created_total;

  console.log('\n╔════════════════════════════════════════════════╗');
  console.log('║         LOAD TEST RESULTS (Flash Sale)          ║');
  console.log('╠════════════════════════════════════════════════╣');
  console.log(`║  Target     : ${BASE_URL.padEnd(33)}║`);
  console.log(`║  Peak VUs   : 200                               ║`);
  if (rps)   console.log(`║  RPS (avg)  : ${String(rps.values.rate.toFixed(2)).padEnd(33)}║`);
  if (dur) {
    console.log(`║  p50 latency: ${String(dur.values['p(50)'].toFixed(1) + ' ms').padEnd(33)}║`);
    console.log(`║  p95 latency: ${String(dur.values['p(95)'].toFixed(1) + ' ms').padEnd(33)}║`);
    console.log(`║  p99 latency: ${String(dur.values['p(99)'].toFixed(1) + ' ms').padEnd(33)}║`);
  }
  if (errs)  console.log(`║  Error rate : ${String((errs.values.rate * 100).toFixed(2) + ' %').padEnd(33)}║`);
  if (total) console.log(`║  Orders OK  : ${String(total.values.count).padEnd(33)}║`);
  console.log('╚════════════════════════════════════════════════╝\n');

  return {};
}
