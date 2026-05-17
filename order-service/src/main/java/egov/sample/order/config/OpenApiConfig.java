package egov.sample.order.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** Swagger UI 에 노출할 OpenAPI 메타데이터(제목·설명 등). */
@Configuration
public class OpenApiConfig {

    @Bean
    public OpenAPI orderServiceOpenApi() {
        return new OpenAPI()
            .info(new Info()
                .title("Order Service API")
                .description("주문 생성 및 결제·재고 마이크로서비스 호출 테스트용 문서")
                .version("1.0.0"));
    }
}
