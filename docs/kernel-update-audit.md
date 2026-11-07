# V1.4 审计与验证范围

V1.4 复查了新装 Debian 的下载入口、官方 APT 隔离、Swap 持久化、重启续行、内核删除、一次性 SSH 通知和恢复流程。两份交付脚本的嵌入代码与源码、SHA256 校验文件均已核对。

## 本次复查覆盖

- 下载前置条件与 README 命令，以及安装和内核维护的本机检查。
- APT 暂存区的所有权、目录边界和清理所依据的文件清单。
- Swap 暂存发布、重启请求中断及清理阶段恢复。
- 实际删除旧内核前的目标内核与软件包清单核对，以及删除中断后的记录。
- SSH 通知的锁、旧通知兼容及一次性清理。

本次仅做静态审计、构建一致性和哈希核对。V1.4 没有执行 Bash 语法检查、自动回归、虚拟机或 VPS 实机验证。

如果首次准备任务或发布通知时突然断电，脚本会保留无法确认归属的目录。出现这类残留时，需要人工核查后再恢复。

旧版的运行验证见 [V1.3 验证记录](https://github.com/JJorigin/next-vps-setup/blob/1.3/docs/kernel-update-audit.md) 和 [V1.2 验证记录](https://github.com/JJorigin/next-vps-setup/blob/1.2/docs/kernel-update-audit.md)，仅对应各自版本。
