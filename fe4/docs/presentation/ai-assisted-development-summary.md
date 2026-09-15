# FastForward 项目的 AI 使用总结

配图：[AI 辅助硬件优化流程（可编辑 SVG）](assets/07-ai-assisted-development-workflow-editable.svg)

交互版：[AI 辅助硬件优化流程（HTML）](../architecture/ai-assisted-development-workflow.html)

## 汇报用文字

本项目将 AI 作为贯穿硬件优化全过程的工程协作者。首先由人明确优化目标与边界，包括降低 `T = cycles × period`、避免时序恶化、减少周期数以及控制面积和功耗；随后 AI 读取 RTL、Git 历史、实验记录和 STA/PPA 报告，结合关键路径与门级延迟估算提出架构候选。每个候选都从可信基线建立独立分支，AI 完成 RTL、断言和测试统计的修改，再通过 Verilator 回归、Yosys/ABC/OpenSTA 代理以及外部正式 STA/Power 数据进行量化。最终由人根据功能、cycles、worst path、面积和功耗决定保留、回退或继续迭代，AI 再负责记录实验 SHA、失败原因、架构图和 GitHub 版本。

## AI 具体完成的工作

- 理解并整理 `ff_ingress`、`ff_rob`、`ff_pick`、`ff_issue`、`ff_sched` 和 `ff_egress` 的数据与控制关系。
- 根据关键路径和经验门延迟估算，提出 ROB32、4×8 分层 Picker、安全复用窗口、退休状态去冗余、Same-Cycle Credit 和结果来源复用等候选。
- 为每个主要候选建立独立 Git 分支，避免失败试验污染可信基线，并保留可准确回退的提交。
- 修改 RTL、补充逐拍断言和性能统计，运行 quick、mid、heavy、多 seed 和依赖重载回归。
- 对比 cycles、关键路径、组合深度、cell count、面积和功耗；发现时序恶化或伪基线时停止该方向并记录原因。
- 持续维护实验日志、模块说明、汇报大纲、可编辑电路图和 GitHub 版本。

## 为什么这种方式有效

AI 能够快速交叉检查代码、历史实验和报告，并并行考虑功能、时序、周期和 PPA 之间的耦合关系，因此可以缩短“发现问题—提出候选—实现—验证”的迭代时间。独立分支、单变量实验和统一测试条件使每次收益都能被归因；失败候选同样被记录，避免重复走已经证明会恶化时序的路线。AI 的结论始终受仿真和 EDA 数据约束，而最终取舍由人完成，因此既提高迭代效率，也保留了工程可追溯性。

## 边界

AI 不替代功能验证和芯片签核。开源综合、STA 与静态功耗结果只用于同条件下的候选排序；最终时序和功耗仍需在统一工艺库、SDC、corner、真实 FE 与活动文件下完成正式签核。
