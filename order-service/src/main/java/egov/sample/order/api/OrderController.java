package egov.sample.order.api;

import egov.sample.order.domain.OrderRequest;
import egov.sample.order.domain.OrderResponse;
import jakarta.validation.Valid;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.util.StringUtils;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.HttpServerErrorException;
import org.springframework.web.client.RestTemplate;

import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

    private static final Logger log = LoggerFactory.getLogger(OrderController.class);

    private final RestTemplate restTemplate;
    private final String inventoryServiceUrl;

    public OrderController(
        RestTemplate restTemplate,
        @Value("${services.inventory.base-url}") String inventoryServiceUrl
    ) {
        this.restTemplate = restTemplate;
        this.inventoryServiceUrl = inventoryServiceUrl;
    }

    @GetMapping("/health-check")
    public Map<String, String> healthCheck() {
        return Map.of("status", "order-service-ok");
    }

    /**
     * 주문 진입점 (실습·Kiali 트래픽 발생용).
     * 본문 없이 호출 가능: curl -X POST http://localhost:18088/api/orders
     * 흐름: order → inventory(ROUND_ROBIN: latest|risky) → payment
     */
    @PostMapping
    public ResponseEntity<?> placeOrder(@Valid @RequestBody(required = false) OrderRequest request) {
        OrderRequest req = resolveRequest(request);
        log.info("Order received. orderId={}, itemId={}, quantity={}",
            req.orderId(), req.itemId(), req.quantity());

        try {
            @SuppressWarnings("unchecked")
            Map<String, Object> inventoryResult = restTemplate.postForObject(
                inventoryServiceUrl + "/api/inventories/reserve",
                Map.of(
                    "orderId", req.orderId(),
                    "itemId", req.itemId(),
                    "quantity", req.quantity(),
                    "amount", req.price()
                ),
                Map.class
            );

            OrderResponse response = new OrderResponse(
                req.orderId(),
                "COMPLETED",
                inventoryResult == null ? Map.of() : inventoryResult.getOrDefault("payment", Map.of()),
                inventoryResult
            );
            return ResponseEntity.status(HttpStatus.CREATED).body(response);
        } catch (HttpServerErrorException e) {
            log.warn("Inventory call failed (5xx). orderId={}, status={}",
                req.orderId(), e.getStatusCode());
            return ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(Map.of(
                "orderId", req.orderId(),
                "status", "FAILED",
                "reason", "inventory-5xx",
                "upstream", e.getStatusCode().value()
            ));
        }
    }

    /** JSON 본문이 없거나 orderId 가 비어 있으면 교육용 기본값을 쓴다. */
    private static OrderRequest resolveRequest(OrderRequest request) {
        if (request != null
            && StringUtils.hasText(request.orderId())
            && StringUtils.hasText(request.itemId())
            && request.quantity() >= 1
            && request.price() != null
            && request.price() >= 100) {
            return request;
        }
        return new OrderRequest(
            "ORD-" + UUID.randomUUID().toString().substring(0, 8),
            "ITEM-1",
            1,
            100
        );
    }
}
