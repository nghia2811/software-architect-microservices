package com.example.orderservice.service;

import com.example.orderservice.model.Order;
import com.example.orderservice.model.OrderRequest;
import com.example.orderservice.repository.OrderRepository;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

@Service
@RequiredArgsConstructor
@Slf4j
public class OrderService {

    private final OrderRepository orderRepository;
    private final StringRedisTemplate redisTemplate;
    private final ObjectMapper objectMapper;

    public List<Order> getAllOrders() {
        return orderRepository.findAll();
    }

    public Optional<Order> getOrderById(Long id) {
        return orderRepository.findById(id);
    }

    public Order createOrder(OrderRequest request) {
        Order order = new Order();
        order.setCustomerName(request.getCustomerName());
        order.setProductName(request.getProductName());
        order.setAmount(request.getAmount());

        Order saved = orderRepository.save(order);
        log.info("Order saved: id={}, customer={}, product={}, amount={}",
                saved.getId(), saved.getCustomerName(), saved.getProductName(), saved.getAmount());

        publishOrderEvent(saved);
        return saved;
    }

    private void publishOrderEvent(Order order) {
        try {
            long publishedAt = System.currentTimeMillis();
            Map<String, Object> event = new HashMap<>();
            event.put("orderId", order.getId());
            event.put("customerName", order.getCustomerName());
            event.put("productName", order.getProductName());
            event.put("amount", order.getAmount());
            event.put("createdAt", order.getCreatedAt().toString());
            event.put("publishedAt", publishedAt);  // epoch ms, để đo async latency

            String message = objectMapper.writeValueAsString(event);
            redisTemplate.convertAndSend("order_events", message);
            log.info("[Redis Publisher] Published event to 'order_events': {}", message);
        } catch (Exception e) {
            log.error("Failed to publish order event to Redis", e);
        }
    }
}
