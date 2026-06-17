# 1. 设置 Mayastor 版本（按需修改）
#    注意：这里填的是镜像 tag，不是 Helm chart 版本。
#    Mayastor 2.10.0 官方镜像 tag 为 v2.10.0
MAYASTOR_VERSION="v2.10.0"

# 2. 创建本地存储目录
mkdir -p ./mayastor-images

# 3. 定义镜像列表
#    以下清单来自 mayastor-extensions 2.10.0 chart 的 helm.sh/images 注解。
#    CSI sidecar 官方仓库在 registry.k8s.io。
IMAGES=(
  # === Mayastor 控制平面 & 数据平面 ===
  "openebs/mayastor-io-engine:${MAYASTOR_VERSION}"
  "openebs/mayastor-agent-core:${MAYASTOR_VERSION}"
  "openebs/mayastor-agent-ha-node:${MAYASTOR_VERSION}"
  "openebs/mayastor-agent-ha-cluster:${MAYASTOR_VERSION}"
  "openebs/mayastor-api-rest:${MAYASTOR_VERSION}"
  "openebs/mayastor-csi-controller:${MAYASTOR_VERSION}"
  "openebs/mayastor-csi-node:${MAYASTOR_VERSION}"
  "openebs/mayastor-operator-diskpool:${MAYASTOR_VERSION}"

  # === Mayastor 扩展组件 ===
  "openebs/mayastor-metrics-exporter-io-engine:${MAYASTOR_VERSION}"
  "openebs/mayastor-obs-callhome:${MAYASTOR_VERSION}"
  "openebs/mayastor-obs-callhome-stats:${MAYASTOR_VERSION}"

  # === OpenEBS 基础工具镜像 ===
  "openebs/alpine-sh:4.3.0"
  "openebs/alpine-bash:4.3.0"
  "openebs/linux-utils:4.3.0"
  "openebs/kubectl:1.25.15"
  "openebs/etcd:3.6.4-debian-12-r0"
  "openebs/provisioner-localpv:4.4.0"

  # === CSI Sidecar（官方仓库在 registry.k8s.io）===
  "registry.k8s.io/sig-storage/csi-provisioner:v5.2.0"
  "registry.k8s.io/sig-storage/csi-attacher:v4.8.1"
  "registry.k8s.io/sig-storage/csi-resizer:v1.13.2"
  "registry.k8s.io/sig-storage/csi-snapshotter:v8.2.0"
  "registry.k8s.io/sig-storage/snapshot-controller:v8.2.0"
  "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.13.0"

  # === 可选依赖（启用对应功能时才需要）===
  # "docker.io/grafana/alloy:v1.8.1"
  # "docker.io/grafana/loki:3.4.2"
  # "docker.io/kiwigrid/k8s-sidecar:1.30.2"
  # "docker.io/nats:2.9.17-alpine"
  # "docker.io/natsio/nats-box:0.13.8"
  # "docker.io/natsio/nats-server-config-reloader:0.10.1"
  # "docker.io/natsio/prometheus-nats-exporter:0.11.0"
  # "quay.io/minio/mc:RELEASE.2024-11-21T17-21-54Z"
  # "quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z"
  # "quay.io/prometheus-operator/prometheus-config-reloader:v0.81.0"
)

# 4. 批量拉取到本地目录（如需代理，加 --src-creds 或 http_proxy）
for img in "${IMAGES[@]}"; do
  dir_name=$(echo "${img}" | tr '/:' '_')
  echo ">>> 拉取: ${img}"
  skopeo copy --override-os linux --override-arch amd64 "docker://${img}" "dir:./mayastor-images/${dir_name}"
done
