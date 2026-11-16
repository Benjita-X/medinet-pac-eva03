# syntax=docker/dockerfile:1
# Imagen multi-stage endurecida: dependencias compiladas en "builder",
# runtime sin pip ni herramientas de compilación, usuario sin privilegios.
FROM docker.io/library/python:3.14-slim AS builder
WORKDIR /build
COPY requirements.txt ./
RUN python -m pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM docker.io/library/python:3.14-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip uninstall -y pip setuptools wheel || true
WORKDIR /srv/pac
COPY --from=builder /install /usr/local
COPY app ./app
COPY migrations ./migrations
COPY alembic.ini ./
COPY scripts/containers ./container_tools
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]
ENTRYPOINT ["python", "container_tools/entrypoint.py"]
CMD ["api"]
