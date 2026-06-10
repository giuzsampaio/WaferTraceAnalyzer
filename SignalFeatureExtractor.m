classdef SignalFeatureExtractor < handle
    % SignalFeatureExtractor — Compute per-signal features at every time step.
    %
    % Takes discovered signals and produces a feature matrix where each row
    % is a time step and each column is a feature (3 per signal: level,
    % activity, derivative_sign). All signals are resampled to a common
    % time base first.
    %
    % Usage:
    %   fe = SignalFeatureExtractor(signals, config);
    %   fe.extract();
    %   F = fe.featureMatrix;   % [N_samples x N_features]
    %   t = fe.commonTime;      % [N_samples x 1]

    properties
        signals         struct      % Input signals (from WaferTraceAnalyzer)
        config          struct      % Configuration
        commonTime      double      % Common resampled time vector
        commonFs        double      % Common sample rate (Hz)
        resampledData   struct      % Signals resampled to common time base
        featureMatrix   double      % [N_samples x N_features]
        featureNames    cell        % Names for each feature column
        categoryMap     struct      % Maps feature column indices to signal categories
    end

    methods
        function obj = SignalFeatureExtractor(signals, config)
            if nargin < 2, config = struct(); end
            obj.signals = signals;
            obj.config = obj.buildConfig(config);
        end

        function extract(obj)
            % Main method: resample signals, compute features.

            obj.resampleToCommonTime();
            obj.computeFeatures();
        end

        function features = extractForSegment(obj, tStart, tEnd)
            % Extract mean feature values for a specific time segment.
            % Returns a struct with per-category features (for fingerprinting).

            mask = obj.commonTime >= tStart & obj.commonTime <= tEnd;
            if ~any(mask)
                features = struct();
                return;
            end

            F = obj.featureMatrix(mask, :);
            t = obj.commonTime(mask);

            categories = unique({obj.signals.category});
            features = struct();

            for c = 1:numel(categories)
                cat = categories{c};
                if strcmp(cat, 'unknown'), continue; end
                catValid = matlab.lang.makeValidName(cat);

                % Find feature columns for this category
                catSigs = obj.signals(strcmp({obj.signals.category}, cat));
                if isempty(catSigs), continue; end

                % Collect level, activity, deriv features for this category
                levels = [];
                activities = [];
                derivs = [];

                for s = 1:numel(catSigs)
                    sigName = matlab.lang.makeValidName(catSigs(s).name);
                    levelCol = find(strcmp(obj.featureNames, [sigName '_level']), 1);
                    actCol = find(strcmp(obj.featureNames, [sigName '_activity']), 1);
                    derivCol = find(strcmp(obj.featureNames, [sigName '_deriv']), 1);

                    if ~isempty(levelCol)
                        levels(:, end+1) = F(:, levelCol); %#ok<AGROW>
                    end
                    if ~isempty(actCol)
                        activities(:, end+1) = F(:, actCol); %#ok<AGROW>
                    end
                    if ~isempty(derivCol)
                        derivs(:, end+1) = F(:, derivCol); %#ok<AGROW>
                    end
                end

                if isempty(levels), continue; end

                % Aggregate across signals in this category
                feat = struct();
                feat.level = mean(mean(levels, 1, 'omitnan'), 'omitnan');
                feat.activity = mean(mean(activities, 1, 'omitnan'), 'omitnan');

                % Trend: linear fit on mean level over the segment
                meanLevel = mean(levels, 2, 'omitnan');
                if numel(t) > 2
                    tNorm = t - t(1);
                    pfit = polyfit(tNorm, meanLevel, 1);
                    slope = pfit(1) * (t(end) - t(1)); % total change over segment
                    feat.trend = max(-1, min(1, slope)); % clamp to [-1, 1]
                else
                    feat.trend = 0;
                end

                % Variability: coefficient of variation of the mean level
                if abs(mean(meanLevel, 'omitnan')) > 1e-9
                    feat.variability = min(1, std(meanLevel, 'omitnan') / abs(mean(meanLevel, 'omitnan')));
                else
                    feat.variability = 0;
                end

                % Shape detection
                feat.shape = obj.detectShape(t, meanLevel);

                features.(catValid) = feat;
            end
        end
    end

    methods (Access = private)
        function cfg = buildConfig(~, userConfig)
            cfg.minSampleRate = 10;     % Hz — floor for common time base
            cfg.levelWindow = 1.0;      % seconds
            cfg.activityWindow = 0.5;   % seconds
            cfg.derivWindow = 1.0;      % seconds
            cfg.maxSignalsPerCategory = 5; % Limit for performance

            if ~isempty(fieldnames(userConfig))
                fns = fieldnames(userConfig);
                for i = 1:numel(fns)
                    cfg.(fns{i}) = userConfig.(fns{i});
                end
            end
        end

        function resampleToCommonTime(obj)
            % Determine common time base and resample all signals.

            % Find common time range and minimum sample rate
            tMin = -inf;
            tMax = inf;
            minFs = inf;

            for i = 1:numel(obj.signals)
                if isempty(obj.signals(i).time), continue; end
                tMin = max(tMin, obj.signals(i).time(1));
                tMax = min(tMax, obj.signals(i).time(end));
                if obj.signals(i).sampleRate > 0
                    minFs = min(minFs, obj.signals(i).sampleRate);
                end
            end

            if isinf(tMin) || isinf(tMax) || tMin >= tMax
                obj.commonTime = [];
                obj.commonFs = 0;
                return;
            end

            % Use minimum sample rate, but at least minSampleRate Hz
            obj.commonFs = max(minFs, obj.config.minSampleRate);
            % Cap at 100 Hz to avoid excessive computation
            obj.commonFs = min(obj.commonFs, 100);
            obj.commonTime = (tMin:(1/obj.commonFs):tMax)';

            % Resample each signal
            obj.resampledData = struct('name', {}, 'category', {}, 'data', {});
            for i = 1:numel(obj.signals)
                sig = obj.signals(i);
                if isempty(sig.time) || numel(sig.data) < 2
                    continue;
                end

                rd = struct();
                rd.name = sig.name;
                rd.category = sig.category;

                % Interpolate to common time
                rd.data = interp1(sig.time, sig.data, obj.commonTime, 'linear', 'extrap');

                obj.resampledData(end+1) = rd;
            end
        end

        function computeFeatures(obj)
            % Compute 3 features per signal: level, activity, derivative_sign.

            N = numel(obj.commonTime);
            if N == 0
                obj.featureMatrix = [];
                obj.featureNames = {};
                return;
            end

            nSigs = numel(obj.resampledData);
            obj.featureMatrix = zeros(N, nSigs * 3);
            obj.featureNames = cell(1, nSigs * 3);

            levelWin = max(1, round(obj.config.levelWindow * obj.commonFs));
            actWin = max(1, round(obj.config.activityWindow * obj.commonFs));
            derivWin = max(1, round(obj.config.derivWindow * obj.commonFs));

            for s = 1:nSigs
                d = obj.resampledData(s).data;
                sigName = matlab.lang.makeValidName(obj.resampledData(s).name);

                % Global min/max for normalization
                dMin = min(d);
                dMax = max(d);
                dRange = dMax - dMin;
                if dRange == 0, dRange = 1; end

                % Feature 1: normalized_level (moving mean, normalized)
                col1 = (s-1)*3 + 1;
                levelSmooth = movmean(d, levelWin);
                obj.featureMatrix(:, col1) = (levelSmooth - dMin) / dRange;
                obj.featureNames{col1} = [sigName '_level'];

                % Feature 2: activity (moving std of diff, normalized)
                col2 = (s-1)*3 + 2;
                dDiff = [0; diff(d)];
                actSmooth = movstd(dDiff, actWin);
                actMax = max(actSmooth);
                if actMax == 0, actMax = 1; end
                obj.featureMatrix(:, col2) = min(1, actSmooth / actMax);
                obj.featureNames{col2} = [sigName '_activity'];

                % Feature 3: derivative sign (sign of moving slope)
                col3 = (s-1)*3 + 3;
                % Use a simple moving linear regression slope
                derivSmooth = zeros(N, 1);
                halfWin = floor(derivWin / 2);
                for i = (halfWin+1):(N-halfWin)
                    segment = d(i-halfWin:i+halfWin);
                    tSeg = (0:numel(segment)-1)';
                    if numel(tSeg) > 1
                        pf = polyfit(tSeg, segment, 1);
                        derivSmooth(i) = pf(1);
                    end
                end
                % Fill edges (only when the signal is longer than the window)
                if N > halfWin + 1
                    derivSmooth(1:halfWin) = derivSmooth(halfWin+1);
                    derivSmooth(N-halfWin+1:end) = derivSmooth(N-halfWin);
                end
                % Normalize to [-1, 1]
                derivMax = max(abs(derivSmooth));
                if derivMax == 0, derivMax = 1; end
                obj.featureMatrix(:, col3) = derivSmooth / derivMax;
                obj.featureNames{col3} = [sigName '_deriv'];
            end
        end

        function shape = detectShape(~, t, data)
            % Detect dominant shape pattern in a time segment.
            % Returns: 0=flat, 1=ramp_up, 2=ramp_down, 3=exp_decay,
            %          4=oscillating, 5=stepping

            if numel(data) < 5
                shape = 0; % flat
                return;
            end

            dataRange = max(data) - min(data);
            dataMean = mean(data, 'omitnan');

            % Normalized range relative to mean
            if abs(dataMean) > 1e-9
                relRange = dataRange / abs(dataMean);
            else
                relRange = dataRange;
            end

            % Check flat
            if relRange < 0.02
                shape = 0; % flat
                return;
            end

            % Linear fit
            tNorm = t - t(1);
            pf = polyfit(tNorm, data, 1);
            linearResidual = data - polyval(pf, tNorm);
            linearRMSE = sqrt(mean(linearResidual.^2));

            % Exponential fit attempt (simple: fit log of shifted data)
            expRMSE = inf;
            if all(data - min(data) + 0.01 > 0)
                try
                    logData = log(data - min(data) + 0.01);
                    pExp = polyfit(tNorm, logData, 1);
                    expFit = exp(polyval(pExp, tNorm)) + min(data) - 0.01;
                    expRMSE = sqrt(mean((data - expFit).^2));
                catch
                end
            end

            % Check oscillating: count zero-crossings of detrended signal
            detrended = data - polyval(pf, tNorm);
            zeroCrossings = sum(abs(diff(sign(detrended))) > 0);
            oscillationRate = zeroCrossings / (t(end) - t(1));

            if oscillationRate > 2 % More than 2 crossings per second
                shape = 4; % oscillating
                return;
            end

            % Check stepping: look for clusters of values
            roundedData = round(data, 2);
            uniqueVals = unique(roundedData);
            if numel(uniqueVals) < max(3, numel(data) * 0.05) && numel(uniqueVals) >= 2
                shape = 5; % stepping
                return;
            end

            % Exponential decay vs linear
            if expRMSE < linearRMSE * 0.7 && pf(1) < 0
                shape = 3; % exponential decay
                return;
            end

            % Ramp
            if pf(1) > 0 && linearRMSE / dataRange < 0.3
                shape = 1; % ramp_up
                return;
            end
            if pf(1) < 0 && linearRMSE / dataRange < 0.3
                shape = 2; % ramp_down
                return;
            end

            % Default: flat (low signal-to-noise)
            shape = 0;
        end
    end
end
