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
| safe-v1 | 0 | 0 | 0 | 历史 timing-safe 参考 |
| safe-v2 | 0 | 0 | 0 | registered commit + in-flight mask |
| safe-v3 | 0 | 0 | 0 | 分层选择；关闭偷取；关键标记/egress 门控解耦 |
| safe-v4 | 0 | 0 | 0 | 寄存 picked 位图；ROB crit/outp 整向量 next-state |
| safe-v5 | 0 | 0 | 0 | safe 单主候选选择；ROB 8×8 分层 oldest-unissued 搜索 |
| rob32-safe | 0 | 0 | 0 | E021 选择策略；32 项 ROB，picker 为 4×8 分层搜索 |
| rob32-window | 0 | 0 | 0 | 原始 v28；仅回收经证明安全的 ROB reuse-window credit |
| rob32-retire-clean | 0 | 0 | 0 | E067；删除冗余退休位图并以 live count 限定退休 |
| rob32-dynamic-credit | 0 | 0 | 0 | E068；用本拍实际退休/发射推进精确解除 BKPR |
| rob32-registered-prewake | 0 | 1 | 0 | E069；寄存依赖 wake mask，不把 tag 比较接到 picker |

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
| E069 | `068ef8e9177b37f5bb347ff84cc9f6a86ed32bdd` | rob32-registered-prewake | 8359 | 10219 | 24907 | — | — | — | 155296† | — | — | — | 从 E068 独立派生；latency1 的 issue tag 与 latency2/3 的 scheduler slot3 tag 提前匹配依赖目标并寄存 32-bit `wake_bind_q`，picker 侧只有位与。latency0 不走组合 next-pick 预绑定，而以实际返回更新 ready。九个重载 seed 平均 8358.778 cycles（相对 E068 -7.66%），DEPHEAVY 三 seed 平均 13055（-12.41%），60k DEPHEAVY -12.38%，sparse 不变。low/nom/high 最大 arrival 代理为 0.7800/0.8475/0.9150 ns，均未超过 E068；关键路径仍为 `exit_idx → out_seq_q`。总 cells +4.88%，真实 STA/Power/统一 T 待测。 |

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

### E069 寄存预唤醒记录

- E069 不让当前 `issue_idx` 经 result bitmap、tag decode 和 picker 形成
  一条实时组合链。ROB 在前一拍用 latency1 的 issue tag、latency2/3 的
  scheduler slot3 tag 匹配依赖目标，只把 32-bit `wake_bind_q` 送到 picker。
  latency0 若要同样提前绑定必须依赖当前 next-pick，故明确留在实际返回后的
  ready 状态边界，避免重新接通 picker 反馈环。
- quick 三组 cycles 为 210/274/593。重载 seeds
  3/5/7/11/13/17/19/23/29 为
  8419/8382/8359/8372/8407/8367/8290/8344/8289，平均 8358.778；
  DEPHEAVY seeds 7/19/41 为 13131/13044/12990，平均 13055；mid、
  sparse、60k DEPHEAVY 分别为 10219/24907/39250。默认配置相对 E068
  的 cycles 改善分别为 heavy 7.66%、mid 4.20%、DEPHEAVY 12.41%、
  60k DEPHEAVY 12.38%。dual-heavy/full-heavy seed7 为 9196/8244。
- E068/E069 配对代理的 low/nom/high 最大 arrival 从
  0.7950/0.8675/0.9400 ns 降至 0.7800/0.8475/0.9150 ns；名义最大路径
  缩短 20 ps，仍为 `exit_idx → out_seq_q`。按 nominal arrival 计算，
  heavy、mid、DEPHEAVY、60k DEPHEAVY 的 `cycles×period` 代理分别改善
  9.79%、6.41%、14.43%、14.40%。这些数字不能替代统一用例 T。
- 新增逻辑不是免费收益：代理总 cells 148066→155296（+4.88%），时序
  cells 5861→5893；nominal 超过 0.400 ns 的端点由 875 增至 1431。
  因此只能结论为“代理最大路径未恶化且周期数下降”，不能宣称真实 STA、
  面积或功耗已经通过。若 0.045 ns uncertainty 下真实 STA 或功耗不通过，
  直接回退到 E068，而不是继续扩大组合旁路。
- 已否决且未保留的四个子方案：原始 bitmap 全旁路的 nominal 最大
  arrival 为 1.2175 ns；当前 tag 直接比较为 0.9625 ns；包含 latency0
  next-pick 的全预绑定为 0.9350 ns；额外寄存 FE source 后为 0.9075 ns。
  它们均比 E068 的 0.8675 ns 恶化，工作区中没有相关 RTL 残留。

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
- `codex/e069-e068-registered-prewake`：从 E068 创建的独立 E069；只保留
  latency1..3 的寄存预绑定，latency0 不接 next-pick 组合反馈。
- RTL、验证、文档分开提交。综合结果文档提交引用被测 RTL SHA，
  不通过 amend 改写已经送入内网综合的 RTL 提交。
