#!/bin/bash
# Mayastor Helm 渲染脚本
# 在能访问互联网、已安装 Helm 的机器上执行

set -e

# ------------------------------------------------------------------------------
# 配置区
# ------------------------------------------------------------------------------
export REGISTRY="${REGISTRY:-172.25.128.67:9003}"
export MAYASTOR_VERSION="${MAYASTOR_VERSION:-2.10.0}"  # Helm chart 版本，对应 Mayastor 2.10.0
NAMESPACE="openebs"
VALUES_FILE="${VALUES_FILE:-values.yaml}"
OUTPUT_FILE="mayastor-airgap.yaml"

# ------------------------------------------------------------------------------
# 检查依赖
# ------------------------------------------------------------------------------
if ! command -v helm &> /dev/null; then
  echo "错误：未找到 helm 命令"
  exit 1
fi

# ------------------------------------------------------------------------------
# 添加/更新仓库
# ------------------------------------------------------------------------------
echo "===== 添加 OpenEBS Helm 仓库 ====="
helm repo add openebs https://openebs.github.io/mayastor-extensions || true
helm repo update

# ------------------------------------------------------------------------------
# 渲染 YAML
# ------------------------------------------------------------------------------
echo ""
echo "===== 渲染 Mayastor ${MAYASTOR_VERSION} ====="
helm template mayastor openebs/mayastor \
  --namespace "${NAMESPACE}" \
  --version "${MAYASTOR_VERSION}" \
  -f "${VALUES_FILE}" \
  > "${OUTPUT_FILE}"

echo ""
echo "===== 渲染完成：${OUTPUT_FILE} ====="
echo ""
echo "镜像清单："
grep -E 'image:' "${OUTPUT_FILE}" | sort | uniq

echo ""
echo "请将 ${OUTPUT_FILE} 复制到目标集群，执行："
echo "  kubectl apply -f ${OUTPUT_FILE}"
