%% demo_generateTestData.m — Generate synthetic wafer trace data for testing.
%
% Creates realistic .mat files with multiple test types:
%   - Standard expose test (load → align → expose → unload)
%   - Thermal conditioning test (load → thermal_soak → expose → unload)
%   - Calibration test (load → calibration_scan → unload)
%
% Usage:
%   demo_generateTestData()                                    % standard expose
%   demo_generateTestData('testType', 'thermal_conditioning')
%   demo_generateTestData('testType', 'calibration')
%   demo_generateTestData('nWafers', 10)
%   demo_generateTestData('outputFile', 'my_test.mat')

function demo_generateTestData(varargin)
    p = inputParser;
    addParameter(p, 'nWafers', 5, @isnumeric);
    addParameter(p, 'outputFile', '', @ischar);
    addParameter(p, 'sampleRate', 100, @isnumeric);
    addParameter(p, 'nFields', 20, @isnumeric);
    addParameter(p, 'nTempSensors', 4, @isnumeric);
    addParameter(p, 'nHeaters', 3, @isnumeric);
    addParameter(p, 'testType', 'standard_expose', @ischar);
    parse(p, varargin{:});
    opts = p.Results;

    if isempty(opts.outputFile)
        opts.outputFile = sprintf('demo_%s.mat', opts.testType);
    end

    fs = opts.sampleRate;
    nWafers = opts.nWafers;

    fprintf('Generating "%s" test: %d wafers...\n', opts.testType, nWafers);

    switch opts.testType
        case 'standard_expose'
            [t, signals] = generateStandardExpose(fs, nWafers, opts);
        case 'thermal_conditioning'
            [t, signals] = generateThermalConditioning(fs, nWafers, opts);
        case 'calibration'
            [t, signals] = generateCalibration(fs, nWafers, opts);
        otherwise
            error('Unknown test type: %s', opts.testType);
    end

    % Save to .mat
    trace_time = t; %#ok<NASGU>
    chuck_x_pos = signals.chuck_x; %#ok<NASGU>
    chuck_y_pos = signals.chuck_y; %#ok<NASGU>
    clamping_pressure = signals.clamp_pressure; %#ok<NASGU>
    epin_z_height = signals.epin_z; %#ok<NASGU>
    wt_temp_sensor1 = signals.temps(:,1); %#ok<NASGU>
    wt_temp_sensor2 = signals.temps(:,2); %#ok<NASGU>
    wt_temp_sensor3 = signals.temps(:,3); %#ok<NASGU>
    wt_temp_sensor4 = signals.temps(:,4); %#ok<NASGU>
    heater_pwr1 = signals.heaters(:,1); %#ok<NASGU>
    heater_pwr2 = signals.heaters(:,2); %#ok<NASGU>
    heater_pwr3 = signals.heaters(:,3); %#ok<NASGU>

    outFile = fullfile(fileparts(mfilename('fullpath')), opts.outputFile);
    save(outFile, 'trace_time', 'chuck_x_pos', 'chuck_y_pos', ...
        'clamping_pressure', 'epin_z_height', ...
        'wt_temp_sensor1', 'wt_temp_sensor2', ...
        'wt_temp_sensor3', 'wt_temp_sensor4', ...
        'heater_pwr1', 'heater_pwr2', 'heater_pwr3', '-v7.3');

    fprintf('Saved to: %s\n', outFile);
end

%% ================================================================
%  TEST TYPE GENERATORS
%  ================================================================

function [t, signals] = generateStandardExpose(fs, nWafers, opts)
    loadDur = 3; alignDur = 6; unloadDur = 2; gap = 4;
    exposeDur = opts.nFields * 0.8;
    waferDur = loadDur + alignDur + exposeDur + unloadDur;
    totalDur = nWafers * (waferDur + gap);
    t = (0:1/fs:totalDur)';
    N = numel(t);
    signals = initSignals(N, opts);
    thermalDrift = 0;

    for w = 1:nWafers
        tW = (w-1) * (waferDur + gap);
        thermalDrift = thermalDrift + 0.02;
        signals = applyLoad(signals, t, fs, tW, loadDur, thermalDrift, opts);
        signals = applyAlign(signals, t, fs, tW + loadDur, alignDur, thermalDrift, opts);
        signals = applyExpose(signals, t, fs, tW + loadDur + alignDur, exposeDur, opts.nFields, thermalDrift, opts);
        signals = applyUnload(signals, t, fs, tW + loadDur + alignDur + exposeDur, unloadDur, thermalDrift, opts);
        fprintf('  Wafer %d: t=[%.1f-%.1f]s (load->align->expose->unload)\n', w, tW, tW + waferDur);
    end
end

function [t, signals] = generateThermalConditioning(fs, nWafers, opts)
    loadDur = 3; soakDur = 15; unloadDur = 2; gap = 5;
    exposeDur = opts.nFields * 0.8;
    waferDur = loadDur + soakDur + exposeDur + unloadDur;
    totalDur = nWafers * (waferDur + gap);
    t = (0:1/fs:totalDur)';
    N = numel(t);
    signals = initSignals(N, opts);
    thermalDrift = 0;

    for w = 1:nWafers
        tW = (w-1) * (waferDur + gap);
        thermalDrift = thermalDrift + 0.015;
        signals = applyLoad(signals, t, fs, tW, loadDur, thermalDrift, opts);
        signals = applyThermalSoak(signals, t, fs, tW + loadDur, soakDur, thermalDrift, opts);
        signals = applyExpose(signals, t, fs, tW + loadDur + soakDur, exposeDur, opts.nFields, thermalDrift, opts);
        signals = applyUnload(signals, t, fs, tW + loadDur + soakDur + exposeDur, unloadDur, thermalDrift, opts);
        fprintf('  Wafer %d: t=[%.1f-%.1f]s (load->thermal_soak->expose->unload)\n', w, tW, tW + waferDur);
    end
end

function [t, signals] = generateCalibration(fs, nWafers, opts)
    loadDur = 3; scanDur = 20; unloadDur = 2; gap = 4;
    waferDur = loadDur + scanDur + unloadDur;
    totalDur = nWafers * (waferDur + gap);
    t = (0:1/fs:totalDur)';
    N = numel(t);
    signals = initSignals(N, opts);
    thermalDrift = 0;

    for w = 1:nWafers
        tW = (w-1) * (waferDur + gap);
        thermalDrift = thermalDrift + 0.01;
        signals = applyLoad(signals, t, fs, tW, loadDur, thermalDrift, opts);
        signals = applyCalibrationScan(signals, t, fs, tW + loadDur, scanDur, thermalDrift, opts);
        signals = applyUnload(signals, t, fs, tW + loadDur + scanDur, unloadDur, thermalDrift, opts);
        fprintf('  Wafer %d: t=[%.1f-%.1f]s (load->calibration_scan->unload)\n', w, tW, tW + waferDur);
    end
end

%% ================================================================
%  SIGNAL GENERATION HELPERS
%  ================================================================

function signals = initSignals(N, opts)
    signals.chuck_x = zeros(N, 1);
    signals.chuck_y = zeros(N, 1);
    signals.clamp_pressure = zeros(N, 1);
    signals.epin_z = ones(N, 1) * 5;
    baseTemps = 22 + rand(1, opts.nTempSensors) * 0.5;
    signals.temps = repmat(baseTemps, N, 1);
    signals.heaters = zeros(N, opts.nHeaters);
    signals.baseTemps = baseTemps;
end

function signals = applyLoad(signals, t, fs, tStart, duration, drift, opts)
    iS = max(1, round(tStart * fs) + 1);
    iE = min(numel(t), round((tStart + duration) * fs));
    ramp = round(0.5 * fs);
    for i = iS:min(iS + ramp - 1, numel(t))
        frac = (i - iS) / ramp;
        signals.clamp_pressure(i) = frac * 3;
        signals.epin_z(i) = 5 - 4.5 * frac;
    end
    signals.clamp_pressure(min(iS+ramp, numel(t)):iE) = 3;
    signals.epin_z(min(iS+ramp, numel(t)):iE) = 0.5;
    for i = iS:iE
        tRel = (i - iS) / fs;
        for s = 1:opts.nTempSensors
            signals.temps(i, s) = signals.baseTemps(s) + drift + ...
                -0.3 * (1 + 0.2*s) * exp(-tRel / (1 + 0.5*s)) + 0.005 * randn;
        end
        for h = 1:opts.nHeaters
            signals.heaters(i, h) = 2 * exp(-tRel / 2) + 0.5 + 0.02 * randn;
        end
    end
end

function signals = applyAlign(signals, t, fs, tStart, duration, drift, opts)
    iS = max(1, round(tStart * fs) + 1);
    iE = min(numel(t), round((tStart + duration) * fs));
    signals.clamp_pressure(iS:iE) = 3;
    signals.epin_z(iS:iE) = 0.5;
    nMoves = 4;
    for m = 1:nMoves
        mS = iS + round((m-1) * duration * fs / nMoves);
        mE = min(mS + round(0.3 * fs), numel(t));
        for i = mS:mE
            signals.chuck_x(i) = 100 * sin(2*pi*(i-mS)/(mE-mS+1));
            signals.chuck_y(i) = 50 * cos(2*pi*(i-mS)/(mE-mS+1));
        end
    end
    for i = iS:iE
        tRel = (i - iS) / fs;
        for s = 1:opts.nTempSensors
            signals.temps(i, s) = signals.baseTemps(s) + drift - 0.05 * exp(-tRel / (3 + s)) + 0.005 * randn;
        end
        for h = 1:opts.nHeaters
            signals.heaters(i, h) = 0.5 + 0.05 * randn;
        end
    end
end

function signals = applyExpose(signals, t, fs, tStart, duration, nFields, drift, opts)
    iS = max(1, round(tStart * fs) + 1);
    iE = min(numel(t), round((tStart + duration) * fs));
    signals.clamp_pressure(iS:iE) = 3;
    signals.epin_z(iS:iE) = 0.5;
    grid = generateFieldGrid(nFields);
    fieldTime = duration / nFields;
    stepTime = fieldTime * 0.4;
    for f = 1:nFields
        fStart = iS + round((f-1) * fieldTime * fs);
        fStep = min(fStart + round(stepTime * fs), numel(t));
        fEnd = min(fStart + round(fieldTime * fs), numel(t));
        targetX = grid(f, 1) * 1000;
        targetY = grid(f, 2) * 1000;
        prevX = signals.chuck_x(max(fStart-1, 1));
        prevY = signals.chuck_y(max(fStart-1, 1));
        for i = fStart:min(fStep, numel(t))
            frac = (i - fStart) / max(fStep - fStart, 1);
            sc = 3*frac^2 - 2*frac^3;
            signals.chuck_x(i) = prevX + (targetX - prevX) * sc;
            signals.chuck_y(i) = prevY + (targetY - prevY) * sc;
        end
        for i = min(fStep+1, numel(t)):min(fEnd, numel(t))
            signals.chuck_x(i) = targetX + 0.01 * randn;
            signals.chuck_y(i) = targetY + 0.01 * randn;
        end
    end
    for i = iS:iE
        tRel = (i - iS) / fs;
        for s = 1:opts.nTempSensors
            signals.temps(i, s) = signals.baseTemps(s) + drift + 0.01 * tRel / max(duration, 1) + 0.003 * randn;
        end
        for h = 1:opts.nHeaters
            signals.heaters(i, h) = 0.3 + 0.05 * sin(2*pi*tRel/10) + 0.02 * randn;
        end
    end
end

function signals = applyUnload(signals, t, fs, tStart, duration, drift, opts)
    iS = max(1, round(tStart * fs) + 1);
    iE = min(numel(t), round((tStart + duration) * fs));
    ramp = round(0.5 * fs);
    for i = iS:min(iS + ramp - 1, numel(t))
        frac = (i - iS) / ramp;
        signals.clamp_pressure(i) = 3 * (1 - frac);
        signals.epin_z(i) = 0.5 + 4.5 * frac;
    end
    signals.epin_z(min(iS+ramp, numel(t)):iE) = 5;
    for i = iS:iE
        tRel = (i - iS) / fs;
        for s = 1:opts.nTempSensors
            signals.temps(i, s) = signals.baseTemps(s) + drift + 0.1 * exp(-tRel) + 0.005 * randn;
        end
        for h = 1:opts.nHeaters
            signals.heaters(i, h) = 1.0 * exp(-tRel) + 0.02 * randn;
        end
    end
end

function signals = applyThermalSoak(signals, t, fs, tStart, duration, drift, opts)
    iS = max(1, round(tStart * fs) + 1);
    iE = min(numel(t), round((tStart + duration) * fs));
    signals.clamp_pressure(iS:iE) = 3;
    signals.epin_z(iS:iE) = 0.5;
    for i = iS:iE
        tRel = (i - iS) / fs;
        for s = 1:opts.nTempSensors
            setpoint = signals.baseTemps(s) + drift + 0.5;
            signals.temps(i, s) = setpoint - 0.5 * exp(-tRel / (3 + s*0.5)) + 0.003 * randn;
        end
        for h = 1:opts.nHeaters
            signals.heaters(i, h) = 3.0 * exp(-tRel / 5) + 0.2 + 0.03 * randn;
        end
    end
end

function signals = applyCalibrationScan(signals, t, fs, tStart, duration, drift, opts)
    iS = max(1, round(tStart * fs) + 1);
    iE = min(numel(t), round((tStart + duration) * fs));
    signals.clamp_pressure(iS:iE) = 3;
    signals.epin_z(iS:iE) = 0.5;
    for i = iS:iE
        tRel = (i - iS) / fs;
        signals.chuck_x(i) = 5000 * sin(2*pi*tRel / 4);
        signals.chuck_y(i) = 3000 * cos(2*pi*tRel / 6);
        for s = 1:opts.nTempSensors
            signals.temps(i, s) = signals.baseTemps(s) + drift + 0.1 * sin(2*pi*tRel / 8) + 0.005 * randn;
        end
        for h = 1:opts.nHeaters
            signals.heaters(i, h) = 1.0 + 0.8 * sin(2*pi*tRel / (3 + h)) + 0.03 * randn;
        end
    end
end

function grid = generateFieldGrid(nFields)
    nCols = ceil(sqrt(nFields));
    nRows = ceil(nFields / nCols);
    pitchX = 26; pitchY = 33;
    grid = zeros(nFields, 2);
    idx = 0;
    for row = 1:nRows
        for col = 1:nCols
            idx = idx + 1;
            if idx > nFields, break; end
            if mod(row, 2) == 1
                grid(idx, 1) = (col - (nCols+1)/2) * pitchX;
            else
                grid(idx, 1) = ((nCols+1-col) - (nCols+1)/2) * pitchX;
            end
            grid(idx, 2) = (row - (nRows+1)/2) * pitchY;
        end
    end
end
