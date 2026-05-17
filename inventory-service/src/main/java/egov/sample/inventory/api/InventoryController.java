package egov.sample.inventory.api;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestTemplate;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 재고 서비스. order-service 가 호출하면 자체 재고 예약 후 payment-service 까지 연쇄 호출한다.
 *
 * - INVENTORY_VERSION=latest (정상): 재고 예약 → 결제 호출 → 합쳐서 응답
 * - INVENTORY_VERSION=risky, INVENTORY_FAULT_MODE=always-5xx: 항상 503 반환(장애전파·서킷브레이커 실습)
 */
@RestController
@RequestMapping("/api/inventories")
public class InventoryController {

    private static final Logger log = LoggerFactory.getLogger(InventoryController.class);

    private final RestTemplate restTemplate;
    private final String paymentServiceUrl;
    private final String version;
    private final String faultMode;

    public InventoryController(
        RestTemplate restTemplate,
        @Value("${services.payment.base-url}") String paymentServiceUrl,
        @Value("${inventory.version:latest}") String version,
        @Value("${inventory.fault.mode:none}") String faultMode
    ) {
        this.restTemplate = restTemplate;
        this.paymentServiceUrl = paymentServiceUrl;
        this.version = version;
        this.faultMode = faultMode;
    }

    @GetMapping("/health-check")
    public Map<String, String> healthCheck() {
        return Map.of("status", "inventory-service-ok", "version", version);
    }

    @PostMapping("/reserve")
    public ResponseEntity<Map<String, Object>> reserve(@Valid @RequestBody ReserveRequest request) {
        log.info("Inventory reserve. orderId={}, itemId={}, quantity={}, version={}",
            request.orderId(), request.itemId(), request.quantity(), version);

        if ("always-5xx".equalsIgnoreCase(faultMode)) {
            log.warn("Injecting 503 (risky inventory). orderId={}", request.orderId());
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(Map.of(
                "orderId", request.orderId(),
                "version", version,
                "reason", "injected-fault-risky"
            ));
        }

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("orderId", request.orderId());
        body.put("itemId", request.itemId());
        body.put("reserved", true);
        body.put("version", version);

        @SuppressWarnings("unchecked")
        Map<String, Object> paymentResult = restTemplate.postForObject(
            paymentServiceUrl + "/api/payments",
            Map.of("orderId", request.orderId(), "amount", request.amount()),
            Map.class
        );
        body.put("payment", paymentResult);
        return ResponseEntity.ok(body);
    }

    /** POST /api/inventories/reserve 본문. order-service 가 amount 까지 함께 보낸다. */
    public record ReserveRequest(
        @NotBlank String orderId,
        @NotBlank String itemId,
        @Min(1) int quantity,
        @NotNull @Min(100) Integer amount
    ) {
    }
}
