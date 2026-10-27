# log-monitor

Kubernetes 集群内的轻量错误日志监控与告警工具，不需要部署 Loki / ELK / 日志采集 Agent。

它在集群内以单个 Deployment 常驻，按固定间隔（默认 300 秒）通过 `kubectl exec` 读取业务 Pod 的 `/tmp/logs/error/*.log`，按工作负载聚合后推送企业微信摘要，同时把每个副本的最新日志快照写入内置 Web 页面供查看。

## 功能

- **无侵入采集**：不要求业务改造，也不需要 sidecar 或日志采集 DaemonSet
- **按工作负载聚合**：同一 Deployment 的多个副本合并为一条告警，避免重复消息
- **告警降噪**：首次发现立即告警，持续报错每 2 小时最多提醒一次，20 分钟无新增错误发送恢复通知
- **保留每个副本**：每个 Pod/容器 各存一份日志快照，页面可切换副本查看
- **告警精简**：只发集群、命名空间、工作负载、受影响副本数、ERROR/Exception 统计和页面链接，不内嵌日志正文
- **内置页面**：告警列表、命名空间/工作负载筛选、关键字高亮、只看匹配行、100/200/1000/2000 行切换
- **多环境部署**：CN 使用 ALB Ingress，海外环境使用 APISIX（ApisixRoute + ApisixUpstream）

## 工作原理

```
scheduler.sh (PID 1)
├── 后台启动 lighttpd，提供静态页面与 /www/data 下的 JSON 快照
└── 每 SCAN_INTERVAL_SECONDS 秒（仅 ACTIVE_HOURS 时段内）→ monitor.sh
    ├── kubectl get ns/pods，解析 Pod 所属 Deployment/StatefulSet
    ├── kubectl exec 进入业务容器，按 mtime 判断最近窗口内变更的文件
    ├── 取最新日志尾部 N 行，为每个 Pod/容器 写一份快照（文件名固定，覆盖写入）
    ├── 按工作负载 upsert /www/data/alerts.json，同一工作负载只保留一条
    └── 读取 /www/data/state.json 状态机，决定首次告警 / 重复提醒 / 恢复通知
```

- 默认巡检间隔：`300` 秒
- 默认运行时段：`09:00-17:59`（Asia/Shanghai），时段外只刷新页面不发消息
- 检测窗口：最近 `RECENT_WINDOW_MINUTES`（默认 6）分钟内有写入的日志文件
- 重复提醒：同一工作负载持续有新错误时，每 `RENOTIFY_HOURS`（默认 2）小时最多一次
- 恢复判定：连续 `RECOVERY_MINUTES`（默认 20）分钟无新增错误，发送一次恢复通知并清除页面记录
- 恢复后再次报错会立即重新告警
- 时段外不发送任何消息；此时若已满足恢复条件，恢复通知会顺延到下一个时段内的巡检再发
- 数据只保留当天，跨天自动清空
- 状态与快照存放在内存 `emptyDir` 中，Pod 重建后丢失（可能重复告警一次）

## 目录结构

```
.
├── monitor.sh                # 扫描、聚合、生成快照、发送告警
├── scheduler.sh              # 常驻进程：lighttpd + 定时调度
├── deploy.sh                 # 按环境部署：./deploy.sh [cn|ru|eu|usw]，并动态生成两个 ConfigMap
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
docker build -t <your-registry>/log-monitor:1.3.0 -f docker/Dockerfile .
docker push <your-registry>/log-monitor:1.3.0
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

## 更新配置或脚本

`monitor.env` 和两个脚本都**不在镜像里**。`deploy.sh` 在部署时用 `kubectl create configmap --from-file` 动态生成两个 ConfigMap：

| ConfigMap | 来源 | 挂载位置 |
| --- | --- | --- |
| `log-monitor-config` | `deploy/envs/<env>/monitor.env` | `/config/monitor.env` |
| `log-monitor-script` | `monitor.sh`、`scheduler.sh` | `/scripts` |

因此仓库的 `deploy/` 下没有这两个 ConfigMap 的 YAML 文件，它们只在部署时生成。

修改配置或脚本后，重新执行对应环境的部署即可，**不需要重建镜像，也不需要重启 Pod**：

```bash
./deploy.sh cn
```

两个 volume 都未使用 `subPath`，kubelet 会在约 1 分钟内把新内容同步进 Pod 内的文件；`scheduler.sh` 下一轮巡检会重新调用 `/scripts/monitor.sh`，直接使用新脚本。状态（`state.json`）保留，不会因此重复告警。

只有修改 `web/` 页面或 `docker/` 下的 Dockerfile、lighttpd 配置时才需要重新构建镜像，并同步提升版本号（`imagePullPolicy: IfNotPresent`，版本不变会继续使用节点上的旧镜像）。

## 配置项

`monitor.env` 中的监控参数：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CLUSTER_NAME` | `cn-prod` | 集群名称 |
| `ERROR_LOG_DIR` | `/tmp/logs/error` | 容器内错误日志目录 |
| `SCAN_INTERVAL_SECONDS` | `300` | 巡检间隔（秒） |
| `ACTIVE_HOURS` | `9-17` | 运行时段，含两端小时（09:00-17:59）；时段外只更新页面不发消息 |
| `RECENT_WINDOW_MINUTES` | `6` | 每次巡检回看窗口（分钟） |
| `RECOVERY_MINUTES` | `20` | 连续多少分钟无新增错误判定为恢复 |
| `RENOTIFY_HOURS` | `2` | 持续报错时的重复提醒间隔（小时） |
| `SNAPSHOT_LINES` | `2000` | 每个副本保留的最新日志行数 |
| `MAX_MESSAGES` | `20` | 单次巡检最多发送条数，超出部分发汇总 |
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

首次告警：

```
**🔥 错误日志告警**
> 集群：cn-prod
> 命名空间：kafree-swarm
> 工作负载：Deployment/payment-service
> 受影响：2 个 Pod/容器；容器：payment-service
> 摘要：ERROR 3 行 / Exception 1 处
> 扫描时间：2026-10-26 11:00:00
> [查看日志详情](https://.../#/alert/w-1234567890)
```

持续报错时每 2 小时最多再提醒一次，标题为 `🔥 错误日志持续告警`，正文与首次告警一致；连续 20 分钟无新增错误后发送一次 `💚 错误日志恢复`。标题中的 emoji 和颜色（告警橙红、恢复绿色）用于快速区分两类消息。

## 使用限制

- 业务容器内必须有 `ERROR_LOG_DIR` 目录，且镜像内包含可用的 `sh`、`stat`、`tail`、`date`
- 需要对 Pod 执行 `kubectl exec` 的权限（RBAC 已包含）
- 页面默认**没有认证**，请只在内网/受信网络暴露，或在网关层自行加鉴权
- 日志快照存放在内存（`emptyDir`，默认上限 256Mi），只保留当天
- Pod 重建后，重建前的快照不可恢复
- 页面每 60 秒自动刷新告警列表；日志正文在点开某条告警时才读取。页面上的「刷新」按钮只是重新读取 `alerts.json`，不会触发扫描
- 时区固定为 `Asia/Shanghai`

## License

[MIT](LICENSE)
