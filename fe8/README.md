# fast_forward — 8-FE 方案（Verilog-2001，模块化）

```
rtl/                可综合 Verilog-2001 RTL（模块化）
  dut.v             顶层：端口展开/例化/一致性断言
  ff_ingress.v      S0/S1：PKTIN 寄存、压缩、依赖判定、槽旋转、alloc
  ff_rob.v          ROB 存储与状态机、wake、计数器、oldest 指针、BKPR
  ff_pick.v         I0 发射选择（每{lat类×奇偶}一口，集合互斥零仲裁）
  ff_issue.v        I1 数据/dp 读出、REG_FEIN、FEIN 驱动
  ff_fetrack.v      每 FE 定长 tag 延迟线（exit + 提前一拍预测）
  ff_egress.v       出口连续弹出、lane 映射、PKTOUT 寄存
rtl_mono/dut_flat.v 模块化前的单文件版（备份参考，不参与编译）
verif/              FE 行为模型 + 自校验 TB
docs/design_spec.md 方案与验证报告
Makefile            make quick / mid / heavy
```

根目录 SystemVerilog 版的逐拍等价 Verilog-2001 移植 + 模块化拆分（各用例数字与 SV 版完全一致）。
实测：重载3.85 pkt/cycle，中载2.0（理想）。4FE方案见`../fe4/`；两者的
正式得分必须用统一用例最终执行时间`T`及同流程Area/Power计算，现有吞吐和
结构估算不足以判定胜负。
