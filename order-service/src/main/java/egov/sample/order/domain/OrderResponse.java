package egov.sample.order.domain;

/** 주문 처리 결과 요약. payment·inventory 는 각 서비스 JSON 응답을 그대로 담는다(Object). */
public record OrderResponse(
    String orderId,
    String status,
    Object payment,
    Object inventory
) {
}
