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

## DCG 环境与评分约束

- 工艺环境：`T7+ / H240 / ssgnp / 0.675V / 125C`。
- 时钟周期由 `design/hdl/bes_cfg.csh` 设置；综合与性能用例使用同一设置。
- clock budget 为 `0.9 × clock_period`。频率 `>1.5GHz` 时额外扣除
  `50ps` ICG delay，否则扣除 `100ps`；clock uncertainty 按时序报告记录，
  周期 `<0.4ns` 时固定为 `35ps`。
- ICG 必须使用工艺库支持的 instance，并同步更新 `rtl_sim.f` 中的库文件。
- 不限制 LVT/ULVT 比例；功耗以 PTPX 输出的瓦数计入评分。
- 官方两个用例使用相同种子和负载分布：`41.7%` 负载占 `1/3` 报文，
  `90%` 负载占 `2/3` 报文。存在反压时保持报文比例，但阶段 cycle 数不必等分。
- 评分目标为 `1 / (T^4 × Power × Area)`；其中 `T` 是统一性能用例的
  实际 elapsed execution time，不是局部仿真的单个周期数。

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
| E040 | `490cdf8` (`c30a55d9` 基线) | safe-v5 | 6269 | 9933 | — | 待内网 | 待内网 | 待内网 | 待内网 | 待内网 | 待内网 | 待内网 | E021 独立分支；P0 8×8 局部 first/second winner + target/local one-hot 元数据寄存，P1 做全局 circular select；`wake_now` 纳入 P0 预测；`WIN_TH=47`。稀疏长用例尚未重新执行 |

## E040 变更与查重

E040 从 E021 提交 `c30a55d9d21faea805f500ddc8497ed70322ed15` 单独开枝，
不修改 E021 主线或历史迭代分支。实现目标是把 picker 的候选生成和全局选择
拆成 P0/P1 两个时序边界：P0 在八个 8-entry bank 内预计算两个候选，并把
`valid/index/target/bank-one-hot/local-one-hot` 作为同一事务寄存；P1 只做
消费校验、环形 bank 顺序选择和 payload mux。`wake_now` 用于生成下一拍可见的
ready candidate，保持数据与目标元数据对齐。该预测会增加寄存器和选择元数据，
因此最终是否值得采用必须由 DCG 的 STA、Area、PTPX Power 和官方 T 联合判断。

历史查重结论：E030 (`ab82ae6`) 已做 4×16 P0/P1 流水化，AB-P8
(`d9752e6`) 已做 8×8 P0/P1 流水化，E032 (`5e5e322`) 已做 ready-class
打拍且因 `picked_q` 扇出导致时序恶化；E040 保留同一研究方向，但改为 bank-local
双候选、完整元数据随拍和 `picked` one-hot stale 校验，不直接复制这些实验。
ROB32/48/56 与 target retime、ROB read-select retime 等也已检查，本次不重复修改。

本地 Verilator 回归（`REG_FEIN=0, WAKE_BYPASS=0, DUAL_STEAL=0`）结果：

| 用例 | cycles | 结果 |
|---|---:|---|
| quick 100%, 500 packets, seed 3 | 167 | PASS |
| quick 50%, 500 packets, seed 4 | 268 | PASS |
| quick 20%, 500 packets, seed 5 | 594 | PASS |
| mid 50%, 20000 packets, seed 11 | 9933 | PASS |
| heavy 100%, 20000 packets, seed 7 | 6269 | PASS |
| dependency-heavy, 90%, 60000 packets, seed 17 | 34342 | PASS |

E040 的 `WIN_TH=49` 对照在官方重载为 `6270` cycles，略差于 `WIN_TH=47`
的 `6269`，所以保留 `47`。当前尚无 DCG 综合、PTPX 功耗、面积、worst path
和官方 elapsed `T`，不能据本地 cycles 单独宣称得分提升。

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
- `ab/4fe-e021-two-stage-predict-v40`：从 E021 独立创建的 E040 候选，
  只用于与 E021/E029 的内网 STA、PTPX 和官方性能用例做 A/B，不纳入主线迭代。
- RTL、验证、文档分开提交。综合结果文档提交引用被测 RTL SHA，
  不通过 amend 改写已经送入内网综合的 RTL 提交。
