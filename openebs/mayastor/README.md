# OpenEBS Mayastor 离线安装文档（方案 B：单独 chart）

> **适用场景**：集群中已安装 OpenEBS LocalPath，现在单独新增 Mayastor 引擎，两者通过不同 StorageClass 共存。
>
> **版本说明**：当前文档以 **Mayastor 2.10.0** 为例。内网仓库中已有 `openebs/mayastor-api-rest:v2.10.0`，说明目标版本为 2.10.0。如需使用其他版本，请全局替换 `v2.10.0` / `2.10.0`。

---

## 一、前置要求

### 1.1 已具备的条件

- Kubernetes 集群可访问
- 已安装 OpenEBS LocalPath 且运行正常（StorageClass 如 `openebs-hostpath`）
- 有私有镜像仓库（示例：`172.25.128.67:9003`）或已掌握 `docker save/load`、`ctr import` 等离线镜像导入方式
- Helm 3 已安装

### 1.2 Mayastor 对节点的硬性要求

| 项目 | 要求 | 检查命令 |
|------|------|----------|
| 大页内存 | 每个运行 io-engine 的节点至少 **2GB hugepages**（1024 × 2MB） | `grep HugePages_ /proc/meminfo` |
| 裸盘 | 用于 DiskPool 的磁盘必须**未分区、未挂载、未加入 LVM/RAID** | `lsblk` |
| 内核 | 建议 **5.15+** | `uname -r` |
| 依赖 | 建议安装 `nvme-cli`、`linux-modules-extra` | `which nvme` |
| 架构 | x86_64（amd64） | `uname -m` |

> ⚠️ **注意**：Mayastor 不支持在虚拟机的普通虚拟磁盘上获得高性能，生产环境建议使用 NVMe SSD 裸盘。

---

## 二、确定版本号

先确认你当前 OpenEBS LocalPath 的版本，确保 Mayastor 版本匹配：

```bash
kubectl get pods -n openebs -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort | uniq
```

你的 LocalPath provisioner 版本与 Mayastor 版本无严格绑定关系。本文后续命令和 YAML 已按 **Mayastor 2.10.0** 配置，如需使用其他版本请全局替换。

---

## 三、准备离线镜像

### 3.1 设置环境变量

在**能访问互联网的机器**上执行：

```bash
export REGISTRY="172.25.128.67:9003"   # 你的私有镜像仓库
export MAYASTOR_VERSION="v2.10.0"      # Mayastor 镜像 tag
```

### 3.2 拉取并推送镜像

运行本目录下的脚本：

```bash
bash image-pull-push.sh
```

脚本会自动拉取 Mayastor 所需镜像，并推送到你的私有仓库。如果你无法直接推送，脚本也支持导出为 `mayastor-images.tar`。

脚本核心镜像清单如下（以 2.10.0 为例）：

```text
openebs/mayastor-io-engine:v2.10.0
openebs/mayastor-agent-core:v2.10.0
openebs/mayastor-agent-ha-node:v2.10.0
openebs/mayastor-agent-ha-cluster:v2.10.0
openebs/mayastor-api-rest:v2.10.0
openebs/mayastor-csi-controller:v2.10.0
openebs/mayastor-csi-node:v2.10.0
openebs/mayastor-operator-diskpool:v2.10.0
openebs/mayastor-metrics-exporter-io-engine:v2.10.0
openebs/mayastor-obs-callhome:v2.10.0
openebs/mayastor-obs-callhome-stats:v2.10.0
openebs/alpine-sh:4.3.0               # init container
openebs/alpine-bash:4.3.0             # etcd init
openebs/linux-utils:4.3.0             # 工具镜像
openebs/etcd:3.6.4-debian-12-r0       # Mayastor 内置 etcd
openebs/provisioner-localpv:4.4.0     # localpv provisioner
registry.k8s.io/sig-storage/csi-provisioner:v5.2.0
registry.k8s.io/sig-storage/csi-attacher:v4.8.1
registry.k8s.io/sig-storage/csi-resizer:v1.13.2
registry.k8s.io/sig-storage/csi-snapshotter:v8.2.0
registry.k8s.io/sig-storage/snapshot-controller:v8.2.0
registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.13.0
```

### 3.3 离线导入镜像（无私有仓库时）

如果目标节点不能访问私有仓库，可使用 `ctr` 导入 tar 包：

```bash
# 在目标节点执行
ctr -n k8s.io images import mayastor-images.tar
```

---

## 四、节点配置 hugepages

### 4.1 每个 Mayastor 节点配置大页内存

在**所有要运行 Mayastor io-engine 的节点**上执行：

```bash
# 临时生效
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# 永久生效
cat <<EOF > /etc/sysctl.d/99-mayastor-hugepages.conf
vm.nr_hugepages = 1024
EOF
sysctl --system
```

> 也可以直接将本目录下的 `99-mayastor-hugepages.conf` 复制到 `/etc/sysctl.d/`。

### 4.2 验证 hugepages

```bash
grep HugePages_ /proc/meminfo
```

预期输出：

```text
HugePages_Total:    1024
HugePages_Free:     1024
HugePages_Rsvd:        0
HugePages_Surp:        0
```

### 4.3 安装 nvme-cli（建议）

```bash
# Ubuntu/Debian
apt-get update && apt-get install -y nvme-cli

# RHEL/CentOS/Rocky
yum install -y nvme-cli
```

---

## 五、渲染 Mayastor 离线安装包

### 5.1 添加 Helm 仓库

在能访问互联网的机器上：

```bash
helm repo add mayastor https://openebs.github.io/mayastor-extensions
helm repo update
```

### 5.2 下载 chart（可选）

```bash
# 注意：这里 --version 是 chart 版本，不是镜像 tag
export MAYASTOR_CHART_VERSION="2.10.0"
helm pull mayastor/mayastor --version ${MAYASTOR_CHART_VERSION} --untar
```

### 5.3 编辑 values.yaml

本目录下已提供 `values.yaml` 模板（来自 mayastor-extensions 2.10.0 chart），请根据你的环境修改：

- `image.registry`: 你的私有镜像仓库地址
- `image.tag`: Mayastor 镜像 tag，例如 `v2.10.0`
- `base.initContainers.image.registry`: init container 仓库
- `etcd.image.registry`: etcd 镜像仓库
- `csi.image.registry`: CSI sidecar 仓库

```bash
vim values.yaml
```

### 5.4 渲染为离线 YAML

```bash
export REGISTRY="172.25.128.67:9003"
export MAYASTOR_CHART_VERSION="2.10.0"

helm template mayastor mayastor/mayastor \
  --namespace openebs \
  --version ${MAYASTOR_CHART_VERSION} \
  -f values.yaml \
  > mayastor-airgap.yaml
```

> 如果无法联网，使用步骤 5.2 下载的本地 chart 目录：
> `helm template mayastor ./mayastor -n openebs -f values.yaml > mayastor-airgap.yaml`

### 5.5 检查渲染结果

```bash
grep -E 'image:' mayastor-airgap.yaml | sort | uniq
```

确认所有镜像都指向你的私有仓库。

### 5.6 检查镜像是否齐全

在能访问内网仓库的机器上运行：

```bash
export REGISTRY="172.25.128.67:9003"
export CHART_VERSION="2.10.0"
bash check-images.sh
```

脚本会根据 `values.yaml` 渲染出所有需要的镜像，并逐个用 `skopeo` 检查是否已存在于内网仓库。最后输出缺失的镜像列表。

---

## 六、部署 Mayastor

### 6.1 应用 manifest

```bash
kubectl apply -f mayastor-airgap.yaml
```

### 6.2 查看 Pod 状态

```bash
kubectl get pods -n openebs -l app.kubernetes.io/part-of=mayastor -w
```

预期会启动以下组件：

- `mayastor-agent-core-*`
- `mayastor-agent-ha-node-*`
- `mayastor-agent-ha-cluster-*`
- `mayastor-api-rest-*`
- `mayastor-csi-controller-*`
- `mayastor-csi-node-*`
- `mayastor-io-engine-*`（DaemonSet，每个 Mayastor 节点一个）
- `mayastor-operator-diskpool-*`
- `mayastor-etcd-*`

---

## 七、创建磁盘池 DiskPool

### 7.1 确认可用裸盘

在每个 Mayastor 节点上：

```bash
lsblk -dpno NAME,SIZE,TYPE,MOUNTPOINT
```

选择**未挂载、未分区**的磁盘，例如 `/dev/nvme0n1`。

### 7.2 编辑 diskpool.yaml

本目录下提供 `diskpool.yaml` 模板。按节点修改：

```yaml
apiVersion: io.openebs.storage/v1beta2
kind: DiskPool
metadata:
  name: pool-node1
  namespace: openebs
spec:
  node: k8s-node1
  disks:
    - /dev/nvme0n1
```

> ⚠️ **警告**：`/dev/nvme0n1` 会被格式化并作为 Mayastor 存储池，数据会丢失！

为每个 Mayastor 节点创建一个 DiskPool：

```bash
vim diskpool.yaml
kubectl apply -f diskpool.yaml
```

### 7.3 验证 DiskPool

```bash
kubectl get diskpool -n openebs
```

预期状态：

```text
NAME        NODE        STATE     POOL_STATUS   CAPACITY   USED   AVAILABLE
pool-node1  k8s-node1   Online    Online        500Gi      0Gi    500Gi
```

---

## 八、创建 StorageClass

### 8.1 单副本 StorageClass

```bash
kubectl apply -f storageclass-single.yaml
```

内容示例：

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: mayastor-single-replica
provisioner: io.openebs.csi-mayastor
parameters:
  protocol: nvmf
  repl: "1"
  pool: "pool-node1"   # 指定使用哪个 DiskPool
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

### 8.2 三副本 StorageClass（生产推荐，需至少 3 个 DiskPool）

```bash
kubectl apply -f storageclass-triple.yaml
```

内容示例：

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: mayastor-triple-replica
provisioner: io.openebs.csi-mayastor
parameters:
  protocol: nvmf
  repl: "3"
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

### 8.3 查看 StorageClass

```bash
kubectl get storageclass
```

你现在应该同时看到：

```text
openebs-hostpath            openebs.io/local           ...
mayastor-single-replica     io.openebs.csi-mayastor    ...
mayastor-triple-replica     io.openebs.csi-mayastor    ...
```

---

## 九、功能测试

### 9.1 创建测试 PVC

```bash
kubectl apply -f test-pvc.yaml
```

### 9.2 创建测试 Pod

```bash
kubectl apply -f test-pod.yaml
```

### 9.3 验证

```bash
# PVC 已绑定
kubectl get pvc mayastor-test-pvc

# Pod 已运行
kubectl get pod mayastor-test-pod

# 进入 Pod 写入测试数据
kubectl exec -it mayastor-test-pod -- /bin/sh -c "echo hello-mayastor > /data/test.txt && cat /data/test.txt"
```

---

## 十、与 LocalPath 共存说明

- 已有 `openebs-hostpath` 的 PVC/PV **不受影响**。
- 新应用需要使用 Mayastor 时，在 PVC 中指定 `storageClassName: mayastor-single-replica`。
- 如需迁移数据，建议使用 `kubectl cp`、应用层同步或备份工具，**不能**直接修改已有 PVC 的 StorageClass。

---

## 十一、卸载 Mayastor（如需要）

> ⚠️ 卸载会删除所有 Mayastor PVC 数据，请提前备份！

```bash
# 1. 删除使用 Mayastor StorageClass 的 PVC 和 PV
kubectl delete pvc --all -n <你的命名空间> --selector <选择器>

# 2. 删除 StorageClass
kubectl delete -f storageclass-single.yaml
kubectl delete -f storageclass-triple.yaml

# 3. 删除 DiskPool
kubectl delete -f diskpool.yaml

# 4. 删除 Mayastor 组件
kubectl delete -f mayastor-airgap.yaml
```

LocalPath 部分**不需要**删除。

---

## 十二、常见问题排查

### 12.1 io-engine Pod 起不来，日志提示 hugepages 不足

```bash
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
```

并写入 `/etc/sysctl.d/99-mayastor-hugepages.conf` 永久生效。

### 12.2 DiskPool 状态为 Error / Degraded

检查：
- 磁盘是否为裸盘
- 磁盘是否已被分区/挂载
- io-engine Pod 是否正常运行
- `kubectl describe diskpool <pool-name> -n openebs`

### 12.3 PVC 一直 Pending

检查：
- `kubectl get sc` 确认 StorageClass 存在
- `kubectl get diskpool -n openebs` 确认 DiskPool Online
- `kubectl describe pvc <pvc-name>` 查看事件
- 确认 Pod 调度到的节点有可用 DiskPool

### 12.4 镜像拉取失败

检查：
- 私有仓库是否可访问
- `imagePullSecrets` 是否配置
- `values.yaml` 中的 registry 是否正确

---

## 十三、附录：文件清单

本目录包含以下文件：

| 文件 | 说明 |
|------|------|
| `README.md` | 本安装文档 |
| `values.yaml` | Helm values 模板 |
| `diskpool.yaml` | DiskPool 示例 |
| `storageclass-single.yaml` | 单副本 StorageClass |
| `storageclass-triple.yaml` | 三副本 StorageClass |
| `test-pvc.yaml` | 测试 PVC |
| `test-pod.yaml` | 测试 Pod |
| `image-pull-push.sh` | 离线镜像拉取/推送脚本 |
| `render.sh` | Helm 渲染脚本 |
| `99-mayastor-hugepages.conf` | hugepages sysctl 配置 |
| `verify.sh` | 部署后验证脚本 |
