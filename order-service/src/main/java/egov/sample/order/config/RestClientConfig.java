package egov.sample.order.config;

import org.springframework.boot.web.client.RestTemplateBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.client.RestTemplate;

import java.time.Duration;

/** 재고 호출용 RestTemplate 빈. 타임아웃은 앱 레벨 보호용이며 Istio 정책과 별개로 동작한다. */
@Configuration
public class RestClientConfig {

    @Bean
    RestTemplate restTemplate(RestTemplateBuilder builder) {
        return builder
            .setConnectTimeout(Duration.ofSeconds(2))
            .setReadTimeout(Duration.ofSeconds(5))
            .build();
    }
}
