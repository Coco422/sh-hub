#!/usr/bin/env bash
# 一键修改主机名 + root 密码
# 使用方法：保存为 change-hostname-passwd.sh，然后 chmod +x 后以 root 执行
# 示例：sudo bash change-hostname-passwd.sh

set -euo pipefail

# 检查是否 root 执行
if [[ $EUID -ne 0 ]]; then
    echo "错误：请以 root 权限运行此脚本（sudo bash $0）"
    exit 1
fi

echo "======================================"
echo "     一键修改主机名 + root 密码      "
echo "======================================"
echo ""

# ====================== 修改主机名 ======================
current_hostname=$(hostname)
echo "当前主机名：${current_hostname}"
echo -n "请输入新的主机名（建议使用小写字母、数字、短横线，不含空格）："
read -r new_hostname

if [[ -z "$new_hostname" ]]; then
    echo "错误：主机名不能为空！"
    exit 1
fi

if [[ ! "$new_hostname" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
    echo "警告：主机名建议只使用小写字母、数字、短横线，避免特殊字符。"
    echo -n "仍要继续吗？(y/N)："
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 1
fi

# 设置新主机名
hostnamectl set-hostname "$new_hostname" 2>/dev/null || {
    echo "$new_hostname" > /etc/hostname
    hostname "$new_hostname"
}

# 更新 /etc/hosts 中的 127.0.1.1 行（Debian/Ubuntu 常用）
if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/127.0.1.1.*$/127.0.1.1\t${new_hostname}/" /etc/hosts
else
    echo "127.0.1.1	${new_hostname}" >> /etc/hosts
fi

# 尝试重载 hostname 服务（systemd 系统）
systemctl restart systemd-hostnamed 2>/dev/null || true

echo ""
echo "主机名已修改为：$(hostname)"
echo "注意：部分终端需要重新登录或重启系统才能在提示符中完全显示新主机名。"
echo ""

# ====================== 修改 root 密码 ======================
echo "接下来修改 root 密码。"
echo -n "请输入新的 root 密码："
read -s new_password
echo ""
echo -n "请再次输入新密码确认："
read -s new_password_confirm
echo ""

if [[ -z "$new_password" ]]; then
    echo "错误：密码不能为空！"
    exit 1
fi

if [[ "$new_password" != "$new_password_confirm" ]]; then
    echo "错误：两次输入的密码不一致！"
    exit 1
fi

# 设置 root 密码（使用 chpasswd 更安全，避免明文在进程列表中出现）
echo "root:${new_password}" | chpasswd

if [[ $? -eq 0 ]]; then
    echo "root 密码修改成功！"
else
    echo "密码修改失败，请检查系统是否支持 chpasswd 或手动使用 passwd root"
    exit 1
fi

echo ""
echo "======================================"
echo "          操作全部完成！             "
echo "新主机名：$(hostname)"
echo "root 密码：已成功更新（请牢记）"
echo ""
echo "建议："
echo "1. 新开一个终端窗口，确认提示符是否更新"
echo "2. 如提示符未变，可执行：exec bash   或重启服务器"
echo "3. 下次登录请使用新密码"
echo "======================================"
