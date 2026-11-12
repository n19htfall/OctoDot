# 实现任务 · Reranker 跨按键增量评分

请在 OctoDot 实现 `docs/rerank-design.md` 的 **Incremental scoring**。同一次组合输入里，相邻两次实际评分的候选往往共享许多汉字前缀。让后一次评分复用这些前缀的 Transformer 状态和输出归一化值，减少 `refine` 的计算量。交付代码、回归测试和同机前后对比数据，并更新设计文档。

## 现有入口和行为约束

- `engine/session.goose` 的 `request_rerank()` 负责判断是否待评分。正常输入经 `refine()` 调用 `rerank_now()`，测试和 accuracy harness 的 `rerank_sync` 直接调用同一个 `rerank_now()`。让两个路径都用增量评分。候选资格、`builds` / `rerank_due` 检查、highlight / page 保护以及 Swift 宿主在下一键前的 `settle()` 继续走现有流程。
- `rerank_now()` 每次用当前的 `words` 重建 shortlist，并通过 `engine/rerank.goose` 的 `Job` 和 `add()` 生成 `[BOS, 字符 IDs…, EOS]`。继续使用本次 shortlist 的 search score、顺序和候选引用。保留 `search score + weight × log2 P`、平手时选靠前的候选、候选移动和学习行为。让模型、词表、shortlist 搜索参数及宿主 ABI 保持兼容。
- `engine/rerank.h` 的 `octo_rerank_score()` 已经为单次调用构建前缀 trie，再按层对所有唯一节点做批量前向。跨调用复用从这里实现。保留现有 `rerank::score(job, bits)` 和 C 评分入口作为无跨调用状态的对照及回退。给会话加内部缓存入口和一个可供测试、基准使用的禁用开关，使相同输入能走完整的冷评或增量流程。生产默认启用增量。

## 缓存的身份、数据和上限

只保留当前组合输入中**最近一次成功评分**的 trie。查找身份是当前已加载模型下从 BOS 到该节点的完整 token ID 路径。匹配时逐层用旧父节点和当前 token ID 找旧子节点。位置编码用当前节点深度，BOS 深度为 0。父节点未命中时该分支的后代全部未命中，即使其他分支的同一位置有相同字符。`<unk>` 也按 ID 比较。每次重建本次 trie，所以候选可以重排、增删、回删后重打，或者在中间改字。

为每个节点缓存以下 `float32` 数据。

- 各层加 bias 后的 K、V，各 `dims` 个值。新节点的 query 在每层都需要自己和祖先的 K、V。
- 最终 LayerNorm 后的向量 `h`，以及输出层对整个词表算出的 `lse = logsumexp(logits)`。命中节点通过 `dot(h, embedding[next_id]) - lse` 得到当前请求的下一个 token 的对数概率。旧候选可能在「一家三口」后接 EOS，新候选可能接「候」，两条边共用这个节点的 `h` 和 `lse`，各自使用自己的 `next_id`。EOS 通常只作最后一条边的目标，末尾 token 本身没有前向节点。

缓存只存上述状态和索引。预算先定为 **8 MiB 常驻缓存**，含常驻 trie 元数据。单槽数据量为 `sizeof(float) × (2 × layers × dims + dims + 1)`，发布模型每槽 19,972 B，单算状态约容纳 420 槽。按模型形状算容量，按实际节点数惰性增长。用一个状态区和可重用的槽位，槽内按层布局，扩容后按槽索引重新取地址。旧、新 trie 只需各自的索引元数据。一整份新 trie 超过容量或缓存分配失败时，本次走完整评分并清空旧的逻辑缓存，后续小 job 可重新建立缓存。

## 在 `engine/rerank.h` 中改前向

1. **先校验，再构建本次 trie。** 复用现有 ID、序列长度和位置约束，检查 `starts` 从 0 到 `ids.len` 且单调递增，在读取、窄化转换和大小乘法前处理范围、溢出和分配失败。Goose 的 `Job` 从 BOS 开始，缓存入口可以把首 token 不是 BOS 的原始 C 请求交给现有完整评分路径，维持其接受范围和返回约定。建立 token、parent、depth，以及每条候选的每条边对应的父节点和目标 ID。
2. **匹配后再分配槽位。** 按父先于子的顺序建立本次节点到旧节点的映射。先标记所有命中槽，随后才为未命中节点分配未保留的槽。这样候选重排时，先出现的新分支也不会覆盖稍后才匹配到的旧分支。用 `row → slot` 和 `row → miss_row` 区分 trie 行、持久槽和本次密集批次里的行。正常完成后仅发布本次 trie 的索引，被移除的分支可以立即复用其槽位。
3. **每层只跑未命中行。** 初始化这些行的 `embedding[token] + position[depth]`，对全部未命中行批量执行该层的 LayerNorm 和 QKV 投影。等该层全部 QKV 已算出，再沿每个未命中节点从 BOS 到自己的路径做 attention。命中祖先的 K/V 来自缓存，未命中祖先和自身的 K/V 来自本层 QKV 批次。将新 K/V 写入预留槽。沿用当前 attention 累加顺序、Accelerate SGEMM、残差、GELU 和 FFN。冷评可作为所有行均未命中、无持久状态读写的同一计算路径，复用核心算子。
4. **输出层只对未命中行跑完整词表。** 对新行做最终 LayerNorm，沿用现有分块 SGEMM 和 softmax 归一化，保存 `h` 与 `lse`，在 logits 块仍有效时收集本次所需的边分数。命中行只计算各请求 token 的单个 logit 并减去缓存的 `lse`。可用一个随本次 `Job` 生命周期的边分数数组，让每个候选按原有从 BOS 到 EOS 的顺序把 `float` 边差值加到 `double`，最后除以 `M_LN2`。全命中调用跳过 Transformer 和整词表投影。保留现有 logits 分块的内存上限。
5. **缓存发布与失败。** 输入校验失败直接返回现有错误结果。分配缓存或计算期间出错时让完整评分接管，完整评分也无法完成时让会话按现有方式保留解码器候选。旧槽可能已被复用，因此写入开始后发生失败应让整个旧 trie 失效，避免下次引用半更新状态。检查待发布评分的有限性和可用范围，损坏权重触发拒绝时清掉缓存。保持原始冷评入口和 `best()` 的损坏模型处理语义。

## 接入和生命周期

- 在 `engine/rerank.goose` 封装会话评分和 C 缓存的清空、释放。只在 `session::rerank_now()` 的评分位置接入。每次真正算完一个可用 job 就可以更新缓存，即使最后第一候选相同。未触发 rerank 的中间按键、未完成音节、被替换或被翻页取消的待评分菜单都不更新缓存。
- 在 `session::clear_composition()` 做常数时间的逻辑清空，覆盖提交、Escape、切换方案、活跃客户端切换、reset 和释放活跃会话。在 `rebuild()` 的空输入分支也清空，覆盖 Backspace 删掉最后一键的路径。普通 `rebuild()`、仍有输入的 Backspace 和同一组合中的局部选词继续用 token 路径判断命中。缓存的生命周期以实际组合输入为界，`builds` 仍只用来判断待评分菜单是否有效。
- 在关闭或重新打开 reranker 时释放状态区，失败的模型重开也从空缓存开始。关闭 rerank 设置和 `session::trim()` 时释放状态区。`trim()` 保留现有待评分菜单和搜索数据，下一次 `refine()` 冷启动并正常完成。缓存属于当前引擎调用线程，内容仅在进程内使用。保留现有 `KEYFLAG_NO_LEARN` 的学习语义。
- 不同 SGEMM 批量尺寸及命中边的单个点积可能产生舍入差异。回归测试将增量与同一个 `Job` 的冷评逐项比较，发布模型的目标为每个候选绝对误差 ≤ `0.001` bits，候选赢家必须一致。若实际用了缓存且前两名加权总分差 ≤ `2 × abs(weight) × 0.001`，用同一 `Job` 完整重评再选第一，保留原有平手规则。若增量结果不可用，也用冷评确认后再决定。可复用 `best()` 的验证与排序逻辑来取得分差。这个分差是基于实测容差的保护，仍需跑逐键赢家对照。

## 回归测试

- 在 `engine/tests/images_test.goose` 保留 `rerank.check.tsv` 现有测试，再加连续 job 的冷暖对照。例子用 token ID 表达：A 为 `[1,3,4,2]`、`[1,3,5,2]`，B 为 `[1,3,4,6,2]`、`[1,3,7,2]`。A 冷启有 4 个节点，B 有 5 个节点且命中 3 个，原前缀 `[1,3,4]` 的下一 token 从 EOS 变为 6。B 重复一次应全命中，B 后回到 A 时旧分支 5 应重算。再覆盖候选重排、同深度同 token 但祖先不同、`<unk>`、长序列边界、强制超预算或分配失败回退。用内部测试统计断言命中、实际前向行数和整词表投影行数，避免纯分数测试在完全没缓存时也通过。测试接近平手时确实回退，并且最终仍按原始规则选第一。
- 在 `engine/tests/typing_test.goose` 用同一逐键序列比较缓存开关两种模式的最终菜单和提交结果，至少覆盖正常 `PENDING → refine`、`rerank_sync`、退格后续打、模型开关、客户端切换或 reset。保留最新菜单保护、翻页/高亮保护、Space 提交与学习的已有断言。在已有 memory pressure 测试里覆盖已预热缓存被释放后，待评分菜单仍可正常完成。新组合的第一次实际评分应为冷启动。
- 在 `engine/fuzz/fuzz_images.goose` 的 weights target 上加同一个映射里的多次缓存调用，包括分支变化、畸形 ID / offset、清空与关闭后重开。用有效小模型验证同形状的模型重开后首个 job 不复用前一模型的节点。ASan 和 UBSan 下运行现有 fuzz 路径及新增序列。

## 性能对照与交付

- 用同一机器、同一模型和同一 release 构建，对全拼与小鹤双拼各跑一组逐键输入。每句从新组合开始，句内按宿主顺序发 key、对 `PENDING` 调用 `refine()`，包含追加和退格。可以扩展现有 typing latency 测试或复用 `engine/bench/typing_memory.goose` 的事件驱动方式。分别报告 `key`、`key → refine` 的 p50/p99，以及评分耗时、前缀节点命中率（总命中行 / 总唯一行）、完整重评次数和缓存内存峰值。以冷评开关隔离缓存收益。`accuracy --time-rerank` 对整句单次评分，适合补充冷评成本，跨键收益以逐键数据为准。
- 检查现有 key 延迟门槛和 typing-memory 稳态门槛。验收时要看到真实的前向与整词表投影行数减少、逐键评分耗时改善、候选结果一致，并报告 cold start、长输入和内存压力后的表现。建议运行 `make test-images test-typing`、`make test-accuracy`、`make bench-typing-memory`、`make check-privacy`，并在 sanitizer 下运行 `make fuzz` 或对应的 `fuzz-rerank-weights` 目标。性能取同机对照，不能拿 debug 数据作延迟结论。
- 更新 `docs/rerank-design.md` 的 Engine / Tests 小节和 Later 条目，记录实际缓存边界及实测结果。在交付说明中列出改动文件、跑过的命令、冷暖对照、实际内存开销和任何尚未验证的项目。当前检出 `9af6dde` 上用本地已构建的 images/typing 测试跑出的单次参考为：训练样本 11 条的最大分差约 `0.000021` bits，全拼 `key` p50/p99 为 `0.348/0.887 ms`，`key → refine` p50/p99 为 `4.524/8.943 ms`。请在你的运行环境重新采集对照。
