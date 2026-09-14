# FastForward 4FE 项目汇报大纲

汇报基准：当前 `E080`，其吞吐控制基于 `E068`。建议时长 15 至 20 分钟，共 12 页。

使用方式：每页“页面内容”放在 PPT 正文中；“为什么”部分作为讲稿或演讲者备注，不要全部堆到页面上。讲述顺序统一为“原问题、修改原因、电路改法、结果与代价”。

## 第 1 页：封面

标题：FastForward 4FE 乱序转发架构与时序优化

副标题：ROB32、4×8 分层选择、动态 BKPR Credit 与状态复用

讲述重点：项目名称、汇报人、日期。封面保持简洁，不放复杂电路图。

## 第 2 页：问题与优化目标

页面内容：

- 每拍最多接收和输出 4 个 packet，内部只使用 4 个 Forwarding Engine。
- 支持乱序发射、依赖转发和按序输出。
- 第一目标是降低统一用例执行时间 `T`，其中时钟周期和 cycles 都会影响结果。
- 目标时钟周期为 0.4 ns，clock uncertainty 为 0.045 ns。
- 时序不能恶化时，再降低面积和功耗。

为什么这样确定目标：

- 项目得分中的 `T` 是四次方权重，所以仅降低面积但让执行时间变长，通常得不偿失。
- `T` 同时由时钟周期和 cycles 决定。只优化其中一个，另一个恶化后，总执行时间仍可能变差。
- 4 个 FE 能明显限制宏单元面积和静态功耗，但资源更少后更容易出现某一 latency class 堵塞，因此需要 ROB、乱序发射和 backpressure 优化补回吞吐。
- 将 0.4 ns 作为目标，是为了约束每一级组合逻辑的深度；0.045 ns uncertainty 必须预留，不能把全部 0.4 ns 都用于数据路径。

建议讲法：先说明最终评价对象是统一用例 `T`，再解释为什么后面的优化有些针对时钟、有些针对 cycles。

配图：[02-project-objectives-editable.svg](assets/02-project-objectives-editable.svg)

## 第 3 页：当前总体架构

页面内容：

- 顶层只暴露 `PKTIN`、`PKTOUT` 和 `BKPR`。
- `ff_ingress` 完成输入寄存、压缩、依赖识别和 ROB 分配。
- `ff_rob` 保存 packet、属性和执行状态。
- `ff_pick` 选择每个 latency class 的最老 ready packet。
- `ff_issue` 读取 packet 与 dependency data，驱动 4 个 FE。
- `ff_sched` 记录每个 FE 的结果到期槽。
- `ff_egress` 按序退休并映射到 4 个输出 lane。

为什么分成这些模块：

| 模块 | 为什么这样划分 | 解决的问题 |
|---|---|---|
| `ff_ingress` | 把外部输入和内部调度隔开，先寄存再处理 | 防止刚到达的 `in_vld` 直接进入深组合逻辑，同时统一处理 4 lane 压缩和分配 |
| `ff_rob` | 用一个集中状态中心保存 packet、依赖和完成状态 | 允许输入、发射、结果返回和退休以不同节奏进行 |
| `ff_pick` | 把最复杂的候选选择独立出来 | 方便单独优化关键路径，并按 latency class 并行选择 |
| `ff_issue` | 将候选选择与数据读取分开 | 避免 picker 同时承担大数据 MUX 和 FEIN 驱动 |
| `ff_sched` | 独立记录每个 FE 的未来输出槽 | 不同 latency 的 packet 混合执行时，仍能提前发现结果槽冲突并对齐返回 tag |
| `ff_egress` | 将乱序完成重新整理成按序输出 | 内部可以乱序提高利用率，对外仍保持协议要求的顺序 |

为什么 ROB 和 Issue Queue 逻辑解耦：ROB 负责“这项是否存在、是否完成、何时退休”，picker/issue 负责“本拍发射谁”。两类状态更新频率不同，解耦后可以分别优化时序，也避免退休反馈网络进入发射选择。

配图：[03-e080-overall-architecture-editable.svg](assets/03-e080-overall-architecture-editable.svg)

## 第 4 页：Packet 的完整处理流程

页面内容：

- S0：无条件寄存 4 路输入。
- S1：压缩有效输入，判断 dependency，分配 ROB entry。
- I0：按 ready、latency class、age 和 critical 标记完成选择。
- I1：读取 ROB data 和 dp data，送入 FE。
- FE 输出经过调度器 tag 对齐后写回 ROB。
- `out_seq` 从 ROB 头连续退休最多 4 项，保证输出顺序。

为什么采用这些流水阶段：

- S0 无条件打拍，是为了保证新输入的 `in_vld`、data 和 control 先成为寄存器输出，再参与压缩、依赖和分配逻辑。这样输入端不会形成外部接口到 ROB/BKPR 的长组合路径。
- S1 把 4 路输入压缩后再分配，是为了让 ROB allocation 连续，减少空洞，并用一个 `acnt` 表示本拍实际分配数量。
- I0 只做选择，I1 再读数据，是为了把 32 项候选搜索和 128-bit 数据读取拆开。picker 关键路径不会继续穿过 FEIN 大 MUX。
- FE 返回时间取决于 latency，调度器必须在发射时登记未来到期槽，否则多个 packet 可能在同一 FE 的同一拍同时返回。
- ROB 允许乱序完成，是为了让空闲 FE 继续工作；egress 按 `out_seq` 退休，是为了保持外部可观察顺序不变。
- 最多连续退休 4 项，是因为外部一拍只有 4 个输出 lane，继续检查更多项不能增加当拍输出量，只会增加组合逻辑。

配图：[04-packet-lifecycle-editable.svg](assets/04-packet-lifecycle-editable.svg)

## 第 5 页：版本演进与取舍

页面内容：

- E006 建立分层 picker 思路，删除 timing-safe 模式未使用的双候选网络。
- v28/E029 确定 ROB32 与 4×8 picker 基线。
- E066 扩大安全复用窗口并使用固定布尔比较。
- E067 删除冗余退休位图，为后续 credit 留出时序余量。
- E068 用本拍确定进度解除 BKPR，降低 cycles。
- E080 复用 latency class，删除重复结果来源状态。
- E064、E069、E072/E073、E074/E074a 因伪时序或真实时序恶化而未进入主线。

为什么采用逐版本独立优化：

- 每个版本只解决一个主要问题，便于判断收益到底来自哪段逻辑，也便于出现问题后准确回退。
- 时序优化会转移关键路径。某次修改即使让原关键路径变短，也可能生成新的更长路径，所以每个版本都重新检查 worst path。
- E064 的数据存在伪例，继续在它上面优化会得到错误结论，因此重新回到可信基线。
- E069 把预唤醒重新接入当拍 picker，增加了 wake、picker 和 FEOUT MUX 的组合锥；E072/E073 增大 ROB 后放大了 ready 到 picker 的搜索压力；E074/E074a 增加输入预处理逻辑。这些方向都因实测时序恶化而停止。
- E066、E067、E068、E080 形成递进关系：先释放安全窗口，再删除冗余路径，然后利用得到的余量减少 cycles，最后删除不影响 cycles 的重复状态。

配图：[05-version-evolution-editable.svg](assets/05-version-evolution-editable.svg)

## 第 6 页：关键改进一，ROB Downsizing 与 4×8 分层 Picker

页面内容：

- ROB 深度由 64 项缩减为 32 项，外部 4-lane 输入、发射和退休带宽保持不变。
- Data Array、ready/issue/result 状态位图和 allocation one-hot 宽度随 entry 数减半。
- ROB 读选择网络由 64:1 缩为 32:1，Picker 的候选搜索宽度由 64-bit 缩为 32-bit。
- 32 个候选按 4 个 bank 分组，每组 8 项。
- bank 内先做 priority encode，再按 `old_u` 形成的 circular age 顺序选择 bank。
- timing-safe 配置只保留主候选，避免 secondary candidate 和 donor/receiver 匹配网络进入组合路径。
- critical 候选与普通 oldest 候选并行计算，最后一级选择。

为什么这样修改：

- ROB64 能容纳更多未退休 packet，但也会让存储阵列、状态向量、one-hot 译码、读 MUX 和候选搜索网络整体变宽。改为 ROB32 可以直接减少存储、控制位和翻转节点，并降低 ROB 到 Picker 的组合压力。
- 容量缩小会使 occupancy/window BKPR 更容易触发，因此 ROB32 不能被当成独立的 cycles 优化；后续用 Safe Window 和 Same-Cycle Credit 回收过早背压造成的周期损失。
- 直接对 32-bit 候选做旋转、全宽 priority encode 和年龄比较，会形成一条层级较深、扇出较大的组合路径。
- 拆成 4 个 8-bit bank 后，bank 内 priority encode 并行进行；第二级只需要在 4 个 bank 结果中选择，组合深度更容易控制。
- `old_u` 只决定 circular bank 顺序，不需要先生成完整 32-bit rotate 网络，可以减少宽 MUX。
- timing-safe 配置本来就关闭 stealing，因此继续计算 secondary candidate 不会改善该配置的 cycles，只会增加面积、翻转和时序负担，所以直接裁掉。
- critical 与 normal oldest 并行计算，是为了避免先找 oldest、再重新搜索 critical 的串行结构。最后一个选择器根据规则二选一即可。

为什么不继续增大 ROB：ROB64 虽然能减少容量阻塞，但 ready mask、age 选择、状态位图和数据 MUX 都翻倍。E072/E073 已观察到 `u_rob/rdy_q` 到 `u_pick/pk_tseq_q` 的严重时序压力，因此当前保留 ROB32。

配图一：[ROB Downsizing](assets/06-rob-downsizing-editable.svg)

配图二：[分层 Pick 搜索](../architecture/e068-key-improvement-01-hierarchical-pick-editable.svg)

## 第 7 页：关键改进二，安全复用窗口

页面内容：

- ROB 深度 32，保留 dependency distance 7 和两拍输入最多 8 项的裕量。
- 安全窗口上限为 `32 - 7 - 8 = 17`。
- `win > 17` 写成固定 bit-level 布尔式，避免通用 magnitude comparator。
- E066 的固定阈值逻辑保留到 E068/E080。

为什么从 13 改为 17：

- 阈值 13 过于保守，ROB 中仍有可安全复用空间时就提前拉高 BKPR，输入停顿会直接增加 cycles。
- ROB 深度为 32。依赖目标最远距离为 7，输入端还有两拍、最多 8 项尚未反映到 ROB 占用，因此可证明的最大窗口是 `32 - 7 - 8 = 17`。
- 17 来自安全边界计算，不是为了追求 cycles 随意调大的经验值。

为什么使用固定布尔式：通用 `win > WIN_TH` 容易综合为完整 magnitude comparator。阈值固定为 17 后，只需检查 `win[5]` 或 `win[4]` 与低位归约，逻辑更浅，也避免比较器直接进入 `bkpr_r` 路径。

为什么不继续把阈值提高到 18 以上：当前安全证明已经把 dependency distance 和 8 个在途输入计入。超过 17 会侵占保留裕量，除非改变接口流水或增加新的精确 credit 证明，否则存在覆盖未退休 entry 的风险。

配图：[安全复用窗口](../architecture/e068-key-improvement-02-window-threshold-editable.svg)

## 第 8 页：关键改进三，退休状态去冗余

页面内容：

- 原实现同时维护 `out_seq_q` 和 32-bit `outp_q`，两者重复表达退休进度。
- E067 删除 `outp_q`、`pop_oh` 译码和反馈网络。
- `live_cnt = alloc_seq - out_seq` 限定有效退休候选。
- `out_seq` 直接按 `pop_cnt` 前进，功能周期与 E066 一致。

为什么这样修改：

- `out_seq_q` 已经指向第一项未退休序列。表项一旦退休，`out_seq_q` 就会前进，所以 `outp_q` 再保存一份“已经退休”状态属于重复信息。
- 原来的 `pop_cnt` 需要先译码成 32-bit `pop_oh`，再与 `outp_q` 做 OR、清除和反馈。这条宽状态反馈网增加了 DFF、译码和翻转，也进入退休关键路径。
- 删除 `outp_q` 后必须防止 ROB 为空或物理索引回绕时误读旧的 `cmpl` 位。因此使用 `live_cnt` 判断第 `k` 个候选是否真的已经分配。
- E067 刻意不改变退休规则和 cycles，只做等价状态消除。这样可以先建立可信的时序余量，再让 E068 使用这部分余量增加 credit 逻辑。

配图：[退休反馈网优化](../architecture/e068-key-improvement-03-retire-cleanup-editable.svg)

## 第 9 页：关键改进四，同拍动态 BKPR Credit

页面内容：

- retirement credit 使用当拍实际 `pop_therm`。
- issue credit 只扫描 `old_u` 起的前四项，并受 allocation frontier 限定。
- 固定安全阈值仍是 occupancy 23、window 17。
- thermometer count 选择固定阈值 bank，不把通用减法器或完整 picker 组合锥接到 `bkpr_r`。

为什么还需要动态 credit：

- E066 的 BKPR 使用当前寄存的 `out_seq_q` 和 `old_u_q`。即使本拍已经确定会退休或发射，指针也要到时钟沿后才更新，因此反压会晚一拍解除。
- 简单继续提高固定阈值缺少安全证明。E068 不改变 23/17 边界，而是只扣除本拍已经确定发生的进度，所以能更早解除 BKPR，又不借用未经证明的空间。

为什么分成两路 credit：

- retirement credit 解决 ROB occupancy 阻塞。`pop_therm` 已由退休链产生，可以准确表示本拍释放 0 至 4 个 entry。
- issue advance credit 解决 oldest-unissued window 阻塞。它只检查 `old_u` 开始的连续 issued 项，并把本拍 `picked` 合入 `iss_eff`。
- 两条阻塞原因不同，只保留其中一路会漏掉另一类停顿，因此完整 E068 同时保留两路。

为什么不用两个减法器：直接计算 `(occ - pop_count) > 23` 和 `(win - advance) > 17` 会增加减法器加比较器。E068 预先计算五个固定阈值，再由 one-hot count 选择对应结果，组合逻辑更可控。

为什么最多只看四项：一拍最多发射和退休 4 项。检查更多 entry 不会产生本拍可兑现的额外 credit，只会延长连续判断链。

配图：[动态 BKPR Credit](../architecture/e068-key-improvement-04-dynamic-credit-editable.svg)

## 第 10 页：E080 状态复用

页面内容：

- timing-safe 配置关闭 stealing，每个 latency class 固定对应一个 FE。
- 此时结果来源 `rob_src` 与已有 `rob_lat` 表达相同信息。
- E080 在 safe 配置中用 `rob_lat` 选择写回和 bypass 来源，删除 32×2-bit `rob_src` 状态。
- dual/full 配置仍保留独立 source tag，功能行为不变。

为什么可以复用 `rob_lat`：

- timing-safe 配置设置 `DUAL_STEAL=0`，每个 latency class 固定绑定同编号 FE。因此 `source FE = latency class` 始终成立。
- `rob_src` 原本用于记录 packet 实际发往哪个 FE。在没有 stealing 时，它与 `rob_lat` 是完全相同的 2-bit 信息。
- 写回和 egress bypass 都可以直接使用 `rob_lat` 选择 FEOUT，不需要第二组状态位。

为什么这是低风险面积和功耗优化：它不改变 picker、BKPR、调度和流水级，只删除重复 DFF 及其写入活动。cycles 保持不变，组合深度代理也没有增加。

为什么 dual/full 仍保留 `rob_src`：启用 stealing 后，packet 可以发往非本类 FE，`source FE = latency class` 不再成立。如果也删除 source tag，结果可能从错误 FEOUT 写回。

配图：[10-e080-source-reuse-editable.svg](assets/10-e080-source-reuse-editable.svg)

## 第 11 页：验证与评估方法

页面内容：

- 功能回归包括 quick、mid、heavy、DEPHEAVY、sparse、dual-heavy 和 full-heavy。
- 多 seed 对比每次优化前后的 cycles。
- 逐拍断言检查按序输出、FE 输出槽冲突、结果唯一写源和 credit 不超真实进度。
- Yosys/ABC 逻辑代理用于候选排序。
- Nangate45、OpenSTA 和固定 SDC 提供开源配对基线，但不能替代内网真实 FE、P&R 和活动率功耗签核。

为什么验证必须分层：

- quick 先拦截明显功能错误，避免在错误 RTL 上浪费长回归和综合时间。
- heavy、DEPHEAVY 和多 seed 用于覆盖拥塞、依赖链和随机到达差异，避免只对一个 seed 过拟合。
- dual/full 虽然不是默认 timing-safe 配置，但用于确认参数化分支没有被 safe 优化破坏。
- 逐拍断言检查局部不变量，比只看最终 PKTOUT 更容易定位哪一拍发生了重复发射、槽冲突或 credit 超发。
- 逻辑代理适合快速筛选候选，但没有真实布线寄生、时钟树和活动率。只有正式 STA、P&amp;R 和 SAIF Power 才能回答最终 T、Area、Power。

为什么失败版本也要记录：失败实验能明确哪些组合路径不能重新接回主线，也能防止后续人员重复尝试已经证实恶化的结构。

配图：[11-verification-flow-editable.svg](assets/11-verification-flow-editable.svg)

## 第 12 页：结果、当前限制与下一步

页面内容：

- 重载代表用例从 v28 的 10337 cycles 降到 E068/E080 的 9070 cycles。
- E067 配对代理将 nominal 最大 arrival 从 0.8875 ns 降到 0.8675 ns，E068 保持不变。
- E080 相对 E068 删除 64 个状态位并减少 672 个 ABC-simple cells，cycles 不变。
- 当前开源 OS-P00 基线的 setup arrival 为 1.0541 ns，0.4 ns 时钟目标尚未收敛。
- 下一步需要在真实 FE、正式 corner、P&R 寄生和 workload SAIF 下完成统一 T、Area、Power 签核。

这些结果为什么分开呈现：

- cycles 只与相同 workload、packet 数和 seed 比较。
- E066/E067 的 arrival 只属于当时相同 Yosys/ABC 命令的历史配对，不能与 OS-P00 的 Nangate45/OpenSTA 数字直接相减。
- E080 的 cell reduction 与 E068 使用配对综合得到，可以证明结构减少，但不能直接等同于实际面积比例或功耗比例。
- OS-P00 显示当前设计距离 0.4 ns 仍有明显差距，所以汇报结论应是“吞吐和结构优化有效，时钟目标仍待物理实现收敛”，不能宣称项目已经达到 0.4 ns。

为什么下一步必须转向真实实现环境：当前 worst path 使用映射后的 cell 名称，且 FE 是代理模型。只有替换真实 FE、加入布线寄生和真实活动文件，才能判断应该继续拆 picker/ROB 路径，还是优化 FE 边界与物理布局。

配图：[12-results-and-next-steps-editable.svg](assets/12-results-and-next-steps-editable.svg)

## 汇报口径

- 把 cycles、逻辑深度和开源 STA 称为“代理结果”，不要称为最终 PPA。
- 不引用 E064 的时序结果，也不把 E069、E072/E073、E074/E074a 作为保留优化。
- E066 已收到功耗约增加 10% 的结果；E068/E080 在新活动率报告返回前不宣称功耗数值改善。
- `T` 指统一用例最终执行时间，不能只用时钟周期或单个 heavy cycles 代替。
