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
| rob64-iq32-safe | 0 | 0 | 0 | E042：64 项 Storage ROB、32 项 IQ、寄存化分配边界 |
| rob64-iq32-retire-decoupled | 0 | 0 | 0 | E046：E042 上解耦退休、issue commit 与 `old_u` 前瞻反馈 |
| rob64-iq32-pipelined-old-u | 0 | 0 | 0 | E047：E046 上将 `old_u` 追赶拆成 16 项捕获与编码/推进两相 |

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
| E042 | `0b9b8db4cde9cdca31840bc3f84bf52b6ad902c3` | rob64-iq32-safe | 6531 | 9933 | 25025 | — | — | — | — | — | — | — | V28 独立分支上的 Storage ROB / IQ 解耦候选：64 项数据/结果/退休 ROB，32 项描述符 IQ；IQ 分配预约寄存，32×32 顺序矩阵 + 五层 OR picker，一元 Kogge-Stone 四路空槽分配；ROB `old_u` 用 one-hot 影子和每拍 8 项 bounded catch-up。依赖重载 12073 cycles，dual/full 重载 6366/5931，普通重载 8 seeds 与依赖 3 seeds 全部通过。统一 Yosys 代理为 299113 AND / 190970 NOT、全设计深度 56、IQ 31、picker 47；V28 为 144256/94141、全设计 54、picker 44。重载 `cycles×depth` 粗代理相对 V28 -34.5%，但 AND+NOT 为 2.05×，必须用固定内网 STA/Area/Power/统一用例确认最终 T 与 Score。 |
| E046 | `4e5324f2038c7554f6e892c024ed25ffc35eef3f` | rob64-iq32-retire-decoupled | 6660 | 9936 | 25026 | — | — | — | — | — | — | — | E042 正向时序候选：退休端删除冗余 `outp_q/pop_oh` 位图，以 `out_seq_q` 的 one-hot 影子和 `alloc_seq-out_seq` 有效数检查四个连续结果；去除 FEOUT→pop/data 同拍旁路，结果写入 ROB 后下一拍才可退休。picker 不再寄存 64-bit `picked_rob_q`，而由寄存的 8×8 坐标重建 ROB commit bitmap；`picked_iq_q` 直接使用 selector 的 one-hot；ROB `old_u` 仅消费已提交 `iss_q`，切断 picker→old_u 前瞻。quick、普通重载 9 seeds、依赖重载 3 seeds、dual/full 均通过；依赖重载 12159，dual/full 6524/6019。统一 memory-map + `abc -g simple` 后，经验门延迟名义全局路径从 E042 的 0.9225ns 降到 0.8675ns（`iss_q → old_u_q`，31 级，2 XOR + 13 AND + 14 OR + 1 MUX + 1 NOT），>0.355/>0.400ns 端点从 2503/1444 降到 1298/933；uncertainty=0.045ns 时，heavy `cycles×(path+uncertainty)` 代理改善 3.82%。旧 `make proxy` 口径为 292587 AND / 187482 NOT、全设计深度 54，较 E042 的 299113/190970、深度 56 同时下降；仍远未达到 0.4ns 周期，需继续优化 `old_u`、IQ ready 和 picker。 |
| E047 | `f73db961727e846913b406f8990188b392c73d14` | rob64-iq32-pipelined-old-u | 6853 | — | — | — | — | — | — | — | — | — | 负向、隔离保留：把 `old_u` 追赶拆为 16 项 issued 窗口捕获和下一拍编码/推进。quick 全部通过，重载 seed 7 与依赖重载分别为 6853/12354；但统一 memory-map + `abc -g simple` 后名义关键路径反而为 0.9225ns（`issued_scan_q[14] → old_u_q[6]`，33 级，2 XOR + 14 AND + 15 OR + 1 MUX + 1 NOT），说明寄存输入后的 16 项编码仍与指针更新串联。相对 E046，heavy cycles +2.90%、组合周期 +6.34%；计入 0.045ns uncertainty，`cycles×(path+uncertainty)` 恶化 9.10%。不合入 E046，后续改攻 picker→结果预测→IQ ready 路径。 |

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
- `codex/4fe-rob32-decoupled-iq-v42`：从已恢复的 V28/E029 创建；E042
  将 64 项 Storage ROB 与 32 项 IQ 解耦，不改写 `timing/4fe-rob32-v28`。
- `codex/e046-e042-rob-retire`：从 E042 创建；解耦退休、picker commit
  与 `old_u` 前瞻，作为后续时序优化的新候选，不改写 E042。
- RTL、验证、文档分开提交。综合结果文档提交引用被测 RTL SHA，
  不通过 amend 改写已经送入内网综合的 RTL 提交。
