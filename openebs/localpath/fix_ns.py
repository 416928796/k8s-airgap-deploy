import re

namespaced_kinds = {
    'Pod', 'ReplicationController', 'Service', 'DaemonSet', 'Deployment',
    'StatefulSet', 'ReplicaSet', 'Job', 'CronJob', 'ConfigMap', 'Secret',
    'PersistentVolumeClaim', 'ServiceAccount', 'Role', 'RoleBinding',
    'NetworkPolicy', 'Ingress', 'LimitRange', 'ResourceQuota',
    'HorizontalPodAutoscaler', 'PodDisruptionBudget', 'Lease', 'EndpointSlice'
}

def fix_doc(doc):
    lines = doc.split('\n')
    
    # 找根级别的 kind
    root_kind = None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('kind: ') and line == line.lstrip():
            root_kind = stripped.split(':', 1)[1].strip()
            break
    
    if not root_kind or root_kind not in namespaced_kinds:
        return doc
    
    # 检查根级别 metadata 是否已有 namespace
    has_ns = False
    in_root_metadata = False
    for line in lines:
        stripped = line.lstrip()
        if stripped.startswith('metadata:') and line == line.lstrip():
            in_root_metadata = True
            continue
        if in_root_metadata:
            if stripped.startswith('namespace:'):
                has_ns = True
                break
            indent = len(line) - len(stripped)
            if indent == 0 and stripped and not stripped.startswith('#'):
                break
    
    if has_ns:
        return doc
    
    # 在根级别 metadata: 后插入 namespace: openebs
    new_lines = []
    for line in lines:
        new_lines.append(line)
        if line.lstrip().startswith('metadata:') and line == line.lstrip():
            new_lines.append('  namespace: openebs')
    return '\n'.join(new_lines)

with open('openebs-airgap(5).yaml', 'r', encoding='utf-8') as f:
    content = f.read()

docs = re.split(r'\n---\n?', content)
fixed_docs = [fix_doc(doc) for doc in docs]
result = '\n---\n'.join(fixed_docs)

with open('openebs-airgap-fixed.yaml', 'w', encoding='utf-8') as f:
    f.write(result)

# 统计修改了多少个资源
count = 0
for doc in docs:
    original = doc
    fixed = fix_doc(doc)
    if original != fixed:
        count += 1

print(f'Done. Modified {count} resources.')
