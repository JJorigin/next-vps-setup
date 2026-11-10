# 2.0 审计与验证范围

## 源码复查

复查以 1.5 为基线，覆盖首次运行、官方 APT 更新、任务恢复、SSH 开机启动和验收、内核删除与任务清理。新 Swap 规则另外核对了整 GiB 边界、文件系统余量、现有 Swap、磁盘分配、启动顺序，以及回执中保存的目标容量。启动后台服务前和重启续行时均核对 systemd 实际读取的服务配置。

## 实际验证范围

两份脚本通过 Bash 语法检查、ShellCheck 错误级扫描、236 项本地隔离回归、内嵌代码一致性检查及 SHA256 核对。

五台本地 Debian 13 amd64 虚拟机使用与交付一致的脚本完成测试。虚拟机使用 cloud 内核和 ext4。

| 本地测试 | 结果 |
|---|---|
| 512 MiB、2.5 GiB 内存 | 分别创建 1 GiB、3 GiB Swap。重启后容量、优先级和 `swappiness` 符合配置 |
| 1 GiB 内存，已有 Swap | 原文件、优先级、`swappiness` 和持久设置均通过核对 |
| 2 GiB 内存，空间不足 | 跳过新建 Swap，其他初始化步骤完成 |
| 768 MiB 内存，模拟 Swap 单元覆盖 | 在启用前停止。移除覆盖后用原脚本恢复，复用原文件并完成重启验收 |
| 内核维护 | 在 512 MiB 和 2.5 GiB 虚拟机上验证重启、Swap 保留、旧内核删除和清理，最终只保留目标内核及原元包 |

本次虚拟机验证还检查了 SSH 重连、Fail2ban 配置、任务文件清理和一次性登录通知。其中一台配置了仅供对照的非官方 APT 源及钩子，初始化仍通过，并核对了这些文件的哈希。

批量部署前，请在实际使用的每种商家镜像上先试装一台，确认新 SSH 连接、完成回执和 Swap 符合预期。上表的运行结果来自本地虚拟机。

如果首次准备任务或发布通知时突然断电，脚本会保留无法确认归属的目录。这类残留需人工核查后再恢复。

早期版本的验证范围见 [1.5](https://github.com/JJorigin/next-vps-setup/blob/1.5/docs/kernel-update-audit.md)、[1.4](https://github.com/JJorigin/next-vps-setup/blob/1.4/docs/kernel-update-audit.md) 和 [1.3](https://github.com/JJorigin/next-vps-setup/blob/1.3/docs/kernel-update-audit.md)。
