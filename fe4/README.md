# fast_forward — 4-FE 乱序方案（Verilog-2001，模块化）

```
rtl/                可综合 Verilog-2001 RTL（模块化）
  ff.v              顶层：端口展开/例化/一致性断言
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

`ff` 的集成边界固定为只暴露 PKTIN、PKTOUT 和 BKPR；四个 `FE`
实例以及 FEIN/FEOUT 连线必须保留在 `ff` 内部。`verif/fe_model.sv`
提供相同端口契约的本地行为模型，内网综合时由真实 `FE` 实现替换。

E069 本地回归和综合代理的默认配置是：

```
WAKE_BYPASS=1  latency1..3 使用提前一拍寄存的 32-bit wake mask
DUAL_STEAL=0   只保留第一偷取匹配器
REG_FEIN=0     FEIN 不额外插入寄存级
```

这里的 `WAKE_BYPASS` 是历史参数名。E069 不把实时 tag 比较或 FE 数据
mux 接到 wake-to-picker 路径；picker 只读取 `wtg_q & wake_bind_q`。
latency0 结果仍跨寄存边界后更新 ready。该配置是待内网 STA/Power 签核的
性能候选，不能仅凭本地组合路径代理标记为 timing-safe。

`pk_idx_q`、`pk_lat_q` 和 `sec_idx_q` 无条件写入；有效性由 valid
寄存器限定，避免综合器把完整 pick 组合锥接到这些小寄存器的 ICG
使能锁存器。

可复现配置：

```
make heavy       # E069：registered prewake，DUAL_STEAL=0
make dual-heavy  # 仅用于 A/B：WAKE_BYPASS=0, DUAL_STEAL=1
make full-heavy  # E069 prewake + DUAL_STEAL=1
```

当前 seed=7、20k 包重载结果：默认配置 8359 cycles
（2.393 pkt/cycle），full-heavy 8244 cycles（2.426 pkt/cycle）；全部
自校验通过。E068 对应默认配置为 9070 cycles。
