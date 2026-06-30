# 内网环境 PostgreSQL 部署与性能测试文档 — 实施计划

## 概述

在现有 OpenEBS（Mayastor + LocalPath）存储集群基础上，创建一套完整的 PostgreSQL 部署与性能对比基准测试方案。产出包括一份涵盖 7 大章节的综合文档和全套可执行部署文件（values、job、脚本、模板），用于对比 Mayastor 双副本 NVMe 存储与 LocalPath hostpath 存储在 PostgreSQL 工作负载下的性能差异。

## 当前状态分析

### 已有基础设施

| 组件              | 状态     | 说明                                                             |
| --------------- | ------ | -------------------------------------------------------------- |
| Mayastor 存储     | ✅ 已部署  | `mayastor-double-replica` SC（NVMe 双副本），3 节点 DiskPool 就绪        |
| LocalPath 存储    | ✅ 已部署  | `openebs-hostpath` SC，basePath `/var/openebs/local`            |
| 私有镜像仓库          | ✅ 已就绪  | `172.25.128.67:9003`（HTTP，skip\_verify）                        |
| containerd 镜像加速 | ✅ 已配置  | docker.io/ghcr.io/quay.io/registry.k8s.io → 172.25.128.67:9003 |
| 集群              | ✅ 3 节点 | `k8s-master-01`、`k8s-worker-01`、`k8s-worker-02`                |
| skopeo 脚本规范     | ✅ 已有   | `check-images.sh` / `push-from-dir.sh` 可参照                     |

### 缺失部分（本计划需创建）

* PostgreSQL 部署目录 `postgres-benchmark/`（尚不存在）

* 综合部署与测试文档

* 两份 Helm values 文件（Mayastor / LocalPath）

* pgbench 基准测试 Job 和执行脚本

* 气隙环境准备脚本

* 镜像清单与报告模板

### 现有计划文档

项目已有 `.trae/documents/postgres-benchmark-plan.md` 计划文档，本计划在其基础上扩展为完整实施版本，补充用户要求的 7 大章节内容。

## 用户决策

| 决策项           | 选择            | 说明                                 |
| ------------- | ------------- | ---------------------------------- |
| PostgreSQL 版本 | PostgreSQL 16 | chart 15.5.38，appVersion 16.4.0    |
| 交付物形式         | 文档 + 全套部署文件   | README.md + values + job + 脚本 + 模板 |
| 镜像/Chart 准备方式 | 仅清单 + 命令模板    | 文档中列出镜像名称版本和 skopeo 命令模板，用户手动执行    |
| Mayastor 副本数  | 双副本           | `mayastor-double-replica`（已部署）     |
| 对比基准          | LocalPath     | `openebs-hostpath`（已部署）            |
| PG 部署模式       | standalone    | 单实例，聚焦存储性能对比                       |
| 测试工具          | pgbench       | Bitnami PG 镜像内置，无需额外镜像             |

## 版本信息

| 组件                       | 版本                                         | 说明                       |
| ------------------------ | ------------------------------------------ | ------------------------ |
| Bitnami postgresql chart | 15.5.38                                    | 对应 PG 16.x 的最新 chart 版本  |
| PostgreSQL               | 16.4.0                                     | chart 默认 appVersion      |
| 镜像                       | `bitnami/postgresql:16.4.0-debian-12-r0`   | 具体-r后缀在拉取时确定             |
| Chart 仓库                 | `https://charts.bitnami.com/bitnami`       | 传统 HTTP 仓库（离线 helm pull） |
| OCI 仓库（备选）               | `oci://registry-1.docker.io/bitnamicharts` | Bitnami 新版 OCI 分发        |

## 文件清单

将创建以下 9 个文件，均位于 `postgres-benchmark/` 目录下：

| 序号 | 文件路径                                       | 类型     | 说明                         |
| -- | ------------------------------------------ | ------ | -------------------------- |
| 1  | `postgres-benchmark/README.md`             | 文档     | 主文档，7 大章节综合指南              |
| 2  | `postgres-benchmark/values-mayastor.yaml`  | 配置     | Mayastor 版 PG Helm values  |
| 3  | `postgres-benchmark/values-localpath.yaml` | 配置     | LocalPath 版 PG Helm values |
| 4  | `postgres-benchmark/pgbench-job.yaml`      | K8s 资源 | pgbench 基准测试 Job           |
| 5  | `postgres-benchmark/prepare.sh`            | 脚本     | 气隙环境准备（下载 chart + 生成镜像清单）  |
| 6  | `postgres-benchmark/run-benchmark.sh`      | 脚本     | 一键执行：部署→初始化→测试→采集          |
| 7  | `postgres-benchmark/cleanup.sh`            | 脚本     | 测试后清理资源                    |
| 8  | `postgres-benchmark/images-list.txt`       | 清单     | 所需镜像完整列表                   |
| 9  | `postgres-benchmark/REPORT-template.md`    | 模板     | 测试报告模板（含对比表格与图表模板）         |

## 各文件详细内容

### 1. `postgres-benchmark/README.md` — 主文档

**内容结构（7 大章节）**：

#### 第一章：环境准备

* 内网环境要求：K8s 1.23+、Helm 3.8.0+、3 节点集群

* 依赖组件版本表：Mayastor 2.10.0、OpenEBS LocalPath 4.4.0、Bitnami PG chart 15.5.38、PG 16.4.0

* 系统配置要求：hugepages（Mayastor 节点）、节点磁盘空间、containerd 镜像加速配置

* 前置条件检查清单（StorageClass、DiskPool、私有仓库可达性）

#### 第二章：部署步骤

* **2.1 Helm 部署 Mayastor 版 PostgreSQL**

  * 气隙准备：`helm pull` 下载 chart 包到 `charts/` 目录

  * 镜像准备：skopeo 拉取并推送到私有仓库

  * 部署命令：`helm install pg-mayastor ./charts/postgresql-15.5.38.tgz -f values-mayastor.yaml -n pg-mayastor --create-namespace`

  * 等待就绪：`kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=pg-mayastor -n pg-mayastor --timeout=300s`

  * 验证步骤：PVC Bound、Pod Running、pg\_isready

* **2.2 Helm 部署 Localpath 版 PostgreSQL**

  * 同上流程，使用 `values-localpath.yaml` 和 namespace `pg-localpath`

  * 验证步骤同上

#### 第三章：基准测试方案

* **3.1 测试工具选择与配置**

  * pgbench（Bitnami PG 镜像内置）

  * 测试参数说明：`-s`(scale factor)、`-c`(clients)、`-j`(threads)、`-T`(duration)、`-S`(read-only)、`-N`(no-vacuum)、`-l`(log latency)

* **3.2 测试指标定义**

  * 吞吐量：TPS（Transactions Per Second）

  * 响应时间：平均延迟（ms）、p95/p99 延迟

  * 资源利用率：CPU、内存、IOPS、磁盘吞吐（通过 kubectl top / Prometheus）

  * 初始化耗时：pgbench -i 执行时间（反映写入吞吐量）

* **3.3 测试执行步骤与数据记录方法**

  * 测试矩阵表（8 个场景，每场景 60 秒）

  * 数据记录方法：pgbench 原生输出 + `--aggregate-interval=1` 采集延迟分布

  * 结果文件命名与存储规范

#### 第四章：性能对比分析

* **4.1 对比表格模板**

  * 初始化耗时对比表

  * TPS 对比表（8 场景 × 2 存储）

  * 延迟对比表（平均/p95/p99）

  * 资源利用率对比表

* **4.2 图表模板**

  * 柱状图模板：TPS 对比（Mayastor vs LocalPath）

  * 折线图模板：并发数 vs TPS

  * 箱线图模板：延迟分布

* **4.3 数据分析方法与结论撰写指南**

  * 差异百分比计算方法

  * 按场景分析框架（只读/读写/写入/并发）

  * 结论撰写模板与建议

#### 第五章：资源准备清单

* **5.1 Helm Chart 包**

  * chart 名称：`bitnami/postgresql`

  * chart 版本：`15.5.38`

  * appVersion：`16.4.0`

  * 下载命令：`helm pull bitnami/postgresql --version 15.5.38`

  * 备选 OCI 下载：`helm pull oci://registry-1.docker.io/bitnamicharts/postgresql --version 15.5.38`

* **5.2 镜像清单**

  | 镜像名称                        | 版本                    | 用途                    |
  | --------------------------- | --------------------- | --------------------- |
  | `bitnami/postgresql`        | `16.4.0-debian-12-r0` | PG 主镜像 + pgbench      |
  | `bitnami/os-shell`          | `latest`              | volumePermissions（可选） |
  | `bitnami/postgres-exporter` | `latest`              | metrics（可选，默认禁用）      |

#### 第六章：内网资源导入指南

* **6.1 skopeo 镜像导入命令模板**

  * 单个镜像拉取：`skopeo copy docker://bitnami/postgresql:16.4.0-debian-12-r0 dir:./postgresql-16.4.0`

  * 单个镜像推送：`skopeo copy --dest-tls-verify=false dir:./postgresql-16.4.0 docker://172.25.128.67:9003/bitnami/postgresql:16.4.0-debian-12-r0`

  * 直接中转：`skopeo copy --dest-tls-verify=false docker://bitnami/postgresql:16.4.0-debian-12-r0 docker://172.25.128.67:9003/bitnami/postgresql:16.4.0-debian-12-r0`

  * 批量拉取脚本模板（读取 images-list.txt 循环执行）

  * 批量推送脚本模板（参照项目 `push-from-dir.sh` 风格）

* **6.2 验证方法**

  * 使用 skopeo inspect 验证镜像存在

  * 参照项目 `check-images.sh` 脚本风格编写验证命令

  * 验证 chart 包完整性

#### 第七章：部署验证与故障排除

* **7.1 部署验证步骤**

  * Helm release 状态检查

  * Pod/PVC/Service 状态检查

  * pg\_isready 连通性验证

  * 存储卷验证（Mayastor PVC / LocalPath PVC）

* **7.2 常见问题与解决方案**

  * Pod 一直 Pending：StorageClass 不存在 / DiskPool 容量不足 / 节点调度问题

  * 镜像拉取失败：私有仓库不可达 / 镜像未推送 / containerd 配置错误

  * PVC Pending：StorageClass waitForFirstConsumer / 无可用节点

  * pgbench 连接失败：密码错误 / Service 未就绪 / 网络策略

  * 性能异常低：hugepages 未配置 / 磁盘 IO 瓶颈 / 资源限制过小

### 2. `postgres-benchmark/values-mayastor.yaml`

```yaml
# Mayastor 版 PostgreSQL Helm values
# 使用 mayastor-double-replica StorageClass（NVMe 双副本）
# 部署命令：
#   helm install pg-mayastor ./charts/postgresql-*.tgz \
#     -f values-mayastor.yaml -n pg-mayastor --create-namespace

global:
  imageRegistry: "172.25.128.67:9003"

architecture: standalone

image:
  repository: bitnami/postgresql
  # tag 留空，使用 chart 默认 appVersion（16.4.0）

auth:
  postgresPassword: "benchmark123"
  database: "benchmark"

primary:
  persistence:
    enabled: true
    storageClass: "mayastor-double-replica"
    size: 20Gi
    accessModes:
      - ReadWriteOnce

  resources:
    requests:
      cpu: "2"
      memory: "2Gi"
    limits:
      cpu: "2"
      memory: "2Gi"

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

volumePermissions:
  enabled: false
metrics:
  enabled: false
```

### 3. `postgres-benchmark/values-localpath.yaml`

与 Mayastor 版完全一致，唯一差异：`storageClass: "openebs-hostpath"`。

### 4. `postgres-benchmark/pgbench-job.yaml`

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
          image: 172.25.128.67:9003/bitnami/postgresql:16.4.0-debian-12-r0
          command: ["/bin/bash", "-c"]
          args:
            - |
              #!/bin/bash
              # 内嵌完整测试脚本（8 场景 × 2 实例）
              # 详见 run-benchmark.sh 中的测试逻辑
              ...
          env:
            - name: PGPASSWORD
              value: "benchmark123"
```

实际实现中，Job YAML 包含完整的内嵌测试脚本，涵盖：

* 数据初始化（pgbench -i -s 100）

* 8 个测试场景循环执行

* 结果格式化输出

### 5. `postgres-benchmark/prepare.sh`

参照项目现有 `check-images.sh` / `push-from-dir.sh` 风格：

* `#!/bin/bash` + `set -e`

* `# ===== 配置区 =====` 分段

* 变量使用 `${VAR:-default}` 形式

* 功能：

  1. 添加 Bitnami 仓库并下载 chart（`helm pull bitnami/postgresql --version 15.5.38`）
  2. 获取 chart appVersion（`helm show chart`）
  3. 生成/更新 `images-list.txt` 镜像清单
  4. 提供 skopeo 拉取镜像命令模板（不自动执行，仅输出提示）
  5. 输出后续步骤指引

### 6. `postgres-benchmark/run-benchmark.sh`

参照项目现有脚本风格，一键执行脚本：

1. 检查前置条件（chart 包存在、镜像可用）
2. 部署两个 PG 实例（helm install）
3. 等待 Pod 就绪（kubectl wait）
4. 数据初始化（pgbench -i -s 100）并记录耗时
5. 执行 8 个测试场景（每场景 60 秒，H 场景 300 秒）
6. 采集结果并格式化为对比表格
7. 输出到 `results/` 目录

测试矩阵：

| 场景         | pgbench 参数          | 指标    |
| ---------- | ------------------- | ----- |
| A. 只读吞吐量   | -S -c 10 -j 2 -T 60 | TPS   |
| B. 读写混合吞吐量 | -c 10 -j 2 -T 60    | TPS   |
| C. 写入压力    | -N -c 10 -j 2 -T 60 | TPS   |
| D. 单客户端延迟  | -c 1 -j 1 -T 60 -l  | 延迟 ms |
| E. 并发10    | -c 10 -j 2 -T 60    | TPS   |
| F. 并发50    | -c 50 -j 4 -T 60    | TPS   |
| G. 并发100   | -c 100 -j 4 -T 60   | TPS   |
| H. 持续稳定性   | -c 50 -j 4 -T 300   | TPS   |

### 7. `postgres-benchmark/cleanup.sh`

```bash
#!/bin/bash
# 清理 PostgreSQL 基准测试资源
set -e
helm uninstall pg-mayastor -n pg-mayastor
helm uninstall pg-localpath -n pg-localpath
kubectl delete job pgbench-benchmark -n pg-mayastor --ignore-not-found
kubectl delete namespace pg-mayastor pg-localpath --ignore-not-found
```

### 8. `postgres-benchmark/images-list.txt`

```
# PostgreSQL 基准测试所需镜像清单
# 格式：源镜像地址（用于 skopeo 拉取和推送）
# 使用方法：参考 README.md 第六章内网资源导入指南

# ===== 必需镜像 =====
bitnami/postgresql:16.4.0-debian-12-r0

# ===== 可选镜像（默认禁用） =====
# bitnami/os-shell:latest              # volumePermissions.enabled=true 时需要
# bitnami/postgres-exporter:latest     # metrics.enabled=true 时需要
```

### 9. `postgres-benchmark/REPORT-template.md`

报告模板结构：

1. 测试环境配置（集群信息、存储配置、PG 配置、pgbench 参数）
2. 测试方法说明
3. 原始数据区（占位表格）
4. 性能对比分析（对比表格 + 图表占位 + 分析模板）
5. 总结与建议（结论撰写模板）

包含以下表格模板：

* 初始化耗时对比表

* TPS 对比表（8 场景 × 2 存储 + 差异百分比）

* 延迟对比表（平均/p95/p99 × 2 存储）

* 资源利用率对比表

## 假设与前提条件

1. Mayastor `mayastor-double-replica` SC 已就绪（用户确认）
2. LocalPath `openebs-hostpath` SC 已就绪（用户确认）
3. 私有仓库 `172.25.128.67:9003` 可达且可推送
4. containerd 镜像加速已配置（项目已就绪）
5. 执行环境有 kubectl + helm 可访问集群
6. 执行环境有 skopeo（用于镜像导入）
7. PG 密码使用固定密码 `benchmark123`（仅测试用途）
8. DiskPool 有足够容量（≥ 40Gi，20Gi × 2 副本）
9. LocalPath 节点有足够磁盘空间（≥ 20Gi）

## 公平性保障措施

| 措施            | 说明                                                        |
| ------------- | --------------------------------------------------------- |
| 相同 Helm chart | 两个实例使用同一份 chart tgz                                       |
| 相同 PG 版本      | chart 15.5.38，PG 16.4.0                                   |
| 相同资源配置        | CPU 2 核 / 内存 2Gi / 存储 20Gi                                |
| 相同 PG 参数      | configuration 完全一致                                        |
| 唯一变量          | storageClass（mayastor-double-replica vs openebs-hostpath） |
| 顺序执行          | 测试串行执行，避免资源争抢                                             |
| 预热机制          | 每场景正式测试前运行 10 秒预热                                         |

## 验证步骤

1. **文件完整性验证**：检查 9 个文件均已创建
2. **YAML 语法验证**：`helm lint` 或 `yamllint` 检查 values 和 job 文件
3. **Shell 脚本语法验证**：`bash -n` 检查脚本语法
4. **镜像清单完整性**：确认 images-list.txt 包含所有必需镜像
5. **文档章节完整性**：确认 README.md 包含 7 大章节
6. **脚本可执行性**：确认 prepare.sh / run-benchmark.sh / cleanup.sh 可正常执行
7. **报告模板完整性**：确认 REPORT-template.md 包含所有对比表格模板

## 实施顺序

1. 创建 `postgres-benchmark/` 目录
2. 创建 `images-list.txt`（镜像清单，基础文件）
3. 创建 `values-mayastor.yaml` 和 `values-localpath.yaml`
4. 创建 `pgbench-job.yaml`
5. 创建 `prepare.sh`（气隙准备脚本）
6. 创建 `run-benchmark.sh`（基准测试执行脚本）
7. 创建 `cleanup.sh`（清理脚本）
8. 创建 `REPORT-template.md`（报告模板）
9. 创建 `README.md`（主文档，最后创建，引用以上所有文件）

