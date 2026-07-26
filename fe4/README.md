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
Makefile            make quick / mid / heavy
```

核心机制：延时类主绑定 + 每 FE 4 槽输出记账 + 跨类偷取(≤2/拍) + 依赖目标 critical 插队 + 预唤醒同拍送入。
实测：重载 3.61 pkt/cycle，中载 2.0（理想）；模块化后与单文件版逐拍一致，全部用例 PASS。
