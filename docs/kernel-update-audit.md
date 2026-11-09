# V1.5 审计与验证范围

## 源码复查

复查从 V1.4 开始，覆盖首次安装、重启前核验、旧任务恢复和最终清理。启动前检查 SSH 持久启动链路、主机名和时区查询。SSH 启动检查包括 Debian 服务的禁用标记。内核维护在安装前核对完整内核清单。

前台持有 root 私有锁时提交后台任务，worker 等待交接，状态查询同时查看 systemd 失败状态。锁目录位于 `/run`，随重启清理。

APT 暂存配置准备失败时停止。下载前核对 `_apt` 对密钥和目录的访问权限。清理先原子移走已核验的暂存目录，再删除归属记录。初始化遇到原索引丢失时可显式恢复并重新选择官方目标。内核维护在重启后核对已批准的目标和实际删除事务，期间允许仓库候选版本更新。

## 实际验证范围

本版进行了静态审计、内嵌代码一致性检查和 SHA256 核对。Bash 语法检查、回归套件和虚拟机或 VPS 运行验证均未执行。

批量部署前，建议按实际商家镜像试装。覆盖实际内存不超过 1GiB 和高于 1GiB 的路径，确认重启后可以新建 SSH 连接，回执完成，并核对小内存机的 Swap。

如果首次准备任务或发布通知时突然断电，脚本会保留无法确认归属的目录。这类残留需人工核查后再恢复。

各版的验证分别见 [V1.4](https://github.com/JJorigin/next-vps-setup/blob/1.4/docs/kernel-update-audit.md)、[V1.3](https://github.com/JJorigin/next-vps-setup/blob/1.3/docs/kernel-update-audit.md) 和 [V1.2](https://github.com/JJorigin/next-vps-setup/blob/1.2/docs/kernel-update-audit.md)。
