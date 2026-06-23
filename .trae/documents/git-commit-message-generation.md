# 生成 Git 提交信息

## 历史提交风格参考

```
更新 Mayastor DiskPool 配置至 v1beta3 并修正磁盘路径

- 将 apiVersion 从 io.openebs.storage/v1beta2 升级到 openebs.io/v1beta3
- 将裸盘路径 /dev/nvme0n1 替换为持久化 by-id 路径
- 添加 Mayastor 4.x 设备路径使用说明
- 补充测试用 pod 压缩包
```

特点：中文标题（可带 feat: 前缀）+ `-` 列表正文

## 变更分析

* 删除 mayastor/ 解压目录及旧脚本（478 文件，76524 行）

* 重组为 diskpool/、helm/、storageclass/、test-pod/ 子目录

* 新增 HDD 存储池配置及对应 StorageClass、测试文件

* 新增气隙部署工具链及 README 文档

## 提议的提交信息

```
refactor(openebs/mayastor): 重构 Mayastor 部署资源目录结构

- 将 Helm Chart 从 mayastor/ 子目录迁移至 helm/mayastor/，与运行时资源分离
- 将 DiskPool、StorageClass、测试 Pod/PVC 等资源按类型归入独立目录
- 新增 HDD 机械硬盘 DiskPool 配置示例（diskpool-hdd.yaml）及对应三副本 StorageClass
- 删除旧目录下混杂的脚本、压缩包、镜像清单及未分类 YAML 文件
- 影响范围：openebs/mayastor/ 下的所有部署清单与 Helm 包
```

## 执行步骤

1. `git add -A`
2. `git commit -m "..."`（使用 HEREDOC 传递多行信息）
3. `git log --oneline -1` 确认

