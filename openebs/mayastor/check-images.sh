#!/bin/bash
# 检查 Mayastor 部署所需镜像是否齐全
# 用法：
#   1. 修改下方 REGISTRY 为你的内网仓库地址
#   2. 确保 values.yaml 已配置好你的内网仓库和版本
#   3. bash check-images.sh

set -e

# ===== 配置区 =====
# 内网镜像仓库地址，例如：172.25.128.67:9003
REGISTRY="${REGISTRY:-172.25.128.67:9003}"

# Helm chart 版本，例如：2.8.0 / 2.10.0
CHART_VERSION="${CHART_VERSION:-2.10.0}"

# 命名空间
NAMESPACE="${NAMESPACE:-openebs}"

# values.yaml 路径
VALUES_FILE="${VALUES_FILE:-./values.yaml}"

# 本地镜像缓存目录（可选）
LOCAL_DIR="${LOCAL_DIR:-./mayastor-images}"

# 输出文件
REQUIRED_LIST="./required-images.txt"
MISSING_LIST="./missing-images.txt"

# ===== 获取所需镜像列表 =====
echo ">>> 正在从 Helm chart 提取所需镜像列表..."

if command -v helm >/dev/null 2>&1; then
  helm repo add mayastor https://openebs.github.io/mayastor-extensions >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true

  helm template mayastor mayastor/mayastor \
    --namespace "${NAMESPACE}" \
    --version "${CHART_VERSION}" \
    -f "${VALUES_FILE}" 2>/dev/null | \
    grep -E "^\s*image:\s*" | \
    sed 's/^\s*image:\s*//; s/^"//; s/"$//' | \
    sort -u > "${REQUIRED_LIST}"
elif [ -f "${REQUIRED_LIST}" ]; then
  echo "未找到 helm 命令，使用现有的 ${REQUIRED_LIST} 进行检查。"
else
  echo "错误：未找到 helm 命令，且 ${REQUIRED_LIST} 不存在。"
  echo "请执行以下操作之一："
  echo "  1. 在能联网的机器上安装 helm 并运行本脚本，生成 ${REQUIRED_LIST} 后复制到本机"
  echo "  2. 手动创建 ${REQUIRED_LIST}，每行一个镜像地址"
  exit 1
fi

TOTAL=$(wc -l < "${REQUIRED_LIST}" | tr -d ' ')
echo "共需 ${TOTAL} 个镜像，列表已保存到 ${REQUIRED_LIST}"

# ===== 检查镜像是否存在 =====
echo ""
echo ">>> 正在检查镜像是否已推送到内网仓库 ${REGISTRY} ..."

> "${MISSING_LIST}"
FOUND=0
MISSING=0

while IFS= read -r img; do
  # 去掉原 registry 前缀，只保留 namespace/image:tag
  img_no_registry=$(echo "${img}" | sed 's|^[^/]*/||')
  full_img="${REGISTRY}/${img_no_registry}"

  if skopeo inspect --raw "docker://${full_img}" >/dev/null 2>&1; then
    echo "  [✓] ${full_img}"
    FOUND=$((FOUND + 1))
  else
    echo "  [✗] ${full_img} 缺失"
    echo "${full_img}" >> "${MISSING_LIST}"
    MISSING=$((MISSING + 1))
  fi
done < "${REQUIRED_LIST}"

# ===== 也可以检查本地目录（可选） =====
if [ -d "${LOCAL_DIR}" ]; then
  echo ""
  echo ">>> 本地缓存目录 ${LOCAL_DIR} 内容："
  ls -1 "${LOCAL_DIR}"
fi

# ===== 汇总 =====
echo ""
echo "========== 检查结果 =========="
echo "总数:   ${TOTAL}"
echo "已有:   ${FOUND}"
echo "缺失:   ${MISSING}"

if [ ${MISSING} -gt 0 ]; then
  echo ""
  echo "缺失镜像列表已保存到: ${MISSING_LIST}"
  cat "${MISSING_LIST}"
  echo ""
  echo "请把这些镜像补充推送到内网仓库后再部署。"
  exit 1
else
  echo ""
  echo "所有镜像已就绪，可以开始部署。"
fi
