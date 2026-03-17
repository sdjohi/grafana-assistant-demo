FROM python:3.12

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

COPY certs/netskope.cer /usr/local/share/ca-certificates/netskope.crt
COPY certs/sd.dika.be.cer /usr/local/share/ca-certificates/sd.dika.be.crt
RUN update-ca-certificates

WORKDIR /app

COPY services/order-service/pyproject.toml .
RUN uv sync --no-dev

COPY services/order-service/app/ app/

CMD ["uv", "run", "opentelemetry-instrument", "--logs_exporter", "otlp", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8001"]
