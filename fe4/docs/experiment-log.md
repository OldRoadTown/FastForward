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

## 赛题时钟与评分约束

- DCG 环境为 T7+、H240、ssgnp、0.675 V、125 C；时钟周期由
  `design/hdl/bes_cfg.csh` 设置，综合和性能用例使用同一设置。
- 对候选容量 `D`，最终执行时间必须按同一个统一性能用例计算：
  `T_D = converged_period_D × total_cycles_D`。不同容量必须分别寻找自己
  的可收敛周期，不能用固定周期下的 cycles、WNS 或面积单项排名。
- 基础 setup budget 为设置周期的 `0.9`。频率高于 1.5 GHz 时 ICG
  delay 为 50 ps；频率小于等于 1.5 GHz 时为 100 ps。时钟周期小于
  0.4 ns 时 uncertainty 固定为 35 ps，其余档位以实际时序报告为准。
- 功耗使用 PTPX 输出的瓦数。最终比较量为
  `score_D = 1 / (T_D^4 × PTPX_power_D × DCG_area_D)`。
- 性能和功耗用例使用相同种子与负载分布；41.7% 和 90% 两段的发包
  数量比例为 1:2。设计发生反压时，必须计入延长后的完整用例 cycles。

## ROB 深度得分搜索实施前查重

- 独立分支：`ab/4fe-rob-depth-score-v33`；RTL 基线为 E021
  `c30a55d9d21faea805f500ddc8497ed70322ed15`。该分支不纳入 E021
  之后的时序主线，也不叠加任何 picker/ROB 优化候选。
- 已有 E029-R32 RTL
  `3bc99500489ab67a8333db3a12b06773a47b1ffd` 已从 E021 实现 32-entry
  ROB、5-bit physical index、6-bit sequence、4x8 picker/read hierarchy 和
  23/13 BKPR threshold。不得重复同一实现。
- E029-R32 当前统一种子 heavy/mid/sparse/dep-heavy 为
  `10337/11719/25028/16143` cycles；E021 为
  `6154/9932/25024/11291`。R32 虽将通用 Yosys 全设计组合门代理约
  减半，但 heavy cycles 增加 `68.0%`，不能只凭面积或时序改善判为
  高分。
- E021 的 64-entry ring 直接用 sequence low bits 寻址。32/64/128 等
  2 的幂容量可保持这种映射；40/48/56 等容量需要显式 modulo wrap，
  因此先用等效 BKPR 容量代理筛选周期，只有存在总分潜力才实现真实
  storage/index/selector，避免为低收益点引入额外环形指针逻辑。
- 搜索目标是最高最终分数
  `1 / (T^4 * Power * Area)`。所有候选先保持与 E021 相同配置、用例和
  `0.4 ns` 时钟周期归因；本地 cycles 与通用 Yosys 只用于淘汰。最终
  必须使用内网 DCG area/STA、PTPX watts 和完整性能用例 elapsed time。
- 候选顺序：有效容量代理 `40/48/56`，E021 `64` 基线，以及 `128`
  上界筛选。16-entry 小于当前 19-entry 安全 reserve，直接排除；大于
  128 的容量在吞吐理论上限下无法合理覆盖 storage/selector 面积功耗，
  除非 R128 实测出现反常的显著得分收益，否则不继续扩大。

## ROB 深度本地筛选结果

容量代理仅改变 E021 的 BKPR 阈值，用于估计反压造成的 cycles 代价；
它不代表非 2 次幂物理环的时序、面积或功耗。41.7%/90% 是题目负载
分段代理，不等同于最终统一用例总 cycles。

| 容量 | 实现 | Heavy | Mid | Sparse | Dep-heavy | 41.7% | 90% | 相对 R64 负载 cycles |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| R32 | E029 真实 RTL | 10337 | 11719 | 25028 | 16143 | 12929 | 10471 | +40.1% |
| R40 | BKPR 代理 | 8359 | 10339 | — | — | 12046 | 8413 | +19.1% |
| R48 | BKPR 代理 | 7307 | 10001 | — | — | 11937 | 7303 | +9.2% |
| R56 | BKPR 代理 | 6601 | 9942 | — | — | 11913 | 6644 | +3.5% |
| R64 | E021 基线 | 6154 | 9932 | 25024 | 11291 | 11910 | 6233 | baseline |

### R56 真实 RTL 候选

- RTL SHA：`fa59adaaed5fed69f9462e9e8c4f6b4a6a016602`。
- 配置：56 entries、6-bit physical pointer、7-bit logical sequence、7x8
  picker/read hierarchy；逻辑 sequence 与 physical ring pointer 分离。
- 本地 long regression 为 `6601/9942/25024/12059` cycles，41.7%/90%
  代理为 `11913/6644`；20 组 safe 和 12 组 dual/full 均与 R56 BKPR
  容量代理逐项同 cycles、同 BKPR。
- 通用 Yosys 代理：picker `32441 cells / depth 40`，full design
  `422839 cells / depth 81`；E021 对应为 picker
  `36681 / depth 42`、full design `481560 / depth 80`。面积代理约减
  `12.2%`，但 full depth `80 -> 81`，必须等待内网候选自身的收敛周期、
  DCG area 和 PTPX power 后才能判断得分。

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
