# util-linux: `make DESTDIR=... install` 里 `chgrp/chown` 失败（user namespace / rootless build）

[toc]

## 现象（你会看到什么）

在 `util-linux` 的 build 目录里执行：

```sh
make DESTDIR=/path/to/rootfs install
```

可能在安装阶段失败，典型报错之一：

- `chgrp: changing group of '.../usr/bin/wall': Invalid argument`
- 或稍后类似的：`chown: changing ownership of '...': Invalid argument`

这些失败往往发生在 `install-exec-hook-*` 这种目标里。

## 初学者视角：它为什么要 `chgrp tty` / `chmod g+s`？

`util-linux` 里 `wall`（以及有些发行版里 `write`）需要把消息写到**其他用户的终端**（例如 `/dev/tty*`、`/dev/pts/*`）。很多系统上终端设备权限模型是：

- 设备节点属于 `root:tty`
- `tty` 组有额外访问权限

因此上游安装时会把 `wall` 设置成：

- group = `tty`（`chgrp tty wall`）
- `setgid`（`chmod g+s wall`）

这样普通用户运行 `wall` 时，会临时获得 `tty` 组权限，才能把消息广播到别人的终端。

如果你跳过这一步：

- `root` 仍然能用 `wall`
- 普通用户可能无法广播（取决于目标系统的 `/dev/pts/*` 权限）

## 进阶视角：为什么不是 “Operation not permitted”，而是 “Invalid argument”？

在很多 rootless / sandbox / 容器化构建环境里，进程运行在 **user namespace** 下，UID/GID 映射是受限的。

在这种情况下，如果你尝试把文件的 group 改成一个**未映射**的 GID（例如宿主的 `tty` 通常是 `gid=5`），内核会返回 `EINVAL`（对应用户态看到的 `Invalid argument`），而不是传统权限不足的 `EPERM`。

一个常见信号：

- `getent group tty` 能看到 `tty:x:5:`
- 但当前用户并不在 `tty` 组里，且 userns 没映射 `gid 5`

类似问题也会在打包时给文件设 `root:root` 所有权时出现（`chown root:root ...`）。

## 解决策略（按你要的目标选择）

### 方案 A：最终 rootfs 不需要普通用户用 `wall`

跳过 `wall` 的 setgid/tty 设置即可（减少 rootless 安装阻塞点）。

我们在 build 目录的 `Makefile` 里把 `install-exec-hook-wall` 做成环境变量开关：

```sh
UL_SKIP_WALL_SETGID=1 make DESTDIR=$TL install
```

含义：

- `UL_SKIP_WALL_SETGID=1`：完全跳过 `wall` 的 `chgrp tty` 和 `chmod g+s`
- 不设置该变量：root 下按上游语义设置；非 root 下会提示并跳过（避免 hard fail）

### 方案 B：你希望普通用户能用 `wall`，同时还要 rootless 安装

推荐把“所有权/权限修正”移到**后处理阶段**（用真正 root 或在有完整 uid/gid 映射的环境里执行）：

- 先完成 `DESTDIR` 文件落盘（允许跳过 hook）
- 再在生成镜像/打包阶段执行：

```sh
chgrp tty $TL/usr/bin/wall
chmod g+s  $TL/usr/bin/wall
```

如果你还需要 `mount` 等被设置成 `root:root` 的文件，也在同阶段补 `chown/chmod`。

### 方案 C：直接用 root（最省事、最接近上游）

在具备 root 权限的环境里执行安装：

```sh
sudo make DESTDIR=$TL install
```

## 实战提示：别只修 `wall`

`util-linux` 里不止 `wall` 会改权限：

- `su` 会被设成 setuid root（例如 `chmod 4755 .../su`）
- `mount` 等会 `chown root:root ...`

所以如果你的目标是“完全 rootless 生成一个最终权限正确的 rootfs”，通常要么：

- 用 root/打包工具统一修权限（最常见）
- 要么使用真正可用的 fakeroot + subuid/subgid 映射（取决于环境支持）

---

<!--
source: /home/egg/source/tiny-linux/gnutools/util-linux (git 57c6893)
written: 2026-05-05
-->
