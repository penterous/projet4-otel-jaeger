FROM nginx:1.27-alpine

ARG PORT_JAEGER=18686
ARG PORT_GRAFANA=13000
ARG PORT_PROMETHEUS=19090
ARG PORT_MAILPIT_UI=18025

RUN printf 'window.G4_CONFIG = {"jaeger":"http://localhost:%s","grafana":"http://localhost:%s","prometheus":"http://localhost:%s","mailpit":"http://localhost:%s"};\n' \
    "$PORT_JAEGER" "$PORT_GRAFANA" "$PORT_PROMETHEUS" "$PORT_MAILPIT_UI" > /usr/share/nginx/html/config.js

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY www/ /usr/share/nginx/html/

EXPOSE 80
