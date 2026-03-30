#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 运行这个脚本。"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="1.0.0"
SSH_DROPIN="/etc/ssh/sshd_config.d/99-hardening.conf"
SSH_BACKUP_DIR="/root/init-prod-backups"
mkdir -p "$SSH_BACKUP_DIR"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_NC='\033[0m'

log()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_NC} $*"; }
ok()   { echo -e "${COLOR_GREEN}[ OK ]${COLOR_NC} $*"; }
warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} $*"; }
err()  { echo -e "${COLOR_RED}[ERR ]${COLOR_NC} $*" >&2; }

trap 'err "脚本执行出错，停止在第 ${LINENO} 行。建议检查上面的输出。"' ERR

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local answer
  while true; do
    if [[ "$default" == "y" ]]; then
      read -r -p "$prompt [Y/n]: " answer || true
      answer="${answer:-Y}"
    else
      read -r -p "$prompt [y/N]: " answer || true
      answer="${answer:-N}"
    fi
    case "$answer" in
      Y|y|YES|yes) return 0 ;;
      N|n|NO|no) return 1 ;;
      *) echo "请输入 y 或 n。" ;;
    esac
  done
}

ask_input() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer || true
    echo "${answer:-$default}"
  else
    read -r -p "$prompt: " answer || true
    echo "$answer"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "缺少命令: $1"
    exit 1
  }
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
    PRETTY="${PRETTY_NAME:-unknown}"
  else
    err "无法识别系统版本。"
    exit 1
  fi

  if [[ "$OS_ID" != "debian" ]]; then
    warn "当前系统是: $PRETTY"
    warn "这个脚本按 Debian 系列写的，继续也大概率能跑，但我没有针对非 Debian 做适配。"
    ask_yes_no "仍然继续吗？" "n" || exit 1
  fi
}

show_banner() {
  echo
  echo "=================================================="
  echo " Debian 生产服务器初始化脚本 v${SCRIPT_VERSION}"
  echo "=================================================="
  echo
}

summary_line() {
  printf "  %-28s %s\n" "$1" "$2"
}

install_base_packages() {
  log "刷新软件包索引..."
  apt update

  local pkgs=(
    vim curl wget git rsync htop iotop sysstat lsof psmisc
    net-tools iproute2 dnsutils jq unzip zip tar tmux
    chrony ufw fail2ban needrestart unattended-upgrades
    ca-certificates gnupg lsb-release logrotate ncdu sudo
  )

  log "安装基础运维工具..."
  apt install -y "${pkgs[@]}"

  ok "基础运维工具安装完成。"
}

set_hostname_interactive() {
  if ! ask_yes_no "是否修改主机名 hostname？" "y"; then
    return 0
  fi

  local current_host new_host
  current_host="$(hostnamectl --static 2>/dev/null || hostname)"
  echo "当前 hostname: $current_host"

  while true; do
    new_host="$(ask_input "请输入新的 hostname，只建议使用字母、数字、减号" "$current_host")"
    [[ -n "$new_host" ]] || { echo "hostname 不能为空。"; continue; }
    if [[ "$new_host" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
      break
    fi
    echo "格式不合法，请重新输入。"
  done

  if [[ "$new_host" == "$current_host" ]]; then
    ok "hostname 未变化，跳过。"
    return 0
  fi

  cp -a /etc/hosts "${SSH_BACKUP_DIR}/hosts.bak.$(date +%F-%H%M%S)" || true

  log "设置 hostname 为: $new_host"
  hostnamectl set-hostname "$new_host"

  if grep -qE '^\s*127\.0\.1\.1\s+' /etc/hosts; then
    sed -ri "s|^\s*127\.0\.1\.1\s+.*|127.0.1.1 ${new_host}|" /etc/hosts
  else
    echo "127.0.1.1 ${new_host}" >> /etc/hosts
  fi

  ok "hostname 已更新。"
}

create_admin_user_interactive() {
  NEW_ADMIN_USER=""
  ADMIN_KEY_ADDED="no"

  if ! ask_yes_no "是否创建新的运维用户并加入 sudo 组？" "y"; then
    warn "你选择了不创建新用户。后续 SSH 加固步骤会自动跳过。"
    return 0
  fi

  while true; do
    NEW_ADMIN_USER="$(ask_input "请输入要创建的用户名" "ray")"
    [[ -n "$NEW_ADMIN_USER" ]] || { echo "用户名不能为空。"; continue; }
    if id "$NEW_ADMIN_USER" >/dev/null 2>&1; then
      warn "用户 $NEW_ADMIN_USER 已存在，将继续使用现有用户。"
      break
    fi
    if [[ "$NEW_ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      break
    fi
    echo "用户名格式不合法，请重新输入。"
  done

  if ! id "$NEW_ADMIN_USER" >/dev/null 2>&1; then
    log "创建用户: $NEW_ADMIN_USER"
    adduser --disabled-password --gecos "" "$NEW_ADMIN_USER"
    ok "用户已创建。"
  fi

  if getent group sudo >/dev/null 2>&1; then
    adduser "$NEW_ADMIN_USER" sudo >/dev/null
    ok "已将 $NEW_ADMIN_USER 加入 sudo 组。"
  else
    warn "系统里没有 sudo 组，尝试安装 sudo 并创建 sudo 组。"
    apt install -y sudo
    getent group sudo >/dev/null 2>&1 || groupadd sudo
    adduser "$NEW_ADMIN_USER" sudo >/dev/null
    ok "已将 $NEW_ADMIN_USER 加入 sudo 组。"
  fi

  local ssh_dir auth_file
  ssh_dir="/home/${NEW_ADMIN_USER}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$auth_file"
  chmod 600 "$auth_file"
  chown -R "${NEW_ADMIN_USER}:${NEW_ADMIN_USER}" "$ssh_dir"

  if ask_yes_no "是否现在为 ${NEW_ADMIN_USER} 写入 SSH 公钥？" "y"; then
    echo
    echo "请粘贴一整行 SSH 公钥，例如 ssh-ed25519 ... 或 ssh-rsa ..."
    echo "粘贴完成后回车。若暂时没有，直接回车跳过。"
    local pubkey
    read -r pubkey || true
    if [[ -n "${pubkey}" ]]; then
      if grep -qxF "${pubkey}" "$auth_file"; then
        warn "该公钥已存在，跳过重复写入。"
      else
        echo "$pubkey" >> "$auth_file"
        chown "${NEW_ADMIN_USER}:${NEW_ADMIN_USER}" "$auth_file"
        ADMIN_KEY_ADDED="yes"
        ok "SSH 公钥已写入 ${auth_file}"
      fi
    else
      warn "你没有输入公钥，后续不会启用禁止密码登录。"
    fi
  fi
}

configure_ssh_hardening_staged() {
  SSH_STAGED="no"
  SSH_READY_TO_APPLY="no"

  if [[ -z "${NEW_ADMIN_USER:-}" ]]; then
    warn "没有可用的新运维用户，跳过 SSH 加固配置。"
    return 0
  fi

  if [[ "${ADMIN_KEY_ADDED:-no}" != "yes" ]]; then
    warn "没有为 ${NEW_ADMIN_USER} 导入 SSH 公钥。为避免锁在服务器外面，跳过 SSH 禁密和禁 root。"
    return 0
  fi

  if ! ask_yes_no "是否生成 SSH 加固配置，但暂时不重启 SSH 服务？" "y"; then
    return 0
  fi

  mkdir -p /etc/ssh/sshd_config.d
  if [[ -f "$SSH_DROPIN" ]]; then
    cp -a "$SSH_DROPIN" "${SSH_BACKUP_DIR}/$(basename "$SSH_DROPIN").bak.$(date +%F-%H%M%S)"
  fi

  cat > "$SSH_DROPIN" <<EOF
# Managed by init-prod.sh
# Review before reloading sshd.

PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
UsePAM yes
EOF

  if sshd -t; then
    SSH_STAGED="yes"
    SSH_READY_TO_APPLY="yes"
    ok "SSH 加固配置已写入: $SSH_DROPIN"
    ok "sshd -t 语法检查通过。"
  else
    err "sshd 配置检查失败，已建议你不要 reload SSH。请检查配置。"
    SSH_READY_TO_APPLY="no"
    return 1
  fi
}

setup_ufw() {
  if ! ask_yes_no "是否配置 UFW 防火墙？" "y"; then
    return 0
  fi

  local ssh_port web_http web_https extra_ports
  ssh_port="$(ss -tlnp 2>/dev/null | awk '/sshd/ {gsub(".*:","",$4); print $4}' | head -n1 || true)"
  ssh_port="${ssh_port:-22}"

  log "将默认允许出站，默认拒绝入站。"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  ufw allow "${ssh_port}/tcp" comment "SSH"

  if ask_yes_no "是否放行 80/tcp？" "y"; then
    web_http="yes"
    ufw allow 80/tcp comment "HTTP"
  else
    web_http="no"
  fi

  if ask_yes_no "是否放行 443/tcp？" "y"; then
    web_https="yes"
    ufw allow 443/tcp comment "HTTPS"
  else
    web_https="no"
  fi

  extra_ports="$(ask_input "如需额外放行端口，请输入，多个端口用逗号分隔；没有就直接回车" "")"
  if [[ -n "$extra_ports" ]]; then
    IFS=',' read -ra PORT_ARR <<< "$extra_ports"
    for p in "${PORT_ARR[@]}"; do
      p="$(echo "$p" | xargs)"
      [[ -n "$p" ]] || continue
      ufw allow "${p}/tcp" comment "custom-${p}" || true
    done
  fi

  ufw --force enable
  systemctl enable ufw >/dev/null 2>&1 || true
  ok "UFW 已启用。当前状态如下："
  ufw status verbose || true
}

setup_fail2ban() {
  if ! ask_yes_no "是否启用 fail2ban？" "y"; then
    return 0
  fi

  mkdir -p /etc/fail2ban
  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = auto

[sshd]
enabled = true
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
  ok "fail2ban 已启用。"
}

setup_chrony() {
  if ! ask_yes_no "是否启用 chrony 时间同步？" "y"; then
    return 0
  fi

  systemctl enable chrony
  systemctl restart chrony || true
  ok "chrony 已启用。"
}

setup_unattended_upgrades() {
  if ! ask_yes_no "是否启用 unattended-upgrades 自动安全更新？" "y"; then
    return 0
  fi

  dpkg-reconfigure -f noninteractive unattended-upgrades || true
  systemctl enable unattended-upgrades >/dev/null 2>&1 || true
  systemctl restart unattended-upgrades >/dev/null 2>&1 || true
  ok "自动安全更新已启用。"
}

install_docker_official_repo() {
  if ! ask_yes_no "是否安装 Docker Engine，使用 Docker 官方 apt 仓库？" "n"; then
    return 0
  fi

  log "安装 Docker 依赖..."
  apt install -y ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  . /etc/os-release
  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="${VERSION_CODENAME:-trixie}"

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable
EOF

  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl restart docker

  if [[ -n "${NEW_ADMIN_USER:-}" ]] && id "$NEW_ADMIN_USER" >/dev/null 2>&1; then
    if ask_yes_no "是否把 ${NEW_ADMIN_USER} 加入 docker 组？" "y"; then
      getent group docker >/dev/null 2>&1 || groupadd docker
      adduser "$NEW_ADMIN_USER" docker >/dev/null || true
      ok "已将 ${NEW_ADMIN_USER} 加入 docker 组。重新登录后生效。"
    fi
  fi

  ok "Docker 安装完成。"
}

show_final_summary() {
  echo
  echo "==================== 执行摘要 ===================="
  summary_line "系统" "$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')"
  summary_line "当前 hostname" "$(hostnamectl --static 2>/dev/null || hostname)"
  summary_line "新运维用户" "${NEW_ADMIN_USER:-未创建}"
  summary_line "SSH 公钥已写入" "${ADMIN_KEY_ADDED:-no}"
  summary_line "SSH 加固配置已暂存" "${SSH_STAGED:-no}"
  summary_line "SSH 可安全 reload" "${SSH_READY_TO_APPLY:-no}"
  echo "================================================="
  echo
}

show_next_steps() {
  local current_host ip_guess
  current_host="$(hostnamectl --static 2>/dev/null || hostname)"
  ip_guess="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

  echo "下一步建议按这个顺序执行："
  echo
  if [[ -n "${NEW_ADMIN_USER:-}" && "${ADMIN_KEY_ADDED:-no}" == "yes" ]]; then
    echo "1) 先在你本地电脑开一个新终端，测试新用户能否登录："
    echo "   ssh ${NEW_ADMIN_USER}@${ip_guess:-<服务器IP>}"
    echo
    echo "2) 登录成功后，测试 sudo："
    echo "   sudo -i"
    echo
  else
    echo "1) 你这次没有完成“新用户 + SSH 公钥”这一步。"
    echo "   所以脚本没有帮你启用禁 root 和禁密码登录。"
    echo
  fi

  if [[ "${SSH_READY_TO_APPLY:-no}" == "yes" ]]; then
    echo "3) 确认新用户登录和 sudo 都没问题后，再在当前会话里执行："
    echo "   sshd -t && systemctl reload ssh"
    echo
    echo "4) reload 成功后，再新开一个终端重新测试一次："
    echo "   ssh ${NEW_ADMIN_USER}@${ip_guess:-<服务器IP>}"
    echo
    echo "5) 确认完全没问题后，你的 root SSH 登录和密码登录就已经被禁用了。"
    echo
  else
    echo "3) 当前没有待应用的 SSH 加固配置，或者还不满足安全启用条件。"
    echo
  fi

  echo "常用检查命令："
  echo "  hostnamectl"
  echo "  ufw status verbose"
  echo "  systemctl status fail2ban --no-pager"
  echo "  systemctl status chrony --no-pager"
  echo "  systemctl status docker --no-pager"
  echo "  needrestart -r l"
  echo
  echo "备份目录： ${SSH_BACKUP_DIR}"
  echo
  echo "初始化完成。"
}

main() {
  require_cmd apt
  require_cmd hostnamectl
  detect_os
  show_banner

  install_base_packages
  set_hostname_interactive
  create_admin_user_interactive
  configure_ssh_hardening_staged
  setup_ufw
  setup_fail2ban
  setup_chrony
  setup_unattended_upgrades
  install_docker_official_repo

  show_final_summary
  show_next_steps
}

main "$@"
