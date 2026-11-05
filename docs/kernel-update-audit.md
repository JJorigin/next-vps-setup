# V1.3 审计与验证范围

本页记录本次发布实际执行的检查。测试使用本地临时目录和一次性 Debian 13 虚拟机，没有连接或修改用户的 VPS。

## 代码与隔离回归

- 两份交付脚本的 Bash 语法检查通过。
- 207 项隔离测试通过；嵌入代码构建检查和两份 SHA256 校验通过。
- 使用真实 util-linux `swapon` 和临时交换区记录，验证显式列参数、正常已用量变化、多 Swap 排序以及增删 Swap。
- 路径、容量、优先级或 swappiness 真的变化时仍会拒绝验收；Swap 为空且 swappiness 保持60时可以通过。
- Swap、SSH 或配置读取失败，即使已经输出部分内容，也不能被相同摘要误判为成功。
- 1.3 拒绝接管未完成的 1.2 任务，原资料保持不变；已完成的 1.2 结果允许后续新建 1.3 维护任务。
- 继续覆盖官方内核系列识别、运行内核构建匹配、精确旧核选择、APT 实际删除事务、重启续行、准备阶段中断恢复、通知及所属任务清理。
- 四份共享代码与两入口的构建一致性检查通过。

新增错误传播用例也针对不可变的 1.2 临时副本运行：旧版按预期不能通过新断言，修复版通过。测试不执行真实的软件安装、内核删除或宿主 Swap 变更；系统操作使用隔离目录和命令替身。

## 本地 Debian 13 虚拟机实测

本次交付的同哈希脚本在一台全新 512MiB、cloud amd64、systemd 虚拟机上完成以下检查：

| 检查 | 结果 |
|---|---|
| 官方 APT 签名、Debian 标准密钥兼容链接 | 通过 |
| 原有源文件、代理配置和钩子隔离 | 保留原文件，不执行原更新钩子 |
| 权限异常索引拒绝、合法临时链接恢复 | 通过 |
| 初始化、官方内核更新及两次自动重启 | 完成 |
| 1GiB Swap、优先级10、swappiness=10 | 重启后核验通过 |
| SSH 配置、Fail2ban、时区和气球驱动配置 | 独立检查通过 |
| 内核维护及一次自动重启 | 完成 |
| 旧内核清理 | 仅保留目标镜像和原系列元包 |
| 两种任务的一次性 SSH 通知 | 首次显示、再次不显示，通知文件清理 |
| 入口、后台任务、私有 APT 目录及临时文件 | 所属清理检查通过 |

为直接覆盖本次误报，测试进程将自己的匿名内存换出到真实磁盘 Swap。维护前已用量为 **33,751,040 字节**，重启后变为 **0**；固定配置和摘要保持一致，V1.3 正常完成验收与旧核清理。没有通过关闭 Swap、凑回已用量或修改结果摘要放行。

实测使用 APT 3.0.3、systemd 257、util-linux 2.41.5 和 Debian 官方内核。测试文件与发布文件的 SHA256 一致。测试虚拟机完成后正常关闭。

此前 1.2 的三种内存和内核系列基线验证，保留在[原版本审计记录](https://github.com/JJorigin/next-vps-setup/blob/1.2/docs/kernel-update-audit.md)。该历史记录不作为 1.3 再次执行三台虚拟机测试的声明。

## 验证边界

这些结果不能覆盖所有商家、引导器、第三方服务或异常磁盘状态。服务进程运行不等于业务连接正常，完成后仍应实际访问业务。ShellCheck 未执行。

登录通知面向 root 交互式 Bash SSH 登录；其他 Shell 可直接读取结果文件。网络时间同步按设计尽力执行，未同步时提醒并继续。

旧内核删除使用 APT，不是原子事务；中途失败时可能已经删除部分旧版本，应保留原文件和日志处理。旧版本未完成任务不能通过覆盖新脚本恢复。

## 参考文档

- [swapon 参数与自定义列](https://manpages.debian.org/trixie/mount/swapon.8.en.html)
- [APT 命令与模拟](https://manpages.debian.org/trixie/apt/apt-get.8.en.html)
- [APT 精确包名匹配](https://manpages.debian.org/trixie/apt/apt-patterns.7.en.html)
- [APT 事务钩子协议](https://manpages.debian.org/trixie/apt/apt.conf.5.en.html)
- [Debian 官方密钥包布局](https://sources.debian.org/src/debian-archive-keyring/2025.1/Makefile/)
- [Debian 内核安装与删除钩子](https://kernel-team.pages.debian.net/kernel-handbook/ch-update-hooks.html)
- [systemctl 服务禁用与重载](https://manpages.debian.org/trixie/systemd/systemctl.1.en.html)
- [amd64 启动镜像头字段](https://www.kernel.org/doc/html/latest/arch/x86/boot.html)
