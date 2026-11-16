# syntax=docker/dockerfile:1
# Frontend PAC endurecido: nginx sin privilegios (usuario 101, puerto 8080), solo archivos estáticos.
FROM docker.io/nginxinc/nginx-unprivileged:1.29-alpine
USER root
RUN apk upgrade --no-cache && rm -f /etc/nginx/conf.d/*.conf /usr/share/nginx/html/*
COPY nginx.conf /etc/nginx/conf.d/pac.conf
COPY index.html app.js styles.css /usr/share/nginx/html/
RUN chmod 0644 /etc/nginx/conf.d/pac.conf /usr/share/nginx/html/*
USER 101:101
ENV NGINX_ENTRYPOINT_QUIET_LOGS=1
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=3 CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
