package egov.sample.order;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/** 주문 마이크로서비스 진입점. 결제·재고 서비스를 HTTP 로 호출하는 오케스트레이션 역할을 한다. */
@SpringBootApplication
public class OrderServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(OrderServiceApplication.class, args);
    }
}
