package com.example.orderservice.model;

import lombok.Data;

import java.math.BigDecimal;

@Data
public class OrderRequest {
    private String customerName;
    private String productName;
    private BigDecimal amount;
}
