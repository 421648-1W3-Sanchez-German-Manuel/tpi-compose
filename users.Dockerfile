# users-service · pattern of SPEC-api-gateway.md §16.1
#
# Lives here and not in the `users` repo because that repo assigns owners per
# file (docs/TASK-ASSIGNMENT.md). The compose references it with `dockerfile:`,
# which resolves relative to the `context`. When the Dockerfile moves to the
# repo, this is deleted and the compose goes back to `build: ../users`.
#
# Comments go on their own line: Docker does not allow them at the end of an
# instruction. `USER app  # NO root` creates a user called "app  # NO root" and
# the container does not start.

# ---- build ----
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
# Cacheable layer: it does not invalidate when code changes.
COPY pom.xml .
RUN mvn -B dependency:go-offline
COPY src ./src
# Tests run in the pipeline. A docker build that needs Testcontainers would
# need a Docker inside Docker.
RUN mvn -B clean package -DskipTests

# ---- runtime ----
# The final image carries neither Maven nor the source code.
FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S app && adduser -S app -G app
# NO root.
USER app
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8082 8083
# MaxRAMPercentage instead of -Xmx: it honors the container limit without
# hardcoding a number.
ENTRYPOINT ["java","-XX:MaxRAMPercentage=75","-jar","app.jar"]
