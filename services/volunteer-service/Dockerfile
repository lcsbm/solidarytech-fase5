FROM python:3.12-slim AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN useradd --create-home --uid 10001 appuser

COPY --from=builder /install /usr/local

WORKDIR /app
COPY --chown=appuser:appuser app.py .

USER appuser
EXPOSE 8083

# 1 worker + threads: o scale horizontal é feito pelo HPA do Kubernetes,
# e mantém o registry do prometheus_client coerente dentro do pod.
CMD ["gunicorn", "--bind", "0.0.0.0:8083", "--workers", "1", "--threads", "8", \
     "--access-logfile", "-", "--error-logfile", "-", "app:app"]
