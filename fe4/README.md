# fast_forward — 4-FE 乱序方案（Verilog-2001，模块化）

```
rtl/                可综合 Verilog-2001 RTL（模块化）
  ff.v              顶层：端口展开/例化/一致性断言
  ff_ingress.v      S0/S1：PKTIN 寄存、压缩、依赖判定、槽旋转、alloc
  ff_rob.v          64 项存储/退休 ROB、结果保留、oldest 指针、BKPR
  ff_iq.v           独立 32 项 IQ、分配预约寄存、wake、并行空槽分配
  ff_iq_pick.v      IQ 顺序矩阵选择、critical 插队、跨类偷取、ROB tag 输出
  ff_pick.v         V28 ROB32 picker 参考（E042 顶层不例化）
  ff_issue.v        I1 数据/dp 读出、REG_FEIN、FEIN 驱动
  ff_sched.v        每 FE 4 槽输出记账调度器（exit/预测/预约导出）
  ff_egress.v       出口连续弹出、lane 映射、PKTOUT 寄存
rtl_mono/dut_flat.v 模块化前的单文件版（备份参考，不参与编译）
verif/              FE 行为模型 + 自校验 TB
docs/design_spec.md 方案与验证报告
docs/experiment-log.md 逐版本仿真/STA/PPA/得分记录
Makefile            make quick / mid / heavy
synth/              无工艺库的 Yosys 全设计结构/面积代理
```

E042 的核心机制是 **64-entry Storage ROB + 32-entry Issue Queue**：
数据、结果保留和顺序退休留在 ROB；picker 只扫描 IQ 中的小描述符，
用 6-bit ROB tag 访问数据。IQ 在分配时记录 32x32 顺序矩阵，pick 时不做
6-bit 环形年龄比较；四路空槽由 4-bit 一元 Kogge-Stone 前缀网络并行
标出，不串联四个 32-entry priority encoder。

Ingress 到 IQ 之间有一拍 compact-descriptor 预约边界，只寄存
`ROB tag/target/lat/isdep`；下一拍用 ROB `res_known` 生成 ready/wait，
避免 readiness 长组合锥跨模块进入 IQ 状态寄存器。

调度策略仍为延时类主绑定 + 每 FE 4 槽输出记账 + 可选跨类偷取 +
依赖目标 critical 插队 + 可选预唤醒同拍送入。

`ff` 的集成边界固定为只暴露 PKTIN、PKTOUT 和 BKPR；四个 `FE`
实例以及 FEIN/FEOUT 连线必须保留在 `ff` 内部。`verif/fe_model.sv`
提供相同端口契约的本地行为模型，内网综合时由真实 `FE` 实现替换。

默认是内网 STA 使用的 timing-safe 配置：

```
WAKE_BYPASS=0  预测唤醒只更新下一拍 IQ 状态，不直通当拍 pick
DUAL_STEAL=0   timing-safe 配置裁掉 secondary/偷取网络
REG_FEIN=0     FEIN 不额外插入寄存级
```

`pk_idx_q`、`pk_lat_q` 和 `sec_idx_q` 无条件写入；有效性由 valid
寄存器限定，避免综合器把完整 pick 组合锥接到这些小寄存器的 ICG
使能锁存器。

可复现配置：

```
make heavy       # timing-safe：WAKE_BYPASS=0, DUAL_STEAL=0
make dual-heavy  # 仅用于 A/B：WAKE_BYPASS=0, DUAL_STEAL=1
make full-heavy  # 原全性能：WAKE_BYPASS=1, DUAL_STEAL=1
make proxy       # Yosys 结构检查与 AND/NOT 面积代理（不替代内网 STA）
```

当前 seed=7、20k 包重载结果：timing-safe `6531 cycles / 3.062
pkt/cycle`，dual `6366 / 3.142`，full-performance `5931 / 3.372`；
全部自校验通过。相对 V28 timing-safe 的 10337 cycles，重载周期减少
36.8%；最终 `T = cycles × Tclk` 仍须由固定内网 STA/统一用例确认。

本地无工艺库代理：IQ 状态更新最长拓扑层数 31、picker 47（V28 picker
为 44），全设计最长拓扑层数 56（V28 为 54），299113 AND / 190970
NOT。重载 `cycles×depth` 粗代理相对 V28 减少 34.5%，但面积约为 V28
的 2.05 倍；上述层数只用于筛选 RTL，不是 STA。
