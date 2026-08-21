# 4FE 仿真、STA 与 PPA 实验记录

本文件是 4FE 优化的唯一对比表。每次内网综合必须对应一个 Git
提交，禁止只修改工作区后记录结果。评分中的 `T` 是统一用例的最终
执行时间，不是单独的时钟周期或重载吞吐。

## 记录规则

1. RTL 变化先提交，记录完整 Git SHA。
2. 综合脚本、工艺库、corner、时钟约束和活动文件必须保持一致；
   任一项变化时新开一组实验，不与旧数据直接比较。
3. `T` 必须采用固定统一用例集完整运行后得到的最终执行时间；单个
   本地回归的 cycles 或单独的时钟周期只能作为代理，不能替代 `T`。
4. 记录 worst path 的 startpoint、endpoint、arrival、required 和
   slack；不能只记录 slack。
5. Area、Power、T 均齐全后再计算
   `score = 1 / (T^4 × Power × Area)`。
6. 原始报告保存在内网归档中，归档目录名使用实验 ID 和完整 SHA。

## 配置

| 配置 | REG_FEIN | WAKE_BYPASS | DUAL_STEAL | 用途 |
|---|---:|---:|---:|---|
| full | 0 | 1 | 1 | 原始全性能参考 |
| no-bypass-dual | 0 | 0 | 1 | 隔离 bypass 影响 |
| safe-v1 | 0 | 0 | 0 | 当前默认综合配置 |
| safe-v2 | 0 | 0 | 0 | registered commit + in-flight mask |
| safe-v3 | 0 | 0 | 0 | 分层选择；关闭偷取；关键标记/egress 门控解耦 |
| safe-v4 | 0 | 0 | 0 | 寄存 picked 位图；ROB crit/outp 整向量 next-state |
| safe-v5 | 0 | 0 | 0 | safe 单主候选选择；ROB 8×8 分层 oldest-unissued 搜索 |
| rob32-safe | 0 | 0 | 0 | E021 选择策略；32 项 ROB，picker 为 4×8 分层搜索 |
| rob32-window | 0 | 0 | 0 | 原始 v28；仅回收经证明安全的 ROB reuse-window credit |
| rob32-retire-clean | 0 | 0 | 0 | E066；删除冗余退休位图并以 live count 限定退休 |
| rob32-dynamic-credit | 0 | 0 | 0 | E068；用本拍实际退休/发射推进精确解除 BKPR |
| rob32-ingress-admission | 0 | 0 | 0 | E074；入口缓冲吸收 BKPR 响应尾，ROB 按物理边界接收 |
| rob32-circular-spill | 0 | 0 | 0 | E077；固定 spill bank 代替宽队列逐拍移位 |
| rob32-head-tail-spill | 0 | 0 | 0 | E078；head/tail 指针简化 spill bank 宽写控制 |

## 结果

| ID | RTL SHA | 配置 | 重载 cycles | 中载 cycles | 稀疏 cycles | Required (ns) | Arrival (ns) | Slack (ns) | Area | Power | 统一用例 T | Score | Worst path / 备注 |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| E000 | `52459edf4aea5b5b43a00e2c6a3ba1382d27c2f8` | full | 5601 | — | — | 0.2650 | 1.0609 | -0.7959 | — | — | — | — | `pk_lat_q → issue → sched → rob → pick → rob` |
| E001 | `52459edf4aea5b5b43a00e2c6a3ba1382d27c2f8` | no-bypass-dual | 6001 | 9932 | 24963 | 0.2650 | 0.8119 | -0.5469 | — | — | — | — | `old_u_q → pick → clk_gate_pk_idx_q latch` |
| E002 | `8bd02b6ec7843d99faaf8c1b4e256a1aaa2f980c` | safe-v1 | 6001 | 9932 | 24963 | 0.2650 | 0.7933 | -0.5283 | — | — | — | — | `old_u_q → pick → rob → clk_gate_iss_q latch` |
| E003 | `d3f4b65160a57aa1e17225440959027b56f6ea7b` | safe-v2 | 6001 | 9932 | 24963 | 0.2893 | 0.8542 | -0.5649 | — | — | — | — | worst `pick/pk_idx_q[2] → pk_idx_f[16] → pick/pk_idx_q[3]`；另有 `pick → ingress/res_known → rob/crit_q` -0.1207 ns、`sched → egress/res_now → lane_d ICG/E` -0.1166 ns |
| E004 | `b739c885fb2bd595560b5ec0c9233fd4709a0b79` | safe-v3 | 6154 | 9932 | 24963 | 0.2833 | 0.6674 | -0.3841 | — | — | — | — | worst `pick/pk_idx_q[3] → picked → rob/old_u`；同组 `pick → pk_idx_n` 三条约 -0.3839 ns；另有 `sched/res_now → rob/outp_q ICG/E` -0.0532 ns、`ingress/k_tgt → rob/crit_q ICG/E` -0.0515 ns |
| E005 | `f90af222172df52a535443d6aed359193d0b081e` | safe-v4 | 6154 | 9932 | 24963 | 0.2803 | 0.6347 | -0.3544 | — | — | — | — | worst `pick/picked_q[48] → rob/old_u_q[5]`，27 级逻辑；另有 `picked_q[31] → picked_n[27]` 与 `rob/old_u_q[0] → pick/picked_n[27]` 均约 -0.3529 ns；违例 10276 条；通用 Yosys 全设计 266102 cells、picker 深度 60 |
| E006 | `489c76a2175aaafec2545f1c854e57b987c0b067` | safe-v5 | 6154 | 9932 | 24963 | — | — | — | — | — | — | — | 待内网综合；safe 模式删除未使用的 secondary/parity 选择网络，ROB 用 8×8 分层搜索替代 64-bit rotate+flat PE；通用 Yosys 全设计 263576 cells（对 E005 -0.95%），picker 8433→5936 cells、最长拓扑深度 60→39；safe/dual/full cycles 与 E005 完全一致 |
| E029 | `3bc99500489ab67a8333db3a12b06773a47b1ffd` | rob32-safe | 10337 | 11719 | 24969 | — | — | — | — | — | — | — | 从时序最佳 E021 独立派生的 32 项 ROB 对照实验；本地回归全部通过，但重载 cycles 较 E021 的 6154 增加 68.0%，不能把局部时序改善直接视为 T 改善。统一 Yosys 代理下全设计 AND/NOT 为 144256/94141（E021 为 286332/184578），同法组合深度 65→54；picker 深度 53→44。必须在固定统一用例上实测最终 T 后再决定保留或回退。 |
| E066 | `87f302b864d63ce7d06b30f47b1c314028f76bed` | rob32-window | 9567 | 10961 | 24907 | — | — | — | 148737* | — | — | — | 从原始 v28 `626413e15bd44c2fbbfea6a22e59d8497101da5a` 直接派生，不包含 E064/E065。将 reuse-window BKPR 阈值 13→17，并把固定 `win > 17` 写成布尔式。九个重载 seed 平均 cycles -7.48%，三个 DEPHEAVY seed 平均 -5.54%；60k DEPHEAVY、dual-heavy、full-heavy 与断言均通过。统一 ABC simple 代理的 low/nom/high 最大 arrival 与 v28 同为 0.8100/0.8875/0.9650 ns，组合 cells 143041→142834、总 cells 148944→148737；但代理关键路径起点及门组成已变化，仍须真实 STA/PPA 和统一用例 T 签核。`*` 为代理 cell count，不是工艺库面积。 |
| E067 | `a1e8605f224d9eb46b2febb62f0aedab5b261d74` | rob32-retire-clean | 9567 | 10961 | 24907 | — | — | — | 147988† | — | — | — | 从 E066 独立派生；删除 32-bit `outp_q`、`pop_oh` 解码及反馈，以 `alloc_seq-out_seq` live count 防止空 ROB/回绕时退休保留的旧结果。quick、九个重载 seed、三个 DEPHEAVY seed、60k DEPHEAVY、dual/full 与新增退休断言全部通过，所有 cycles 与 E066 完全一致。配对重综合下 low/nom/high 最大 arrival 代理从 0.8100/0.8875/0.9650 ns 降至 0.7950/0.8675/0.9400 ns，关键路径转为 `picked[30] → old_u_n`；总 cells 148338→147988（-0.236%），组合 cells 142435→142117，时序状态位 5893→5861。`†` 为本次配对重综合代理，绝对数不可与 E066 行的旧综合归档直接混算；真实 STA/Power 待测。 |
| E068 | `c6092b9185710eaedbcbfcaeee78e3db0e76f6c2` | rob32-dynamic-credit | 9070 | 10667 | 24907 | — | — | — | 148066† | — | — | — | 固定 23/17 安全阈值不变，以本拍实际退休和最多四项连续 issued 推进动态解除 BKPR；九个重载 seed 平均 9052.333，三个 DEPHEAVY seed 平均 14904.667，60k DEPHEAVY 为 44794，dual/full seed7 为 9018/7949。low/nom/high 最大 arrival 代理为 0.7950/0.8675/0.9400 ns。用户侧真实 STA 已通过并确认有提升，后续候选均以该版本为功能和时序基线。 |
| E074 | `d6f33c985007e6925c99f3178ecc366fca9b0faf` | rob32-ingress-admission | 8074 | 10131 | 24907 | — | — | — | 157509† | — | — | — | 从 E068 RTL 独立派生。现有 S0 加两拍 spill buffer 吸收两拍/八包 BKPR 响应尾，ROB 对当前队首按 occupancy 31、reuse span 25 的物理边界精确 admission。九个重载 seed 平均 8054（较 E068 -11.03%），三个 DEPHEAVY seed 平均 14036.333（-5.83%），mid -5.03%，60k DEPHEAVY -5.31%，sparse 不变；dual/full seed7 为 8006/7033（-11.22%/-11.52%）。low/nom/high 最大 arrival 代理与 E068 同为 0.7950/0.8675/0.9400 ns，但状态位 +1074、总 cells +6.38%，且近关键端点显著增加，必须以真实 STA/Power 决定是否保留。 |
| E077 | `77c09f909afcfc7ab21dbec140bc7ff97b55e392` | rob32-circular-spill | 8074 | 10131 | 24907 | — | — | — | 155379† | — | — | — | E074 队列的等价重构：q0 保持队首，两个固定 spill bank 以单 head 指针轮换，删除 q2→q1 的 532-bit 移位。所有 cycles 与 E074 一致；总 cells 较 E074 -1.35%，但状态位 +1 且近关键端点未改善，作为中间检查点。 |
| E078 | `14bc4b0f6cf8da05b849c8e4cd9364b47dde35e0` | rob32-head-tail-spill | 8074 | 10131 | 24907 | — | — | — | 151871† | — | — | — | 在 E077 上以独立 1-bit head/tail 指针把两个 spill bank 变成规则的 enqueue-only 宽寄存器。完整回归与 E074 cycles 精确一致，故保留相对 E068 的 heavy -11.03%、DEPHEAVY -5.83%、dual/full -11.22%/-11.52%。总 cells 只比 E068 +2.57%，组合 cells +1.92%；low/nom/high 最大 arrival 仍为 0.7950/0.8675/0.9400 ns。忽略 Power 的 T^4/Area 代理为 E068 的 1.556 倍；若 Power 保守按 cells 同比例增长则为 1.517 倍。真实 STA/Power/统一 T 待签核。 |

### E066 基线与否决记录

- E066 的直接父提交是原始 v28 文档提交 `626413e15bd44c2fbbfea6a22e59d8497101da5a`，
  对应 v28 RTL 提交 `3bc99500489ab67a8333db3a12b06773a47b1ffd`；不得引用
  E064 或其派生版本的时序数据。
- 曾本地试验通用比较写法 `win > WIN_TH`，nominal 最大 arrival 代理由
  0.8875 ns 恶化至 0.9150 ns，已否决且未提交。提交版本使用阈值 17 的
  固定布尔表达式，最大 arrival 代理恢复到 v28 数值。
- v28 的代理最坏路径为 `exit_idx_f[10] → u_rob.outp_n[15]:D`；E066 为
  `exit_idx_f[15] → u_rob.outp_n[15]:D`。因此只能结论为“最坏 arrival
  代理数值未变”，不能宣称物理关键路径未变或已经满足 0.4 ns 时钟周期。
- 重载 seeds 3/5/7/11/13/17/19/23/29 的 cycles 分别为
  9612/9576/9567/9557/9598/9525/9444/9482/9507；DEPHEAVY seeds
  7/19/41 为 15366/15122/15109。中载 seed 11 为 10961，稀疏 seed 11
  为 24907，dual-heavy/full-heavy seed 7 为 9512/8432。
- 已收到的 E066 PPA 结果显示功耗相对对照增加约 10%；活动文件、corner
  与完整报告仍须归档。E067 不用 cell count 代替功耗结论，必须重新测量。

### E067 退休边界记录

- `out_seq_q` 始终指向第一项未退休序列并在退休边沿前进，因此无需
  `outp_q` 防止重复退休；`alloc_seq-out_seq` live count 限定四个候选，
  防止 ROB 为空或物理索引回绕时把保留结果误判为新结果。
- E066/E067 使用同一 Yosys/ABC 命令配对重综合。nominal 最大 arrival
  代理 0.8875→0.8675 ns（-2.25%）；nominal 超过 0.400 ns 的端点
  908→876。该结果只证明代理不恶化，不替代 0.045 ns uncertainty 下 STA。
- E067 不降低 cycles；它为下一步使用本拍 retirement/old-u credit 精确
  解除 BKPR 提供时序余量。后续候选仍须以 E066 的三 corner 最大值为上限。

### E074 入口 admission 记录

- `ff_pick`、`ff_issue`、`ff_sched`、`ff_egress` 与 E068 逐字不变。入口
  队列保留原 S0 为队首，仅在 ROB 暂停接收时使用两拍 spill；正常流不增加
  稳态 pipeline 周期。队列 BKPR 覆盖“当前阻塞拍 + 一拍响应延迟”的最多
  八个输入包，仿真增加 `BKPRLAG=1` 压力模式和 overflow/队列状态断言。
- ROB admission 只读取寄存后的 `alloc_seq_q/out_seq_q/old_u_q` 和当前队首
  数量；不再把本拍 `picked` 或 `exit/pop` 接入 admission。允许进入的硬边界
  为 live occupancy `<=31`、reuse span `<=25`，并逐拍断言两项均不越界。
- 早期版本保留 E068 同拍 issue credit 时 nominal 最大 arrival 代理为
  0.9225 ns；只删除 issue credit 后仍因 retirement credit 形成
  `exit_idx → admit → alloc → crit` 路径，最大值为 0.9150 ns。两版均否决。
  最终提交删除 admission 的所有同拍 progress credit，三 corner 最大值恢复
  到 E068 的 0.7950/0.8675/0.9400 ns。
- 最终重载 seeds 3/5/7/11/13/17/19/23/29 cycles 为
  8115/8101/8074/8068/8132/8045/7924/8013/8014；DEPHEAVY seeds
  7/19/41 为 14119/13999/13991。`BKPRLAG=1` 的 60k DEPHEAVY 为
  42474，所有功能、复用、occupancy 和队列断言通过。
- 配对 ABC simple 总 cells 为 157509（E068 为 148066），时序状态位
  6935（E068 为 5861）。这只是通用门级代理；新增缓冲可能增加面积、时钟
  功耗和布局拥塞，最大 arrival 数值相同也不能替代 0.045 ns uncertainty
  下的真实 STA。真实最大路径、违例数、面积和活动率功耗不合格时拒绝 E074。

### E078 head/tail spill 记录

- E077 先把 E074 的 q0/q1/q2 移位队列改为 q0 加两个固定 spill bank，
  删除 spill bank 之间的 532-bit 复制；E078 再采用独立 head/tail 指针，
  使每个 spill 宽数据寄存器只从 `in_data_f/in_ctrl_f` 接收 enqueue 写入。
  q0 仍是唯一队首，ROB admission、安全阈值和 BKPR 响应容量均未改变。
- quick、重载 seeds 3/5/7/11/13/17/19/23/29、DEPHEAVY seeds
  7/19/41、60k `BKPRLAG=1`、mid/sparse、dual/full 均通过；所有 cycles
  与 E074 精确一致。额外断言覆盖 overflow、count/valid 一致性以及
  empty/single/full 三种 spill 指针关系。
- 同一 ABC simple 流程下，E068/E074/E077/E078 总 cells 分别为
  148066/157509/155379/151871；时序状态位为 5861/6935/6936/6937。
  因此 E078 相对 E068 的总 cells 代价从 E074 的 +6.38% 压到 +2.57%，
  组合 cells 仅 +1.92%；相对 E074 总 cells -3.58%、组合 cells -3.75%。
- E078 low/nom/high 最大 arrival 代理与 E068 完全相同，仍为
  0.7950/0.8675/0.9400 ns。nominal `>.400 ns` 端点从 E074 的 12727
  降到 11728，但仍显著多于 E068 的 907；最大值不恶化不等于物理时序
  已签核，必须在相同约束下检查真实 worst path、uncertainty 和拥塞。
- heavy 平均 cycles 9052.333→8054 后，单独的 T^4 因子为 1.596。
  除以 cell-area 比值得 1.556；再保守假设 Power 与 cells 同比例增加，
  代理仍为 1.517。该数字用于筛选，不替代统一用例 T、真实 Area/Power
  和最终 score。

## 分支与提交约定

- `main`：稳定参考，不直接堆实验。
- `timing/4fe-pick-safe-v1`：当前 timing-safe 版本。
- `timing/4fe-pick-commit-v2`：从 safe-v1 创建，切断
  `old_u_q → pick → rob/iss_q` 路径；不要覆盖 v1。
- `timing/4fe-hier-pick-v3`：从 safe-v2 创建，针对 E003 的三组
  新关键路径；safe 配置关闭偷取，dual/full 配置仍可开启双偷取。
- `timing/4fe-picked-bitmap-v4`：从 safe-v3 创建，切断
  `pk_idx_q → picked → next-pick/old_u`，并去除 crit/outp 的逐位 ICG 使能。
- `timing/4fe-safe-selector-v5`：从 safe-v4 创建，精简 safe 模式的
  单主候选选择网络，并将 ROB oldest-unissued 搜索改为 8×8 分层结构。
- `timing/4fe-rob32-v28`：从 E021 创建的 E029 独立实验；ROB 32 项、
  picker 4×8。不得在统一用例 T 未确认前替换 E021。
- `codex/e066-v28-reuse-window`：从原始 v28 创建的独立 E066；只回收
  ROB reuse-window credit，明确禁止混入 E064/E065。
- `codex/e067-e066-retire-cleanup`：从 E066 创建的独立 E067；删除
  冗余退休位图，为后续动态 BKPR credit 提供时序余量。
- `codex/e068-e067-dynamic-bkpr-credit`：从 E067 创建的独立 E068；只用
  本拍实际进度动态释放 credit，固定安全阈值不变。
- `codex/e074-e068-ingress-admission`：从 E068 RTL 提交独立创建；用入口
  弹性缓冲承担 BKPR 响应尾，picker/issue/wake/egress 保持 E068 不变。
- `codex/e077-e074-circular-spill`：从 E074 创建；以固定 spill bank 删除
  宽队列逐拍移位，保留为 E078 的中间检查点。
- `codex/e078-e077-head-tail-spill`：从 E077 创建；以独立 head/tail 指针
  规整 spill bank 写使能，是当前大幅提分候选。
- RTL、验证、文档分开提交。综合结果文档提交引用被测 RTL SHA，
  不通过 amend 改写已经送入内网综合的 RTL 提交。
