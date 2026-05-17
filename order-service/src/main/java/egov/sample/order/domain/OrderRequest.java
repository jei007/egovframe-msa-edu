package egov.sample.order.domain;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

/** POST /api/orders 요청 본문. 금액·수량 등 검증 규칙은 교육용 샘플 수준이다. */
public record OrderRequest(
    @NotBlank String orderId,
    @NotBlank String itemId,
    @Min(1) int quantity,
    @NotNull @Min(100) Integer price
) {
}
