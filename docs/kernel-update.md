# Debian 13 内核维护

`next-vps-kernel-update.sh` 1.1 是 `next-vps-setup` 的配套工具，用于完成初始化后的内核更新。

它保留原来的cloud／标准amd64系列，更新Debian官方稳定源内核，自动重启一次，核验后清理旧版本，只保留本次目标内核和原系列元包。原初始化配置和结果文件保留。

## 使用要求

- Debian 13、amd64、systemd虚拟机，使用root。
- 本机有已完成的 `next-vps-setup` 初始化结果。
- 根分区至少512MiB空闲、`/boot` 至少200MiB空闲、可用内存至少128MiB。
- 已备份重要数据，并确认商家控制台可用。

已有其他APT源可以保留；任务使用独立官方源获取更新，不修改原源文件。第三方软件的兼容性仍需自行确认。遇到被设为hold的内核包、混装元包、第三方内核或无法确认的包状态时，工具会停止。

**旧内核清理后没有备用内核可回退，请在允许业务短暂中断时执行。**

## 下载并检查

以下方式任选一种，任务运行期间不要重复下载或替换脚本。

GitHub：

```bash
curl -fL --retry 3 --connect-timeout 15 \
  https://raw.githubusercontent.com/JJorigin/next-vps-setup/v1.1/next-vps-kernel-update.sh \
  -o /root/next-vps-kernel-update.download &&
mv -fT -- /root/next-vps-kernel-update.download /root/next-vps-kernel-update.sh &&
chmod 700 /root/next-vps-kernel-update.sh &&
bash /root/next-vps-kernel-update.sh --check
```

jsDelivr：

```bash
curl -fL --retry 3 --connect-timeout 15 \
  https://cdn.jsdelivr.net/gh/JJorigin/next-vps-setup@v1.1/next-vps-kernel-update.sh \
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

`--check` 只检查本机条件，不刷新软件索引、不安装软件、不删除内核、不重启。正式运行时才通过独立官方源检查更新。

## 开始更新

前置检查通过后：

```bash
bash /root/next-vps-kernel-update.sh
```

任务会在后台依次完成：

1. 获取官方更新，安装原系列内核及必要依赖。
2. 自动重启一次，开机后继续。
3. 检查运行内核、启动文件、SSH、Fail2ban、Swap和相关配置与服务。
4. 自动识别并清理旧内核，保留当前目标内核和元包。
5. 清理本次任务文件，保存结果。

即使内核名称没有变化，也会通过新启动核验。工具不执行整套软件包升级，不额外安装推荐包，不做全局 `autoremove`。

## 重连后查看结果

重启时SSH会断开，需手动重新连接。首次断线后可先等待约3～10分钟；下载、开机或服务恢复较慢时需要更久。

后台任务完成或失败后，下次通过SSH以root交互登录时会显示一次结果提示，显示后自动清理。常见Bash登录环境可使用该提示；其他登录环境没有提示时，直接查询：

```bash
cat /var/lib/next-vps-kernel-update-result.tsv
```

以下三项同时满足才表示完成：

```text
phase           done
result_status   complete
failed          no
```

如果任务仍在运行，结果不会显示本次成功。原初始化结果仍保留当时的内核版本，本次结果以独立的内核维护文件为准。

完成后建议检查：

```bash
uname -r
dpkg --audit
apt-get check
```

`dpkg --audit` 正常无输出，`apt-get check` 应无依赖错误。也请实际连接业务服务，确认正常使用。

## 失败后恢复

先保留状态和日志，不要反复开始新任务或手工删除内核文件。查看日志：

```bash
tail -n 100 /var/lib/next-vps-kernel-update/run.log
```

修复原因后，使用原版本、相同内容、原路径的脚本继续：

```bash
bash /root/next-vps-kernel-update.sh --resume
```

如果停在 `cleanup_pending` 且入口已被清理，重新上传相同内容到原路径，再执行 `--resume`。不要删除结果文件，它包含恢复清理所需的记录。

失败后不会反复自动重启。删除过程使用APT；若中途失败，可能已有部分旧内核被删除，应结合日志和实际包状态处理。

## 下次维护

成功后，本次上传脚本、工作副本、后台服务和临时日志会被清理，独立结果文件会保留。下次重新下载或上传脚本，再按“检查→更新”执行即可。

登录提示与任务恢复文件分别处理：提示显示后自行清理；失败时需要排查和恢复的任务文件不会因此删除。
