/**
 * FlashOrder – Smoke Test
 * ──────────────────────────────────────────────────────────────
 * Quick sanity check: 5 VUs × 30 s
 * Tests POST /orders and GET /orders
 *
 * Usage:
 *   k6 run k6/smoke-test.js
 *   k6 run --env BASE_URL=http://localhost:8090 k6/smoke-test.js  (monolith)
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// ── Custom metrics ────────────────────────────────────────────
const errorRate  = new Rate('error_rate');
const createTime = new Trend('order_create_duration', true);
const listTime   = new Trend('order_list_duration',   true);

// ── Config ────────────────────────────────────────────────────
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8081';

export const options = {
  vus:      5,
  duration: '30s',

  thresholds: {
    http_req_duration: ['p(95)<500'],   // 95 % of all requests under 500 ms
    error_rate:        ['rate<0.01'],   // error rate under 1 %
    'order_create_duration': ['p(95)<500'],
    'order_list_duration':   ['p(95)<300'],
  },
};

// ── Vietnamese test data ──────────────────────────────────────
const CUSTOMERS = [
  'Nguyễn Văn An', 'Trần Thị Bình', 'Lê Minh Cường',
  'Phạm Thị Dung',  'Hoàng Văn Em',  'Đặng Thị Phương',
];
const PRODUCTS = [
  'iPhone 15 Pro', 'Samsung Galaxy S24', 'MacBook Air M3',
  'AirPods Pro 2',  'iPad Air 5',         'Apple Watch S9',
];

function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

// ── Main scenario ─────────────────────────────────────────────
export default function () {
  const headers = { 'Content-Type': 'application/json' };

  // 1. POST /orders
  const payload = JSON.stringify({
    customerName: randomItem(CUSTOMERS),
    productName:  randomItem(PRODUCTS),
    amount:       Math.floor(Math.random() * 50_000_000) + 500_000,
  });

  const createRes = http.post(`${BASE_URL}/orders`, payload, { headers, tags: { name: 'POST /orders' } });
  createTime.add(createRes.timings.duration);

  const createOK = check(createRes, {
    'POST /orders – status 201':       (r) => r.status === 201,
    'POST /orders – has id':           (r) => r.json('id') !== undefined,
    'POST /orders – has customerName': (r) => r.json('customerName') !== undefined,
  });
  errorRate.add(!createOK);

  sleep(0.5);

  // 2. GET /orders
  const listRes = http.get(`${BASE_URL}/orders`, { tags: { name: 'GET /orders' } });
  listTime.add(listRes.timings.duration);

  const listOK = check(listRes, {
    'GET /orders – status 200':      (r) => r.status === 200,
    'GET /orders – returns array':   (r) => Array.isArray(r.json()),
  });
  errorRate.add(!listOK);

  sleep(0.5);
}

// ── Summary ───────────────────────────────────────────────────
export function handleSummary(data) {
  const passed = Object.values(data.metrics)
    .filter((m) => m.thresholds)
    .every((m) => Object.values(m.thresholds).every((t) => !t.ok === false));

  console.log('\n╔══════════════════════════════════════╗');
  console.log('║         SMOKE TEST  RESULTS           ║');
  console.log('╠══════════════════════════════════════╣');
  console.log(`║  Base URL : ${BASE_URL.padEnd(26)}║`);
  console.log(`║  VUs      : 5  Duration: 30s          ║`);

  const dur  = data.metrics.http_req_duration;
  const errs = data.metrics.error_rate;
  if (dur) {
    console.log(`║  p95 latency : ${String(dur.values['p(95)'].toFixed(1) + ' ms').padEnd(22)}║`);
    console.log(`║  p99 latency : ${String(dur.values['p(99)'].toFixed(1) + ' ms').padEnd(22)}║`);
  }
  if (errs) {
    console.log(`║  Error rate  : ${String((errs.values.rate * 100).toFixed(2) + ' %').padEnd(22)}║`);
  }
  console.log('╚══════════════════════════════════════╝\n');

  return {};
}
