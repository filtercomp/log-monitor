# log-monitor

Kubernetes 集群内的轻量错误日志监控与告警工具，不需要部署 Loki / ELK / 日志采集 Agent。

它在集群内以单个 Deployment 常驻，定时通过 `kubectl exec` 读取业务 Pod 的 `/tmp/logs/error/*.log`，按工作负载聚合后推送企业微信摘要，同时把每个副本的最新日志快照写入内置 Web 页面供查看。

## 功能

- **无侵入采集**：不要求业务改造，也不需要 sidecar 或日志采集 DaemonSet
- **按工作负载聚合**：同一 Deployment 的多个副本合并为一条告警，避免重复消息
- **保留每个副本**：每个 Pod/容器 各存一份日志快照，页面可切换副本查看
- **告警精简**：只发集群、命名空间、工作负载、副本数和页面链接，不内嵌日志正文
- **内置页面**：告警列表、命名空间/工作负载/Pod 筛选、关键字高亮、只看匹配行、100/200/1000/2000 行切换
- **多环境部署**：CN 使用 ALB Ingress，海外环境使用 APISIX（ApisixRoute + ApisixUpstream）

## 工作原理

```
scheduler.sh (PID 1)
├── 后台启动 lighttpd，提供静态页面与 /www/data 下的 JSON 快照
└── 到达扫描时间点 → monitor.sh
    ├── kubectl get ns/pods，解析 Pod 所属 Deployment/StatefulSet
    ├── kubectl exec 进入业务容器，按 mtime 判断窗口内变更的文件
    ├── 取最新日志尾部 N 行，为每个 Pod/容器 写一份快照
    ├── 按工作负载聚合写入 /www/data/alerts.json
    └── 仅告警时间点前 15 分钟推送企业微信
```

- 默认扫描时间：`09/11/13/15/17`（Asia/Shanghai）
- 检测窗口：`CHECK_INTERVAL_HOURS` 小时 + 10 分钟容差，避免漏掉边界日志
- 数据只保留当天，跨天自动清空
- 快照存放在内存 `emptyDir` 中，Pod 重建后丢失

## 目录结构

```
.
├── monitor.sh                # 扫描、聚合、生成快照、发送告警
├── scheduler.sh              # 常驻进程：lighttpd + 定时调度
├── deploy.sh                 # 按环境部署：./deploy.sh [cn|ru|eu|usw]
├── deploy/
│   ├── 00-namespace.yaml
│   ├── 01-rbac.yaml          # 集群级 RBAC（namespaces/pods/exec/replicasets）
│   ├── 03-secret.yaml        # 企微 webhook 模板（占位值）
│   ├── 04-deployment.yaml
│   ├── 05-service.yaml
│   └── envs/
│       ├── cn/               # ALB Ingress
│       ├── ru/               # APISIX
│       ├── eu/               # APISIX
│       └── usw/              # APISIX
├── docker/
│   ├── Dockerfile
│   └── lighttpd.conf
└── web/                      # 纯静态页面（HTML/CSS/JS）
```

每个环境目录包含：

- `monitor.env`：监控配置，同时会被打成 ConfigMap 挂载给容器
- `gateway.yaml`：入口清单，CN 是 Ingress，海外是 ApisixRoute/ApisixUpstream
- `secret.yaml`（可选，不提交）：该环境专用的企微 webhook，优先于 `deploy/03-secret.yaml`

## 快速开始

### 1. 构建并推送镜像

```bash
docker build -t <your-registry>/log-monitor:1.2.0 -f docker/Dockerfile .
docker push <your-registry>/log-monitor:1.2.0
```

### 2. 修改环境配置

```bash
vi deploy/envs/cn/monitor.env
```

至少修改以下内容：

| 变量 | 说明 |
| --- | --- |
| `CLUSTER_NAME` | 告警中显示的集群名称 |
| `INCLUDE_NAMESPACES` | 要监控的命名空间，逗号分隔；留空则扫描全部（再排除 `EXCLUDE_NAMESPACES`） |
| `WEB_BASE_URL` | 页面访问地址，需与 `gateway.yaml` 中的 host 一致 |
| `IMAGE` | 镜像地址 |
| `IMAGE_PULL_SECRET` | 目标命名空间内的拉取凭据 Secret；留空则部署时移除 `imagePullSecrets` |
| `SOURCE_PULL_SECRET_NAMESPACE` / `SOURCE_PULL_SECRET_NAME` | 从哪个命名空间的哪个 Secret 复制拉取凭据，留空则跳过 |

### 3. 配置企业微信 Webhook

```bash
cp deploy/03-secret.yaml deploy/envs/cn/secret.yaml
vi deploy/envs/cn/secret.yaml   # 替换 REPLACE_ME
```

`deploy/envs/*/secret.yaml` 已被 `.gitignore` 忽略，不会被提交。

### 4. 部署

```bash
kubectl config current-context   # 先确认集群没连错
./deploy.sh cn
```

海外环境：

```bash
# 先按实际修改 deploy/envs/ru/monitor.env 与 gateway.yaml
./deploy.sh ru
```

## 配置项

`monitor.env` 中的监控参数：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CLUSTER_NAME` | `cn-prod` | 集群名称 |
| `ERROR_LOG_DIR` | `/tmp/logs/error` | 容器内错误日志目录 |
| `CHECK_INTERVAL_HOURS` | `2` | 检测窗口（小时） |
| `SNAPSHOT_LINES` | `2000` | 每个副本保留的最新日志行数 |
| `ALERT_HOURS` | `9,11,13,15,17` | 扫描时间点；仅在这些时间点前 15 分钟内发送告警 |
| `MAX_MESSAGES` | `20` | 单次扫描最多发送条数，超出部分发汇总 |
| `INCLUDE_NAMESPACES` | 空 | 只扫描这些命名空间 |
| `EXCLUDE_NAMESPACES` | `kube-system,kube-public,kube-node-lease` | 排除的命名空间 |
| `EXCLUDE_CONTAINERS` | `^(istio-proxy\|linkerd-proxy\|.*-init)$` | 跳过 sidecar / init 容器 |
| `DRY_RUN` | `false` | `true` 时只打印不推送 |
| `WEB_BASE_URL` | 空 | 告警中的页面链接前缀 |

## 网关说明

### CN：ALB Ingress

```yaml
spec:
  ingressClassName: alb-config
  rules:
    - host: kafree-cn-log-monitor.coffee-iot.com
```

证书由集群的 `AlbConfig` 管理。注意：新增 Ingress 会触发 ALB 控制器全量同步，证书请统一在 `AlbConfig` 中维护，不要只在控制台改监听器。

### 海外：APISIX

需要集群已安装 APISIX Ingress Controller，并存在覆盖该域名的 `ApisixTls`。清单同时创建 `ApisixUpstream`（与 Service 同名，控制器自动关联）和 `ApisixRoute`。

## 告警效果

```
**错误日志告警**
> 集群：cn-prod
> 命名空间：kafree-swarm
> 工作负载：Deployment/payment-service
> 受影响：2 个 Pod/容器；容器：payment-service
> 代表 Pod：payment-service-7d9f-abcde（容器 payment-service）
> 摘要：ERROR 3 行 / Exception 1 处（2 份副本日志）
> 扫描时间：2026-10-26 11:00:00（检测窗口 2 小时）
> [查看日志详情](https://.../#/alert/20261026110000-01)
```

## 使用限制

- 业务容器内必须有 `ERROR_LOG_DIR` 目录，且镜像内包含可用的 `sh`、`stat`、`tail`、`date`
- 需要对 Pod 执行 `kubectl exec` 的权限（RBAC 已包含）
- 页面默认**没有认证**，请只在内网/受信网络暴露，或在网关层自行加鉴权
- 日志快照存放在内存（`emptyDir`，默认上限 256Mi），只保留当天
- Pod 重建后，重建前的快照不可恢复
- 时区固定为 `Asia/Shanghai`

## License

[MIT](LICENSE)
