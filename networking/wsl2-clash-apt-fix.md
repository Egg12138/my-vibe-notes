# WSL2 Mirrored Mode + Clash Proxy 导致 apt 失败的排查与修复

[toc]

## 现象

- 环境：Windows 11 WSL2（网络模式 mirrored）+ Clash for Windows（系统代理 `127.0.0.1:7897`）
- 症状：`sudo apt install` 失败（hang 住或无响应），但浏览器等其他网络应用正常

## Debug 过程

### Step 1 — 确认网络基础连通性

```bash
curl -I https://deb.debian.org    # → 200 OK（代理通路正常）
ping 8.8.8.8                      # → 通（ICMP 可达）
ping google.com                   # → 100% 丢包（正常，ICMP 不走代理）
```

**结论**：网络层面没问题，问题锁定在 apt 自身或其与代理的交互上。

### Step 2 — 检查 sudo 环境中的代理变量

```bash
sudo env | grep -i proxy
# http_proxy=http://127.0.0.1:7897
# https_proxy=http://127.0.0.1:7897
```

**结论**：`/etc/sudoers.d/` 中有 `env_keep` 配置，代理环境变量在 sudo 环境中完整保留，apt 理论上应该走代理。

### Step 3 — 抓取 apt update 实际错误日志

```bash
sudo apt update 2>&1
```

**关键错误**：

```
Err:21 https://mirrors.tuna.tsinghua.edu.cn/ubuntu noble InRelease
  Could not wait for server fd - select (11: Resource temporarily unavailable) [IP: 127.0.0.1 7897]
```

**解读**：
- 错误码 `11` = `EAGAIN`（Resource temporarily unavailable）
- 错误地址是 `127.0.0.1:7897`——**不是远端镜像站，而是 Clash 代理本身**
- 含义：apt 的并发请求把 Clash 代理的连接数/文件描述符打满了

### Step 4 — 确认并发连接是根因

清华镜像站配置了 3 个 suite：

```
Suites: noble noble-updates noble-backports
```

apt 默认 `Queue-Mode "access"` 会为每个 URI 同时打开独立连接，3 条连接同时打到 Clash 代理，触发 fd/连接上限。

**验证思路**：问题不是"网络不通"，而是"请求太多"——限制并发应该能解决。

## 修复

### 1. 限制 apt 并发连接数

创建 `/etc/apt/apt.conf.d/99-proxy-fix`：

```
Acquire::Queue-Mode "host";
Acquire::http::Pipeline-Depth "0";
```

| 选项 | 作用 |
|------|------|
| `Queue-Mode "host"` | 同一主机串行化请求，不再并行打开多个连接 |
| `Pipeline-Depth "0"` | 禁用 HTTP 管道（pipelining），进一步减少单连接并发 |

### 2. 导入缺失的 GPG 公钥（本次附带问题）

```bash
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys BAA929FF1A7ECACE  # claude-code
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 5989A47D8D14C246  # kraftkit
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys F42ED6FBAB17C654  # ROS2
```

## 方法论总结

```
用户报告 "apt install 失败"
        │
        ▼
┌──────────────────────┐
│ 1. 排除网络层        │  curl / ping → 确认代理通路正常
└──────────────────────┘
        │
        ▼
┌──────────────────────┐
│ 2. 排除环境传递      │  sudo env → 确认 proxy 变量被保留
└──────────────────────┘
        │
        ▼
┌──────────────────────┐
│ 3. 抓实际错误日志    │  apt update 输出 → 拿到具体 errno + 地址
└──────────────────────┘
        │
        ▼
┌──────────────────────┐
│ 4. 解读错误语义      │  EAGAIN @ 127.0.0.1:7897 → 代理被打满
└──────────────────────┘
        │
        ▼
┌──────────────────────┐
│ 5. 针对性修复        │  限制并发 → apt config；GPG → 导入公钥
└──────────────────────┘
```

## 核心经验

- **表面是网络问题，实际是并发控制问题**——代理本身能通，但承受不住 apt 的请求风暴
- **错误信息中的 IP 地址是关键线索**——`127.0.0.1:7897` 直接指向代理而非远端镜像站，这是定位根因的决定性证据
- **`select (11: Resource temporarily unavailable)`** 是 Clash fd 打满的典型特征
