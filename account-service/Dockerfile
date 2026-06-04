# ---- Build stage ---------------------------------------------------------
FROM python:3.11-slim AS builder

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir -r requirements.txt


# ---- Runtime stage -------------------------------------------------------
FROM python:3.11-slim

WORKDIR /app

RUN groupadd -r appgroup && useradd -r -g appgroup -d /app appuser

COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin/uvicorn /usr/local/bin/uvicorn

COPY app/ ./app/

RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" \
  || exit 1

ENV SERVICE_NAME=account-service

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]