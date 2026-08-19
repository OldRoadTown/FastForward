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
| rob32-dynamic-credit | 0 | 0 | 0 | E067；用本拍实际退休/发射推进精确解除 BKPR |

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
| E068 | `c6092b9185710eaedbcbfcaeee78e3db0e76f6c2` | rob32-dynamic-credit | 9070 | 10667 | 24907 | — | — | — | 148066† | — | — | — | 从 E067 独立派生；BKPR 不提高固定 23/17 安全阈值，只将本拍实际 `pop_therm` 和最多四项、由 allocation frontier 限定的连续 `iss_eff` 作为 retirement/old-u credit。九个重载 seed 平均 cycles 相对 E066 -5.12%，三个 DEPHEAVY seed -1.94%，mid -2.68%，60k -1.83%，sparse 不变；dual/full seed7 为 9018/7949。low/nom/high 最大 arrival 代理与 E067 同为 0.7950/0.8675/0.9400 ns，低于 E066 上限；关键路径转为 `exit_idx → out_seq_q`。总 cells 较 E067 +78、较配对 E066 -272。所有复用、退休、credit 不超实际进度断言通过；真实 STA/Power/统一 T 待测。 |

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
  解除 BKPR 提供时序余量；该后续候选已在 E068 实现。更后续的候选仍须
  以 E066 的三 corner 最大值为上限。

### E068 动态 credit 记录

- E068 判断等价于对退休使用 `occ-pop_count > 23`，对发射窗口使用
  `win-guaranteed_advance > 17`；实现采用 thermometer 和五组固定阈值，
  没有把通用减法器或完整 `old_u_n` 搜索接到 `bkpr_r`。
- guaranteed advance 只扫描 `old_u_q` 起的前四项，并由
  `alloc_seq_q-old_u_q` 限定，故不会把回绕后未分配 entry 的陈旧 issued
  状态作为 credit。仿真逐拍断言 credit 不超过真实 `old_u_n-old_u_q`。
- 重载 seeds 3/5/7/11/13/17/19/23/29 的 cycles 为
  9142/9076/9070/9041/9122/9046/8928/9015/9031；DEPHEAVY seeds
  7/19/41 为 15028/14854/14832。计入 nominal arrival 代理后，heavy
  `cycles×period` 相对 E066 约改善 7.26%，但不能替代统一用例 T。
- E068 更高吞吐可能继续提高单位时间翻转率；在新功耗报告返回前不宣称
  功耗改善，也不使用 cell count 代替活动率功耗。
- 为确认新增 BKPR 逻辑的收益/代价，另从 E068 建立两个隔离分支。E068A
  只保留 retirement credit：九个重载 seed 平均 9265.222 cycles（相对
  E066 -2.889%），三个 DEPHEAVY seed 平均 15120（-0.520%），mid 为
  10847、60k DEPHEAVY 为 45403；low/nom/high 最大 arrival 代理为
  0.7850/0.8600/0.9350 ns，总 cells 147721。E068B 只保留 issue credit：
  重载平均 9402.222（-1.453%），DEPHEAVY 平均 15005（-1.276%），mid
  为 10841、60k DEPHEAVY 为 45082；arrival 代理为
  0.7950/0.8675/0.9400 ns，总 cells 148451。
- 两路 credit 对不同阻塞负载互补：完整 E068 的重载/DEPHEAVY 平均分别
  为 9052.333/14904.667，均优于任一单路候选。按 nominal arrival 计算，
  E068A、E068B、完整 E068 的 `cycles×period` 相对 E066 分别约
  -5.90%、-3.67%、-7.26%；以降低 T 为首要目标时继续保留完整 E068。
  E068A 是真实 STA 或功耗不通过时的低逻辑量回退候选。
- 仓库没有提交 `.sdc`、工艺库、真实 STA/功耗脚本，本机也没有 OpenSTA；
  上述结果仅为同一 Yosys/ABC/Verilator 流程的配对代理，真实
  `0.045 ns` uncertainty 与活动率功耗仍需外部签核。

### E069 否决与 E070-P 气泡画像

- E069 的 32-entry registered prewake 在本地门延迟代理中最大 arrival
  没有超过 E068，但真实 STA 已确认明显恶化，因此判定失败且不得作为
  后续 base。原因是 issue/far tag 对 32 项 waiting state 的全局比较造成
  高扇出、布线拥塞和大量新增近临界端点；E070 重新从 E068 派生。
- E070-P 提交 `9055306` 只在 testbench 增加层级探针，不修改任何综合
  RTL、DUT 端口或配置，所有 cycles 与 E068 完全一致。画像统计 issue/
  retirement 宽度、picker 空闲归因、BKPR credit、`old_u` 状态和真实
  可偷取机会。
- heavy seeds 3/7/19 中，`old_u` 一拍推进超过四项平均占 17.10% 周期，
  且 10.16% 的总周期同时处于 BKPR；DEPHEAVY seeds 7/19/41 对应
  9.07%/7.10%，mid seed11 对应 13.48%/2.18%。E068 当前只承认最多
  四项 advance credit，存在可测的保守解除空间。
- 扣除 donor 自身主发射并检查 receiver scheduler 冲突后，至少存在一个
  可偷取机会的周期占 heavy 51.70%、DEPHEAVY 25.41%、mid 41.44%。这是
  理论机会而非可直接相加的 cycles 收益；已有 dual-steal 实测收益仅约
  0.6%，说明实现方式和时序代价比机会计数更关键。
- `old_u` 处于 waiting 时，其 target 在上述全部画像中 100% 已经 issued；
  retirement 的首个阻塞项也没有落在 waiting 状态。因此否决单纯的
  head-of-line producer priority：生产者优先级已经无法缩短这些等待，
  主要瓶颈是已发射结果延迟、class 利用率和保守 BKPR。
- 下一步先隔离评估 8-entry exact advance credit：保持 23/17 安全阈值，
  仅扩展 BKPR 对连续 `iss_eff` 的精确 credit，不连接 picker、wake、FE
  数据或 `exit_idx → out_seq` 路径。若真实 STA 不劣于 E068 且 cycles
  有稳定收益，再考虑比现有 dual-steal 更简单的单路寄存式偷取。

### E071 单入口 replay oracle

- E071 从 E068 的综合 RTL 独立派生；第一提交只增加 testbench oracle，
  不修改 DUT、综合 RTL、端口或配置。它只统计如下交集：`old_u` 正在等待
  依赖、该 target 已由 `pre_v` 预测在下一拍返回、正常 picker 为下一拍
  留下空 FE，且在该 FE 上预订 `old_u` 的 latency 不会造成返回槽冲突。
- heavy seeds 3/5/7/11/13/17/19/23/29 的 safe replay 机会为
  964/879/906/903/964/905/826/911/882，合计 `8140/81471=9.99%`
  总周期；对应 cycles 与 E068 逐项相同。DEPHEAVY seeds 7/19/41 为
  2584/2548/2576，合计 `7708/44714=17.24%`；mid seed11 为
  `1281/10667=12.01%`。全部功能检查通过。
- 该比例是“可在空 FE 上提前一拍发射最老依赖项”的动态机会，不是最终
  cycles 收益；下游资源和 workload 相互作用会令实际收益更低。但它已
  明显超过 3% 的实现门槛，因此允许进入单入口 registered replay RTL。
  实现不得把 wake 接回全局 picker，也不得恢复 E069 的 32-entry 全局
  tag 比较；若实际 cycles 收益不足 2% 或真实 STA 劣于 E068，则否决。

### E072-P completion capacity shadow

- E072-P 提交 `612679c4eb59ee29b68e07775cafedbd026baf15` 只修改
  testbench；综合 RTL、DUT 端口和 E068 cycles 完全不变。shadow 在与
  E068 `occ_over/win_over` 相同的决策时刻，统计32-entry decoupled IQ
  以及完成容量32/36/38/40/48/64的被动阻塞结果。模型保留两拍、最多
  8包的入口裕量；completion 阈值分别为23/27/29/31/39/55，IQ 保守
  使用23。该模型不改变 DUT 流量，因此结果是容量方向筛选，不是精确的
  counterfactual cycles。
- heavy 九个 seed 合计81471 cycles、36364次现有阻塞决策。完成容量
  32/36/38/40时分别可避免14002/34632/36176/36364次，即
  38.51%/95.24%/99.48%/100%；对应剩余shadow阻塞为
  22362/1732/188/0。heavy 的 post-progress completion 峰值31，
  IQ-after-progress 峰值20，说明当前 trace 中瓶颈是已发射未退休项，
  不是32-entry IQ容量。
- DEPHEAVY seeds 7/19/41 共29662次现有阻塞决策；容量36/38/40分别
  可避免28901/29604/29635次，即97.43%/99.80%/99.91%。容量40仍剩
  27次均为IQ压力，IQ峰值25。60k DEPHEAVY seed73的对应覆盖率为
  97.42%/99.78%/99.89%，结论一致。
- mid seed11在容量36/38/40下分别覆盖99.05%/100%/100%；sparse
  seed11没有现有容量阻塞。所有用例功能检查、live-entry partition和
  C32 occupancy等价断言通过，shadow没有产生当前决策之外的额外阻塞。
- 容量48和64在所有被测 trace 上均不优于40，因此排除直接ROB64。
  E072-P显著超过“至少15%可避免阻塞”的RTL筛选门槛；下一候选应从
  4-entry issued-completion spill（总完成容量36）开始，而不是扩大picker
  或统一ROB。RTL必须保持32-entry 4x8 picker，并单独解决6-bit epoch tag、
  spill结果返回、依赖结果读取和顺序退休合并；若heavy实际cycles改善
  不足5%或任一时序代理劣于E068，则否决。

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
- `codex/e068a-retirement-credit-only`：E068 retirement-only 隔离候选；
  用于真实 STA/功耗不通过时的低逻辑量回退评估。
- `codex/e068b-issue-credit-only`：E068 issue-only 隔离候选；收益弱于
  完整 E068，仅作为归因与复现实验保留。
- `codex/e070-e068-stall-profile`：从 E068 创建的非综合画像分支；只增加
  testbench 统计，用于否决 HOL priority 并选择后续优化方向。
- `codex/e071-e068-replay-oracle`：从 E068 综合 RTL 创建的独立 E071；
  先以 testbench oracle 量化单入口 replay 上限，再决定是否加入 RTL。
- `codex/e072-e068-capacity-shadow`：从 E068 综合 RTL 创建的纯验证画像；
  比较32-entry IQ与4/6/8项completion spill，不修改综合设计。
- RTL、验证、文档分开提交。综合结果文档提交引用被测 RTL SHA，
  不通过 amend 改写已经送入内网综合的 RTL 提交。
