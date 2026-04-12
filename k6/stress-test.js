/**
 * FlashOrder – Stress Test  (Find the Breaking Point)
 * ──────────────────────────────────────────────────────────────
 * Ramp profile:
 *   0 → 500 users over 10 min   (aggressive ramp)
 *   500 users  hold   2  min    (sustained peak)
 *   500 → 0    over   2  min    (graceful drain)
 *
 * The script tracks when errors first appear and logs the VU count
 * at that moment — effectively identifying the saturation point.
 *
 * Usage:
 *   k6 run k6/stress-test.js
 *   k6 run --env BASE_URL=http://localhost:8090 k6/stress-test.js  (monolith)
 *   k6 run --out json=results/stress-microservices.json k6/stress-test.js
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Gauge, Rate, Trend } from 'k6/metrics';

// ── Custom metrics ────────────────────────────────────────────
const errorRate          = new Rate('error_rate');
const ordersCreated      = new Counter('orders_created');
const ordersFailedTotal  = new Counter('orders_failed');
const createDuration     = new Trend('order_create_duration', true);
const activeVUs          = new Gauge('active_vus');

// ── Breaking-point tracker ────────────────────────────────────
let firstErrorAt    = null;   // epoch ms when first error occurred
let firstErrorVU    = null;   // approximate VU count at that moment

// ── Config ────────────────────────────────────────────────────
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8081';

export const options = {
  stages: [
    { duration: '10m', target: 500 },   // ramp to 500
    { duration: '2m',  target: 500 },   // hold at 500
    { duration: '2m',  target: 0   },   // ramp down
  ],

  thresholds: {
    // These are intentionally aggressive — we expect them to breach
    http_req_duration: ['p(95)<5000'],
    error_rate:        ['rate<0.20'],    // allow up to 20 % errors (stress test)
  },

  // Don't abort the run when thresholds breach — we want full data
  noConnectionReuse: false,
};

// ── Data ──────────────────────────────────────────────────────
const CUSTOMERS = [
  'Nguyễn Văn An', 'Trần Thị Bình', 'Lê Minh Cường', 'Phạm Thị Dung',
  'Hoàng Văn Em',  'Đặng Thị Phương', 'Vũ Thị Giang', 'Đỗ Văn Hùng',
  'Bùi Thị Lan',   'Ngô Văn Minh',    'Dương Thị Ngọc', 'Lý Văn Phát',
];
const PRODUCTS = [
  'iPhone 15 Pro', 'Galaxy S24 Ultra', 'MacBook Air M3',
  'AirPods Pro',   'iPad Pro M4',      'Apple Watch S9',
];

function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

// ── Main scenario ─────────────────────────────────────────────
export default function () {
  activeVUs.add(1);

  const payload = JSON.stringify({
    customerName: randomItem(CUSTOMERS),
    productName:  randomItem(PRODUCTS),
    amount:       Math.floor(Math.random() * 30_000_000) + 500_000,
  });

  const res = http.post(`${BASE_URL}/orders`, payload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '10s',
    tags: { name: 'POST /orders' },
  });

  createDuration.add(res.timings.duration);

  const ok = check(res, {
    'status 201':    (r) => r.status === 201,
    'has id':        (r) => r.json('id') !== undefined,
    'under 5s':      (r) => r.timings.duration < 5000,
  });

  if (!ok) {
    errorRate.add(1);
    ordersFailedTotal.add(1);

    // Record first error moment
    if (firstErrorAt === null) {
      firstErrorAt = Date.now();
      firstErrorVU = __VU;
      console.error(
        `[BREAKING POINT] First error detected!\n` +
        `  Time   : ${new Date(firstErrorAt).toISOString()}\n` +
        `  VU #   : ${firstErrorVU}\n` +
        `  Status : ${res.status}\n` +
        `  Latency: ${res.timings.duration.toFixed(0)} ms\n` +
        `  Body   : ${res.body?.slice(0, 300)}`
      );
    }
  } else {
    errorRate.add(0);
    ordersCreated.add(1);
  }

  // Minimal think time under stress
  sleep(0.1 + Math.random() * 0.3);
}

// ── Summary ───────────────────────────────────────────────────
export function handleSummary(data) {
  const dur    = data.metrics.http_req_duration;
  const errs   = data.metrics.error_rate;
  const rps    = data.metrics.http_reqs;
  const ok     = data.metrics.orders_created;
  const failed = data.metrics.orders_failed;

  console.log('\n╔══════════════════════════════════════════════════════╗');
  console.log('║              STRESS TEST RESULTS                      ║');
  console.log('╠══════════════════════════════════════════════════════╣');
  console.log(`║  Target    : ${BASE_URL.padEnd(41)}║`);
  console.log(`║  Peak VUs  : 500  (ramp 10 min → hold 2 min)          ║`);

  if (rps)    console.log(`║  RPS (avg) : ${String(rps.values.rate.toFixed(2)).padEnd(41)}║`);
  if (dur) {
    console.log(`║  p50       : ${String(dur.values['p(50)'].toFixed(1) + ' ms').padEnd(41)}║`);
    console.log(`║  p95       : ${String(dur.values['p(95)'].toFixed(1) + ' ms').padEnd(41)}║`);
    console.log(`║  p99       : ${String(dur.values['p(99)'].toFixed(1) + ' ms').padEnd(41)}║`);
    console.log(`║  max       : ${String(dur.values.max.toFixed(1) + ' ms').padEnd(41)}║`);
  }
  if (errs)   console.log(`║  Error %   : ${String((errs.values.rate * 100).toFixed(2) + ' %').padEnd(41)}║`);
  if (ok)     console.log(`║  Orders OK : ${String(ok.values.count).padEnd(41)}║`);
  if (failed) console.log(`║  Orders ✗  : ${String(failed.values.count).padEnd(41)}║`);

  if (firstErrorAt) {
    console.log(`║  ⚠ Break @ VU #${String(firstErrorVU).padEnd(38)}║`);
  } else {
    console.log(`║  ✓ No errors detected — system held under 500 VUs!   ║`);
  }
  console.log('╚══════════════════════════════════════════════════════╝\n');

  return {};
}
