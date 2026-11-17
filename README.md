# EasyTier 服务端一键脚本 — 设计说明

脚本：`easytier-server.sh`（Bash，面向带 systemd 的 Linux：Debian / Ubuntu / CentOS / Rocky 等）
部署模式与本次实战一致：**easytier-web-embed（控制台 + 配置服务器）托管 easytier-core**，纯 systemd 参数运行，不用 TOML。

## 快速开始

```bash
chmod +x easytier-server.sh
sudo ./easytier-server.sh            # 交互菜单
sudo ./easytier-server.sh install    # 一键安装
sudo ET_VERSION=2.7.1 ET_GH_PROXY=https://ghfast.top/ ./easytier-server.sh install
```

## 命令一览

| 命令 | 作用 |
|---|---|
| `install` | 一键安装：预检 → 下载+SHA256 校验 → 写 systemd 单元 → 设自启 → 启动 → 健康检查 → 打印建网步骤 |
| `update` | 更新到 ET_VERSION：先自动备份 → 换二进制 → 重启 → 健康检查，**不过自动回滚** |
| `uninstall` | 停服、禁用自启、删单元与二进制（默认保留数据和备份） |
| `uninstall --purge` | 连数据目录和备份一起删（二次确认） |
| `start` / `stop` / `restart` | 启停两个服务（顺序固定：先 Web 后核心） |
| `status` | 服务状态 + 版本 + 关键端口监听 |
| `check` | 健康检查：服务/自启/端口/控制台 HTTP/实例监听/日志刷屏预警 |
| `backup` | 立即备份到 `/opt/easytier-backups/easytier-backup-<时间戳>` |
| `rollback [目录]` | 回滚到指定备份（默认最近一份） |
| `logs [行数]` | 查看两个服务的日志 |
| `menu` | 交互菜单（无参数时默认） |

## 可配置项（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `ET_VERSION` | `2.7.1` | 目标版本（不带 v）；填 `latest` 自动取最新正式版 |
| `ET_GH_PROXY` | 空 | GitHub 加速前缀，如 `https://ghfast.top/` |
| `ET_GH_PROXY_FALLBACKS` | ghfast.top / gh-proxy.com / ghproxy.net | 备用加速前缀，空格分隔，依次轮换，最后 GitHub 直连兜底 |
| `ET_PUBLIC_IP` | 自动探测 | 完成提示里展示的公网 IP，内网/多网卡环境可手动指定 |
| `ET_WEB_PORT` | `26010` | 控制台/API 端口（TCP） |
| `ET_CONFIG_PORT` | `26020` | 配置服务器端口 |
| `ET_CONFIG_PROTO` | `udp` | 配置服务器协议 udp / tcp |
| `ET_ADMIN_USER` | `admin` | 核心归属的控制台账号（核心用 `协议://127.0.0.1:端口/账号` 报到） |
| `ET_SERVER_NAME` | `easytier-server` | 核心主机名（后台里显示的名字） |
| `ET_INSTALL_DIR` | `/opt/easytier` | 安装根目录 |
| `ET_BACKUP_DIR` | `/opt/easytier-backups` | 备份目录 |
| `ET_DISABLE_REGISTRATION` | `1` | 禁止控制台注册新账号 |
| `ET_OPEN_FIREWALL` | `0` | 设 1 时顺带放行本机 ufw / firewalld（**云安全组仍需在控制台放行**） |
| `ET_YES` | `0` | 设 1 跳过所有交互确认（适合批量/自动化） |

架构自动识别：x86_64 / aarch64；其他架构会明确报错退出。

## 本次实战的坑 → 脚本的对策

| 踩过的坑 | 脚本对策 |
|---|---|
| 以为装的是 2.6.4，实际是 2.6.0 | install/update 前先实测已装版本并打印；update 显示「当前 → 目标」 |
| 两个服务被停后没设自启，机器重启后停摆 10 天 | 安装即 `enable` 双服务；`check` 专门校验自启状态 |
| 从国内直连 GitHub 慢到 13 KB/s | 多源轮换下载：指定加速前缀 → 内置备用列表 → 直连兜底 |
| 怕下到坏包/错包 | 每个源下完立刻用官方 SHA256SUMS 校验，不过就换源 |
| 升级没有退路 | update 前自动全量备份（二进制+单元+DB 的 sqlite 一致性快照）；健康检查不过**自动回滚**；另有手动 `backup`/`rollback` |
| 云安全组漏放 UDP 26020，客户端能组网却注册不进后台 | 安装完成打印逐项放行清单（TCP 26010 / UDP 26020 / TCP+UDP 11010-11013）；`check` 校验配置端口监听 |
| 新建网络实例监听为空，服务器「在线但耳聋」 | 完成提示写明补监听的正确顺序与地址写法（`tcp://0.0.0.0:11010`）；`check` 发现「有实例但 11010 未监听」会预警 |
| 旧配置把自己的公网地址当 peer，无限重试刷屏 | `check` 统计近 10 分钟 `connect to peer error` 条数，超阈值预警 |
| wanju 是旧版遗留的孤儿配置，新后台里看不见 | 脚本统一走 2.7 中心网络模型部署；完成提示写明「先建网络、再给设备运行」的顺序 |
| 核心和 Web 启动顺序敏感（核心要连本机配置服务器） | 启停封装固定顺序：启动先 Web 后核心，停止先核心后 Web |

## 注意事项

- 脚本管的是**服务端基础设施**（二进制、服务、备份、健康）；建网络、加成员、分配 IP 仍在控制台里做，完成提示里有顺序说明。
- 云厂商安全组脚本碰不到，务必按完成提示逐项核对——这是「半通不通」类问题最常见的根源。
- 备份目录默认在 `/opt/easytier-backups`，建议保留最近 2~3 份即可，别和安装目录一起误删（`uninstall` 默认保留它就是这个原因）。
- 在陌生机器上先跑 `./easytier-server.sh check` 也能当巡检用，不做任何修改。
