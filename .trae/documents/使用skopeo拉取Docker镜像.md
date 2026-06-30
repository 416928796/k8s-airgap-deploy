# 使用 skopeo 拉取 Docker 镜像到本地 DIR 存储

## 任务摘要

使用WSL环境中的skopeo工具，从 `images-list.txt` 读取镜像名称，将镜像拉取到本地目录存储（DIR格式）。

## 镜像列表分析

**必需镜像：**

* `docker.io/bitnami/postgresql:16.4.0-debian-12-r0`

**可选镜像（已注释，默认不启用）：**

* `docker.io/bitnami/os-shell:latest`

* `docker.io/bitnami/postgres-exporter:latest`

> 注：本次仅拉取必需镜像。

## 实施方案

### 步骤 1：确认images目录存在

* 目标位置：`e:\Code\002-k8s部署\postgres-benchmark\images\`

* WSL访问路径：`/mnt/e/Code/002-k8s部署/postgres-benchmark/images/`

### 步骤 2：拉取镜像

使用skopeo copy命令：

```bash
wsl -- skopeo copy docker://docker.io/bitnami/postgresql:16.4.0-debian-12-r0 dir:///mnt/e/Code/002-k8s部署/postgres-benchmark/images/postgresql-16.4.0-debian-12-r0
```

### 步骤 3：验证镜像完整性

```bash
wsl -- skopeo inspect dir:///mnt/e/Code/002-k8s部署/postgres-benchmark/images/postgresql-16.4.0-debian-12-r0
```

### 步骤 4：检查文件结构

```bash
wsl -- ls -la /mnt/e/Code/002-k8s部署/postgres-benchmark/images/
```

## 预期结果

* 目录 `postgres-benchmark/images/` 下包含镜像的完整DIR格式文件（以镜像名命名的子目录）

* 每个镜像目录包含：`manifest.json`, `*.layer` 等必要文件

