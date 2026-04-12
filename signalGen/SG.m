%% FPGA 调试信号生成脚本
% 采样率: 245.76 MHz
% 任务 1: 20MHz 正弦波 IQ 信号
% 任务 2: 实部递增序列 (用于数据流对齐调试)

clear; clc; close all;

%% 1. 参数设置
fs = 245.76e6;              % 采样率 245.76 MHz
num_samples = 16384;        % 生成样本点数 (增加长度以包含完整的OFDM符号)
t = (0:num_samples-1).' / fs; % 时间向量

%% 2. 生成 20MHz 正弦波 IQ 信号 (浮点)
fc = 20e6;                  % 正弦波频率 20 MHz

% 正弦波没有高 PAPR，将其幅度设为 1.0，以充分利用完整的 16-bit 满量程进行数据线连通性测试
amplitude_sin = 1.0;
iq_sine_float = amplitude_sin * exp(1j * 2 * pi * fc * t);

%% 3. 生成宽带 OFDM IQ 信号 (浮点)
% 简单的宽带 OFDM 参数设置 (约占 100MHz 带宽)
scal = 0.25;                % OFDM 的 PAPR 冗余标度 (留出约12dB动态余量)
fft_size = 4096;
cp_len = 288;
num_subcarriers = 1668; % 有效子载波数量 (1668 * 60kHz = 100.08 MHz)
num_symbols = ceil(num_samples / (fft_size + cp_len));

% 生成随机 QPSK 频域数据
freq_data = zeros(fft_size, num_symbols);
% 分配有效子载波位置 (去除直流和边缘的高频保护带)
active_idx = [2:num_subcarriers/2+1, fft_size-num_subcarriers/2+1:fft_size];
freq_data(active_idx, :) = (sign(randn(length(active_idx), num_symbols)) + ...
                           1j * sign(randn(length(active_idx), num_symbols))) / sqrt(2);

% IFFT 并添加循环前缀 (CP)
time_data = ifft(freq_data, fft_size) * sqrt(fft_size); % 归一化能量
ofdm_tx = [time_data(end-cp_len+1:end, :); time_data];
iq_ofdm_float = ofdm_tx(:);

% 截断至目标的样本长度
iq_ofdm_float = iq_ofdm_float(1:num_samples);

% 施加 PAPR 冗余：按均方根(RMS)功率归一化后乘以 scal (0.25)
% 这样可以保证与 randn 方式的平均功率完全一致 (约为 0.0625)
% 此时信号的极值峰值大约在 0.75~0.9 左右，刚好在 1.0 的定点量程内，充分利用了动态范围
rms_val = sqrt(mean(abs(iq_ofdm_float).^2));
iq_ofdm_float = (iq_ofdm_float / rms_val) * scal;

%% 4. 计算浮点信号平均功率
power_sine_avg = mean(abs(iq_sine_float).^2);
power_ofdm_avg = mean(abs(iq_ofdm_float).^2);

fprintf('=== 信号生成与功率统计 ===\n');
fprintf('正弦波平均功率 (浮点): %.6f\n', power_sine_avg);
fprintf('OFDM信号平均功率 (浮点): %.6f\n', power_ofdm_avg);

%% 5. 信号定点化 (使用 Fixed-Point Designer, 格式 Q15)
% 定义定点数数学规则：四舍五入(Round)，溢出饱和(Saturate)
Fm = fimath('RoundingMethod', 'Round', 'OverflowAction', 'Saturate');

% 定义 Q15 数据类型：1(有符号), 16(字长), 15(小数位宽)
T = numerictype(1, 16, 15);

% 直接一键转换为 fi 对象 (自动处理复数、缩放和饱和)
iq_sine_fi = fi(iq_sine_float, T, Fm);
iq_ofdm_fi = fi(iq_ofdm_float, T, Fm);

% 提取底层 16 位整数用于后续处理和保存
iq_sine_fixed = int16(iq_sine_fi.int);
iq_ofdm_fixed = int16(iq_ofdm_fi.int);

%% 6. 生成 16位自增调试序列 (定点组3)
% 产生每个 clk 递增 1 的序列，模拟 16-bit 有符号数回绕 (-32768 到 32767)
inc_val = mod(0:num_samples-1, 65536).';
inc_val(inc_val > 32767) = inc_val(inc_val > 32767) - 65536;

% 调试序列1：实部递增，虚部为0 (使用 int16 确保数据类型纯净)
debug_inc_real_fixed = complex(int16(inc_val), zeros(num_samples, 1, 'int16'));

% 调试序列2：实部为0，虚部递增 (使用 int16 确保数据类型纯净)
debug_inc_imag_fixed = complex(zeros(num_samples, 1, 'int16'), int16(inc_val));

%% 7. 存储至 .mat 文件
save_filename = 'fpga_test_signals.mat';
save(save_filename, ...
    'fs', 'fc', 'scal', ...
    'iq_sine_float', 'iq_ofdm_float', ...
    'power_sine_avg', 'power_ofdm_avg', ...
    'iq_sine_fixed', 'iq_ofdm_fixed', ...
    'debug_inc_real_fixed', 'debug_inc_imag_fixed');

fprintf('数据已成功保存至: %s\n', save_filename);
fprintf('包含 2 组浮点数据、功率值以及 3 大类(共4组)定点数据。\n');

%% 8. 导出 16进制 TXT 文件 (Xilinx FPGA 仿真/RAM 初始化用)
% 数据格式: 32-bit Hex, 拼接格式为 {Q[15:0], I[15:0]} (高 16位为 Q, 低 16位为 I)
% 适用于 Vivado Testbench ($readmemh) 或 Block RAM 的初始化文件生成

fprintf('=== 开始导出 16进制 TXT 文件 ===\n');

write_iq_hex(iq_sine_fixed, 'sim_sine_iq.txt');
write_iq_hex(iq_ofdm_fixed, 'sim_ofdm_iq.txt');
write_iq_hex(debug_inc_real_fixed, 'sim_debug_real_iq.txt');
write_iq_hex(debug_inc_imag_fixed, 'sim_debug_imag_iq.txt');

fprintf('TXT 文件导出完成，可直接用于 Xilinx 平台仿真。\n\n');

%% 9. 可视化验证 (时域)
figure('Name', 'FPGA 多信号时域验证', 'Color', 'w', 'Position', [100, 100, 1000, 600]);

% 子图 1: 正弦波定点数据 (前100个点)
subplot(2,2,1);
plot(1:100, real(iq_sine_fixed(1:100)), 'b', 'LineWidth', 1.5); hold on;
plot(1:100, imag(iq_sine_fixed(1:100)), 'r--', 'LineWidth', 1.5);
title('定点正弦波时域 (头100点)');
xlabel('样本'); ylabel('量化幅值 (16-bit)'); legend('I', 'Q'); grid on;

% 子图 2: OFDM 定点数据时域
subplot(2,2,2);
plot(1:500, real(iq_ofdm_fixed(1:500)), 'b'); 
title('定点OFDM信号时域 (头500点)');
xlabel('样本'); ylabel('量化幅值 (16-bit)'); grid on;

% 子图 3: 实部递增调试数据
subplot(2,2,3);
plot(1:200, real(debug_inc_real_fixed(1:200)), 'g', 'LineWidth', 1.5); hold on;
plot(1:200, imag(debug_inc_real_fixed(1:200)), 'k--');
title('调试信号1: 实部递增');
xlabel('样本'); ylabel('值'); legend('I', 'Q'); grid on;

% 子图 4: 虚部递增调试数据
subplot(2,2,4);
plot(1:200, real(debug_inc_imag_fixed(1:200)), 'k--'); hold on;
plot(1:200, imag(debug_inc_imag_fixed(1:200)), 'm', 'LineWidth', 1.5);
title('调试信号2: 虚部递增');
xlabel('样本'); ylabel('值'); legend('I', 'Q'); grid on;

%% 10. 可视化验证 (频域)
figure('Name', 'FPGA 多信号频域特性', 'Color', 'w', 'Position', [150, 150, 1000, 600]);

nfft = 8192; % 增加FFT点数使频谱更平滑

% 子图 1: 定点正弦波频域
subplot(2,2,1);
[pxx_sine, f_axis] = periodogram(double(iq_sine_fixed), rectwin(length(iq_sine_fixed)), nfft, fs, 'centered');
plot(f_axis/1e6, 10*log10(pxx_sine/max(pxx_sine)), 'b', 'LineWidth', 1.2);
title('定点正弦波频域 (20MHz)');
xlabel('频率 (MHz)'); ylabel('归一化功率谱密度 (dB)');
grid on; axis tight; ylim([-100 5]);

% 子图 2: 定点OFDM频域
subplot(2,2,2);
% 对于OFDM使用汉宁窗(hann)以减少频谱泄漏
[pxx_ofdm, f_axis_ofdm] = periodogram(double(iq_ofdm_fixed), hann(length(iq_ofdm_fixed)), nfft, fs, 'centered');
plot(f_axis_ofdm/1e6, 10*log10(pxx_ofdm/max(pxx_ofdm)), 'r', 'LineWidth', 1.2);
title('定点OFDM信号频域 (约100MHz带宽)');
xlabel('频率 (MHz)'); ylabel('归一化功率谱密度 (dB)');
grid on; axis tight; ylim([-80 5]);

% 子图 3: 调试信号1(实部递增)频域
subplot(2,2,3);
[pxx_inc1, f_axis_inc] = periodogram(double(debug_inc_real_fixed), hann(length(debug_inc_real_fixed)), nfft, fs, 'centered');
plot(f_axis_inc/1e6, 10*log10(pxx_inc1/max(pxx_inc1)), 'g', 'LineWidth', 1.2);
title('调试信号1 (实部递增锯齿波) 频域');
xlabel('频率 (MHz)'); ylabel('归一化功率谱密度 (dB)');
grid on; axis tight;

% 子图 4: 调试信号2(虚部递增)频域
subplot(2,2,4);
[pxx_inc2, ~] = periodogram(double(debug_inc_imag_fixed), hann(length(debug_inc_imag_fixed)), nfft, fs, 'centered');
plot(f_axis_inc/1e6, 10*log10(pxx_inc2/max(pxx_inc2)), 'm', 'LineWidth', 1.2);
title('调试信号2 (虚部递增锯齿波) 频域');
xlabel('频率 (MHz)'); ylabel('归一化功率谱密度 (dB)');
grid on; axis tight;

%% =========================================================================
%% 辅助函数区
%% =========================================================================

% 辅助函数：导出 IQ 数据为 32-bit Hex 格式
function write_iq_hex(iq_data, filename)
    fid = fopen(filename, 'w');
    if fid == -1
        error('无法创建文件: %s', filename);
    end
    
    % 使用 typecast 严格处理有符号负数(补码)到无符号 uint16 的转换
    % 这是确保 MATLAB 打印 16进制不出错(防止扩展为 64-bit FFFF...)的关键
    I_uint16 = typecast(real(iq_data), 'uint16');
    Q_uint16 = typecast(imag(iq_data), 'uint16');
    
    % 拼接并写入文件: %04X 保证 4 位大写 16 进制字符
    % 要求格式为 {Q[15:0], I[15:0]}，因此在此处先打印 Q，再打印 I
    for k = 1:length(iq_data)
        fprintf(fid, '%04X%04X\n', Q_uint16(k), I_uint16(k));
    end
    fclose(fid);
end