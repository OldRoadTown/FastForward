# fast_forward

按题目要求实现的报文转发/保序/依赖处理模块（顶层 `dut`），含自建 FE 行为模型与自校验 TB。

```
rtl/dut.sv          可综合 RTL（顶层 dut，8×FE 接口，参数 REG_FEIN / WAKE_BYPASS）
verif/fe_model.sv   FE 行为模型（黑盒占位，含输出冲突检测）
verif/tb_top.sv     自校验 TB（协议/数据/保序/性能统计）
docs/design_spec.md 方案、微架构、hazard 推导、PPA 与验证报告
Makefile            make quick / mid / heavy
```

实测：重载 3.85 pkt/cycle（理想 4.0），中载 2.0（输入受限理想值）。详见 docs。
