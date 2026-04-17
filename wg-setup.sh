#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# TogetherToTheSpire — 杀戮尖塔广域网联机一键部署
# ============================================================

WG_CONF="/etc/wireguard/wg0.conf"
WG_INTERFACE="wg0"
WG_DIR="/etc/wireguard"
SYSCTL_FILE="/etc/sysctl.d/99-wireguard.conf"
WG_ADDRESS="10.66.66.1/24"
WG_PORT=""
CLIENT_DIR="${HOME}/wg-clients"

# ── 工具函数 ──────────────────────────────────────────────

info()  { echo -e "\033[1;34m[信息]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[完成]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[注意]\033[0m $*"; }
error() { echo -e "\033[1;31m[错误]\033[0m $*" >&2; }

RESET="\033[0m"
GOLD="\033[1;33m"
CYAN="\033[1;36m"
PURPLE="\033[1;35m"
ORANGE="\033[38;5;208m"
GRAY="\033[1;90m"
WHITE="\033[1;37m"

paint() {
  local color="$1"
  shift
  echo -e "${color}$*${RESET}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    error "缺少命令: $1"
    exit 1
  }
}

check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "请用 sudo 运行脚本"
    exit 1
  fi
}

# ── 系统检测 ──────────────────────────────────────────────

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID}"
    OS_NAME="${PRETTY_NAME:-${ID}}"
    OS_VERSION="${VERSION_ID:-}"
  else
    OS_ID=""
    OS_NAME="未知"
    OS_VERSION=""
  fi

  case "${OS_ID}" in
    ubuntu|debian|linuxmint|pop)
      PKG_MANAGER="apt"
      ;;
    centos|rhel|rocky|almalinux|fedora)
      PKG_MANAGER="dnf"
      ;;
    *)
      error "不支持的系统: ${OS_NAME}"
      echo "目前支持: Ubuntu/Debian/Rocky/AlmaLinux" >&2
      exit 1
      ;;
  esac

  if [[ "${OS_ID}" == "centos" && "${OS_VERSION%%.*}" == "8" ]]; then
    error "当前版本暂不支持 CentOS 8"
    echo "原因：CentOS 8 的 WireGuard 内核模块适配不稳定，后续会单独补 CentOS 8 支持。" >&2
    echo "建议改用 Ubuntu/Debian/Rocky/AlmaLinux 后再运行脚本。" >&2
    exit 1
  fi
}

# ── 安装 ──────────────────────────────────────────────────

install_packages() {
  case "${PKG_MANAGER}" in
    apt)
      apt update -qq
      apt install -y -qq wireguard qrencode curl iptables
      ;;
    dnf)
      configure_epel_repo
      if ! command -v dnf >/dev/null 2>&1 && command -v yum >/dev/null 2>&1; then
        yum makecache -y --refresh
        yum install -y wireguard-tools qrencode curl iptables
      else
        dnf makecache -y --refresh
        dnf install -y wireguard-tools qrencode curl iptables
      fi
      ;;
  esac
}

configure_el8_mirrors() {
  local repo_dir="/etc/yum.repos.d"
  local backup_dir="${repo_dir}/backup-$(date +%Y%m%d%H%M%S)"
  local repo_file="${repo_dir}/CentOS-aliyun.repo"

  mkdir -p "${backup_dir}"

  shopt -s nullglob
  for f in "${repo_dir}"/CentOS-*.repo; do
    mv "${f}" "${backup_dir}/"
  done
  shopt -u nullglob

  cat > "${repo_file}" <<'EOF'
[BaseOS]
name=CentOS Linux 8 - BaseOS
baseurl=https://mirrors.aliyun.com/centos/8/BaseOS/$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
skip_if_unavailable=1

[AppStream]
name=CentOS Linux 8 - AppStream
baseurl=https://mirrors.aliyun.com/centos/8/AppStream/$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
skip_if_unavailable=1

[extras]
name=CentOS Linux 8 - Extras
baseurl=https://mirrors.aliyun.com/centos/8/extras/$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
skip_if_unavailable=1

[PowerTools]
name=CentOS Linux 8 - PowerTools
baseurl=https://mirrors.aliyun.com/centos/8/PowerTools/$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
skip_if_unavailable=1
EOF
}

configure_epel_repo() {
  local repo_file="/etc/yum.repos.d/epel.repo"

  require_cmd rpm
  rpm --import https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-8 >/dev/null 2>&1 || true

  rm -f /etc/yum.repos.d/epel*.repo

  cat > "${repo_file}" <<'EOF'
[epel]
name=Extra Packages for Enterprise Linux $releasever - $basearch
baseurl=https://mirrors.aliyun.com/epel/$releasever/Everything/$basearch/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-8
skip_if_unavailable=1

[epel-modular]
name=Extra Packages for Enterprise Linux Modular $releasever - $basearch
baseurl=https://mirrors.aliyun.com/epel/$releasever/Modular/$basearch/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-8
skip_if_unavailable=1
EOF
}

# ── 网络配置 ──────────────────────────────────────────────

detect_default_nic() {
  ip route | awk '/default/ {print $5; exit}'
}

port_is_available() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ! ss -lntu 2>/dev/null | awk -v target=":${port}" '$5 ~ target { found=1 } END { exit(found ? 0 : 1) }'
  else
    return 0
  fi
}

prompt_listen_port() {
  local port_input port_value

  echo >/dev/tty
  paint "${GOLD}" "  请手动输入 WireGuard 监听端口" >/dev/tty
  paint "${CYAN}" "  端口范围: 1024-65535" >/dev/tty
  paint "${ORANGE}" "  不能直接回车，必须输入一个端口号" >/dev/tty
  paint "${WHITE}" "  示例: 51820、51821、60000" >/dev/tty
  echo >/dev/tty
  echo "  提示：请先确认你要使用的端口没有被占用，然后再输入下面这一行。" >/dev/tty
  echo >/dev/tty

  while true; do
    read -r -p "  请输入端口号（1024-65535）> " port_input </dev/tty
    echo >/dev/tty

    if [[ -z "${port_input}" ]]; then
      warn "端口不能为空" >/dev/tty
      continue
    fi

    if [[ ! "${port_input}" =~ ^[0-9]+$ ]]; then
      warn "请输入数字端口" >/dev/tty
      continue
    fi

    if (( port_input < 1024 || port_input > 65535 )); then
      warn "端口必须在 1024-65535 之间" >/dev/tty
      continue
    fi

    if ! port_is_available "${port_input}"; then
      warn "端口 ${port_input} 当前已被占用，请换一个" >/dev/tty
      continue
    fi

    port_value="${port_input}"
    break
  done

  echo "${port_value}"
}

check_wireguard_kernel_support() {
  require_cmd modprobe

  if modprobe wireguard >/dev/null 2>&1; then
    return 0
  fi

  error "当前内核不支持 WireGuard 模块，wg-quick 无法启动"
  echo "请先处理下面任一项，然后重新运行 setup：" >&2
  echo "  1. 安装支持 WireGuard 的内核模块（例如 kmod-wireguard / elrepo）" >&2
  echo "  2. 升级到带 WireGuard 支持的内核" >&2
  echo "  3. 更换到支持 WireGuard 的系统（如较新的 Ubuntu / Debian / Rocky / AlmaLinux）" >&2
  return 1
}

get_public_ip() {
  local ip=""
  ip="$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -4 -s --max-time 5 ip.sb 2>/dev/null || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(curl -4 -s --max-time 5 api.ipify.org 2>/dev/null || true)"
  fi
  echo "${ip}"
}

enable_ip_forward() {
  echo 'net.ipv4.ip_forward=1' > "${SYSCTL_FILE}"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl --system >/dev/null 2>&1
}

# ── WireGuard 服务端 ──────────────────────────────────────

generate_server_keys() {
  mkdir -p "${WG_DIR}"
  chmod 700 "${WG_DIR}"
  wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
  chmod 600 "${WG_DIR}/server_private.key"
  chmod 644 "${WG_DIR}/server_public.key"
}

create_wg_conf() {
  local wg_address="$1"
  local wg_port="$2"
  local nic="$3"
  local private_key
  private_key="$(cat "${WG_DIR}/server_private.key")"

  cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${wg_address}
ListenPort = ${wg_port}
PrivateKey = ${private_key}
PostUp = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -A FORWARD -o ${WG_INTERFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -D FORWARD -o ${WG_INTERFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE
EOF

  chmod 600 "${WG_CONF}"
}

start_wg() {
  systemctl enable "wg-quick@${WG_INTERFACE}" >/dev/null 2>&1
  systemctl restart "wg-quick@${WG_INTERFACE}"
}

restart_wg() {
  systemctl restart "wg-quick@${WG_INTERFACE}"
}

# ── 防火墙 ────────────────────────────────────────────────

handle_firewall() {
  local port="$1"

  # ufw
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
    ufw allow "${port}/udp" >/dev/null 2>&1
    ok "已通过 ufw 放行 UDP ${port}"
    return
  fi

  # firewalld
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ok "已通过 firewalld 放行 UDP ${port}"
    return
  fi

  warn "未检测到 ufw 或 firewalld，请手动确认防火墙已放行 UDP ${port}"
}

# ── 配置读取 ──────────────────────────────────────────────

get_interface_value() {
  local key="$1"
  awk -v wanted="$key" '
    /^\[Interface\]/ { in_if=1; next }
    /^\[/ && $0 !~ /^\[Interface\]/ { in_if=0 }
    in_if && $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
      line=$0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/[[:space:]]*$/, "", line)
      print line
      exit
    }
  ' "${WG_CONF}"
}

get_server_public_key() {
  local key
  key="$(wg show "${WG_INTERFACE}" public-key 2>/dev/null || true)"
  if [[ -n "${key}" ]]; then
    echo "${key}"
    return
  fi
  local private_key
  private_key="$(get_interface_value "PrivateKey" | tr -d '\r' | xargs)"
  echo "${private_key}" | wg pubkey
}

# ── Peer 管理 ─────────────────────────────────────────────

get_used_ip_octets() {
  local prefix="$1"
  grep -oE "AllowedIPs = ${prefix//./\\.}\.[0-9]+/32" "${WG_CONF}" 2>/dev/null \
    | sed -E "s#AllowedIPs = ${prefix//./\\.}\.([0-9]+)/32#\1#" \
    | sort -n | uniq
}

find_next_ip_octet() {
  local prefix="$1"
  local used
  used="$(get_used_ip_octets "${prefix}")"
  for i in $(seq 2 254); do
    if ! echo "${used}" | grep -qx "${i}"; then
      echo "${i}"
      return
    fi
  done
  error "没有可分配的 IP 地址了"
  exit 1
}

peer_name_exists() {
  local name="$1"
  grep -Fqx "# peer: ${name}" "${WG_CONF}" 2>/dev/null
}

get_peer_records() {
  awk '
    /^# peer: / {
      if (seen_name && seen_key && seen_ip) {
        print seen_name "|" seen_key "|" seen_ip
      }
      seen_name = substr($0, 9)
      seen_key = ""
      seen_ip = ""
      in_peer = 0
      next
    }
    /^\[Peer\]/ {
      in_peer = 1
      next
    }
    in_peer && /^PublicKey = / {
      seen_key = substr($0, 13)
      next
    }
    in_peer && /^AllowedIPs = / {
      seen_ip = substr($0, 14)
      sub(/\/32$/, "", seen_ip)
      next
    }
    /^\[/ {
      in_peer = 0
    }
    END {
      if (seen_name && seen_key && seen_ip) {
        print seen_name "|" seen_key "|" seen_ip
      }
    }
  ' "${WG_CONF}"
}

get_wg_network_info() {
  local addr ip cidr prefix
  addr="$(get_interface_value "Address")"

  if [[ -z "${addr}" ]]; then
    error "无法从 ${WG_CONF} 读取 [Interface] Address"
    exit 1
  fi

  ip="${addr%/*}"
  cidr="${addr#*/}"

  if [[ "${ip}" != *.*.*.* ]]; then
    error "当前脚本只支持 IPv4 Address，读到的是: ${addr}"
    exit 1
  fi

  prefix="$(echo "${ip}" | awk -F. '{print $1"."$2"."$3}')"
  echo "${ip}|${cidr}|${prefix}"
}

get_listen_port() {
  local port
  port="$(get_interface_value "ListenPort")"
  if [[ -z "${port}" ]]; then
    error "无法从 ${WG_CONF} 读取 [Interface] ListenPort"
    exit 1
  fi
  echo "${port}"
}

show_qr_terminal() {
  local conf_file="$1"
  echo >/dev/tty
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  请使用 WireGuard 扫描下方二维码导入配置："
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  qrencode -t ANSIUTF8 < "${conf_file}" || true
  echo
}

wait_for_handshake() {
  local peer_pubkey="$1"
  local listen_port="$2"
  local timeout="${3:-120}"
  local interval="${4:-2}"
  local elapsed=0

  echo
  info "正在等待客户端连接，超时时间 ${timeout} 秒..."

  while (( elapsed < timeout )); do
    if wg show "${WG_INTERFACE}" latest-handshakes | awk -v key="${peer_pubkey}" '
      $1==key && $2 > 0 { found=1 }
      END { exit(found ? 0 : 1) }
    '; then
      echo
      ok "检测到客户端已连接"
      wg show "${WG_INTERFACE}" | awk -v key="${peer_pubkey}" '
        $1=="peer:" && $2==key { print; in_peer=1; next }
        $1=="peer:" && $2!=key { in_peer=0 }
        in_peer { print }
      '
      return 0
    fi

    sleep "${interval}"
    elapsed=$((elapsed + interval))
    printf "\r等待中... %ds/%ds" "${elapsed}" "${timeout}"
  done

  echo
  warn "等待超时，尚未检测到客户端握手"
  echo "  请确认："
  echo "  1. 客户端是否已扫码导入配置"
  echo "  2. 客户端是否已打开 WireGuard 隧道"
  echo "  3. 云安全组是否放行 UDP ${listen_port}"
  return 1
}

add_peer() {
  local peer_name="$1"
  local client_ip="$2"

  cp "${WG_CONF}" "${WG_CONF}.bak.$(date +%Y%m%d%H%M%S)"

  local private_key public_key
  private_key="$(wg genkey)"
  public_key="$(echo "${private_key}" | wg pubkey)"

  cat >> "${WG_CONF}" <<EOF

# peer: ${peer_name}
[Peer]
PublicKey = ${public_key}
AllowedIPs = ${client_ip}/32
EOF

  # 生成客户端配置
  mkdir -p "${CLIENT_DIR}"
  chmod 700 "${CLIENT_DIR}"

  local addr cidr prefix
  addr="$(get_interface_value "Address")"
  cidr="${addr#*/}"
  prefix="$(echo "${addr}" | awk -F. '{print $1"."$2"."$3}')"

  local server_pubkey port public_ip endpoint
  server_pubkey="$(get_server_public_key)"
  port="$(get_interface_value "ListenPort")"
  public_ip="$(get_public_ip)"
  endpoint="${public_ip}:${port}"

  local conf_file="${CLIENT_DIR}/${peer_name}.conf"
  cat > "${conf_file}" <<EOF
[Interface]
PrivateKey = ${private_key}
Address = ${client_ip}/${cidr}
DNS = 1.1.1.1

[Peer]
PublicKey = ${server_pubkey}
Endpoint = ${endpoint}
AllowedIPs = ${prefix}.0/24
PersistentKeepalive = 25
EOF
  chmod 600 "${conf_file}"

  # 返回客户端公钥（用于握手检测）
  echo "${public_key}"
}

# ── 二维码展示 ─────────────────────────────────────────────

show_peer_qr() {
  local peer_name="$1"
  local client_ip="$2"
  local conf_file="${CLIENT_DIR}/${peer_name}.conf"

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ${peer_name}  |  ${client_ip}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  echo "  请 ${peer_name} 用 WireGuard 扫描下方二维码："
  echo
  qrencode -t ANSIUTF8 < "${conf_file}" || true
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── 握手检测 ──────────────────────────────────────────────

check_handshakes() {
  local listen_port="$1"
  shift
  local -a peer_pubkeys=("$@")
  local found=0
  local total=${#peer_pubkeys[@]}

  echo
  info "正在检测所有玩家的连接状态..."

  for i in "${!peer_pubkeys[@]}"; do
    local key="${peer_pubkeys[$i]}"
    if wg show "${WG_INTERFACE}" latest-handshakes | awk -v k="${key}" '
      $1==k && $2 > 0 { found=1 }
      END { exit(found ? 0 : 1) }
    '; then
      ok "玩家 $((i+1)) 已连接"
      found=$((found+1))
    else
      warn "玩家 $((i+1)) 未连接"
    fi
  done

  echo
  if [[ "${found}" -eq "${total}" ]]; then
    ok "全部 ${total} 位玩家已连接，可以开始联机了！"
  else
    warn "${found}/${total} 位玩家已连接"
    echo >/dev/tty
    echo "  未连接的玩家请检查："
    echo "  1. 是否已扫码导入 WireGuard 并打开隧道"
    echo "  2. 云服务器安全组是否放行 UDP ${listen_port}"
    echo "  3. 手机/电脑网络是否正常"
  fi
}

wait_for_all_handshakes() {
  local listen_port="$1"
  local timeout="${2:-90}"
  shift 2
  local -a peer_pubkeys=("$@")
  local total="${#peer_pubkeys[@]}"
  local interval=2
  local elapsed=0

  echo
  info "正在等待所有玩家连接 WireGuard..."
  echo "  （最长等待 ${timeout} 秒，期间会持续检测）"

  while (( elapsed < timeout )); do
    local connected=0
    local key
    for key in "${peer_pubkeys[@]}"; do
      if wg show "${WG_INTERFACE}" latest-handshakes | awk -v k="${key}" '
        $1==k && $2 > 0 { found=1 }
        END { exit(found ? 0 : 1) }
      '; then
        connected=$((connected + 1))
      fi
    done

    if [[ "${connected}" -eq "${total}" ]]; then
      echo
      ok "全部 ${total} 位玩家已连接"
      return 0
    fi

    printf "\r  当前连接: %d/%d，剩余 %ds" "${connected}" "${total}" "$((timeout - elapsed))"
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  echo
  warn "等待超时，尚未检测到全部玩家连接"
  echo "  请确认："
  echo "  1. 玩家是否已扫码导入并打开 WireGuard"
  echo "  2. 云服务器安全组是否放行 UDP ${listen_port}"
  echo "  3. 客户端网络是否正常"
  return 1
}

# ── 联机说明 ──────────────────────────────────────────────

generate_guide() {
  local public_ip="$1"
  local port="$2"
  local prefix="$3"
  local guide="${CLIENT_DIR}/联机说明.txt"

  cat > "${guide}" <<EOF
╔══════════════════════════════════════════════╗
║     TogetherToTheSpire 联机说明              ║
╚══════════════════════════════════════════════╝

服务端信息：
  公网地址: ${public_ip}:${port}
  VPN 网段: ${prefix}.0/24

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

一、WireGuard 客户端下载

  Windows:  https://www.wireguard.com/postinstall/
  macOS:    在 App Store 搜索 WireGuard
  Android:  在 Play 商店或应用市场搜索 WireGuard
  iOS:      在 App Store 搜索 WireGuard

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

二、导入配置

  1. 打开 WireGuard 客户端
  2. 点击 + 号，选择"扫描二维码"或"从文件导入"
  3. 扫描终端上的二维码，或使用 ${CLIENT_DIR}/ 下的 .conf 文件
  4. 导入后点击连接开关

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

三、开始联机（杀戮尖塔）

  1. 确认所有人的 WireGuard 都已连接
  2. 一个人打开杀戮尖塔，选择"联机" → "局域网游戏" → "创建房间"
  3. 其他人打开杀戮尖塔，选择"联机" → "局域网游戏" → "输入房主 IP" → 加入

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

如果进入不了房间，请确认：
  - 所有人的 WireGuard 隧道已打开（状态为活跃）
  - 尝试在杀戮尖塔中手动输入房主的 VPN IP 地址加入

EOF

  echo "${guide}"
}

# ── 部署完成提示 ──────────────────────────────────────────

show_summary() {
  local public_ip="$1"
  local port="$2"
  local addr
  addr="$(get_interface_value "Address")"
  local prefix
  prefix="$(echo "${addr}" | awk -F. '{print $1"."$2"."$3}')"

  echo
  echo "╔══════════════════════════════════════════════╗"
  echo "║          部署完成                            ║"
  echo "╚══════════════════════════════════════════════╝"
  echo
  echo "  服务端信息："
  echo "    公网地址: ${public_ip}:${port}"
  echo "    VPN 网段: ${prefix}.0/24"
  echo "    配置文件: ${WG_CONF}"
  echo
  warn "  ⚠ 请确认云服务器安全组已放行以下端口："
  echo
  echo "    UDP ${port}（WireGuard 通信端口，必须放行）"
  echo
  echo "  各云厂商操作路径："
  echo "    阿里云: 控制台 → 安全组 → 添加入方向规则 → UDP ${port}"
  echo "    腾讯云: 控制台 → 安全组 → 入站规则 → 添加 UDP ${port}"
  echo "    华为云: 安全组 → 入方向规则 → 添加 UDP ${port}"
  echo "    AWS:    Security Groups → Inbound Rules → UDP ${port}"
  echo
}

# ── 控制器 ────────────────────────────────────────────────

setup_flow() {
  check_root
  require_cmd ip
  require_cmd awk

  echo
  echo "╔══════════════════════════════════════════════╗"
  echo "║   TogetherToTheSpire — 一键部署 WireGuard    ║"
  echo "╚══════════════════════════════════════════════╝"
  echo

  if [[ -f "${WG_CONF}" ]]; then
    warn "检测到已有 WireGuard 配置: ${WG_CONF}"
    echo
    echo "  如果要重新部署，请先执行："
    echo "    sudo wg-quick down ${WG_INTERFACE}"
    echo "    sudo rm -rf ${WG_DIR}"
    echo
    read -r -p "  是否覆盖现有配置？(y/N) " confirm </dev/tty
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
      info "已退出，现有配置未改动"
      exit 0
    fi
    systemctl stop "wg-quick@${WG_INTERFACE}" 2>/dev/null || true
    cp "${WG_CONF}" "${WG_CONF}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  fi

  info "检测系统..."
  detect_os
  ok "${OS_NAME} (${PKG_MANAGER})"

  local nic
  nic="$(detect_default_nic)"
  if [[ -z "${nic}" ]]; then
    error "无法自动检测默认网卡，请手动执行 ip route 查看"
    exit 1
  fi
  ok "默认网卡: ${nic}"

  info "安装 WireGuard..."
  install_packages
  ok "WireGuard 安装完成"

  info "检查内核对 WireGuard 的支持..."
  if ! check_wireguard_kernel_support; then
    warn "部署流程已中止，等待你修复内核模块后重试"
    return 0
  fi
  ok "WireGuard 内核模块可用"

  info "开启 IP 转发..."
  enable_ip_forward
  ok "IP 转发已开启"

  info "选择 WireGuard 监听端口..."
  WG_PORT="$(prompt_listen_port)"
  ok "监听端口: ${WG_PORT}"

  info "生成服务端密钥..."
  generate_server_keys
  ok "密钥已生成"

  info "写入 WireGuard 配置..."
  create_wg_conf "${WG_ADDRESS}" "${WG_PORT}" "${nic}"

  info "启动 WireGuard..."
  if ! start_wg; then
    error "WireGuard 启动失败，请先查看系统日志"
    echo "  systemctl status wg-quick@${WG_INTERFACE} -l --no-pager" >&2
    echo "  journalctl -u wg-quick@${WG_INTERFACE} -xe --no-pager" >&2
    warn "部署流程已中止，等待你修复问题后重试"
    return 0
  fi
  ok "WireGuard 已启动并设置开机自启"

  info "检查防火墙..."
  handle_firewall "${WG_PORT}"

  local public_ip
  public_ip="$(get_public_ip || true)"
  if [[ -z "${public_ip}" ]]; then
    warn "无法自动获取公网 IP，请手动确认"
  fi

  show_summary "${public_ip}" "${WG_PORT}"

  echo "  几位朋友要一起联机？（输入 1-5 的数字）"
  local peer_count
  while true; do
    read -r -p "  > " peer_count </dev/tty
    if [[ "${peer_count}" =~ ^[1-5]$ ]]; then
      break
    fi
    warn "请输入 1 到 5 之间的数字"
  done

  echo
  ok "好的，为 ${peer_count} 位玩家生成配置"
  echo

  local -a default_names=("战士" "猎宝" "亡灵" "机器人" "储君" "观者大人")
  local -a peer_names=()
  local -a peer_pubkeys=()
  local -a peer_ips=()
  local addr cidr prefix next_octet
  addr="$(get_interface_value "Address")"
  cidr="${addr#*/}"
  prefix="$(echo "${addr}" | awk -F. '{print $1"."$2"."$3}')"

  for (( i = 0; i < peer_count; i++ )); do
    local idx=$((i + 1))
    local default_name="${default_names[$i]:-player${idx}}"
    echo "  给玩家 ${idx} 取个名字（回车默认: ${default_name}）"
    local name
    read -r -p "  > " name </dev/tty
    name="${name:-${default_name}}"

    while peer_name_exists "${name}"; do
      warn "名字「${name}」已存在，请换一个"
      read -r -p "  > " name </dev/tty
      name="${name:-${default_name}}$((i+2))"
    done

    peer_names+=("${name}")
    next_octet="$(find_next_ip_octet "${prefix}")"
    local client_ip="${prefix}.${next_octet}"

    info "生成 ${name} 的配置..."
    local pubkey
    pubkey="$(add_peer "${name}" "${client_ip}")"
    peer_pubkeys+=("${pubkey}")
    peer_ips+=("${client_ip}")
    ok "${name} (${client_ip}) → ${CLIENT_DIR}/${name}.conf"
  done

  info "重启 WireGuard 使配置生效..."
  if ! restart_wg; then
    error "WireGuard 重启失败，请先查看系统日志"
    echo "  systemctl status wg-quick@${WG_INTERFACE} -l --no-pager" >&2
    echo "  journalctl -u wg-quick@${WG_INTERFACE} -xe --no-pager" >&2
    return 1
  fi
  ok "WireGuard 已重启"

  echo
  info "接下来请朋友们依次扫描二维码（每次一人）"
  for (( i = 0; i < peer_count; i++ )); do
    local name="${peer_names[$i]}"
    local peer_ip="${peer_ips[$i]}"

    show_peer_qr "${name}" "${peer_ip}"

    if (( i < peer_count - 1 )); then
      echo
      read -r -p "  ${name} 扫码完成后按回车继续... " _ </dev/tty
    fi
  done

  if ! wait_for_all_handshakes "${WG_PORT}" 90 "${peer_pubkeys[@]}"; then
    warn "本次未等到全部玩家上线，可以稍后用 status 再查看"
  fi

  check_handshakes "${WG_PORT}" "${peer_pubkeys[@]}"

  info "生成联机说明..."
  local guide_path
  guide_path="$(generate_guide "${public_ip}" "${WG_PORT}" "${prefix}")"
  ok "联机说明已保存到 ${guide_path}"

  info "安装本地入口命令..."
  install_entrypoint

  echo
  echo "  玩家列表："
  for (( i = 0; i < peer_count; i++ )); do
    local name="${peer_names[$i]}"
    local peer_ip="${peer_ips[$i]}"
    echo "    ${name}    ${peer_ip}"
  done

  echo
  echo "  WireGuard 服务状态:"
  if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}" 2>/dev/null; then
    ok "wg-quick@${WG_INTERFACE} 运行中"
  else
    warn "wg-quick@${WG_INTERFACE} 未运行"
  fi

  local peer_total
  peer_total="$(grep -c "^\# peer:" "${WG_CONF}" 2>/dev/null || echo 0)"
  echo "  已配置 peer 数量: ${peer_total}"

  echo
  echo "╔══════════════════════════════════════════════╗"
  echo "║          全部完成！                          ║"
  echo "╚══════════════════════════════════════════════╝"
  echo
  echo "  所有配置文件在: ${CLIENT_DIR}/"
  echo "  联机说明在:     ${guide_path}"
  echo
  echo "  后续管理命令: sudo ./wg-setup.sh [setup|add-peer|remove-peer|status|remove-env]"
  echo "  或者直接使用: sudo together [add-peer|remove-peer|status|remove-env]"
  echo
}

ensure_wg_config() {
  if [[ ! -f "${WG_CONF}" ]]; then
    error "未找到 WireGuard 配置: ${WG_CONF}"
    echo "请先执行 setup 初始化环境。" >&2
    exit 1
  fi
}

remove_peer_from_server_config() {
  local peer_name="$1"
  local tmp
  tmp="$(mktemp)"

  awk -v target="# peer: ${peer_name}" '
    BEGIN { skip = 0; count = 0 }
    $0 == target {
      skip = 1
      count = 4
      next
    }
    skip {
      if (count > 0) {
        count--
        if (count == 0) {
          skip = 0
        }
        next
      }
    }
    { print }
  ' "${WG_CONF}" > "${tmp}"

  mv "${tmp}" "${WG_CONF}"
}

remove_peer_artifacts() {
  local peer_name="$1"
  rm -f "${CLIENT_DIR}/${peer_name}.conf" "${CLIENT_DIR}/${peer_name}.png"
}

show_status() {
  ensure_wg_config

  local addr prefix port peer_total public_ip service_state now
  addr="$(get_interface_value "Address")"
  prefix="$(echo "${addr}" | awk -F. '{print $1"."$2"."$3}')"
  port="$(get_interface_value "ListenPort")"
  public_ip="$(get_public_ip || true)"
  peer_total="$(grep -c '^# peer:' "${WG_CONF}" 2>/dev/null || echo 0)"
  now="$(date +%s)"

  echo
  paint "${GOLD}" "╔══════════════════════════════════════════════╗"
  paint "${GOLD}" "║          WireGuard 状态                      ║"
  paint "${GOLD}" "╚══════════════════════════════════════════════╝"
  echo
  printf "  %b服务端信息：%b\n" "${CYAN}" "${RESET}"
  printf "    %b配置文件:%b %s\n" "${WHITE}" "${RESET}" "${WG_CONF}"
  printf "    %bVPN 网段:%b %s\n" "${WHITE}" "${RESET}" "${prefix}.0/24"
  printf "    %b监听端口:%b %s\n" "${WHITE}" "${RESET}" "${port}"
  if [[ -n "${public_ip}" ]]; then
    printf "    %b公网地址:%b %s:%s\n" "${WHITE}" "${RESET}" "${public_ip}" "${port}"
  fi
  printf "    %b已配置 peer 数量:%b %s\n" "${WHITE}" "${RESET}" "${peer_total}"
  echo
  printf "  %b服务状态：%b\n" "${PURPLE}" "${RESET}"
  if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}" 2>/dev/null; then
    service_state="运行中"
    printf "    %b●%b wg-quick@%s %b运行中%b\n" "${CYAN}" "${RESET}" "${WG_INTERFACE}" "${CYAN}" "${RESET}"
  else
    service_state="未运行"
    printf "    %b●%b wg-quick@%s %b未运行%b\n" "${ORANGE}" "${RESET}" "${WG_INTERFACE}" "${ORANGE}" "${RESET}"
  fi
  echo
  printf "  %bPeer 列表：%b\n" "${CYAN}" "${RESET}"
  if [[ "${peer_total}" -gt 0 ]]; then
    printf "    %b%-18s %-16s %-20s %s%b\n" "${PURPLE}" "名字" "VPN IP" "最近握手" "状态" "${RESET}"
    printf "    %b%-18s %-16s %-20s %s%b\n" "${GRAY}" "------------------" "----------------" "--------------------" "------" "${RESET}"
    while IFS='|' read -r peer_name peer_key peer_ip; do
      [[ -z "${peer_name}" ]] && continue
      local handshake_epoch handshake_state handshake_label row_color
      handshake_epoch="$(wg show "${WG_INTERFACE}" latest-handshakes 2>/dev/null | awk -v key="${peer_key}" '$1==key {print $2; exit}')"
      if [[ -n "${handshake_epoch}" && "${handshake_epoch}" != "0" ]]; then
        handshake_state="$((now - handshake_epoch)) 秒前"
        handshake_label="已连接"
        row_color="${CYAN}"
      else
        handshake_state="未握手"
        handshake_label="未连接"
        row_color="${ORANGE}"
      fi
      printf "    %b%-18s %-16s %-20s %s%b\n" "${row_color}" "${peer_name}" "${peer_ip}" "${handshake_state}" "${handshake_label}" "${RESET}"
    done < <(get_peer_records)
  else
    printf "    %b当前还没有任何 peer%b\n" "${GRAY}" "${RESET}"
  fi

  echo
  printf "  %b最近握手原始数据：%b\n" "${PURPLE}" "${RESET}"
  if wg show "${WG_INTERFACE}" latest-handshakes 2>/dev/null | grep -q '.'; then
    wg show "${WG_INTERFACE}" latest-handshakes
  else
    printf "    %b当前还没有任何握手记录%b\n" "${GRAY}" "${RESET}"
  fi
}

add_peer_flow() {
  check_root
  ensure_wg_config
  require_cmd wg
  require_cmd qrencode
  require_cmd curl
  require_cmd systemctl

  local peer_name="${1:-}"
  local wait_timeout="${2:-120}"

  if [[ -z "${peer_name}" ]]; then
    read -r -p "请输入玩家名字: " peer_name </dev/tty
  fi

  if [[ -z "${peer_name}" ]]; then
    error "玩家名字不能为空"
    exit 1
  fi

  if peer_name_exists "${peer_name}"; then
    error "名字「${peer_name}」已存在，请换一个"
    exit 1
  fi

  local net_info cidr prefix port next_octet client_ip client_public_key conf_file
  net_info="$(get_wg_network_info)"
  net_info="${net_info#*|}"
  cidr="${net_info%%|*}"
  prefix="${net_info##*|}"
  port="$(get_listen_port)"
  next_octet="$(find_next_ip_octet "${prefix}")"
  client_ip="${prefix}.${next_octet}"

  info "添加 ${peer_name} ..."
  client_public_key="$(add_peer "${peer_name}" "${client_ip}")"
  conf_file="${CLIENT_DIR}/${peer_name}.conf"

  info "重启 WireGuard ..."
  if ! restart_wg; then
    error "WireGuard 重启失败，请先查看系统日志"
    echo "  systemctl status wg-quick@${WG_INTERFACE} -l --no-pager" >&2
    echo "  journalctl -u wg-quick@${WG_INTERFACE} -xe --no-pager" >&2
    return 0
  fi

  ok "配置已生成: ${conf_file}"
  show_qr_terminal "${conf_file}"
  if ! wait_for_handshake "${client_public_key}" "${port}" "${wait_timeout}" "${POLL_INTERVAL}"; then
    warn "本次未检测到握手，稍后可在 status 里继续查看"
    return 0
  fi
}

remove_peer_flow() {
  check_root
  ensure_wg_config
  require_cmd wg
  require_cmd systemctl

  local peer_name="${1:-}"
  if [[ -z "${peer_name}" ]]; then
    read -r -p "请输入要删除的玩家名字: " peer_name </dev/tty
  fi

  if [[ -z "${peer_name}" ]]; then
    error "玩家名字不能为空"
    exit 1
  fi

  if ! peer_name_exists "${peer_name}"; then
    error "未找到名为「${peer_name}」的 peer"
    exit 1
  fi

  warn "即将删除 peer「${peer_name}」"
  read -r -p "确认删除请输入 yes: " confirm </dev/tty
  if [[ "${confirm}" != "yes" ]]; then
    info "已取消删除"
    exit 0
  fi

  cp "${WG_CONF}" "${WG_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  remove_peer_from_server_config "${peer_name}"
  remove_peer_artifacts "${peer_name}"

  if ! systemctl restart "wg-quick@${WG_INTERFACE}"; then
    error "WireGuard 重启失败，请先查看系统日志"
    echo "  systemctl status wg-quick@${WG_INTERFACE} -l --no-pager" >&2
    echo "  journalctl -u wg-quick@${WG_INTERFACE} -xe --no-pager" >&2
    return 0
  fi
  ok "已删除 peer「${peer_name}」并重启 WireGuard"
}

remove_env_flow() {
  check_root
  require_cmd systemctl

  if [[ ! -d "${WG_DIR}" && ! -f "${WG_CONF}" ]]; then
    warn "未检测到已安装环境"
    return 0
  fi

  warn "此操作会删除 WireGuard 服务端配置并停止服务"
  echo "  目标: ${WG_CONF}"
  echo "  目录: ${WG_DIR}"
  read -r -p "确认删除请输入 DELETE: " confirm </dev/tty
  if [[ "${confirm}" != "DELETE" ]]; then
    info "已取消删除"
    exit 0
  fi

  systemctl stop "wg-quick@${WG_INTERFACE}" 2>/dev/null || true
  systemctl disable "wg-quick@${WG_INTERFACE}" 2>/dev/null || true
  rm -f "${WG_CONF}" "${WG_DIR}/server_private.key" "${WG_DIR}/server_public.key" "${SYSCTL_FILE}"
  rm -rf "${WG_DIR}"

  sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
  rm -rf "${CLIENT_DIR}" 2>/dev/null || true

  ok "已删除环境相关文件"
}

install_entrypoint() {
  local target="/usr/local/bin/together"

  cat > "${target}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec bash -c 'curl -fsSL https://raw.githubusercontent.com/jesse-ux/TogetherToTheSpire/main/wg-setup.sh | bash -s -- "$@"' bash "$@"
EOF

  chmod +x "${target}"
  ok "已安装本地入口: together"
}

get_system_summary() {
  local os_name="未知系统"
  local os_id="unknown"

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    os_name="${PRETTY_NAME:-${ID:-未知系统}}"
    os_id="${ID:-unknown}"
  else
    os_name="$(uname -s)"
  fi

  echo "${os_name}|${os_id}"
}

get_peer_names() {
  if [[ ! -f "${WG_CONF}" ]]; then
    return 0
  fi

  awk -F': ' '/^# peer: / { print $2 }' "${WG_CONF}"
}

show_menu() {
  local system_summary system_name system_id env_exists peer_count service_state recommendation
  system_summary="$(get_system_summary)"
  system_name="${system_summary%%|*}"
  system_id="${system_summary##*|}"
  env_exists="no"
  peer_count=0
  service_state="未检测到服务"
  recommendation="推荐先部署环境"

  if [[ -f "${WG_CONF}" ]]; then
    env_exists="yes"
    peer_count="$(get_peer_names | sed '/^$/d' | wc -l | tr -d ' ')"
    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}" 2>/dev/null; then
      service_state="检测到服务运行中"
    else
      service_state="检测到环境，但服务未运行"
    fi
    recommendation="可以添加 peer、查看状态或删除 peer"
  fi

  echo
  paint "${GOLD}" "╔══════════════════════════════════════════════╗"
  paint "${GOLD}" "║   TogetherToTheSpire — 控制菜单             ║"
  paint "${GOLD}" "╚══════════════════════════════════════════════╝"
  echo
  printf "  %b当前系统环境:%b %b%s (%s)%b\n" "${CYAN}" "${RESET}" "${WHITE}" "${system_name}" "${system_id}" "${RESET}"
  printf "  %b当前状态:%b %b%s%b\n" "${PURPLE}" "${RESET}" "${WHITE}" "${service_state}" "${RESET}"
  printf "  %b推荐操作:%b %b%s%b\n" "${ORANGE}" "${RESET}" "${WHITE}" "${recommendation}" "${RESET}"

  if [[ "${env_exists}" == "yes" ]]; then
    printf "  %b当前 peer 数量:%b %b%s%b\n" "${CYAN}" "${RESET}" "${WHITE}" "${peer_count}" "${RESET}"
    if [[ "${peer_count}" -gt 0 ]]; then
      printf "  %b已有 peer:%b\n" "${CYAN}" "${RESET}"
      while IFS= read -r peer_name; do
        [[ -z "${peer_name}" ]] && continue
        printf "    %b- %s%b\n" "${GOLD}" "${peer_name}" "${RESET}"
      done < <(get_peer_names)
    fi
  fi

  echo
  printf "  %b1.%b %s\n" "${GOLD}" "${RESET}" "部署环境"
  if [[ "${env_exists}" == "yes" ]]; then
    printf "  %b2.%b %s\n" "${CYAN}" "${RESET}" "添加 peer"
    printf "  %b3.%b %s\n" "${PURPLE}" "${RESET}" "删除 peer"
    printf "  %b4.%b %s\n" "${ORANGE}" "${RESET}" "查看状态"
    printf "  %b5.%b %s\n" "${GOLD}" "${RESET}" "删除环境"
  else
    printf "  %b2.%b %s\n" "${GRAY}" "${RESET}" "添加 peer（未部署，暂不可用）"
    printf "  %b3.%b %s\n" "${GRAY}" "${RESET}" "删除 peer（未部署，暂不可用）"
    printf "  %b4.%b %s\n" "${GRAY}" "${RESET}" "查看状态（未部署，暂不可用）"
    printf "  %b5.%b %s\n" "${GRAY}" "${RESET}" "删除环境（未部署，暂不可用）"
  fi
  printf "  %b0.%b %s\n" "${WHITE}" "${RESET}" "退出"
  echo
}

interactive_menu() {
  while true; do
    show_menu
    read -r -p "请选择: " choice </dev/tty
    case "${choice}" in
      1) setup_flow ;;
      2)
        if [[ -f "${WG_CONF}" ]]; then
          add_peer_flow
        else
          warn "当前没有检测到已部署环境，请先选择 1 部署环境"
        fi
        ;;
      3)
        if [[ -f "${WG_CONF}" ]]; then
          remove_peer_flow
        else
          warn "当前没有检测到已部署环境，请先选择 1 部署环境"
        fi
        ;;
      4)
        if [[ -f "${WG_CONF}" ]]; then
          show_status
        else
          warn "当前没有检测到已部署环境，请先选择 1 部署环境"
        fi
        ;;
      5)
        if [[ -f "${WG_CONF}" ]]; then
          remove_env_flow
        else
          warn "当前没有检测到已部署环境，无需删除"
        fi
        ;;
      0|q|Q) exit 0 ;;
      *) warn "请输入 0-5 的数字" ;;
    esac
    echo
    read -r -p "按回车返回菜单..." _ </dev/tty
  done
}

main() {
  local command="${1:-}"
  case "${command}" in
    setup)
      shift || true
      setup_flow "$@"
      ;;
    add-peer|add)
      shift || true
      add_peer_flow "$@"
      ;;
    remove-peer|rm-peer)
      shift || true
      remove_peer_flow "$@"
      ;;
    status)
      shift || true
      show_status "$@"
      ;;
    remove-env|destroy|uninstall)
      shift || true
      remove_env_flow "$@"
      ;;
    help|-h|--help)
      echo "用法: sudo ./wg-setup.sh [setup|add-peer|remove-peer|status|remove-env]"
      echo "不带参数时进入交互菜单"
      ;;
    "")
      interactive_menu
      ;;
    *)
      error "未知命令: ${command}"
      echo "可用命令: setup, add-peer, remove-peer, status, remove-env" >&2
      exit 1
      ;;
  esac
}

main "$@"
