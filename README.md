# next-vps-setup

**1.1 · 一键 VPS 初始化，适用于 Debian 13。**

首次安装用 `next-vps-setup.sh`；以后更新内核，用配套的 `next-vps-kernel-update.sh`。

| 工具 | 什么时候使用 | 完成什么 |
|---|---|---|
| [系统初始化](#首次初始化) | 刚重装系统、尚未安装业务服务 | 官方更新、基础配置、SSH防护和重启检查 |
| [内核维护](#后续内核维护) | 已完成本项目初始化，需要更新内核 | 更新官方内核，重启检查后清理旧内核 |

两个工具均保留原来的 cloud／标准 amd64 内核系列，不使用第三方内核。已有其他 APT 源可以保留；任务使用独立的 Debian 官方源进行更新，不修改现有源文件。已安装的第三方软件仍需自行确认兼容性。有签名也不代表第三方软件一定安全；如果装过不可信软件，建议重装干净系统。

## 使用要求

- Debian 13、amd64、systemd 虚拟机，使用 root。
- 当前 SSH 登录正常，商家防火墙已放行对应端口。
- 操作前备份重要数据，并确认能使用商家控制台。

初始化仅用于新系统，不用于重新初始化已经部署业务的机器。不支持容器、NAT外部端口映射、多SSH监听端口或已有自定义Fail2ban配置。

## 首次初始化

初始化会完成以下设置：

| 项目 | 设置 |
|---|---|
| 官方更新 | 更新 Debian 官方软件包及稳定源当前最新内核 |
| SSH | 保留账号、密码、端口和认证方式；输入端口仅用于核验 |
| 主机名 | 运行时自行填写 |
| 时区 | 马来西亚 `Asia/Kuala_Lumpur`，UTC+8 |
| 时间同步 | 尽力启用，无法同步时警告并继续 |
| SSH防护 | Fail2ban：同一来源10分钟内匹配5次失败事件，永久封禁 |
| 气球驱动 | 禁止模块式驱动加载并重启检查；内建驱动无法处理时停止 |
| 实际内存≤1GiB | 创建1GiB磁盘Swap，`swappiness=10`、优先级10 |
| 实际内存>1GiB | 不新建Swap，不接管已有内存策略 |

内存按 `MemTotal` 判断。创建Swap要求本地可写ext4；已有Swap或冲突配置时停止，不自动覆盖。初始根分区需至少2GiB空闲、`/boot` 至少200MiB空闲、可用内存至少128MiB；Swap所在分区还需容纳1GiB文件并保留1GiB余量。

### 下载并运行

下面两种方式任选一种。**任务进行期间不要重复下载、替换脚本或同时执行系统升级。**

GitHub：

```bash
curl -fL --retry 3 --connect-timeout 15 \
  https://raw.githubusercontent.com/JJorigin/next-vps-setup/v1.1/next-vps-setup.sh \
  -o /root/next-vps-setup.download &&
mv -fT -- /root/next-vps-setup.download /root/next-vps-setup.sh &&
chmod 700 /root/next-vps-setup.sh &&
bash /root/next-vps-setup.sh
```

jsDelivr：

```bash
curl -fL --retry 3 --connect-timeout 15 \
  https://cdn.jsdelivr.net/gh/JJorigin/next-vps-setup@v1.1/next-vps-setup.sh \
  -o /root/next-vps-setup.download &&
mv -fT -- /root/next-vps-setup.download /root/next-vps-setup.sh &&
chmod 700 /root/next-vps-setup.sh &&
bash /root/next-vps-setup.sh
```

没有 `curl` 时，也可以下载本仓库的 `next-vps-setup.sh`，上传到 `/root/next-vps-setup.sh`，再执行：

```bash
chmod 700 /root/next-vps-setup.sh
bash /root/next-vps-setup.sh
```

请保存为本地文件后执行，不要使用 `curl | bash` 或进程替换。

### 等待并查看结果

输入机器名和当前SSH端口后，任务会在后台继续。期间可能重启多次，SSH会断开，**需要手动重新连接**。首次断线后可先等待约5～10分钟；下载或更新较慢时需要更久。

后台任务完成或失败后，下次通过SSH以root交互登录时会显示一次结果提示，提示显示后会自动清理。若任务仍在进行，不会显示为成功。该提示适用于常见的Bash登录环境；没有看到提示时，直接查询：

```bash
cat /var/lib/next-vps-setup-result.tsv
```

只有同时显示 `phase done`、`result_status complete`、`failed no` 才表示完成。NTP未同步会单独记录，不代表其他步骤失败。

成功后清理本次脚本、后台任务和临时日志，保留系统配置、Swap、Fail2ban数据库及结果文件。

## 后续内核维护

已完成本项目初始化的机器，以后使用配套工具更新内核，**无需重新运行初始化脚本**。

内核维护会自动识别版本，更新原系列官方内核，自动重启一次。核验正常后清理旧内核，只保留本次最新目标内核和原系列元包。它不执行整套系统软件升级。

**旧内核清理后没有备用内核可供回退。** 请在允许业务短暂中断时操作。

下载、前置检查和开始更新：

```bash
curl -fL --retry 3 --connect-timeout 15 \
  https://raw.githubusercontent.com/JJorigin/next-vps-setup/v1.1/next-vps-kernel-update.sh \
  -o /root/next-vps-kernel-update.download &&
mv -fT -- /root/next-vps-kernel-update.download /root/next-vps-kernel-update.sh &&
chmod 700 /root/next-vps-kernel-update.sh &&
bash /root/next-vps-kernel-update.sh --check &&
bash /root/next-vps-kernel-update.sh
```

`--check` 只检查本机条件，不安装软件、不删除内核、不重启；正式运行时才获取官方更新。

重启后先等待约3～10分钟，再手动连接SSH。后台任务完成或失败后同样会显示一次结果提示，也可以查询：

```bash
cat /var/lib/next-vps-kernel-update-result.tsv
```

成功标准同样是 `phase done`、`result_status complete`、`failed no`。详细步骤、jsDelivr下载方式和恢复方法见[内核维护说明](docs/kernel-update.md)。

## 出错后怎么办

出现 `STOP` 或 `failed yes` 时，先保留日志和任务文件，处理原因后使用**原版本、相同内容、原路径**的脚本继续：

```bash
# 初始化任务
bash /root/next-vps-setup.sh --resume

# 内核维护任务
bash /root/next-vps-kernel-update.sh --resume
```

只执行对应任务的命令。不要反复重新下载、删除状态文件或重跑初始化。通知提示会自行清理，失败任务所需的日志和恢复文件会保留。

运行日志分别位于：

- 初始化：`/var/lib/next-vps-setup/next-vps-setup.log`
- 内核维护：`/var/lib/next-vps-kernel-update/run.log`

`cleanup_pending` 表示清理尚未完成，不等于成功。若脚本入口已被清理，重新上传相同内容到原路径后再执行 `--resume`。

## 其他说明

- Fail2ban只管理自己的封禁规则，不启用整套本机防火墙，不清空现有规则。
- 不做全局 `autoremove`，不清除正常系统日志。
- 初始化结果记录当时状态；后续内核维护另存结果，不改写原初始化结果。
- 下载链接固定为1.1，已有1.0发布保持不变。新版本不能接管其他版本尚未完成的任务。
- 本地测试不能代替真实VPS验证，首次使用建议选择可恢复的机器。[开发验证范围](docs/kernel-update-audit.md)
