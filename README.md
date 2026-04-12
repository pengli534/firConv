# FIR / MIMO Validation Tool

## 简介

`FirConvValidationTool.m` 是一个 MATLAB 工具，用于验证信道卷积链路中的浮点参考结果与 FPGA 定点数据链路之间的一致性。

当前版本主要完成以下工作：

1. 从 `signalGen\` 读取浮点 IQ 和定点 IQ 数据
2. 从 `channelGen\` 读取浮点信道和定点信道数据
3. 对每组 IQ 信号和每组信道执行时变 FIR / MIMO 卷积
4. 对定点全精度累加结果执行动态截位搜索
5. 输出误差指标、最佳 shift、宽搜索建议值和结果文件


## 当前目录约定

项目目录下需要包含以下内容：

1. `signalGen\fpga_test_signals.mat`
2. `signalGen\sim_sine_iq.txt`
3. `signalGen\sim_ofdm_iq.txt`
4. `signalGen\sim_debug_real_iq.txt`
5. `signalGen\sim_debug_imag_iq.txt`
6. `channelGen\*.mat`
7. `channelGen\*.irc`
8. `channelGen\*.ird`

其中：

1. 浮点 IQ 只从 `.mat` 读取
2. 定点 IQ 只从 `.txt` 读取
3. 定点信道只从 `.irc/.ird` 读取


## 输入数据说明

### 浮点 IQ

从 `signalGen\fpga_test_signals.mat` 读取：

1. `fs`
2. `iq_sine_float`
3. `iq_ofdm_float`

### 定点 IQ

从以下文本文件读取：

1. `sim_sine_iq.txt`
2. `sim_ofdm_iq.txt`
3. `sim_debug_real_iq.txt`
4. `sim_debug_imag_iq.txt`

格式为：

1. 每行一个 32-bit 十六进制字
2. 高 16 bit 是 Q
3. 低 16 bit 是 I

### 信道数据

从 `channelGen\` 读取：

1. `<prefix>_fixedpoint.mat`
2. `<prefix>.irc`
3. `<prefix>.ird`

程序会自动兼容 `*_fixedpoint.mat` 与同前缀 `.irc/.ird` 的配对方式。


## 主要处理流程

工具对每个“信号 + 信道”组合执行以下步骤：

1. 读取浮点 IQ 和定点 IQ
2. 读取浮点信道 `H`
3. 解析 `.irc/.ird`，恢复定点系数和时延
4. 根据 `cir_up_rate` 进行 snapshot 时间窗映射
5. 执行浮点时变 FIR 卷积
6. 执行定点时变 FIR 卷积，全程保持高精度累加
7. 搜索最佳右移位 `shift`
8. 输出误差指标和结果文件


## 截位搜索规则

默认情况下：

1. 正式搜索范围是 `0 ~ 18`
2. 额外给出一个“宽搜索建议值”
3. 宽搜索范围默认是 `0 ~ 24`

搜索目标：

1. 主目标是 `MSE` 最小
2. 若 `MSE` 相同，则选择 `max abs error` 更小的方案
3. 若仍相同，则选择更小的 `shift`


## 调试序列说明

默认情况下只验证：

1. `sine`
2. `ofdm`

如果打开 `include_debug` 开关，则额外验证：

1. `sim_debug_real_iq.txt`
2. `sim_debug_imag_iq.txt`

注意：

1. 调试序列只从 `.txt` 读取
2. 调试序列用于 FPGA 原始码流核对
3. 调试序列误差不做归一化


## 使用方法

在 MATLAB 当前目录切到本项目根目录后，可直接运行：

```matlab
results = FirConvValidationTool();
```

如果希望把调试序列也加入验证：

```matlab
results = FirConvValidationTool('include_debug', true);
```

如果希望手动指定 shift：

```matlab
results = FirConvValidationTool('manual_shift', 12);
```

如果希望调整搜索范围：

```matlab
results = FirConvValidationTool( ...
    'shift_min', 0, ...
    'shift_max', 18, ...
    'wide_shift_min', 0, ...
    'wide_shift_max', 24);
```


## 输出内容

所有输出默认保存到：

`output\`

每个测试组合会生成：

1. `<signal>__<channel>.mat`
2. `<signal>__<channel>_report.txt`
3. `<signal>__<channel>_fixed_out_chXX.txt`
4. `<signal>__<channel>_float_out_chXX.txt`

此外还会生成总汇总文件：

1. `validation_summary.mat`


## 报告内容

每个 `_report.txt` 至少包含：

1. 信号名
2. 信道名前缀
3. `fs`
4. `cir_up_rate`
5. `IN_num`
6. `OUT_num`
7. `T_num`
8. 最佳 `shift`
9. 宽搜索建议值
10. `MSE`
11. 平均绝对误差
12. 最大绝对误差


## 当前实现边界

当前版本只实现以下范围：

1. 只考虑 `clk = fs`
2. 时延换算后，`delay_clk` 直接作为样值移位
3. 还未实现 `2*clk = fs` 时的奇偶双路拆分结构

后续下一阶段会再扩展：

1. `2*clk = fs`
2. 所有信号路径和信道路径拆分为奇偶两路


## 建议阅读文件

如果需要了解实现细节，建议优先查看：

1. [`FirConvValidationTool.m`](c:\Users\pengl\Documents\CloudStation\捷希科技\信道模拟器\fixedpoints\firConv\FirConvValidationTool.m)
2. [`agent.md`](c:\Users\pengl\Documents\CloudStation\捷希科技\信道模拟器\fixedpoints\firConv\agent.md)
