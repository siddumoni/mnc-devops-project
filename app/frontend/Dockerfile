# ─────────────────────────────────────────────
# Multi-stage Dockerfile — Frontend (React → Nginx)
#
# Stage 1 (builder): Node.js builds the static React bundle.
# Stage 2 (runtime): Nginx serves the static files.
#
# The final image has NO Node.js, NO npm, NO source — just
# the compiled HTML/CSS/JS files served by a hardened Nginx.
# Final image size: ~25MB (vs ~1GB with Node included).
# ─────────────────────────────────────────────

# ── Stage 1: Build React app ─────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

# Install dependencies first (cache layer)
COPY package*.json ./
RUN npm ci --silent

# Build arguments — injected by Jenkins at build time
# These become baked into the JS bundle (not runtime env vars)
ARG REACT_APP_API_URL
ARG REACT_APP_ENV
ARG GIT_COMMIT

ENV REACT_APP_API_URL=${REACT_APP_API_URL}
ENV REACT_APP_ENV=${REACT_APP_ENV}
ENV REACT_APP_GIT_COMMIT=${GIT_COMMIT}

COPY . .
RUN npm run build

# ── Stage 2: Nginx runtime ───────────────────────────────────────────────
FROM nginx:1.25-alpine

# Remove default nginx static content
RUN rm -rf /usr/share/nginx/html/*

# Copy the React build output
COPY --from=builder /app/build /usr/share/nginx/html

# Custom nginx config: handles React Router (SPA) properly
# Without this, refreshing /products/1 gives a 404
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Security: run as non-root
RUN addgroup -S nginxgroup && adduser -S nginxuser -G nginxgroup
RUN chown -R nginxuser:nginxgroup /usr/share/nginx/html \
    && chown -R nginxuser:nginxgroup /var/cache/nginx \
    && chown -R nginxuser:nginxgroup /var/log/nginx \
    && touch /var/run/nginx.pid \
    && chown nginxuser:nginxgroup /var/run/nginx.pid

USER nginxuser

EXPOSE 3000

CMD ["nginx", "-g", "daemon off;"]
