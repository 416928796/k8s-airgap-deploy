#!/bin/bash
# Mayastor 部署后验证脚本

set -e

NAMESPACE="openebs"

echo "===== 1. Mayastor Pod 状态 ====="
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/part-of=mayastor -o wide

echo ""
echo "===== 2. DiskPool 状态 ====="
kubectl get diskpool -n "${NAMESPACE}" -o wide

echo ""
echo "===== 3. StorageClass 列表 ====="
kubectl get storageclass

echo ""
echo "===== 4. 测试 PVC 绑定状态 ====="
kubectl get pvc mayastor-test-pvc -n default || true

echo ""
echo "===== 5. io-engine 节点 hugepages 使用 ====="
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "Node: ${node}"
  kubectl get pod -n "${NAMESPACE}" -l app=mayastor-io-engine --field-selector spec.nodeName="${node}" -o name || true
done

echo ""
echo "===== 验证完成 ====="
