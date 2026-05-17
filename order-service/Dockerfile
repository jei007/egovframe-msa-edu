# 멀티 스테이지 없이 빌드 산출 JAR 만 복사하는 단순 런타임 이미지. 빌드는 호스트에서 mvn package 후 docker build.
FROM eclipse-temurin:17-jre
WORKDIR /app
ARG JAR_FILE=target/order-service-1.0.0.jar
COPY ${JAR_FILE} app.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","/app/app.jar"]
