# inventory-service 컨테이너 이미지 (호스트에서 JAR 빌드 후 사용).
FROM eclipse-temurin:17-jre
WORKDIR /app
ARG JAR_FILE=target/inventory-service-1.0.0.jar
COPY ${JAR_FILE} app.jar
EXPOSE 8082
ENTRYPOINT ["java","-jar","/app/app.jar"]
