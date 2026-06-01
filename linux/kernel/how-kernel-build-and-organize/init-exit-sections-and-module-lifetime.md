# init/exit 段、`__initdata`/`__exit` 与模块生命周期（以 rmmod 崩溃为例）

[toc]

## 1. 现象速览（你看到的 panic 在说什么）

典型栈：

- `rmmod` → `__x64_sys_delete_module` → `do_init_module`/`free_module` 相关路径
- 崩溃点：`hello_exit+0x5`，并且提示 `Unable to access opcode bytes` / CR2 指向一个模块地址（常见在 `0xffffffffc0...`）

这类信息高度吻合 **访问了已经被释放/取消映射的模块内存**：不是“printk 触发”，而是 `hello_exit()` 本身所在的地址或其访问的数据所在地址已经不可用。

## 2. `__initdata`/`__exit` 是什么：从宏展开到 section

### 2.1 宏展开（Linux 6.6 系列）

在 `include/linux/init.h` 里（模块与内核本体共用）：

- `__initdata` 定义为 `__section(".init.data")`
- `__exit` 定义为 `__section(".exit.text") __exitused __cold notrace`

而 `__section(x)` 在 `include/linux/compiler_attributes.h` 里定义为：

- `__attribute__((__section__(x)))`

因此：

- `static int hello_data __initdata = 3;`
  - 会被编译器放入 ELF 的 `.init.data` 段
- `static void __exit hello_exit(void) { ... }`
  - 会被编译器放入 `.exit.text` 段（模块卸载时需要执行的代码）

### 2.2 `.init.*` / `.exit.*` 的语义（直觉版）

- `.init.*`：**只在“初始化阶段”需要**。初始化结束后可回收，减少常驻内存。
- `.exit.*`：**只在“退出/卸载阶段”需要**。对于可卸载模块，`rmmod` 会用到；对于不可卸载或内核内置场景，可能会被丢弃（取决于配置/链接脚本/宏定义）。

## 3. 根因：模块 init 段会在装载成功后被释放

对 **可卸载模块**，流程是：

1. `insmod`/`modprobe` 装载模块，分配并映射多类内存：
   - core：常驻（`.text/.data/.rodata/...`）
   - init：初始化用（`.init.text/.init.data/.init.rodata`）
2. 调用模块的 `module_init()`（即 `mod->init`）
3. **如果 init 返回成功（0 或正值但会 warn）**：
   - 模块状态变为 `LIVE`
   - **模块子系统会把 init 段对应的内存记录下来，并在稍后释放**

在 `kernel/module/main.c` 的 `do_init_module()` 里（6.6 系列）可以看到：

- 把 `MOD_INIT_TEXT / MOD_INIT_DATA / MOD_INIT_RODATA` 的 base 保存到一个 `freeinit` 结构
- 把该结构加入链表并 `schedule_work()`，最终在 `do_free_init()` 中：
  - `synchronize_rcu()`
  - `execmem_free(initfree->init_text/init_data/init_rodata)` 释放映射

**关键结论：模块 init 成功后，`.init.*` 就不再保证可访问。**

因此你的示例里：

```c
static int hello_data __initdata = 3;

static void __exit hello_exit(void)
{
    pr_info("goodbye __exit %d\n", hello_data);
}
```

`hello_exit()` 在 `rmmod` 时执行，但它读取的 `hello_data` 位于 `.init.data`，此时已被释放 → 页故障 → Oops/panic。

> 这不是“`__initdata` 不能被 `__exit` 使用”的语法限制，而是 **生命周期不满足**：你引用了已释放的对象。

## 4. 生命周期图（模块视角）

以“模块成功装载 + 之后卸载”为时间线：

1. **装载中**：
   - `.init.text/.init.data/.init.rodata`：有效
   - `.text/.data/.rodata`：有效
2. **`module_init()` 返回成功之后**：
   - `.init.*`：被排队释放（异步 workqueue + RCU 同步后真正 free）
   - `.text/.data/.rodata`：仍有效（模块常驻）
3. **`rmmod` 卸载中**：
   - `.exit.text`：有效（卸载代码执行）
   - `.init.*`：**通常已无效**（这正是你的 crash）
4. **卸载结束**：
   - core/exit 相关内存释放，模块彻底消失

## 5. 为什么错误信息里 “opcode bytes 无法访问”？

日志中常见：

- `RIP: hello_exit+0x5`
- `Code: Unable to access opcode bytes at 0xffffffffc07e0feb`

解释路径有两类（都和“内存不可访问”有关）：

1. **exit 函数本体所在页不可访问**
   - 例如你把函数本体放到了已经被释放的段（更常见于错误标注 `__init` / 放错段）
2. **指令页还在，但访问了不可访问的数据页**
   - CPU 在执行 `hello_exit` 时读 `hello_data` 触发 fault

你给的 `RIP` 指向 `hello_exit`，且 `CR2` 指向 `0xffffffffc07e0feb`（模块范围），与“访问 `.init.data` 已被释放”高度一致。

## 6. “应该怎么写”——模式与反模式

### 6.1 反模式：exit 依赖 init 段数据

- `__exit` 里读 `__initdata` / 调用 `__init` 函数
- 任何 “常驻路径” 里读 `.init.*`

### 6.2 正确模式 A：常驻变量（最简单）

如果 `hello_data` 在 init 和 exit 都要用：

- 去掉 `__initdata`，让它进普通 `.data`：
  - `static int hello_data = 3;`

### 6.3 正确模式 B：init 拷贝到常驻（适用于大对象/只想常驻一小份）

- init 阶段用 `.init.data` 做临时配置解析
- init 结束前，把最终需要在运行期/卸载期使用的那部分拷贝到常驻内存：
  - 常驻的静态变量（`.data`）
  - 或 `kmalloc` 分配（模块常驻期间有效，卸载时释放）

### 6.4 正确模式 C：真的只在 init 用

- 保留 `__initdata`
- exit 不再引用它（必要时仅打印“exit”而不打印该值）

## 7. 进阶：为什么内核要这么做（节省内存 + 安全/一致性）

1. **节省常驻内存**：init 代码和数据往往很大，初始化结束后无价值。
2. **强制约束**：把生命周期不正确的引用尽早暴露为崩溃/告警（在内核里比“默默错”更可取）。
3. **并发安全**：释放 init 段要和 RCU/符号遍历等机制协调（所以有 `synchronize_rcu()` 与 workqueue）。

## 8. 自查清单（看到类似 Oops 时快速定位）

- 变量或函数是否标了 `__init*` / `__exit*`？
- 崩溃时机是否是：
  - 模块装载成功后的一段时间（访问 `.init.*`）
  - `rmmod` 卸载时（exit 路径访问 init 数据）
- `RIP` 是否落在模块地址（`0xffffffffc0...`）？
- `CR2` 是否落在模块 `.init.*` 对应范围（需要结合 `cat /sys/module/<name>/sections/*` 或调试符号定位）？

---

<!--
vibenotes-footer:
repo: /home/egg/source/linux
version: arm-module-lds-unwind-group (4db02a472d88a20203595c97f1d2b81b43c659fb)
timestamp: 2026-06-02T00:48:46+08:00
-->

