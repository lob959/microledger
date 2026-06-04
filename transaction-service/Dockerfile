# ---- Build stage ---------------------------------------------------------
FROM python:3.11-slim AS builder

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir -r requirements.txt


# ---- Runtime stage -------------------------------------------------------
FROM python:3.11-slim

WORKDIR /app

# Security: run as a non-root user
# Avoids a whole class of container escape / privilege escalation issues
RUN groupadd -r appgroup && useradd -r -g appgroup -d /app appuser

# Copy installed packages from builder (keeps final image smaller)
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin/uvicorn /usr/local/bin/uvicorn

# Copy application source
COPY app/ ./app/

# Set ownership so appuser can read the files
RUN chown -R appuser:appgroup /app

USER appuser

# Document the port — does not publish it; that is done in docker-compose / ECS task def
EXPOSE 8000

# Docker-native health check — used by docker-compose and visible in `docker ps`
# ECS uses the ALB target group health check; this is a belt-and-braces local check
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" \
  || exit 1

# SERVICE_NAME is read by logger.py — override per environment
ENV SERVICE_NAME=transaction-service

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
