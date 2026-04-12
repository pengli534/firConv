function results = ChannelFixedPointTools()
% ChannelFixedPointTools
% -------------------------------------------------------------------------
% 目的:
%   将信道系数 MAT 文件中的 H (浮点) 转成 FPGA 使用的数据文件:
%   1) 定点化后的 MAT
%   2) 滤波器系数文件 .irc (32-bit word, UTF-8 text)
%   3) 时延系数文件 .ird (32-bit word, UTF-8 text)
%   4) 手工检查辅助文本（十进制展开）
%
% 与需求文档对齐的核心约束:
%   - H 组织: Nsamples x (T_num*3) x (IN_num*OUT_num)
%   - 每个 tap 三元组: [delay, real, imag]
%   - delay 单位: ns (本版按最新 codex.md 固定为 ns)
%   - 实虚部量化: int16 (有符号 16 位)
%   - .irc 位域: BIT[15:0]=real, BIT[31:16]=imag
%   - .ird 位域: BIT[31] 为增减方向, BIT[30:0] 为时钟变化量幅值
%   - tap 对齐: T1_num = ceil(T_num/4)*4, 不足补 0 (TZ_num)
%   - .ird 写出: 按人工检查结论，对所有 OUT 通道都写出，避免遗漏子信道
%
% 输出目录:
%   默认写到 ./codex_gen/output
% -------------------------------------------------------------------------

clc;
close all;

fprintf('==================================================\n');
fprintf('  信道系数定点化与 .irc/.ird 导出工具\n');
fprintf('==================================================\n');

% 目录组织:
% scriptDir   -> 当前脚本所在目录 (codex_gen)
% projectRoot -> 项目根目录 (channelGen)
scriptDir = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);

% 默认输入目录指向已有样例库
defaultInputDir = fullfile(projectRoot, 'tap_to_asc_matlab', 'cir_mat_file');

% 所有新输出都放在 codex_gen/output，避免和旧目录混写
defaultOutputDir = fullfile(scriptDir, 'output');
if ~isfolder(defaultOutputDir)
    mkdir(defaultOutputDir);
end

% 可选: 先生成一组“人工可辨识”的验证样例
% 样例集覆盖:
%   - 基础可读性
%   - 时延变化量正/负/零变化
%   - T_num 非4倍数时的补零对齐
%   - 子信道完整性
%   - 定点量化边界
genTest = askNumeric('是否生成验证样例集 .mat？(1/0, 默认1): ', 1);
if genTest == 1
    validationDir = fullfile(scriptDir, 'validation_mats');
    validationFiles = generateValidationMats(validationDir);
    fprintf('已生成 %d 个验证文件:\n', numel(validationFiles));
    for i = 1:numel(validationFiles)
        fprintf('  %s\n', validationFiles{i});
    end
end

% 文件选择起始目录优先使用 cir_mat_file
if isfolder(defaultInputDir)
    startDir = defaultInputDir;
else
    startDir = projectRoot;
end

% 交互选择输入 MAT
[fileName, filePath] = uigetfile({'*.mat','MAT files (*.mat)'}, '选择包含 H 的 .mat 文件', startDir);
if isequal(fileName, 0)
    error('未选择输入 .mat 文件。');
end
inputFile = fullfile(filePath, fileName);

% 读取 MAT
src = load(inputFile);
if ~isfield(src, 'H')
    error('输入 .mat 缺少变量 H。');
end

H = src.H;
if ~isnumeric(H)
    error('H 必须是数值数组。');
end
if ~(ismatrix(H) || ndims(H) == 3)
    error('H 维度必须是 2D 或 3D。');
end

% 解析 H 维度
% Nsamples: CIR 快照数
% packedCols: 第二维总列数，必须是 3 的整数倍
% T_num: 每通道 tap 数
% Nchannel: IN*OUT
Nsamples = size(H, 1);
packedCols = size(H, 2);
if mod(packedCols, 3) ~= 0
    error('H 第二维必须是 3 的整数倍（delay/real/imag）。');
end
T_num = packedCols / 3;
if ismatrix(H)
    Nchannel = 1;
else
    Nchannel = size(H, 3);
end

% IN/OUT 优先从 MAT 的元数据读取，否则按通道数推断
[IN_num, OUT_num] = inferInOut(src, Nchannel);

% 从三元组中提取各分量
% H_delay/H_real/H_imag 统一输出成 3D: [Nsamples, T_num, Nchannel]
H_delay = extractTriplet(H, 1);
H_real = extractTriplet(H, 2);
H_imag = extractTriplet(H, 3);
H_cpx = H_real + 1i .* H_imag;

% CIR 刷新率字段可能名称不统一，做多候选读取
cirRate = readScalar(src, {'cir_up_rate','CIR_update_rate','CIRUpdateRate','fs'}, NaN);
if isnan(cirRate)
    cirRate = askNumeric('未检测到 CIR update rate，请输入 (Hz，默认1e6): ', 1e6);
end

fprintf('\n=== 输入分析 ===\n');
fprintf('输入文件: %s\n', inputFile);
fprintf('H维度: [%d, %d, %d]\n', Nsamples, packedCols, Nchannel);
fprintf('Nsamples: %d\n', Nsamples);
fprintf('T_num: %d\n', T_num);
fprintf('IN_num: %d\n', IN_num);
fprintf('OUT_num: %d\n', OUT_num);
fprintf('CIR update rate: %.6g Hz\n', cirRate);

% 计算每个 channel 的平均功率，再计算整体 model gain
avgPowerPerCh = zeros(1, Nchannel);
for ch = 1:Nchannel
    p = abs(H_cpx(:,:,ch)).^2;
    avgPowerPerCh(ch) = mean(p(:));
end
modelGainDb = 10 * log10(mean(avgPowerPerCh));

% 仿真相关统计
simDurationSec = Nsamples / cirRate;
dopplerEst = cirRate / 4;

fprintf('平均功率(各channel): %s\n', mat2str(avgPowerPerCh, 6));
fprintf('Model gain: %.6f dB\n', modelGainDb);
fprintf('仿真时长: %.9g s\n', simDurationSec);
fprintf('多普勒扩展估计: +/- %.6g Hz\n', dopplerEst);

% ------------------------------
% 定点化配置
% ------------------------------
normalizeFlag = askNumeric('是否归一化后再定点化？(1/0, 默认1): ', 1);
modeManual = askNumeric('定点方式: 自动IQ_max(0) / 手动IQ_max(1), 默认0: ', 0);

if modeManual == 1
    IQ_max = askNumeric('请输入手动 IQ_max (>0): ', 1);
    if IQ_max <= 0
        error('IQ_max 必须 > 0。');
    end
    modeText = 'manual';
else
    % 自动模式: 使用全局实虚部绝对值最大值
    IQ_max = max(abs([H_real(:); H_imag(:)]));
    if IQ_max == 0
        IQ_max = 1;
    end
    modeText = 'auto';
end

fprintf('\n=== 定点化配置 ===\n');
fprintf('定点方式: %s\n', modeText);
fprintf('归一化: %d\n', normalizeFlag);
fprintf('IQ_max: %.12g\n', IQ_max);

% 量化缩放:
%   归一化时: x / IQ_max 映射到 [-1,1]，再乘 32767
%   非归一化: 直接按整数四舍五入并饱和到 int16
if normalizeFlag == 1
    scale = (2^15 - 1) / IQ_max;
else
    scale = 1;
end
fprintf('量化缩放 scale: %.12g\n', scale);

% 按最新 codex.md 增加 FPGA 时钟频率询问步骤
fpgaClock = askNumeric('请输入 FPGA 时钟频率 (Hz，默认245.76e6，调试模式可输入1e9): ', 245.76e6);
fprintf('FPGA时钟频率: %.12g Hz\n', fpgaClock);

% 使用 fi 执行“取整 + 饱和”逻辑，和目标硬件习惯一致
fm = fimath('RoundingMethod','Nearest', 'OverflowAction','Saturate');
realScaled = H_real * scale;
imagScaled = H_imag * scale;
qRealFi = fi(realScaled, 1, 16, 0, fm);
qImagFi = fi(imagScaled, 1, 16, 0, fm);

% 取出底层有符号 16 位整数
qReal = int16(qRealFi.int);
qImag = int16(qImagFi.int);

% 误差定义:
%   - normalize=1: 先反标定回原量纲再比较
%   - normalize=0: 直接与原值比较（本质是整数化误差）
if normalizeFlag == 1
    recReal = double(qReal) / scale;
    recImag = double(qImag) / scale;
else
    recReal = double(qReal);
    recImag = double(qImag);
end
err = abs((H_real + 1i*H_imag) - (recReal + 1i*recImag));
maxErr = max(err(:));
meanErr = mean(err(:));

fprintf('\n=== 量化误差 ===\n');
fprintf('max abs error : %.6e\n', maxErr);
fprintf('mean abs error: %.6e\n', meanErr);
fprintf('阈值判定(<1e-4): %d\n', maxErr < 1e-4);

% ------------------------------
% delay(ns) -> FPGA 时钟计数
% ------------------------------
% 按最新 codex.md，delay 单位固定是 ns，不再做自动/手动切换。
delayClocks = round(H_delay * 1e-9 * fpgaClock);
delayUnitText = 'ns';
fprintf('delay单位: %s (按规范固定)\n', delayUnitText);

% tap 对齐规则 (4 个 32-bit 对齐)
T1_num = ceil(T_num / 4) * 4;
TZ_num = T1_num - T_num;
fprintf('T1_num=%d, TZ_num=%d\n', T1_num, TZ_num);

% 构建输出字流
% .irc/.ird 均按文档伪代码顺序展开
[ircWords, irdWords] = buildWords(qReal, qImag, delayClocks, IN_num, OUT_num, T_num, T1_num);

% 输出文件命名: 使用输入文件同名
[~, baseName, ~] = fileparts(inputFile);
outPrefix = fullfile(defaultOutputDir, baseName);
outIrc = [outPrefix, '.irc'];
outIrd = [outPrefix, '.ird'];
outMat = [outPrefix, '_fixedpoint.mat'];
outIrcDebug = [outPrefix, '_irc_decimal.txt'];
outIrdDebug = [outPrefix, '_ird_decimal.txt'];

% 写 .irc/.ird，UTF-8 文本：
%   连续写 tap 字流，但每4个32-bit字换一行，满足4x32bit对齐显示。
%   每行固定 4*8 = 32 个 hex 字符。
writeHexAligned4(outIrc, ircWords);
writeHexAligned4(outIrd, irdWords);
writeIrcDebugDecimal(outIrcDebug, ircWords);
writeIrdDebugDecimal(outIrdDebug, irdWords);

% 汇总元数据，便于回溯参数与结果
meta = struct();
meta.input_file = inputFile;
meta.Nsamples = Nsamples;
meta.T_num = T_num;
meta.T1_num = T1_num;
meta.TZ_num = TZ_num;
meta.IN_num = IN_num;
meta.OUT_num = OUT_num;
meta.channels = Nchannel;
meta.cir_update_rate_hz = cirRate;
meta.sim_duration_sec = simDurationSec;
meta.doppler_est_hz = dopplerEst;
meta.mode = modeText;
meta.normalize = normalizeFlag;
meta.IQ_max = IQ_max;
meta.scale = scale;
meta.delay_unit = delayUnitText;
meta.fpga_clock_hz = fpgaClock;
meta.max_abs_error = maxErr;
meta.mean_abs_error = meanErr;
meta.manual_debug_irc_decimal = outIrcDebug;
meta.manual_debug_ird_decimal = outIrdDebug;

% 构造“和 H 同结构”的量化后矩阵:
% 按最新 codex.md，Hq 中 delay 列改为 FPGA 时钟计数整数，保证输出自洽
Hq = zeros(size(H), 'double');
if ismatrix(H)
    Hq(:,1:3:end) = double(delayClocks(:,:,1));
    Hq(:,2:3:end) = double(qReal(:,:,1));
    Hq(:,3:3:end) = double(qImag(:,:,1));
else
    for ch = 1:Nchannel
        Hq(:,1:3:end,ch) = double(delayClocks(:,:,ch));
        Hq(:,2:3:end,ch) = double(qReal(:,:,ch));
        Hq(:,3:3:end,ch) = double(qImag(:,:,ch));
    end
end

% 兼容旧版本字段名，便于历史脚本和人工排查继续复用。
delay_clks = delayClocks;
IQ_max = metaCompatibleScalar(IQ_max);
CIR_update_rate = cirRate;
normalize = normalizeFlag;
irc_words = ircWords;
ird_words = irdWords;

% 保存 MAT 输出
save(outMat, 'H', 'qRealFi', 'qImagFi', 'Hq', 'meta', ...
    'delay_clks', 'IQ_max', 'CIR_update_rate', ...
    'normalize', 'IN_num', 'OUT_num', 'T_num', 'irc_words', 'ird_words');

fprintf('\n=== 输出文件 ===\n');
fprintf('%s\n', outMat);
fprintf('%s\n', outIrc);
fprintf('%s\n', outIrd);
fprintf('%s\n', outIrcDebug);
fprintf('%s\n', outIrdDebug);

% 返回结构体，便于脚本化调用
results = struct();
results.out_mat = outMat;
results.out_irc = outIrc;
results.out_ird = outIrd;
results.out_irc_decimal = outIrcDebug;
results.out_ird_decimal = outIrdDebug;
results.max_abs_error = maxErr;
results.mean_abs_error = meanErr;
results.meta = meta;
end

function x = metaCompatibleScalar(x)
% metaCompatibleScalar
% 将保存到 MAT 顶层的标量统一转为 double，避免历史脚本读取时出现类型分歧。
x = double(x);
end

function X = extractTriplet(H, pos)
% extractTriplet
% 从三元组列中抽取指定分量:
%   pos=1 -> delay
%   pos=2 -> real
%   pos=3 -> imag
%
% 输入 H 支持:
%   2D: [Nsamples, T_num*3]
%   3D: [Nsamples, T_num*3, Nchannel]
%
% 输出统一为 3D: [Nsamples, T_num, Nchannel]
if ismatrix(H)
    X = zeros(size(H,1), size(H,2)/3, 1);
    X(:,:,1) = H(:,pos:3:end);
else
    X = zeros(size(H,1), size(H,2)/3, size(H,3));
    for ch = 1:size(H,3)
        X(:,:,ch) = H(:,pos:3:end,ch);
    end
end
end

function [IN_num, OUT_num] = inferInOut(src, Nchannel)
% inferInOut
% 尝试从 MAT 字段中识别 IN/OUT 数量。
% 兼容多个候选字段名，若不存在则按 Nchannel 推断。
IN_num = readScalar(src, {'IN_num','N_T','Ntx','N_mimo_input','MIMOInputCount'}, NaN);
OUT_num = readScalar(src, {'OUT_num','N_R','Nrx','N_mimo_output','MIMOOutputCount'}, NaN);

if ~isnan(IN_num) && ~isnan(OUT_num)
    IN_num = max(1, round(IN_num));
    OUT_num = max(1, round(OUT_num));
    return;
end

% 2D 或单通道时默认 SISO
if Nchannel == 1
    IN_num = 1;
    OUT_num = 1;
    return;
end

% 若通道数是完全平方数，优先假设 IN=OUT=sqrt(Nchannel)
s = round(sqrt(Nchannel));
if s * s == Nchannel
    IN_num = s;
    OUT_num = s;
else
    % 否则采用保守退化: IN=1, OUT=Nchannel
    IN_num = 1;
    OUT_num = Nchannel;
end
end

function v = readScalar(src, names, defaultV)
% readScalar
% 在结构体 src 中按候选字段名顺序读取一个数值标量。
% 找不到则返回 defaultV。
v = defaultV;
for i = 1:numel(names)
    n = names{i};
    if isfield(src, n)
        t = src.(n);
        if isnumeric(t) && isscalar(t)
            v = double(t);
            return;
        end
    end
end
end

function val = askNumeric(prompt, defaultVal)
% askNumeric
% 读取一个数值输入；空输入或非法输入时回退默认值。
s = input(prompt, 's');
if isempty(s)
    val = defaultVal;
else
    val = str2double(s);
    if isnan(val)
        val = defaultVal;
    end
end
end

function [ircWords, irdWords] = buildWords(qReal, qImag, delayClocks, IN_num, OUT_num, T_num, T1_num)
% buildWords
% 按文档伪代码顺序，构建 .irc/.ird 的 32-bit 字流。
%
% 展开顺序:
%   for s = 1..Nsamples
%     for m = 1..IN_num
%       for n = 1..OUT_num
%         for t = 1..T1_num
%           写 CF
%           写 CD
%         end
%       end
%     end
%   end
%
% 说明:
%   - CF 每个元素占 32bit
%   - CD 每个元素占 32bit
%   - t > T_num 时填 0 (TZ_num padding)

Nsamples = size(qReal, 1);
Nchannel = size(qReal, 3);

% .irc 总字数: 每个 sample 都写满 IN*OUT*T1_num
ircWords = zeros(Nsamples * IN_num * OUT_num * T1_num, 1, 'uint32');

% .ird 总字数: 按最新人工检查结论，所有 OUT 通道都需要写出
irdWords = zeros(Nsamples * IN_num * OUT_num * T1_num, 1, 'uint32');

iIdx = 1;
dIdx = 1;
for s = 1:Nsamples
    for m = 1:IN_num
        for n = 1:OUT_num
            % 通道映射约定:
            % ch = (m-1)*OUT_num + n
            ch = (m - 1) * OUT_num + n;
            if ch > Nchannel
                error('IN/OUT 与 H 通道数不匹配。');
            end

            for t = 1:T1_num
                % -------------------------
                % CF 写出 (.irc)
                % -------------------------
                if t <= T_num
                    % 将 int16 位模式无符号重解释后拼接:
                    % [31:16]=imag, [15:0]=real
                    re16 = typecast(qReal(s,t,ch), 'uint16');
                    im16 = typecast(qImag(s,t,ch), 'uint16');
                    ircWords(iIdx) = bitor(uint32(re16), bitshift(uint32(im16), 16));
                else
                    % tap padding 区域补 0
                    ircWords(iIdx) = uint32(0);
                end
                iIdx = iIdx + 1;

                % -------------------------
                % CD 写出 (.ird)
                % -------------------------
                % 按最新人工检查结论，所有 OUT 子信道都必须写出 delay 系数
                if t <= T_num
                    % 相邻 sample 的 delay 时钟差分
                    % s=1 时以上一帧=0 作为参考
                    if s == 1
                        prev = int64(0);
                    else
                        prev = int64(delayClocks(s - 1, t, ch));
                    end
                    cur = int64(delayClocks(s, t, ch));
                    delta = cur - prev;

                    % 幅值限制在 31 bit
                    mag = uint32(min(abs(delta), int64(2^31 - 1)));

                    % BIT31: 0=增大, 1=减小
                    if delta < 0
                        irdWords(dIdx) = bitor(bitshift(uint32(1), 31), mag);
                    else
                        irdWords(dIdx) = mag;
                    end
                else
                    % tap padding 区域补 0
                    irdWords(dIdx) = uint32(0);
                end
                dIdx = dIdx + 1;
            end
        end
    end
end
end

function writeHexAligned4(pathName, words)
% writeHexAligned4
% 将 uint32 字流输出为 UTF-8 文本，按“每4个字换行”写出。
%
% 规则:
%   - 行内: 连续拼接4个32-bit字，每字8位hex。
%   - 行尾: 换行。
%   - 不在字之间加空格或分隔符。
%
% 说明:
%   - 该格式与“任何情况下满足4个32比特对齐”要求一致。
%   - 若总字数不是4的整数倍，最后补零凑齐一行。
wordsPerLine = 4;
remWords = mod(numel(words), wordsPerLine);
if remWords ~= 0
    words = [words; zeros(wordsPerLine - remWords, 1, 'uint32')];
end

fid = fopen(pathName, 'w', 'n', 'UTF-8');
if fid < 0
    error('无法写入文件: %s', pathName);
end
c = onCleanup(@() fclose(fid));
for i = 1:wordsPerLine:numel(words)
    lineWords = words(i:i+wordsPerLine-1);
    for k = 1:wordsPerLine
        fprintf(fid, '%08X', lineWords(k));
    end
    fprintf(fid, '\n');
end
end

function writeIrcDebugDecimal(pathName, words)
% writeIrcDebugDecimal
% .irc 手工检查辅助文件：
%   每个 32-bit 字拆成 2 个 int16 十进制数（real, imag），
%   每行对应 4 个 32-bit 字，因此每行输出 8 个十进制数。
fid = fopen(pathName, 'w', 'n', 'UTF-8');
if fid < 0
    error('无法写入文件: %s', pathName);
end
c = onCleanup(@() fclose(fid));

wordsPerLine = 4;
for i = 1:wordsPerLine:numel(words)
    lineWords = words(i:min(i + wordsPerLine - 1, numel(words)));
    vals = zeros(1, numel(lineWords) * 2);
    vIdx = 1;
    for k = 1:numel(lineWords)
        w = lineWords(k);
        re = typecast(uint16(bitand(w, uint32(hex2dec('FFFF')))), 'int16');
        im = typecast(uint16(bitshift(w, -16)), 'int16');
        vals(vIdx) = double(im);
        vals(vIdx + 1) = double(re);
        vIdx = vIdx + 2;
    end
    fprintf(fid, '%d', vals(1));
    for k = 2:numel(vals)
        fprintf(fid, ' %d', vals(k));
    end
    fprintf(fid, '\n');
end
end

function writeIrdDebugDecimal(pathName, words)
% writeIrdDebugDecimal
% .ird 手工检查辅助文件：
%   每个 32-bit 字按无符号整数转十进制，
%   每行对应 4 个 32-bit 字，因此每行输出 4 个十进制数。
fid = fopen(pathName, 'w', 'n', 'UTF-8');
if fid < 0
    error('无法写入文件: %s', pathName);
end
c = onCleanup(@() fclose(fid));

wordsPerLine = 4;
for i = 1:wordsPerLine:numel(words)
    lineWords = double(words(i:min(i + wordsPerLine - 1, numel(words))));
    fprintf(fid, '%.0f', lineWords(1));
    for k = 2:numel(lineWords)
        fprintf(fid, ' %.0f', lineWords(k));
    end
    fprintf(fid, '\n');
end
end

function outFiles = generateValidationMats(outDir)
% generateValidationMats
% 生成一组职责明确的验证样例，避免单个样例承担全部验证目标。
if ~isfolder(outDir)
    mkdir(outDir);
end

cases = {
    makeValidationCaseBasic(), ...
    makeValidationCaseDelayDelta(), ...
    makeValidationCasePadding(), ...
    makeValidationCaseChannelCoverage(), ...
    makeValidationCaseQuantBoundary()};

outFiles = cell(numel(cases), 1);
for i = 1:numel(cases)
    data = cases{i};
    outFile = fullfile(outDir, data.fileName);
    H = data.H;
    IN_num = data.IN_num;
    OUT_num = data.OUT_num;
    cir_up_rate = data.cir_up_rate;
    validation_info = data.validation_info;
    save(outFile, 'H', 'IN_num', 'OUT_num', 'cir_up_rate', 'validation_info');
    outFiles{i} = outFile;
end
end

function data = makeValidationCaseBasic()
% 基础可读性样例:
%   - 便于人工识别 sample / IN / OUT / tap
Nsamples = 4;
T_num = 24;
IN_num = 4;
OUT_num = 4;
cir_up_rate = 1e6;
H = zeros(Nsamples, T_num * 3, IN_num * OUT_num);

for s = 1:Nsamples
    for m = 1:IN_num
        for n = 1:OUT_num
            ch = mapChannelIndex(m, n, OUT_num);
            for t = 1:T_num
                code = m * 1000 + n * 100 + t;
                delay_ns = 1000 + code * 10 + s * 40;
                real_v = code;
                imag_v = code + 50;
                H = setTapTriplet(H, s, t, ch, delay_ns, real_v, imag_v);
            end
        end
    end
end

data = wrapValidationCase( ...
    'validation_basic.mat', H, IN_num, OUT_num, cir_up_rate, ...
    '基础可读性样例', ...
    {'验证 H 的维度组织'; '验证 IN/OUT/tap/sample 编码是否易于人工识别'; '验证基础 .irc/.ird 落盘顺序'});
end

function data = makeValidationCaseDelayDelta()
% 时延变化量样例:
%   - 同时覆盖时延增大/减小/不变三种情况
Nsamples = 5;
T_num = 24;
IN_num = 4;
OUT_num = 4;
cir_up_rate = 1e6;
H = zeros(Nsamples, T_num * 3, IN_num * OUT_num);
sampleOffsetNs = [0, 40, 40, 10, 70];

for s = 1:Nsamples
    for m = 1:IN_num
        for n = 1:OUT_num
            ch = mapChannelIndex(m, n, OUT_num);
            for t = 1:T_num
                code = m * 1000 + n * 100 + t;
                delay_ns = 5000 + code * 12 + sampleOffsetNs(s);
                real_v = code;
                imag_v = -(code + 25);
                H = setTapTriplet(H, s, t, ch, delay_ns, real_v, imag_v);
            end
        end
    end
end

data = wrapValidationCase( ...
    'validation_delay_delta.mat', H, IN_num, OUT_num, cir_up_rate, ...
    '时延变化量样例', ...
    {'检查 .ird 中相邻时刻变化量'; 'sample 1->2 为增大'; 'sample 2->3 为不变'; 'sample 3->4 为减小'; 'sample 4->5 再次增大'});
end

function data = makeValidationCasePadding()
% 补零对齐样例:
%   - T_num 非4的整数倍，用于稳定触发 TZ_num 补零
Nsamples = 3;
T_num = 22;
IN_num = 4;
OUT_num = 4;
cir_up_rate = 1e6;
H = zeros(Nsamples, T_num * 3, IN_num * OUT_num);

for s = 1:Nsamples
    for m = 1:IN_num
        for n = 1:OUT_num
            ch = mapChannelIndex(m, n, OUT_num);
            for t = 1:T_num
                code = m * 1000 + n * 100 + t;
                delay_ns = 800 + t * 25 + s * 100 + m * 10 + n;
                real_v = 100 + code;
                imag_v = -(100 + code);
                H = setTapTriplet(H, s, t, ch, delay_ns, real_v, imag_v);
            end
        end
    end
end

data = wrapValidationCase( ...
    'validation_padding.mat', H, IN_num, OUT_num, cir_up_rate, ...
    '补零对齐样例', ...
    {'T_num=22，应补齐到24'; '用于检查 TZ_num=2 时 .irc/.ird 尾部补零'; '用于检查每4个32-bit字换行'});
end

function data = makeValidationCaseChannelCoverage()
% 子信道完整性样例:
%   - 不同 out_num / in_num 使用明显不同编码
Nsamples = 2;
T_num = 8;
IN_num = 4;
OUT_num = 4;
cir_up_rate = 1e6;
H = zeros(Nsamples, T_num * 3, IN_num * OUT_num);

for s = 1:Nsamples
    for m = 1:IN_num
        for n = 1:OUT_num
            ch = mapChannelIndex(m, n, OUT_num);
            channelTag = m * 10000 + n * 1000;
            for t = 1:T_num
                delay_ns = 2000 + channelTag + t * 20 + s * 200;
                real_v = channelTag + t * 10 + 1;
                imag_v = -(channelTag + t * 10 + 2);
                H = setTapTriplet(H, s, t, ch, delay_ns, real_v, imag_v);
            end
        end
    end
end

data = wrapValidationCase( ...
    'validation_channel_coverage.mat', H, IN_num, OUT_num, cir_up_rate, ...
    '子信道完整性样例', ...
    {'不同 (in_num,out_num) 使用明显不同编码'; '用于检查偶数/奇数 out_num 都被完整写出'; '同时可检查 .irc 和 .ird 的通道覆盖'});
end

function data = makeValidationCaseQuantBoundary()
% 定点边界样例:
%   - 覆盖小数舍入、边界值、越界饱和
Nsamples = 2;
T_num = 8;
IN_num = 2;
OUT_num = 2;
cir_up_rate = 1e6;
H = zeros(Nsamples, T_num * 3, IN_num * OUT_num);
realPattern = [-32768.4, -32767.5, -1.5, -0.49, 0.49, 1.5, 32766.6, 40000.2];
imagPattern = [40000.2, 32766.6, 1.5, 0.49, -0.49, -1.5, -32767.5, -32768.4];

for s = 1:Nsamples
    for m = 1:IN_num
        for n = 1:OUT_num
            ch = mapChannelIndex(m, n, OUT_num);
            tweak = (m - 1) * 0.125 + (n - 1) * 0.25 + (s - 1) * 0.5;
            for t = 1:T_num
                delay_ns = 100 + t * 8 + s * 16;
                real_v = realPattern(t) + tweak;
                imag_v = imagPattern(t) - tweak;
                H = setTapTriplet(H, s, t, ch, delay_ns, real_v, imag_v);
            end
        end
    end
end

data = wrapValidationCase( ...
    'validation_quant_boundary.mat', H, IN_num, OUT_num, cir_up_rate, ...
    '定点边界样例', ...
    {'覆盖接近 int16 上下限的值'; '覆盖超范围后的饱和'; '覆盖接近 0 和 .5 的舍入行为'});
end

function data = wrapValidationCase(fileName, H, IN_num, OUT_num, cir_up_rate, target, checkpoints)
validation_info = struct();
validation_info.target = target;
validation_info.checkpoints = checkpoints;
validation_info.generated_by = 'ChannelFixedPointTools';
validation_info.version = 'validation_suite_v1';

data = struct();
data.fileName = fileName;
data.H = H;
data.IN_num = IN_num;
data.OUT_num = OUT_num;
data.cir_up_rate = cir_up_rate;
data.validation_info = validation_info;
end

function H = setTapTriplet(H, sampleIdx, tapIdx, channelIdx, delayValue, realValue, imagValue)
baseIdx = (tapIdx - 1) * 3;
H(sampleIdx, baseIdx + 1, channelIdx) = delayValue;
H(sampleIdx, baseIdx + 2, channelIdx) = realValue;
H(sampleIdx, baseIdx + 3, channelIdx) = imagValue;
end

function ch = mapChannelIndex(inIdx, outIdx, OUT_num)
ch = (inIdx - 1) * OUT_num + outIdx;
end
