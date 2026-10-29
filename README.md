# next-vps-setup

**1.0 · Debian 13 VPS 基础初始化**

适合刚重装、已经能正常 SSH 登录的 VPS。输入机器名和当前 SSH 端口后，脚本会在后台完成更新、基础配置、重启验证和任务清理。

## 功能

| 项目 | 默认设置 |
|---|---|
| 系统更新 | 更新官方软件包及 Debian 13 官方稳定源当前最新内核，保留原 cloud／标准 amd64 系列 |
| SSH | 保留现有账号、密码、端口和认证方式；输入端口仅用于核验 |
| 主机名 | 运行时自行填写 |
| 时区 | 马来西亚 `Asia/Kuala_Lumpur`，UTC+8 |
| 时间同步 | 尽力启用；无法同步时记录警告，继续其他步骤 |
| SSH 防护 | Fail2ban：同一来源在10分钟内匹配5次失败事件，永久封禁 |
| 气球驱动 | 对模块式驱动禁止加载并重启验证；遇到内建驱动会停止并提示 |
| 小内存 Swap | 实际内存 **≤1GiB**：创建 **1GiB 磁盘 Swap**，`swappiness=10`、优先级10 |
| 大内存 | 实际内存 **>1GiB**：不新建 Swap，不修改已有 Swap 和 swappiness |
| 完成清理 | 清理本次执行文件、后台任务及临时日志，保留持久配置和结果摘要 |

内存按系统的 `MemTotal` 判断。标称1GB、系统实际可见约968MiB的机器会创建 Swap。小内存机器先启用 Swap，再进行软件更新。

## 使用要求

- 新装 **Debian 13、amd64、systemd 虚拟机**，使用 Debian 官方软件源。
- 使用 root，当前 SSH 连接正常，商家防火墙已放行该端口。
- 创建 Swap 要求本地可写 **ext4**；已有 Swap 或冲突配置时停止，不自动覆盖。
- 初始根分区至少2GiB空闲、`/boot`至少200MiB空闲，并有128MiB可用内存；Swap所在分区需容纳1GiB文件并留1GiB余量。

请在安装业务服务前使用。此版本不用于升级已有部署，不支持容器、NAT外部端口映射、多SSH监听端口或已有自定义Fail2ban配置。

## 开始使用

先安装下载工具，已有时可跳过：

```bash
apt-get update && apt-get install -y --no-install-recommends curl ca-certificates
```

下面两种下载方式任选一种。请只执行一次，**安装进行中不要重新下载或替换脚本**。

### GitHub

```bash
curl -fL --retry 3 --connect-timeout 15 \
  https://raw.githubusercontent.com/JJorigin/next-vps-setup/v1.0/next-vps-setup.sh \
  -o /root/next-vps-setup.download &&
mv -fT -- /root/next-vps-setup.download /root/next-vps-setup.sh &&
chmod 700 /root/next-vps-setup.sh &&
bash /root/next-vps-setup.sh
```

### jsDelivr

```bash
curl -fL --retry 3 --connect-timeout 15 \
  https://cdn.jsdelivr.net/gh/JJorigin/next-vps-setup@v1.0/next-vps-setup.sh \
  -o /root/next-vps-setup.download &&
mv -fT -- /root/next-vps-setup.download /root/next-vps-setup.sh &&
chmod 700 /root/next-vps-setup.sh &&
bash /root/next-vps-setup.sh
```

也可以从仓库下载 `next-vps-setup.sh`，上传到 `/root/next-vps-setup.sh` 后执行：

```bash
chmod 700 /root/next-vps-setup.sh
bash /root/next-vps-setup.sh
```

脚本需要保存为本地文件，以便重启后续行。请勿使用 `curl | bash` 或进程替换方式运行。

## 运行后会发生什么

1. 输入本机机器名和**当前实际 SSH 端口**。脚本不会修改登录密码或端口。
2. 通过检查后，任务交给 systemd 在后台执行。
3. 必要时自动重启并继续，SSH 会断开。**SSH 不会自动重连，需要手动连接。**
4. 首次断线后，可先等待约 **5～10分钟**再连接查询；下载或更新较慢时会更久，期间可能再次重启。

重新连接成功不代表任务已经完成，请查看结果。

## 查看进度与结果

执行期间查看状态：

```bash
bash /root/next-vps-setup.sh --status
```

查看运行日志：

```bash
tail -n 80 /var/lib/next-vps-setup/next-vps-setup.log
```

查看最终结果：

```bash
cat /var/lib/next-vps-setup-result.tsv
```

以下三项同时满足，才表示全部必需步骤完成：

```text
phase           done
result_status   complete
failed          no
```

小内存机器还应显示 `swap_status verified`；大于1GiB的机器显示 `swap_status skipped`。NTP未同步属于独立警告，会如实记录。

成功后，上传的脚本和任务日志会被清理，之后直接查看结果摘要即可。Swap文件及其启动配置、Fail2ban数据库等会保留。

## 出错后处理

出现 `STOP` 或 `failed yes` 时，任务已经停止，请先保留日志并排查，不要反复运行下载命令或删除状态文件。

修复原因后，使用原文件继续：

```bash
bash /root/next-vps-setup.sh --resume
```

恢复必须使用同一版本文件；不要在运行中换用其他版本。`cleanup_pending` 表示清理尚未完成，不等于成功。遇到清理中断且入口已删除时，按结果中的原路径上传同版本文件，再执行 `--resume`。

不要使用自己的管理IP连续试错SSH密码，以免被永久封禁。需要解封时，通过商家控制台或另一可信连接执行：

```bash
fail2ban-client set sshd unbanip '被封禁的IP'
```

## 说明

- 更新至 Debian 13 官方稳定源当前最新内核，不使用第三方内核。
- 不建立整套本机防火墙，不启用 `nftables.service`，不清空现有规则；Fail2ban只管理自己的封禁规则。
- 不删除旧内核、系统日志，不执行 `autoremove`。
- 系统升级和重启有风险，请先备份重要数据，并确认能使用商家控制台。首次使用建议先在可恢复的新系统验证。
- 固定版本链接指向1.0；后续修复通过新版本发布。
