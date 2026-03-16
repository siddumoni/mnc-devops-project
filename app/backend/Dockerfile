# ─────────────────────────────────────────────
# Multi-stage Dockerfile — Backend (Spring Boot)
#
# Stage 1 (builder): Maven compiles the JAR.
# Stage 2 (runtime): Only the JAR runs — no Maven, no source code.
#
# This is CRITICAL for production:
# - Final image is ~200MB instead of ~600MB
# - Attack surface is minimal (no build tools in prod)
# - Never expose source code in the running container
# ─────────────────────────────────────────────

# ── Stage 1: Build ────────────────────────────────────────────────────────
FROM maven:3.9-amazoncorretto-17 AS builder

WORKDIR /app

# Copy pom.xml first and download dependencies.
# This is a Docker layer caching trick: if pom.xml hasn't changed,
# Docker reuses the cached layer and skips the slow mvn dependency:resolve step.
# Only invalidated when pom.xml changes.
COPY pom.xml .
RUN mvn dependency:resolve --batch-mode --no-transfer-progress -q

# Now copy the source and build
COPY src ./src
RUN mvn clean package \
    -DskipTests \
    --batch-mode \
    --no-transfer-progress \
    -q

# ── Stage 2: Runtime ─────────────────────────────────────────────────────
FROM amazoncorretto:17-alpine3.18

# Security: run as non-root user
# Never run Java applications as root in containers
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy only the JAR from the build stage — nothing else
COPY --from=builder /app/target/*.jar app.jar

# Change ownership to non-root user
RUN chown appuser:appgroup app.jar
USER appuser

# Build arguments (injected by Jenkins, stored as image labels for traceability)
ARG BUILD_DATE
ARG GIT_COMMIT
ARG VERSION
LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.title="mnc-app-backend"

# Expose the application port
EXPOSE 8080

# JVM tuning for containers:
# - UseContainerSupport: JVM respects cgroup memory limits (not host RAM)
# - MaxRAMPercentage: use up to 75% of container memory for heap
# - ExitOnOutOfMemoryError: crash fast instead of degraded state
ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75.0", \
    "-XX:+ExitOnOutOfMemoryError", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "-jar", "app.jar"]
