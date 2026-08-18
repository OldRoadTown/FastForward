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
| rob32-ap-safe | 0 | 0 | 0 | v28 周期/逻辑时序不变约束下精简冗余 ROB 元数据 |
| rob32-reuse17-safe | 0 | 0 | 0 | E064 上按依赖距离与 BKPR 在途上界证明回收 reuse window |

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
| E064 | `3cd2531e22e8561b67d3ed9e326d97424c89a983` | rob32-ap-safe | 10337 | 11719 | 24910 | — | 0.8875* | — | 148331* | proxy↓* | — | — | 从原始 v28 树 `626413e` 独立派生；删除 32-bit `rob_isdep`，safe 配置复用已有 `rob_lat` 代替 64-bit `rob_src`，dual/full 保留原表。当前工具环境重建 v28 后，quick、heavy/mid/sparse、dual/full 周期逐项完全相同；normal 9 seeds、DEPHEAVY 3 seeds 全通过。星号项均为同脚本逻辑代理，不是内网 PPA 签核。 |
| E065 | `2fef005e18209f68a7503cf091b9f2391a6dee78` | rob32-reuse17-safe | 9567 | 10961 | 24907 | — | 0.8875* | — | 148321* | flat* | — | — | 将 `WIN_TH` 从13提高到17：最新 allocation 相对 first-unissued 最多为 D-8，覆盖最大依赖距离7；再为两拍 BKPR 保留8个在途包，因此阈值为 D-7-8。新增仿真期逐拍 `reuse_span` 安全断言。heavy/mid 分别较 E064 -7.45%/-6.47%，dual/full 为9512/8432；normal 9 seeds、DEPHEAVY 3 seeds及60k依赖长跑通过。 |

E064 的同流 Yosys/ABC 对比：总 cells `148944 → 148331`（-613，
-0.412%），时钟状态位代理 `5893 → 5797`（-96，-1.629%），主要组合
门代理 `143041 → 142524`（-517，-0.361%）。按项目经验门延时模型计算的
low/nom/high 最长组合路径均为 `0.8100/0.8875/0.9650 ns`，与重建的
v28 基线完全相同；nominal 下超过 0.355 ns 的 endpoint `1503 → 1477`，
超过 0.4 ns 的 endpoint 保持 1198。由于本地没有目标 liberty、布局布线
寄生和 SAIF/VCD 活动，Power 仅由时钟状态位与组合单元/切换电容趋势代理，
最终面积、功耗和时序必须以内网同约束报告签核。E029 稀疏历史值 24969 与
当前 Verilator 环境重建值 24910 不同，因此 E064 的“周期不变”结论使用同一
当前工具版本重建 v28 后的逐项 A/B，而不跨工具版本直接比较历史数值。

E065 不增加状态、流水级或 picker 逻辑。相同 Yosys/ABC 流程下总 cells
`148331 → 148321`，时钟状态位保持5797，主要组合门代理
`142524 → 142514`；low/nom/high 最长组合路径保持
`0.8100/0.8875/0.9650 ns`。ABC 的 nominal `>0.4 ns` endpoint 数由
1198变为1463，虽然 worst arrival 不变，仍需以内网 STA 同时确认 WNS/TNS，
不能仅凭本地最长路径代理宣称物理时序完全等价。普通 heavy 9-seed 平均
cycles 下降7.48%，DEPHEAVY 3-seed 平均下降5.54%；在时钟周期不变且面积、
功耗近似不变的前提下，seed7 的 T 代理下降7.45%，仅 T 四次方评分项约
提升1.36倍。

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
- `codex/v28-area-power-opt`：从原始 v28 创建的 E064 独立实验；只接受
  周期逐项不变且 low/nom/high 逻辑延时代理不恶化的面积/功耗候选。
- `codex/e065-e064-precise-reuse-credit`：从 E064 创建；以最大依赖距离和
  BKPR 在途上界重新证明 ROB reuse window，并用仿真期断言覆盖实际分配边界。
- RTL、验证、文档分开提交。综合结果文档提交引用被测 RTL SHA，
  不通过 amend 改写已经送入内网综合的 RTL 提交。
