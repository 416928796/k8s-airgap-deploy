#!/bin/bash
# PostgreSQL 存储性能对比基准测试 — 一键执行脚本
# 用法：
#   bash run-benchmark.sh              # 完整流程：部署→初始化→测试→采集结果
#   bash run-benchmark.sh --skip-deploy # 跳过部署，直接测试（假设 PG 实例已存在）
#
# 功能：
#   1. 检查前置条件（chart 包、镜像可用性）
#   2. 部署两个 PG 实例（Mayastor / LocalPath）
#   3. 等待 Pod 就绪
#   4. 执行 pgbench 数据初始化并记录耗时
#   5. 执行 8 场景基准测试（每实例）
#   6. 采集结果到 results/ 目录
#
# 前置条件：
#   - charts/postgresql-*.tgz 已下载（由 prepare.sh 生成）
#   - 镜像 172.25.128.67:9003/bitnami/postgresql 已推送
#   - StorageClass mayastor-double-replica 和 openebs-hostpath 已部署
#   - kubectl 和 helm 可访问集群

set -e

# ===== 配置区 =====
# 内网镜像仓库
PRIVATE_REGISTRY="${PRIVATE_REGISTRY:-172.25.128.67:9003}"

# 命名空间
MAYASTOR_NS="${MAYASTOR_NS:-pg-mayastor}"
LOCALPATH_NS="${LOCALPATH_NS:-pg-localpath}"

# Helm release 名称
MAYASTOR_RELEASE="${MAYASTOR_RELEASE:-pg-mayastor}"
LOCALPATH_RELEASE="${LOCALPATH_RELEASE:-pg-localpath}"

# Chart 包路径
CHARTS_DIR="${CHARTS_DIR:-./charts}"
CHART_VERSION="${CHART_VERSION:-18.7.5}"
CHART_FILE="${CHARTS_DIR}/postgresql-${CHART_VERSION}.tgz"

# Values 文件
VALUES_MAYASTOR="${VALUES_MAYASTOR:-./values-mayastor.yaml}"
VALUES_LOCALPATH="${VALUES_LOCALPATH:-./values-localpath.yaml}"

# 结果输出目录
RESULTS_DIR="${RESULTS_DIR:-./results}"

# pgbench 参数
PG_PASSWORD="${PG_PASSWORD:-benchmark123}"
PG_DATABASE="${PG_DATABASE:-benchmark}"
SCALE_FACTOR="${SCALE_FACTOR:-100}"
WARMUP_DURATION="${WARMUP_DURATION:-10}"

# Pod 等待超时（秒）
POD_TIMEOUT="${POD_TIMEOUT:-300}"

# ===== 工具函数 =====
log() {
  echo ""
  echo "=============================================="
  echo "  $1"
  echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=============================================="
}

check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "错误：未找到 $1 命令"
    exit 1
  fi
}

# ===== 0. 检查前置条件 =====
log "步骤 0: 检查前置条件"

check_cmd kubectl
check_cmd helm
echo "  [✓] kubectl 和 helm 可用"

if [ ! -f "${CHART_FILE}" ]; then
  echo "错误：未找到 chart 包 ${CHART_FILE}，请先执行 bash prepare.sh 下载 chart"
  exit 1
fi
echo "  [✓] chart 包: ${CHART_FILE}"

if [ ! -f "${VALUES_MAYASTOR}" ]; then
  echo "错误：未找到 ${VALUES_MAYASTOR}"
  exit 1
fi
echo "  [✓] values 文件: ${VALUES_MAYASTOR}, ${VALUES_LOCALPATH}"

# 检查 StorageClass
SC_MAYASTOR=$(kubectl get sc mayastor-double-replica -o name 2>/dev/null || true)
SC_LOCALPATH=$(kubectl get sc openebs-hostpath -o name 2>/dev/null || true)

if [ -z "${SC_MAYASTOR}" ]; then
  echo "  [✗] StorageClass mayastor-double-replica 不存在"
  exit 1
fi
echo "  [✓] StorageClass mayastor-double-replica 已就绪"

if [ -z "${SC_LOCALPATH}" ]; then
  echo "  [✗] StorageClass openebs-hostpath 不存在"
  exit 1
fi
echo "  [✓] StorageClass openebs-hostpath 已就绪"

# ===== 1. 部署 PG 实例 =====
if [[ "$1" != "--skip-deploy" ]]; then
  log "步骤 1: 部署 PostgreSQL 实例"

  echo ">>> 部署 Mayastor 版 PG..."
  helm upgrade --install "${MAYASTOR_RELEASE}" "${CHART_FILE}" \
    -f "${VALUES_MAYASTOR}" \
    -n "${MAYASTOR_NS}" --create-namespace
  echo "  [✓] ${MAYASTOR_RELEASE} 已部署"

  echo ""
  echo ">>> 部署 LocalPath 版 PG..."
  helm upgrade --install "${LOCALPATH_RELEASE}" "${CHART_FILE}" \
    -f "${VALUES_LOCALPATH}" \
    -n "${LOCALPATH_NS}" --create-namespace
  echo "  [✓] ${LOCALPATH_RELEASE} 已部署"

  # ===== 2. 等待 Pod 就绪 =====
  log "步骤 2: 等待 PG Pod 就绪"

  echo ">>> 等待 Mayastor PG Pod 就绪（超时 ${POD_TIMEOUT}s）..."
  kubectl wait --for=condition=Ready pod \
    -l app.kubernetes.io/instance="${MAYASTOR_RELEASE}" \
    -n "${MAYASTOR_NS}" --timeout="${POD_TIMEOUT}s"
  echo "  [✓] Mayastor PG Pod 已就绪"

  echo ""
  echo ">>> 等待 LocalPath PG Pod 就绪（超时 ${POD_TIMEOUT}s）..."
  kubectl wait --for=condition=Ready pod \
    -l app.kubernetes.io/instance="${LOCALPATH_RELEASE}" \
    -n "${LOCALPATH_NS}" --timeout="${POD_TIMEOUT}s"
  echo "  [✓] LocalPath PG Pod 已就绪"
else
  echo "  [!] 跳过部署步骤（--skip-deploy）"
fi

# ===== 3. 准备结果目录 =====
mkdir -p "${RESULTS_DIR}"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
RESULT_FILE="${RESULTS_DIR}/benchmark_${TIMESTAMP}.log"
echo ">>> 结果将保存到: ${RESULT_FILE}"

# ===== 4. 验证 PG 连通性 =====
log "步骤 3: 验证 PG 连通性"

MAYASTOR_POD=$(kubectl get pod -l app.kubernetes.io/instance="${MAYASTOR_RELEASE}" \
  -n "${MAYASTOR_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
LOCALPATH_POD=$(kubectl get pod -l app.kubernetes.io/instance="${LOCALPATH_RELEASE}" \
  -n "${LOCALPATH_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

echo "  Mayastor Pod: ${MAYASTOR_POD}"
echo "  LocalPath Pod: ${LOCALPATH_POD}"

echo ""
echo ">>> 验证 Mayastor PG 连通性..."
kubectl exec -n "${MAYASTOR_NS}" "${MAYASTOR_POD}" -- \
  pg_isready -U postgres -d "${PG_DATABASE}"
echo "  [✓] Mayastor PG 连通正常"

echo ""
echo ">>> 验证 LocalPath PG 连通性..."
kubectl exec -n "${LOCALPATH_NS}" "${LOCALPATH_POD}" -- \
  pg_isready -U postgres -d "${PG_DATABASE}"
echo "  [✓] LocalPath PG 连通正常"

# ===== 5. 执行基准测试 =====
log "步骤 4: 执行 pgbench 基准测试"

# 将所有输出同时写入文件和终端
exec > >(tee -a "${RESULT_FILE}") 2>&1

echo "测试时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Mayastor Pod: ${MAYASTOR_POD} (${MAYASTOR_NS})"
echo "LocalPath Pod: ${LOCALPATH_POD} (${LOCALPATH_NS})"
echo "Scale Factor: ${SCALE_FACTOR}"
echo ""

# 执行单个实例的完整测试流程
# 参数: $1=namespace $2=pod名称 $3=实例标签
run_benchmark_for_instance() {
  local ns="$1"
  local pod="$2"
  local label="$3"

  log "${label} - 数据初始化 (pgbench -i -s ${SCALE_FACTOR})"
  local start_time=$(date +%s)

  kubectl exec -n "${ns}" "${pod}" -- \
    pgbench -i -s "${SCALE_FACTOR}" -U postgres -d "${PG_DATABASE}" 2>&1

  local init_time=$(($(date +%s) - start_time))
  echo ""
  echo "${label} 初始化耗时: ${init_time}s"

  # 测试场景定义
  local scenarios=(
    "A_只读吞吐量:-S -c 10 -j 2 -T 60"
    "B_读写混合吞吐量:-c 10 -j 2 -T 60"
    "C_写入压力:-N -c 10 -j 2 -T 60"
    "D_单客户端延迟:-c 1 -j 1 -T 60 -l"
    "E_并发10:-c 10 -j 2 -T 60"
    "F_并发50:-c 50 -j 4 -T 60"
    "G_并发100:-c 100 -j 4 -T 60"
    "H_持续稳定性:-c 50 -j 4 -T 300"
  )

  for scenario_def in "${scenarios[@]}"; do
    local scenario_name="${scenario_def%%:*}"
    local scenario_args="${scenario_def#*:}"

    echo ""
    echo "----------------------------------------------"
    echo "[${label}] 场景 ${scenario_name}"
    echo "参数: pgbench ${scenario_args}"
    echo "----------------------------------------------"

    # 预热
    echo "  预热中 (${WARMUP_DURATION}s)..."
    kubectl exec -n "${ns}" "${pod}" -- \
      pgbench -U postgres -d "${PG_DATABASE}" \
      -c 10 -j 2 -T "${WARMUP_DURATION}" >/dev/null 2>&1 || true

    # 正式测试
    echo "  正式测试..."
    kubectl exec -n "${ns}" "${pod}" -- \
      pgbench -U postgres -d "${PG_DATABASE}" \
      --aggregate-interval=1 ${scenario_args} 2>&1

    echo ""
  done

  echo ""
  echo "${label} 测试完成。"
  echo ""
}

# 先测 Mayastor，再测 LocalPath（避免资源争抢）
run_benchmark_for_instance "${MAYASTOR_NS}" "${MAYASTOR_POD}" "Mayastor"
run_benchmark_for_instance "${LOCALPATH_NS}" "${LOCALPATH_POD}" "LocalPath"

# ===== 6. 汇总 =====
log "基准测试完成"

echo "结果文件: ${RESULT_FILE}"
echo ""
echo "后续步骤:"
echo "  1. 查看完整结果: cat ${RESULT_FILE}"
echo "  2. 将数据填入 REPORT-template.md 进行分析"
echo "  3. 清理资源: bash cleanup.sh"
