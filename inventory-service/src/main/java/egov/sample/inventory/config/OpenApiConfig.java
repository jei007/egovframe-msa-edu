package egov.sample.inventory.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** Swagger UI 에 노출할 OpenAPI 메타데이터. */
@Configuration
public class OpenApiConfig {

    @Bean
    public OpenAPI inventoryServiceOpenApi() {
        return new OpenAPI()
            .info(new Info()
                .title("Inventory Service API")
                .description("재고 예약 API 테스트용 문서")
                .version("1.0.0"));
    }
}
