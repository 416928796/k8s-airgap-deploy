#!/bin/bash
# 清理 PostgreSQL 基准测试资源
# 用法：bash cleanup.sh
#
# 清理内容：
#   1. 卸载两个 PG Helm release
#   2. 删除 pgbench Job
#   3. 删除命名空间（含 PVC/PV 等资源）

set -e

# ===== 配置区 =====
MAYASTOR_NS="${MAYASTOR_NS:-pg-mayastor}"
LOCALPATH_NS="${LOCALPATH_NS:-pg-localpath}"
MAYASTOR_RELEASE="${MAYASTOR_RELEASE:-pg-mayastor}"
LOCALPATH_RELEASE="${LOCALPATH_RELEASE:-pg-localpath}"
JOB_NAME="${JOB_NAME:-pgbench-benchmark}"

# ===== 卸载 Helm release =====
echo ">>> 卸载 Helm release..."

helm uninstall "${MAYASTOR_RELEASE}" -n "${MAYASTOR_NS}" 2>/dev/null || true
echo "  [✓] ${MAYASTOR_RELEASE} 已卸载（或不存在）"

helm uninstall "${LOCALPATH_RELEASE}" -n "${LOCALPATH_NS}" 2>/dev/null || true
echo "  [✓] ${LOCALPATH_RELEASE} 已卸载（或不存在）"

# ===== 删除 pgbench Job =====
echo ""
echo ">>> 删除 pgbench Job..."

kubectl delete job "${JOB_NAME}" -n "${MAYASTOR_NS}" --ignore-not-found 2>/dev/null || true
echo "  [✓] Job ${JOB_NAME} 已删除（或不存在）"

# ===== 删除命名空间 =====
echo ""
echo ">>> 删除命名空间..."

kubectl delete namespace "${MAYASTOR_NS}" --ignore-not-found 2>/dev/null || true
echo "  [✓] namespace ${MAYASTOR_NS} 已删除（或不存在）"

kubectl delete namespace "${LOCALPATH_NS}" --ignore-not-found 2>/dev/null || true
echo "  [✓] namespace ${LOCALPATH_NS} 已删除（或不存在）"

# ===== 汇总 =====
echo ""
echo "========== 清理完成 =========="
echo "已清理资源："
echo "  - Helm release: ${MAYASTOR_RELEASE}, ${LOCALPATH_RELEASE}"
echo "  - Job: ${JOB_NAME}"
echo "  - Namespace: ${MAYASTOR_NS}, ${LOCALPATH_NS}"
echo ""
echo "注意：DiskPool 和 StorageClass 属于集群级资源，未清理。"
echo "      如需清理存储卷中的残留数据，请手动检查 PV 状态。"
