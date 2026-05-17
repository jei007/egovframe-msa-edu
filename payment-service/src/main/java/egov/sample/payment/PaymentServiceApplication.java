package egov.sample.payment;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/** 결제 마이크로서비스. 지연 시뮬레이션 API 로 Istio 타임아웃·재시도 실습에 활용한다. */
@SpringBootApplication
public class PaymentServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(PaymentServiceApplication.class, args);
    }
}
