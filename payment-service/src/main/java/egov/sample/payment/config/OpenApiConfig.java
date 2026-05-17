package egov.sample.payment.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** Swagger UI 에 노출할 OpenAPI 메타데이터. */
@Configuration
public class OpenApiConfig {

    @Bean
    public OpenAPI paymentServiceOpenApi() {
        return new OpenAPI()
            .info(new Info()
                .title("Payment Service API")
                .description("결제 승인 및 지연 시뮬레이션(Istio 복원력 실습) 테스트용 문서")
                .version("1.0.0"));
    }
}
