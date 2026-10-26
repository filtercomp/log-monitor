FROM alpine:3.20

RUN apk add --no-cache bash curl jq ca-certificates tzdata lighttpd \
 && curl -fsSL --http1.1 --retry 3 -o /usr/local/bin/kubectl https://dl.k8s.io/release/v1.32.1/bin/linux/amd64/kubectl \
 && chmod +x /usr/local/bin/kubectl

COPY web/ /www/
COPY docker/lighttpd.conf /etc/lighttpd/log-monitor.conf

WORKDIR /scripts
