# 4FE 仿真、STA 与 PPA 实验记录

本文件是 4FE 优化的唯一对比表。每次内网综合必须对应一个 Git
提交，禁止只修改工作区后记录结果。评分中的 `T` 是统一用例的最终
执行时间，不是单独的时钟周期或重载吞吐。

## 记录规则

1. 修改 RTL 前必须检索全部 Git 历史和分支，核对是否已有相同或实质
   相似的实现。记录匹配的提交/分支、代码差异和新方案的关键路径假设；
   没有实质架构差异时禁止重复实验。
2. 只有在新的架构条件会改变原实验结论时才允许重试旧思路，并在写
   RTL 前明确记录该条件、预期收益和失败判据。
3. RTL 变化先提交，记录完整 Git SHA。
4. 综合脚本、工艺库、corner、时钟约束和活动文件必须保持一致；每次
   记录 `bes_cfg.csh` 周期、实际频率、0.9 clock budget、ICG delay 档位
   和报告中的 uncertainty。任一项变化时新开一组实验，不与旧数据
   直接比较。
5. 记录官方 41.7%/90% 混合负载的最终 elapsed cycles，并计算
   `T = configured_clock_period × official_elapsed_cycles`。本地 heavy、
   mid、sparse、dep-heavy 只作为筛查和回归数据。
6. 记录 worst path 的 startpoint、endpoint、arrival、required 和
   slack；不能只记录 slack。
7. Area、PTPX Power（W）、T 均齐全后再计算
   `score = 1 / (T^4 × Power × Area)`。
8. 原始报告保存在内网归档中，归档目录名使用实验 ID 和完整 SHA。
9. 官方 DCG、频率、ICG 和负载条件统一见
   [`evaluation-conditions.md`](evaluation-conditions.md)。

## E031-R64 实施前查重

- 基线：E021 `c30a55d9d21faea805f500ddc8497ed70322ed15`，保持
  64-entry ROB、接口、BKPR 阈值和流水级不变。
- `489c76a2175aaafec2545f1c854e57b987c0b067` 已将 ROB oldest
  search 改为 8x8 分层结构，但仍使用 rotate、priority encode、bank
  index add 和动态 local-bank 读取。
- `c30a55d9d21faea805f500ddc8497ed70322ed15` 已在 picker 中使用
  fixed-order bank selector，但没有修改 ROB 的 `peH`。
- `3bc99500489ab67a8333db3a12b06773a47b1ffd` 在 32-entry ROB 中
  使用过四 bank 固定 case，但同时改变容量和 BKPR，且仍动态读取
  local bank；重载 cycles 增加 68%，不能归因到 selector。
- 本候选只把 64-entry ROB `peH` 的跨 bank 搜索改为固定顺序，并由
  case 分支直接返回 physical bank/local index，消除 rotate、index add
  和动态 local-bank read，不改变可见周期语义。
- 预期目标：缩短 `picked/old_u_q -> old_u_q.D` 及其 clock-gating cone；
  单独运行时不承诺越过 E021 picker WNS。任一标准用例 cycles 变化即判
  功能/性能失败；综合后若目标路径、面积或功耗无净收益则不进入组合版。

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
| E031-R64 | `aa33b5f6284e7f65fde048e6a9cba9d333d4fb80` | E021 + ROB fixed-order | 6154 | 9932 | 25024 | — | — | — | — | — | — | — | 待内网 STA/PPA；dep-heavy 11291 cycles，与 E021 四项完全一致；旧/new `peH` 通过空集、全 1、全部 single/two-bit 和 200k 随机状态等价检查；同流程 Yosys 273267→273093 cells（-174，-0.064%） |

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
- `timing/4fe-rob-onehot-v30`：从 E021 精确 SHA 创建，只隔离 64-entry
  ROB fixed-order bank/local selector；内网结果确认前不与 picker 候选合并。
- RTL、验证、文档分开提交。综合结果文档提交引用被测 RTL SHA，
  不通过 amend 改写已经送入内网综合的 RTL 提交。
