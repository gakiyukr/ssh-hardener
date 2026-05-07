#!/usr/bin/env bash
# SSH 加固脚本（交互版 + 参数版）：
# - 允许用户自定义 SSH 端口
# - 允许用户自定义公钥来源（HTTPS 链接或 SSH 公钥字符串）
# - 强制仅使用密钥认证
# - 保留回滚能力
#
# 用法：
#   交互模式：sudo bash $0
#   参数模式：sudo bash $0 --port 2333 --key '<SSH公钥或HTTPS链接>' [--non-interactive]
#
# 参数说明：
#   -p, --port <端口>        指定 SSH 端口（默认: 2333）
#   -k, --key <公钥或URL>    指定公钥（可以是 ssh-rsa/ssh-ed25519 或 https:// 链接）
#   -u, --user <用户名>      指定目标用户（默认: root 或 SUDO_USER）
#   -n, --non-interactive    跳过确认，直接执行
#   -h, --help              显示此帮助信息
#
# 示例：
#   sudo bash $0 --port 2333 --key 'https://github.com/username.keys'
#   sudo bash $0 -p 2333 -k 'ssh-ed25519 AAAA...' -n

# Bash 安全模式（暂不启用 -u，因为需要处理可选参数）
set -eo pipefail

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# 显示帮助信息
show_help() {
  cat << 'EOF'
SSH 加固脚本 - 交互版 + 参数版

用法：
  sudo bash vps_ssh_interactive.sh [选项]

选项：
  -p, --port <端口>        指定 SSH 端口（默认: 2333）
  -k, --key <公钥或URL>    指定公钥（可以是 ssh-rsa/ssh-ed25519 等，或 https:// 链接）
  -u, --user <用户名>      指定目标用户（默认: root 或 SUDO_USER）
  -n, --non-interactive    跳过确认，直接执行（需要配合 -p 和 -k）
  -h, --help              显示此帮助信息

示例：
  # 交互模式
  sudo bash vps_ssh_interactive.sh

  # 参数模式（从 GitHub 获取公钥）
  sudo bash vps_ssh_interactive.sh --port 2333 --key 'https://github.com/username.keys'

  # 参数模式（直接指定公钥，跳过确认）
  sudo bash vps_ssh_interactive.sh -p 2333 -k 'ssh-ed25519 AAAA...' -n

  # 参数模式（指定目标用户）
  sudo bash vps_ssh_interactive.sh -p 2333 -k 'ssh-rsa AAAA...' -u myuser -n
EOF
}

# 初始化参数
TARGET_PORT=""
AUTH_KEYS_INPUT=""
TARGET_USER_OVERRIDE=""
INTERACTIVE_MODE=true

# 解析命令行参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)
      TARGET_PORT="$2"
      shift 2
      ;;
    -k|--key)
      AUTH_KEYS_INPUT="$2"
      shift 2
      ;;
    -u|--user)
      TARGET_USER_OVERRIDE="$2"
      shift 2
      ;;
    -n|--non-interactive)
      INTERACTIVE_MODE=false
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      err "未知参数: $1"
      show_help
      exit 1
      ;;
  esac
done

# 必须以 root 运行
if [[ $EUID -ne 0 ]]; then
  err "请使用 root 运行：sudo bash $0"
  exit 1
fi

# 检查 OpenSSH 服务端配置文件存在
if [[ ! -f "$SSHD_CONFIG" ]]; then
  err "找不到 $SSHD_CONFIG，可能尚未安装 OpenSSH 服务端。"
  exit 1
fi

# 需要 curl 来拉取远程公钥
if ! command_exists curl; then
  err "缺少依赖 curl，请先安装。"
  exit 1
fi

# 确定 SSH 服务名称
SSH_SERVICE="sshd"
if command_exists systemctl && systemctl list-unit-files | grep -q "^ssh\.service"; then
  SSH_SERVICE="ssh"
fi

# 从 sshd 解析后的生效配置读取端口
get_current_port() {
  if command_exists sshd; then
    sshd -T 2>/dev/null | awk '/^port / { print $2; exit }'
  fi
}

CURRENT_PORT="$(get_current_port || true)"
CURRENT_PORT="${CURRENT_PORT:-22}"
log "当前 SSH 端口：$CURRENT_PORT"

# ============================================
# 处理目标端口
# ============================================

if $INTERACTIVE_MODE && [[ -z "$TARGET_PORT" ]]; then
  # 交互模式：提示用户输入
  read -p "请输入目标 SSH 端口 (默认: 2333): " TARGET_PORT_INPUT
  TARGET_PORT="${TARGET_PORT_INPUT:-2333}"
elif [[ -z "$TARGET_PORT" ]]; then
  # 参数模式但未提供端口
  err "参数模式下必须使用 --port 指定端口"
  exit 1
fi

# 验证端口号有效性
if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]] || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
  err "无效的端口号：$TARGET_PORT"
  exit 1
fi

log "将使用端口：$TARGET_PORT"

# ============================================
# 处理公钥来源
# ============================================

AUTH_KEYS_CONTENT=""

if $INTERACTIVE_MODE && [[ -z "$AUTH_KEYS_INPUT" ]]; then
  # 交互模式：提示用户选择公钥来源方式
  echo
  echo "请选择公钥来源方式："
  echo "1. HTTPS 链接（可以是 GitHub、Gitee 等）"
  echo "2. SSH 公钥字符串（ssh-rsa/ssh-ed25519 开头）"
  echo "3. 多个来源（逐一输入，输入空行结束）"

  read -p "请选择 (1/2/3): " KEY_SOURCE_CHOICE

  case "$KEY_SOURCE_CHOICE" in
    1)
      # HTTPS 链接方式
      read -p "请输入 HTTPS 链接: " KEY_URL
      if [[ -z "$KEY_URL" ]]; then
        err "URL 不能为空"
        exit 1
      fi
      log "正在从 $KEY_URL 获取公钥..."
      AUTH_KEYS_CONTENT="$(curl -fsSL "$KEY_URL" | tr -d '\r')"
      ;;
    2)
      # SSH 公钥字符串
      read -p "请输入 SSH 公钥 (ssh-rsa/ssh-ed25519/...): " SSH_KEY_STRING
      if [[ -z "$SSH_KEY_STRING" ]]; then
        err "公钥不能为空"
        exit 1
      fi
      
      # 验证格式（以 ssh- 开头）
      if [[ "$SSH_KEY_STRING" =~ ^ssh- ]]; then
        AUTH_KEYS_CONTENT="$SSH_KEY_STRING"
        log "已读取 SSH 公钥"
      else
        err "无效的 SSH 公钥格式（必须以 ssh- 开头）"
        exit 1
      fi
      ;;
    3)
      # 多个来源
      echo "逐一输入公钥或链接（输入空行结束）:"
      while true; do
        read -p "公钥/链接: " KEY_INPUT
        
        if [[ -z "$KEY_INPUT" ]]; then
          break
        fi
        
        # 检测来源类型
        if [[ "$KEY_INPUT" =~ ^https?:// ]]; then
          # 扩展 HTTPS 链接
          log "正在从链接获取：$KEY_INPUT"
          FETCHED_KEYS="$(curl -fsSL "$KEY_INPUT" | tr -d '\r')"
          AUTH_KEYS_CONTENT+="$FETCHED_KEYS"$'\n'
        elif [[ "$KEY_INPUT" =~ ^ssh- ]]; then
          # 直接使用 SSH 公钥
          AUTH_KEYS_CONTENT+="$KEY_INPUT"$'\n'
        else
          warn "跳过无效内容：$KEY_INPUT"
        fi
      done
      
      # 去除末尾空行
      AUTH_KEYS_CONTENT="$(echo "$AUTH_KEYS_CONTENT" | sed -e :a -e '/^\s*$/d;N;ba')"
      ;;
    *)
      err "无效选择"
      exit 1
      ;;
  esac

elif [[ -z "$AUTH_KEYS_INPUT" ]]; then
  # 参数模式但未提供公钥
  err "参数模式下必须使用 --key 指定公钥"
  exit 1
else
  # 参数模式：自动检测公钥来源
  log "处理公钥参数..."
  
  # 检测来源类型
  if [[ "$AUTH_KEYS_INPUT" =~ ^https?:// ]]; then
    # HTTPS 链接
    log "正在从 $AUTH_KEYS_INPUT 获取公钥..."
    AUTH_KEYS_CONTENT="$(curl -fsSL "$AUTH_KEYS_INPUT" | tr -d '\r')"
  elif [[ "$AUTH_KEYS_INPUT" =~ ^ssh- ]]; then
    # SSH 公钥字符串
    AUTH_KEYS_CONTENT="$AUTH_KEYS_INPUT"
    log "已读取 SSH 公钥"
  else
    err "无法识别的公钥格式：必须以 ssh- 开头或 https:// 开头的 URL"
    exit 1
fi

# 验证是否获取到公钥
if [[ -z "$AUTH_KEYS_CONTENT" ]]; then
  err "没有获取到有效的公钥"
  exit 1
fi

log "已成功读取公钥内容"

# ============================================
# 确认执行
# ============================================
echo
echo "========== 执行摘要 =========="
echo "SSH 端口: $TARGET_PORT"
echo "公钥行数: $(echo "$AUTH_KEYS_CONTENT" | wc -l)"
echo "备份文件: ${SSHD_CONFIG}.bak.${BACKUP_SUFFIX}"
echo "=============================="
echo

# 如果是非交互模式，直接执行；否则提示用户确认
if ! $INTERACTIVE_MODE; then
  log "非交互模式，将直接执行..."
else
  read -p "确认上述设置？(y/n): " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    log "已取消操作"
    exit 0
  fi
fi

# ============================================
# 执行配置修改
# ============================================

# 先备份配置
cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.${BACKUP_SUFFIX}"
log "已创建备份：${SSHD_CONFIG}.bak.${BACKUP_SUFFIX}"

# 辅助函数：确保配置存在
ensure_kv() {
  local key="$1"
  local value="$2"
  sed -ri "s/^[[:space:]]*${key}[[:space:]].*$/# &/I" "$SSHD_CONFIG"
  printf "%s %s\n" "$key" "$value" >> "$SSHD_CONFIG"
}

# 修改端口
if [[ "$CURRENT_PORT" != "$TARGET_PORT" ]]; then
  ensure_kv "Port" "$TARGET_PORT"
  log "已设置端口为 $TARGET_PORT"
else
  log "端口已是 $TARGET_PORT"
fi

# 应用安全配置
ensure_kv "PubkeyAuthentication" "yes"
ensure_kv "PasswordAuthentication" "no"
ensure_kv "KbdInteractiveAuthentication" "no"
ensure_kv "ChallengeResponseAuthentication" "no"

# 保持 PAM 可用
grep -qiE '^UsePAM[[:space:]]+yes' "$SSHD_CONFIG" || ensure_kv "UsePAM" "yes"
grep -qiE '^AuthorizedKeysFile[[:space:]]' "$SSHD_CONFIG" || ensure_kv "AuthorizedKeysFile" ".ssh/authorized_keys"

# 确定目标用户和主目录
if [[ -n "$TARGET_USER_OVERRIDE" ]]; then
  TARGET_USER="$TARGET_USER_OVERRIDE"
else
  TARGET_USER="${SUDO_USER:-root}"
fi

if [[ "$TARGET_USER" == "root" ]]; then
  TARGET_HOME="/root"
else
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
fi

SSH_DIR="$TARGET_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

# 写入公钥
install -d -m 700 "$SSH_DIR"
printf "%s\n" "$AUTH_KEYS_CONTENT" > "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"
log "已设置 authorized_keys：$AUTH_KEYS"

# ============================================
# 防火墙配置
# ============================================

open_firewall_port() {
  local port="$1"

  if command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ! ufw status | grep -qE "[[:space:]]${port}/tcp"; then
      yes | ufw allow "${port}/tcp" >/dev/null 2>&1 || true
      log "UFW 已放行 ${port}/tcp"
    else
      log "UFW 已存在 ${port}/tcp 规则"
    fi
  fi

  if command_exists firewall-cmd && systemctl is-active --quiet firewalld; then
    if ! firewall-cmd --list-ports | tr ' ' '\n' | grep -qx "${port}/tcp"; then
      firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
      firewall-cmd --reload >/dev/null
      log "firewalld 已放行 ${port}/tcp"
    else
      log "firewalld 已存在 ${port}/tcp 规则"
    fi
  fi
}

open_firewall_port "$TARGET_PORT"
if [[ "$CURRENT_PORT" != "$TARGET_PORT" ]]; then
  open_firewall_port "$CURRENT_PORT"
fi

# ============================================
# SELinux 配置
# ============================================

handle_selinux() {
  local port="$1"
  if command_exists getenforce && [[ "$(getenforce 2>/dev/null || echo Permissive)" == "Enforcing" ]]; then
    if command_exists semanage; then
      if ! semanage port -l | awk '$1=="ssh_port_t" { print $0 }' | grep -qw "$port"; then
        semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null || \
          semanage port -m -t ssh_port_t -p tcp "$port"
        log "SELinux 已允许 ssh_port_t 使用 ${port}/tcp"
      else
        log "SELinux 已允许 ssh_port_t 使用 ${port}/tcp"
      fi
    else
      warn "SELinux 处于 Enforcing，但缺少 semanage。"
      warn "请安装 policycoreutils-python-utils 后执行："
      warn "  semanage port -a -t ssh_port_t -p tcp ${port}"
    fi
  fi
}

handle_selinux "$TARGET_PORT"
if [[ "$CURRENT_PORT" != "$TARGET_PORT" ]]; then
  handle_selinux "$CURRENT_PORT"
fi

# ============================================
# 配置校验与服务重启
# ============================================

if command_exists sshd; then
  if ! sshd -t -f "$SSHD_CONFIG"; then
    err "sshd 配置校验失败，正在回滚。"
    cp -a "${SSHD_CONFIG}.bak.${BACKUP_SUFFIX}" "$SSHD_CONFIG"
    exit 1
  fi
else
  warn "未找到 sshd 命令，跳过配置校验。"
fi

# 重载或重启 SSH 服务
if command_exists systemctl; then
  systemctl reload "$SSH_SERVICE" 2>/dev/null || systemctl restart "$SSH_SERVICE"
elif command_exists service; then
  service "$SSH_SERVICE" reload 2>/dev/null || service "$SSH_SERVICE" restart
fi
log "SSH 服务已重载/重启。"

# 检查端口监听
if command_exists ss; then
  sleep 1
  if ss -ltn | awk '{print $4}' | grep -q ":${TARGET_PORT}\$"; then
    log "检测到 ${TARGET_PORT}/tcp 正在监听。"
  else
    warn "未检测到 ${TARGET_PORT} 监听，请手动检查："
    warn "  ss -ltn | grep :${TARGET_PORT}"
  fi
fi

echo
log "========== 完成 =========="
log "请在新终端测试："
log "  ssh -p ${TARGET_PORT} ${TARGET_USER}@<服务器IP>"
log "如需回滚（当前会话内）："
log "  cp -a ${SSHD_CONFIG}.bak.${BACKUP_SUFFIX} ${SSHD_CONFIG} && systemctl restart ${SSH_SERVICE}"
log "如果使用云安全组，请确保 ${TARGET_PORT}/tcp 已放行。"
