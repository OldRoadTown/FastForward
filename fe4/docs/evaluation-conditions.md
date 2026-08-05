# FE4 官方 DCG 与评分条件

本文记录后续微架构、时序、功耗和总分比较必须采用的题面条件。若内网
脚本或时序报告与本文存在差异，以该次官方脚本和报告为准，并在实验记录
中注明差异，禁止与旧结果直接混算。

## 1. DCG 环境

| 项目 | 条件 |
|---|---|
| 工艺/环境 | T7+，H240 |
| Corner | ssgnp |
| 电压 | 0.675 V |
| 温度 | 125 C |
| 功耗来源 | PTPX 输出，单位 W |
| Vt 使用 | lvt/ulvt 比例不受限制，工具优先满足性能约束 |

## 2. 自定义周期与 setup 预算

- 设计者在 `design/hdl/bes_cfg.csh` 中设置时钟周期 `Pset`；DCG 综合、
  性能仿真和功耗评估必须使用同一个设置。
- 名义 clock budget 为 `0.9 * Pset`。
- ICG 路径还需扣除频率相关的插入延迟：

```text
frequency > 1.5 GHz : ICG delay = 0.050 ns
frequency <= 1.5 GHz: ICG delay = 0.100 ns
```

- 因此仅用于理解预算、尚未计入其它报告项时，ICG setup 窗口可写成：

```text
B_icg(Pset) = 0.9 * Pset - ICG_delay
```

- Clock uncertainty 随频率变化；`Pset < 0.4 ns`（频率 > 2.5 GHz）时
  固定为 0.035 ns。其它频率档位必须读取该次时序报告，不能沿用旧值。
- 实际 required time 还可能包含 setup、clock path、CPPR 等工具项，最终
  判定以该次报告为准，不能只用上述简式反推 signoff slack。
- `1.5 GHz` 对应 `Pset = 0.6667 ns` 左右。跨到低频侧时 ICG delay 从
  50 ps 跳到 100 ps，这是离散预算变化，周期 sweep 必须分别综合两侧。

题面允许显式例化库支持的 ICG。显式使用时，`rtl_sim.f` 必须加入对应
仿真库。当前收到的补充说明没有包含具体 ICG cell 和库文件名，必须从
内网官方模板/库说明读取，禁止在仓库中猜测名称。

## 3. 官方负载

功耗与性能用例使用相同种子；报文延时完全伪随机，依赖关系按题面修订
说明生成。两个用例采用相同的混合负载：

| PKTIN 发射速率 | 含义 | 题面报文数量占比 |
|---:|---|---:|
| 41.7% | 以 4 packet/cycle 为 100%，平均约 1.668 packet/cycle | 1 |
| 90% | 平均约 3.6 packet/cycle | 2 |

在完全无阻塞、约 20000 个激励 cycle 的示例中：

```text
前约 10000 cycles: 发射约 16680 packets（41.7%）
后约 10000 cycles: 发射约 36000 packets（90%）
```

存在 BKPR 时，两个负载部分的发包数量关系保持题面规定，但时间不再严格
等分。因此必须使用官方 testbench 的最终 elapsed cycles；本地固定 20%、
50%、100% 和 dependency-heavy 用例只用于功能、吞吐和回归筛查。

## 4. 得分比较

对同一官方性能用例：

```text
T = Pset * official_elapsed_cycles
score = 1 / (T^4 * PTPX_power_W * implementation_area)
```

每个候选必须绑定完整 RTL SHA，并记录：`Pset`、实际频率、clock budget、
ICG 档位、uncertainty、WNS/TNS/违例数、官方 elapsed cycles、PTPX W、
Area 和最终 Score。任一约束、活动文件、种子、corner 或工具设置不同的
结果不能直接比较。

周期不是越小越必然得分越高：更紧约束可能增加 lvt/ulvt、缓冲、面积和
功耗。但由于 `T` 为四次方，候选应围绕最快可收敛周期做离散 PPA sweep，
并在 `1.5 GHz` ICG 档位两侧单独取点，而不是只综合一个周期。

