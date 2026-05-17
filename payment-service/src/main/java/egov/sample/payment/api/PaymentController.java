package egov.sample.payment.api;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@Validated
@RestController
@RequestMapping("/api/payments")
public class PaymentController {

    private static final Logger log = LoggerFactory.getLogger(PaymentController.class);

    @GetMapping("/health-check")
    public Map<String, String> healthCheck() {
        return Map.of("status", "payment-service-ok");
    }

    /**
     * 의도적으로 처리 시간을 늘린다. order-service → payment 호출 경로에 Istio VirtualService
     * 의 timeout/retry 가 걸려 있을 때 동작 차이를 관찰하기 위한 교육용 엔드포인트다.
     */
    @GetMapping("/simulate-delay")
    public ResponseEntity<Map<String, Object>> simulateDelay(
        @RequestParam(defaultValue = "1000") @Min(0) long millis
    ) throws InterruptedException {
        Thread.sleep(millis);
        log.info("Delay simulation completed. millis={}", millis);
        return ResponseEntity.ok(Map.of("delayedMillis", millis));
    }

    /** 결제 승인을 가장한 단순 응답(외부 PG 연동 없음). */
    @PostMapping
    public ResponseEntity<Map<String, Object>> pay(@RequestBody PaymentRequest request) {
        log.info("Payment requested. orderId={}, amount={}", request.orderId(), request.amount());
        return ResponseEntity.ok(
            Map.of(
                "orderId", request.orderId(),
                "paymentStatus", "APPROVED",
                "amount", request.amount()
            )
        );
    }

    /** POST /api/payments 본문. */
    public record PaymentRequest(@NotBlank String orderId, @Min(100) int amount) {
    }
}
