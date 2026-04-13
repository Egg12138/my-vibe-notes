# WSL2 + Clash 虚拟网卡下 GitHub SSH 失败排障笔记

[toc]

**主题**: WSL2, Clash, GitHub SSH, fake-ip, Git push  
**结论先行**: 这类失败通常不是 Git 仓库权限问题，而是 `WSL2` 里的 DNS / 路由被 Clash 接管后，`github.com:22` 被解析到 `198.18.0.0/16` 的 fake IP，导致 SSH 握手被中间层关掉。

## Beginner

### 1. 先看错误，不要先猜权限

典型报错是：

- `Connection closed by 198.18.0.14 port 22`
- `Could not read from remote repository`

这类信息很容易让人误判成：

- SSH key 没配好
- GitHub 仓库不存在
- 仓库权限不够

但真正关键的是 `198.18.x.x`。这个网段通常不是 GitHub 的真实地址，而是 Clash fake-ip 体系下的占位地址。

### 2. 先确认仓库远端

先看本地仓库配置是不是标准的 GitHub SSH：

```bash
git remote -v
git config --show-origin --get-regexp '^(remote\\..*|url\\..*insteadof)$'
```

如果远端还是 `git@github.com:owner/repo.git`，问题大概率不在 repo 配置本身。

### 3. 再确认 DNS 解析结果

在 WSL2 里查：

```bash
getent hosts github.com
cat /etc/resolv.conf
```

如果 `github.com` 被解析成 `198.18.0.14` 之类的地址，说明当前 DNS 已经被 Clash 接管了。

### 4. 验证 SSH 真正连到了哪里

用 verbose 模式看：

```bash
ssh -vvvT git@github.com
```

如果输出里出现：

```text
Connecting to github.com [198.18.0.14] port 22
```

说明 SSH 根本没有走到真实的 GitHub 公网地址。

### 5. 最小可行修复

最稳妥的规避方式是让 GitHub SSH 走 443：

```sshconfig
Host github.com
  HostName ssh.github.com
  User git
  Port 443
```

这不会改变你仓库的 remote 写法，只是把底层连接端口换成 GitHub 官方支持的 SSH 备用入口。

## Expert

### 1. 根因链路

这次的问题链路可以拆成四层：

1. Windows 上 Clash 以虚拟网卡 / TUN 方式接管流量
2. WSL2 的 DNS 指向了 Clash 提供的解析器
3. `github.com` 被映射到 fake-ip 网段 `198.18.0.0/16`
4. SSH 22 端口在这条路径上被中间层关闭

所以从现象上看是 `git push` 失败，从网络层上看其实是“错误的目标地址 + 不适合的端口”。

### 2. 为什么 443 更稳

GitHub 提供 `ssh.github.com:443` 的目的，就是给 22 端口不可用的网络环境做备用通道。

对这类环境，443 的优势是：

- 更容易穿过企业网络、代理和 VPN 策略
- 更少受 22 端口拦截影响
- 对 Git 工作流没有本质影响

### 3. 为什么这个 repo 里还能看到 non-fast-forward

当 SSH 链路修好以后，`git push --dry-run` 可能仍然失败，但那就不是网络问题了。

常见原因是：

- 本地分支落后于远端
- 本地和远端都各自有提交，产生了分叉

这次验证里就出现了：

```text
ahead 3, behind 2
```

这说明网络层已经通了，剩下的是 Git 历史整合问题。

### 4. 排障顺序建议

按这个顺序查，效率最高：

1. `git remote -v`
2. `getent hosts github.com`
3. `ssh -vvvT git@github.com`
4. 如果看到 fake-ip，再试 `ssh.github.com:443`
5. 最后才看 `git pull` / `rebase` / `push` 的历史问题

## 验证记录

这次在 WSL2 里实际验证到的结果是：

- `github.com` 被解析到了 `198.18.0.14`
- `ssh -vvvT git@github.com` 在 `port 22` 上被关闭
- `ssh -T -p 443 git@ssh.github.com` 已成功完成 GitHub 认证
- `git push --dry-run` 仍然可能因为 `ahead/behind` 分叉失败，但不是网络层问题

## 可复用命令

```bash
getent hosts github.com
ssh -vvvT git@github.com
ssh -o UserKnownHostsFile=/tmp/vibenotes_known_hosts -o StrictHostKeyChecking=accept-new -T -p 443 git@ssh.github.com
GIT_SSH_COMMAND='ssh -o UserKnownHostsFile=/tmp/vibenotes_known_hosts -o StrictHostKeyChecking=accept-new' git push --dry-run origin HEAD
```

## 适用结论

如果你在 WSL2 里使用 Clash 虚拟网卡，并且 GitHub SSH 经常报 `Connection closed by 198.18.x.x port 22`，优先把 GitHub SSH 切到 `ssh.github.com:443`，再处理分支同步问题。

<!-- version: main@bab5f88, timestamp: 2026-04-13 13:02:24 CST -->
