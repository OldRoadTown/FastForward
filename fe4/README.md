# fast_forward — 4-FE 乱序方案（Verilog-2001，模块化）

```
rtl/                可综合 Verilog-2001 RTL（模块化）
  dut.v             顶层：端口展开/例化/一致性断言
  ff_ingress.v      S0/S1：PKTIN 寄存、压缩、依赖判定、槽旋转、alloc
  ff_rob.v          ROB 存储与状态机、wake、计数器、oldest 指针、BKPR
  ff_pick.v         I0 发射选择（奇偶双选 + critical 插队 + 跨类偷取 + rob_src 记录）
  ff_issue.v        I1 数据/dp 读出、REG_FEIN、FEIN 驱动
  ff_sched.v        每 FE 4 槽输出记账调度器（exit/预测/预约导出）
  ff_egress.v       出口连续弹出、lane 映射、PKTOUT 寄存
rtl_mono/dut_flat.v 模块化前的单文件版（备份参考，不参与编译）
verif/              FE 行为模型 + 自校验 TB
docs/design_spec.md 方案与验证报告
docs/experiment-log.md 逐版本仿真/STA/PPA/得分记录
Makefile            make quick / mid / heavy
```

核心机制：延时类主绑定 + 每 FE 4 槽输出记账 + 跨类偷取 + 依赖目标
critical 插队 + 可选的预唤醒同拍送入。

默认是内网 STA 使用的 timing-safe 配置：

```
WAKE_BYPASS=0  预测唤醒只更新下一拍 ROB 状态，不直通当拍 pick
DUAL_STEAL=0   只保留第一偷取匹配器
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
```

当前 seed=7、20k 包重载结果：timing-safe 3.333 pkt/cycle，
full-performance 3.571 pkt/cycle；全部自校验通过。
