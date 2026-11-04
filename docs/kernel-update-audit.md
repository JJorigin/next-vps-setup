# 1.1.1 开发验证范围

本页说明本地检查能覆盖什么，以及仍需真实服务器验证的部分。

1.1.1发布前，两份脚本的Bash语法检查及114项本地测试通过。

## 检查范围

- 两个脚本的Bash语法和源码审阅。
- 动态内核识别、Debian包版本比较、精确删除清单和APT事务保护。
- 重启续行、错误启动目标、失败停止、状态保存及清理中断恢复。
- 独立官方源的使用范围，以及现有源文件的保留。
- Debian 13 官方密钥符号链接的识别、异常密钥文件拒绝及密钥包升级后的配置一致性。
- 三个官方仓库索引的中断恢复，以及合法空软件包索引的兼容处理。
- 任务阶段和结果显示、下一次root交互登录提示及提示清理。
- 原有SSH、Swap、Fail2ban、气球驱动配置等保留检查。

测试使用临时目录、虚构软件包记录及系统命令替身；实际APT协议检查也重定向到隔离目录，并使用拒绝执行的dpkg替身，避免变更测试宿主的软件包。官方源隔离还使用真实APT配置解析和URI预览检查，未执行软件安装。

## 验证边界

本地模拟不能代替真实Debian 13 VPS的安装、启动和业务连通性验证。首次使用应选择有备份、能通过商家控制台恢复的机器。

服务显示正常不等于业务连接一定正常，完成后仍需实际连接业务服务。登录提示面向常见Bash登录环境，其他Shell应使用结果查询命令。

APT清理不是原子事务；维护钩子失败时，可能已有部分旧内核被删除。脚本会停止并保留排查和恢复资料，审计时应结合日志与实际软件包状态。

## 参考文档

- [APT命令与模拟](https://manpages.debian.org/trixie/apt/apt-get.8.en.html)
- [APT精确包名匹配](https://manpages.debian.org/trixie/apt/apt-patterns.7.en.html)
- [APT事务钩子协议](https://manpages.debian.org/trixie/apt/apt.conf.5.en.html)
- [Debian官方密钥包的链接及安装布局](https://sources.debian.org/src/debian-archive-keyring/2025.1/Makefile/)
- [Debian内核安装和删除钩子](https://kernel-team.pages.debian.net/kernel-handbook/ch-update-hooks.html)
