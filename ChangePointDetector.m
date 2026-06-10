classdef ChangePointDetector < handle
    % ChangePointDetector — Find state transitions in multi-signal feature data.
    %
    % Uses a weighted multi-signal change score to detect time points where
    % the machine's behavior changes. Works on any combination of signals.
    %
    % Usage:
    %   cpd = ChangePointDetector(featureExtractor, config);
    %   cpd.detect();
    %   transitions = cpd.transitionTimes;  % column vector of time points

    properties
        fe                          % Feature extractor (SignalFeatureExtractor, already run)
        config          struct
        changeScore     double      % [N x 1] combined change score
        transitionTimes double      % Detected transition time points
        transitionIdx   double      % Indices into commonTime
        rawPeaks        double      % All candidate peaks before filtering
    end

    methods
        function obj = ChangePointDetector(featureExtractor, config)
            if nargin < 2, config = struct(); end
            obj.fe = featureExtractor;
            obj.config = obj.buildConfig(config);
        end

        function detect(obj)
            % Main method: compute change score, find peaks.

            obj.computeChangeScore();
            obj.findTransitions();
        end

        function detectForWafer(obj, tStart, tEnd)
            % Detect transitions within a specific wafer time window.
            % Recomputes change score only within the window.

            obj.computeChangeScore();

            % Mask to wafer window
            t = obj.fe.commonTime;
            waferMask = t >= tStart & t <= tEnd;

            % Find peaks only within this window
            obj.findTransitionsInMask(waferMask, tStart, tEnd);
        end
    end

    methods (Access = private)
        function cfg = buildConfig(~, userConfig)
            cfg.compareWindow = 2.0;        % seconds — window before/after each point
            cfg.smoothWindow = 0.5;         % seconds — change score smoothing
            cfg.minProminence = 0.30;       % fraction above local baseline for a peak
            cfg.baselineWindow = 10.0;      % seconds — window for computing local baseline
            cfg.minSeparation = 0.5;        % seconds — minimum gap between transitions
            cfg.adaptiveTarget = 0;         % If > 0, adjust threshold to hit approx this many transitions

            % Category weights for combining change scores
            cfg.categoryWeights = struct();
            cfg.categoryWeights.pressure = 3.0;
            cfg.categoryWeights.height = 2.5;
            cfg.categoryWeights.position = 2.0;
            cfg.categoryWeights.heater = 1.0;
            cfg.categoryWeights.temperature = 0.5;
            cfg.categoryWeights.unknown = 0.5;

            if ~isempty(fieldnames(userConfig))
                fns = fieldnames(userConfig);
                for i = 1:numel(fns)
                    cfg.(fns{i}) = userConfig.(fns{i});
                end
            end
        end

        function computeChangeScore(obj)
            % Compute a weighted change score at every time step.
            % For each point, compare feature means in windows before vs after.

            F = obj.fe.featureMatrix;
            t = obj.fe.commonTime;
            N = numel(t);
            fs = obj.fe.commonFs;

            if N < 10
                obj.changeScore = zeros(N, 1);
                return;
            end

            halfWin = max(1, round(obj.config.compareWindow * fs / 2));
            nFeatures = size(F, 2);

            % Build feature-to-category weight map
            weights = ones(nFeatures, 1);
            for f = 1:nFeatures
                % Find which signal this feature belongs to
                sigIdx = ceil(f / 3); % 3 features per signal
                if sigIdx <= numel(obj.fe.resampledData)
                    cat = obj.fe.resampledData(sigIdx).category;
                    catValid = matlab.lang.makeValidName(cat);
                    if isfield(obj.config.categoryWeights, catValid)
                        weights(f) = obj.config.categoryWeights.(catValid);
                    elseif isfield(obj.config.categoryWeights, cat)
                        weights(f) = obj.config.categoryWeights.(cat);
                    end
                end
            end

            % Normalize weights
            weights = weights / sum(weights);

            % Compute change score
            score = zeros(N, 1);

            % Vectorized approach: compute rolling means and compare
            % For efficiency, use cumulative sums
            cumF = [zeros(1, nFeatures); cumsum(F, 1)];

            for i = (halfWin+1):(N-halfWin)
                % Mean of features in window before
                i1 = max(1, i - halfWin + 1);
                i2 = i;
                n1 = i2 - i1 + 1;
                if n1 == 0, continue; end
                meanBefore = (cumF(i2+1, :) - cumF(i1, :)) / n1;

                % Mean of features in window after
                i3 = i + 1;
                i4 = min(N, i + halfWin);
                n2 = i4 - i3 + 1;
                if n2 == 0, continue; end
                meanAfter = (cumF(i4+1, :) - cumF(i3, :)) / n2;

                % Weighted absolute difference
                diff_vec = abs(meanAfter - meanBefore);
                score(i) = sum(diff_vec(:) .* weights(:));
            end

            % Smooth the score
            smoothWin = max(1, round(obj.config.smoothWindow * fs));
            obj.changeScore = movmean(score, smoothWin);
        end

        function findTransitions(obj)
            % Find peaks in the change score.

            t = obj.fe.commonTime;
            N = numel(t);
            waferMask = true(N, 1);
            obj.findTransitionsInMask(waferMask, t(1), t(end));
        end

        function findTransitionsInMask(obj, mask, tStart, tEnd)
            % Find transition peaks within a specific time mask.

            t = obj.fe.commonTime;
            fs = obj.fe.commonFs;
            score = obj.changeScore;

            % Apply mask
            maskedScore = score;
            maskedScore(~mask) = 0;

            % Compute local baseline (median over baselineWindow)
            baseWin = max(1, round(obj.config.baselineWindow * fs));
            baseline = movmedian(maskedScore, baseWin);

            % Prominence = score above local baseline
            prominence = maskedScore - baseline;
            prominence(prominence < 0) = 0;

            % Find peaks with minimum separation
            minSepSamples = max(1, round(obj.config.minSeparation * fs));

            % Simple peak detection
            candidateIdx = [];
            candidateProminence = [];

            for i = 2:(numel(maskedScore)-1)
                if ~mask(i), continue; end
                if maskedScore(i) > maskedScore(i-1) && maskedScore(i) >= maskedScore(i+1)
                    candidateIdx(end+1) = i; %#ok<AGROW>
                    candidateProminence(end+1) = prominence(i); %#ok<AGROW>
                end
            end

            if isempty(candidateIdx)
                obj.transitionTimes = [];
                obj.transitionIdx = [];
                obj.rawPeaks = [];
                return;
            end

            obj.rawPeaks = t(candidateIdx);

            % Determine prominence threshold
            maxProm = max(candidateProminence);
            if maxProm == 0
                obj.transitionTimes = [];
                obj.transitionIdx = [];
                return;
            end

            promThresh = obj.config.minProminence * maxProm;

            % Adaptive threshold: if target count specified, adjust
            if obj.config.adaptiveTarget > 0
                sortedProm = sort(candidateProminence, 'descend');
                targetIdx = min(obj.config.adaptiveTarget, numel(sortedProm));
                adaptiveThresh = sortedProm(targetIdx) * 0.9;
                promThresh = min(promThresh, adaptiveThresh);
            end

            % Filter by prominence
            keepMask = candidateProminence >= promThresh;
            filteredIdx = candidateIdx(keepMask);
            filteredProm = candidateProminence(keepMask);

            % Enforce minimum separation (keep highest prominence)
            if numel(filteredIdx) > 1
                selectedIdx = filteredIdx(1);
                selectedProm = filteredProm(1);

                for i = 2:numel(filteredIdx)
                    if filteredIdx(i) - selectedIdx(end) >= minSepSamples
                        selectedIdx(end+1) = filteredIdx(i); %#ok<AGROW>
                        selectedProm(end+1) = filteredProm(i); %#ok<AGROW>
                    else
                        % Keep whichever has higher prominence
                        if filteredProm(i) > selectedProm(end)
                            selectedIdx(end) = filteredIdx(i);
                            selectedProm(end) = filteredProm(i);
                        end
                    end
                end
                filteredIdx = selectedIdx;
            end

            obj.transitionIdx = filteredIdx(:);
            obj.transitionTimes = t(filteredIdx(:));
        end
    end
end
