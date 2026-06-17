#!/bin/bash
# Mayastor 离线镜像拉取/推送脚本
# 在能访问互联网的机器上执行

set -e

# ------------------------------------------------------------------------------
# 配置区（请根据实际情况修改）
# ------------------------------------------------------------------------------
REGISTRY="${REGISTRY:-172.25.128.67:9003}"
# Mayastor 镜像 tag：v2.8.0 / v2.9.0 / v2.10.0 等
MAYASTOR_VERSION="${MAYASTOR_VERSION:-v2.10.0}"

# 是否仅导出 tar 包，不推送到仓库
EXPORT_ONLY="${EXPORT_ONLY:-false}"
TAR_FILE="${TAR_FILE:-mayastor-images.tar}"

# ------------------------------------------------------------------------------
# Mayastor 镜像清单
# 以下清单来自 mayastor-extensions 2.10.0 chart 的 helm.sh/images 注解。
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 拉取镜像
# ------------------------------------------------------------------------------
echo "===== 开始拉取 Mayastor 镜像（版本：${MAYASTOR_VERSION}） ====="
for img in "${IMAGES[@]}"; do
  echo "拉取: ${img}"
  docker pull "${img}"
done

# ------------------------------------------------------------------------------
# 推送镜像到私有仓库
# ------------------------------------------------------------------------------
if [ "$EXPORT_ONLY" = "false" ]; then
  echo ""
  echo "===== 开始推送到私有仓库：${REGISTRY} ====="
  for img in "${IMAGES[@]}"; do
    # 构造目标镜像地址
    # 对于有 registry 前缀的（如 registry.k8s.io/...），去掉前缀再拼接目标 registry
    if echo "${img}" | grep -q '/'; then
      first_part=$(echo "${img}" | cut -d'/' -f1)
      if echo "${first_part}" | grep -q '\.'; then
        target_img="${REGISTRY}/$(echo "${img}" | cut -d'/' -f2-)"
      else
        target_img="${REGISTRY}/${img}"
      fi
    else
      target_img="${REGISTRY}/${img}"
    fi

    echo "标记并推送: ${target_img}"
    docker tag "${img}" "${target_img}"
    docker push "${target_img}"
  done
  echo "===== 推送完成 ====="
else
  # ------------------------------------------------------------------------------
  # 导出为 tar 包
  # ------------------------------------------------------------------------------
  echo ""
  echo "===== 导出镜像到 ${TAR_FILE} ====="
  docker save "${IMAGES[@]}" -o "${TAR_FILE}"
  echo "===== 导出完成：${TAR_FILE} ====="
  echo ""
  echo "请将该 tar 包复制到目标节点，然后执行："
  echo "  ctr -n k8s.io images import ${TAR_FILE}"
fi
