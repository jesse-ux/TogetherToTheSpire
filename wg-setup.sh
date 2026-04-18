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
POLL_INTERVAL="2"
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
    error "请用 sudo 运行，例如: sudo ./wg-setup.sh"
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
      error "当前系统不支持: ${OS_NAME}"
      echo "目前仅支持: Ubuntu、Debian、Rocky Linux、AlmaLinux" >&2
      exit 1
      ;;
  esac

  if [[ "${OS_ID}" == "centos" && "${OS_VERSION%%.*}" == "8" ]]; then
    error "暂不支持 CentOS 8"
    echo "CentOS 8 的 WireGuard 内核模块存在兼容问题，建议更换为 Ubuntu/Debian。" >&2
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
  paint "${GOLD}" "  请输入 WireGuard 监听端口" >/dev/tty
  paint "${CYAN}" "  范围 1024-65535，不知道填什么的话用 51820 就行" >/dev/tty
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

  error "当前内核不支持 WireGuard，无法启动服务"
  echo "建议（任选其一）：" >&2
  echo "  1. 安装内核模块: dnf install kmod-wireguard（RHEL 系）" >&2
  echo "  2. 升级系统内核" >&2
  echo "  3. 更换为 Ubuntu / Debian 等自带 WireGuard 支持的系统" >&2
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
  echo "  用 WireGuard 扫描下方二维码即可导入："
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
  if [[ "${timeout}" -gt 0 ]]; then
    info "等待玩家连接中（最长 ${timeout} 秒）..."
  else
    info "等待玩家连接中..."
  fi

  echo
  echo "  玩家操作步骤："
  echo "  1. 打开 WireGuard"
  echo "  2. 点 + → 扫描二维码"
  echo "  3. 对准终端里的二维码扫描"
  echo "  4. 打开连接开关"
  echo "  5. 连接成功后这里会自动检测到"

  while :; do
    if wg show "${WG_INTERFACE}" latest-handshakes | awk -v key="${peer_pubkey}" '
      $1==key && $2 > 0 { found=1 }
      END { exit(found ? 0 : 1) }
    '; then
      echo
      ok "玩家已连接"
      wg show "${WG_INTERFACE}" | awk -v key="${peer_pubkey}" '
        $1=="peer:" && $2==key { print; in_peer=1; next }
        $1=="peer:" && $2!=key { in_peer=0 }
        in_peer { print }
      '
      return 0
    fi

    if [[ "${timeout}" -gt 0 && "${elapsed}" -ge "${timeout}" ]]; then
      echo
      warn "等待超时，未检测到玩家连接"
      echo "  排查清单："
      echo "  1. 玩家是否已扫码并打开 WireGuard 连接"
      echo "  2. 云服务器安全组是否放行 UDP ${listen_port}（最常见的原因）"
      echo "  3. 玩家手机/电脑网络是否正常"
      return 1
    fi

    sleep "${interval}"
    elapsed=$((elapsed + interval))
    if [[ "${timeout}" -gt 0 ]]; then
      printf "\r\033[K  等待中... %ds/%ds" "${elapsed}" "${timeout}"
    else
      printf "\r\033[K  等待中... %ds" "${elapsed}"
    fi
  done
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
  echo "  请把手机递给 ${peer_name}，打开 WireGuard 扫码："
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
  info "正在检测所有玩家连接状态..."

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
    ok "全部 ${total} 位玩家已连接，可以开游戏了！"
  else
    warn "${found}/${total} 位玩家已连接"
    echo >/dev/tty
    echo "  未连接的玩家请检查："
    echo "  1. WireGuard 是否已打开连接"
    echo "  2. 云服务器安全组是否放行 UDP ${listen_port}"
    echo "  3. 网络是否正常"
  fi
}

wait_for_all_handshakes() {
  local listen_port="$1"
  local timeout="${2:-0}"
  shift 2
  local -a peer_pubkeys=("$@")
  local total="${#peer_pubkeys[@]}"
  local interval=2
  local elapsed=0

  echo
  info "等待所有玩家连接..."
  if [[ "${timeout}" -gt 0 ]]; then
    echo "  （最长等待 ${timeout} 秒）"
  else
    echo "  （会一直等到所有人都连上）"
  fi

  while :; do
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

    if [[ "${timeout}" -gt 0 && "${elapsed}" -ge "${timeout}" ]]; then
      echo
      warn "等待超时，部分玩家未连接"
      echo "  排查清单："
      echo "  1. 玩家是否已打开 WireGuard 连接"
      echo "  2. 云服务器安全组是否放行 UDP ${listen_port}"
      echo "  3. 玩家网络是否正常"
      return 1
    fi

    if [[ "${timeout}" -gt 0 ]]; then
      printf "\r  当前连接: %d/%d，剩余 %ds" "${connected}" "${total}" "$((timeout - elapsed))"
    else
      printf "\r  当前连接: %d/%d，等待所有玩家上线..." "${connected}" "${total}"
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done
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

服务器信息：
  公网地址: ${public_ip}:${port}
  VPN 网段: ${prefix}.0/24

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

第一步：安装 WireGuard 客户端

  Windows: https://www.wireguard.com/install/ (v0.6.1)
  macOS:   App Store 搜索 WireGuard
  iOS:     App Store 搜索 WireGuard
  Android: 使用仓库内置的 APK

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

第二步：扫码导入配置

  1. 打开 WireGuard
  2. 点 + 号 → 扫描二维码（或从文件导入 ${CLIENT_DIR}/ 下的 .conf）
  3. 扫码后打开连接开关

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

第三步：开始联机

  1. 确认所有人 WireGuard 都显示已连接
  2. 房主打开《杀戮尖塔》→ 联机 → 局域网游戏 → 创建房间
  3. 其他人打开《杀戮尖塔》→ 联机 → 局域网游戏 → 输入房主的 VPN IP

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

连不上的常见原因：
  - WireGuard 连接开关没打开
  - 云服务器安全组没放行 UDP ${port}
  - 杀戮尖塔里用的是公网 IP 而不是 VPN IP

EOF

  echo "${guide}"
}

print_guide_summary() {
  local public_ip="$1"
  local port="$2"
  local prefix="$3"

  echo
  echo "╔══════════════════════════════════════════════╗"
  echo "║          接下来怎么做（照着走就行）          ║"
  echo "╚══════════════════════════════════════════════╝"
  echo
  echo "  1. 让朋友用 WireGuard 扫描上面的二维码（或导入 .conf 文件）"
  echo "  2. 确认所有人 WireGuard 都显示已连接"
  echo "  3. 房主打开《杀戮尖塔》→ 联机 → 局域网游戏 → 创建房间"
  echo "  4. 其他人→ 联机 → 局域网游戏 → 输入房主的 VPN IP"
  echo
  echo "  服务器信息："
  echo "    公网地址: ${public_ip}:${port}"
  echo "    VPN 网段: ${prefix}.0/24"
  echo
  echo "  连不上？优先检查这三项："
  echo "    - WireGuard 连接开关是否打开"
  echo "    - 云服务器安全组是否放行 UDP ${port}"
  echo "    - 杀戮尖塔里填的是 VPN IP（不是公网 IP）"
  echo
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
  echo "  服务器信息："
  echo "    公网地址: ${public_ip}:${port}"
  echo "    VPN 网段: ${prefix}.0/24"
  echo "    配置文件: ${WG_CONF}"
  echo
  paint "${GOLD}" "╔══════════════════════════════════════════════╗"
  paint "${GOLD}" "║    !! 安全组放行（这一步不做就连不上 !!）    ║"
  paint "${GOLD}" "╚══════════════════════════════════════════════╝"
  echo
  paint "${ORANGE}" "  请立刻去云服务器控制台，添加一条入方向规则："
  echo
  paint "${WHITE}" "    协议: UDP    端口: ${port}    来源: 0.0.0.0/0"
  echo
  paint "${CYAN}" "  找不到在哪？各厂商路径："
  echo "    阿里云 → 安全组 → 入方向 → 添加规则 → UDP ${port}"
  echo "    腾讯云 → 安全组 → 入站规则 → 添加规则 → UDP ${port}"
  echo "    华为云 → 安全组 → 入方向规则 → 添加 → UDP ${port}"
  echo "    AWS    → Security Groups → Inbound → UDP ${port}"
  echo
}

# ── 控制器 ────────────────────────────────────────────────

setup_flow() {
  check_root
  require_cmd ip
  require_cmd awk

  echo
  echo "╔══════════════════════════════════════════════╗"
  echo "║   TogetherToTheSpire — 联机部署              ║"
  echo "╚══════════════════════════════════════════════╝"
  echo

  if [[ -f "${WG_CONF}" ]]; then
    warn "检测到已有 WireGuard 配置"
    echo "  位置: ${WG_CONF}"
    echo
    echo "  如需全新部署，请先手动执行："
    echo "    sudo wg-quick down ${WG_INTERFACE} && sudo rm -rf ${WG_DIR}"
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

  echo
  echo "  几个人一起联机？（1-5，回车默认 2）"
  local peer_count
  while true; do
    read -r -p "  > " peer_count </dev/tty
    if [[ -z "${peer_count}" ]]; then
      peer_count=2
      break
    fi
    if [[ "${peer_count}" =~ ^[1-5]$ ]]; then
      break
    fi
    warn "请输入 1 到 5 的数字"
  done

  echo
  ok "为 ${peer_count} 位玩家生成配置"
  echo

  local -a default_names=("战士" "猎宝" "亡灵" "鸡煲" "储君" "观者大人")
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
    echo "  玩家 ${idx} 叫什么？（回车默认: ${default_name}）"
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
    info "重启 WireGuard 使配置生效..."
    if ! restart_wg; then
      error "WireGuard 重启失败，请先查看系统日志"
      echo "  systemctl status wg-quick@${WG_INTERFACE} -l --no-pager" >&2
      echo "  journalctl -u wg-quick@${WG_INTERFACE} -xe --no-pager" >&2
      return 1
    fi
    ok "WireGuard 已重启"

    echo
    info "轮到 ${name} 了，请把手机递过去扫码"
    show_peer_qr "${name}" "${client_ip}"

    if ! wait_for_handshake "${pubkey}" "${WG_PORT}" 0 "${POLL_INTERVAL}"; then
      warn "${name} 连接失败，先停在这里"
      return 0
    fi

    ok "${name} 搞定了，下一位"
    echo
  done

  check_handshakes "${WG_PORT}" "${peer_pubkeys[@]}"

  info "生成联机说明..."
  local guide_path
  guide_path="$(generate_guide "${public_ip}" "${WG_PORT}" "${prefix}")"
  ok "联机说明已保存到 ${guide_path}"
  print_guide_summary "${public_ip}" "${WG_PORT}" "${prefix}"

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
  echo "  已配置玩家: ${peer_total}"

  echo
  echo "╔══════════════════════════════════════════════╗"
  echo "║          全部搞定，开游戏吧！                ║"
  echo "╚══════════════════════════════════════════════╝"
  echo
  echo "  配置文件在: ${CLIENT_DIR}/"
  echo
  echo "  下次管理: sudo ./wg-setup.sh [add-peer|remove-peer|status]"
  echo "  或:       sudo together [add-peer|remove-peer|status]"
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
  paint "${GOLD}" "║          联机状态                            ║"
  paint "${GOLD}" "╚══════════════════════════════════════════════╝"
  echo
  printf "  %b服务器信息：%b\n" "${CYAN}" "${RESET}"
  printf "    %bVPN 网段:%b %s\n" "${WHITE}" "${RESET}" "${prefix}.0/24"
  printf "    %b监听端口:%b %s\n" "${WHITE}" "${RESET}" "${port}"
  if [[ -n "${public_ip}" ]]; then
    printf "    %b公网地址:%b %s:%s\n" "${WHITE}" "${RESET}" "${public_ip}" "${port}"
  fi
  printf "    %b已配置玩家:%b %s\n" "${WHITE}" "${RESET}" "${peer_total}"
  echo
  printf "  %b运行状态：%b\n" "${PURPLE}" "${RESET}"
  if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}" 2>/dev/null; then
    service_state="运行中"
    printf "    %b●%b wg-quick@%s %b运行中%b\n" "${CYAN}" "${RESET}" "${WG_INTERFACE}" "${CYAN}" "${RESET}"
  else
    service_state="未运行"
    printf "    %b●%b wg-quick@%s %b未运行%b\n" "${ORANGE}" "${RESET}" "${WG_INTERFACE}" "${ORANGE}" "${RESET}"
  fi
  echo
  printf "  %b玩家列表：%b\n" "${CYAN}" "${RESET}"
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
  printf "  %b握手详情：%b\n" "${PURPLE}" "${RESET}"
  if wg show "${WG_INTERFACE}" latest-handshakes 2>/dev/null | grep -q '.'; then
    wg show "${WG_INTERFACE}" latest-handshakes
  else
    printf "    %b暂无握手记录%b\n" "${GRAY}" "${RESET}"
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
    read -r -p "新玩家叫什么名字: " peer_name </dev/tty
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
    warn "未检测到连接，可以稍后用 sudo ./wg-setup.sh status 查看"
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
    read -r -p "要删除哪位玩家: " peer_name </dev/tty
  fi

  if [[ -z "${peer_name}" ]]; then
    error "玩家名字不能为空"
    exit 1
  fi

  if ! peer_name_exists "${peer_name}"; then
    error "未找到名为「${peer_name}」的 peer"
    exit 1
  fi

  warn "即将删除「${peer_name}」的所有配置"
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
  ok "已删除「${peer_name}」并重启 WireGuard"
}

remove_env_flow() {
  check_root
  require_cmd systemctl

  if [[ ! -d "${WG_DIR}" && ! -f "${WG_CONF}" ]]; then
    warn "未检测到已安装环境"
    return 0
  fi

  warn "此操作会停止 WireGuard 服务并删除所有配置"
  echo "  将删除: ${WG_CONF}、${WG_DIR}、${CLIENT_DIR}"
  read -r -p "确认全部删除请输入 DELETE: " confirm </dev/tty
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

  ok "WireGuard 环境已清除"
}

install_entrypoint() {
  local target="/usr/local/bin/together"

  cat > "${target}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec bash -c 'curl -fsSL https://gitee.com/jesse-chen1/TogetherToTheSpire/raw/main/wg-setup.sh | bash -s -- "$@"' bash "$@"
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
    recommendation="可以添加新玩家、查看状态或删除玩家"
  fi

  echo
  paint "${GOLD}" "╔══════════════════════════════════════════════╗"
  paint "${GOLD}" "║   TogetherToTheSpire — 联机控制台           ║"
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
    printf "  %b2.%b %s\n" "${CYAN}" "${RESET}" "添加玩家"
    printf "  %b3.%b %s\n" "${PURPLE}" "${RESET}" "删除玩家"
    printf "  %b4.%b %s\n" "${ORANGE}" "${RESET}" "查看连接状态"
    printf "  %b5.%b %s\n" "${GOLD}" "${RESET}" "删除环境"
  else
    printf "  %b2.%b %s\n" "${GRAY}" "${RESET}" "添加玩家（需先部署）"
    printf "  %b3.%b %s\n" "${GRAY}" "${RESET}" "删除玩家（需先部署）"
    printf "  %b4.%b %s\n" "${GRAY}" "${RESET}" "查看状态（需先部署）"
    printf "  %b5.%b %s\n" "${GRAY}" "${RESET}" "删除环境（需先部署）"
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
          warn "还没有部署环境，请先选 1"
        fi
        ;;
      3)
        if [[ -f "${WG_CONF}" ]]; then
          remove_peer_flow
        else
          warn "还没有部署环境，请先选 1"
        fi
        ;;
      4)
        if [[ -f "${WG_CONF}" ]]; then
          show_status
        else
          warn "还没有部署环境，请先选 1"
        fi
        ;;
      5)
        if [[ -f "${WG_CONF}" ]]; then
          remove_env_flow
        else
          warn "还没有部署环境，无需删除"
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
      echo "不带参数进入交互菜单"
      ;;
    "")
      interactive_menu
      ;;
    *)
      error "未知命令: ${command}"
      echo "可用命令: setup, add-peer, remove-peer, status, remove-env"
      exit 1
      ;;
  esac
}

main "$@"
