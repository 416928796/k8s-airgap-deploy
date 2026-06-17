#!/bin/bash
# 将 skopeo 拉取到本地目录的镜像推送到内网仓库
# 用法：
#   1. 先执行 image-pull-push-by-skopeo.sh 拉取镜像到 ./mayastor-images/
#   2. 修改下方 REGISTRY 为你的内网仓库地址
#   3. bash push-from-dir.sh

set -e

# ===== 配置区 =====
REGISTRY="${REGISTRY:-172.25.128.67:9003}"
LOCAL_DIR="${LOCAL_DIR:-./mayastor-images}"

# ===== 检查 =====
if [ ! -d "${LOCAL_DIR}" ]; then
  echo "错误：本地镜像目录 ${LOCAL_DIR} 不存在"
  exit 1
fi

if ! command -v skopeo >/dev/null 2>&1; then
  echo "错误：未找到 skopeo 命令"
  exit 1
fi

# ===== 推送 =====
echo ">>> 开始将 ${LOCAL_DIR} 中的镜像推送到 ${REGISTRY} ..."

for dir in "${LOCAL_DIR}"/*; do
  [ -d "${dir}" ] || continue

  # 目录名格式由 image-pull-push-by-skopeo.sh 生成：
  #   openebs_mayastor-io-engine_v2.8.0
  #   registry.k8s.io_sig-storage_csi-provisioner_v3.5.0
  name=$(basename "${dir}")

  # 把最后一个下划线还原为冒号（tag 分隔符）
  img_path=$(echo "${name}" | sed 's/\(.*\)_/\1:/')

  # 判断第一部分是否包含点，包含则说明是 registry 前缀
  first_part=$(echo "${img_path}" | cut -d'/' -f1)
  if echo "${first_part}" | grep -q '\.'; then
    # 带 registry 前缀，去掉原 registry，换成目标 registry
    target_img="${REGISTRY}/$(echo "${img_path}" | cut -d'/' -f2-)"
  else
    # 默认 docker.io 镜像，直接加目标 registry
    target_img="${REGISTRY}/${img_path}"
  fi

  echo ""
  echo ">>> 推送: ${name} -> ${target_img}"
  skopeo copy --dest-tls-verify=false "dir:${dir}" "docker://${target_img}"
done

echo ""
echo ">>> 全部推送完成"
