package egov.sample.inventory;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/** 재고 마이크로서비스. 주문 서비스에서 호출하는 예약 API 만 제공하는 교육용 단순 구현이다. */
@SpringBootApplication
public class InventoryServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(InventoryServiceApplication.class, args);
    }
}
