# 📦 sh-hub

一个用于存放个人常用 Shell 脚本的仓库。

主要用于解决开发、运维过程中一些高频、重复、环境相关的问题。

---

## 🚀 使用方式

```bash
git clone https://github.com/Coco422/sh-hub
cd sh-hub

chmod +x xxx.sh
./xxx.sh
```

## 📂 脚本列表

1. cursor-remote-deploy.sh

用于在无外网服务器上部署 Cursor Remote Server。
功能：
	•	自动获取本地 Cursor 版本（commit）
	•	自动下载对应 server 包
	•	自动上传并部署到远程服务器
	•	自动识别远程架构（x64 / arm64）

2. change hostname pwd

更改主机名和 root 密码小脚本

## 🧠 设计原则

	•	每个脚本只解决一个问题
	•	优先实用，不做过度抽象
	•	支持内网 / 离线场景
	•	尽量做到开箱即用


## 📌 说明

	•	所有脚本均为个人常用工具，持续补充中
	•	不保证兼容所有环境，请根据实际情况调整
	•	建议在使用前阅读脚本内容

## ⭐

一个持续积累的 Shell 工具箱。
