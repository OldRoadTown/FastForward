# fast_forward 4-FE 乱序方案（Verilog-2001 实现）

> 顶层：`ff`（`fe4/rtl/ff.v`，纯 Verilog-2001，可综合）
> 验证：`fe4/verif/`（FE 行为模型 + 自校验 TB，Verilator）
> 参数：`REG_FEIN`（FEIN 加寄存级）、`WAKE_BYPASS`（预测唤醒是否
> 直通当拍 pick）、`DUAL_STEAL`（是否启用第二偷取匹配器）。
> 内网综合默认：`REG_FEIN=0, WAKE_BYPASS=0, DUAL_STEAL=0`。
>
> E042-R64-IQ32 分支说明：本分支从原始 V28/E029 独立派生，把
> 数据存储/顺序退休 ROB 恢复为 64 项，同时把调度描述符留在独立的
> 32 项 IQ；picker 不扫描 64 项数据 ROB。E042 的本地代理与待测
> 统一用例 T 见 `experiment-log.md`。

---

## 1. 为什么 4 FE 可能是得分最优

得分 = (1/T)⁴ × (1/Power) × (1/Area)，FE 单价 ~3500um²。

| | 8 FE（lat×奇偶绑定） | **4 FE（lat 绑定 + 偷取）** |
|---|---|---|
| 重载吞吐 (pkt/cycle) | 3.85 | 3.61 |
| 中载吞吐 | 2.00（理想） | 2.00（理想） |
| FE 面积 | ~28k um² | **~14k um²** |
| 自身逻辑 | 相当 | 相当（+调度器/偷取小逻辑） |

估算（重载 T 占比最大情形）：T 比值 3.85/3.61≈1.066 → T⁴ 劣化 1.29×；面积+功耗合计约优 (0.78×0.8)≈0.62×。**4FE 综合得分约为 8FE 的 1.2~1.3 倍**；若计分 T 为中载+重载合计，中载两者相同，4FE 优势进一步放大。

4 FE 的挑战：每个延时类只有 1 台发动机，重载下类到达率 = 服务率（ρ=1 临界），某类瞬时积压时其它 FE 空转、且被依赖的目标报文在类内排队会拉长依赖链。本方案用**输出槽记账 + 跨类偷取 + 关键报文抬价**三个机制补回吞吐（基线 3.34 → 3.61）。

---

## 2. 架构总览

```
PKTIN(4 lane) → S0 输入寄存 → S1 压缩+分配
                                      ├→ Storage ROB 64×{data128, 退休/结果状态}
                                      └→ IQ 预约寄存 → 32×{ROB tag, lat, tgt, ready, critical}
                                                │
     I0 IQ pick（每类一个发射口，分配顺序矩阵，critical 优先）
        ├─ 顺序矩阵 oldest mask + 五层 OR 树 → 主选/可选次选
        ├─ 偷取匹配器×2：空闲 FE + 输出槽空闲 → 跨类接单
        ▼
     I1 issue：按 6-bit ROB tag 读 data + 依赖 data(dp, 含 FEOUT 当拍旁路) → FEIN
        ▼
   FE0..3（黑盒；主绑定 lat 类 = FE 编号，偷取时混流）
        │   每 FE 4 槽结果调度器：精确记账"第 k 拍后出结果"
        ▼   （exit=槽1，预唤醒=槽2，发射预约冲突检查）
   FEOUT → 结果写回 ROB[记账 tag]（写源 = rob_src 记录的 FE，唯一）
        ▼
   输出级：out_seq 起连续弹出 ≤4（含当拍结果旁路），lane = seq[1:0] → PKTOUT 寄存
   BKPR：ROB 占用(>55) / 结果保留窗口(>45) / IQ 占用(>23)，寄存输出
```

与 8FE 版共享的机制（推导详见 `../docs/design_spec.md`）：输入数据与
转发结果复用同一个 128b 存储槽、乱序发射/按序输出、预唤醒（依赖
报文与目标结果**同拍**进 FE，dp_data 从 FEOUT 总线旁路）、pop 当拍
旁路。E042 额外保留原 E021 的
45 项结果保留窗口约束；只按 IQ 容量背压会让 64 项 ROB 过早复用，
破坏晚到依赖者读取旧结果的安全性。

### 2.1 Storage ROB / Issue Queue 解耦

- Storage ROB 保存 64 项 128-bit packet/result、依赖属性、结果与退休
  状态；已经输出的结果继续保留到该 ROB 槽重分配。
- IQ 只保存最多 32 个尚未发射描述符：`valid/ready/wait/critical`、
  `lat`、6-bit `ROB tag` 与 6-bit `target tag`。
- Ingress 到 IQ 有一拍物理槽预约/描述符寄存边界；pending 槽不参与下一
  批空槽分配。边界只携带 `ROB tag/target/lat/isdep`，提交 IQ 时用
  `res_known[target]` 生成 ready/wait，因此同批依赖和边界拍结果到达均
  不会丢失，同时切断 ingress readiness 到 IQ 状态寄存器的组合路径。
- IQ 物理槽与 ROB tag 无关；32x32 顺序矩阵在分配时记录任意两个 live
  描述符的先后关系，picker 只做 blocker/oldest one-hot 和 OR 归约，
  不在关键选择锥内重复比较 6-bit 环形年龄。选择后同时产生 IQ commit
  bitmap 和 ROB issued bitmap。
- 四路 IQ 分配使用 4-bit 一元饱和计数的 Kogge-Stone 前缀网络，一次
  并行标出前四个空槽，避免四级串联 free-list 搜索。
- 64 项数据读保持 8×8 bank/local one-hot，IQ 树直接携带最终 ROB tag
  与 target tag，避免选中后再串联一个 32:1 描述符读取。

---

## 3. 4FE 专属机制

### 3.1 输出槽记账调度器（每 FE 4 槽）
每 FE 维护 `sched_v[4:1]`/`sched_idx`：**当前拍槽 k 中的表项将在第 k-1 拍后从 FEOUT 输出**。每拍下移；发射（FEIN 拍）lat 类 c 的报文插入槽 c+1。

- `exit = 槽1`：当拍出结果 → 写回 ROB、pop 旁路；
- `pre = 槽2`（lat1 报文发射当拍额外并入）：下一拍出结果 → 预唤醒依赖报文；
- **发射预约检查**（pick 拍 t，插入发生在 t+1）：插入槽 c+1 的冲突源 =
  ① 既有流水：`sched_v[c+3]`（c≤1 时存在）；② 当拍正在发射的报文（pick 于 t-1）恰好预约同一槽：`pk_v && pk_lat == c+1`（c≠3）。c=3（lat4）插入最深槽，结构上永不冲突。

同类流恒不冲突（主绑定），混合流（偷取）由上述两条检查精确拦截——TB 的 FE 模型与"输出冲突预约"断言双重验证了这一点。

### 3.2 跨类偷取（work stealing）
- 每类用顺序矩阵生成 oldest one-hot，再用五层 OR 树携带描述符；
  `DUAL_STEAL=1` 时并行生成
  排除主候选后的次候选，safe 配置在 elaboration 时裁掉整棵次选树；
- 次选寄存一拍（跨拍确认积压，实测优于当拍直取），下一拍重新验证（仍 rdy、未被本类主选拿走）后成为**捐出者**；捐出类按"次选全局年龄最老"优先（直接压发射窗口）；
- **接收者** = 本拍无自类候选的 FE，且对捐出 lat 通过 3.1 的槽预约检查；
  默认每拍最多 1 个偷取，`DUAL_STEAL=1` 时启用扫描方向相反的第二匹配器；
- 表项发射时记录 `rob_src`（实际去往的 FE），结果写回、dp 旁路、pop 旁路一律按 `rob_src` 选源——每表项写源仍唯一；
- `fwd*_pkt_lat` 因此为动态值（= 报文自身 lat，忠实透传）；
- 偷取可能占用 FE 未来输出槽 → 自类主选增加对应门控 `own_cfl`（同样两条检查）。
- `REG_FEIN=1` 挡位下发射时刻改为 pick+2，记账基准偏移，**该挡位自动关闭偷取**（退化为纯绑定，结构无冲突，功能已验证）。

E042 seed=7、20k 重载实测：safe `3.062` → dual `3.142 pkt/cycle`。

### 3.3 关键报文抬价（critical-first pick）
win 停顿的主因：窗口头部是等待中的依赖报文，其**目标**在类内排队。机制：
- 分配时依赖报文若进入等待（wtg），将其目标表项打 `crit` 标记（同拍分配的目标也正确覆盖：置位写在分配清零之后）；
- pick 时每类增加一路"最老 critical 候选"优先编码：**critical 报文插队**，除非年龄最老候选恰为窗口头（旋转位置 0，此时保头优先）；
- 表项重分配时清 `crit`。

E021 历史实验为 3.51 → 3.61（win 停顿 476→383，occ 243→153）；
E042 保留同一策略，但 critical 状态位于 IQ 描述符中。
（历史实验中关键性沿依赖链再上传一级无增益，已回退不留逻辑。）

---

## 4. 时序（0.4ns 目标）

E042 的目标是让存储容量恢复为 64 时，I0 选择规模仍固定在 32 项。
每个延时类通过 32x32 顺序矩阵判定 oldest，再用五层 OR 树携带 IQ
index、ROB tag 和 target tag；safe 配置裁掉 secondary/steal 树。
分配侧使用一元 Kogge-Stone 前缀网络，不再串联四次空槽 priority
search。挡位：

- Storage ROB 的 `old_u` 同时维护物理 one-hot 影子，每拍只扫描头部 8
  项并最多追赶 8 项；发射宽度最多 4，因此释放头阻塞后仍能净消化历史
  issued 积压，避免 64 项全局 oldest-unissued 扫描成为关键路径；

- `WAKE_BYPASS=0`：切断预唤醒→当拍 pick 组合链（依赖链每级 +1 拍，重载 3.25，功能验证通过）；
- `REG_FEIN=1`：FEIN 出口加寄存（FE 输入时序紧时用；自动关偷取，重载 3.17，功能验证通过）；
- `DUAL_STEAL=0`：综合时裁掉 secondary 和偷取匹配网络；
- `pk_idx_q`、`pk_lat_q`、`sec_idx_q` 无条件写入，避免其更新条件
  被实现为 ICG enable 长路径；valid=0 时这些字段为 don't-care。
- 若上述配置仍无法收敛，下一步是将候选选择与偷取匹配拆成 P0/P1 两级。

面积/功耗：4×FE≈14k um²；自身主体 = Storage ROB 64×128b 数据
（无复位、使能门控）+ 32 项 IQ 描述符 + 控制位图。通用 Yosys
AND/NOT 数量只能做结构代理，不能替代工艺库映射后的 Area/STA。
所有 128b 数据通路寄存器使能门控，FEIN 数据 vld=0 时保持不翻转。

最终本地同法代理：IQ 状态更新最长拓扑层数 31、safe picker 47（V28
picker 44；早期直接比较 6-bit 年龄的 E042 原型为 128）；全设计最长
拓扑层数 56（V28 54、E021 65），299113 AND / 190970 NOT，约为 V28
的 2.05 倍。重载 `cycles×depth` 粗代理相对 V28 减少 34.5%、相对
E021 减少 8.6%，但恢复 64 项数据 ROB 与 32x32 顺序矩阵有明确面积
代价。是否减少最终 `T = cycles × Tclk` 仍以固定内网 STA 和统一用例
为准。

---

## 5. 验证结果（Verilator，全部 0 错误）

TB 检查点与 8FE 版一致（FEIN 协议/依赖时序与 dp 数据/FEOUT 精确到期拍匹配/输出冲突预约断言/PKTOUT 循环保序金比对/BKPR 语义），并针对偷取升级：FEOUT **按到期拍匹配**（单 FE 混流乱序出结果为设计特性）、FEIN 侧新增输出冲突预约检查。

| 用例 | 配置 | 结果 (cycles / pkt/cycle) |
|---|---|---|
| 重载长跑 | safe, 20k 包, seed=7 | **6531 cycles / 3.062** |
| 中载长跑 | safe, 20k 包, seed=11 | 9933 / 2.013 |
| 依赖极限压力 | safe, 20k 包, seed=7 | 12073 / 1.657 |
| 稀疏负载 | safe, 20k 包, seed=13 | 25025 / 0.799 |
| 跨类偷取 | dual, 20k 重载 | 6366 / 3.142 |
| 预唤醒 + 偷取 | full, 20k 重载 | 5931 / 3.372 |
| 重载多种子 | safe, 2k 包, seed=1..8 | 2.994–3.082，全部 PASS |
| 依赖多种子 | safe, 5k 包, seed=2/5/11 | 1.567–1.714，全部 PASS |

复现：`cd fe4 && make quick / mid / heavy`；参数 `+NPKT= +LOADPCT= +SEED= +DEPHEAVY=`。

---

## 6. 对接注意

1. `ff` 顶层只暴露题目规定的 PKTIN、PKTOUT 和 BKPR 端口；FE 数固定为
   4，`fwd0..3` / `fwded0..3` 连线位于顶层内部，并例化官方 `FE` 4 份；
2. `fwd*_pkt_lat` 为报文真实 lat 透传（偷取使 FE 收到混合延时流——FE 本身支持所有延时，输出冲突由本设计的槽记账保证，属题目允许的设计者责任范围）；
3. 若环境对"依赖报文与目标结果同拍进 FE"报协议错误 → `WAKE_BYPASS=0`；FE 输入时序紧 → `REG_FEIN=1`；
4. 本地 fe_model 的变换函数为占位，ff 不触碰数据内容，接真实 FE 无影响。
