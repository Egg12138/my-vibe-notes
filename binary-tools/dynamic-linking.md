# ELF 动态链接：共享库解析方式一览

[TOC]

## 场景

```
main.c ──(调用)──> safe_add_condition() ──(定义在)──> a.c ──(编译为)──> liba.so
```

核心问题：`main` 可执行文件依赖 `liba.so`，运行时动态链接器需要找到这个 `.so`。以下是从静态编译到高阶 ELF 技巧的完整分类。

## 一、静态编译（无动态依赖）

所有代码合并到一个二进制，不依赖外部 .so。

### 1. 直接合并编译

```bash
gcc -o a.out main.c a.c
```

最朴素的方式，两个 translation unit 一起编译链接，与动态链接完全无关。

### 2. 静态库 .a

```bash
gcc -c a.c -o a.o
ar rcs liba.a a.o
gcc -o a.out main.c -L. -la    # 链接器优先选 .so，需直接指定 .a 或用 -static
gcc -o a.out main.c liba.a     # 或直接链接 .a 文件（仍是动态链接但代码嵌入了）
gcc -static -o a.out main.c -L. -la   # 完全静态
```

`.a` 本质是 `.o` 的归档，链接时按需提取。

### 3. static-pie

```bash
gcc -static-pie -o a.out main.c a.c
```

静态 + 位置无关，既无外部依赖又支持 ASLR，现代容器场景推荐。

## 二、编译时嵌入库搜索路径

在 ELF 的 `DYNAMIC` 段写入搜索路径，运行时动态链接器自动读取。

### 4. rpath $ORIGIN

```bash
gcc -o a.out main.c -L. -la -Wl,-rpath,'$ORIGIN'
```

`$ORIGIN` 是动态链接器识别的特殊 token，展开为可执行文件所在目录。推荐方式之一，不影响环境。

### 5. rpath 绝对路径

```bash
gcc -o a.out main.c -L. -la -Wl,-rpath,/home/user/project
```

硬编码路径，适合部署路径固定的场景。迁移时需要重新编译。

### 6. rpath 相对路径

```bash
gcc -o a.out main.c -L. -la -Wl,-rpath,.
```

`.` 是**运行时 CWD**，脆弱。若 `cd /tmp` 再跑就找不到库。**不推荐**。

### 7. RUNPATH（enable-new-dtags）

```bash
gcc -o a.out main.c -L. -la -Wl,--enable-new-dtags,-rpath,'$ORIGIN'
```

与 rpath 的区别：
- **DT_RPATH**：优先级高于 `LD_LIBRARY_PATH`
- **DT_RUNPATH**：优先级低于 `LD_LIBRARY_PATH`（用户环境变量可以覆盖）

现代工具链默认生成 RUNPATH。

### 8. patchelf 后注入

```bash
gcc -o a.out main.c -L. -la    # 先编译，不设 rpath
patchelf --set-rpath '$ORIGIN' a.out   # 后改 ELF 头
```

无需重新编译，适合修补第三方二进制或 CI 产物。

## 三、运行时环境变量控制

不修改 ELF，不重新编译，通过环境变量告诉动态链接器去哪找。

### 9. LD_LIBRARY_PATH

```bash
export LD_LIBRARY_PATH=.    # 或包含库的目录
./a.out
```

最广为人知。搜索顺序：`DT_RPATH` → `LD_LIBRARY_PATH` → `DT_RUNPATH` → `/etc/ld.so.cache` → `/lib/` → `/usr/lib/`。

### 10. 直接调用 ld-linux

```bash
/lib64/ld-linux-x86-64.so.2 --library-path . ./a.out
```

绕过内核的 ELF 加载器，手动调用动态链接器并指定路径。调试时很有用（`--inhibit-rpath`、`--list` 等）。

### 11. LD_PRELOAD + 弱符号

```c
// main.c
int safe_add_condition(int a, int b, int *result) __attribute__((weak));
int main() {
    int res = 0;
    if (safe_add_condition)
        safe_add_condition(3, 5, &res);
    ...
}
```

```bash
gcc -o a.out main.c
LD_PRELOAD=./liba.so ./a.out
```

关键点：
- 声明为 `__attribute__((weak))` → 未解析时符号地址为 NULL
- 运行时通过 LD_PRELOAD 提供强符号 → 动态链接器用 LD_PRELOAD 的版本
- 没有弱符号时不能用（链接器不允许未定义符号）

### 12. 封装脚本

```bash
#!/bin/bash
export LD_LIBRARY_PATH="$(dirname "$(readlink -f "$0")")"
exec "$(dirname "$0")/a.out" "$@"
```

适用于分发场景：一个 wrapper 脚本自动设置环境然后 exec 真正程序。

## 四、运行时手动加载

不依赖动态链接器自动搜索，在代码中显式加载。

### 13. dlopen / dlsym

```c
void *handle = dlopen("./liba.so", RTLD_LAZY);
int (*fn)(int,int,int*) = dlsym(handle, "safe_add_condition");
fn(3, 5, &res);
```

```bash
gcc -o a.out main.c -ldl
```

完整控制：可以按需加载、卸载、按不同 flag 控制解析行为。插件系统的基石。

### 14. memfd_create + dlopen

```c
int fd = syscall(SYS_memfd_create, "liba", 0);
write(fd, liba_data, liba_size);
lseek(fd, 0, SEEK_SET);
snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
void *handle = dlopen(path, RTLD_LAZY);
```

不依赖文件系统中的 .so 文件。从内存（memfd 或嵌入二进制数据）创建匿名文件后 dlopen。

## 五、高阶 ELF 技巧

### 15. LD_AUDIT 劫持库搜索

```c
// audit.c
char *la_objsearch(const char *name, uintptr_t *cookie, unsigned int flag) {
    if (name && strstr(name, "liba.so"))
        return "./liba.so";
    return (char*)name;
}
```

```bash
gcc -shared -fPIC -o libaudit.so audit.c
LD_AUDIT=./libaudit.so ./a.out
```

Solaris 引入的运行时审计接口，可以拦截符号解析、路径搜索等。不常见但非常灵活。

### 16. objcopy 嵌入 + 解出加载

```bash
ld -r -b binary -o liba_embed.o liba.so    # 把 .so 作为 data section 嵌入
gcc -o a.out main.c liba_embed.o -ldl
```

运行时把嵌入的 .so 数据写到临时文件后 dlopen。适合单文件分发。

### 17. --defsym 桩 + LD_PRELOAD（不可行）

```bash
gcc -o a.out main.c -Wl,--defsym,safe_add_condition=0
LD_PRELOAD=./liba.so ./a.out    # ❌ 段错误
```

`--defsym` 把符号地址设为 0，但 call 指令直接用该地址跳转 → segfault。LD_PRELOAD 也不能挽回。

### 18. 系统库路径

```bash
sudo cp liba.so /usr/local/lib/
sudo ldconfig
gcc -o a.out main.c -L. -la
./a.out
```

加到 `/etc/ld.so.cache`，全局生效。需要 root，会影响系统上所有程序。

`/etc/ld.so.conf.d/` 下的 `.conf` 文件可以按需添加自定义搜索目录。

## 关键对比

| 维度 | 静态编译 | rpath | LD_LIBRARY_PATH | dlopen | LD_AUDIT |
|------|----------|-------|-----------------|--------|----------|
| 需改代码 | 否 | 否 | 否 | 是 | 否（审计库需改）|
| 需重新编译 | 是 | 是 | 否 | 是 | 否 |
| 需 root | 否 | 否 | 否 | 否 | 否 |
| 影响范围 | 单二进制 | 单二进制 | 进程级 | 进程级 | 进程级 |
| 灵活性 | 低 | 中 | 中 | 高 | 极高 |

## 动态链接器搜索顺序

```
1. DT_RPATH (已弃用, 除非 DT_RUNPATH 不存在)
2. LD_LIBRARY_PATH
3. DT_RUNPATH (仅搜索直接依赖)
4. /etc/ld.so.cache (ldconfig 缓存)
5. /lib/  →  /usr/lib/
```

## 调试工具

```bash
# 查看依赖
ldd a.out
readelf -d a.out | grep -E 'RPATH|RUNPATH|NEEDED'

# 查看动态链接过程
LD_DEBUG=libs ./a.out        # 显示库搜索过程
LD_DEBUG=files ./a.out       # 显示文件打开
LD_DEBUG=all ./a.out         # 全部细节

# 查看符号绑定
readelf -s liba.so | grep safe_add_condition
nm a.out | grep safe_add_condition

# 查看符号绑定强弱
readelf -s liba.so | awk '/safe_add_condition/ {print $4, $8}'
```

---

> 2026-07-21 | 基于 `dyn` 场景的实测总结  
> vibenotes @ 4c20779
