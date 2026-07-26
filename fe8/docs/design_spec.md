# fast_forward 8-FE 方案 — Verilog-2001 实现说明

本目录是根目录 SystemVerilog 版（`../rtl/dut.sv`）的 **Verilog-2001 逐拍等价移植**。
架构、hazard 推导、PPA 分析详见 `../docs/design_spec.md`，此处只记录移植与验证要点。

## 架构要点（与 SV 版一致）
- 8 个 FE，**延时类×奇偶绑定**：FE f = {lat类 L, 奇偶 p} = 2L+p，只接收 lat==L 且
  ROB 索引奇偶==p 的报文 → 输出端结构无冲突（tag 跟踪退化为定长 L+1 延迟线）、
  每表项结果写源唯一、8 个发射口候选集互斥零仲裁；
- 64 深统一 ROB（输入数据/转发结果复用同一 128b 寄存器）、乱序发射、按序输出
  （lane = seq[1:0]）；
- 预唤醒：tag 延迟线提前一拍预测结果，依赖报文与目标结果**同拍**送入 FE
  （dp_data 从 FEOUT 总线组合旁路）；
- 结果保留 + bkpr 双阈值（占用度 >55 / 发射窗口 >45，含 2 拍/8 包在途裕量）；
- pop 当拍旁路、oldest-unissued 指针一拍全速追赶。
- 参数：`REG_FEIN`（FEIN 加寄存级）、`WAKE_BYPASS`（预唤醒当拍 pick 开关）。

## Verilog-2001 移植要点
- `logic/always_ff/always_comb/unique case` → `wire·reg / always @(posedge...) / always @* / case`；
- 参数与 genvar 不做位选（严格 1364-2001）：改用带位宽的 `localparam [1:0] LCB`、
  `localparam [0:0] PRB`；数组元素不做部分位选：压缩载荷拆出独立 128b `slot_dat` 数组；
- 定长 tag 延迟线的 TD==1 特例用 generate-if 展开；
- 多维数组、net 数组均为 1364-2001 合法特性，DC/VCS 兼容。

## 验证（与 SV 版结果逐拍一致，全部 PASS）
| 用例 | 吞吐 (pkt/cycle) | 与 SV 版对比 |
|---|---|---|
| 重载 20k (seed 101) | **3.848**（bkpr 183: occ 88 / win 102） | 完全一致 |
| 中载 20k | 1.999 | 完全一致 |
| 重载×8 种子 (2k) | 3.630–3.766 | 完全一致 |
| 依赖极限压力 (7/8 依赖) | 2.309 | 完全一致 |
| 稀疏 20% | PASS | 一致 |
| REG_FEIN=1 | 3.371 / 1.716(压力) | 完全一致 |
| WAKE_BYPASS=0 | 3.390 / 1.694(压力) | 完全一致 |

复现：`make quick / mid / heavy`；参数 `+NPKT= +LOADPCT= +SEED= +DEPHEAVY=`。
