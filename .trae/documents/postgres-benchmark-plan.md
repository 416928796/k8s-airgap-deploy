# PostgreSQL 存储性能对比基准测试方案

## 概述

使用 Bitnami 官方 PostgreSQL Helm chart 部署两个 PostgreSQL 实例，分别使用 Mayastor 双副本存储和 LocalPath 存储，通过 pgbench 执行标准化基准测试，对比两种存储引擎在读写吞吐量、查询响应时间、并发处理能力等维度的性能差异，最终生成详细分析报告。

## 当前状态分析

### 已有基础设施

* **Mayastor 存储**：已部署双副本 StorageClass `mayastor-double-replica`（NVMe，provisioner `io.openebs.csi-mastor`）

* **LocalPath 存储**：已部署 StorageClass `openebs-hostpath`（provisioner `openebs.io/local`，basePath `/var/openebs/local`）

* **私有镜像仓库**：`172.25.128.67:9003`，containerd 已配置镜像（docker.io → 172.25.128.67:9003）

* **3 节点集群**：`k8s-master-01`、`k8s-worker-01`、`k8s-worker-02`

### 缺失部分（本方案需创建）

* 气隙环境准备脚本（下载 chart + 推送镜像）

* 两份 Helm values 文件（Mayastor 版 / LocalPath 版）

* pgbench 基准测试 Job 和脚本

* 测试报告模板

### 遵循的现有约定

* 镜像使用 `172.25.128.67:9003` 私有仓库前缀

* Namespace 按用途隔离

* 中文注释

* 脚本文件用 bash

## 用户决策

| 决策项          | 选择                                 |
| ------------ | ---------------------------------- |
| Mayastor 副本数 | 双副本（`mayastor-double-replica`，已部署） |
| 节点调度策略       | 不限制调度（由 K8s 自动调度）                  |
| 对比基准         | LocalPath `openebs-hostpath` 单副本   |
| PG 部署方式      | Bitnami 官方 Helm chart              |

## 技术选型

| 组件            | 选择                                   | 说明              |
| ------------- | ------------------------------------ | --------------- |
| PG Helm Chart | `bitnami/postgresql`                 | 官方维护，最广泛使用      |
| Chart 来源      | `https://charts.bitnami.com/bitnami` | Bitnami 官方仓库    |
| 部署模式          | `standalone`（单实例）                    | 无需主从复制，聚焦存储性能对比 |
| pgbench 工具    | Bitnami PG 镜像内置                      | 无需额外镜像          |

## 目录结构

```
e:\Code\002-k8s部署\postgres-benchmark\
├── charts/
│   └── postgresql-*.tgz              # Bitnami PostgreSQL chart 包（气隙离线，由 prepare.sh 下载）
├── values-mayastor.yaml               # Mayastor 版 Helm values
├── values-localpath.yaml              # LocalPath 版 Helm values
├── pgbench-job.yaml                   # pgbench 基准测试 Job
├── run-benchmark.sh                   # 一键执行脚本：部署→初始化→测试→采集结果
├── prepare.sh                         # 气隙环境准备脚本（下载 chart + 推送镜像）
├── cleanup.sh                         # 测试后清理资源脚本
└── REPORT.md                          # 测试报告（含环境配置、方法、数据、对比分析）
```

## 详细实施步骤

### 步骤 0：气隙环境准备脚本

**文件**：`postgres-benchmark/prepare.sh`

此脚本需在**有网环境**的机器上执行，准备以下离线资源：

```bash
#!/bin/bash
# 气隙环境准备脚本（在有网环境执行）
# 1. 下载 Bitnami PostgreSQL chart
# 2. 拉取并推送 PostgreSQL 镜像到私有仓库

set -e

CHART_VERSION=""  # 留空则拉取最新版
PRIVATE_REGISTRY="172.25.128.67:9003"

# 1. 添加 Bitnami 仓库并下载 chart
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm pull bitnami/postgresql ${CHART_VERSION:+--version $CHART_VERSION}
# 生成 postgresql-{version}.tgz 文件，移动到 charts/ 目录
mkdir -p charts
mv postgresql-*.tgz charts/

# 2. 获取 chart 的 appVersion（即 PG 版本号）
APP_VERSION=$(helm show chart bitnami/postgresql ${CHART_VERSION:+--version $CHART_VERSION} | grep appVersion | awk '{print $2}')
echo "PostgreSQL appVersion: $APP_VERSION"

# 3. 拉取并推送 PostgreSQL 镜像
docker pull bitnami/postgresql:$APP_VERSION
docker tag bitnami/postgresql:$APP_VERSION $PRIVATE_REGISTRY/bitnami/postgresql:$APP_VERSION
docker push $PRIVATE_REGISTRY/bitnami/postgresql:$APP_VERSION

echo "准备完成！请将 charts/ 目录和 values-*.yaml 传到气隙环境"
```

### 步骤 1：创建 Mayastor 版 Helm values

**文件**：`postgres-benchmark/values-mayastor.yaml`

```yaml
# Mayastor 版 PostgreSQL Helm values
# 使用 mayastor-double-replica StorageClass（NVMe 双副本）

global:
  imageRegistry: "172.25.128.67:9003"

# 单实例模式（无主从复制）
architecture: standalone

# 镜像配置（registry 由 global.imageRegistry 覆盖）
image:
  repository: bitnami/postgresql
  # tag 留空，使用 chart 默认 appVersion

# 认证配置
auth:
  postgresPassword: "benchmark123"
  database: "benchmark"

# 主节点配置
primary:
  # 持久化存储 —— 核心差异点
  persistence:
    enabled: true
    storageClass: "mayastor-double-replica"
    size: 20Gi
    accessModes:
      - ReadWriteOnce

  # 资源限制（确保公平对比）
  resources:
    requests:
      cpu: "2"
      memory: "2Gi"
    limits:
      cpu: "2"
      memory: "2Gi"

  # 自定义 postgresql.conf 参数（两实例完全一致）
  configuration: |
    shared_buffers = 512MB
    max_connections = 200
    random_page_cost = 1.1
    effective_cache_size = 1GB
    work_mem = 16MB
    maintenance_work_mem = 256MB
    wal_buffers = 16MB
    max_wal_size = 1GB
    synchronous_commit = on

# 禁用不需要的组件
volumePermissions:
  enabled: false
metrics:
  enabled: false
```

### 步骤 2：创建 LocalPath 版 Helm values

**文件**：`postgres-benchmark/values-localpath.yaml`

与步骤 1 完全一致，唯一差异：

```yaml
  persistence:
    enabled: true
    storageClass: "openebs-hostpath"   # ← 唯一差异：LocalPath 存储
    size: 20Gi
    accessModes:
      - ReadWriteOnce
```

其余所有参数（镜像、资源、PG 配置、认证）完全一致。

### 步骤 3：部署两个 PG 实例

通过 `run-benchmark.sh` 脚本执行（见步骤 5），核心命令：

```bash
# Mayastor 版
helm install pg-mayastor ./charts/postgresql-*.tgz \
  -f values-mayastor.yaml \
  -n pg-mayastor --create-namespace

# LocalPath 版
helm install pg-localpath ./charts/postgresql-*.tgz \
  -f values-localpath.yaml \
  -n pg-localpath --create-namespace
```

部署后的资源名称（Bitnami chart 命名规则）：

| 实例        | Namespace      | StatefulSet               | Service                   | Pod                         |
| --------- | -------------- | ------------------------- | ------------------------- | --------------------------- |
| Mayastor  | `pg-mayastor`  | `pg-mayastor-postgresql`  | `pg-mayastor-postgresql`  | `pg-mayastor-postgresql-0`  |
| LocalPath | `pg-localpath` | `pg-localpath-postgresql` | `pg-localpath-postgresql` | `pg-localpath-postgresql-0` |

pgbench 连接地址：

* Mayastor: `pg-mayastor-postgresql.pg-mayastor.svc.cluster.local:5432`

* LocalPath: `pg-localpath-postgresql.pg-localpath.svc.cluster.local:5432`

### 步骤 4：创建 pgbench 基准测试 Job

**文件**：`postgres-benchmark/pgbench-job.yaml`

使用 Bitnami PostgreSQL 镜像内置的 pgbench 工具，依次对两个实例执行全套测试。

```yaml
# pgbench 基准测试 Job
# 依次对 Mayastor 和 LocalPath 两个 PG 实例执行全套性能测试
apiVersion: batch/v1
kind: Job
metadata:
  name: pgbench-benchmark
  namespace: pg-mayastor
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: pgbench
          image: 172.25.128.67:9003/bitnami/postgresql:{PG_VERSION}
          command: ["/bin/bash", "-c"]
          args:
            - |
              #!/bin/bash
              # 内嵌测试脚本，见步骤 5 详细逻辑
              ...
          env:
            - name: PGPASSWORD
              value: "benchmark123"
```

### 步骤 5：基准测试脚本逻辑

**文件**：`postgres-benchmark/run-benchmark.sh`（本地编排脚本）

脚本执行流程：

```
1. 部署两个 PG 实例（helm install）
   helm install pg-mayastor ./charts/postgresql-*.tgz -f values-mayastor.yaml -n pg-mayastor --create-namespace
   helm install pg-localpath ./charts/postgresql-*.tgz -f values-localpath.yaml -n pg-localpath --create-namespace

2. 等待两个 PG 实例就绪
   kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=pg-mayastor -n pg-mayastor --timeout=300s
   kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=pg-localpath -n pg-localpath --timeout=300s

3. 数据初始化（pgbench -i -s 100）
   对两个实例分别执行初始化，scale=100 生成 ~150 万行 accounts 数据
   记录初始化耗时（反映写入吞吐量）

4. 执行测试矩阵（每实例每场景运行 60 秒）
   ┌─────────────────────────┬──────────────────────────────────┬──────────┐
   │ 测试场景                │ pgbench 参数                     │ 指标     │
   ├─────────────────────────┼──────────────────────────────────┼──────────┤
   │ A. 只读吞吐量           │ -S -c 10 -j 2 -T 60              │ TPS      │
   │ B. 读写混合吞吐量       │ -c 10 -j 2 -T 60                 │ TPS      │
   │ C. 写入压力（no-vacuum）│ -N -c 10 -j 2 -T 60              │ TPS      │
   │ D. 单客户端延迟         │ -c 1 -j 1 -T 60 -l              │ 延迟 ms   │
   │ E. 并发10              │ -c 10 -j 2 -T 60                 │ TPS      │
   │ F. 并发50              │ -c 50 -j 4 -T 60                 │ TPS      │
   │ G. 并发100             │ -c 100 -j 4 -T 60                │ TPS      │
   │ H. 持续稳定性           │ -c 50 -j 4 -T 300                │ TPS      │
   └─────────────────────────┴──────────────────────────────────┴──────────┘

5. 采集结果
   每次测试使用 pgbench 原生输出 + --aggregate-interval=1 采集延迟分布
   将结果写入文件并格式化为对比表格

6. 生成报告
   汇总数据填充到 REPORT.md
```

**关键测试参数说明**：

* `-s 100`：scale factor 100，约 1.5GB 数据量，足够体现存储 I/O 差异

* `-T 60`：每场景 60 秒持续时间，平衡测试精度与总耗时

* `-c`：客户端连接数（并发数）

* `-j`：pgbench 工作线程数

* `-S`：只读模式（纯 SELECT）

* `-N`：跳过 vacuum（写密集场景）

* `-l`：记录每事务延迟日志

### 步骤 6：创建清理脚本

**文件**：`postgres-benchmark/cleanup.sh`

```bash
#!/bin/bash
helm uninstall pg-mayastor -n pg-mayastor
helm uninstall pg-localpath -n pg-localpath
kubectl delete job pgbench-benchmark -n pg-mayastor --ignore-not-found
kubectl delete namespace pg-mayastor pg-localpath --ignore-not-found
```

### 步骤 7：创建测试报告模板

**文件**：`postgres-benchmark/REPORT.md`

报告结构：

1. **测试环境配置**

   * K8s 集群信息（节点数、版本）

   * 存储配置（Mayastor 双副本 NVMe vs LocalPath hostpath）

   * PostgreSQL 配置（Bitnami chart 版本、PG 版本、资源、参数）

   * pgbench 参数（scale、duration、并发数）

2. **测试方法**

   * 测试矩阵说明

   * 各场景的 pgbench 命令

   * 指标定义（TPS、平均延迟、p95 延迟）

3. **原始数据**

   * 每个场景的 Mayastor 和 LocalPath 原始输出

   * 初始化耗时对比

4. **性能对比分析**

   * 对比表格（TPS 差异百分比、延迟差异）

   * 按场景分析（只读/读写/并发各自结论）

   * 总结与建议

## 假设与前提条件

1. **镜像可用性**：`172.25.128.67:9003/bitnami/postgresql:{PG_VERSION}` 需在私有仓库中可用。由 `prepare.sh` 脚本在有网环境准备
2. **Chart 包可用**：`charts/postgresql-*.tgz` 需提前下载。由 `prepare.sh` 脚本在有网环境准备
3. **StorageClass 已部署**：`mayastor-double-replica` 和 `openebs-hostpath` 均已就绪（用户确认）
4. **DiskPool 可用**：NVMe DiskPool 已创建且有可用容量（至少 20Gi × 2 副本 = 40Gi）
5. **节点磁盘空间**：LocalPath 节点 `/var/openebs/local` 至少有 20Gi 可用空间
6. **kubeconfig 已配置**：本机 kubectl 和 helm 可访问集群
7. **PG 密码**：使用固定密码 `benchmark123`（仅测试用途）
8. **containerd mirror**：已配置 docker.io → 172.25.128.67:9003 镜像（用户环境已就绪）

## 验证步骤

1. **气隙准备验证**：

   ```bash
   ls charts/postgresql-*.tgz          # chart 包存在
   docker pull 172.25.128.67:9003/bitnami/postgresql:{PG_VERSION}  # 镜像可拉取
   ```

2. **部署验证**：

   ```bash
   kubectl get pods -n pg-mayastor     # pg-mayastor-postgresql-0 为 Running 且 Ready
   kubectl get pods -n pg-localpath    # pg-localpath-postgresql-0 为 Running 且 Ready
   ```

3. **存储验证**：

   ```bash
   kubectl get pvc -n pg-mayastor      # Bound, SC=mayastor-double-replica
   kubectl get pvc -n pg-localpath     # Bound, SC=openebs-hostpath
   ```

4. **连通性验证**：

   ```bash
   kubectl exec -n pg-mayastor pg-mayastor-postgresql-0 -- pg_isready
   kubectl exec -n pg-localpath pg-localpath-postgresql-0 -- pg_isready
   ```

5. **基准测试执行**：

   ```bash
   cd postgres-benchmark
   bash run-benchmark.sh
   ```

6. **报告生成验证**：

   ```bash
   cat REPORT.md    # 已填充测试数据
   ```

## 公平性保障措施

| 措施            | 说明                                                        |
| ------------- | --------------------------------------------------------- |
| 相同 Helm chart | 两个实例使用同一份 Bitnami chart tgz                               |
| 相同 PG 版本      | 由同一 chart 决定，保证版本一致                                       |
| 相同资源配置        | CPU 2 核 / 内存 2Gi / 存储 20Gi                                |
| 相同 PG 参数      | values 中 configuration 参数完全一致                             |
| 唯一变量          | storageClass（mayastor-double-replica vs openebs-hostpath） |
| 顺序执行          | 测试串行执行（先 A 全场景再 B 全场景），避免资源争抢                             |
| 预热机制          | 每场景正式测试前先运行 10 秒预热                                        |

