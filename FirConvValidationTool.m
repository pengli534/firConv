function results = FirConvValidationTool(varargin)
% FirConvValidationTool
% -------------------------------------------------------------------------
% MATLAB 信道卷积验证与定点分析工具
%
% 当前阶段范围:
%   - 只考虑 clk = fs
%   - 浮点 IQ 仅从 signalGen/fpga_test_signals.mat 读取
%   - 定点 IQ 仅从 signalGen/*.txt 读取
%   - 定点信道仅从 channelGen/*.irc / *.ird 读取
%   - 信道配对兼容 *_fixedpoint.mat <-> .irc/.ird
%
% 主要能力:
%   1) 扫描 channelGen\ 下所有合法信道组
%   2) 对 sine / OFDM 信号逐组做浮点与定点验证
%   3) 可选将调试序列加入验证
%   4) 自动搜索最佳右移位并输出误差
%   5) 额外输出宽搜索建议值
%   5) 结果保存到 output\
%
% 用法:
%   results = FirConvValidationTool();
%   results = FirConvValidationTool('include_debug', true, 'manual_shift', 10);
% -------------------------------------------------------------------------

rootDir = fileparts(mfilename('fullpath'));

% 步骤 1:
% 解析用户传入的可选参数，得到输入目录、输出目录、
% 是否包含 debug 序列、shift 搜索范围等运行配置。
opts = parseInputs(rootDir, varargin{:});

fprintf('==================================================\n');
fprintf(' MATLAB FIR/MIMO Validation Tool\n');
fprintf('==================================================\n');
fprintf('Root      : %s\n', rootDir);
fprintf('Signal dir: %s\n', opts.signal_dir);
fprintf('Chan dir  : %s\n', opts.channel_dir);
fprintf('Output dir: %s\n', opts.output_dir);
fprintf('Include debug sequences: %d\n', opts.include_debug);
if isnan(opts.manual_shift)
    fprintf('Shift mode: auto\n');
else
    fprintf('Shift mode: manual (%d)\n', opts.manual_shift);
end

ensureDir(opts.output_dir);

% 步骤 2:
% 读取 signalGen\ 下的浮点 IQ 和定点 IQ 资源。
% 这里会同时检查:
%   - 浮点 .mat 是否存在
%   - 定点 .txt 是否存在
%   - 必需变量是否完整
signalData = loadSignalResources(opts.signal_dir);

% 步骤 3:
% 扫描 channelGen\，自动发现所有合法信道组。
% 每组信道至少需要:
%   - 一个包含 H 的 .mat
%   - 一个同前缀 .irc
%   - 一个同前缀 .ird
channelSets = discoverChannelSets(opts.channel_dir);
if isempty(channelSets)
    error('在 %s 下没有找到可用的信道文件组。', opts.channel_dir);
end

% 步骤 4:
% 根据是否启用 debug 序列，构建待验证的 IQ 测试集合。
% 默认只验证 sine / ofdm。
testCases = buildTestCases(signalData, opts.include_debug);

results = struct();
results.root_dir = rootDir;
results.options = opts;
results.timestamp = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
results.signal_summary = rmfield(signalData, {'float_cases', 'fixed_cases'});
results.cases = cell(0, 1);

caseIdx = 1;
for tcIdx = 1:numel(testCases)
    tc = testCases(tcIdx);
    fprintf('\n--------------------------------------------------\n');
    fprintf('Signal case: %s\n', tc.name);
    fprintf('Mode      : %s\n', tc.metric_mode);
    fprintf('--------------------------------------------------\n');

    for chIdx = 1:numel(channelSets)
        try
            chan = channelSets(chIdx);
            fprintf('Channel set: %s\n', chan.prefix);

            % 步骤 5:
            % 对“一个信号 case + 一个信道组”执行完整验证。
            caseResult = runSingleCase(tc, chan, signalData.fs, opts);
            results.cases{caseIdx, 1} = caseResult; 
            printCaseSummary(caseResult);
            caseIdx = caseIdx + 1;
        catch ME
            fprintf(2, '  [ERROR] %s\n', ME.message);
            errResult = struct();
            errResult.signal_name = tc.name;
            errResult.channel_prefix = channelSets(chIdx).prefix;
            errResult.status = 'failed';
            errResult.error_message = ME.message;
            results.cases{caseIdx, 1} = errResult; 
            caseIdx = caseIdx + 1;
        end
    end
end

% 步骤 6:
% 将所有 case 的汇总结果保存到 MAT 文件，便于后处理和批量分析。
summaryFile = fullfile(opts.output_dir, 'validation_summary.mat');
save(summaryFile, 'results', '-v7.3');
fprintf('\nSummary saved: %s\n', summaryFile);
end

function opts = parseInputs(rootDir, varargin)
% parseInputs
% -------------------------------------------------------------------------
% 解析主函数的 Name-Value 输入参数。
%
% 输入:
%   rootDir   - 当前工具所在目录
%   varargin  - 用户传入的可选参数
%
% 输出:
%   opts      - 统一后的配置结构体
%
% 当前支持的参数包括:
%   signal_dir, channel_dir, output_dir
%   include_debug
%   manual_shift
%   shift_min, shift_max
%   wide_shift_min, wide_shift_max
% -------------------------------------------------------------------------
opts = struct();
opts.signal_dir = fullfile(rootDir, 'signalGen');
opts.channel_dir = fullfile(rootDir, 'channelGen');
opts.output_dir = fullfile(rootDir, 'output');
opts.include_debug = false;
opts.manual_shift = NaN;
opts.shift_min = 0;
opts.shift_max = 18;
opts.wide_shift_min = 0;
opts.wide_shift_max = 24;

if mod(numel(varargin), 2) ~= 0
    error('输入参数必须成对出现。');
end

for i = 1:2:numel(varargin)
    key = lower(string(varargin{i}));
    val = varargin{i + 1};
    switch key
        case "signal_dir"
            opts.signal_dir = char(val);
        case "channel_dir"
            opts.channel_dir = char(val);
        case "output_dir"
            opts.output_dir = char(val);
        case "include_debug"
            opts.include_debug = logical(val);
        case "manual_shift"
            if isempty(val)
                opts.manual_shift = NaN;
            else
                opts.manual_shift = double(val);
            end
        case "shift_min"
            opts.shift_min = double(val);
        case "shift_max"
            opts.shift_max = double(val);
        case "wide_shift_min"
            opts.wide_shift_min = double(val);
        case "wide_shift_max"
            opts.wide_shift_max = double(val);
        otherwise
            error('未知参数: %s', key);
    end
end
end

function signalData = loadSignalResources(signalDir)
% loadSignalResources
% -------------------------------------------------------------------------
% 读取 signalGen\ 下的所有 IQ 资源。
%
% 读取内容:
%   1) 浮点 IQ:
%        fpga_test_signals.mat 中的 fs / iq_sine_float / iq_ofdm_float
%   2) 定点 IQ:
%        sim_sine_iq.txt
%        sim_ofdm_iq.txt
%        sim_debug_real_iq.txt
%        sim_debug_imag_iq.txt
%
% 输出:
%   signalData.fs
%   signalData.float_cases
%   signalData.fixed_cases
%
% 说明:
%   - 所有定点 IQ 都必须从 .txt 读取
%   - 调试序列不从 .mat 读取
% -------------------------------------------------------------------------
matPath = fullfile(signalDir, 'fpga_test_signals.mat');
if ~isfile(matPath)
    error('缺少浮点 IQ 文件: %s', matPath);
end

src = load(matPath);
requiredFloat = {'fs', 'iq_sine_float', 'iq_ofdm_float'};
for i = 1:numel(requiredFloat)
    if ~isfield(src, requiredFloat{i})
        error('浮点 IQ 文件缺少变量: %s', requiredFloat{i});
    end
end

fixedFiles = struct( ...
    'sine', fullfile(signalDir, 'sim_sine_iq.txt'), ...
    'ofdm', fullfile(signalDir, 'sim_ofdm_iq.txt'), ...
    'debug_real', fullfile(signalDir, 'sim_debug_real_iq.txt'), ...
    'debug_imag', fullfile(signalDir, 'sim_debug_imag_iq.txt'));

fixedNames = fieldnames(fixedFiles);
for i = 1:numel(fixedNames)
    p = fixedFiles.(fixedNames{i});
    if ~isfile(p)
        error('缺少定点 IQ 文件: %s', p);
    end
end

signalData = struct();
signalData.fs = double(src.fs);
signalData.float_mat = matPath;
signalData.fixed_files = fixedFiles;

signalData.float_cases = struct();
signalData.float_cases.sine = ensureColumnComplexDouble(src.iq_sine_float);
signalData.float_cases.ofdm = ensureColumnComplexDouble(src.iq_ofdm_float);

signalData.fixed_cases = struct();
signalData.fixed_cases.sine = readIqHexFile(fixedFiles.sine);
signalData.fixed_cases.ofdm = readIqHexFile(fixedFiles.ofdm);
signalData.fixed_cases.debug_real = readIqHexFile(fixedFiles.debug_real);
signalData.fixed_cases.debug_imag = readIqHexFile(fixedFiles.debug_imag);
end

function testCases = buildTestCases(signalData, includeDebug)
% buildTestCases
% -------------------------------------------------------------------------
% 根据运行开关构建待验证的 IQ 信号集合。
%
% 默认包含:
%   - sine
%   - ofdm
%
% 可选附加:
%   - debug_real
%   - debug_imag
%
% 注意:
%   debug 序列的“参考输入”也来自 .txt 解析结果，而不是 .mat。
% -------------------------------------------------------------------------
testCasesCell = cell(0, 1);

testCasesCell{end + 1, 1} = makeSignalCase( ... 
    'sine', ...
    signalData.float_cases.sine, ...
    signalData.fixed_cases.sine, ...
    'normalized');

testCasesCell{end + 1, 1} = makeSignalCase( ... 
    'ofdm', ...
    signalData.float_cases.ofdm, ...
    signalData.fixed_cases.ofdm, ...
    'normalized');

if includeDebug
    % 调试序列不从 .mat 读，直接使用 .txt 解析后的 int16 数据转 double 作为参考。
    dbgRealRef = complex(double(real(signalData.fixed_cases.debug_real)), ...
        double(imag(signalData.fixed_cases.debug_real)));
    dbgImagRef = complex(double(real(signalData.fixed_cases.debug_imag)), ...
        double(imag(signalData.fixed_cases.debug_imag)));

    testCasesCell{end + 1, 1} = makeSignalCase( ... 
        'debug_real', ...
        dbgRealRef, ...
        signalData.fixed_cases.debug_real, ...
        'integer');

    testCasesCell{end + 1, 1} = makeSignalCase( ... 
        'debug_imag', ...
        dbgImagRef, ...
        signalData.fixed_cases.debug_imag, ...
        'integer');
end

testCases = vertcat(testCasesCell{:});
end

function tc = makeSignalCase(name, floatInput, fixedInput, metricMode)
% makeSignalCase
% -------------------------------------------------------------------------
% 将一个 IQ 信号样例封装成统一结构，供主流程逐项处理。
%
% 输入:
%   name       - 用例名，例如 sine / ofdm / debug_real
%   floatInput - 参考输入序列
%   fixedInput - 定点输入序列
%   metricMode - normalized 或 integer
% -------------------------------------------------------------------------
tc = struct();
tc.name = name;
tc.float_input = ensureColumnComplexDouble(floatInput);
tc.fixed_input = fixedInput(:);
tc.metric_mode = metricMode;
end

function channelSets = discoverChannelSets(channelDir)
% discoverChannelSets
% -------------------------------------------------------------------------
% 扫描 channelGen\ 下所有可用信道组。
%
% 匹配规则:
%   - 遍历所有 .mat
%   - 仅保留包含变量 H 的文件
%   - 将 *_fixedpoint.mat 归一化成信道前缀
%   - 检查同前缀 .irc / .ird 是否存在
%
% 输出:
%   channelSets(i) 为一组可直接用于仿真的信道描述结构
% -------------------------------------------------------------------------
matFiles = dir(fullfile(channelDir, '*.mat'));
channelSetsCell = cell(0, 1);

for i = 1:numel(matFiles)
    if strcmpi(matFiles(i).name, 'ChannelFixedPointTools.m')
        continue;
    end

    matPath = fullfile(matFiles(i).folder, matFiles(i).name);
    try
        info = whos('-file', matPath);
    catch
        continue;
    end
    if ~any(strcmp({info.name}, 'H'))
        continue;
    end

    [~, nameNoExt] = fileparts(matFiles(i).name);
    prefix = regexprep(nameNoExt, '_fixedpoint$', '', 'ignorecase');
    ircPath = fullfile(channelDir, [prefix, '.irc']);
    irdPath = fullfile(channelDir, [prefix, '.ird']);
    if ~isfile(ircPath) || ~isfile(irdPath)
        fprintf(2, '跳过信道 %s: 未找到对应 .irc/.ird\n', matFiles(i).name);
        continue;
    end

    s = load(matPath);
    if ~isfield(s, 'H')
        continue;
    end
    validateH(s.H, matPath);

    set = struct();
    set.prefix = prefix;
    set.mat_path = matPath;
    set.irc_path = ircPath;
    set.ird_path = irdPath;
    set.H = s.H;
    set.cir_up_rate = pickFieldScalar(s, {'cir_up_rate', 'CIR_update_rate'});
    set.IN_num = pickFieldScalar(s, {'IN_num'});
    set.OUT_num = pickFieldScalar(s, {'OUT_num'});
    set.T_num = size(s.H, 2) / 3;
    if ~isfield(s, 'T_num') || isempty(s.T_num)
        set.T_num_meta = set.T_num;
    else
        set.T_num_meta = double(s.T_num);
    end
    set.Nsamples = size(s.H, 1);
    set.Nchannel = max(1, size3(s.H));
    channelSetsCell{end + 1, 1} = set; %#ok<AGROW>
end

if isempty(channelSetsCell)
    channelSets = repmat(struct(), 0, 1);
else
    channelSets = vertcat(channelSetsCell{:});
end
end

function validateH(H, matPath)
% validateH
% -------------------------------------------------------------------------
% 检查信道矩阵 H 是否满足当前工具的基本格式要求。
%
% 要求:
%   - H 必须是数值数组
%   - 维度只能是 2D 或 3D
%   - 第二维必须是 3 的整数倍，对应 [delay, real, imag] 三元组
% -------------------------------------------------------------------------
if ~isnumeric(H)
    error('文件 %s 中的 H 不是数值数组。', matPath);
end
if ~(ismatrix(H) || ndims(H) == 3)
    error('文件 %s 中的 H 维度非法。', matPath);
end
if mod(size(H, 2), 3) ~= 0
    error('文件 %s 中的 H 第二维不是 3 的整数倍。', matPath);
end
end

function v = pickFieldScalar(s, names)
% pickFieldScalar
% -------------------------------------------------------------------------
% 在结构体 s 中按候选字段名顺序读取一个数值标量。
% 如果没有找到有效字段，则返回 NaN。
% -------------------------------------------------------------------------
v = NaN;
for i = 1:numel(names)
    if isfield(s, names{i})
        t = s.(names{i});
        if isnumeric(t) && isscalar(t)
            v = double(t);
            return;
        end
    end
end
end

function out = runSingleCase(tc, chan, fs, opts)
% runSingleCase
% -------------------------------------------------------------------------
% 对“一个 IQ 测试信号 + 一组信道文件”执行完整验证流程。
%
% 处理顺序:
%   1) 从浮点 .mat 解包出 H 的 delay/real/imag
%   2) 从 .irc/.ird 恢复定点系数与定点 delay_clk
%   3) 将 CIR update rate 映射为每个 snapshot 持续的样点数
%   4) 分别执行浮点链路与定点链路卷积
%   5) 对定点全精度累加结果搜索最佳右移位
%   6) 输出最佳 shift、宽搜索建议值及误差指标
%
% 注意:
%   - 当前阶段 clk = fs，因此 delay_clk 直接等于样值移位
%   - 正式信号与调试信号使用不同误差口径:
%       normalized -> 与浮点信号按 [-1, 1] 量纲比较
%       integer    -> 保持整数码流量纲比较
% -------------------------------------------------------------------------
floatH = unpackFloatH(chan.H);
fixedH = parseFixedChannel(chan.irc_path, chan.ird_path, chan.IN_num, chan.OUT_num, chan.T_num, chan.Nsamples);
coeffScale = estimateCoeffScale(floatH, fixedH);

if abs(fs - 245.76e6) > 1e-6
    fprintf('  fs = %.12g Hz\n', fs);
end

samplesPerSnapshot = max(1, round(fs / chan.cir_up_rate));

% 输入扩展:
% 当前样例主要是单路 IQ 输入。若未来某组信道要求 IN_num > 1，
% 则按需求文档中的容错规则将同一路输入复制到多路输入端口上。
floatInputs = expandInputs(tc.float_input, chan.IN_num);
fixedInputs = expandInputs(tc.fixed_input, chan.IN_num);

% 浮点链路:
%   直接使用 double 精度的输入和 H 做时变 FIR 参考计算。
%
% 定点链路:
%   输入来自 .txt 解析后的 int16，
%   信道来自 .irc/.ird 解析后的 int16 / delay_clk，
%   乘法与累加在 int64 中保持更高精度，直到最后一步才截位。
floatOut = simulateTimeVaryingFirDouble(floatInputs, floatH, samplesPerSnapshot);
fixedAccum = simulateTimeVaryingFirFixed(fixedInputs, fixedH, samplesPerSnapshot);

switch tc.metric_mode
    case 'normalized'
        inputScale = 32768;
    case 'integer'
        inputScale = 1;
    otherwise
        error('未知误差模式: %s', tc.metric_mode);
end
metricScale = inputScale * coeffScale;

if isnan(opts.manual_shift)
    % 正式搜索范围:
    %   按需求文档规定在 [shift_min, shift_max] 内寻找最佳 shift。
    [bestShift, fixedOutInt16, fixedOutMetric, metricInfo] = ...
        searchBestShift(fixedAccum, floatOut, tc.metric_mode, metricScale, opts.shift_min, opts.shift_max);
    % 宽搜索建议值:
    %   用更大的搜索范围给出一个“建议 shift”，帮助分析当前正式范围
    %   是否存在饱和或范围不足的问题，但不替代正式结果。
    [wideSuggestionShift, ~, ~, wideMetricInfo] = ...
        searchBestShift(fixedAccum, floatOut, tc.metric_mode, metricScale, opts.wide_shift_min, opts.wide_shift_max);
else
    bestShift = max(opts.shift_min, min(opts.shift_max, round(opts.manual_shift)));
    [fixedOutInt16, fixedOutMetric] = applyShiftToAccum(fixedAccum, bestShift, tc.metric_mode, metricScale);
    metricInfo = evaluateError(floatOut, fixedOutMetric, tc.metric_mode);
    [wideSuggestionShift, ~, ~, wideMetricInfo] = ...
        searchBestShift(fixedAccum, floatOut, tc.metric_mode, metricScale, opts.wide_shift_min, opts.wide_shift_max);
end

out = struct();
out.signal_name = tc.name;
out.channel_prefix = chan.prefix;
out.status = 'ok';
out.metric_mode = tc.metric_mode;
out.fs_hz = fs;
out.cir_update_rate_hz = chan.cir_up_rate;
out.samples_per_snapshot = samplesPerSnapshot;
out.IN_num = chan.IN_num;
out.OUT_num = chan.OUT_num;
out.T_num = chan.T_num;
out.float_length = size(floatOut, 1);
out.fixed_length = size(fixedOutInt16, 1);
out.best_shift = bestShift;
out.shift_search_range = [opts.shift_min, opts.shift_max];
out.wide_shift_suggestion = wideSuggestionShift;
out.wide_shift_search_range = [opts.wide_shift_min, opts.wide_shift_max];
out.coeff_scale = coeffScale;
out.metric_scale = metricScale;
out.mse = metricInfo.mse;
out.max_abs_error = metricInfo.max_abs_error;
out.mean_abs_error = metricInfo.mean_abs_error;
out.wide_suggestion_mse = wideMetricInfo.mse;
out.wide_suggestion_max_abs_error = wideMetricInfo.max_abs_error;
out.float_out = floatOut;
out.fixed_accum = fixedAccum;
out.fixed_out_int16 = fixedOutInt16;
out.fixed_out_metric = fixedOutMetric;
out.channel_files = struct('mat', chan.mat_path, 'irc', chan.irc_path, 'ird', chan.ird_path);
out.signal_sources = buildSignalSources(tc, opts.signal_dir);

writeCaseOutputs(out, opts.output_dir);
end

function signalSources = buildSignalSources(tc, signalDir)
% buildSignalSources
% -------------------------------------------------------------------------
% 根据当前测试信号名，构建其对应的输入文件路径记录。
% 这些路径会被写入报告，方便用户追踪数据来源。
% -------------------------------------------------------------------------
signalSources = struct();
switch tc.name
    case 'sine'
        signalSources.float_mat = fullfile(signalDir, 'fpga_test_signals.mat');
        signalSources.fixed_txt = fullfile(signalDir, 'sim_sine_iq.txt');
    case 'ofdm'
        signalSources.float_mat = fullfile(signalDir, 'fpga_test_signals.mat');
        signalSources.fixed_txt = fullfile(signalDir, 'sim_ofdm_iq.txt');
    case 'debug_real'
        signalSources.float_mat = '';
        signalSources.fixed_txt = fullfile(signalDir, 'sim_debug_real_iq.txt');
    case 'debug_imag'
        signalSources.float_mat = '';
        signalSources.fixed_txt = fullfile(signalDir, 'sim_debug_imag_iq.txt');
    otherwise
        signalSources.float_mat = '';
        signalSources.fixed_txt = '';
end
end

function packed = unpackFloatH(H)
% unpackFloatH
% -------------------------------------------------------------------------
% 从浮点 H 中拆出:
%   - delay_ns
%   - real
%   - imag
%   - coeff = real + j*imag
%   - delay_samples
%
% 当前阶段固定 clk = fs = 245.76e6，因此 delay_samples 直接由
% delay_ns 乘以采样率换算得到。
% -------------------------------------------------------------------------
packed = struct();
packed.delay_ns = extractTriplet(H, 1);
packed.real = extractTriplet(H, 2);
packed.imag = extractTriplet(H, 3);
packed.coeff = packed.real + 1i * packed.imag;
packed.delay_samples = round(packed.delay_ns * 1e-9 * 245.76e6); % 当前阶段 clk = fs = 245.76e6
end

function packed = parseFixedChannel(ircPath, irdPath, IN_num, OUT_num, T_num, Nsamples)
% parseFixedChannel
% -------------------------------------------------------------------------
% 从 .irc / .ird 文件恢复定点信道。
%
% .irc:
%   每个 32-bit 字包含一组复数系数:
%     [31:16] -> imag(int16)
%     [15:0]  -> real(int16)
%
% .ird:
%   每个 32-bit 字包含 delay 的“相邻 snapshot 增量”:
%     BIT31   -> 增减方向
%     BIT30:0 -> 幅值
%
% 恢复方式:
%   - 第 1 个 snapshot 以前一帧 delay = 0 为基准
%   - 后续 snapshot 通过逐帧累加 delta 恢复绝对 delay_clk
%
% 展开顺序必须与 ChannelFixedPointTools.m 写文件的顺序完全一致，
% 否则会出现系数、tap、channel 对齐错误。
% -------------------------------------------------------------------------
T1_num = ceil(T_num / 4) * 4;
Nchannel = IN_num * OUT_num;
expectedWords = Nsamples * Nchannel * T1_num;

ircWords = readPackedHexWords(ircPath);
irdWords = readPackedHexWords(irdPath);
if numel(ircWords) < expectedWords || numel(irdWords) < expectedWords
    error('信道文件字数不足: %s / %s', ircPath, irdPath);
end

ircWords = ircWords(1:expectedWords);
irdWords = irdWords(1:expectedWords);

qReal = zeros(Nsamples, T_num, Nchannel, 'int16');
qImag = zeros(Nsamples, T_num, Nchannel, 'int16');
delayClks = zeros(Nsamples, T_num, Nchannel, 'int64');

idx = 1;
for s = 1:Nsamples
    for m = 1:IN_num
        for n = 1:OUT_num
            ch = (m - 1) * OUT_num + n;
            for t = 1:T1_num
                wIrc = ircWords(idx);
                wIrd = irdWords(idx);
                idx = idx + 1;

                if t > T_num
                    continue;
                end

                qReal(s, t, ch) = typecast(uint16(bitand(wIrc, uint32(65535))), 'int16');
                qImag(s, t, ch) = typecast(uint16(bitshift(wIrc, -16)), 'int16');

                mag = int64(bitand(wIrd, uint32(hex2dec('7FFFFFFF'))));
                if bitget(wIrd, 32)
                    delta = -mag;
                else
                    delta = mag;
                end
                if s == 1
                    delayClks(s, t, ch) = delta;
                else
                    delayClks(s, t, ch) = delayClks(s - 1, t, ch) + delta;
                end
            end
        end
    end
end

packed = struct();
packed.qReal = qReal;
packed.qImag = qImag;
packed.delay_clks = delayClks;
packed.Nsamples = Nsamples;
packed.T_num = T_num;
packed.IN_num = IN_num;
packed.OUT_num = OUT_num;
end

function X = expandInputs(x, inNum)
% expandInputs
% -------------------------------------------------------------------------
% 当信道要求 IN_num > 1 而输入只有一路时，按容错规则将同一路输入复制
% 到多路输入端口上。
%
% 输出:
%   X 的尺寸为 [Nsamples, inNum]
% -------------------------------------------------------------------------
x = x(:);
X = zeros(numel(x), inNum, 'like', x);
for k = 1:inNum
    X(:, k) = x;
end
end

function y = simulateTimeVaryingFirDouble(inputs, H, samplesPerSnapshot)
% simulateTimeVaryingFirDouble
% -------------------------------------------------------------------------
% 时变浮点 FIR / MIMO 参考实现。
%
% 这个函数的本质是“按输出时间索引 n”进行直接求和:
%
%   y_out(n, outIdx) =
%       sum_{m=1..IN_num} sum_{t=1..T_num}
%           x_in(n - delay(snap,t,ch), m) * h(snap,t,ch)
%
% 其中:
%   - snap 由 n 所处的 snapshot 时间窗决定
%   - 同一 snapshot 时间窗内，所有 tap 系数保持不变
%   - 每个输出通道都要汇总来自所有输入通道的 FIR 结果
%
% 这里没有调用 MATLAB 的 conv()，是因为当前信道是“时变”的:
% 不同时间窗对应不同的 snapshot 系数，因此更稳妥的方式是直接按时间索引求值。
% -------------------------------------------------------------------------
inputLen = size(inputs, 1);
IN_num = size(inputs, 2);
OUT_num = size(H.coeff, 3) / IN_num;
maxDelay = max(H.delay_samples(:));
if isempty(maxDelay)
    maxDelay = 0;
end
maxDelay = double(max(maxDelay, 0));
totalLen = inputLen + maxDelay;
Nsnap = size(H.coeff, 1);
T_num = size(H.coeff, 2);

y = complex(zeros(totalLen, OUT_num));
for n = 1:totalLen
    snap = min(floor((n - 1) / samplesPerSnapshot) + 1, Nsnap);
    outRow = complex(zeros(1, OUT_num));
    for m = 1:IN_num
        for outIdx = 1:OUT_num
            ch = (m - 1) * OUT_num + outIdx;
            acc = complex(0, 0);
            for t = 1:T_num
                % delay 已经按当前阶段规则换算成样值移位。
                % srcIdx 越界时，相当于 FIR 输入补零。
                delay = double(H.delay_samples(snap, t, ch));
                srcIdx = n - delay;
                if srcIdx >= 1 && srcIdx <= inputLen
                    acc = acc + inputs(srcIdx, m) * H.coeff(snap, t, ch);
                end
            end
            outRow(outIdx) = outRow(outIdx) + acc;
        end
    end
    y(n, :) = outRow;
end
end

function accum = simulateTimeVaryingFirFixed(inputs, H, samplesPerSnapshot)
% simulateTimeVaryingFirFixed
% -------------------------------------------------------------------------
% 时变定点 FIR / MIMO 参考实现。
%
% 设计目标:
%   - 尽可能贴近 FPGA 的定点数据链路
%   - 同时避免在 MATLAB 中过早截位
%
% 精度策略:
%   1) 输入 IQ 为 int16
%   2) 信道系数 real/imag 为 int16
%   3) 单次乘法理论上是 16x16 -> 32 bit
%   4) 但多个 tap 卷积、以及多输入通道求和后，累加精度可能超过 32 bit
%   5) 因此这里统一使用 int64 做累加容器
%
% 复数乘法展开:
%   (xr + j*xi) * (cr + j*ci)
%     = (xr*cr - xi*ci) + j*(xr*ci + xi*cr)
%
% 返回值 accum 不是最终 16 bit 输出，而是“最终截位前”的全精度近似结果。
% 后续动态 shift 搜索全部基于这个 accum 进行。
% -------------------------------------------------------------------------
inputLen = size(inputs, 1);
IN_num = size(inputs, 2);
OUT_num = H.OUT_num;
maxDelay = max(H.delay_clks(:));
if isempty(maxDelay)
    maxDelay = int64(0);
end
maxDelay = double(max(maxDelay, 0));
totalLen = inputLen + maxDelay;
Nsnap = H.Nsamples;
T_num = H.T_num;

accumReal = zeros(totalLen, OUT_num, 'int64');
accumImag = zeros(totalLen, OUT_num, 'int64');

for n = 1:totalLen
    snap = min(floor((n - 1) / samplesPerSnapshot) + 1, Nsnap);
    for m = 1:IN_num
        for outIdx = 1:OUT_num
            ch = (m - 1) * OUT_num + outIdx;
            accR = int64(0);
            accI = int64(0);
            for t = 1:T_num
                delay = double(H.delay_clks(snap, t, ch));
                srcIdx = n - delay;
                if srcIdx < 1 || srcIdx > inputLen
                    continue;
                end
                xVal = inputs(srcIdx, m);
                xr = int64(real(xVal));
                xi = int64(imag(xVal));
                cr = int64(H.qReal(snap, t, ch));
                ci = int64(H.qImag(snap, t, ch));

                % 复数乘法四项展开后再累加。
                % 这里不做中途截位，避免把量化误差和位宽截断误差混在一起。
                accR = accR + (xr * cr - xi * ci);
                accI = accI + (xr * ci + xi * cr);
            end
            accumReal(n, outIdx) = accumReal(n, outIdx) + accR;
            accumImag(n, outIdx) = accumImag(n, outIdx) + accI;
        end
    end
end

accum = complex(accumReal, accumImag);
end

function [bestShift, bestInt16, bestMetric, bestInfo] = searchBestShift(accum, ref, metricMode, metricScale, shiftMin, shiftMax)
% searchBestShift
% -------------------------------------------------------------------------
% 在给定 shift 搜索范围内寻找最佳右移位数。
%
% 搜索逻辑:
%   1) 对每个候选 shift，把全精度 accum 右移 shift 位
%   2) 截位并饱和到 int16
%   3) 依据 metricScale 反标定到与参考输出一致的量纲
%   4) 计算误差指标
%   5) 以 MSE 最小为主判据；若并列，则优先 max_abs_error 更小；
%      若仍并列，则选更小的 shift
%
% 这样做的好处是:
%   - 把“乘加全精度”与“最终输出位宽约束”明确分离
%   - 用户可以直观看到不同 shift 对误差和饱和的影响
% -------------------------------------------------------------------------
bestShift = shiftMin;
bestInt16 = [];
bestMetric = [];
bestInfo = struct('mse', inf, 'max_abs_error', inf, 'mean_abs_error', inf);

for shift = shiftMin:shiftMax
    [candInt16, candMetric] = applyShiftToAccum(accum, shift, metricMode, metricScale);
    info = evaluateError(ref, candMetric, metricMode);
    if isBetterMetric(info, bestInfo, shift, bestShift)
        bestShift = shift;
        bestInt16 = candInt16;
        bestMetric = candMetric;
        bestInfo = info;
    end
end
end

function tf = isBetterMetric(info, bestInfo, shift, bestShift)
% isBetterMetric
% -------------------------------------------------------------------------
% 比较两个 shift 候选解的优劣。
%
% 优先级:
%   1) MSE 更小
%   2) 若 MSE 近似相同，则 max_abs_error 更小
%   3) 若仍相同，则取更小的 shift
% -------------------------------------------------------------------------
tol = 1e-18;
if info.mse < bestInfo.mse - tol
    tf = true;
    return;
end
if abs(info.mse - bestInfo.mse) <= tol
    if info.max_abs_error < bestInfo.max_abs_error - tol
        tf = true;
        return;
    end
    if abs(info.max_abs_error - bestInfo.max_abs_error) <= tol
        tf = shift < bestShift;
        return;
    end
end
tf = false;
end

function [outInt16, outMetric] = applyShiftToAccum(accum, shift, metricMode, metricScale)
% applyShiftToAccum
% -------------------------------------------------------------------------
% 将全精度累加结果应用指定右移位数，并生成两份结果:
%
%   outInt16:
%     真正的 16 bit 输出码流，适合导出到 .txt 或和 FPGA 原始输出比对
%
%   outMetric:
%     为误差评估而反标定后的结果，量纲与 float reference 对齐
%
% 注意:
%   右移发生在 int64 的全精度累加结果上，而不是在每个乘法或每个 tap 上。
%   这正对应需求中的“最后一步再截位”。
% -------------------------------------------------------------------------
realShifted = saturateToInt16(bitshift(real(accum), -shift));
imagShifted = saturateToInt16(bitshift(imag(accum), -shift));
outInt16 = complex(realShifted, imagShifted);
gain = 2 ^ shift;

switch metricMode
    case 'normalized'
        % normalized:
        %   反标定到接近浮点信号的归一化量纲，用于 sine / OFDM 误差比较。
        outMetric = complex( ...
            double(real(outInt16)) * gain / metricScale, ...
            double(imag(outInt16)) * gain / metricScale);
    case 'integer'
        % integer:
        %   保持原始整数码流比较口径，用于 debug 序列核对。
        outMetric = complex( ...
            double(real(outInt16)) * gain / metricScale, ...
            double(imag(outInt16)) * gain / metricScale);
    otherwise
        error('未知误差模式: %s', metricMode);
end
end

function info = evaluateError(ref, test, metricMode)
% evaluateError
% -------------------------------------------------------------------------
% 计算参考输出与测试输出之间的误差指标。
%
% 输出指标:
%   - mse
%   - max_abs_error
%   - mean_abs_error
%
% 当前比较方式统一基于复数误差幅度 abs(ref - test)。
% -------------------------------------------------------------------------
ref = ref(:);
test = test(:);
if numel(ref) ~= numel(test)
    error('比较长度不一致。');
end

switch metricMode
    case {'normalized', 'integer'}
        diffVal = abs(ref - test);
    otherwise
        error('未知误差模式: %s', metricMode);
end

info = struct();
info.mse = mean(diffVal .^ 2);
info.max_abs_error = max(diffVal);
info.mean_abs_error = mean(diffVal);
end

function writeCaseOutputs(caseResult, outputDir)
% writeCaseOutputs
% -------------------------------------------------------------------------
% 为每个测试组合写出:
%   1) MAT 结果文件
%   2) 文本报告
%   3) 定点输出 IQ 文本
%   4) 浮点输出文本
%   5) 浮点/定点输出频域图
%
% 频域图部分用于人工检查:
%   - 主瓣位置是否一致
%   - 带宽是否一致
%   - 定点化后杂散与底噪是否明显恶化
% -------------------------------------------------------------------------
base = sprintf('%s__%s', caseResult.signal_name, caseResult.channel_prefix);
matPath = fullfile(outputDir, [base, '.mat']);
reportPath = fullfile(outputDir, [base, '_report.txt']);

float_out = caseResult.float_out; 
fixed_accum = caseResult.fixed_accum; 
fixed_out_int16 = caseResult.fixed_out_int16; 
fixed_out_metric = caseResult.fixed_out_metric; 
summary = rmfield(caseResult, {'float_out', 'fixed_accum', 'fixed_out_int16', 'fixed_out_metric'}); 
save(matPath, 'summary', 'float_out', 'fixed_accum', 'fixed_out_int16', 'fixed_out_metric', '-v7.3');

fid = fopen(reportPath, 'w', 'n', 'UTF-8');
if fid < 0
    error('无法写入报告文件: %s', reportPath);
end
cleanupObj = onCleanup(@() fclose(fid)); 

fprintf(fid, 'Signal name          : %s\n', caseResult.signal_name);
fprintf(fid, 'Channel prefix       : %s\n', caseResult.channel_prefix);
fprintf(fid, 'Metric mode          : %s\n', caseResult.metric_mode);
fprintf(fid, 'fs (Hz)              : %.12g\n', caseResult.fs_hz);
fprintf(fid, 'CIR update rate (Hz) : %.12g\n', caseResult.cir_update_rate_hz);
fprintf(fid, 'Samples/snapshot     : %d\n', caseResult.samples_per_snapshot);
fprintf(fid, 'IN_num               : %d\n', caseResult.IN_num);
fprintf(fid, 'OUT_num              : %d\n', caseResult.OUT_num);
fprintf(fid, 'T_num                : %d\n', caseResult.T_num);
fprintf(fid, 'Best shift           : %d\n', caseResult.best_shift);
fprintf(fid, 'Shift search range   : [%d, %d]\n', caseResult.shift_search_range(1), caseResult.shift_search_range(2));
fprintf(fid, 'Wide shift suggestion: %d\n', caseResult.wide_shift_suggestion);
fprintf(fid, 'Wide search range    : [%d, %d]\n', caseResult.wide_shift_search_range(1), caseResult.wide_shift_search_range(2));
fprintf(fid, 'MSE                  : %.12e\n', caseResult.mse);
fprintf(fid, 'Mean abs error       : %.12e\n', caseResult.mean_abs_error);
fprintf(fid, 'Max abs error        : %.12e\n', caseResult.max_abs_error);
fprintf(fid, 'Wide suggestion MSE  : %.12e\n', caseResult.wide_suggestion_mse);
fprintf(fid, 'Wide suggestion MaxE : %.12e\n', caseResult.wide_suggestion_max_abs_error);
fprintf(fid, 'Float source         : %s\n', caseResult.signal_sources.float_mat);
fprintf(fid, 'Fixed IQ source      : %s\n', caseResult.signal_sources.fixed_txt);
fprintf(fid, 'Channel MAT          : %s\n', caseResult.channel_files.mat);
fprintf(fid, 'Channel IRC          : %s\n', caseResult.channel_files.irc);
fprintf(fid, 'Channel IRD          : %s\n', caseResult.channel_files.ird);

for outIdx = 1:caseResult.OUT_num
    hexPath = fullfile(outputDir, sprintf('%s_fixed_out_ch%02d.txt', base, outIdx));
    floatTxtPath = fullfile(outputDir, sprintf('%s_float_out_ch%02d.txt', base, outIdx));
    spectrumPath = fullfile(outputDir, sprintf('%s_spectrum_ch%02d.png', base, outIdx));
    writeIqHexFile(caseResult.fixed_out_int16(:, outIdx), hexPath);
    writeComplexText(caseResult.float_out(:, outIdx), floatTxtPath);
    writeSpectrumFigure(caseResult, outIdx, outputDir, base);
    fprintf(fid, 'Fixed OUT TXT ch%02d   : %s\n', outIdx, hexPath);
    fprintf(fid, 'Float OUT TXT ch%02d   : %s\n', outIdx, floatTxtPath);
    fprintf(fid, 'Spectrum PNG ch%02d    : %s\n', outIdx, spectrumPath);
end
end

function printCaseSummary(caseResult)
% printCaseSummary
% -------------------------------------------------------------------------
% 在命令行中打印单个 case 的关键摘要，便于批量运行时快速浏览。
% -------------------------------------------------------------------------
fprintf('  shift=%d, wideSuggest=%d, mse=%.6e, meanAbs=%.6e, maxAbs=%.6e\n', ...
    caseResult.best_shift, caseResult.wide_shift_suggestion, ...
    caseResult.mse, caseResult.mean_abs_error, caseResult.max_abs_error);
end

function x = ensureColumnComplexDouble(x)
% ensureColumnComplexDouble
% -------------------------------------------------------------------------
% 将输入统一转换为“列向量 complex double”。
%
% 作用:
%   - 保证后续卷积实现不需要处理行向量/列向量差异
%   - 保证浮点链路输入类型统一
% -------------------------------------------------------------------------
x = x(:);
if ~isa(x, 'double')
    x = double(x);
end
if ~isreal(x)
    return;
end
x = complex(x, zeros(size(x)));
end

function data = readIqHexFile(pathName)
% readIqHexFile
% -------------------------------------------------------------------------
% 读取 IQ 十六进制文本文件，并恢复为 complex(int16) 列向量。
%
% 每个 32-bit 字的格式为:
%   [31:16] -> Q / imag
%   [15:0]  -> I / real
% -------------------------------------------------------------------------
words = readPackedHexWords(pathName);
re = zeros(numel(words), 1, 'int16');
im = zeros(numel(words), 1, 'int16');
for i = 1:numel(words)
    re(i) = typecast(uint16(bitand(words(i), uint32(65535))), 'int16');
    im(i) = typecast(uint16(bitshift(words(i), -16)), 'int16');
end
data = complex(re, im);
end

function words = readPackedHexWords(pathName)
% readPackedHexWords
% -------------------------------------------------------------------------
% 从文本中提取所有 32-bit 十六进制字。
%
% 处理方式:
%   - 去掉所有空白字符
%   - 每 8 个十六进制字符解析为一个 uint32
% -------------------------------------------------------------------------
txt = fileread(pathName);
txt = regexprep(txt, '\s+', '');
if mod(numel(txt), 8) ~= 0
    error('文件 %s 的十六进制长度不是 8 的整数倍。', pathName);
end
numWords = numel(txt) / 8;
words = zeros(numWords, 1, 'uint32');
for i = 1:numWords
    idx = (i - 1) * 8 + (1:8);
    words(i) = uint32(hex2dec(txt(idx)));
end
end

function writeIqHexFile(iqData, pathName)
% writeIqHexFile
% -------------------------------------------------------------------------
% 将 complex(int16) 输出序列写回 IQ 十六进制文本格式。
% 输出格式与 signalGen\ 中的输入 IQ 文本保持一致。
% -------------------------------------------------------------------------
fid = fopen(pathName, 'w', 'n', 'UTF-8');
if fid < 0
    error('无法写入文件: %s', pathName);
end
cleanupObj = onCleanup(@() fclose(fid)); 

for k = 1:numel(iqData)
    iVal = typecast(int16(real(iqData(k))), 'uint16');
    qVal = typecast(int16(imag(iqData(k))), 'uint16');
    fprintf(fid, '%04X%04X\n', qVal, iVal);
end
end

function writeComplexText(x, pathName)
% writeComplexText
% -------------------------------------------------------------------------
% 将复数序列以“实部 虚部”两列文本的方式写到文件，便于人工查看
% 或其他脚本工具读取。
% -------------------------------------------------------------------------
fid = fopen(pathName, 'w', 'n', 'UTF-8');
if fid < 0
    error('无法写入文件: %s', pathName);
end
cleanupObj = onCleanup(@() fclose(fid)); 

for k = 1:numel(x)
    fprintf(fid, '%.12e %.12e\n', real(x(k)), imag(x(k)));
end
end

function y = saturateToInt16(x)
% saturateToInt16
% -------------------------------------------------------------------------
% 对整数数组执行 int16 饱和裁剪。
%
% 作用:
%   在最终输出阶段模拟 FPGA 输出位宽限制，超出 [-32768, 32767]
%   的值直接钳位。
% -------------------------------------------------------------------------
x = min(max(x, int64(-32768)), int64(32767));
y = int16(x);
end

function writeSpectrumFigure(caseResult, outIdx, outputDir, base)
% writeSpectrumFigure
% -------------------------------------------------------------------------
% 分别绘制定点输出和浮点输出的频域图。
%
% 图中采用上下两个子图:
%   - 上图: float output spectrum
%   - 下图: fixed output spectrum
%
% 这里使用最基础的 FFT 计算归一化频谱，避免引入额外工具箱依赖。
% 对于定点输出:
%   - 使用 fixed_out_metric 作为频域绘图输入
%   - 这样量纲与当前误差分析口径保持一致
% -------------------------------------------------------------------------
floatSig = caseResult.float_out(:, outIdx);
fixedSig = caseResult.fixed_out_metric(:, outIdx);

[freqFloatMHz, specFloatDb] = computeSpectrumDb(floatSig, caseResult.fs_hz);
[freqFixedMHz, specFixedDb] = computeSpectrumDb(fixedSig, caseResult.fs_hz);

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100, 100, 1000, 700]);

subplot(2, 1, 1);
plot(freqFloatMHz, specFloatDb, 'b', 'LineWidth', 1.1);
grid on;
xlabel('Frequency (MHz)');
ylabel('Norm PSD (dB)');
title(sprintf('Float Output Spectrum: %s / ch%02d', strrep(base, '_', '\_'), outIdx));

subplot(2, 1, 2);
plot(freqFixedMHz, specFixedDb, 'r', 'LineWidth', 1.1);
grid on;
xlabel('Frequency (MHz)');
ylabel('Norm PSD (dB)');
title(sprintf('Fixed Output Spectrum: %s / ch%02d', strrep(base, '_', '\_'), outIdx));

pngPath = fullfile(outputDir, sprintf('%s_spectrum_ch%02d.png', base, outIdx));
saveas(fig, pngPath);
close(fig);
end

function [freqMHz, specDb] = computeSpectrumDb(x, fs)
% computeSpectrumDb
% -------------------------------------------------------------------------
% 计算一个复数输出序列的归一化频谱。
%
% 实现说明:
%   1) 取前 N 个样点做 FFT，N 取不超过 65536 的 2 次幂
%   2) 频谱做 fftshift，得到 [-fs/2, fs/2) 频轴
%   3) 功率归一化到最大值 0 dB，便于比较浮点与定点结果
% -------------------------------------------------------------------------
x = x(:);
n = min(numel(x), 65536);
nfft = 2 ^ nextpow2(max(n, 1));
x = x(1:n);
if numel(x) < nfft
    x = [x; zeros(nfft - numel(x), 1)];
end

X = fftshift(fft(x, nfft));
powerVal = abs(X) .^ 2;
powerVal = powerVal / max(max(powerVal), eps);
specDb = 10 * log10(max(powerVal, 1e-12));
freqAxis = ((-nfft/2):(nfft/2 - 1)).' / nfft * fs;
freqMHz = freqAxis / 1e6;
end

function scale = estimateCoeffScale(floatH, fixedH)
% estimateCoeffScale
% -------------------------------------------------------------------------
% 估计浮点系数与定点系数之间的量化缩放因子。
%
% 背景:
%   当前信道定点化并不是简单的 Q15，而是按一组单独的 scale 量化。
%   为了把定点链路结果正确反标定到浮点量纲，需要估计这个 scale。
%
% 方法:
%   对非零浮点系数做最小二乘意义下的比例拟合。
% -------------------------------------------------------------------------
floatVals = [real(floatH.coeff(:)); imag(floatH.coeff(:))];
fixedVals = [double(fixedH.qReal(:)); double(fixedH.qImag(:))];
mask = abs(floatVals) > 1e-12;
if ~any(mask)
    scale = 1;
    return;
end
num = floatVals(mask)' * fixedVals(mask);
den = floatVals(mask)' * floatVals(mask);
if den <= 0
    scale = 1;
else
    scale = num / den;
end
if ~(isfinite(scale) && scale > 0)
    scale = 1;
end
end

function X = extractTriplet(H, pos)
% extractTriplet
% -------------------------------------------------------------------------
% 从 H 的 [delay, real, imag] 三元组布局中提取指定分量。
%
% pos:
%   1 -> delay
%   2 -> real
%   3 -> imag
%
% 输出统一为 3D 形式:
%   [Nsamples, T_num, Nchannel]
% -------------------------------------------------------------------------
if ismatrix(H)
    X = zeros(size(H, 1), size(H, 2) / 3, 1);
    X(:, :, 1) = H(:, pos:3:end);
else
    X = zeros(size(H, 1), size(H, 2) / 3, size(H, 3));
    for ch = 1:size(H, 3)
        X(:, :, ch) = H(:, pos:3:end, ch);
    end
end
end

function n = size3(x)
% size3
% -------------------------------------------------------------------------
% 安全获取数组第三维大小。
% 对 2D 数组返回 1。
% -------------------------------------------------------------------------
if ndims(x) < 3
    n = 1;
else
    n = size(x, 3);
end
end

function ensureDir(pathName)
% ensureDir
% -------------------------------------------------------------------------
% 若目录不存在则创建。
% -------------------------------------------------------------------------
if ~isfolder(pathName)
    mkdir(pathName);
end
end
