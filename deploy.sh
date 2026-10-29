#!/bin/bash
# 按环境部署错误日志监控
# 用法：./deploy.sh [cn|ru|eu|usw]
set -euo pipefail
cd "$(dirname "$0")"

ENV_NAME="${1:-cn}"
ENV_DIR="deploy/envs/$ENV_NAME"
if [ ! -d "$ENV_DIR" ]; then
  echo "未知环境：$ENV_NAME"
  echo "可选：$(ls deploy/envs | tr '\n' ' ')"
  exit 1
fi

# Windows 下编辑的文件转成 LF，避免脚本在容器里执行失败
sed -i 's/\r$//' monitor.sh scheduler.sh deploy/*.yaml deploy/envs/*/gateway.yaml deploy/envs/*/monitor.env

# 读取环境配置；同一份文件也会作为 ConfigMap 挂载给 monitor.sh
# shellcheck disable=SC1090
. "$ENV_DIR/monitor.env"

: "${IMAGE:=registry.cn-hangzhou.aliyuncs.com/kafree/log-monitor:1.4.0}"
if [ -z "${IMAGE_PULL_SECRET+x}" ]; then IMAGE_PULL_SECRET="acr"; fi

echo "当前 kubectl context: $(kubectl config current-context)"
echo "部署环境：$ENV_NAME（集群 $CLUSTER_NAME）"

kubectl apply -f deploy/00-namespace.yaml
kubectl apply -f deploy/01-rbac.yaml

# 复制已有仓库凭据（Secret 不能跨命名空间引用）；未配置来源时跳过
if [ -n "${SOURCE_PULL_SECRET_NAMESPACE:-}" ] && [ -n "${SOURCE_PULL_SECRET_NAME:-}" ] && [ -n "$IMAGE_PULL_SECRET" ]; then
  DOCKER_CFG=$(kubectl -n "$SOURCE_PULL_SECRET_NAMESPACE" get secret "$SOURCE_PULL_SECRET_NAME" -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
  kubectl -n log-monitor create secret generic "$IMAGE_PULL_SECRET" \
    --type=kubernetes.io/dockerconfigjson \
    --from-literal=.dockerconfigjson="$DOCKER_CFG" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# 配置直接来自环境目录，避免多环境各维护一份 ConfigMap YAML
kubectl -n log-monitor create configmap log-monitor-config \
  --from-file=monitor.env="$ENV_DIR/monitor.env" \
  --dry-run=client -o yaml | kubectl apply -f -

# 允许环境目录覆盖 webhook；默认使用 deploy/03-secret.yaml
SECRET_FILE="$ENV_DIR/secret.yaml"
[ -f "$SECRET_FILE" ] || SECRET_FILE="deploy/03-secret.yaml"
if grep -q 'REPLACE_ME' "$SECRET_FILE"; then
  echo "错误：$SECRET_FILE 中的企业微信 webhook 仍是占位值 REPLACE_ME"
  echo "请先复制 deploy/03-secret.yaml 到 $ENV_DIR/secret.yaml 并填入真实 key，再重新执行"
  exit 1
fi
kubectl apply -f "$SECRET_FILE"

kubectl -n log-monitor create configmap log-monitor-script \
  --from-file=monitor.sh --from-file=scheduler.sh \
  --dry-run=client -o yaml | kubectl apply -f -

# 用环境配置的镜像替换默认镜像；没有拉取凭据时移除 imagePullSecrets
DEPLOY_FILE=$(mktemp)
sed "s|registry.cn-hangzhou.aliyuncs.com/kafree/log-monitor:1.4.0|$IMAGE|g" deploy/04-deployment.yaml > "$DEPLOY_FILE"
if [ -n "$IMAGE_PULL_SECRET" ]; then
  sed -i "s|name: acr|name: $IMAGE_PULL_SECRET|" "$DEPLOY_FILE"
else
  sed -i '/imagePullSecrets:/,+1d' "$DEPLOY_FILE"
fi
kubectl apply -f "$DEPLOY_FILE"
rm -f "$DEPLOY_FILE"

kubectl apply -f deploy/05-service.yaml
kubectl apply -f "$ENV_DIR/gateway.yaml"

kubectl -n log-monitor rollout status deploy/log-monitor --timeout=180s

echo "部署完成：env=$ENV_NAME cluster=$CLUSTER_NAME"
echo "页面地址：$WEB_BASE_URL"
