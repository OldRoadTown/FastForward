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
| rob64-iq32-old-u-lookahead | 0 | 0 | 0 | E048：E046 上将 bounded `old_u` advance 前推寄存 |
| rob64-iq32-lat0-wake-boundary | 0 | 0 | 0 | E049：E048 上移除 latency-0 同拍 issue-tag 预测旁路 |
| rob64-iq32-direct-wake-tags | 0 | 0 | 0 | E050：E049 上直接比较已寄存 result tag 与 IQ target |
| rob64-iq32-retire-live-vector | 0 | 0 | 0 | E052：E050 上以 live vector 解耦退休判定与序号差分 |
| rob64-iq32-postreg-coordinate-decode | 0 | 0 | 0 | E053：E052 上将 ROB 坐标译码移到 picker 寄存器后 |
| rob64-iq32-live-bounded-advance | 0 | 0 | 0 | E056：E053 上以 live vector 直接钳制 old-u advance |
| rob64-iq32-safe-strict-oldest | 0 | 0 | 0 | E057：E056 上 safe profile 仅保留严格 oldest selector |
| rob64-iq32-registered-bkpr-distance | 0 | 0 | 0 | E058：E057 上寄存 ROB 占用与窗口距离，缩短 BKPR 计数链 |
| rob64-iq32-onehot-retirement-boundary | 0 | 0 | 0 | E059：E058 上以 one-hot/thermometer 表达退休边界，删除 binary out-seq |

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
| E048 | `b4825a3ba1be5c7367f9b5d1722f62db8ae4115e` | rob64-iq32-old-u-lookahead | 6774 | 9938 | 24909 | — | — | — | — | — | — | — | E046 正向候选：维护 `adv_q`，本拍用已寄存的 bounded advance 推进 `old_u_q/old_u_oh_q`，并从推进后的位置并行计算下一拍 `adv_n`；仍可连续每拍追赶最多 8 项，避免 E047 两相扫描吞吐减半。quick、普通重载 9 seeds、依赖重载 3 seeds、dual/full 均通过；普通/依赖重载平均 cycles 相对 E046 +1.56%/+0.59%，seed 7 dual/full 为 6628/6125。统一 memory-map + `abc -g simple` 后名义全局路径从 0.8675ns 降至 0.8325ns，转移到 `pk_idx_q → IQ ready_q`；`old_u_q/old_u_oh_q` 路径降至 0.3450/0.1925ns。低/名义/高门延迟估计为 0.7600/0.8325/0.9050ns；名义 >0.400ns 端点为 801。计入 0.045ns uncertainty，seed 7 heavy `cycles×(path+uncertainty)` 相对 E046 改善 2.19%。旧 `make proxy` 为 292736 AND / 187664 NOT、全设计深度 48；AND+NOT 仅 +0.07%，深度 54→48。仍未达到 0.4ns，下一步切断结果预测到 IQ ready 的跨模块组合链。 |
| E049 | `145bb7dfd304c67e00ef31e46b70b9c6c27e9b53` | rob64-iq32-lat0-wake-boundary | 6855 | 9945 | 24909 | — | — | — | — | — | — | — | E048 正向候选：scheduler 的 `pre_v/pre_idx` 只由已寄存 slot2 产生，移除 latency-0 的同拍 `issue_v/issue_idx` 注入；latency-0 依赖者改由已寄存 slot1 的实际返回 tag 唤醒，latency 1..3 的 pre-wake 保持不变。quick、普通重载 9 seeds、依赖重载 3 seeds、dual/full 均通过；9-seed 普通重载平均 cycles +1.57%，3-seed 依赖重载 +5.11%，seed 7 dual/full 为 6739/6168。统一 memory-map + `abc -g simple` 后名义路径从 0.8325ns 降到 0.7775ns，关键路径变为 `sched_idx → IQ ready_q`；低/名义/高估计为 0.7100/0.7775/0.8450ns，名义 >0.400ns 端点仍为 801，但 >0.355ns 总端点从 5079 降到 1103。计入 0.045ns uncertainty，普通/依赖多 seed 平均 `cycles×period` 相对 E048 改善 4.80%/1.48%。旧 `make proxy` 为 292441 AND / 187549 NOT，较 E048 AND+NOT -0.085%，深度 50（该旧口径路径与经验加权关键路径不同）。下一步将四个预测 tag 直接与 IQ target 比较，避免 64-bit one-hot 译码/再索引。 |
| E050 | `d2d352d7838cc10d830300a7a2de270390aa554f` | rob64-iq32-direct-wake-tags | 6855 | 9945 | 24909 | — | — | — | — | — | — | — | E049 等周期边界优化：IQ resident/pending descriptor 直接将四路已寄存 pre-tag 与四路实际 exit-tag 同六位 target 比较，保留的 `resv_q` 位图只用于已存结果，不再构造 64-bit event bitmap 后动态索引。quick、普通重载 9 seeds、依赖重载 3 seeds、dual/full 均通过且所有 cycles 与 E049 完全相同；seed 7 依赖/dual/full 为 12891/6739/6168。统一 memory-map + `abc -g simple` 下 IQ ready 最长路径从 0.7775ns 降至 0.4675ns；全局名义路径仍为 0.7775ns，瓶颈转移至 picker 的 `valid_q → pk_bank_oh_q` 输出编码，低/名义/高仍为 0.7100/0.7775/0.8450ns。名义 >0.400ns 端点从 801 降到 736（其中 picker/ROB/IQ/egress 为 148/396/188/4），但 >0.355ns 端点增至 1331。旧 `make proxy` 为 292029 AND / 186476 NOT、深度 50，较 E049 AND+NOT -0.31%。由于全局周期与 cycles 均不变，`cycles×(path+0.045)` 持平；该提交作为解除 IQ 关键链的正向架构阶段保留，下一步消除 picker binary-tag 到 8×8 one-hot 的末级译码。 |
| E052 | `aa641aa3d41cf43e6d937cccbda080ecbbfec572` | rob64-iq32-retire-live-vector | 6855 | 9945 | 24909 | — | — | — | — | — | — | — | E050 等周期退休边界优化：新增每项 `live_q` 标记当前 allocation epoch，egress 用 `live_q & resv_q & out_oh` 判断连续完成，替代 `alloc_seq-out_seq` 的有效数差分；ROB 用固定四个 head rotation 清除已退休 live 位。quick、普通重载 9 seeds、依赖重载 3 seeds、dual/full 均通过且 cycles 与 E050 完全一致，seed 7 依赖/dual/full 为 12891/6739/6168。统一 memory-map + `abc -g simple` 下 `out_seq_q` 路径降到 0.5850ns，egress valid 降到 0.4675ns；低/名义/高全局仍为 0.7100/0.7775/0.8450ns，关键路径回到 picker `valid_q → pk_local_oh_q`。名义 >0.400ns 端点为 1000（picker/ROB/IQ/egress 148/660/188/4），新增 live 状态使 ROB 慢端点增多；但映射总单元从 E050 的 307898 降至 306992（-0.29%）。全局周期与 cycles 持平，作为解除 retirement 关键链的架构阶段保留；下一步将 picker one-hot 坐标移到 binary index 寄存器之后译码。 |
| E053 | `8942dee937d529185a93fbd1e76b602c62354c6d` | rob64-iq32-postreg-coordinate-decode | 6855 | 9945 | 24909 | — | — | — | — | — | — | — | E052 正向时序候选：picker 边界只寄存六位 `pk_idx_q`，I1 数据读取所需 bank/local one-hot 与 64-bit ROB commit mask 均在寄存器后用相等比较重建；保留 registered `picked_iq_q`，避免形成 `pk_qix_q → picked_iq → ready_avail → pk_v` 反馈长链。quick、普通重载 9 seeds、依赖重载 3 seeds、dual/full 均通过，cycles 与 E052 完全一致，seed 7 依赖/dual/full 为 12891/6739/6168。统一 memory-map + `abc -g simple` 下低/名义/高全局从 0.7100/0.7775/0.8450ns 降至 0.6850/0.7500/0.8150ns，关键路径变为 `IQ valid_q → picked_iq_q`；计入 0.045ns uncertainty，同 cycles 的时间代理改善 3.34%。名义 >0.400ns 端点从 1000 降到 671，>0.355ns 从 1034 降到 985；映射总单元 309360，较 E052 +0.77%，但时间四次方评分代理仍为正向。仍未达到 0.4ns，下一步删除 `pri_oh` 到 `picked_iq_q` 的冗余 found 门控并继续分层 picker。 |
| E056 | `72dfe187a7e4f79a09833027c990d5d6d3743668` | rob64-iq32-live-bounded-advance | 6855 | 9945 | 24909 | — | — | — | — | — | — | — | E053 正向时序候选：`issued_win` 改为扫描 `iss_q & live_q`，第一个未分配或未发射项自然终止推进，因此删除 `alloc_seq_q-old_u_n` 距离减法、大小比较和 `adv_n` 末级 mux。quick、普通重载 9 seeds、依赖重载 3 seeds、dual/full 均通过，所有 cycles 与 E053 完全一致；seed 7 依赖/dual/full 为 12891/6739/6168。统一 memory-map + `abc -g simple` 下低/名义/高全局从 0.6850/0.7500/0.8150ns 降至 0.6600/0.7225/0.7850ns，关键路径仍为 `IQ valid_q → picked_iq_q`；ROB `old_u/adv` 相关路径从 0.7425ns 降至 0.2900ns。计入 0.045ns uncertainty，时间代理改善 3.46%；映射总单元从 309360 降到 304531（-1.56%），名义 >0.400ns 端点 640。下一步在此基线上重新评估 safe strict-oldest，因 ROB advance 已不再成为 0.770ns 的替代瓶颈。 |
| E057 | `f6735daa3fc1d3e2c86ec5321b44374903dc9eeb` | rob64-iq32-safe-strict-oldest | 6977 | 9945 | 24909 | — | — | — | — | — | — | — | E056 正向架构候选：safe profile 删除 critical-jump 的第二套 32-entry age-matrix selector，只保留严格 oldest；dual/full 仍保留 critical-first 与 stealing，因此其 seed 7 cycles 维持 6739/6168。quick、普通重载 9 seeds、依赖重载 3 seeds、dual/full 均通过；普通/依赖多 seed cycles 相对 E056 均增加约 1.41%，seed 7 依赖为 13034。统一 memory-map + `abc -g simple` 下低/名义/高全局从 0.6600/0.7225/0.7850ns 降至 0.5800/0.6275/0.6750ns，关键路径转为 `ingress in_vld_q → ROB bkpr_r`；picker commit 路径降至 0.3575ns。计入 0.045ns uncertainty，多 seed 普通/依赖 `cycles×period` 均改善约 11.14%，时间四次方评分项约 1.60×；映射总单元从 304531 降到 288662（-5.21%），名义 >0.400ns 端点从 640 降到 508。下一步优化 BKPR 的 `alloc_nxt-out_seq/old_u` 计数链；0.4ns 目标仍需继续拆分控制路径。 |
| E058 | `268cfaaf8db717b5cdc5403f3a253549f4b73d30` | rob64-iq32-registered-bkpr-distance | 6977 | 9947 | 24909 | — | — | — | — | — | — | — | E057 等周期控制优化：ROB 维护寄存的 `occ_q=alloc_seq-out_seq` 与 `win_q=alloc_seq-old_u`，BKPR 只需在距离状态上加本拍 `acnt`，删除 `alloc_nxt` 后串联的七位减法。quick、普通重载 9 seeds、依赖重载 3 seeds、dual/full 均通过且所有对应 cycles 与 E057 完全一致；seed 7 普通/依赖/dual/full 为 6977/13034/6739/6168。统一 memory-map + `abc -g simple` 下低/名义/高全局从 0.5800/0.6275/0.6750ns 降至 0.5350/0.5850/0.6350ns，关键路径为 `ROB resv_q → occ_q`，21 级（1 XOR + 15 OR + 5 AND）；BKPR 自身降至 0.5100ns，`out_seq_q` 为 0.5575ns。计入 0.045ns uncertainty，同 cycles 的时间代理再改善 6.32%，时间四次方评分项约 1.30×；映射总单元 288672，较 E057 仅 +10。名义 >0.400ns 端点从 508 降到 389。下一步解耦 retirement pop 计数与 `occ_q/out_seq_q` 更新；0.4ns 目标仍需同时优化 IQ allocation reservation 与 picker target 路径。 |
| E059 | `cb2d5f6f0047feb86184b938014092091a91b5b9` | rob64-iq32-onehot-retirement-boundary | 6977 | 9947 | 24909 | — | — | — | — | — | — | — | E058 等周期退休重构：egress 直接输出四位连续退休 thermometer code，ROB 用它清除 live 位并在五个固定 one-hot head rotation 中选择下一 head；egress 数据也直接用四个 head rotation 做每 lane 的 16 项 one-hot 读，因而删除 `out_seq_q` 及其 binary 地址运算。另将 binary `pop_cnt` 先寄存为 retirement credit，BKPR 使用前减掉该 credit，保证 occupancy 判定与 E058 逐拍等价。quick、普通重载 9 seeds、依赖重载 3 seeds、dual/full 均通过且对应 cycles 与 E058 一致；seed 7 普通/依赖/dual/full 为 6977/13034/6739/6168。统一 memory-map + `abc -g simple` 下低/名义/高全局为 0.5250/0.5775/0.6300ns，较 E058 名义改善 1.28%，关键路径转为 `adv_q → adv_q` 的 oldest-unissued 前瞻递推；egress data 从 0.3575ns 降到 0.2200ns。计入 0.045ns uncertainty，时间代理改善 1.19%，时间四次方评分项约 1.05×；映射总单元 288725，较 E058 +0.018%。名义 >0.400ns 端点为 448（ROB/IQ/picker/egress = 268/124/52/4），说明全局略降但慢路径数量增加；下一步消除 `adv_q` 自反馈，并继续处理 IQ allocation reservation。 |

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
