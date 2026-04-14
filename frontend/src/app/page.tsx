'use client'

import { useState, useEffect, useRef, useCallback } from 'react'
import { Toaster, toast } from 'sonner'

const ORDER_URL = process.env.NEXT_PUBLIC_ORDER_URL ?? 'http://localhost:8081'
const NOTIF_HEALTH_URL = (process.env.NEXT_PUBLIC_NOTIF_URL ?? 'http://localhost:8082') + '/health'
const WS_URL = process.env.NEXT_PUBLIC_WS_URL ?? 'ws://localhost:8082/ws'

type ServiceState = 'green' | 'red' | 'checking'

interface OrderEvent {
  orderId: number
  customerName: string
  productName: string
  amount: number
  createdAt: string
}

interface HealthState {
  order: ServiceState
  notification: ServiceState
}

// Map orderId → { t1: time submit, t2: time HTTP response }
const timings = new Map<number, { t1: number; t2: number }>()

export default function Home() {
  const [form, setForm] = useState({ customerName: '', productName: '', amount: '' })
  const [loading, setLoading] = useState(false)
  const [health, setHealth] = useState<HealthState>({ order: 'checking', notification: 'checking' })
  const [wsConnected, setWsConnected] = useState(false)
  const [events, setEvents] = useState<OrderEvent[]>([])
  const wsRef = useRef<WebSocket | null>(null)
  const reconnectTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  const connectWs = useCallback(() => {
    const ws = new WebSocket(WS_URL)

    ws.onopen = () => {
      setWsConnected(true)
      console.log('[WS] Connected to notification-service')
    }

    ws.onmessage = (e) => {
      const t3 = performance.now()
      const data: OrderEvent = JSON.parse(e.data)

      const timing = timings.get(data.orderId)
      if (timing) {
        const httpMs = Math.round(timing.t2 - timing.t1)
        const asyncMs = Math.round(t3 - timing.t2)
        const totalMs = Math.round(t3 - timing.t1)
        console.log(
          `[Timing] Order #${data.orderId} | HTTP: ${httpMs}ms | Async (Redis→WS): ${asyncMs}ms | Total: ${totalMs}ms`
        )
        timings.delete(data.orderId)
      }

      toast.success(`Đơn hàng #${data.orderId} đã được xử lý`, {
        description: `Khách hàng: ${data.customerName} | sản phẩm: ${data.productName} | ${Number(data.amount).toLocaleString('vi-VN')} VND`,
        duration: 6000,
      })
      setEvents((prev) => [data, ...prev].slice(0, 20))
    }

    ws.onclose = () => {
      setWsConnected(false)
      console.log('[WS] Disconnected, reconnecting in 3s...')
      reconnectTimer.current = setTimeout(connectWs, 3000)
    }

    ws.onerror = () => ws.close()

    wsRef.current = ws
  }, [])

  useEffect(() => {
    connectWs()

    const checkHealth = async () => {
      // Order Service
      try {
        const res = await fetch(`${ORDER_URL}/actuator/health`)
        const json = await res.json()
        setHealth((h) => ({ ...h, order: json.status === 'UP' ? 'green' : 'red' }))
      } catch {
        setHealth((h) => ({ ...h, order: 'red' }))
      }

      // Notification Service
      try {
        const res = await fetch(NOTIF_HEALTH_URL)
        setHealth((h) => ({ ...h, notification: res.ok ? 'green' : 'red' }))
      } catch {
        setHealth((h) => ({ ...h, notification: 'red' }))
      }
    }

    checkHealth()
    const interval = setInterval(checkHealth, 5000)

    return () => {
      clearInterval(interval)
      if (reconnectTimer.current) clearTimeout(reconnectTimer.current)
      wsRef.current?.close()
    }
  }, [connectWs])

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setLoading(true)
    const t1 = performance.now()
    try {
      const res = await fetch(`${ORDER_URL}/orders`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          customerName: form.customerName,
          productName: form.productName,
          amount: parseFloat(form.amount),
        }),
      })
      const t2 = performance.now()
      if (res.ok) {
        const order = await res.json()
        timings.set(order.id, { t1, t2 })
        console.log(`[Timing] Order #${order.id} | HTTP round-trip: ${Math.round(t2 - t1)}ms`)
        toast.info(`Đã tạo đơn hàng #${order.id} – cho thông báo từ Notification Service...`)
        setForm({ customerName: '', productName: '', amount: '' })
      } else {
        toast.error('Tạo đơn hàng thất bại!')
      }
    } catch {
      toast.error('Khong the ket noi den Order Service!')
    } finally {
      setLoading(false)
    }
  }

  const Badge = ({ state }: { state: ServiceState }) => {
    const map: Record<ServiceState, { cls: string; label: string }> = {
      green: { cls: 'badge badge-green', label: 'Online' },
      red: { cls: 'badge badge-red', label: 'Offline' },
      checking: { cls: 'badge badge-checking', label: 'Checking...' },
    }
    const { cls, label } = map[state]
    return <span className={cls}>{label}</span>
  }

  return (
    <main className="container">
      <Toaster position="top-right" richColors closeButton />

      <h1>Microservices Demo</h1>
      <p className="subtitle">Order Service → Redis Pub/Sub → Notification Service → WebSocket → Browser</p>

      {/* Health Dashboard */}
      <div className="card">
        <h2>Service Health</h2>
        <div className="health-grid">
          <div className="health-item">
            <span className="health-label">Order Service (8081)</span>
            <Badge state={health.order} />
          </div>
          <div className="health-item">
            <span className="health-label">Notification Service (8082)</span>
            <Badge state={health.notification} />
          </div>
          <div className="health-item">
            <span className="health-label">WebSocket</span>
            <span className={`badge ${wsConnected ? 'badge-green' : 'badge-red'}`}>
              <span className={`ws-indicator ${wsConnected ? 'ws-connected' : 'ws-disconnected'}`} />
              {wsConnected ? 'Connected' : 'Disconnected'}
            </span>
          </div>
        </div>
      </div>

      {/* Order Form */}
      <div className="card">
        <h2>Tạo đơn hàng mới</h2>
        <form className="form" onSubmit={handleSubmit}>
          <input
            type="text"
            placeholder="Tên khách hàng"
            value={form.customerName}
            onChange={(e) => setForm({ ...form, customerName: e.target.value })}
            required
          />
          <input
            type="text"
            placeholder="Tên sản phẩm"
            value={form.productName}
            onChange={(e) => setForm({ ...form, productName: e.target.value })}
            required
          />
          <input
            type="number"
            placeholder="Số tiền (VND)"
            value={form.amount}
            onChange={(e) => setForm({ ...form, amount: e.target.value })}
            required
            min="0"
            step="0.01"
          />
          <button type="submit" disabled={loading}>
            {loading ? 'Đang xử lý...' : 'Đặt hàng'}
          </button>
        </form>
      </div>

      {/* Real-time Event Log */}
      <div className="card">
        <h2>Real-time Order Events</h2>
        {events.length === 0 ? (
          <p className="log-empty">Chưa có sự kiện nào. Hãy đặt hàng để xem thông báo real-time.</p>
        ) : (
          <ul className="log-list">
            {events.map((ev) => (
              <li key={`${ev.orderId}-${ev.createdAt}`} className="log-item">
                [{ev.createdAt?.split('T')[1]?.slice(0, 8) ?? ''}] Đã nhận đơn hàng #{ev.orderId} cho khách hàng {ev.customerName} — {ev.productName}
              </li>
            ))}
          </ul>
        )}
      </div>
    </main>
  )
}
