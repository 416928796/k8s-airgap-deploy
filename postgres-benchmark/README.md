# 内网环境 PostgreSQL 部署与性能测试文档

> 本文档详细描述在内网（气隙）Kubernetes 环境中，使用 Helm 部署基于 Mayastor 和 LocalPath 两种存储引擎的 PostgreSQL 数据库，并通过 pgbench 执行标准化基准测试，对比两种存储引擎在 PostgreSQL 工作负载下的性能差异。

## 目录

- [一、环境准备](#一环境准备)
- [二、部署步骤](#二部署步骤)
- [三、基准测试方案](#三基准测试方案)
- [四、性能对比分析](#四性能对比分析)
- [五、资源准备清单](#五资源准备清单)
- [六、内网资源导入指南](#六内网资源导入指南)
- [七、部署验证与故障排除](#七部署验证与故障排除)
- [附录：文件清单](#附录文件清单)

---

## 一、环境准备

### 1.1 内网环境要求

| 项目 | 要求 | 说明 |
|------|------|------|
| Kubernetes | 1.23+ | 集群已运行且可访问 |
| Helm | 3.8.0+ | 支持 OCI registry 拉取 |
| kubectl | 已配置 | 可访问集群，kubeconfig 已就绪 |
| skopeo | 已安装 | 用于镜像导入（版本 1.10+） |
| 集群节点 | 3 节点 | `k8s-master-01`、`k8s-worker-01`、`k8s-worker-02` |
| 私有镜像仓库 | 可达 | `172.25.128.67:9003`（HTTP，skip_verify） |
| containerd 镜像加速 | 已配置 | docker.io → 172.25.128.67:9003 |

### 1.2 依赖组件版本

| 组件 | 版本 | 说明 |
|------|------|------|
| OpenEBS Mayastor | 2.10.0 | NVMe 存储引擎，已部署 |
| OpenEBS LocalPath | 4.4.0 | 本地路径存储，已部署 |
| Bitnami PostgreSQL chart | 18.7.5 | 对应 PostgreSQL 18.x |
| PostgreSQL | 18.4.0 | chart 默认 appVersion |
| pgbench | 随 PG 镜像 | 内置于 Bitnami PG 镜像 |

### 1.3 系统配置要求

#### 1.3.1 Mayastor 节点 hugepages 配置

每个 Mayastor io-engine Pod 需要 2GB hugepages。在所有 Mayastor 调度节点上执行：

```bash
# 复制 hugepages 配置到 sysctl.d
sudo cp openebs/mayastor/99-mayastor-hugepages.conf /etc/sysctl.d/
sudo sysctl --system

# 验证
cat /proc/meminfo | grep HugePages
# 预期输出：
# HugePages_Total:    1024
# HugePages_Free:     1024
# HugePages_Rsvd:        0
# HugePages_Surp:        0
```

#### 1.3.2 节点磁盘空间

| 节点 | 用途 | 最低可用空间 |
|------|------|-------------|
| Mayastor 调度节点 | NVMe DiskPool | 40Gi（20Gi × 2 副本） |
| LocalPath 调度节点 | `/var/openebs/local` | 20Gi |

#### 1.3.3 containerd 镜像加速配置

确保 containerd 已配置镜像加速（项目已就绪），使 `docker.io` 请求自动重定向到 `172.25.128.67:9003`：

```text
# 配置文件位置：/etc/containerd/certs.d/docker.io/hosts.toml
server = "http://172.25.128.67:9003"
[host."http://172.25.128.67:9003"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
```

### 1.4 前置条件检查清单

在开始部署前，逐项确认以下条件已满足：

```bash
# 1. 检查 StorageClass
kubectl get sc mayastor-double-replica
kubectl get sc openebs-hostpath

# 2. 检查 Mayastor DiskPool 状态
kubectl get diskpool -n openebs

# 3. 检查私有仓库可达性
curl -s http://172.25.128.67:9003/v2/_catalog | head -20

# 4. 检查节点状态
kubectl get nodes -o wide

# 5. 检查 hugepages（Mayastor 节点）
kubectl get nodes -o jsonpath='{.items[*].status.allocatable.hugepages\.2Mi}'
```

> ⚠️ **注意**：如果以上任何一项检查失败，请先解决后再继续部署。

---

## 二、部署步骤

### 2.1 Helm 部署 Mayastor 版 PostgreSQL

#### 2.1.1 气隙准备（有网环境执行）

在有网环境的机器上执行 `prepare.sh` 脚本，下载 Helm chart 包并生成镜像清单：

```bash
cd postgres-benchmark

# 下载 chart 包并生成镜像清单
bash prepare.sh

# 如需同时拉取镜像到本地目录（用于气隙传输）
bash prepare.sh --pull
```

执行完成后，`charts/` 目录将包含 `postgresql-18.7.5.tgz`，`images/images-list.txt` 将包含所需镜像列表。如使用 `--pull` 参数，镜像会拉取到 `pg-images/` 目录（当前项目已预拉取到 `images/postgresql-latest/`）。

> ✅ **当前状态**：本项目已完成气隙准备，`charts/` 目录下已有 `postgresql-18.7.5.tgz`（及旧版 `postgresql-15.5.38.tgz`），`images/` 目录下已有预拉取的镜像和清单文件。如无需更新版本，可直接跳到 [2.1.2 镜像准备](#212-镜像准备导入内网仓库)。

#### 2.1.2 镜像准备（导入内网仓库）

按照 [第六章内网资源导入指南](#六内网资源导入指南) 将镜像推送到私有仓库 `172.25.128.67:9003`。

#### 2.1.3 部署 PostgreSQL 实例

将 `charts/` 目录和 values 文件传到内网环境后，执行部署：

```bash
cd postgres-benchmark

# 部署 Mayastor 版 PostgreSQL
helm install pg-mayastor ./charts/postgresql-18.7.5.tgz \
  -f values-mayastor.yaml \
  -n pg-mayastor --create-namespace

# 预期输出：
# NAME: pg-mayastor
# LAST DEPLOYED: ...
# NAMESPACE: pg-mayastor
# STATUS: deployed
# REVISION: 1
# NOTES: ...
```

#### 2.1.4 等待 Pod 就绪

```bash
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/instance=pg-mayastor \
  -n pg-mayastor --timeout=300s

# 验证 Pod 状态
kubectl get pods -n pg-mayastor
# 预期输出：
# NAME                       READY   STATUS    RESTARTS   AGE
# pg-mayastor-postgresql-0   1/1     Running   0          2m
```

#### 2.1.5 验证 Mayastor 版部署

```bash
# 检查 PVC
kubectl get pvc -n pg-mayastor
# 预期：STATUS 为 Bound，StorageClass 为 mayastor-double-replica

# 检查 Service
kubectl get svc -n pg-mayastor
# 预期：pg-mayastor-postgresql 服务存在

# 验证 PG 连通性
kubectl exec -n pg-mayastor pg-mayastor-postgresql-0 -- pg_isready
# 预期输出：/var/run/postgresql:5432 - accepting connections
```

### 2.2 Helm 部署 Localpath 版 PostgreSQL

#### 2.2.1 部署 PostgreSQL 实例

```bash
cd postgres-benchmark

# 部署 LocalPath 版 PostgreSQL
helm install pg-localpath ./charts/postgresql-18.7.5.tgz \
  -f values-localpath.yaml \
  -n pg-localpath --create-namespace

# 预期输出：
# NAME: pg-localpath
# LAST DEPLOYED: ...
# NAMESPACE: pg-localpath
# STATUS: deployed
# REVISION: 1
```

#### 2.2.2 等待 Pod 就绪

```bash
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/instance=pg-localpath \
  -n pg-localpath --timeout=300s

# 验证 Pod 状态
kubectl get pods -n pg-localpath
# 预期输出：
# NAME                         READY   STATUS    RESTARTS   AGE
# pg-localpath-postgresql-0    1/1     Running   0          2m
```

#### 2.2.3 验证 LocalPath 版部署

```bash
# 检查 PVC
kubectl get pvc -n pg-localpath
# 预期：STATUS 为 Bound，StorageClass 为 openebs-hostpath

# 验证 PG 连通性
kubectl exec -n pg-localpath pg-localpath-postgresql-0 -- pg_isready
# 预期输出：/var/run/postgresql:5432 - accepting connections
```

### 2.3 部署后资源概览

部署完成后，集群中应存在以下资源：

| 实例 | Namespace | StatefulSet | Service | Pod |
|------|-----------|-------------|---------|-----|
| Mayastor | `pg-mayastor` | `pg-mayastor-postgresql` | `pg-mayastor-postgresql` | `pg-mayastor-postgresql-0` |
| LocalPath | `pg-localpath` | `pg-localpath-postgresql` | `pg-localpath-postgresql` | `pg-localpath-postgresql-0` |

pgbench 连接地址（集群内部）：

- Mayastor: `pg-mayastor-postgresql.pg-mayastor.svc.cluster.local:5432`
- LocalPath: `pg-localpath-postgresql.pg-localpath.svc.cluster.local:5432`

### 2.4 一键部署（可选）

也可使用 `run-benchmark.sh` 脚本一键完成部署和测试：

```bash
# 完整流程：部署→初始化→测试→采集结果
bash run-benchmark.sh

# 如已有 PG 实例，跳过部署直接测试
bash run-benchmark.sh --skip-deploy
```

---

## 三、基准测试方案

### 3.1 测试工具选择与配置

#### 3.1.1 工具选择

| 工具 | 来源 | 用途 |
|------|------|------|
| pgbench | Bitnami PG 镜像内置 | TPC-B 类基准测试 |
| kubectl top | Kubernetes 内置 | 资源利用率监控 |
| kubectl exec | Kubernetes 内置 | 远程执行 pgbench |

> pgbench 是 PostgreSQL 官方提供的基准测试工具，模拟 TPC-B 工作负载，是评估 PostgreSQL 存储性能的标准方法。

#### 3.1.2 pgbench 参数说明

| 参数 | 含义 | 本方案取值 |
|------|------|-----------|
| `-s` | scale factor（数据规模因子） | 100（约 1.5GB 数据） |
| `-c` | 并发客户端连接数 | 1 / 10 / 50 / 100 |
| `-j` | pgbench 工作线程数 | 1 / 2 / 4 |
| `-T` | 测试持续时间（秒） | 60 / 300 |
| `-S` | 只读模式（纯 SELECT 查询） | - |
| `-N` | 跳过 vacuum（写密集场景） | - |
| `-l` | 记录每事务延迟日志 | - |
| `--aggregate-interval=1` | 每秒聚合输出延迟统计 | - |
| `-i` | 初始化模式（创建测试表和数据） | - |

### 3.2 测试指标定义

#### 3.2.1 核心指标

| 指标 | 单位 | 说明 | 数据来源 |
|------|------|------|----------|
| TPS | tps | 每秒事务数（吞吐量） | pgbench 输出 |
| 平均延迟 | ms | 每事务平均响应时间 | pgbench 输出 |
| p95 延迟 | ms | 95% 分位延迟 | pgbench `--aggregate-interval` |
| p99 延迟 | ms | 99% 分位延迟 | pgbench `--aggregate-interval` |
| 初始化耗时 | s | pgbench -i 执行时间 | 脚本计时 |

#### 3.2.2 辅助指标

| 指标 | 单位 | 说明 | 数据来源 |
|------|------|------|----------|
| CPU 利用率 | % | PG Pod CPU 使用率 | `kubectl top pod` |
| 内存利用率 | % | PG Pod 内存使用率 | `kubectl top pod` |
| IOPS | ops/s | 存储每秒 I/O 操作数 | Prometheus / 节点监控 |
| 磁盘吞吐 | MB/s | 存储读写带宽 | Prometheus / 节点监控 |

### 3.3 测试执行步骤与数据记录方法

#### 3.3.1 测试矩阵

共 8 个测试场景，每实例每场景运行指定时长：

| 场景 | 描述 | pgbench 参数 | 持续时间 | 主要指标 |
|------|------|-------------|----------|----------|
| A | 只读吞吐量 | `-S -c 10 -j 2 -T 60` | 60s | TPS |
| B | 读写混合吞吐量 | `-c 10 -j 2 -T 60` | 60s | TPS |
| C | 写入压力 | `-N -c 10 -j 2 -T 60` | 60s | TPS |
| D | 单客户端延迟 | `-c 1 -j 1 -T 60 -l` | 60s | 延迟 ms |
| E | 并发 10 | `-c 10 -j 2 -T 60` | 60s | TPS |
| F | 并发 50 | `-c 50 -j 4 -T 60` | 60s | TPS |
| G | 并发 100 | `-c 100 -j 4 -T 60` | 60s | TPS |
| H | 持续稳定性 | `-c 50 -j 4 -T 300` | 300s | TPS |

#### 3.3.2 执行流程

```
1. 数据初始化（pgbench -i -s 100）
   对两个实例分别执行初始化，记录耗时

2. 串行测试（先 A 全场景，再 B 全场景）
   每场景正式测试前运行 10 秒预热
   使用 --aggregate-interval=1 采集延迟分布

3. 结果采集
   每次测试输出写入 results/ 目录
   文件命名：benchmark_YYYYMMDD_HHMMSS.log
```

#### 3.3.3 数据记录方法

**方式一：通过 Job 执行（推荐）**

```bash
# 创建 pgbench 测试 Job
kubectl apply -f pgbench-job.yaml

# 查看 Job 状态
kubectl get job pgbench-benchmark -n pg-mayastor

# 查看测试结果（实时跟随）
kubectl logs job/pgbench-benchmark -n pg-mayastor -f

# 将结果保存到文件
kubectl logs job/pgbench-benchmark -n pg-mayastor > results/benchmark_$(date +%Y%m%d_%H%M%S).log
```

**方式二：通过脚本执行（推荐）**

```bash
# 一键执行完整测试流程
bash run-benchmark.sh

# 结果自动保存到 results/ 目录
ls results/
# 预期：benchmark_20260623_120000.log
```

#### 3.3.4 结果文件命名与存储规范

`run-benchmark.sh` 将所有测试输出（含初始化耗时、各场景 pgbench 结果）统一写入单个日志文件：

```
results/
└── benchmark_20260623_120000.log      # 完整测试日志（含 Mayastor + LocalPath 全部场景）
```

> 日志文件内按实例和场景分段输出，可通过搜索 `[Mayastor]` / `[LocalPath]` 和 `场景` 关键字定位各部分数据。初始化耗时在日志中以 `初始化耗时: Xs` 行记录。

### 3.4 公平性保障措施

| 措施 | 说明 |
|------|------|
| 相同 Helm chart | 两个实例使用同一份 chart tgz 包 |
| 相同 PG 版本 | chart 18.7.5，PG 18.4.0 |
| 相同资源配置 | CPU 2 核 / 内存 2Gi / 存储 20Gi |
| 相同 PG 参数 | values 中 configuration 参数完全一致 |
| 唯一变量 | storageClass（mayastor-double-replica vs openebs-hostpath） |
| 顺序执行 | 测试串行执行（先 Mayastor 全场景，再 LocalPath 全场景），避免资源争抢 |
| 预热机制 | 每场景正式测试前先运行 10 秒预热 |

---

## 四、性能对比分析

### 4.1 对比表格模板

#### 4.1.1 初始化耗时对比表

| 存储引擎 | 初始化耗时（s） | 差异 |
|----------|----------------|------|
| Mayastor (双副本 NVMe) | ________ | 基准 |
| LocalPath (hostpath) | ________ | ________ |

> 差异计算方式：`(LocalPath - Mayastor) / Mayastor × 100%`，正值表示 LocalPath 更慢

#### 4.1.2 TPS 对比表

| 场景 | Mayastor TPS | LocalPath TPS | 差异 (%) | 优势方 |
|------|-------------|--------------|----------|--------|
| A. 只读吞吐量 | ________ | ________ | ________ | ________ |
| B. 读写混合吞吐量 | ________ | ________ | ________ | ________ |
| C. 写入压力 | ________ | ________ | ________ | ________ |
| D. 单客户端延迟 | ________ | ________ | ________ | ________ |
| E. 并发 10 | ________ | ________ | ________ | ________ |
| F. 并发 50 | ________ | ________ | ________ | ________ |
| G. 并发 100 | ________ | ________ | ________ | ________ |
| H. 持续稳定性 | ________ | ________ | ________ | ________ |

> 差异计算方式：`(Mayastor - LocalPath) / LocalPath × 100%`，正值表示 Mayastor 更快

#### 4.1.3 延迟对比表

| 场景 | 指标 | Mayastor (ms) | LocalPath (ms) | 差异 (%) |
|------|------|--------------|----------------|----------|
| D. 单客户端延迟 | 平均延迟 | ________ | ________ | ________ |
| D. 单客户端延迟 | p95 延迟 | ________ | ________ | ________ |
| D. 单客户端延迟 | p99 延迟 | ________ | ________ | ________ |
| B. 读写混合 | 平均延迟 | ________ | ________ | ________ |
| B. 读写混合 | p95 延迟 | ________ | ________ | ________ |
| B. 读写混合 | p99 延迟 | ________ | ________ | ________ |

#### 4.1.4 资源利用率对比表

| 指标 | Mayastor | LocalPath | 说明 |
|------|----------|-----------|------|
| CPU 平均利用率 (%) | ________ | ________ | |
| CPU 峰值利用率 (%) | ________ | ________ | |
| 内存平均利用率 (%) | ________ | ________ | |
| 内存峰值利用率 (%) | ________ | ________ | |

### 4.2 图表模板

#### 4.2.1 柱状图：TPS 对比

```
TPS 对比图（示例）

  TPS
  │
  │  ████                              ████
  │  ████  ████                        ████  ████
  │  ████  ████  ████                  ████  ████  ████
  │  ████  ████  ████  ████            ████  ████  ████  ████
  │  ████  ████  ████  ████  ████      ████  ████  ████  ████  ████
  └──────────────────────────────┬───────────────────────────────
    A     B     C     D     E      F     G     H
              Mayastor              LocalPath
```

**绘制建议**：使用 Excel / Python matplotlib / Gnuplot 绘制分组柱状图，X 轴为测试场景，Y 轴为 TPS。

#### 4.2.2 折线图：并发数 vs TPS

```
并发数 vs TPS（示例）

  TPS
  │                          · · · · · Mayastor
  │                    · · ──────────
  │              · · ──
  │        · · ──              ─ ─ ─ ─ ─ LocalPath
  │  · · ──              · · ──
  └──────────────────────────────────────
    1       10       50       100
              并发客户端数
```

**绘制建议**：使用折线图，X 轴为并发数（1/10/50/100），Y 轴为 TPS，两条线分别为 Mayastor 和 LocalPath。

#### 4.2.3 箱线图：延迟分布

```
延迟分布（示例）

  延迟(ms)
  │         ┌──┐
  │         │  │         ┌──┐
  │      ┌──┤  │      ┌──┤  │
  │   ┌──┤  │  │   ┌──┤  │  │
  │───┴──┴──┴──┴───┴──┴──┴──┴───
  │   Mayastor       LocalPath
```

**绘制建议**：使用箱线图展示延迟分布，包括最小值、Q1、中位数、Q3、最大值。

### 4.3 数据分析方法与结论撰写指南

#### 4.3.1 差异百分比计算方法

```text
TPS 差异 = (Mayastor TPS - LocalPath TPS) / LocalPath TPS × 100%
  正值 → Mayastor 更快
  负值 → LocalPath 更快

延迟差异 = (Mayastor 延迟 - LocalPath 延迟) / LocalPath 延迟 × 100%
  正值 → Mayastor 延迟更高（更慢）
  负值 → Mayastor 延迟更低（更快）
```

#### 4.3.2 按场景分析框架

| 场景类型 | 分析重点 | 预期结论方向 |
|----------|----------|-------------|
| 只读（A） | 存储读取性能、缓存命中率 | NVMe 应显著优于 HDD |
| 读写混合（B） | 综合读写能力 | NVMe 应优于 LocalPath |
| 写入压力（C） | WAL 写入、fsync 性能 | NVMe 应显著优于 HDD |
| 单客户端延迟（D） | 最小响应时间 | NVMe 延迟应更低 |
| 并发（E/F/G） | 高并发下 I/O 调度 | NVMe 并发优势应更明显 |
| 持续稳定性（H） | 长时间性能衰减 | 关注性能曲线是否平稳 |

#### 4.3.3 结论撰写模板

```markdown
## 测试结论

### 总体性能对比

在本次测试中，Mayastor（双副本 NVMe）与 LocalPath（hostpath）在 PostgreSQL
工作负载下的性能对比如下：

- 吞吐量方面：Mayastor 在 [场景] 中 TPS 为 ____，相比 LocalPath 的 ____ 
  [提升/降低] 了 ____%
- 延迟方面：Mayastor 平均延迟为 ____ms，相比 LocalPath 的 ____ms 
  [降低/增加] 了 ____%
- 初始化耗时：Mayastor 耗时 ____s，LocalPath 耗时 ____s

### 按场景分析

1. 只读场景（A）：__________
2. 读写混合场景（B）：__________
3. 写入压力场景（C）：__________
4. 并发场景（E/F/G）：__________
5. 持续稳定性（H）：__________

### 建议

- 对于 [场景] 类型的工作负载，推荐使用 ________ 存储
- ________ 存储在 ________ 场景下有明显优势
- 综合考虑性能和可靠性，推荐 ________
```

---

## 五、资源准备清单

### 5.1 Helm Chart 包

| 项目 | 值 | 说明 |
|------|-----|------|
| Chart 名称 | `bitnami/postgresql` | Bitnami 官方 PostgreSQL chart |
| Chart 版本 | `18.7.5` | 对应 PG 18.x 的最新 chart |
| App 版本 | `18.4.0` | PostgreSQL 18.4.0 |
| Chart 仓库 | `https://charts.bitnami.com/bitnami` | 传统 HTTP 仓库 |
| OCI 仓库（备选） | `oci://registry-1.docker.io/bitnamicharts` | Bitnami OCI 分发 |

**下载命令**：

```bash
# 方式1：传统 HTTP 仓库
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm pull bitnami/postgresql --version 18.7.5

# 方式2：OCI registry（需 helm 3.8.0+）
helm pull oci://registry-1.docker.io/bitnamicharts/postgresql --version 18.7.5

# 也可使用本项目的 prepare.sh 脚本自动下载
bash prepare.sh
```

> ⚠️ **注意**：从 2025 年 8 月 28 日起，Bitnami 不再向 Docker Hub OCI registry 发布新的 chart 版本。`https://charts.bitnami.com/bitnami` 传统仓库仍可使用，但建议验证最新可用版本。如需最新功能，可使用 Bitnami Secure Images（商业版）。

> ✅ **当前状态**：本项目 `charts/` 目录已包含 `postgresql-18.7.5.tgz`（当前使用）和 `postgresql-15.5.38.tgz`（旧版备用），无需重复下载。

### 5.2 镜像清单

| 镜像名称 | 版本 | 用途 | 是否必需 |
|----------|------|------|----------|
| `bitnami/postgresql` | `latest` | PG 主镜像 + pgbench 工具 | ✅ 必需 |
| `bitnami/os-shell` | `latest` | volumePermissions 初始化容器 | ❌ 可选（默认禁用） |
| `bitnami/postgres-exporter` | `latest` | Prometheus 指标导出 | ❌ 可选（默认禁用） |

> ⚠️ **注意**：Bitnami PostgreSQL 18.4.0 chart 当前使用 `latest` 标签，而非版本号标签（如 `18.4.0-debian-12-r0`）。镜像已预拉取并保存到 `images/postgresql-latest/` 目录（skopeo dir 格式），可直接推送到内网仓库。

**完整镜像地址**（含 registry 前缀）：

```text
docker.io/bitnami/postgresql:latest
```

**内网仓库目标地址**：

```text
172.25.128.67:9003/bitnami/postgresql:latest
```

**从本地预拉取目录推送（已就绪）**：

```bash
# images/postgresql-latest/ 目录已包含 skopeo dir 格式的镜像
# 直接推送到内网仓库
skopeo copy --dest-tls-verify=false \
  dir:./images/postgresql-latest \
  docker://172.25.128.67:9003/bitnami/postgresql:latest
```

---

## 六、内网资源导入指南

### 6.1 使用 skopeo 工具向内网环境导入镜像

#### 6.1.1 前置条件

- 已安装 skopeo（版本 1.10+）
- 外网环境可访问 `docker.io`
- 内网仓库 `172.25.128.67:9003` 可达（HTTP，无需 TLS）

#### 6.1.2 单个镜像导入命令模板

**方式一：直接中转（需同时可访问外网和内网）**

```bash
# 从 Docker Hub 直接复制到内网仓库
skopeo copy --dest-tls-verify=false \
  docker://bitnami/postgresql:latest \
  docker://172.25.128.67:9003/bitnami/postgresql:latest
```

**方式二：先拉取到本地目录，再推送到内网（气隙环境推荐）**

```bash
# 步骤1：在外网环境拉取镜像到本地目录
mkdir -p ./pg-images
skopeo copy \
  docker://bitnami/postgresql:latest \
  dir:./pg-images/bitnami_postgresql_latest

# 步骤2：将本地目录传到内网环境（U盘/SCP/其他方式）

# 步骤3：在内网环境推送到私有仓库
skopeo copy --dest-tls-verify=false \
  dir:./pg-images/bitnami_postgresql_latest \
  docker://172.25.128.67:9003/bitnami/postgresql:latest
```

> ✅ **当前状态**：本项目已预拉取镜像到 `images/postgresql-latest/` 目录（skopeo dir 格式），可直接使用方式二步骤3的命令推送，只需将 `dir:` 路径改为 `dir:./images/postgresql-latest`。

#### 6.1.3 批量镜像导入脚本模板

```bash
#!/bin/bash
# 批量拉取镜像到本地目录（在外网环境执行）
# 用法：bash pull-images.sh

set -e

REGISTRY="docker.io"
LOCAL_DIR="./pg-images"
IMAGES_LIST="./images-list.txt"

mkdir -p "${LOCAL_DIR}"

while IFS= read -r line; do
  # 跳过注释和空行
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue

  # 去掉 registry 前缀
  img_no_registry=$(echo "${line}" | sed 's|^[^/]*/||')
  # 生成目录名（将 / 替换为 _）
  dir_name="${img_no_registry//\//_}"

  echo ">>> 拉取: ${line}"
  skopeo copy "docker://${line}" "dir:${LOCAL_DIR}/${dir_name}"
  echo "  [✓] 已保存到 ${LOCAL_DIR}/${dir_name}"
done < "${IMAGES_LIST}"

echo ""
echo "========== 拉取完成 =========="
echo "镜像目录: ${LOCAL_DIR}"
ls -1 "${LOCAL_DIR}"
```

```bash
#!/bin/bash
# 批量推送镜像到内网仓库（在内网环境执行）
# 用法：bash push-images.sh
# 参照项目 openebs/mayastor/push-from-dir.sh 风格

set -e

REGISTRY="172.25.128.67:9003"
LOCAL_DIR="./pg-images"

for dir in "${LOCAL_DIR}"/*; do
  [ -d "${dir}" ] || continue

  # 从目录名还原镜像名：最后一个下划线替换为冒号
  dir_name=$(basename "${dir}")
  img_name=$(echo "${dir_name}" | sed 's/_\([^_]*\)$/: \1/')

  # 判断首段是否含 .（区分带 registry 前缀的镜像）
  first_segment=$(echo "${img_name}" | cut -d'/' -f1)
  if [[ "${first_segment}" != *"."* ]]; then
    # 不含 .，说明没有 registry 前缀，需要添加
    target_img="${REGISTRY}/${img_name}"
  else
    # 含 .，已有 registry 前缀，替换为目标 registry
    target_img="${REGISTRY}/$(echo "${img_name}" | sed 's|^[^/]*/|')"
  fi

  echo ">>> 推送: ${dir_name} -> ${target_img}"
  skopeo copy --dest-tls-verify=false "dir:${dir}" "docker://${target_img}"
  echo "  [✓] 成功"
done

echo ""
echo "========== 推送完成 =========="
```

#### 6.1.4 Helm Chart 包导入

```bash
# chart 包无需特殊导入，直接将 postgresql-18.7.5.tgz 文件复制到内网环境
# 放到 postgres-benchmark/charts/ 目录下即可

# 当前项目已包含两个 chart 版本：
#   postgresql-18.7.5.tgz   — 当前使用（PG 18.4.0）
#   postgresql-15.5.38.tgz  — 旧版备用（PG 15.x）
# 另有 charts/postgresql/ 解包目录，可查看 chart 源码和默认 values

# 验证 chart 包
helm show chart ./charts/postgresql-18.7.5.tgz
# 预期输出包含：
# apiVersion: v2
# appVersion: "18.4.0"
# version: 18.7.5
# name: postgresql
```

### 6.2 验证方法

#### 6.2.1 镜像验证

使用 skopeo inspect 验证镜像是否已存在于内网仓库：

```bash
# 验证单个镜像
skopeo inspect --tls-verify=false \
  docker://172.25.128.67:9003/bitnami/postgresql:latest

# 预期输出包含：
# {
#     "Name": "172.25.128.67:9003/bitnami/postgresql",
#     "Digest": "sha256:...",
#     "RepoTags": ["latest"],
#     ...
# }
```

#### 6.2.2 批量验证（参照项目 check-images.sh 风格）

```bash
#!/bin/bash
# 批量验证镜像是否已推送到内网仓库
# 参照项目 openebs/mayastor/check-images.sh

REGISTRY="172.25.128.67:9003"
IMAGES_LIST="./images-list.txt"

FOUND=0
MISSING=0

while IFS= read -r line; do
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue

  img_no_registry=$(echo "${line}" | sed 's|^[^/]*/||')
  full_img="${REGISTRY}/${img_no_registry}"

  if skopeo inspect --tls-verify=false "docker://${full_img}" >/dev/null 2>&1; then
    echo "  [✓] ${full_img}"
    FOUND=$((FOUND + 1))
  else
    echo "  [✗] ${full_img} 缺失"
    MISSING=$((MISSING + 1))
  fi
done < "${IMAGES_LIST}"

echo ""
echo "========== 验证结果 =========="
echo "已有:   ${FOUND}"
echo "缺失:   ${MISSING}"

if [ ${MISSING} -gt 0 ]; then
  echo "请补充推送缺失镜像后再部署。"
  exit 1
else
  echo "所有镜像已就绪，可以开始部署。"
fi
```

#### 6.2.3 Chart 包完整性验证

```bash
# 验证 chart 包
ls -la charts/postgresql-18.7.5.tgz

# 查看 chart 信息
helm show chart charts/postgresql-18.7.5.tgz | grep -E "^(name|version|appVersion):"
# 预期输出：
# name: postgresql
# version: 18.7.5
# appVersion: "18.4.0"

# 渲染验证（检查模板是否正常）
helm template pg-test charts/postgresql-18.7.5.tgz \
  -f values-mayastor.yaml \
  --namespace pg-mayastor | head -20
```

#### 6.2.4 StorageClass 验证

```bash
# 验证 StorageClass 存在
kubectl get sc mayastor-double-replica openebs-hostpath

# 验证 Mayastor DiskPool 有足够容量
kubectl get diskpool -n openebs -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CAPACITY:.status.capacity

# 验证 LocalPath 节点磁盘空间
kubectl debug node/$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') -it --image=busybox -- df -h /var/openebs/local
```

---

## 七、部署验证与故障排除

### 7.1 部署验证步骤

#### 7.1.1 Helm Release 状态检查

```bash
# 检查 Helm release 状态
helm list -n pg-mayastor
helm list -n pg-localpath

# 预期输出：
# NAME          NAMESPACE      STATUS   REVISION   AGE
# pg-mayastor   pg-mayastor    deployed 1          5m
```

#### 7.1.2 Pod 状态检查

```bash
# 检查 Pod 状态
kubectl get pods -n pg-mayastor -o wide
kubectl get pods -n pg-localpath -o wide

# 预期：STATUS 为 Running，READY 为 1/1

# 查看 Pod 事件（如有异常）
kubectl describe pod -n pg-mayastor -l app.kubernetes.io/instance=pg-mayastor
```

#### 7.1.3 PVC 状态检查

```bash
# 检查 PVC 状态
kubectl get pvc -n pg-mayastor
kubectl get pvc -n pg-localpath

# 预期：
# Mayastor:  StorageClass 为 mayastor-double-replica，STATUS 为 Bound
# LocalPath: StorageClass 为 openebs-hostpath，STATUS 为 Bound
```

#### 7.1.4 Service 连通性验证

```bash
# 检查 Service
kubectl get svc -n pg-mayastor
kubectl get svc -n pg-localpath

# 验证 PG 连通性
kubectl exec -n pg-mayastor pg-mayastor-postgresql-0 -- pg_isready
kubectl exec -n pg-localpath pg-localpath-postgresql-0 -- pg_isready

# 预期输出：/var/run/postgresql:5432 - accepting connections
```

#### 7.1.5 存储卷验证

```bash
# Mayastor PVC 验证
kubectl describe pvc -n pg-mayastor | grep -E "StorageClass|Status|Capacity"

# LocalPath PVC 验证
kubectl describe pvc -n pg-localpath | grep -E "StorageClass|Status|Capacity"

# 检查 PV
kubectl get pv | grep -E "pg-mayastor|pg-localpath"
```

### 7.2 常见问题与解决方案

#### 7.2.1 Pod 一直 Pending

| 原因 | 检查方法 | 解决方案 |
|------|----------|----------|
| StorageClass 不存在 | `kubectl get sc` | 确认 SC 名称拼写正确，参考项目 Mayastor/LocalPath 部署文档 |
| DiskPool 容量不足 | `kubectl get diskpool -n openebs` | 扩容 DiskPool 或减小 PVC size |
| 节点调度问题 | `kubectl describe pod <pod-name> -n <ns>` | 检查节点标签和污点容忍 |
| PVC WaitForFirstConsumer | `kubectl get pvc -n <ns>` | 这是正常行为，Pod 调度后 PVC 会自动绑定 |

#### 7.2.2 镜像拉取失败

| 原因 | 检查方法 | 解决方案 |
|------|----------|----------|
| 私有仓库不可达 | `curl http://172.25.128.67:9003/v2/_catalog` | 检查网络连接和仓库服务状态 |
| 镜像未推送 | `skopeo inspect --tls-verify=false docker://172.25.128.67:9003/bitnami/postgresql:latest` | 按照第六章导入镜像 |
| containerd 配置错误 | 检查 `/etc/containerd/certs.d/docker.io/hosts.toml` | 确认配置指向 `172.25.128.67:9003` |
| 镜像 tag 不匹配 | `kubectl describe pod <pod-name> -n <ns> \| grep -A5 Events` | 确认推送的镜像 tag 与 values 中一致 |

#### 7.2.3 pgbench 连接失败

| 原因 | 检查方法 | 解决方案 |
|------|----------|----------|
| 密码错误 | 检查 values 中 `auth.postgresPassword` | 确保密码为 `benchmark123` |
| Service 未就绪 | `kubectl get svc -n <ns>` | 等待 Pod 完全就绪后再执行测试 |
| 数据库不存在 | `kubectl exec -n <ns> <pod> -- psql -U postgres -l` | 确认 `benchmark` 数据库已创建 |
| 网络策略限制 | `kubectl get networkpolicy -A` | 检查是否有 NetworkPolicy 限制跨 namespace 通信 |

#### 7.2.4 性能异常低

| 原因 | 检查方法 | 解决方案 |
|------|----------|----------|
| hugepages 未配置 | `kubectl get nodes -o jsonpath='{.items[*].status.allocatable.hugepages\.2Mi}'` | 配置 hugepages（参见 1.3.1） |
| 磁盘 IO 瓶颈 | `kubectl exec <pod> -- iostat -x 1 5` | 检查磁盘 I/O 等待时间 |
| 资源限制过小 | `kubectl describe pod <pod> -n <ns> \| grep -A10 Resources` | 调整 values 中 resources 配置 |
| PG 参数不合理 | 检查 values 中 `configuration` | 确保 shared_buffers、work_mem 等参数合理 |
| Mayastor 副本同步延迟 | `kubectl get msv -n openebs` | 检查 Mayastor Volume 状态和副本健康 |

#### 7.2.5 Helm 部署失败

```bash
# 查看 Helm release 状态
helm status pg-mayastor -n pg-mayastor

# 查看 Helm 事件
kubectl get events -n pg-mayastor --sort-by='.lastTimestamp'

# 回滚到上一个版本
helm rollback pg-mayastor 0 -n pg-mayastor

# 完全卸载后重新部署
helm uninstall pg-mayastor -n pg-mayastor
kubectl delete namespace pg-mayastor --ignore-not-found
helm install pg-mayastor ./charts/postgresql-18.7.5.tgz \
  -f values-mayastor.yaml -n pg-mayastor --create-namespace
```

---

## 附录：文件清单

### 项目目录结构

```
postgres-benchmark/
├── charts/
│   ├── postgresql/                    # 解包后的 chart（18.7.5，用于查看源码）
│   │   ├── charts/common/             # 子依赖
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── README.md
│   ├── postgresql-18.7.5.tgz         # 当前使用的 chart 包（PG 18.4.0）
│   └── postgresql-15.5.38.tgz        # 旧版 chart 包（PG 15.x，备用）
├── images/
│   ├── postgresql-latest/             # 预拉取的镜像（skopeo dir 格式）
│   │   ├── manifest.json
│   │   ├── version
│   │   └── <sha256-digest>            # 镜像层文件
│   └── images-list.txt                # 镜像清单（由 prepare.sh 生成）
├── values-mayastor.yaml
├── values-localpath.yaml
├── values.zip                         # values 文件打包备份
├── pgbench-job.yaml
├── prepare.sh
├── run-benchmark.sh
├── cleanup.sh
├── REPORT-template.md
└── README.md
```

### 文件说明

| 文件 | 说明 |
|------|------|
| [README.md](file:///e:/Code/002-k8s部署/postgres-benchmark/README.md) | 本文档（主文档） |
| [values-mayastor.yaml](file:///e:/Code/002-k8s部署/postgres-benchmark/values-mayastor.yaml) | Mayastor 版 PG Helm values |
| [values-localpath.yaml](file:///e:/Code/002-k8s部署/postgres-benchmark/values-localpath.yaml) | LocalPath 版 PG Helm values |
| [pgbench-job.yaml](file:///e:/Code/002-k8s部署/postgres-benchmark/pgbench-job.yaml) | pgbench 基准测试 Job |
| [prepare.sh](file:///e:/Code/002-k8s部署/postgres-benchmark/prepare.sh) | 气隙环境准备脚本 |
| [run-benchmark.sh](file:///e:/Code/002-k8s部署/postgres-benchmark/run-benchmark.sh) | 一键执行基准测试脚本 |
| [cleanup.sh](file:///e:/Code/002-k8s部署/postgres-benchmark/cleanup.sh) | 清理资源脚本 |
| [images/images-list.txt](file:///e:/Code/002-k8s部署/postgres-benchmark/images/images-list.txt) | 镜像清单（由 prepare.sh 生成） |
| [images/postgresql-latest/](file:///e:/Code/002-k8s部署/postgres-benchmark/images/postgresql-latest) | 预拉取的 PostgreSQL 镜像（skopeo dir 格式） |
| [charts/postgresql-18.7.5.tgz](file:///e:/Code/002-k8s部署/postgres-benchmark/charts/postgresql-18.7.5.tgz) | 当前使用的 Helm chart 包（PG 18.4.0） |
| [charts/postgresql-15.5.38.tgz](file:///e:/Code/002-k8s部署/postgres-benchmark/charts/postgresql-15.5.38.tgz) | 旧版 chart 包（PG 15.x，备用） |
| [charts/postgresql/](file:///e:/Code/002-k8s部署/postgres-benchmark/charts/postgresql) | 解包后的 chart 源码（用于查看模板和参数） |
| [REPORT-template.md](file:///e:/Code/002-k8s部署/postgres-benchmark/REPORT-template.md) | 测试报告模板 |

### 快速开始

```bash
# 1. 有网环境：准备 chart 和镜像（首次执行）
bash prepare.sh
# 或使用 --pull 同时拉取镜像到本地目录
bash prepare.sh --pull

# 2. 内网环境：导入镜像（参考第六章）
#    方式一：从 Docker Hub 直接中转
skopeo copy --dest-tls-verify=false \
  docker://bitnami/postgresql:latest \
  docker://172.25.128.67:9003/bitnami/postgresql:latest
#    方式二：从项目预拉取目录推送（images/postgresql-latest/ 已就绪）
skopeo copy --dest-tls-verify=false \
  dir:./images/postgresql-latest \
  docker://172.25.128.67:9003/bitnami/postgresql:latest

# 3. 内网环境：执行部署和测试
bash run-benchmark.sh

# 4. 查看结果
cat results/benchmark_*.log

# 5. 清理资源
bash cleanup.sh
```
