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

## E031-R64 内网结论

- 结论：拒绝，不进入后续组合版本。虽然 clock-gating 路径改善为
  `sched_idx_q -> res_now -> old_u_q ICG/E`、slack `-0.0256 ns`，但
  全局 WNS、面积和违例数均劣于 E021。
- 相对 E021：WNS `-0.1684 -> -0.1774 ns`，恶化 9.0 ps；面积
  `31056 -> 31133`，增加 77（约 0.248%）；违例数 `10354 -> 10363`，
  增加 9。
- 新 worst path 回到 `rdy_q -> picker`：`u_rob/rdy_q_reg_8/Q ->
  u_pick/sel_tgt[8] -> u_pick/pk_tgt_q_reg_2_2/D`，required `0.2871 ns`，
  arrival `0.4645 ns`，slack `-0.1774 ns`。同组 `pk_idx_n`、`picked_n`
  和 `sel_local_oh` 路径分别为 `-0.1765`、`-0.1760` 和 `-0.1737 ns`。
- 独立 egress 路径 `sched_idx_q -> res_now -> egress/out_dat ->
  lane_d_f.D` 已达到 `-0.1769 ns`；另有终点为 `u_fe3/o_data_out_reg_10`
  的不可见全路径为 `-0.1719 ns`。因此即使只修 picker，egress/forward
  路径也会立即成为下一组 WNS。
- 该实现改善了局部 ROB/ICG cone，却因面积和逻辑重映射暴露并恶化
  picker/egress 主路径，不能视为总时序优化。后续候选必须从 E021 的
  精确 SHA 单独建分支，不允许在 E031-R64 上继续叠加。

## E032-C1 实施前查重

- 基线：E021 `c30a55d9d21faea805f500ddc8497ed70322ed15`；分支
  `timing/4fe-rdy-class-v31` 只携带实验规则和结果文档，不包含
  E031-R64 的 ROB RTL 修改。
- 全部既有 picker 版本都在 picker 内从 `rdy_q & (rob_lat == class)`
  生成四个 class candidate。`1df54843cc2c8308aa090c241db8086ec9a17a28`
  的 fast-bank-valid 和 `2d7556cdc5cc2e0db0b6d4dc59cc55b8bde48965`
  的 balanced mux/OR 均优化该 candidate 之后的逻辑，没有降低
  `rdy_q` 的四 class 扇出或移除 class compare。
- `aaa144eef8ace9395532d248faaad2f12237f432`、
  `bf364afc3ea874c0d93fafd4d5b080fedc551923` 分别尝试 4x16 hierarchy
  和六 bank 扫描，仍由同一组合 candidate 驱动；`ab82ae63ed11a2bac4aca49b96754e910d6cf5c0`
  和 `d9752e644aab6ce8b9bbedd574addec87d8d1712` 增加 picker 流水级，已知
  会增加重载和 dependency-heavy cycles，不与本候选等价。
- 本候选在 ROB 状态边界寄存四组 latency-class ready bitmap，直接
  替代 picker safe path 中的 `rdy_q -> class compare`。不增加流水级，
  不修改 oldest/critical-first 选择语义；保留 `rob_lat` 供 waiting wake
  和非 safe 配置使用。预计净增加 192 个状态位。
- 目标是同时缩短 E031 报告中的 `sel_tgt`、`pk_idx_n`、`picked_n` 和
  `sel_local_oh` 四组共享路径。egress/forward 不在本实验中修改，以便
  单独归因；picker 改善后允许 WNS 转移到已知约 `-0.17 ns` 的 egress
  路径。
- 任一标准 workload cycles 与 E021 不同即拒绝；若通用综合没有降低
  picker 逻辑深度，或内网 WNS 收益不足以覆盖面积/功耗增加，也拒绝且
  不进入组合版本。

## E032-C1 内网结论

- 结论：拒绝，不进入组合版本。在与 E021 相同约束的内网运行中，用户
  回报 WNS 约 `-0.20 ns`，明显劣于 E021 的 `-0.1684 ns`；精确
  required/arrival、面积和违例数待完整报告补录。
- 关键路径从 E021 的 `rdy_q -> picker` 转移为 `picked_q -> picked ->
  ROB/top-level picked fanout -> picker -> pk_tgt_q` 同组反馈路径。E032
  在每个 class candidate 前直接使用同一个 aggregate `picked_q` 位，
  class-ready 预解码减少的 compare 深度被 picked feedback 的扇出和
  物理布线代价抵消。
- 后续不得在 E032 上叠加。新候选必须回到 E021，并直接消除 safe
  picker 对 aggregate `picked_q` 的读取；同时不得重复
  `f8a403b231e1bc040fabdf521e1b8ff3f5493d3d` 已试过的 aggregate
  picked mask/commit 双寄存器复制。

## E033-M1 实施前查重

- 基线：E021 `c30a55d9d21faea805f500ddc8497ed70322ed15`；分支
  `timing/4fe-local-pick-mask-v32` 不包含 E031/E032 RTL。
- `f90af222172df52a535443d6aed359193d0b081e` 首次寄存 aggregate
  `picked_q`，用 64-bit bitmap 取代 `pk_idx_q` 的 6-to-64 feedback
  decode；E021 仍由这个 aggregate bitmap 同时驱动 ROB 和四个 class
  candidate mask。
- `f8a403b231e1bc040fabdf521e1b8ff3f5493d3d` 已试过两个完全相同的
  aggregate picked 寄存器副本，分别驱动 picker mask 和 ROB commit。
  该分支没有进入后续主线；E033 不复制 aggregate bitmap，与其不等价。
- E021 已有每个 FE 的 registered `pk_bank_oh_q`、`pk_local_oh_q` 和
  `pk_v_int`。在 `DUAL_STEAL=0` 的 scored safe 配置中，FE/class 固定
  对应且 entry latency 不变，因此 class `c` 的 ready bitmap 只可能与
  上周期 class `c` 的 pick 相交，其它 class 的 picked 位对它恒为 0。
- E033 只在 safe generate 分支中从上述既有 hierarchy coordinates
  重建本 class 的上周期 one-hot mask，并用它替代 aggregate `picked_q`
  mask。aggregate `picked_q` 继续独立驱动 ROB commit/oldest look-ahead；
  dual/full 配置继续使用原 aggregate mask，因为 stealing 会改变 FE 与
  latency class 的对应关系。该方案不增加寄存器、接口或流水级。
- 目标是从 safe picker candidate cone 中完全删除内网报告的
  `picked_q -> picked -> ROB/top-level picked fanout -> picker` 起点。
  风险是 hierarchy-coordinate decode 会增加 `pk_bank/local_oh_q` 负载；
  若标准 cycles 不一致、picker depth/cells 无收益、FE issue read 路径
  恶化，或内网仍出现 aggregate `picked_q -> picker`，则直接拒绝。

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
| E031-R64 | `aa33b5f6284e7f65fde048e6a9cba9d333d4fb80` | E021 + ROB fixed-order | 6154 | 9932 | 25024 | 0.2871 | 0.4645 | -0.1774 | 31133 | — | — | — | 拒绝：10363 条违例；worst `rdy_q -> pick/sel_tgt -> pk_tgt_q`；另有 `sched_idx_q -> res_now -> egress/lane_d_f` -0.1769 ns；clock-gating 改善到 -0.0256 ns，但相对 E021 WNS 恶化 9.0 ps、面积 +77、违例 +9；dep-heavy 11291 cycles，与 E021 四项完全一致；旧/new `peH` 等价检查通过 |
| E032-C1 | `5e5e3220df6dd9b9e88203817d36b543f2e5794d` | E021 + registered class-ready | 6154 | 9932 | 25024 | — | — | ≈-0.20 | — | — | — | — | 拒绝：内网 WNS 约 -0.20 ns，转为 `picked_q -> picker -> pk_tgt_q` 同组反馈路径；精确 required/arrival、面积和违例数待补；dep-heavy 11291，与 E021 四项完全一致；20 组 safe 和 12 组 full 随机负载逐项同周期；picker 通用 cells -2.23%，但全设计通用 cells +0.240% |

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
- `timing/4fe-rdy-class-v31`：从 E021 精确 RTL 创建，只把 ready 状态
  按 latency class 寄存到 ROB/picker 边界；不包含 E031 ROB selector 或
  egress 修改，内网结果确认前不与其它候选合并。
- RTL、验证、文档分开提交。综合结果文档提交引用被测 RTL SHA，
  不通过 amend 改写已经送入内网综合的 RTL 提交。
