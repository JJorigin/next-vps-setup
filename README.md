# next-vps-setup

**V1.4 · 一键 VPS 初始化，适用于 Debian 13。**

新装系统使用 `next-vps-setup.sh`；以后更新内核使用 `next-vps-kernel-update.sh`。

两个工具都更新 Debian 官方内核，保留原来的 cloud／标准 amd64 系列，不更换第三方内核。任务使用独立的官方 APT 源和缓存，保留签名校验，不修改现有源文件。已安装的第三方软件仍需自行确认安全性和兼容性。

**已经成功初始化的机器无需重跑初始化。旧版本任务尚未完成时，请保留原脚本和日志，先处理原任务。**

## 使用要求

- Debian 13、amd64、systemd 虚拟机，使用 root。
- `/root` 由 root 独占访问，例如权限为 `0700`。
- 使用 `initramfs-tools` 和 Debian 标准或 cloud 内核。
- SSH 登录正常，商家防火墙已放行当前 SSH 端口。
- 操作前备份重要数据，并确认能使用商家控制台。
- 初始化只用于新装系统。SSH 需由 `ssh.service` 在单一端口监听。已安装 Fail2ban、存在自定义 Fail2ban 配置、使用 `ssh.socket` 或通过 NAT 映射成不同端口的系统不适用。

## 首次初始化

| 项目 | 设置 |
|---|---|
| 官方更新 | 更新 Debian 官方软件包及稳定源当前最新内核 |
| SSH | 保留账号、密码、端口和认证方式；输入端口仅用于核验 |
| 主机名 | 运行时自行填写 |
| 时区 | 马来西亚 `Asia/Kuala_Lumpur`，UTC+8 |
| 时间同步 | 尽力启用，无法同步时提醒并继续 |
| SSH 防护 | Fail2ban：同一来源10分钟内匹配5次失败事件，永久封禁 |
| 气球驱动 | 禁止模块式驱动加载并重启检查；无法处理内建驱动时停止 |
| 实际内存≤1GiB | 创建1GiB磁盘 Swap，`swappiness=10`、优先级10 |
| 实际内存>1GiB | 不新建 Swap，不接管已有内存策略 |

内存按 `MemTotal` 判断。低内存机器创建 Swap 需要本地可写的 ext4，已有 Swap 或冲突配置时会停止。开始前，根分区需至少 2GiB 空闲和 10,000 个空闲 inode，`/boot` 需至少 200MiB 空闲，可用内存需至少 128MiB。Swap 所在分区需能容纳 1GiB 文件并留出 1GiB 余量。

### 下载并运行

新装的 Debian 可能缺少 `curl` 或 CA 证书。已有这两项时直接选择 GitHub 或 jsDelivr 下载。缺少时，如果当前系统的 APT 源可用且可信，先执行：

```bash
apt-get --error-on=any update &&
apt-get install -y --no-install-recommends --no-remove curl ca-certificates
```

这一步使用系统现有软件源。若刷新失败或不想使用这些源，请走下方的本地上传方式。

**任务进行期间不要替换脚本、重复启动任务或同时执行系统升级。**

**GitHub 下载**

```bash
curl -fL --retry 3 --connect-timeout 15 \
  https://raw.githubusercontent.com/JJorigin/next-vps-setup/1.4/next-vps-setup.sh \
  -o /root/next-vps-setup.download &&
mv -fT -- /root/next-vps-setup.download /root/next-vps-setup.sh &&
chmod 700 /root/next-vps-setup.sh &&
bash /root/next-vps-setup.sh
```

**jsDelivr 下载**

```bash
curl -fL --retry 3 --connect-timeout 15 \
  https://cdn.jsdelivr.net/gh/JJorigin/next-vps-setup@1.4/next-vps-setup.sh \
  -o /root/next-vps-setup.download &&
mv -fT -- /root/next-vps-setup.download /root/next-vps-setup.sh &&
chmod 700 /root/next-vps-setup.sh &&
bash /root/next-vps-setup.sh
```

也可以从 [V1.4 发布页](https://github.com/JJorigin/next-vps-setup/releases/tag/1.4) 下载脚本，上传到 `/root/next-vps-setup.sh`，再执行以下命令。

```bash
chmod 700 /root/next-vps-setup.sh &&
bash /root/next-vps-setup.sh
```

请先保存为本地文件再运行，不要使用 `curl | bash` 或进程替换。

### 等待完成

输入机器名和当前 SSH 端口后，任务在后台继续，期间可能多次重启，SSH 会断开。**请先等待约5～10分钟，再手动连接 SSH**；下载或更新较慢时需要更久。

任务成功或失败后，下次通过 SSH 直接登录 root（登录 Shell 为 Bash）会显示一次结果，随后自动清理通知文件。没有看到提示时，可查询结果文件。

```bash
cat /var/lib/next-vps-setup-result.tsv
```

只有 `phase done`、`result_status complete`、`failed no` 同时满足才表示完成。NTP 未同步会单独提醒，不代表其他步骤失败。

成功后清理本次脚本、后台任务和临时日志，保留系统配置、Swap、Fail2ban 数据库及结果文件。

## 后续内核维护

完成本项目初始化后，使用配套工具更新原系列官方内核，自动重启一次，核验后清理旧内核，只保留本次目标内核和原系列元包。它不执行整套软件包升级。

**旧内核清理后没有备用内核可回退，请在允许业务短暂中断时操作。**

```bash
curl -fL --retry 3 --connect-timeout 15 \
  https://raw.githubusercontent.com/JJorigin/next-vps-setup/1.4/next-vps-kernel-update.sh \
  -o /root/next-vps-kernel-update.download &&
mv -fT -- /root/next-vps-kernel-update.download /root/next-vps-kernel-update.sh &&
chmod 700 /root/next-vps-kernel-update.sh &&
bash /root/next-vps-kernel-update.sh --check &&
bash /root/next-vps-kernel-update.sh
```

`--check` 只检查本机条件，不刷新索引、不安装软件、不删除内核、不重启。重启后先等待约3～10分钟，再手动连接 SSH 查看一次性提示，或查询：

```bash
cat /var/lib/next-vps-kernel-update-result.tsv
```

成功标准同样是 `phase done`、`result_status complete`、`failed no`。详细检查、jsDelivr 下载和恢复步骤见[内核维护说明](docs/kernel-update.md)。

## 出错后怎么办

先保留日志和任务文件，修复原因后使用**原版本、相同内容、原路径**的脚本恢复，只执行对应任务的命令：

```bash
# 初始化
bash /root/next-vps-setup.sh --resume

# 内核维护
bash /root/next-vps-kernel-update.sh --resume
```

初始化日志：`/var/lib/next-vps-setup/next-vps-setup.log`；内核维护日志：`/var/lib/next-vps-kernel-update/run.log`。

任务已提交但没有日志时，用 `journalctl -u next-vps-setup.service -n 80 --no-pager` 查看启动错误。内核维护请把服务名换成 `next-vps-kernel-update.service`。

如果日志明确提示已请求重启、但启动尚未发生，先确认 APT 和任务已停止，再通过商家控制台重启。重连后若任务仍显示失败，使用原脚本恢复。

V1.2 内核维护若提示 `Swap or swappiness did not persist.`，可能是旧版将 Swap 已用量计入比较造成误报。请保留原脚本、状态和日志，先确认实际原因。

`cleanup_pending` 表示清理尚未完成。若入口已清理，需重新上传相同内容到原路径再恢复。

## 其他说明

- 正常系统配置和结果文件有意保留；不做全局 `autoremove`，不清除正常系统日志。
- Fail2ban 只管理自己的封禁规则，不启用整套本机防火墙。
- 新版本不会自动接管旧版本未完成的任务；已成功完成的旧版初始化结果可以用于后续内核维护。

[更新记录](CHANGELOG.md) · [开发验证范围](docs/kernel-update-audit.md)
