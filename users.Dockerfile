# users-service · patron de SPEC-api-gateway.md §16.1
#
# Vive aca y no en el repo `users` porque ese repo asigna dueños por archivo
# (docs/TASK-ASSIGNMENT.md). El compose lo referencia con `dockerfile:`, que se
# resuelve relativo al `context`. Cuando el Dockerfile pase al repo, esto se
# borra y el compose vuelve a `build: ../users`.
#
# Los comentarios van en su propia linea: Docker no los admite al final de una
# instruccion. `USER app  # NO root` crea un usuario llamado "app  # NO root" y
# el contenedor no arranca.

# ---- build ----
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
# Capa cacheable: no se invalida al tocar codigo.
COPY pom.xml .
RUN mvn -B dependency:go-offline
COPY src ./src
# Los tests corren en el pipeline. Un docker build que necesita Testcontainers
# necesitaria un Docker adentro de Docker.
RUN mvn -B clean package -DskipTests

# ---- runtime ----
# La imagen final no lleva Maven ni el codigo fuente.
FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S app && adduser -S app -G app
# NO root.
USER app
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8082 8083
# MaxRAMPercentage en vez de -Xmx: respeta el limite del contenedor sin
# hardcodear un numero.
ENTRYPOINT ["java","-XX:MaxRAMPercentage=75","-jar","app.jar"]
