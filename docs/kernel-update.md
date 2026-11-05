# Debian 13 内核维护

`next-vps-kernel-update.sh` V1.3 是 `next-vps-setup` 的配套工具，用于初始化完成后的内核更新。

工具更新 Debian 官方稳定源内核，保留原来的 cloud／标准 amd64 系列，自动重启一次。新启动核验通过后，动态清理旧内核，只保留本次目标内核和原系列元包。原初始化配置和结果文件保留，不执行整套软件包升级。

## 开始前确认

- Debian 13、amd64、systemd 虚拟机，使用 root。
- 本机已有成功完成的 `next-vps-setup` 初始化结果；无需重新初始化。
- 根分区至少512MiB空闲、`/boot` 至少200MiB空闲、可用内存至少128MiB。
- SSH 和 Fail2ban 正常运行，重要数据已备份，商家控制台可用。
- 没有其他初始化、内核维护或 APT 安装任务同时运行。

任务使用独立的官方 APT 源、索引及包缓存，保留签名验证，不修改现有源文件。已有第三方软件仍需自行确认安全性与兼容性。遇到被设为 hold 的内核包、混装元包、第三方内核或无法确认的状态时停止。

**旧内核删除后没有备用内核可回退，请选择允许业务短暂中断的时段。任务运行期间不要重新下载或替换脚本。**

## 下载并检查

以下两种方式任选一种。

GitHub：

```bash
curl -fL --retry 3 --connect-timeout 15 \
  https://raw.githubusercontent.com/JJorigin/next-vps-setup/1.3/next-vps-kernel-update.sh \
  -o /root/next-vps-kernel-update.download &&
mv -fT -- /root/next-vps-kernel-update.download /root/next-vps-kernel-update.sh &&
chmod 700 /root/next-vps-kernel-update.sh &&
bash /root/next-vps-kernel-update.sh --check
```

jsDelivr：

```bash
curl -fL --retry 3 --connect-timeout 15 \
  https://cdn.jsdelivr.net/gh/JJorigin/next-vps-setup@1.3/next-vps-kernel-update.sh \
  -o /root/next-vps-kernel-update.download &&
mv -fT -- /root/next-vps-kernel-update.download /root/next-vps-kernel-update.sh &&
chmod 700 /root/next-vps-kernel-update.sh &&
bash /root/next-vps-kernel-update.sh --check
```

没有 `curl` 时，可从仓库下载文件，上传到 `/root/next-vps-kernel-update.sh`，再执行：

```bash
chmod 700 /root/next-vps-kernel-update.sh
bash /root/next-vps-kernel-update.sh --check
```

`--check` 只检查本机条件，不刷新软件索引、不安装软件、不删除内核、不重启。正式开始后才获取官方更新。

## 执行维护

前置检查通过后：

```bash
bash /root/next-vps-kernel-update.sh
```

后台任务依次完成：

1. 从官方源安装原系列内核及必要依赖。
2. 自动重启一次，开机后继续。
3. 核对运行内核与目标启动镜像，检查 SSH、Fail2ban、Swap 和相关配置及服务。
4. 通过 APT 精确清理旧内核，保留本次目标内核和原系列元包。
5. 清理所属任务文件，保存结果。

即使内核名称没有变化，也会执行新启动核验。工具不额外安装推荐包，不做全局 `autoremove`。

维护保留原 SSH 账号、密码、认证方式和端口，以及维护前的 Swap 与 `swappiness`。V1.3 比较 Swap 的路径、容量和优先级，不将正常变化的已用量计入摘要；读取失败时会停止，不放行后续删除。

若维护前 `x-ui.service` 正在运行，也会检查重启后是否恢复运行。进程运行状态不能代替面板访问、证书或节点连通测试，完成后仍应实际检查自己的业务。

## 重连并查看结果

重启会断开 SSH，需手动重新连接。首次断线后先等待约3～10分钟；下载、开机或服务恢复较慢时需要更久。

后台任务成功或失败后，下次以 root 通过交互式 Bash SSH 登录，会显示一次结果，随后自动清理通知文件。没有看到提示时查询：

```bash
cat /var/lib/next-vps-kernel-update-result.tsv
```

以下三项同时满足才表示完成：

```text
phase           done
result_status   complete
failed          no
```

`cleanup_pending` 表示清理尚未完成。原初始化结果记录当时状态；本次维护以独立的内核维护结果为准。

完成后可检查：

```bash
uname -r
dpkg --audit
```

`dpkg --audit` 正常无输出。请同时实际连接业务服务，确认正常使用。

## 失败后恢复

先保留原脚本、任务状态和日志，查看具体原因：

```bash
tail -n 100 /var/lib/next-vps-kernel-update/run.log
cat /var/lib/next-vps-kernel-update-result.tsv
```

日志和结果确认原因、处理完成后，使用**原版本、相同内容、原路径**的脚本恢复：

```bash
bash /root/next-vps-kernel-update.sh --resume
```

不要反复开始新任务、删除状态文件或手工删除内核文件。若入口已被清理，重新上传相同内容到原路径，再执行 `--resume`。失败后不会反复自动重启；删除过程若中途失败，可能已有部分旧内核被删除，需结合日志及实际包状态处理。

### V1.2 的 Swap 核验误报

V1.2 若提示 `Swap or swappiness did not persist.`，可能是旧命令误将 Swap 已用量纳入摘要。该提示也可能对应真实配置变化，不能一律当作误报。

请保留原版本脚本、状态和日志，先核对实际 Swap 与 `swappiness`。不要为消除报错而关闭或重建 Swap、改写结果摘要，也不要下载 V1.3 覆盖未完成任务。V1.3 不会自动迁移或接管旧版本任务；恢复方案需要基于该任务的实际记录判断。

### 旧版仅在前置检查停止

若旧版仅在 `--check` 提示官方密钥文件不支持，且尚未创建维护任务，可以下载 V1.3 后重新检查。Debian 的官方 `.gpg` → `.pgp` 兼容链接无需手动修改或删除。

## 下次维护

成功后清理本次入口脚本、工作副本、后台服务、私有 APT 目录及临时日志，保留独立结果文件。下次需要维护时，重新下载脚本，按“检查 → 开始维护”执行。

一次性通知显示后只清理通知自身；失败任务的日志和恢复资料会保留。已经成功完成旧版本任务的机器，无需为升级脚本版本重新初始化。
