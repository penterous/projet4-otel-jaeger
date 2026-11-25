FROM nginx:1.27-alpine

RUN apk add --no-cache apache2-utils

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY entrypoint.sh /docker-entrypoint.d/99-generate-htpasswd.sh
RUN chmod 755 /docker-entrypoint.d/99-generate-htpasswd.sh

EXPOSE 16686 8025 9090 9093
