#!/bin/sh
# 按 KUBECTL_VERSION 选择与集群版本匹配的 kubectl 二进制。
# 未设置或对应版本不存在时，回落到镜像内的最新版本。
v="${KUBECTL_VERSION:-}"
[ -n "$v" ] || v="1.37"
bin="/usr/local/bin/kubectl-${v}"
[ -x "$bin" ] || bin="/usr/local/bin/kubectl-1.37"
exec "$bin" "$@"
