# KV Cache、QKV 与 Prefix Caching：基于 nano-vllm 源码的学习笔记

[TOC]

## 引言

本文以 **nano-vllm** 代码库（https://github.com/GeeeekExplorer/nano-vllm，commit `44a51af`）为具体参照，逐行回答一个初学者在理解 LLM 推理加速时最常问的几个问题。每个结论都附带对应代码行号的证明，并且包含完整的代码展示（不省略任何参数）和具体的数值跟踪示例。

本文不假设读者有 Transformer 算法细节经验，但假设读者理解基本的"token → 向量"概念和逐 token 自回归生成的基本流程。

---

## Q1: 推理一个 token 时，Transformer 到底在算什么？

### 完整代码：Qwen3ForCausalLM 的前向路径

从 token ID 输入到下一个 token 概率输出，数据依次经过。我们先看完整的模型前向代码，然后在每个关键点标注张量形状。

**入口**：`nanovllm/models/qwen3.py` 行 205-216：

```python
class Qwen3ForCausalLM(nn.Module):
    def forward(self, input_ids, positions):
        return self.model(input_ids, positions)  # → Qwen3Model.forward()

    def compute_logits(self, hidden_states):
        return self.lm_head(hidden_states)       # 线性投影: hidden_size → vocab_size
```

**Qwen3Model**：行 162-183：

```python
class Qwen3Model(nn.Module):
    def __init__(self, config: Qwen3Config):
        self.embed_tokens = VocabParallelEmbedding(
            config.vocab_size, config.hidden_size             # 例如: [151936, 2048]
        )
        self.layers = nn.ModuleList([
            Qwen3DecoderLayer(config)                         # 例如: 28 层
            for _ in range(config.num_hidden_layers)
        ])
        self.norm = RMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def forward(self, input_ids, positions):
        hidden_states = self.embed_tokens(input_ids)  # ← 张量形状: [seq_len, 2048]
        residual = None
        for layer in self.layers:                      # ← 逐层处理，每层形状不变
            hidden_states, residual = layer(
                positions, hidden_states, residual
            )
        hidden_states, _ = self.norm(hidden_states, residual)  # ← 形状: [seq_len, 2048]
        return hidden_states
```

**Qwen3DecoderLayer**（单层的结构）：行 120-159：

```python
class Qwen3DecoderLayer(nn.Module):
    def __init__(self, config: Qwen3Config):
        self.self_attn = Qwen3Attention(
            hidden_size=config.hidden_size,
            num_heads=config.num_attention_heads,
            num_kv_heads=config.num_key_value_heads,
            max_position=config.max_position_embeddings,
            rms_norm_eps=config.rms_norm_eps,
            qkv_bias=getattr(config, 'attention_bias', True),
            head_dim=getattr(config, 'head_dim', None),
            rope_theta=getattr(config, "rope_theta", 1000000),
            rope_scaling=getattr(config, "rope_scaling", None),
        )
        self.mlp = Qwen3MLP(
            hidden_size=config.hidden_size,
            intermediate_size=config.intermediate_size,
            hidden_act=config.hidden_act,
        )
        self.input_layernorm = RMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.post_attention_layernorm = RMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def forward(self, positions, hidden_states, residual):
        # 层归一化（带残差连接）
        hidden_states, residual = self.input_layernorm(hidden_states, residual)
        # ← 形状: [seq_len, 2048]
        
        # 自注意力
        hidden_states = self.self_attn(positions, hidden_states)
        # ← 形状: [seq_len, 2048]（注意力输出后经 o_proj 投影回 hidden_size）
        
        # 后层归一化 + FFN
        hidden_states, residual = self.post_attention_layernorm(hidden_states, residual)
        hidden_states = self.mlp(hidden_states)
        # ← 形状: [seq_len, 2048]
        return hidden_states, residual
```

**Qwen3Attention**（注意力的完整结构）：行 14-88：

```python
class Qwen3Attention(nn.Module):
    def __init__(
        self,
        hidden_size: int,
        num_heads: int,
        num_kv_heads: int,
        max_position: int = 4096 * 32,
        head_dim: int | None = None,
        rms_norm_eps: float = 1e-06,
        qkv_bias: bool = False,
        rope_theta: float = 10000,
        rope_scaling: dict | None = None,
    ):
        # QKV 融合投影（一个权重矩阵同时产生 Q、K、V）
        self.qkv_proj = QKVParallelLinear(
            hidden_size,
            self.head_dim,
            self.total_num_heads,
            self.total_num_kv_heads,
            bias=qkv_bias,
        )
        # 输出投影（把 attention 输出映射回 hidden_size）
        self.o_proj = RowParallelLinear(
            self.total_num_heads * self.head_dim,
            hidden_size,
            bias=False,
        )
        # RoPE（旋转位置编码）
        if isinstance(rope_scaling, dict):
            rope_theta = rope_scaling.get("rope_theta", rope_theta)
        self.rotary_emb = get_rope(
            self.head_dim,
            rotary_dim=self.head_dim,
            max_position=max_position,
            base=rope_theta,
        )
        # 实际的 Attention 计算
        self.attn = Attention(
            self.num_heads,
            self.head_dim,
            self.scaling,
            self.num_kv_heads,
        )
```

### 数据流总结（张量形状变化）

```
输入: input_ids 形状=[seq_len] （例如 [4]: [今天, 天气, 如何, ？]）
      positions  形状=[seq_len] （例如 [4]: [0, 1, 2, 3]）

embed_tokens:    [seq_len] → [seq_len, 2048]   ← 查表嵌入
Qwen3Attention:  [seq_len, 2048] → [seq_len, 2048]
  qkv_proj:      [seq_len, 2048] → [seq_len, 2304]   ← QKV 融合投影
  split:         [seq_len, 2304] → Q=[seq_len, 1792], K=[seq_len, 256], V=[seq_len, 256]
  reshape:       Q→[seq_len, 14, 128]  K→[seq_len, 2, 128]  V→[seq_len, 2, 128]
  加 RoPE:      Q,K 被旋转（形状不变）
  attn():       Q×K^T → softmax → ×V → [seq_len, 14, 128]
  o_proj:       [seq_len, 1792] → [seq_len, 2048]
Qwen3MLP:        [seq_len, 2048] → [seq_len, 2048]
  重复 28 层（每层形状均为 [seq_len, 2048]，保持不变）
norm:            [seq_len, 2048] → [seq_len, 2048]
lm_head:         [seq_len, 2048] → [seq_len, vocab_size]   ← 每个位置预测下一个 token
sampler:         [seq_len, vocab_size] → [seq_len]         ← 采样出下一个 token ID
```

---

## Q2: 什么是 KV Cache？它为什么能省计算？

### 问题

LLM 是自回归的：生成 token_1，然后把它拼到输入里生成 token_2，再拼到输入里生成 token_3……

```
Step 1: [今天, 天气, 如何]                     → 预测 "？"
Step 2: [今天, 天气, 如何, ？]                 → 预测 "我"
Step 3: [今天, 天气, 如何, ？, 我]            → 预测 "来"
Step 4: [今天, 天气, 如何, ？, 我, 来]       → 预测 "帮"
```

**没有 KV Cache**：Step 4 要重新计算"今天""天气""如何""？""我"的 K 和 V——尽管它们完全没变过。

**有 KV Cache**：Step 1 算一次并存下来，Step 2-4 只算新 token 的 K 和 V，旧的直接复用。

### 完整的代码证明

在 `nanovllm/layers/attention.py` 行 43-75，`Attention` 类完整如下：

```python
class Attention(nn.Module):

    def __init__(self, num_heads, head_dim, scale, num_kv_heads):
        super().__init__()
        self.num_heads = num_heads
        self.head_dim = head_dim
        self.scale = scale
        self.num_kv_heads = num_kv_heads
        self.k_cache = self.v_cache = torch.tensor([])  # ← 初始为空 tensor

    def forward(self, q: torch.Tensor, k: torch.Tensor, v: torch.Tensor):
        context = get_context()
        k_cache, v_cache = self.k_cache, self.v_cache

        # 不管 prefill 还是 decode，先把本轮 k,v 写入 KV Cache
        if k_cache.numel() and v_cache.numel():
            store_kvcache(k, v, k_cache, v_cache, context.slot_mapping)
            # ↑ k 形状: [seq_len, num_kv_heads, head_dim]
            # ↑ v 形状: [seq_len, num_kv_heads, head_dim]
            # ↑ slot_mapping: [seq_len] — 每个 token 在 cache 中的位置

        if context.is_prefill:
            # ── Prefill 阶段 ──
            # 用原始 k,v 做 attention（它们刚算出来的）
            # 如果启用了 prefix cache，k,v 会被替换
            if context.block_tables is not None:    # prefix cache
                k, v = k_cache, v_cache
            o = flash_attn_varlen_func(
                q, k, v,
                max_seqlen_q=context.max_seqlen_q,
                cu_seqlens_q=context.cu_seqlens_q,
                max_seqlen_k=context.max_seqlen_k,
                cu_seqlens_k=context.cu_seqlens_k,
                softmax_scale=self.scale,
                causal=True,
                block_table=context.block_tables,  # prefix cache 时非 None
            )
        else:
            # ── Decode 阶段 ──
            # q.unsqueeze(1): 加上序列维度 [1, num_heads, head_dim]
            # k_cache, v_cache: 包含所有之前 token 的 K/V
            o = flash_attn_with_kvcache(
                q.unsqueeze(1),
                k_cache,
                v_cache,
                cache_seqlens=context.context_lens,    # 每个序列已缓存的长度
                block_table=context.block_tables,       # 所有序列的 block_table
                softmax_scale=self.scale,
                causal=True,
            )
        return o
```

**关键观察**：

| 阶段 | Q 的来源 | K 的来源 | V 的来源 | 计算量 |
|------|---------|---------|---------|-------|
| Prefill | 所有 input tokens（刚计算的） | 所有 input tokens（刚计算的） | 所有 input tokens（刚计算的） | O(n²) — 一次性处理整个 prompt |
| Decode step t | 第 t 个新 token（刚计算的） | **所有之前的 tokens（从 Cache 读取）** | **所有之前的 tokens（从 Cache 读取）** | O(n) — 每步只处理 1 个新 token |

### 为什么 KV Cache 能节省计算？一个具体数值例子

假设有 1000 个 token 的 prompt，生成 100 个新 token：

| 方案 | Step 1 (Prefill) | 每个 Decode 步骤 | 总计算量 |
|------|-----------------|-----------------|---------|
| 无 KV Cache | 计算 1000 个 K/V | 重新计算全部 (1000 + t) 个 K/V | ~1,050,000 次 K/V 计算 |
| 有 KV Cache | 计算 1000 个 K/V | 只计算 1 个新 K/V，复用 1000 个 | 只计算 **1100** 次 K/V |

**节省约 1000 倍**（生成越长，收益越大）。

### Q: 为什么不缓存 Q？

每一步的"当前 token"都不同，所以每步的 Q 都是**全新计算**的。Q 只有"现在"有用，没有未来复用的价值。

---

## Q3: Q、K、V 到底是什么？它们从哪来、到哪去？

### 概念：注意力即"检索"

Transformer 中的缩放点积注意力（Scaled Dot-Product Attention）可以理解为一次**检索操作**：

```
你（Q）在图书馆查资料，书架上每本书都有一个标签（K）和实际内容（V）。
你的借书条（Q）和所有标签（K）逐个比对 → 相关度分数 → softmax 归一化 → 挑出最相关的书 → 综合它们的内容（V）带走。
```

数学上：
```
Attention(Q, K, V) = softmax(Q × K^T / √d) × V
   Q: [seq_len, head_dim] 或 [batch, seq_len, head_dim]
   K: [seq_len, head_dim]
   V: [seq_len, head_dim]
   输出: [seq_len, head_dim]
```

### 从 hidden_state 到 Q、K、V——完整的矩阵乘法跟踪

我们用一个**简化但带真实维度的例子**。设 Qwen3-0.6B 参数：`hidden_size=2048`, `head_dim=128`, `num_heads=14`, `num_kv_heads=2`。

**Step 1: QKV 融合投影**

代码 `nanovllm/models/qwen3.py` 行 77-81：

```python
# hidden_states 形状: [seq_len, 2048]，例如 [4, 2048]（4 个 token）
qkv = self.qkv_proj(hidden_states)
# qkv_proj 的权重形状: [2304, 2048]（由 QKVParallelLinear 构造）
# qkv 形状: [4, 2304]
#   qkv[0] = 第 0 个 token "今天"的 QKV 融合向量（2304 维）
#   qkv[1] = 第 1 个 token "天气"的 QKV 融合向量
#   qkv[2] = 第 2 个 token "如何"的 QKV 融合向量
#   qkv[3] = 第 3 个 token "？"的 QKV 融合向量

# 拆成 Q、K、V 三份
q, k, v = qkv.split(
    [self.q_size, self.kv_size, self.kv_size], dim=-1
)
# q: [4, 1792]    ← 14 heads × 128 = 1792 维
# k: [4, 256]     ← 2 heads × 128 = 256 维
# v: [4, 256]     ← 2 heads × 128 = 256 维

# 拆完后重塑为多头格式
q = q.view(-1, self.num_heads, self.head_dim)
#   → [4, 14, 128]
k = k.view(-1, self.num_kv_heads, self.head_dim)
#   → [4, 2, 128]
v = v.view(-1, self.num_kv_heads, self.head_dim)
#   → [4, 2, 128]
```

**QKVParallelLinear** 的完整定义（`nanovllm/layers/linear.py` 行 96-128）：

```python
class QKVParallelLinear(ColumnParallelLinear):
    def __init__(self, hidden_size, head_size, total_num_heads, total_num_kv_heads, bias=False):
        tp_size = dist.get_world_size()
        total_num_kv_heads = total_num_kv_heads or total_num_heads
        self.head_size = head_size
        self.num_heads = total_num_heads // tp_size       # Q heads 数（本 GPU）
        self.num_kv_heads = total_num_kv_heads // tp_size # KV heads 数（本 GPU）
        # 输出维度 = Q 部分 + K 部分 + V 部分
        # = (total_num_heads + 2 * total_num_kv_heads) * head_size
        output_size = (total_num_heads + 2 * total_num_kv_heads) * self.head_size
        super().__init__(hidden_size, output_size, bias)
        # super().__init__ 调用 LinearBase 构造权重矩阵:
        # self.weight = nn.Parameter(torch.empty(output_size, input_size))
        # 即 self.weight 形状: [2304, 2048]

    def forward(self, x):
        # x: [seq_len, 2048]
        # weight: [2304, 2048]
        # F.linear(x, weight) → [seq_len, 2304]
        return F.linear(x, self.weight, self.bias)
```

**Step 2: QKV 在 Attention 前还经过 RoPE**

代码 `qwen3.py` 行 85：

```python
q, k = self.rotary_emb(positions, q, k)  # ← RoPE 只旋转 Q 和 K，V 不变
```

完整的 RoPE 实现（`rotary_embedding.py` 行 17-48）：

```python
class RotaryEmbedding(nn.Module):
    def __init__(self, head_size, rotary_dim, max_position_embeddings, base):
        # 预计算所有位置的 sin/cos 值
        inv_freq = 1.0 / (base ** (torch.arange(0, rotary_dim, 2, dtype=torch.float) / rotary_dim))
        t = torch.arange(max_position_embeddings, dtype=torch.float)
        freqs = torch.einsum("i,j -> ij", t, inv_freq)  # 外积
        cos = freqs.cos()
        sin = freqs.sin()
        cache = torch.cat((cos, sin), dim=-1).unsqueeze_(1)  # [max_positions, 1, rotary_dim]
        self.register_buffer("cos_sin_cache", cache, persistent=False)

    def forward(self, positions, query, key):
        # positions: [seq_len] — 每个 token 在序列中的位置
        cos_sin = self.cos_sin_cache[positions]   # [seq_len, 1, rotary_dim]
        cos, sin = cos_sin.chunk(2, dim=-1)       # 各 [seq_len, 1, rotary_dim/2]
        query = apply_rotary_emb(query, cos, sin)  # 旋转 Q → 形状不变
        key = apply_rotary_emb(key, cos, sin)      # 旋转 K → 形状不变
        return query, key
```

`apply_rotary_emb` 的完整实现（行 6-14）：

```python
def apply_rotary_emb(x, cos, sin):
    # x: [seq_len, num_heads, head_dim]
    # 将最后 1 维切半
    x1, x2 = torch.chunk(x.float(), 2, dim=-1)  # 各 [seq_len, num_heads, head_dim/2]
    # 旋转公式（二维旋转的推广）
    y1 = x1 * cos - x2 * sin
    y2 = x2 * cos + x1 * sin
    return torch.cat((y1, y2), dim=-1).to(x.dtype)
    # 返回形状: [seq_len, num_heads, head_dim]（不变）
```

**为什么只有 Q 和 K 需要位置信息，V 不需要？**

因为 Attention 分数来自 `Q × K^T`——匹配 Q 和 K 时需要知道 token 间的距离（"谁前谁后"）。而 V 只是被加权求和的"内容"——位置不改变内容本身。

**为什么 RoPE 叫"旋转"？**

对一个 2 维向量 `(x1, x2)`，乘以旋转矩阵 `[[cosθ, -sinθ], [sinθ, cosθ]]` 就是：
```
y1 = x1*cosθ - x2*sinθ
y2 = x1*sinθ + x2*cosθ
```
RoPE 把 `head_dim` 分成 `head_dim/2` 对，每对按不同的 `θ` 旋转（`θ` 由位置决定）。同一 token 在不同位置的 Q/K 向量方向不同——使得 Attention 可以通过点积感知距离。

### QKV 三者的角色总结

| 角色 | 形状（Qwen3-0.6B, 1GPU, 1 个 token） | 语义 | 是否缓存 |
|------|--------------------------------------|------|---------|
| **Q** | [14, 128] | 当前 token 的"查询请求"——它在寻找什么信息 | **不缓存**，每步新算 |
| **K** | [2, 128] | token 的"内容标签"——它有什么信息可供匹配 | **缓存**，永不重算 |
| **V** | [2, 128] | token 的"实际内容"——它携带的信息本身 | **缓存**，永不重算 |

---

## Q4: 一次推理请求的完整生命周期——Prefill 与 Decode

### 整体流程

`LLMEngine.generate()` 驱动整个流程（`nanovllm/engine/llm_engine.py` 行 60-90）：

```python
def generate(self, prompts, sampling_params, use_tqdm=True):
    # 步骤 1: 所有请求入队
    for prompt, sp in zip(prompts, sampling_params):
        self.add_request(prompt, sp)  # → Scheduler.add()

    # 步骤 2: 循环调度直到全部完成
    while not self.is_finished():
        output, num_tokens = self.step()

    # 步骤 3: 收集结果并解码
    outputs = [tokenizer.decode(token_ids) for token_ids in outputs]
    return outputs
```

每次 `step()`（行 49-55）：

```python
def step(self):
    seqs, is_prefill = self.scheduler.schedule()
    # ↑ 返回: 本次要执行的序列列表 + 是否为 prefill 阶段

    num_tokens = (sum(seq.num_scheduled_tokens for seq in seqs)
                  if is_prefill else -len(seqs))

    token_ids = self.model_runner.call("run", seqs, is_prefill)
    # ↑ 执行模型推理

    self.scheduler.postprocess(seqs, token_ids, is_prefill)
    # ↑ 后处理: 追加新 token，更新缓存计数

    outputs = [(seq.seq_id, seq.completion_token_ids)
               for seq in seqs if seq.is_finished]
    return outputs, num_tokens
```

### Scheduler.schedule()：完整的调度逻辑

`nanovllm/engine/scheduler.py` 行 24-76：

```python
def schedule(self) -> tuple[list[Sequence], bool]:
    scheduled_seqs = []
    num_batched_tokens = 0

    # ── 阶段 1: Prefill ──
    # 处理 waiting 队列（等待首次处理的序列）
    while self.waiting and len(scheduled_seqs) < self.max_num_seqs:
        seq = self.waiting[0]
        remaining = self.max_num_batched_tokens - num_batched_tokens

        if remaining == 0 or (not seq.block_table and not self.block_manager.can_allocate(seq)):
            break  # 资源不足

        if not seq.block_table:
            self.block_manager.allocate(seq)
            # ↑ 分配物理 blocks（可能触发 prefix cache 命中）

        # 重算 num_tokens: allocate() 可能更新了 seq.num_cached_tokens
        num_tokens = max(seq.num_tokens - seq.num_cached_tokens, 1)

        if remaining < num_tokens and scheduled_seqs:
            break  # 只允许第一个序列做 chunked prefill

        seq.num_scheduled_tokens = min(num_tokens, remaining)
        if seq.num_scheduled_tokens == num_tokens:
            # 全部被调度 → 移到 running 队列
            seq.status = SequenceStatus.RUNNING
            self.waiting.popleft()
            self.running.append(seq)

        scheduled_seqs.append(seq)
        num_batched_tokens += seq.num_scheduled_tokens

    if scheduled_seqs:
        return scheduled_seqs, True  # is_prefill = True

    # ── 阶段 2: Decode ──
    # waiting 空了，处理 running 队列（正在生成的序列）
    while self.running and len(scheduled_seqs) < self.max_num_seqs:
        seq = self.running.popleft()

        # 检查是否有足够空闲块追加一个 token
        while not self.block_manager.can_append(seq):
            if self.running:
                self.preempt(self.running.pop())  # 抢占其他序列
            else:
                self.preempt(seq)  # 抢占自己（重新调度）
                break
        else:
            seq.num_scheduled_tokens = 1
            self.block_manager.may_append(seq)   # 追加一个 slot
            scheduled_seqs.append(seq)

    assert scheduled_seqs
    # 把已调度的序列放回 running 队列
    self.running.extendleft(reversed(scheduled_seqs))
    return scheduled_seqs, False  # is_prefill = False
```

### Prefill 阶段完整展开

Prefill 发生时，Scheduler 调用了 `BlockManager.allocate(seq)`，然后 `ModelRunner.run(seqs, is_prefill=True)`。

`ModelRunner.run()`（`nanovllm/engine/model_runner.py` 行 215-221）：

```python
def run(self, seqs: list[Sequence], is_prefill: bool) -> list[int]:
    if is_prefill:
        input_ids, positions = self.prepare_prefill(seqs)  # ← 准备输入
    else:
        input_ids, positions = self.prepare_decode(seqs)   # ← 准备输入

    temperatures = self.prepare_sample(seqs) if self.rank == 0 else None
    logits = self.run_model(input_ids, positions, is_prefill)
    # ↑ 模型推理
    token_ids = self.sampler(logits, temperatures).tolist() if self.rank == 0 else None
    reset_context()
    return token_ids
```

**prepare_prefill** 完整代码（行 129-171）：

```python
def prepare_prefill(self, seqs: list[Sequence]):
    input_ids = []
    positions = []
    cu_seqlens_q = [0]
    cu_seqlens_k = [0]
    max_seqlen_q = 0
    max_seqlen_k = 0
    slot_mapping = []
    block_tables = None

    for seq in seqs:
        seqlen = len(seq)
        start = min(seq.num_cached_tokens, seqlen - 1)
        seqlen_q = seq.num_scheduled_tokens
        end = start + seqlen_q
        seqlen_k = end

        # 只收集需要新计算的部分
        input_ids.extend(seq[start:end])
        positions.extend(range(start, end))

        cu_seqlens_q.append(cu_seqlens_q[-1] + seqlen_q)
        cu_seqlens_k.append(cu_seqlens_k[-1] + seqlen_k)
        max_seqlen_q = max(seqlen_q, max_seqlen_q)
        max_seqlen_k = max(seqlen_k, max_seqlen_k)

        if not seq.block_table:    # warmup 时没有 block_table
            continue

        # 计算 slot_mapping: 需要知道哪些物理位置要写入
        start_block = start // self.block_size
        end_block = (end + self.block_size - 1) // self.block_size
        for i in range(start_block, end_block):
            slot_start = seq.block_table[i] * self.block_size
            if i == start_block:
                slot_start += start % self.block_size
            if i != end_block - 1:
                slot_end = seq.block_table[i] * self.block_size + self.block_size
            else:
                slot_end = seq.block_table[i] * self.block_size + end - i * self.block_size
            slot_mapping.extend(range(slot_start, slot_end))

    # 如果有缓存的 token（K 比 Q 长），需要 block_tables
    if cu_seqlens_k[-1] > cu_seqlens_q[-1]:    # prefix cache
        block_tables = self.prepare_block_tables(seqs)

    # 全部搬到 GPU
    input_ids = torch.tensor(input_ids, dtype=torch.int64, pin_memory=True).cuda(non_blocking=True)
    positions = torch.tensor(positions, dtype=torch.int64, pin_memory=True).cuda(non_blocking=True)
    cu_seqlens_q = torch.tensor(cu_seqlens_q, dtype=torch.int32, pin_memory=True).cuda(non_blocking=True)
    cu_seqlens_k = torch.tensor(cu_seqlens_k, dtype=torch.int32, pin_memory=True).cuda(non_blocking=True)
    slot_mapping = torch.tensor(slot_mapping, dtype=torch.int32, pin_memory=True).cuda(non_blocking=True)

    # 通过全局 context 传递给 Attention 层
    set_context(
        True,                    # is_prefill
        cu_seqlens_q,
        cu_seqlens_k,
        max_seqlen_q,
        max_seqlen_k,
        slot_mapping,
        None,                    # context_lens（prefill 不用）
        block_tables,
    )
    return input_ids, positions
```

### Decode 阶段完整展开

**prepare_decode** 完整代码（行 173-189）：

```python
def prepare_decode(self, seqs: list[Sequence]):
    input_ids = []
    positions = []
    slot_mapping = []
    context_lens = []

    for seq in seqs:
        input_ids.append(seq.last_token)                         # ← 只取最后一个 token
        positions.append(len(seq) - 1)                            # ← 它的位置
        context_lens.append(len(seq))                             # ← 已缓存的长度（包含当前步）
        slot_mapping.append(
            seq.block_table[-1] * self.block_size +
            seq.last_block_num_tokens - 1
        )                                                         # ← 它要写入的 slot

    input_ids = torch.tensor(input_ids, dtype=torch.int64, pin_memory=True).cuda(non_blocking=True)
    positions = torch.tensor(positions, dtype=torch.int64, pin_memory=True).cuda(non_blocking=True)
    slot_mapping = torch.tensor(slot_mapping, dtype=torch.int32, pin_memory=True).cuda(non_blocking=True)
    context_lens = torch.tensor(context_lens, dtype=torch.int32, pin_memory=True).cuda(non_blocking=True)
    block_tables = self.prepare_block_tables(seqs)

    set_context(
        False,                   # is_prefill
        slot_mapping=slot_mapping,
        context_lens=context_lens,
        block_tables=block_tables,
    )
    return input_ids, positions
```

### 完整数值例子：Prefill "今天天气如何"

设 `block_size = 4`（为便于演示），`block_table` 包含两个块: `[3, 7]`（物理块 3 和 7）。

序列"今天天气如何"长度 = 4 token。没有 prefix cache → `num_cached_tokens = 0`。

**prepare_prefill 的计算过程**：

```
seqlen = 4
start = min(0, 3) = 0          # 从第一个 token 开始
seqlen_q = 4                    # 4 个 token 都要计算
end = 0 + 4 = 4
seqlen_k = 4

input_ids = seq[0:4] = [token_今天, token_天气, token_如何, token_？]
positions = range(0, 4) = [0, 1, 2, 3]

slot_mapping 计算:
  start_block = 0 // 4 = 0
  end_block = (4 + 3) // 4 = 1
  i = 0:
    slot_start = block_table[0] * 4 = 3 * 4 = 12
    (i == start_block, 不加偏移)
    (i != end_block - 1, 所以 slot_end = 12 + 4 = 16)
    slot_mapping.extend(range(12, 16)) = [12, 13, 14, 15]

结果:
  input_ids = [今天_ID, 天气_ID, 如何_ID, ？_ID]
  positions = [0, 1, 2, 3]
  slot_mapping = [12, 13, 14, 15]
  cu_seqlens_q = [0, 4]
  cu_seqlens_k = [0, 4]
  max_seqlen_q = 4
  max_seqlen_k = 4
  block_tables = None  ← 因为 cu_seqlens_k[-1] == cu_seqlens_q[-1]，没有 prefix cache
```

在 `Attention.forward()` 中：
1. `store_kvcache` 根据 `slot_mapping = [12,13,14,15]` 把每个 token 的 K/V 写入物理块 3（slots 12-15）
2. `flash_attn_varlen_func(q, k, v, softmax_scale=self.scale, causal=True, block_table=None, max_seqlen_q=4, cu_seqlens_q=[0,4], max_seqlen_k=4, cu_seqlens_k=[0,4])` 计算 attention

### 完整数值例子：Decode 一步（生成第 5 个 token）

序列现在有 5 个 token `[今天, 天气, 如何, ？, 我]`，block_table = `[3, 7]`（仍在物理块 3 和 7 中）。

`block_size = 4`，所以：
- Block 0（物理块 3）：token 0-3
- Block 1（物理块 7）：到目前为止只有 token 4"我"

`last_block_num_tokens = 5 - 4 = 1`

**prepare_decode 的计算过程**：

```
input_ids = [token_我]                          # seq.last_token
positions = [4]                                 # len(seq) - 1 = 4
context_lens = [5]                              # len(seq) = 5
slot_mapping = [
  seq.block_table[-1] * block_size + seq.last_block_num_tokens - 1
  = 7 * 4 + 1 - 1 = 28                          # 写入物理块 7 的 slot 0
]

block_tables:
  max_len = 2
  block_tables = [[3, 7]]  # padding 成 2 列
```

在 `Attention.forward()` 中：
1. `store_kvcache` 根据 `slot_mapping = [28]` 把 token_我 的 K/V 写入物理块 7 的 slot 28
2. `flash_attn_with_kvcache(q.unsqueeze(1), k_cache, v_cache, cache_seqlens=context.context_lens, block_table=context.block_tables, softmax_scale=self.scale, causal=True)` 中：
   - q: 新 token"我"的 Q [1, num_heads, head_dim]
   - k_cache: 所有缓存的 K [num_blocks, block_size, kv_heads, head_dim]
   - v_cache: 所有缓存的 V [num_blocks, block_size, kv_heads, head_dim]
   - block_table: [3, 7] — 告诉 flash_attn 从物理块 3 和 7 按顺序读取 K/V
   - context_lens: [5] — 告诉 flash_attn 前 5 个 token 是有效内容
   - Attention 用 Q 与全部 5 个 K 做点积 → softmax → 加权 5 个 V → 输出

### 两个阶段对比总结

| | Prefill | Decode |
|---|---|---|
| 处理 token 数 | 整个 prompt（或 chunk） | 每步 1 个新 token |
| 计算 QKV | 所有输入 token 并行计算 | 只算 1 个 token |
| Attention 计算 | `flash_attn_varlen_func(q原始, k原始, v原始, causal=True)` | `flash_attn_with_kvcache(q新, k_cache, v_cache)` |
| 计算复杂度 | O(n²) | O(n) — n 是已缓存的总 token 数 |
| 调用频率 | 每个序列**一次** | 每个生成 token **一次** |
| KV Cache 写入 | 整个 prompt 的 tokens 同时写入 | 每次写入 1 个 token |

---

## Q5: KV Cache 是怎么存储和管理的？

### 物理结构：一个巨大的预分配张量

`nanovllm/engine/model_runner.py` 行 103-121：

```python
def allocate_kv_cache(self):
    config = self.config
    hf_config = config.hf_config

    # 获取当前 GPU 显存状态
    free, total = torch.cuda.mem_get_info()
    used = total - free
    peak = torch.cuda.memory_stats()["allocated_bytes.all.peak"]
    current = torch.cuda.memory_stats()["allocated_bytes.all.current"]

    # 计算每个 KV head 的维度
    num_kv_heads = hf_config.num_key_value_heads // self.world_size
    head_dim = getattr(
        hf_config, "head_dim",
        hf_config.hidden_size // hf_config.num_attention_heads
    )
    # head_dim: 通常是 hidden_size / num_attention_heads，例如 2048/14=128
    # 但也可以被 hf_config.head_dim 覆盖（Qwen3 中 head_dim 是显式配置的 128）

    # 每个物理 block 占用的显存（字节）
    block_bytes = (
        2                                              # K 和 V 各一份
        * hf_config.num_hidden_layers                  # 每层一个独立的 KV Cache
        * self.block_size                              # 每块容纳 token 数（默认 256）
        * num_kv_heads                                 # KV head 数
        * head_dim                                     # 每个 head 的维度
        * hf_config.dtype.itemsize                     # 每个元素的字节数（float16=2, bfloat16=2）
    )

    # 可分配的 block 数 = 可用显存 / 每 block 字节数
    config.num_kvcache_blocks = (
        int(total * config.gpu_memory_utilization      # 显存总量 × 利用率（默认 0.9）
            - used                                      # 已使用的显存
            - peak + current)                           # 释放在峰值和当前之间的显存
        // block_bytes
    )
    assert config.num_kvcache_blocks > 0

    # 预分配 KV Cache 张量
    self.kv_cache = torch.empty(
        2,                                    # 0 = K 的存储，1 = V 的存储
        hf_config.num_hidden_layers,          # 每层独立缓存，例如 28 层
        config.num_kvcache_blocks,            # 物理块数，例如 1234 块
        self.block_size,                      # 每块 token 数，默认 256
        num_kv_heads,                         # KV head 数，例如 2
        head_dim,                             # 每个 head 的维度，例如 128
    )
    # tf 形状: [2, 28, 1234, 256, 2, 128]

    # 分发给每个 Attention 层
    layer_id = 0
    for module in self.model.modules():
        if hasattr(module, "k_cache") and hasattr(module, "v_cache"):
            # k_cache: [num_blocks, block_size, kv_heads, head_dim] = [1234, 256, 2, 128]
            module.k_cache = self.kv_cache[0, layer_id]
            module.v_cache = self.kv_cache[1, layer_id]
            layer_id += 1
```

### 完整数值例子：显存分配计算

Qwen3-0.6B, batch_size=1, GPU 8GB, `gpu_memory_utilization=0.9, block_size=256`：

```
hidden_layers = 28
num_kv_heads = 2
head_dim = 128
dtype = float16 → itemsize = 2

每个 block 占用:
  block_bytes = 2 × 28 × 256 × 2 × 128 × 2 = 7,340,032 字节 ≈ 7 MB

可用显存（假设）:
  total = 8 GB = 8,589,934,592 字节
  gpu_memory_utilization=0.9 → 7,730,941,132 字节
  假设 used + peak - current ≈ 2 GB → 剩余 ≈ 5,730,941,132 字节

num_kvcache_blocks ≈ 5,730,941,132 / 7,340,032 ≈ 780 块
780 块 × 256 个 token/块 = 199,680 token 的最大 KV Cache 容量
```

### 逻辑管理：BlockManager

**Block** 类（`nanovllm/engine/block_manager.py` 行 8-23）：

```python
class Block:
    def __init__(self, block_id):
        self.block_id = block_id      # 物理块编号（范围: 0 到 num_blocks-1 的整数）
        self.ref_count = 0            # 引用计数——被多少个序列共享
        self.hash = -1                # 哈希值——用于 prefix cache 匹配
        self.token_ids = []           # 该块缓存内容对应的 token IDs

    def update(self, hash: int, token_ids: list[int]):
        self.hash = hash
        self.token_ids = token_ids

    def reset(self):
        self.ref_count = 1            # 新分配时 ref_count = 1（占用者自己）
        self.hash = -1
        self.token_ids = []
```

**BlockManager** 类（行 26-33）：

```python
class BlockManager:
    def __init__(self, num_blocks: int, block_size: int):
        self.block_size = block_size
        self.blocks: list[Block] = [Block(i) for i in range(num_blocks)]
        self.hash_to_block_id: dict[int, int] = dict()
        # ↑ 哈希值 → 物理块号（用于 prefix cache 查找）
        self.free_block_ids: deque[int] = deque(range(num_blocks))
        # ↑ 空闲块队列（FIFO）
        self.used_block_ids: set[int] = set()
        # ↑ 已使用的块集合
```

### slot_mapping 完整数值例子

以 prefill 为例，序列有 5 个 token，block_table = `[3, 7]`，block_size = 4。

```
seq.block_table = [3, 7]

Block 0（物理块 3）: slots 12-15（3*4=12, 3*4+3=15）
Block 1（物理块 7）: slots 28-31（7*4=28, 7*4+3=31）

token 0 → slot 12（block_table[0] * 4 + 0）
token 1 → slot 13（block_table[0] * 4 + 1）
token 2 → slot 14（block_table[0] * 4 + 2）
token 3 → slot 15（block_table[0] * 4 + 3）
token 4 → slot 28（block_table[1] * 4 + 0）
```

**decode 时的 slot_mapping**（`prepare_decode` 行 182）：

```python
slot_mapping.append(
    seq.block_table[-1] * self.block_size + seq.last_block_num_tokens - 1
)
```

以上面的序列为例，生成了 5 个 token：
```
block_table = [3, 7]
block_size = 4
last_block_num_tokens = 5 - 4 = 1  （物理块 7 中已有 1 个 token）

slot = block_table[-1] * block_size + last_block_num_tokens - 1
     = 7 * 4 + 1 - 1
     = 28

所以下一个新 token 要写入 slot 29。
```

### block_table：序列的页表

每个 `Sequence` 维护一个 `block_table`（`nanovllm/engine/sequence.py` 行 27）：

```python
self.block_table = []  # 整数列表，例如 [3, 7, 15]: 第 0 块在物理块 3，第 1 块在物理块 7
```

**类比：虚拟内存分页**

| 操作系统 | vLLM KV Cache |
|---------|---------------|
| 虚拟地址空间 | 序列的逻辑 token 位置（从 0 开始连续递增编号） |
| 物理帧（page） | 物理块（physical block） |
| 页表（page table） | block_table: `[物理块号]` |
| 缺页中断 | 需要分配新的 block |
| 页面共享 | 多个序列的 block_table 指向同一物理块（prefix cache） |

例如序列 A 和 B 共享前 2 个 blocks：

```
序列 A: block_table = [3, 7, 15]        ← 物理块 3, 7 独享
序列 B: block_table = [3, 7, 22, 31]    ← 和 A 共享物理块 3, 7
                          ↑  shared  ↑
```

---

## Q6: vLLM 的 Prefix Caching 到底是什么？和 API 提供商的"缓存命中"是一回事吗？

### 两种 KV Cache 的区别

**Runtime KV Cache**（Q2-Q5 讨论的）：**同一次 generate() 调用内部**，decode 阶段复用 prefill 阶段算好的 K/V。这是**每次推理都发生**的。

**Prefix Caching**（也叫 Automatic Prefix Caching）：**不同 generate() 调用之间**，如果请求共享完全相同的 token 前缀，复用之前计算过的 K/V。

### 代码证明：基于精确的 xxhash(token_IDs) 匹配

`nanovllm/engine/block_manager.py` 行 35-41：

```python
@classmethod
def compute_hash(cls, token_ids: list[int], prefix: int = -1):
    h = xxhash.xxh64()
    # 链式哈希：把前一个 block 的哈希值也混入当前 block 的哈希
    if prefix != -1:
        h.update(prefix.to_bytes(8, "little"))
    # 把当前 block 的 token IDs 的原始字节混入哈希
    h.update(np.array(token_ids).tobytes())
    return h.intdigest()
```

**关键设计决策**：
- 使用 `xxhash.xxh64()`，一个**非加密哈希**，速度极快（纳秒级）
- 输入的是**原始 token ID 的字节序列**（`np.array(token_ids).tobytes()`）
- **没有语义理解、没有 embedding 对比、没有 NLP 处理**
- 可选的 `prefix` 参数实现哈希链

### 哈希链（Hash Chain）完整展开

完整 `allocate()` 代码（行 59-82）：

```python
def allocate(self, seq: Sequence):
    assert not seq.block_table          # 序列刚开始，还没有 block 映射
    h = -1                              # ← 初始哈希值 = -1
    cache_miss = False

    for i in range(seq.num_blocks):
        token_ids = seq.block(i)        # 取第 i 块的 token IDs（list[int]）

        # 计算哈希：只有完整块才参与缓存，最后不满的块 hash = -1
        if len(token_ids) == self.block_size:
            h = self.compute_hash(token_ids, h)  # ← 链式：依赖前一个 h
        else:
            h = -1                       # ← 不完整块不参与缓存

        block_id = self.hash_to_block_id.get(h, -1)
        # ↑ 查哈希表：已有同样内容的块吗？

        # 双重验证：哈希匹配 + 内容精确匹配（防哈希碰撞）
        if block_id == -1 or self.blocks[block_id].token_ids != token_ids:
            cache_miss = True             # ← 一旦 miss，后续所有块都 miss

        if cache_miss:
            # 分配新的物理块
            block_id = self.free_block_ids[0]
            block = self._allocate_block(block_id)
        else:
            # ← 命中缓存！
            seq.num_cached_tokens += self.block_size  # 跳过这些 token 的 KV 计算
            if block_id in self.used_block_ids:
                # 块已被使用 → 共享（引用计数 +1）
                block = self.blocks[block_id]
                block.ref_count += 1
            else:
                # 块在 hash_to_block_id 中但 unused（被释放过 → 重新激活）
                block = self._allocate_block(block_id)

        # 如果是完整块，更新哈希映射
        if h != -1:
            block.update(h, token_ids)
            self.hash_to_block_id[h] = block_id

        seq.block_table.append(block_id)  # ← 记录到序列的页表
```

哈希链的实际含义：

```
hash_0 = xxhash(                 token_ids_of_block_0 )
hash_1 = xxhash(hash_0 +         token_ids_of_block_1 )
hash_2 = xxhash(hash_1 +         token_ids_of_block_2 )
```

**Block i 能匹配的前置条件**：Block 0 ~ Block i 的 token IDs **全部逐字节相同**。因为：
- 如果 Block 2 有 1 个 token 不同 → hash_2 不同
- 即使 Block 3 的内容完全相同 → hash_3 需要依赖于 hash_2 → 也不同
- 所以 Block 3 永远不可能在 Block 2 miss 的情况下命中

### 完整的数值例子：哈希匹配 vs 不匹配

```
block_size = 4

请求 A 的 token 序列（被缓存过）:
  索引: 0      1      2      3   |   4      5      6      7
  token: 今天   天气   如何   ？   |   我    来     帮     你
  
  Block 0: [今天, 天气, 如何, ？]   → hash_A0 = 0x7A3F1C8B
  Block 1: [我, 来, 帮, 你]        → hash_A1 = xxhash(0x7A3F1C8B + [我,来,帮,你])
                                    → hash_A1 = 0xB2E1D94A
  已写入 hash_to_block_id:
    {0x7A3F1C8B: block_id_A0, 0xB2E1D94A: block_id_A1}

请求 B: "今天天气如何"（完全相同的 prompt）
  Block 0: [今天, 天气, 如何, ？] → hash_B0 = 0x7A3F1C8B ✓ 匹配
    num_cached_tokens += 4
  Block 1: [我, 来, 帮, 你]       → hash_B1 = xxhash(0x7A3F1C8B + [我,来,帮,你])
                                   = 0xB2E1D94A ✓ 匹配
    num_cached_tokens += 4
  → 8 个 token 全部命中缓存，零计算

请求 C: "今天天气好吗"（1 个 token 不同）
  Block 0: [今天, 天气, 好吗, ？] → hash_C0 = xxhash([今天,天气,好吗,？])
                                   = 0xD5E8F231 ✗ 不匹配（因为"好吗"≠"如何"）
    → cache_miss = True
    → 新分配物理块（不再检查 hash_to_block_id）
  Block 1: 因 cache_miss 已为 True → 不检查哈希，直接新分配
  → 0 个 token 命中（Block 0 不同导致第一个 block 就 miss，后续全部新分配）

请求 D: "教我怎样使用工具"（完全不同）
  Block 0: [教我, 怎样, 使用, 工具] → hash_D0 = 完全不同 ✗
  → 0 个 token 命中
```

### 最后一块永远不参与缓存

行 65：

```python
h = self.compute_hash(token_ids, h) if len(token_ids) == self.block_size else -1
```

如果一个 block 不满 256 个 token（序列的最后一块），`h = -1`：
- `hash_to_block_id.get(-1, -1)` 返回 -1 → **永远不会命中**
- 行 79 `if h != -1` 不成立 → **永远不会被写入 hash_to_block_id**

所以 Prefix Cache 只缓存 **完整填满的 block**。

### Prefix Cache 在 Attention 中的激活条件

在 `prepare_prefill`（`model_runner.py` 行 163-164）：

```python
if cu_seqlens_k[-1] > cu_seqlens_q[-1]:    # ← prefix cache 条件
    block_tables = self.prepare_block_tables(seqs)
```

`cu_seqlens_q[-1]` 是所有 sequence 的 Q 长度之和（即需要新计算的 token 数）。
`cu_seqlens_k[-1]` 是所有 sequence 的 K 长度之和（即参与 attention 的总 token 数，包括已被缓存的）。

**当 cu_seqlens_k[-1] > cu_seqlens_q[-1]，意味着有些 K 来自缓存**。

然后在 `attention.py` 行 65-66：

```python
if context.block_tables is not None:    # ← prefix cache 激活
    k, v = k_cache, v_cache             # ← 用完整的缓存 K/V 替换 k,v
```

然后 `flash_attn_varlen_func` 使用：
- q: 当前输入（新 token）的 Q
- k: **缓存中的全部 K**（包括所有之前缓存的 token）
- v: **缓存中的全部 V**
- block_table: 用于从分散的物理块中连续读取 K/V

**注意**：这里 k 和 v 变量被替换为指向整个 k_cache/v_cache 的引用。所以 flash_attn 读到的 K/V 包含了**所有历史 token + 当前这一步的新 token**（因为 `store_kvcache` 已经在新 token 被计算出来后就写入了缓存）。

### 那么 API 提供商说的"缓存命中"是什么？

**两者本质上是同一机制在两层抽象上的体现**。

| | Runtime KV Cache（vLLM 引擎内部） | Prefix Cache（API 提供商"缓存命中"） |
|---|---|---|
| **范围** | 同一次 generate() 调用内的 decode 步骤 | 不同 generate() 调用之间 |
| **复用对象** | 同一请求中之前步骤算过的 K/V | 不同请求中共享的 token 前缀的 K/V |
| **判断条件** | 无条件——每个 token 的 K/V 都自动缓存 | 精确哈希匹配（token IDs 逐字节相同） |
| **生命周期** | 到本次推理结束 | 到物理块的 ref_count 降到 0 |
| **对用户透明** | 完全自动，无需关注 | 部分透明——API 提供商据此决定是否打折计费 |

**API 提供商"缓存命中"在 vLLM 中的对应实现**：

当多个用户请求共享相同的 system prompt 时：

```
请求 A: "[system: 你是一个有用的助手，你可以使用以下工具：get_weather, search_web, calculator，如果用户询问天气，请调用 get_weather 工具查询后回答]" + "今天天气如何"
请求 B: "[system: 你是一个有用的助手，你可以使用以下工具：get_weather, search_web, calculator，如果用户询问天气，请调用 get_weather 工具查询后回答]" + "告诉我一个笑话"
           ↑← system prompt 的 blocks →→→→ 完全相同！

hash_to_block_id 中已有 system prompt 的哈希映射：
  block 0: hash_0 → physical block PA (ref_count = 1 来自 A)
  block 1: hash_1 → physical block PB (ref_count = 1 来自 A)
  block 2: hash_2 → physical block PC (ref_count = 1 来自 A)
  block 3: hash_3 → physical block PD (ref_count = 1 来自 A)

请求 B 的 allocate():
  block 0: hash_B0 == hash_0 ✓ → ref_count++ (ref_count = 2)
  block 1: hash_B1 == hash_1 ✓ → ref_count++ (ref_count = 2)
  block 2: hash_B2 == hash_2 ✓ → ref_count++ (ref_count = 2)
  block 3: hash_B3 == hash_3 ✓ → ref_count++ (ref_count = 2)
  block 4: hash_B4 不匹配（system prompt 已用尽，这里是请求 B 独有的新内容）→ 新分配 block PE
  num_cached_tokens = block_size × 4 = 1024（system prompt 的 4 个 block 全部命中，跳过 KV 计算）

请求 A 结束 → deallocate():
  block PA: ref_count-- → ref_count = 1 > 0 → 保留
  block PB: ref_count-- → ref_count = 1 > 0 → 保留

请求 C 发来相同 system prompt → 再次命中 → ref_count++
```

这就是 Provider 按"缓存命中量"打折的经济基础：**一次计算 system prompt 的 K/V，服务所有并发用户，多次分摊成本**。

---

## Q7: Prefix Cache 在多轮对话中的真实行为

### 什么情况下多轮对话能复用？

**向模型发两条完全不同的消息**：

```
请求 1: "今天天气如何"
请求 2: "讨论天气质量"
```

Block 0 的内容（token IDs）完全不同 → **零命中**。没有任何前缀重叠。

**如果应用层把历史拼进 prompt**（ChatGPT 等应用的典型实现）：

```
请求 1 (Turn 1):
  "[系统提示] 用户: 今天天气如何\n助手:"
  ≈ 10 tokens

请求 2 (Turn 2):
  "[系统提示] 用户: 今天天气如何\n助手: [AI回复]\n用户: 讨论天气质量\n助手:"
   ↑________  这部分与请求 1 完全相同  ________↑  ← 新增 ≈10 tokens

请求 3 (Turn 3):
  "[系统提示] 用户: 今天天气如何\n助手: [AI回复]\n用户: 讨论天气质量\n助手: [AI回复]\n用户: 根据刚刚的天气给出穿搭建议\n助手:"
   ↑________________ 这部分与请求 2 完全相同 ________________↑  ← 新增 ≈15 tokens
```

在这种情况下，每次新请求的 prompt **前部与上一次完全相同**——哈希匹配 → 前缀 blocks 全部复用。

### 完整的数值跟踪：增量增长

设 `block_size = 256`，每轮实际增量 ≈ 200 token：

```
Turn 1 的 token 序列长度: 180 token
  blocks 0-0  (180 token = 0 full blocks + 180 partial)
  只有完整 block 才参与缓存 → Block 0 不满 256 → hash = -1 → 不缓存

等等，这里有个重要的细节：如果 length < block_size，第一个 block 就不完整。
这意味着 Prefix Cache 在短 prompt 场景下几乎没有收益！

真正的场景：system prompt 足够长（≥ block_size，例如 1280 token = 5 个完整 block），才能积累出有意义的缓存命中收益
```

所以 Prefix Cache 最具经济价值的场景是**长 system prompt**（几百到几千 token）：

```
System Prompt = 1280 token（正好 5 个完整 block: block_size=256）
Turn 1: System Prompt(1280) + "今天天气如何"(20) = 1300 tokens
  blocks = [b0, b1, b2, b3, b4, b5(partial)]
  // b0-b4 完整，b5 不满
  // prefix cache 注册 b0-b4 的哈希

Turn 2: System Prompt(1280) + "今天天气如何\n助手:已查询到上海天气，气温28度，空气质量良好，适合户外活动"(180) + "用户:讨论天气质量\n助手:"(20) = 1500 tokens
  blocks = [b0, b1, b2, b3, b4, b5, b6(partial)]
           ↑~~~~ 全部命中 ~~~~↑  ↑~ 新算 ~↑
  // b0-b4: hash 匹配，num_cached_tokens += 256×5，ref_count++
  // b5: 内容不同（多了一部分）→ miss → 新分配
  // b6: 不满 → hash=-1 → 不参与缓存

Turn 3: System Prompt(1280) + "前两轮完整对话"(400) + "根据刚刚的天气给出穿搭建议"(30) = 1710 tokens
  blocks = [b0, b1, b2, b3, b4, b5, b6, b7(partial)]
           ↑~~~~~~~~~~~~ 全部命中 ~~~~~~~~~~~~↑  ↑~ 新算 ~↑
  // prefix cache 注册 b5, b6 的新哈希（如果它们满了）
  // blocks 越长，命中率越高
  // 新增计算量趋近于纯新增用户输入的长度
```

### decode 阶段新 token 的缓存增长：完整代码

每个 decode 步骤追加一个 token。后处理代码（`scheduler.py` 行 83-95）：

```python
def postprocess(self, seqs: list[Sequence], token_ids: list[int], is_prefill: bool):
    for seq, token_id in zip(seqs, token_ids):
        if is_prefill:
            # prefill 完成后更新 cached_tokens 计数
            seq.num_cached_tokens = min(
                seq.num_cached_tokens + seq.num_scheduled_tokens,
                seq.num_tokens
            )
            if seq.num_cached_tokens < seq.num_tokens or seq.num_completion_tokens > 0:
                # chunked prefill 或 重 prefll 后还没进入 decode
                seq.num_scheduled_tokens = 0
                continue

        # ── decode 后处理 ──
        seq.append_token(token_id)          # 追加到 token_ids 列表
        seq.num_cached_tokens += 1           # 缓存计数 +1

        seq.num_scheduled_tokens = 0
        if (not seq.ignore_eos and token_id == self.eos) or seq.num_completion_tokens == seq.max_tokens:
            seq.status = SequenceStatus.FINISHED
            self.block_manager.deallocate(seq)  # 回收 blocks
            self.running.remove(seq)
```

`may_append` —— 在 decode 前分配新 slot（`block_manager.py` 行 96-112）：

```python
def may_append(self, seq: Sequence):
    block_table = seq.block_table
    last_block = self.blocks[block_table[-1]]

    if len(seq) % self.block_size == 1:
        # 当前 block 正好用满 → 需要分配新 block
        # len=5, block_size=4 → 5%4=1 → 新分配
        assert last_block.hash != -1
        block_id = self.free_block_ids[0]
        self._allocate_block(block_id)
        block_table.append(block_id)

    elif len(seq) % self.block_size == 0:
        # 恰好完成一个完整 block → 计算并注册哈希
        # len=4, block_size=4 → 4%4=0 → 注册这个新完成的 block
        assert last_block.hash == -1
        token_ids = seq.block(seq.num_blocks - 1)
        prefix = self.blocks[block_table[-2]].hash if len(block_table) > 1 else -1
        h = self.compute_hash(token_ids, prefix)
        last_block.update(h, token_ids)
        self.hash_to_block_id[h] = last_block.block_id

    else:
        # 还在当前 block 内写，不需要做什么
        assert last_block.hash == -1
```

### 序列结束后的回收

`deallocate` 完整代码（行 84-91）：

```python
def deallocate(self, seq: Sequence):
    for block_id in reversed(seq.block_table):
        block = self.blocks[block_id]
        block.ref_count -= 1             # ← 每个共享它的序列减少一个引用
        if block.ref_count == 0:          # ← 没人用了
            self._deallocate_block(block_id)  # ← 回收回空闲池
    seq.num_cached_tokens = 0
    seq.block_table.clear()
```

**回收规则**：
- `ref_count > 1`（被多个序列共享）→ **保留**（仍有其他人在用）
- `ref_count == 0`（只有本序列在用）→ **回收**，block 回到 `free_block_ids`
- **保留的共享 block 中的 K/V 数据不变**——下一个命中该哈希的序列可以直接复用

---

## 对比总结

| 机制 | 解决的问题 | 实现方法 | 核心代码位置 | 是否自动启用 |
|------|-----------|---------|-------------|------------|
| **Runtime KV Cache** | 同一请求内 decode 时避免重复计算 K/V | 每步新 token 的 K/V 追加写入预分配缓存；attention 用缓存 K/V 代替重算 | `attention.py:63,72` | 是 |
| **PagedAttention** | 避免显存碎片，提高利用率（借鉴 OS 分页） | KV Cache 按固定大小分块（block），序列用 block_table 映射逻辑→物理位置 | `block_manager.py` 全局 | 是 |
| **Prefix Caching** | 不同请求间共享完全相同的前缀 token 的 K/V | xxhash(token_IDs) 精确匹配，哈希链保证前缀连续性，引用计数管理共享声明周期 | `block_manager.py:35-82` | 是 |

### 需要特别注意的常见误解

1. **❌ 语义匹配 = 前缀缓存命中**
   ✓ 是 **token ID 精确字节匹配**（`np.array(token_ids).tobytes()`），不是语义匹配。"今天天气如何"vs"今天天气好吗"只差一个 token→哈希全不同→零命中

2. **❌ 多轮对话自动复用**
   ✓ 仅在**应用层把完整对话历史拼入 prompt** 时才可能复用前缀；互不相关的独立请求之间不会命中

3. **❌ 最后一个不完整的 block 也参与缓存**
   ✓ 只有 `len(token_ids) == block_size` 的完整块才参与；最后不满的块 `hash = -1`，不写入 `hash_to_block_id`，不参与匹配

4. **❌ 可以跳跃匹配"（Block 0 不匹配但 Block 1 匹配）
   ✓ `cache_miss` 一旦设为 `True` 永不重置 + 哈希链依赖前块哈希 → 不可能跳过不匹配的块去匹配后面的块

5. **❌ Q 也被缓存**
   ✓ Q 每步新算（每一步的"当前 token"都不同）；只有 K 和 V 被缓存

---

> **版本**: commit `44a51af` | 基于 [nano-vllm](https://github.com/GeeeekExplorer/nano-vllm) 代码库
> **生成时间**: 2026-04-28
