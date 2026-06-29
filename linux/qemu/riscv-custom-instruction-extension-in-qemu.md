# QEMU 中 RISC-V 自定义指令扩展的实现思路

## [toc]

- [概述](#概述)
- [Beginner](#beginner)
  - [先不要急着改代码：先确定链路](#先不要急着改代码先确定链路)
  - [我是怎么找到改动点的](#我是怎么找到改动点的)
  - [每类文件分别负责什么](#每类文件分别负责什么)
  - [为什么先单题打通再铺开全部指令](#为什么先单题打通再铺开全部指令)
- [Expert](#expert)
  - [定位改动点的方法论：从测试反推实现](#定位改动点的方法论从测试反推实现)
  - [为什么要加 CPU feature 开关](#为什么要加-cpu-feature-开关)
  - [怎么知道 decodetree 要怎么写](#怎么知道-decodetree-要怎么写)
  - [怎么把手册规格翻译成 `trans_*` 和 helper](#怎么把手册规格翻译成-trans_-和-helper)
  - [QEMU 中一条自定义指令的最小实现模板](#qemu-中一条自定义指令的最小实现模板)
  - [这类实验最容易写错的地方](#这类实验最容易写错的地方)
  - [可复用的工作流](#可复用的工作流)
- [Checklist](#checklist)

## 概述

给 QEMU 扩展一组 RISC-V 自定义指令，核心不是“会不会写 C”，而是先理解 **QEMU 是如何接收一条指令的**。一条新指令从测试程序里的 `.insn` 开始，进入 CPU 类型的 feature 集合，再经过 decodetree 解码、`trans_*` 翻译、helper 执行，最后才体现在测试结果里。

这类任务最稳的做法不是一次写完 10 条指令，而是先挑一条语义最清晰的题，比如 `dma`，把整条链路打通。链路一旦通了，后面的 `sort`、`crush`、`expand`、`vrelu`、`vscale`、`vadd`、`gemm`、`vdot`、`vmax` 大多是在重复同一个结构。

## Beginner

### 先不要急着改代码：先确定链路

第一步不是打开 `target/riscv/` 硬改，而是先看测试和实验手册：

- 测试告诉你：
  - 指令编码长什么样
  - 调用参数顺序是什么
  - 最终结果如何比对
- 手册告诉你：
  - `rd`、`rs1`、`rs2` 在这条自定义指令里分别表示什么
  - 是否写回寄存器，还是只读写内存
  - 边界条件是什么

这两者合起来，才是“规格”。

### 我是怎么找到改动点的

我用的是一条固定逆向路径：

1. 从测试文件开始
2. 找测试运行在哪台 machine 上
3. 找 machine 默认用的 CPU type
4. 找 CPU type 的 feature 配置
5. 找 RISC-V 解码和翻译入口
6. 对照仓库里已有 vendor extension 的组织方式
7. 再决定新文件该建在哪里

这比全文搜索某个名字更可靠，因为它直接沿着执行路径找。

### 每类文件分别负责什么

可以把改动点按职责分成五层：

1. **CPU 能力层**
   - 例如 `cpu_cfg_fields.h.inc`、`cpu_cfg.h`、`cpu.c`
   - 作用：告诉 QEMU “这颗 CPU 支持这个扩展”

2. **编码描述层**
   - 例如 `xg233ai.decode`
   - 作用：告诉 decodetree “哪些 bit pattern 对应哪些指令”

3. **翻译层**
   - 例如 `trans_xg233ai.c.inc`
   - 作用：把一条 guest 指令转换成 TCG 操作或 helper 调用

4. **执行语义层**
   - 例如 `xg233ai_helper.c`
   - 作用：真正实现指令行为

5. **构建接线层**
   - 例如 `meson.build`、`translate.c`、`helper.h`
   - 作用：把新 decoder、新 helper、新翻译逻辑接进构建和运行路径

### 为什么先单题打通再铺开全部指令

因为第一题验证的是“框架接线是否正确”，而不是“所有语义是否都对”。如果第一条指令都没跑通，你同时写 10 条，出问题时你不知道是：

- CPU feature 没开
- decoder 没注册
- `trans_*` 没被调用
- helper 没声明
- helper 语义错了

所以先用 `dma` 这种输入输出最直观的题，把链路打通，是最省时间的策略。

## Expert

### 定位改动点的方法论：从测试反推实现

以 `test-insn-dma.c` 为例，测试里有：

```c
.insn r 0x7b, 6, 6, %0, %1, %2
```

这已经足够提取第一批关键信息：

- 这是 `R-type`
- `opcode = 0x7b`
- `funct3 = 6`
- `funct7 = 6`

然后顺着测试框架找：

- `tests/gevico/tcg/riscv64/Makefile.softmmu-target`
  - 确认测试跑在 `-M g233`
- `hw/riscv/g233.c`
  - 确认默认 CPU type 是 `TYPE_RISCV_CPU_GEVICO_CV1`
- `target/riscv/cpu.c`
  - 确认这颗 CPU 的 feature 集合

这一步得出的结论是：如果不先给 `gevico-cpu-v1` 加扩展开关，后面哪怕 decoder 写对了，也不一定能走到新逻辑。

### 为什么要加 CPU feature 开关

QEMU 不是“文件存在就代表扩展可用”。RISC-V 这套代码有明确的 feature gating：

- CPU 配置结构里有 `ext_*` 布尔值
- decoder table 可以按 feature 条件启用
- `trans_*` 里通常还会二次 `REQUIRE_*`

所以要先做三件事：

1. 在 `cpu_cfg_fields.h.inc` 加 `ext_xg233ai`
2. 在 `cpu_cfg.h` 暴露 `has_xg233ai_p`
3. 在 `cpu.c` 里把它加入 vendor extension 列表，并给 `gevico-cpu-v1` 默认打开

这相当于先把“这组指令是这个 CPU 的一部分”这件事建模出来。

### 怎么知道 decodetree 要怎么写

这不是猜语法，而是直接向 QEMU 现有 decode 文件学。

参考来源有两个：

1. `target/riscv/insn32.decode`
   - 学字段定义、argument set、`@r` 格式模板怎么写
2. 现有 vendor extension
   - `xthead.decode`
   - `xmips.decode`
   - `XVentanaCondOps.decode`

实验手册给的是“架构规格”：

- `opcode = 1111011`
- `funct3 = 110`
- 10 条指令靠 `funct7` 区分

QEMU decodetree 需要的是“位模式描述”：

```text
dma   0000110 ..... ..... 110 ..... 1111011 @r
sort  0010110 ..... ..... 110 ..... 1111011 @r
crush 0100110 ..... ..... 110 ..... 1111011 @r
```

也就是说：**手册描述的是语义编码，decodetree 描述的是 bit pattern**。两者之间的映射，是通过观察现有 `.decode` 文件学会的。

### 怎么把手册规格翻译成 `trans_*` 和 helper

一条指令要拆成两层看：

1. **翻译层**
   - 从 `a->rd`、`a->rs1`、`a->rs2` 取参数
   - 决定是直接生成 TCG，还是调 helper

2. **执行层**
   - 真正实现规格里的伪代码

基础实验里，helper-first 是最稳的。因为这些题大量涉及：

- guest 内存读写
- 固定长度循环
- byte/int32/float32 混合元素宽度
- 原地更新或结果写回

直接用 helper 可以快速对齐规格，而不必一开始就优化成纯 TCG IR。

### QEMU 中一条自定义指令的最小实现模板

最小模板通常长这样：

1. **在 `.decode` 里定义编码**
2. **在 `trans_xxx.c.inc` 里写 `trans_*`**
   - 读参数
   - `REQUIRE_*`
   - `decode_save_opc(ctx, 0)`
   - `gen_helper_*`
3. **在 `helper.h` 声明 helper**
4. **在 `xxx_helper.c` 实现语义**
5. **在 `meson.build` 和 `translate.c` 接线**

如果是像 `dma`、`sort`、`crush` 这种题，这个模板已经够用了。

### 这类实验最容易写错的地方

#### 1. 把 `rd` 误当“结果寄存器”

这些题虽然编码上是 R-type，但语义上很多不是普通算术指令。比如：

- `dma`
  - `rd` 是目标地址
- `sort`
  - `rd` 是排序长度 `K`
- `crush`
  - `rd` 是目标地址

所以一定要以手册定义为准，不要以 RISC-V 常规直觉为准。

#### 2. 忘了这是“guest 内存”，不是宿主机数组

helper 里不能拿地址直接强转指针去读，要用 QEMU 的 guest memory access API，比如：

- `cpu_ldl_data_ra`
- `cpu_stl_data_ra`
- `cpu_ldub_data_ra`
- `cpu_stb_data_ra`

这是在 guest 语义下访问内存，不是直接操作宿主进程里的裸指针。

#### 3. 只改了代码，没重编 `qemu-system-riscv64`

TCG 测试命令本身不会保证你已经把 QEMU 主程序重新编好。正确节奏通常是：

```bash
make -C build -j4 qemu-system-riscv64
make -C build/tests/gevico/tcg/riscv64-softmmu run-insn-dma
```

#### 4. 一开始就想做优化

基础实验的主要目标是：

- 语义正确
- 测试通过
- 理解解码和翻译链路

不是一上来就做纯 TCG IR 内联。优化可以放到进阶实验。

### 可复用的工作流

可以把这类任务抽象成一个固定工作流：

1. 读测试文件
2. 读规格手册
3. 提取编码常量和参数角色
4. 找测试 machine 和 CPU type
5. 给 CPU 加 feature
6. 新建 decode 文件并注册
7. 写 `trans_*`
8. 写 helper
9. 重编 QEMU
10. 跑单题
11. 题过了再做下一题

这套流程的优点是：每一步都可验证，出错时定位很快。

## Checklist

- 测试文件里 `.insn` 的编码字段是否已经读清楚
- 手册里 `rd/rs1/rs2` 的语义角色是否已经单独记下来
- CPU feature 是否已加并在目标 CPU 上启用
- decoder 是否已注册到 `translate.c`
- `trans_*` 是否真的被连接进构建
- helper 是否已在 `helper.h` 声明
- helper 是否用 QEMU 的 guest memory API 访问内存
- 是否先跑了单题而不是全套
- 修改后是否重编了 `qemu-system-riscv64`

<!-- source-version: branch ai_try, commit 27de27e, noted at 2026-06-20 22:12:43 CST -->
