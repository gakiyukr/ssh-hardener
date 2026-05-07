# vps_ssh_interactive.sh

一键加固 Linux SSH 配置：自定义端口、密钥认证、防火墙放行、自动回滚。

## 快速开始

```bash
# 交互模式（按提示输入）
sudo bash vps_ssh_interactive.sh

# 参数模式（从 GitHub 拉取公钥）
sudo bash vps_ssh_interactive.sh -p 2333 -k 'https://github.com/你的用户名.keys'

# 参数模式（直接指定公钥字符串）
sudo bash vps_ssh_interactive.sh -p 2333 -k 'ssh-ed25519 AAAA...'

# 自动化模式（跳过确认）
sudo bash vps_ssh_interactive.sh -p 2333 -k 'https://github.com/你的用户名.keys' -n
```

## 参数

| 参数                | 简写 | 说明                                       |
| ------------------- | ---- | ------------------------------------------ |
| `--port`            | `-p` | SSH 端口，1-65535，默认 2333               |
| `--key`             | `-k` | 公钥来源，支持 HTTPS URL 或 SSH 公钥字符串 |
| `--user`            | `-u` | 目标用户，默认 root 或当前 sudo 用户       |
| `--non-interactive` | `-n` | 跳过确认，直接执行                         |
| `--help`            | `-h` | 显示帮助                                   |

## `-k` 支持两种格式

脚本自动识别：

- **HTTPS URL**：以 `https://` 或 `http://` 开头

  ```bash
  -k 'https://github.com/用户名.keys'
  -k 'https://gitee.com/用户名.keys'
  ```

- **SSH 公钥字符串**：以 `ssh-` 开头

  ```bash
  -k 'ssh-rsa AAAAB3NzaC1yc2E...'
  -k 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...'
  ```

## 脚本做了什么

- 修改前**自动备份**原配置：`/etc/ssh/sshd_config.bak.20260222-120000`
- 将 SSH 端口改为指定值
- 强制密钥认证，禁用密码登录
- 覆盖 `authorized_keys`（仅保留你指定的公钥）
- 自动放行防火墙端口（UFW / firewalld）
- 如 SELinux 为 Enforcing，自动配置端口策略
- **配置校验**：重启前校验新配置有效性，**失败自动回滚**
- 优先 `reload` 保持现有连接，失败才 `restart`

## 常用场景

### 新服务器首次配置

```bash
sudo bash vps_ssh_interactive.sh
```

交互模式逐步输入，适合手动作业。

### 配合 GitHub 公钥，一键完成

```bash
sudo bash vps_ssh_interactive.sh \
  -p 2222 \
  -k 'https://github.com/你的用户名.keys' \
  -n
```

### 指定非 root 用户

```bash
sudo bash vps_ssh_interactive.sh \
  -p 2333 \
  -k 'ssh-rsa AAAAB3NzaC1yc2E...' \
  -u ubuntu \
  -n
```

### 嵌入自动化部署脚本

```bash
PUB_KEY=$(cat ~/.ssh/id_ed25519.pub)
sudo bash vps_ssh_interactive.sh -p 2333 -k "$PUB_KEY" -n
```

## 执行后

```bash
ssh -p 2333 user@服务器IP
```

## 回滚

脚本会在修改前自动备份原配置。如果出问题：

```bash
# 查看所有备份
ls /etc/ssh/sshd_config.bak.*

# 恢复指定备份
sudo cp /etc/ssh/sshd_config.bak.20260101-120000 /etc/ssh/sshd_config
sudo systemctl restart sshd
```

## 环境要求

- Linux（Debian/Ubuntu/CentOS/RHEL 等）
- OpenSSH 服务端已安装
- curl
- root 权限

## 注意事项

- 脚本会**覆盖** `authorized_keys`，旧密钥会被清除
- 云服务器需在安全组中放行新端口（TCP）
- 执行后务必新开终端测试，**不要关闭当前会话**，以防配置出问题时无法恢复
