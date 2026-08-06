# 4FE 仿真、STA 与 PPA 实验记录

本文件是 4FE 优化的唯一对比表。每次内网综合必须对应一个 Git
提交，禁止只修改工作区后记录结果。评分中的 `T` 是统一用例的最终
执行时间，不是单独的时钟周期或重载吞吐。

## 记录规则

1. RTL 变化先提交，记录完整 Git SHA。
2. 综合脚本、工艺库、corner、时钟约束和活动文件必须保持一致；
   任一项变化时新开一组实验，不与旧数据直接比较。
3. 同时记录所有统一用例的 cycles，并计算
   `T = clock_period × weighted_total_cycles`。
4. 记录 worst path 的 startpoint、endpoint、arrival、required 和
   slack；不能只记录 slack。
5. Area、Power、T 均齐全后再计算
   `score = 1 / (T^4 × Power × Area)`。
6. 原始报告保存在内网归档中，归档目录名使用实验 ID 和完整 SHA。
7. 修改前必须检索全部 Git 历史；相同流水化、ready-class 打拍、picked
   位图复制或 target/read-select retime 不得重复提交。

## 官方评估条件

- DCG corner：`T7+ / H240 / ssgnp / 0.675 V / 125 C`。
- 时钟周期由 `design/hdl/bes_cfg.csh` 设置，clock budget 为设置周期的
  `0.9` 倍；周期与负载用例必须和内网综合保持一致。
- 频率大于 1.5 GHz 时 ICG 额外 delay 为 50 ps，否则为 100 ps；clock
  uncertainty 以同一份时序报告为准，周期小于 0.4 ns 时固定为 35 ps。
- 功耗使用 PTPX 输出的瓦数；统一评分为
  `score = 1 / (T^4 * Power * Area)`，其中 `T` 是官方混合负载的 elapsed
  execution time，不是单个局部回归的周期数。
- 官方负载为 41.7% / 90%，报文占比为 1 / 2；无反压时每 20000 cycle
  分别注入 16680 和 36000 个报文。存在反压时注入比例保持不变。

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
| E029 | `3bc99500489ab67a8333db3a12b06773a47b1ffd` | ROB32 safe-v5，DUAL_STEAL=0 | 10337 | 11719 | 25028 | 0.2821 | -0.3470 | -0.0649 | 22101 | — | — | — | E021 基线的独立 32-entry ROB；物理组织为 4x8，不是 8x8 |
| E039 | `abcda49` | ROB32 safe-v5，DUAL_STEAL=0 | 10337 | 11719 | 25028 | 待内网综合 | 待内网综合 | 待内网综合 | 待内网综合 | 待内网综合 | 待内网综合 | 待内网综合 | 同拍更新 `old_u_idx_q` shadow，picker 从独立 Q 读取 `rbase`；不增加 issue/FE 周期 |

## E039 实施审计

- E030 的 4x16 P0/P1、AB-P8 的 8x8 pipeline 已存在，E039 没有重复插入
  picker pipeline，也没有修改最终 `pk_*` 的 issue 边界。
- E032 的 ready-class bitmap 打拍已被综合拒绝，原因是 `picked_q` 反馈
  扇出使 WNS 恶化；E039 不复制 ready bitmap，不把 `picked_q` 重新送入
  class selector。
- E039 在 ROB 中用与 `old_u_q` 完全相同的 `old_u_n` 同拍更新 5-bit
  `old_u_idx_q`，只将 picker 的 `rbase` 起点从该 shadow Q 接入。它是
  fanout/register-duplication 候选，不是增加一级架构流水。
- 仅当官方 cycles 不增加、picker 目标路径改善且 Area/PTPX Power 的增量
  没有抵消时序收益，才允许进入组合版本；否则保留 E029 为基线。

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
- RTL、验证、文档分开提交。综合结果文档提交引用被测 RTL SHA，
  不通过 amend 改写已经送入内网综合的 RTL 提交。
