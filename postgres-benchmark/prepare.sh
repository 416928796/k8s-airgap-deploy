#!/bin/bash
# 气隙环境准备脚本（在有网环境执行）
# 用法：
#   bash prepare.sh              # 下载 chart + 生成镜像清单
#   bash prepare.sh --pull       # 下载 chart + 生成镜像清单 + 拉取镜像到本地目录
#
# 功能：
#   1. 下载 Bitnami PostgreSQL Helm chart 包到 charts/ 目录
#   2. 获取 chart 的 appVersion（即 PG 版本号）
#   3. 生成/更新 images-list.txt 镜像清单
#   4. 输出 skopeo 镜像拉取/推送命令模板（--pull 时自动执行拉取）
#
# 前置条件：
#   - 已安装 helm 3.8.0+
#   - 已安装 skopeo（--pull 模式需要）
#   - 网络可访问 https://charts.bitnami.com/bitnami 和 docker.io

set -e

# ===== 配置区 =====
# Bitnami PostgreSQL chart 版本（对应 PG 18.x）
CHART_VERSION="${CHART_VERSION:-18.7.5}"

# 内网镜像仓库地址
PRIVATE_REGISTRY="${PRIVATE_REGISTRY:-172.25.128.67:9003}"

# 镜像仓库前缀（docker.io 上的 Bitnami 镜像）
IMAGE_REGISTRY="docker.io"

# 本地镜像缓存目录
LOCAL_DIR="${LOCAL_DIR:-./pg-images}"

# chart 存储目录
CHARTS_DIR="${CHARTS_DIR:-./charts}"

# 镜像清单文件
IMAGES_LIST="${IMAGES_LIST:-./images-list.txt}"

# ===== 检查依赖 =====
echo ">>> 检查依赖..."

if ! command -v helm >/dev/null 2>&1; then
  echo "错误：未找到 helm 命令，请先安装 Helm 3.8.0+"
  exit 1
fi
echo "  [✓] helm $(helm version --short 2>/dev/null || echo '已安装')"

if [[ "$1" == "--pull" ]]; then
  if ! command -v skopeo >/dev/null 2>&1; then
    echo "错误：--pull 模式需要 skopeo 命令，请先安装 skopeo"
    exit 1
  fi
  echo "  [✓] skopeo $(skopeo --version 2>/dev/null || echo '已安装')"
fi

# ===== 1. 下载 Helm Chart =====
echo ""
echo ">>> 下载 Bitnami PostgreSQL chart (v${CHART_VERSION})..."

helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

mkdir -p "${CHARTS_DIR}"

helm pull bitnami/postgresql --version "${CHART_VERSION}" -d "${CHARTS_DIR}"
echo "  [✓] chart 已下载到 ${CHARTS_DIR}/"

# ===== 2. 获取 appVersion =====
echo ""
echo ">>> 获取 chart appVersion..."

APP_VERSION=$(helm show chart bitnami/postgresql --version "${CHART_VERSION}" 2>/dev/null | grep "^appVersion:" | awk '{print $2}')
if [ -z "${APP_VERSION}" ]; then
  echo "警告：无法自动获取 appVersion，使用默认值 18.4.0"
  APP_VERSION="18.4.0"
fi
echo "  [✓] PostgreSQL appVersion: ${APP_VERSION}"

# ===== 3. 生成镜像清单 =====
echo ""
echo ">>> 生成镜像清单..."

# 尝试从 chart 渲染中提取完整镜像列表
CHART_FILE="${CHARTS_DIR}/postgresql-${CHART_VERSION}.tgz"
if [ -n "${CHART_FILE}" ]; then
  TEMP_NS="temp-render"
  helm template pg-test "${CHART_FILE}" \
    --namespace "${TEMP_NS}" \
    --set architecture=standalone \
    --set global.imageRegistry="${IMAGE_REGISTRY}" \
    --set global.security.allowInsecureImages=true 2>/dev/null | \
    grep -E "^\s*image:\s*" | \
    sed 's/^\s*image:\s*//; s/^"//; s/"$//' | \
    sort -u > /tmp/pg-images-rendered.txt

  if [ -s /tmp/pg-images-rendered.txt ]; then
    echo "  [✓] 从 chart 渲染中提取到 $(wc -l < /tmp/pg-images-rendered.txt) 个镜像"
  fi
fi

# 生成镜像清单文件
cat > "${IMAGES_LIST}" << EOF
# PostgreSQL 基准测试所需镜像清单
# 由 prepare.sh 自动生成
# chart 版本: ${CHART_VERSION}
# PostgreSQL appVersion: ${APP_VERSION}
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
#
# 使用方法：参考 README.md 第六章内网资源导入指南

# ===== 必需镜像 =====
EOF

# 添加主镜像
echo "${IMAGE_REGISTRY}/bitnami/postgresql:${APP_VERSION}-debian-12-r0" >> "${IMAGES_LIST}"

# 如果渲染结果中有其他镜像，也添加进去
if [ -f /tmp/pg-images-rendered.txt ]; then
  while IFS= read -r img; do
    # 排除已添加的 postgresql 主镜像
    if [[ "${img}" != *"postgresql"* ]] || [[ "${img}" != *"${APP_VERSION}"* ]]; then
      # 提取镜像名（去掉 registry 前缀）
      img_name=$(echo "${img}" | sed 's|^[^/]*/||')
      # 检查是否已在清单中
      if ! grep -q "${img_name}" "${IMAGES_LIST}"; then
        echo "${img}" >> "${IMAGES_LIST}"
      fi
    fi
  done < /tmp/pg-images-rendered.txt
fi

cat >> "${IMAGES_LIST}" << EOF

# ===== 可选镜像（默认禁用，按需启用） =====
# ${IMAGE_REGISTRY}/bitnami/os-shell:latest              # volumePermissions.enabled=true 时需要
# ${IMAGE_REGISTRY}/bitnami/postgres-exporter:latest     # metrics.enabled=true 时需要
EOF

echo "  [✓] 镜像清单已生成: ${IMAGES_LIST}"
echo ""
echo "---------- 镜像清单内容 ----------"
cat "${IMAGES_LIST}"
echo "----------------------------------"

# ===== 4. 镜像拉取/推送命令模板 =====
echo ""
echo "========== 镜像导入命令模板 =========="
echo ""
echo "以下命令用于将镜像导入内网环境，请根据实际情况选择执行："
echo ""

# 读取镜像清单中的必需镜像
while IFS= read -r line; do
  # 跳过注释和空行
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue

  # 去掉 registry 前缀，获取 namespace/image:tag
  img_no_registry=$(echo "${line}" | sed 's|^[^/]*/||')
  target_img="${PRIVATE_REGISTRY}/${img_no_registry}"

  echo "  # 镜像: ${line}"
  echo "  # 方式1: 直接中转（需同时可访问外网和内网）"
  echo "  skopeo copy --dest-tls-verify=false \\"
  echo "    docker://${line} \\"
  echo "    docker://${target_img}"
  echo ""
  echo "  # 方式2: 先拉取到本地目录，再推送到内网（气隙环境推荐）"
  echo "  skopeo copy docker://${line} dir:${LOCAL_DIR}/${img_no_registry//\//_}"
  echo "  skopeo copy --dest-tls-verify=false dir:${LOCAL_DIR}/${img_no_registry//\//_} docker://${target_img}"
  echo ""
done < "${IMAGES_LIST}"

# ===== 5. --pull 模式：自动拉取镜像到本地目录 =====
if [[ "$1" == "--pull" ]]; then
  echo ""
  echo ">>> 开始拉取镜像到本地目录 ${LOCAL_DIR}/ ..."
  mkdir -p "${LOCAL_DIR}"

  while IFS= read -r line; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    img_no_registry=$(echo "${line}" | sed 's|^[^/]*/||')
    local_path="${LOCAL_DIR}/${img_no_registry//\//_}"

    echo "  拉取: ${line}"
    if skopeo copy "docker://${line}" "dir:${local_path}" 2>/dev/null; then
      echo "    [✓] 成功"
    else
      echo "    [✗] 失败，请手动拉取"
    fi
  done < "${IMAGES_LIST}"

  echo ""
  echo "  镜像已拉取到 ${LOCAL_DIR}/"
  echo "  请将此目录复制到内网环境，然后使用 skopeo push 推送到 ${PRIVATE_REGISTRY}"
fi

# ===== 汇总 =====
echo ""
echo "========== 准备完成 =========="
echo ""
echo "已生成文件："
echo "  - ${CHARTS_DIR}/postgresql-${CHART_VERSION}.tgz  (Helm chart 包)"
echo "  - ${IMAGES_LIST}                                  (镜像清单)"
echo ""
echo "后续步骤："
echo "  1. 将 ${CHARTS_DIR}/ 和 ${IMAGES_LIST} 传到内网环境"
echo "  2. 按照上述 skopeo 命令模板导入镜像到 ${PRIVATE_REGISTRY}"
echo "  3. 在内网环境执行: bash run-benchmark.sh"
