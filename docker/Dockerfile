# kubectl 官方只保证与 API Server ±1 个小版本兼容，因此镜像内预装多个版本，
# 由 KUBECTL_VERSION（各环境 monitor.env）选择，/usr/local/bin/kubectl 负责分发。
# 二进制取自阿里云对 pkgs.k8s.io 的镜像，避免直连 dl.k8s.io 过慢。
ARG KUBECTL_MINORS="1.30 1.31 1.32 1.33 1.34 1.35 1.36 1.37"

FROM alpine:3.20 AS kubectl-bins
ARG KUBECTL_MINORS
RUN set -eux; \
    apk add --no-cache curl dpkg; \
    mkdir -p /out; \
    for v in $KUBECTL_MINORS; do \
      base="https://mirrors.aliyun.com/kubernetes-new/core/stable/v${v}/deb"; \
      pkg="$(curl -fsSL --retry 3 "$base/Packages" \
        | awk '/^Package: kubectl$/{p=1;next} p && /^Filename:/{if (index($2,"amd64/")>0){print $2; exit}}')"; \
      test -n "$pkg"; \
      curl -fsSL --retry 3 -o /tmp/kubectl.deb "$base/$pkg"; \
      dpkg-deb -x /tmp/kubectl.deb /out; \
      mv /out/usr/bin/kubectl "/out/kubectl-${v}"; \
      rm -rf /out/usr /tmp/kubectl.deb; \
    done

FROM alpine:3.20

RUN apk add --no-cache bash curl jq ca-certificates tzdata lighttpd

COPY --from=kubectl-bins /out/kubectl-* /usr/local/bin/
COPY docker/kubectl-wrapper.sh /usr/local/bin/kubectl
COPY web/ /www/
COPY docker/lighttpd.conf /etc/lighttpd/log-monitor.conf

RUN chmod +x /usr/local/bin/kubectl

WORKDIR /scripts
