#!/usr/bin/env bash
# =============================================================================
# easytier-server.sh — EasyTier 服务端（核心 + Web 集中管理）一键部署/运维脚本
#
# 模式：easytier-web-embed（控制台 + 配置服务器） + easytier-core（受其托管）
# 功能：安装 / 更新（自动备份、失败自动回滚）/ 卸载 / 启停 / 重启 / 状态 /
#       健康检查 / 备份 / 回滚 / 日志
#
# 用法：
#   ./easytier-server.sh                 # 交互菜单
#   ./easytier-server.sh install         # 一键安装
#   ./easytier-server.sh update          # 更新到 ET_VERSION 指定版本
#   ./easytier-server.sh check           # 健康检查（版本/服务/端口/页面/常见坑）
#   ./easytier-server.sh uninstall       # 卸载（默认保留数据与备份）
#   ./easytier-server.sh uninstall --purge   # 连数据一起删
#
# 全部可配置项都可用环境变量覆盖，例如：
#   ET_VERSION=2.7.1 ET_WEB_PORT=26010 ET_GH_PROXY=https://ghfast.top/ \
#     ./easytier-server.sh install
#
# 设计说明见同目录 README-easytier-server.md
# =============================================================================
set -euo pipefail

# ------------------------------- 可配置项 -----------------------------------
ET_VERSION="${ET_VERSION:-2.7.1}"                 # 目标版本（不带 v）；latest=最新正式版
ET_INSTALL_DIR="${ET_INSTALL_DIR:-/opt/easytier}" # 安装根目录
ET_BACKUP_DIR="${ET_BACKUP_DIR:-/opt/easytier-backups}"
ET_WEB_PORT="${ET_WEB_PORT:-26010}"               # 控制台/API 端口 (TCP)
ET_CONFIG_PORT="${ET_CONFIG_PORT:-26020}"         # 配置服务器端口
ET_CONFIG_PROTO="${ET_CONFIG_PROTO:-udp}"         # 配置服务器协议 udp|tcp
ET_ADMIN_USER="${ET_ADMIN_USER:-admin}"           # 核心归属的控制台账号名
ET_SERVER_NAME="${ET_SERVER_NAME:-easytier-server}"   # 核心主机名（后台显示）
ET_MACHINE_ID="${ET_MACHINE_ID:-}"                # 留空则按 /etc/machine-id 稳定生成
ET_GH_PROXY="${ET_GH_PROXY:-}"                    # GitHub 加速前缀，如 https://ghfast.top/
ET_GH_PROXY_FALLBACKS="${ET_GH_PROXY_FALLBACKS:-https://ghfast.top/ https://gh-proxy.com/ https://ghproxy.net/}"
ET_PUBLIC_IP="${ET_PUBLIC_IP:-}"                  # 留空自动探测公网 IP
ET_DISABLE_REGISTRATION="${ET_DISABLE_REGISTRATION:-1}"  # 1=禁止控制台注册新账号
ET_OPEN_FIREWALL="${ET_OPEN_FIREWALL:-0}"         # 1=顺带放行本机防火墙(ufw/firewalld)
ET_YES="${ET_YES:-0}"                             # 1=跳过交互确认
ET_DOWNLOAD_TIMEOUT="${ET_DOWNLOAD_TIMEOUT:-600}" # 单个文件下载超时（秒）

BIN_DIR="$ET_INSTALL_DIR/server"
DATA_DIR="$ET_INSTALL_DIR/data"
LOG_DIR="$ET_INSTALL_DIR/logs"
UNIT_WEB="/etc/systemd/system/easytier-web-embed.service"
UNIT_CORE="/etc/systemd/system/easytier-core.service"
GITHUB_REPO="https://github.com/EasyTier/EasyTier"

# ------------------------------- 基础工具 -----------------------------------
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_off=$'\033[0m'
info()  { echo "${c_cyn}[INFO]${c_off} $*"; }
ok()    { echo "${c_grn}[ OK ]${c_off} $*"; }
warn()  { echo "${c_ylw}[WARN]${c_off} $*"; }
err()   { echo "${c_red}[ERR ]${c_off} $*" >&2; }
die()   { err "$*"; exit 1; }

confirm() { # confirm "提示" -> 0/1
  [ "$ET_YES" = "1" ] && return 0
  local ans; read -r -p "$1 [y/N] " ans || true
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

need_root() { [ "$(id -u)" = "0" ] || die "需要 root 运行（可用 sudo）"; }

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) die "暂不支持的架构：$(uname -m)（目前仅 x86_64 / aarch64）" ;;
  esac
}

detect_public_ip() {
  if [ -n "$ET_PUBLIC_IP" ]; then echo "$ET_PUBLIC_IP"; return; fi
  local ip=""
  ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [ -z "$ip" ] && ip="$(curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  [ -z "$ip" ] && ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || true)"
  echo "${ip:-<你的服务器公网IP>}"
}

preflight() {
  need_root
  command -v systemctl >/dev/null 2>&1 || die "未检测到 systemd，本脚本面向 systemd 的 Linux 发行版（Debian/Ubuntu/CentOS/Rocky 等）"
  command -v curl >/dev/null 2>&1 || die "需要 curl，请先安装"
  command -v unzip >/dev/null 2>&1 || die "需要 unzip，请先安装"
  if [ -r /etc/os-release ]; then . /etc/os-release; info "系统：${PRETTY_NAME:-unknown} / 架构：$(uname -m)"; fi
}

port_busy() { # port_busy <port> -> 0 表示被占用（且占用者不是 easytier）
  ss -tuln 2>/dev/null | grep -qE "[:.]$1[[:space:]]" || return 1
  ss -tulnp 2>/dev/null | grep -E "[:.]$1[[:space:]]" | grep -q easytier && return 1
  return 0
}

resolve_version() {
  if [ "$ET_VERSION" = "latest" ]; then
    local tag
    tag="$(curl -fsSL --max-time 20 https://api.github.com/repos/EasyTier/EasyTier/releases/latest | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)"
    [ -n "$tag" ] || die "无法获取最新版本，请手动指定 ET_VERSION"
    ET_VERSION="${tag#v}"
    info "最新正式版：$ET_VERSION"
  fi
}

machine_id() {
  if [ -n "$ET_MACHINE_ID" ]; then echo "$ET_MACHINE_ID"; return; fi
  local mid=""
  [ -r /etc/machine-id ] && mid="$(cat /etc/machine-id)"
  [ -z "$mid" ] && mid="$(hostname)"
  echo "et-$(echo "$mid" | sha256sum | cut -c1-16)"
}

# ------------------------------- 下载与校验 ---------------------------------
# 依次尝试：ET_GH_PROXY 指定前缀 -> 内置加速前缀列表 -> GitHub 直连
# 每个地址下完立刻用官方 SHA256SUMS 校验，校验不过自动换下一个源。
download_release() { # download_release <version> <outdir>
  local ver="$1" outdir="$2" arch asset sums
  arch="$(detect_arch)"
  asset="easytier-linux-${arch}-v${ver}.zip"
  sums="SHA256SUMS"
  mkdir -p "$outdir"
  local bases=() b
  [ -n "$ET_GH_PROXY" ] && bases+=("$ET_GH_PROXY")
  for b in $ET_GH_PROXY_FALLBACKS; do bases+=("$b"); done
  bases+=("")
  local base url
  for base in "${bases[@]}"; do
    url="${base}${GITHUB_REPO}/releases/download/v${ver}/${asset}"
    info "尝试下载：$url"
    if curl -fL --retry 2 --connect-timeout 15 --max-time "$ET_DOWNLOAD_TIMEOUT" -o "$outdir/$asset" "$url" \
       && curl -fsSL --max-time 60 -o "$outdir/$sums" "${base}${GITHUB_REPO}/releases/download/v${ver}/${sums}"; then
      if (cd "$outdir" && grep -F " $asset" "$sums" | sha256sum -c - >/dev/null 2>&1); then
        ok "下载完成且 SHA256 校验通过（来源：${base:-GitHub 直连}）"
        return 0
      fi
      warn "SHA256 校验不通过，换下一个下载源"
    else
      warn "该源下载失败，换下一个"
    fi
    rm -f "$outdir/$asset" "$outdir/$sums"
  done
  die "所有下载源都失败。请检查网络，或用 ET_GH_PROXY 指定可用加速前缀后重试"
}

unpack_binaries() { # unpack_binaries <zipdir> <destdir>
  local zipdir="$1" dest="$2" arch
  arch="$(detect_arch)"
  rm -rf "$zipdir/pkg"; mkdir -p "$zipdir/pkg"
  unzip -q -o "$zipdir"/easytier-linux-*-v*.zip -d "$zipdir/pkg"
  local src="$zipdir/pkg/easytier-linux-${arch}"
  [ -d "$src" ] || src="$(find "$zipdir/pkg" -maxdepth 1 -type d -name 'easytier-linux-*' | head -1)"
  [ -n "$src" ] && [ -f "$src/easytier-core" ] || die "安装包结构异常，未找到 easytier-core"
  mkdir -p "$dest"
  install -o root -g root -m 755 "$src/easytier-core" "$src/easytier-cli" "$dest/"
  [ -f "$src/easytier-web-embed" ] && install -o root -g root -m 755 "$src/easytier-web-embed" "$dest/"
  [ -f "$src/easytier-web" ] && install -o root -g root -m 755 "$src/easytier-web" "$dest/"
  ok "二进制已安装到 $dest，版本：$("$dest/easytier-core" --version 2>/dev/null | head -1)"
}

# ------------------------------- systemd 单元 -------------------------------
write_units() {
  local reg_flag=""
  [ "$ET_DISABLE_REGISTRATION" = "1" ] && reg_flag="--disable-registration"
  cat > "$UNIT_WEB" <<EOF
[Unit]
Description=easytier-web-embed (EasyTier console + config server)
After=network.target

[Service]
Type=simple
ExecStart=$BIN_DIR/easytier-web-embed --db $DATA_DIR/web-embed.db --file-log-dir $LOG_DIR --file-log-level error $reg_flag --config-server-port $ET_CONFIG_PORT --config-server-protocol $ET_CONFIG_PROTO --api-server-port $ET_WEB_PORT --web-server-port $ET_WEB_PORT --web-server-addr 0.0.0.0 --api-server-addr 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  cat > "$UNIT_CORE" <<EOF
[Unit]
Description=easytier-core (managed by local config server)
After=network.target easytier-web-embed.service
Wants=easytier-web-embed.service

[Service]
Type=simple
User=root
ExecStart=$BIN_DIR/easytier-core --config-server ${ET_CONFIG_PROTO}://127.0.0.1:${ET_CONFIG_PORT}/${ET_ADMIN_USER} --relay-network-whitelist "*" --machine-id $(machine_id) --hostname $ET_SERVER_NAME
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "systemd 单元已写入（web: $UNIT_WEB / core: $UNIT_CORE）"
}

open_local_firewall() {
  [ "$ET_OPEN_FIREWALL" = "1" ] || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$ET_WEB_PORT/tcp" >/dev/null 2>&1 || true
    ufw allow "$ET_CONFIG_PORT/$ET_CONFIG_PROTO" >/dev/null 2>&1 || true
    ufw allow 11010/tcp >/dev/null 2>&1 || true
    ufw allow 11010/udp >/dev/null 2>&1 || true
    ufw allow 11011:11013/tcp >/dev/null 2>&1 || true
    ufw allow 11011:11013/udp >/dev/null 2>&1 || true
    info "ufw 已放行相关端口"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$ET_WEB_PORT/tcp" --add-port="$ET_CONFIG_PORT/$ET_CONFIG_PROTO" \
      --add-port=11010/tcp --add-port=11010/udp --add-port=11011-11013/tcp --add-port=11011-11013/udp >/dev/null || true
    firewall-cmd --reload >/dev/null || true
    info "firewalld 已放行相关端口"
  fi
}

start_all() {
  systemctl enable easytier-web-embed easytier-core >/dev/null 2>&1 || true
  systemctl start easytier-web-embed
  sleep 3
  systemctl start easytier-core
  sleep 3
  ok "服务已启动并设为开机自启（先 Web 后核心，核心要连本机配置服务器）"
}
stop_all() { systemctl stop easytier-core easytier-web-embed 2>/dev/null || true; }

# ------------------------------- 备份与回滚 ---------------------------------
make_backup() { # make_backup -> 输出备份目录
  local ts bk
  ts="$(date +%Y%m%d-%H%M%S)"
  bk="$ET_BACKUP_DIR/easytier-backup-$ts"
  mkdir -p "$bk"
  [ -d "$ET_INSTALL_DIR" ] && cp -a "$ET_INSTALL_DIR" "$bk/install-dir"
  [ -f "$UNIT_WEB" ] && cp -a "$UNIT_WEB" "$bk/"
  [ -f "$UNIT_CORE" ] && cp -a "$UNIT_CORE" "$bk/"
  if [ -f "$BIN_DIR/easytier-core" ]; then
    "$BIN_DIR/easytier-core" --version > "$bk/version-before.txt" 2>&1 || true
    (cd "$BIN_DIR" && sha256sum easytier-* > "$bk/binaries-before.sha256" 2>/dev/null) || true
  fi
  # 数据库用 sqlite 在线备份（一致性快照）；没有 sqlite3 时退化为停服拷贝由调用方处理
  if [ -f "$DATA_DIR/web-embed.db" ] && command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DATA_DIR/web-embed.db" ".backup '$bk/web-embed-snapshot.db'" || true
  fi
  echo "$bk"
}

restore_backup() { # restore_backup <dir>
  local bk="$1"
  [ -d "$bk/install-dir" ] || die "备份目录不完整：$bk"
  stop_all
  rm -rf "$ET_INSTALL_DIR"
  cp -a "$bk/install-dir" "$ET_INSTALL_DIR"
  [ -f "$bk/easytier-web-embed.service" ] && cp -a "$bk/easytier-web-embed.service" "$UNIT_WEB"
  [ -f "$bk/easytier-core.service" ] && cp -a "$bk/easytier-core.service" "$UNIT_CORE"
  systemctl daemon-reload
  start_all
}

# ------------------------------- 健康检查 -----------------------------------
health_check() { # 返回 0 表示核心链路可用
  local fail=0
  systemctl is-active --quiet easytier-web-embed && ok "easytier-web-embed 运行中" || { err "easytier-web-embed 未运行"; fail=1; }
  systemctl is-active --quiet easytier-core && ok "easytier-core 运行中" || { err "easytier-core 未运行"; fail=1; }
  systemctl is-enabled --quiet easytier-web-embed 2>/dev/null && systemctl is-enabled --quiet easytier-core 2>/dev/null \
    && ok "两个服务均已开机自启" || warn "存在未设开机自启的服务（重启机器后不会自动恢复，务必 enable）"
  if [ -f "$BIN_DIR/easytier-core" ]; then info "核心版本：$("$BIN_DIR/easytier-core" --version 2>/dev/null | head -1)"; fi
  ss -tln 2>/dev/null | grep -q ":$ET_WEB_PORT " && ok "控制台端口 $ET_WEB_PORT (TCP) 监听中" || { err "控制台端口 $ET_WEB_PORT 未监听"; fail=1; }
  if ss -uln 2>/dev/null | grep -q ":$ET_CONFIG_PORT " || ss -tln 2>/dev/null | grep -q ":$ET_CONFIG_PORT "; then
    ok "配置服务器端口 $ET_CONFIG_PORT ($ET_CONFIG_PROTO) 监听中"
  else
    err "配置服务器端口 $ET_CONFIG_PORT 未监听"; fail=1
  fi
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$ET_WEB_PORT/" || echo 000)"
  [ "$code" = "200" ] && ok "控制台页面本地访问 HTTP 200" || { err "控制台页面本地访问异常（HTTP $code）"; fail=1; }
  if [ -x "$BIN_DIR/easytier-cli" ]; then
    if "$BIN_DIR/easytier-cli" node >/dev/null 2>&1; then
      ok "核心已有运行中的网络实例"
      "$BIN_DIR/easytier-cli" node 2>/dev/null | grep -E "Virtual IP|Hostname" || true
      ss -tuln 2>/dev/null | grep -q ":11010 " && ok "对等监听 11010 已打开" || warn "有网络实例但 11010 未监听：多半是该实例没配监听地址，客户端将无法连入（到后台给该成员补监听）"
    else
      warn "核心当前没有运行任何网络实例（刚装好时正常，去控制台建网络并给本机运行即可）"
    fi
  fi
  # 常见坑：实例把自己的公网地址当 peer 无限重试（日志刷屏 + 新客户端照着错地址连）
  local n
  n="$(journalctl -u easytier-core --since "-10 min" --no-pager 2>/dev/null | grep -c "connect to peer error" || true)"
  if [ "${n:-0}" -gt 20 ] 2>/dev/null; then
    warn "核心日志在频繁重试连接 peer（10 分钟内 $n 条）：检查网络的初始节点是否误填了本机地址或未监听的端口"
  fi
  return $fail
}

print_next_steps() {
  local pub; pub="$(detect_public_ip)"
  cat <<EOF

==================== 部署完成，下一步 ====================
1. 打开控制台： http://$pub:$ET_WEB_PORT
   首次打开请按页面提示创建/登录管理员账号（ET_ADMIN_USER=$ET_ADMIN_USER，
   核心就是归属在这个账号下向配置服务器报到的）。
2. 云服务器安全组/防火墙务必放行（少一个都会出现"能组网但进不了后台"
   或"客户端连不上配置服务器"这类半通不通的问题）：
   - TCP  $ET_WEB_PORT   控制台（建议只对自己的 IP 放行）
   - ${ET_CONFIG_PROTO^^}  $ET_CONFIG_PORT   配置服务器（客户端向它报到）
   - TCP+UDP 11010       对等连接主端口
   - TCP+UDP 11011-11013 WireGuard/WS/WSS/QUIC/FakeTCP（可选，建议放行）
3. 建网络顺序（2.7 的中心网络模型，别走反）：
   先在控制台「网络」里新建网络 -> 再到「设备列表」给本机运行该网络；
   需要被外部连入的节点，记得在成员配置里补监听地址
   tcp://0.0.0.0:11010 与 udp://0.0.0.0:11010（监听为空 = 谁也连不进来）。
4. 客户端接入：托管模式填 ${ET_CONFIG_PROTO}://$pub:${ET_CONFIG_PORT}/${ET_ADMIN_USER}，
   或独立模式用网络名+密钥直连 tcp://$pub:11010。
=========================================================
EOF
}

# ------------------------------- 主命令 -------------------------------------
cmd_install() {
  preflight; resolve_version
  if [ -f "$BIN_DIR/easytier-core" ]; then
    warn "检测到已安装：$("$BIN_DIR/easytier-core" --version 2>/dev/null | head -1)"
    confirm "继续安装将覆盖二进制（配置和数据保留），改用 update 更稳妥。仍要继续？" || exit 0
  fi
  for p in "$ET_WEB_PORT" "$ET_CONFIG_PORT"; do
    port_busy "$p" && die "端口 $p 已被其他程序占用，请换端口（ET_WEB_PORT/ET_CONFIG_PORT）或先释放"
  done
  local tmp; tmp="$(mktemp -d)"
  download_release "$ET_VERSION" "$tmp"
  mkdir -p "$BIN_DIR" "$DATA_DIR" "$LOG_DIR" "$ET_BACKUP_DIR"
  unpack_binaries "$tmp" "$BIN_DIR"
  rm -rf "$tmp"
  write_units
  open_local_firewall
  start_all
  if health_check; then ok "安装成功"; else warn "安装完成但健康检查有异常，请按上面提示处理（或看 logs）"; fi
  print_next_steps
}

cmd_update() {
  preflight; resolve_version
  [ -f "$BIN_DIR/easytier-core" ] || die "未检测到已有安装，请先 install"
  local cur; cur="$("$BIN_DIR/easytier-core" --version 2>/dev/null | head -1)"
  info "当前版本：$cur -> 目标版本：$ET_VERSION"
  confirm "开始更新？（会先自动备份，失败自动回滚）" || exit 0
  local bk; bk="$(make_backup)"; ok "已备份到 $bk"
  local tmp; tmp="$(mktemp -d)"
  download_release "$ET_VERSION" "$tmp"
  stop_all
  unpack_binaries "$tmp" "$BIN_DIR"
  rm -rf "$tmp"
  systemctl daemon-reload
  start_all
  if health_check; then
    ok "更新成功：$cur -> $ET_VERSION（备份保留在 $bk）"
  else
    err "更新后健康检查未通过，自动回滚到备份 $bk"
    restore_backup "$bk"
    health_check || true
    die "已回滚到更新前状态，请查看日志排查（./easytier-server.sh logs）"
  fi
}

cmd_uninstall() {
  need_root
  local purge=0; [ "${1:-}" = "--purge" ] && purge=1
  confirm "确认卸载 EasyTier 服务端？（服务与二进制将被移除）" || exit 0
  stop_all
  systemctl disable easytier-web-embed easytier-core >/dev/null 2>&1 || true
  rm -f "$UNIT_WEB" "$UNIT_CORE"
  systemctl daemon-reload
  rm -rf "$BIN_DIR"
  if [ "$purge" = "1" ]; then
    confirm "将连同数据目录 $ET_INSTALL_DIR 和备份 $ET_BACKUP_DIR 一起删除，不可恢复。确定？" \
      && rm -rf "$ET_INSTALL_DIR" "$ET_BACKUP_DIR" && ok "已彻底卸载（含数据与备份）" \
      || { rm -rf "$ET_INSTALL_DIR/server"; ok "已卸载服务与二进制，数据与备份保留"; }
  else
    ok "已卸载服务与二进制；数据保留在 $DATA_DIR，备份保留在 $ET_BACKUP_DIR（如需彻底清理用 uninstall --purge）"
  fi
}

cmd_status() {
  systemctl status easytier-web-embed easytier-core --no-pager 2>/dev/null | head -30 || true
  echo "---"
  [ -f "$BIN_DIR/easytier-core" ] && info "版本：$("$BIN_DIR/easytier-core" --version 2>/dev/null | head -1)"
  ss -tuln 2>/dev/null | grep -E ":($ET_WEB_PORT|$ET_CONFIG_PORT|11010|11011|11012|11013|15888) " || warn "未发现 EasyTier 相关监听端口"
}

cmd_backup()  { preflight; local bk; bk="$(make_backup)"; ok "备份完成：$bk"; }
cmd_rollback() {
  preflight
  local bk="${1:-}"
  if [ -z "$bk" ]; then bk="$(ls -d "$ET_BACKUP_DIR"/easytier-backup-* 2>/dev/null | sort | tail -1 || true)"; fi
  [ -n "$bk" ] && [ -d "$bk" ] || die "找不到可用备份（$ET_BACKUP_DIR 下为空）"
  confirm "用备份 $bk 回滚？当前状态将被覆盖" || exit 0
  restore_backup "$bk"; health_check && ok "回滚完成：$bk"
}
cmd_logs() { journalctl -u easytier-web-embed -u easytier-core -n "${1:-100}" --no-pager 2>/dev/null || journalctl -u easytier-core -f; }

menu() {
  echo "EasyTier 服务端管理"
  echo " 1) 安装        2) 更新        3) 健康检查    4) 状态"
  echo " 5) 启动        6) 停止        7) 重启        8) 备份"
  echo " 9) 回滚       10) 日志       11) 卸载        0) 退出"
  local c; read -r -p "请选择: " c || true
  case "$c" in
    1) cmd_install ;; 2) cmd_update ;; 3) preflight; health_check ;; 4) cmd_status ;;
    5) need_root; start_all ;; 6) need_root; stop_all; ok "已停止" ;;
    7) need_root; stop_all; start_all ;; 8) cmd_backup ;; 9) cmd_rollback ;;
    10) cmd_logs 100 ;; 11) cmd_uninstall ;; 0) exit 0 ;; *) echo "无效选择" ;;
  esac
}

usage() {
  cat <<EOF
用法: $0 <命令> [参数]
  install            一键安装（下载校验、写服务、设自启、健康检查）
  update             更新到 ET_VERSION（自动备份，失败自动回滚）
  uninstall [--purge] 卸载（--purge 连数据与备份一起删）
  start|stop|restart 启停/重启两个服务
  status             服务状态与监听端口
  check              健康检查（版本/服务/端口/页面/常见坑预警）
  backup             立即备份一份到 $ET_BACKUP_DIR
  rollback [目录]    回滚到指定备份（默认最近一份）
  logs [行数]        查看两个服务的日志
  menu               交互菜单（无参数时默认）

常用环境变量:
  ET_VERSION=2.7.1            目标版本（或 latest）
  ET_GH_PROXY=https://ghfast.top/   GitHub 加速前缀（自动多源轮换+直连兜底）
  ET_WEB_PORT=26010  ET_CONFIG_PORT=26020  ET_CONFIG_PROTO=udp
  ET_PUBLIC_IP=1.2.3.4        完成提示里显示的公网 IP（默认自动探测）
  ET_OPEN_FIREWALL=1          同时放行本机 ufw/firewalld
  ET_YES=1                    跳过所有交互确认
EOF
}

main() {
  case "${1:-menu}" in
    install) cmd_install ;;
    update) cmd_update ;;
    uninstall) shift; cmd_uninstall "${1:-}" ;;
    start) need_root; start_all ;;
    stop) need_root; stop_all; ok "已停止" ;;
    restart) need_root; stop_all; start_all ;;
    status) cmd_status ;;
    check) preflight; health_check && ok "健康检查全部通过" ;;
    backup) cmd_backup ;;
    rollback) shift; cmd_rollback "${1:-}" ;;
    logs) shift; cmd_logs "${1:-100}" ;;
    menu) menu ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}
main "$@"
