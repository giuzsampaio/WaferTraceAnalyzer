classdef WaferTraceAnalyzer < handle
    % WaferTraceAnalyzer — Main orchestrator for wafer trace analysis.
    %
    % Loads a .mat file, auto-discovers signals, classifies them, detects
    % wafer boundaries and time periods, runs thermal analysis, and feeds
    % everything into a persistent knowledge base.

    properties
        filePath        char
        rawData         struct          % Raw loaded .mat contents
        signals         struct          % Discovered & classified signals
        wafers          struct          % Detected wafer intervals
        numWafers       double = 0
        periods         cell            % {wafer_idx} -> struct array of periods/states
        thermalResults  cell            % {wafer_idx} -> thermal analysis per period
        kb                              % Handle to knowledge base (KnowledgeBase)
        config          struct          % Signal classification config
        analysisID      char            % Unique ID for this analysis

        % State discovery engine components (v2)
        featureExtractor                % SignalFeatureExtractor
        changePointDetector             % ChangePointDetector
        stateSegmenter                  % StateSegmenter
        useStateDiscovery   logical = true   % Use new engine (false = legacy mode)
    end

    methods
        function obj = WaferTraceAnalyzer(matFilePath, varargin)
            p = inputParser;
            addRequired(p, 'matFilePath', @ischar);
            addParameter(p, 'KnowledgeBase', [], @(x) isa(x, 'KnowledgeBase'));
            addParameter(p, 'SignalConfig', struct(), @isstruct);
            parse(p, matFilePath, varargin{:});

            obj.filePath = matFilePath;
            obj.kb = p.Results.KnowledgeBase;
            obj.config = obj.buildConfig(p.Results.SignalConfig);
            obj.analysisID = obj.generateID();

            % Load .mat file
            obj.rawData = load(matFilePath);
        end

        %% ============================================================
        %  SIGNAL DISCOVERY
        %  ============================================================
        function discoverSignals(obj)
            % Auto-discover and classify all signals in the loaded data.
            % Handles flat variables, structs, and nested structs.
            % Each signal gets: name, time, data, category, sampleRate, unit.

            raw = obj.rawData;
            fieldNames = fieldnames(raw);
            discovered = struct('name', {}, 'fullPath', {}, 'time', {}, ...
                'data', {}, 'category', {}, 'sampleRate', {}, 'unit', {});

            for i = 1:numel(fieldNames)
                fn = fieldNames{i};
                val = raw.(fn);
                discovered = obj.extractSignals(discovered, fn, fn, val);
            end

            % Auto-pair time vectors with data vectors
            discovered = obj.pairTimeVectors(discovered);

            % Classify each signal
            for i = 1:numel(discovered)
                if isempty(discovered(i).category)
                    discovered(i).category = obj.classifySignal(discovered(i));
                end
            end

            % Ask knowledge base for any learned re-classifications
            if ~isempty(obj.kb)
                discovered = obj.kb.applySignalOverrides(discovered);
            end

            obj.signals = discovered;
        end

        function printSignalSummary(obj)
            categories = unique({obj.signals.category});
            fprintf('  Discovered %d signals in %d categories:\n', ...
                numel(obj.signals), numel(categories));
            for c = 1:numel(categories)
                cat = categories{c};
                sigs = obj.signals(strcmp({obj.signals.category}, cat));
                names = strjoin({sigs.name}, ', ');
                fprintf('    [%s] %d signals: %s\n', cat, numel(sigs), names);
            end
        end

        %% ============================================================
        %  WAFER BOUNDARY DETECTION
        %  ============================================================
        function detectWaferBoundaries(obj)
            % Detect wafer load/unload boundaries using a priority cascade:
            %   1. Clamping pressure (most reliable)
            %   2. Epin Z-height
            %   3. Chuck position activity
            %   4. Temperature discontinuities (last resort)

            waferIntervals = [];

            % Try clamping pressure first
            pressureSigs = obj.getSignalsByCategory('pressure');
            if ~isempty(pressureSigs)
                waferIntervals = obj.detectWafersFromPressure(pressureSigs(1));
            end

            % Fallback: epin Z-height
            if isempty(waferIntervals)
                heightSigs = obj.getSignalsByCategory('height');
                if ~isempty(heightSigs)
                    waferIntervals = obj.detectWafersFromHeight(heightSigs(1));
                end
            end

            % Fallback: chuck position activity
            if isempty(waferIntervals)
                posSigs = obj.getSignalsByCategory('position');
                if ~isempty(posSigs)
                    waferIntervals = obj.detectWafersFromPosition(posSigs);
                end
            end

            % Fallback: temperature discontinuities
            if isempty(waferIntervals)
                tempSigs = obj.getSignalsByCategory('temperature');
                if ~isempty(tempSigs)
                    waferIntervals = obj.detectWafersFromThermal(tempSigs);
                end
            end

            if isempty(waferIntervals)
                warning('WTA:noWafers', 'Could not detect wafer boundaries from any signal.');
                obj.wafers = struct('tStart', {}, 'tEnd', {}, 'idx', {});
                obj.numWafers = 0;
                return;
            end

            obj.wafers = waferIntervals;
            obj.numWafers = numel(waferIntervals);
        end

        %% ============================================================
        %  TIME PERIOD / STATE DETECTION
        %  ============================================================
        function detectTimePeriods(obj)
            % Detect time periods (states) within each wafer.
            %
            % V2 (default): Uses bottom-up state discovery:
            %   SignalFeatureExtractor → ChangePointDetector → StateSegmenter → StateLibrary
            %
            % Legacy: Uses top-down hardcoded period detection
            %   load → prealign → align → expose → unload

            if obj.useStateDiscovery
                obj.detectStates();
            else
                obj.detectPeriodsLegacy();
            end
        end

        function detectStates(obj)
            % Bottom-up state discovery pipeline.

            % Step 1: Extract features from all signals
            obj.featureExtractor = SignalFeatureExtractor(obj.signals, obj.config);
            obj.featureExtractor.extract();

            if isempty(obj.featureExtractor.commonTime)
                warning('WTA:noFeatures', 'Could not extract features — falling back to legacy.');
                obj.detectPeriodsLegacy();
                return;
            end

            % Step 2: Detect change points per wafer
            obj.changePointDetector = ChangePointDetector(obj.featureExtractor, obj.config);
            obj.changePointDetector.detect();

            % Step 3: Segment into states and cluster
            obj.stateSegmenter = StateSegmenter(obj.featureExtractor, ...
                obj.changePointDetector.transitionTimes, obj.wafers, obj.config);
            obj.stateSegmenter.segment();

            % Step 4: Match against state library
            obj.periods = obj.stateSegmenter.states;

            if ~isempty(obj.kb) && ~isempty(obj.kb.stateLibrary)
                obj.periods = obj.kb.stateLibrary.labelStates(obj.periods);
            end

            % Step 5: Specialist refinement — if a state is labeled "expose",
            % run the position-stepping detector to find individual fields
            for w = 1:obj.numWafers
                for s = 1:numel(obj.periods{w})
                    prd = obj.periods{w}(s);
                    if contains(lower(prd.name), 'expose') && prd.confidence >= 0.5
                        exposeRegion = obj.detectExposeFromPosition(prd.tStart, prd.tEnd);
                        if ~isempty(exposeRegion) && ~isempty(exposeRegion.fields)
                            obj.periods{w}(s).subPeriods = exposeRegion.fields;
                        end
                    end
                end
            end
        end

        function detectPeriodsLegacy(obj)
            % Legacy top-down period detection (V1 behavior).
            obj.periods = cell(obj.numWafers, 1);
            for w = 1:obj.numWafers
                wf = obj.wafers(w);
                obj.periods{w} = obj.detectPeriodsForWafer(wf, w);
            end
        end

        function printPeriodSummary(obj)
            for w = 1:obj.numWafers
                p = obj.periods{w};
                if isempty(p)
                    fprintf('  Wafer %d: no periods detected\n', w);
                    continue;
                end
                names = strjoin({p.name}, ' → ');
                durations = arrayfun(@(x) x.tEnd - x.tStart, p);
                totalDur = obj.wafers(w).tEnd - obj.wafers(w).tStart;
                fprintf('  Wafer %d (%.1fs total): %s\n', w, totalDur, names);
                for i = 1:numel(p)
                    fprintf('    %-15s  [%.2f – %.2f]s  (%.2fs)\n', ...
                        p(i).name, p(i).tStart, p(i).tEnd, durations(i));
                end
            end
        end

        %% ============================================================
        %  THERMAL ANALYSIS
        %  ============================================================
        function analyzeThermal(obj)
            % For each (wafer, period), compute thermal statistics,
            % transient characteristics, and cross-correlations.

            tempSigs = obj.getSignalsByCategory('temperature');
            heaterSigs = obj.getSignalsByCategory('heater');

            if isempty(tempSigs) && isempty(heaterSigs)
                fprintf('  No thermal signals found — skipping thermal analysis.\n');
                obj.thermalResults = cell(obj.numWafers, 1);
                return;
            end

            obj.thermalResults = cell(obj.numWafers, 1);

            for w = 1:obj.numWafers
                periodResults = struct();
                nPeriods = numel(obj.periods{w});

                for p = 1:nPeriods
                    prd = obj.periods{w}(p);
                    pName = matlab.lang.makeValidName(prd.name);

                    % Temperature statistics per sensor
                    tempStats = obj.computeThermalStats(tempSigs, prd.tStart, prd.tEnd);

                    % Heater statistics
                    heaterStats = obj.computeThermalStats(heaterSigs, prd.tStart, prd.tEnd);

                    % Transient analysis (settling, drift)
                    transients = obj.computeTransients(tempSigs, heaterSigs, prd.tStart, prd.tEnd);

                    % Cross-correlations: heater power → temperature response
                    xcorrs = obj.computeHeaterTempXCorr(heaterSigs, tempSigs, prd.tStart, prd.tEnd);

                    periodResults.(pName) = struct(...
                        'periodName', prd.name, ...
                        'tStart', prd.tStart, ...
                        'tEnd', prd.tEnd, ...
                        'temperature', tempStats, ...
                        'heater', heaterStats, ...
                        'transients', transients, ...
                        'crossCorrelations', xcorrs);
                end

                obj.thermalResults{w} = periodResults;
            end

            % Compute wafer-over-wafer drift
            obj.computeWaferDrift();
        end

        %% ============================================================
        %  KNOWLEDGE BASE UPDATE
        %  ============================================================
        function updateKnowledge(obj)
            if isempty(obj.kb)
                return;
            end

            entry = struct();
            entry.analysisID = obj.analysisID;
            entry.filePath = obj.filePath;
            entry.timestamp = datetime('now');
            entry.numWafers = obj.numWafers;
            entry.signalCategories = obj.getSignalCategorySummary();
            entry.periodNames = obj.getUniquePeriodNames();
            entry.thermalFingerprint = obj.computeThermalFingerprint();
            entry.waferDurations = arrayfun(@(w) w.tEnd - w.tStart, obj.wafers);

            % Per-period aggregate stats (across all wafers)
            entry.periodAggregates = obj.computePeriodAggregates();

            obj.kb.addAnalysis(entry);

            % Check for anomalies against historical data
            anomalies = obj.kb.detectAnomalies(entry);
            if ~isempty(anomalies)
                fprintf('  ⚠ Knowledge base flagged %d anomalies:\n', numel(anomalies));
                for a = 1:numel(anomalies)
                    fprintf('    - %s\n', anomalies{a});
                end
            end
        end

        %% ============================================================
        %  REPORT GENERATION
        %  ============================================================
        function generateReport(obj, outputDir)
            if ~exist(outputDir, 'dir')
                mkdir(outputDir);
            end

            % Figure 1: Signal overview with wafer boundaries and periods
            obj.plotSignalOverview(outputDir);

            % Figure 2: Per-wafer period timeline (Gantt-style)
            obj.plotPeriodTimeline(outputDir);

            % Figure 3: Thermal behavior per period
            obj.plotThermalPerPeriod(outputDir);

            % Figure 4: Wafer-over-wafer thermal drift
            obj.plotWaferDrift(outputDir);

            % Figure 5: Heater-temperature cross-correlation heatmap
            obj.plotXCorrHeatmap(outputDir);

            % Save structured results as .mat
            results = obj.getResults(); %#ok<NASGU>
            save(fullfile(outputDir, 'results.mat'), 'results');

            % Save human-readable summary
            obj.writeTextSummary(fullfile(outputDir, 'summary.txt'));

            fprintf('  Reports saved to: %s\n', outputDir);
        end

        function results = getResults(obj)
            results = struct();
            results.analysisID = obj.analysisID;
            results.filePath = obj.filePath;
            results.signals = obj.signals;
            results.wafers = obj.wafers;
            results.numWafers = obj.numWafers;
            results.periods = obj.periods;
            results.thermalResults = obj.thermalResults;
            results.useStateDiscovery = obj.useStateDiscovery;
        end

        function openExplorer(obj)
            % Open the interactive TraceExplorer for this analysis.
            explorer = TraceExplorer(obj);
            explorer.open();
        end

        function teachStates(obj)
            % Run command-line teach mode for state labeling.
            explorer = TraceExplorer(obj);
            explorer.teachFromCommandLine();
        end
    end

    %% ================================================================
    %  PRIVATE METHODS
    %  ================================================================
    methods (Access = private)

        %% --- Config ---
        function cfg = buildConfig(~, userConfig)
            % Default signal classification patterns (regex on signal name)
            cfg.namePatterns = struct();
            cfg.namePatterns.position = {'^chuck', 'x_pos', 'y_pos', '_x$', '_y$', ...
                'wafer_table.*pos', 'stage.*pos', 'reticle.*pos', 'wt_x', 'wt_y'};
            cfg.namePatterns.temperature = {'temp', 'therm', 'sensor.*t', 'tc_', ...
                'ntc', 'pt100', 'wt_temp', 'chuck.*temp'};
            cfg.namePatterns.heater = {'heater', 'htr', 'power', 'pwr', ...
                'heat.*pwr', 'actuator'};
            cfg.namePatterns.pressure = {'clamp', 'press', 'vacuum', 'vac_', ...
                'grip', 'epin.*press'};
            cfg.namePatterns.height = {'epin', 'z_pos', 'z_height', '_z$', ...
                'leveling', 'focus.*z', 'height'};

            % Thresholds
            cfg.clampThresholdFraction = 0.5;   % Fraction of range for pressure on/off
            cfg.minWaferDuration = 5;            % Min seconds for a valid wafer
            cfg.maxWaferGap = 120;               % Max seconds gap between wafers
            cfg.velocityThreshold = 0.01;        % Fraction of range/s for "moving"
            cfg.settleThreshold = 0.001;         % Fraction of range for "settled"
            cfg.minPeriodDuration = 0.5;         % Min seconds for a valid period
            cfg.exposeStepMinCount = 3;          % Min field steps to call it "expose"

            % Merge user overrides
            if ~isempty(fieldnames(userConfig))
                fns = fieldnames(userConfig);
                for i = 1:numel(fns)
                    cfg.(fns{i}) = userConfig.(fns{i});
                end
            end
        end

        function id = generateID(obj)
            [~, fname] = fileparts(obj.filePath);
            id = sprintf('%s_%s', fname, datestr(now, 'yyyymmdd_HHMMSS'));
        end

        %% --- Signal Extraction (recursive struct walker) ---
        function discovered = extractSignals(obj, discovered, name, fullPath, val)
            if isstruct(val) && ~istable(val)
                fns = fieldnames(val);
                for i = 1:numel(fns)
                    childName = fns{i};
                    childPath = [fullPath '.' childName];
                    % If struct array, take first element
                    if numel(val) > 1
                        discovered = obj.extractSignals(discovered, childName, childPath, val(1).(childName));
                    else
                        discovered = obj.extractSignals(discovered, childName, childPath, val.(childName));
                    end
                end
            elseif isnumeric(val) && isvector(val) && numel(val) > 10
                % This looks like a signal or time vector
                entry = struct();
                entry.name = name;
                entry.fullPath = fullPath;
                entry.time = [];        % Will be paired later
                entry.data = double(val(:));
                entry.category = '';    % Will be classified later
                entry.sampleRate = 0;
                entry.unit = '';
                discovered(end+1) = entry; %#ok<AGROW>
            elseif isnumeric(val) && ismatrix(val) && min(size(val)) > 1
                % Matrix — treat each column as a separate signal
                for col = 1:size(val, 2)
                    entry = struct();
                    entry.name = sprintf('%s_col%d', name, col);
                    entry.fullPath = sprintf('%s(:,%d)', fullPath, col);
                    entry.time = [];
                    entry.data = double(val(:, col));
                    entry.category = '';
                    entry.sampleRate = 0;
                    entry.unit = '';
                    discovered(end+1) = entry; %#ok<AGROW>
                end
            end
        end

        function discovered = pairTimeVectors(obj, discovered)
            % Heuristic: find time vectors and pair with data vectors.
            % A "time vector" is monotonically increasing and named *time* or *t*.
            % Each data vector is paired with the time vector of matching length.

            isTimeVec = false(numel(discovered), 1);
            for i = 1:numel(discovered)
                nm = lower(discovered(i).name);
                d = discovered(i).data;
                isMonotonic = all(diff(d) >= 0);
                hasTimeName = contains(nm, 'time') || strcmp(nm, 't') || ...
                    endsWith(nm, '_t') || startsWith(nm, 't_');
                isTimeVec(i) = isMonotonic && hasTimeName;
            end

            timeVecs = discovered(isTimeVec);
            dataVecs = discovered(~isTimeVec);

            % Build length → time vector lookup
            timeLenMap = containers.Map('KeyType', 'int64', 'ValueType', 'int32');
            for i = 1:numel(timeVecs)
                len = int64(numel(timeVecs(i).data));
                timeLenMap(len) = int32(i);
            end

            % Pair each data vector with matching-length time vector
            for i = 1:numel(dataVecs)
                len = int64(numel(dataVecs(i).data));
                if timeLenMap.isKey(len)
                    tIdx = timeLenMap(len);
                    dataVecs(i).time = timeVecs(tIdx).data;
                    dt = median(diff(dataVecs(i).time));
                    if dt > 0
                        dataVecs(i).sampleRate = 1 / dt;
                    end
                else
                    % No matching time vector — assume uniform sampling
                    % Try to infer from knowledge base or use index
                    dataVecs(i).time = (0:numel(dataVecs(i).data)-1)';
                    dataVecs(i).sampleRate = 1;
                end
            end

            % Also handle case where time is first column of a 2-column variable
            % (already handled by matrix splitting above)

            discovered = dataVecs;

            % If no time vectors found at all, try: first signal sorted ascending
            if isempty(timeVecs) && ~isempty(discovered)
                % Check if any signal looks like time (large monotonic range)
                for i = 1:numel(discovered)
                    d = discovered(i).data;
                    if all(diff(d) > 0) && (max(d) - min(d)) > 1
                        % Might be time — try pairing with others of same length
                        fprintf('  Warning: No explicit time vector found. Using "%s" as time.\n', ...
                            discovered(i).name);
                        tVec = d;
                        for j = 1:numel(discovered)
                            if j ~= i && numel(discovered(j).data) == numel(tVec)
                                discovered(j).time = tVec;
                                dt = median(diff(tVec));
                                if dt > 0
                                    discovered(j).sampleRate = 1 / dt;
                                end
                            end
                        end
                        % Remove the time signal itself from data signals
                        discovered(i) = [];
                        break;
                    end
                end
            end
        end

        function category = classifySignal(obj, sig)
            % Classify a signal by matching its name against known patterns,
            % then by statistical properties if name matching fails.

            nm = lower(sig.name);

            % Name-based classification
            cats = fieldnames(obj.config.namePatterns);
            for c = 1:numel(cats)
                patterns = obj.config.namePatterns.(cats{c});
                for p = 1:numel(patterns)
                    if ~isempty(regexp(nm, patterns{p}, 'once'))
                        category = cats{c};
                        return;
                    end
                end
            end

            % Statistical classification fallback
            d = sig.data;
            d = d(~isnan(d));
            if isempty(d)
                category = 'unknown';
                return;
            end

            range = max(d) - min(d);
            meanVal = mean(d);
            uniqueRatio = numel(unique(round(d, 4))) / numel(d);

            % Binary-like signal → likely pressure/clamp
            if uniqueRatio < 0.01 && numel(unique(round(d, 2))) <= 5
                category = 'pressure';
                return;
            end

            % Very large range with step patterns → likely position
            if range > 1000
                category = 'position';
                return;
            end

            % Typical temperature range (15-60 °C for wafer table temps)
            if meanVal > 10 && meanVal < 80 && range < 20
                category = 'temperature';
                return;
            end

            category = 'unknown';
        end

        function sigs = getSignalsByCategory(obj, category)
            mask = strcmp({obj.signals.category}, category);
            sigs = obj.signals(mask);
        end

        %% --- Wafer Boundary Detection Methods ---
        function intervals = detectWafersFromPressure(obj, pressSig)
            d = pressSig.data;
            t = pressSig.time;

            % Normalize to [0, 1]
            dMin = min(d); dMax = max(d);
            if dMax == dMin
                intervals = [];
                return;
            end
            dNorm = (d - dMin) / (dMax - dMin);

            % Binary threshold
            thresh = obj.config.clampThresholdFraction;
            clamped = dNorm > thresh;

            % Find rising edges (load) and falling edges (unload)
            edges = diff(double(clamped));
            loadIdx = find(edges > 0) + 1;
            unloadIdx = find(edges < 0);

            % Handle edge cases
            if clamped(1)
                loadIdx = [1; loadIdx(:)];
            end
            if clamped(end)
                unloadIdx = [unloadIdx(:); numel(clamped)];
            end

            % Pair loads with unloads
            intervals = struct('tStart', {}, 'tEnd', {}, 'idx', {}, ...
                'loadIdx', {}, 'unloadIdx', {});
            ui = 1;
            for li = 1:numel(loadIdx)
                % Find next unload after this load
                while ui <= numel(unloadIdx) && unloadIdx(ui) <= loadIdx(li)
                    ui = ui + 1;
                end
                if ui > numel(unloadIdx)
                    break;
                end

                tS = t(loadIdx(li));
                tE = t(unloadIdx(ui));
                dur = tE - tS;

                if dur >= obj.config.minWaferDuration
                    w = struct();
                    w.tStart = tS;
                    w.tEnd = tE;
                    w.idx = numel(intervals) + 1;
                    w.loadIdx = loadIdx(li);
                    w.unloadIdx = unloadIdx(ui);
                    intervals(end+1) = w; %#ok<AGROW>
                end
                ui = ui + 1;
            end
        end

        function intervals = detectWafersFromHeight(obj, heightSig)
            % Epin Z-height drops when wafer loads, rises when unloads.
            % Detect transitions.
            d = heightSig.data;
            t = heightSig.time;

            dSmooth = movmean(d, max(1, round(0.5 * heightSig.sampleRate)));
            dDiff = diff(dSmooth);

            % Large negative derivative → load; large positive → unload
            thresh = 0.3 * std(dDiff);
            loadIdx = find(dDiff < -thresh * 5);
            unloadIdx = find(dDiff > thresh * 5);

            % Cluster consecutive indices and take first of each cluster
            loadIdx = obj.clusterEdges(loadIdx, heightSig.sampleRate);
            unloadIdx = obj.clusterEdges(unloadIdx, heightSig.sampleRate);

            intervals = struct('tStart', {}, 'tEnd', {}, 'idx', {});
            ui = 1;
            for li = 1:numel(loadIdx)
                while ui <= numel(unloadIdx) && unloadIdx(ui) <= loadIdx(li)
                    ui = ui + 1;
                end
                if ui > numel(unloadIdx), break; end
                dur = t(unloadIdx(ui)) - t(loadIdx(li));
                if dur >= obj.config.minWaferDuration
                    w.tStart = t(loadIdx(li));
                    w.tEnd = t(unloadIdx(ui));
                    w.idx = numel(intervals) + 1;
                    intervals(end+1) = w; %#ok<AGROW>
                end
                ui = ui + 1;
            end
        end

        function intervals = detectWafersFromPosition(obj, posSigs)
            % Use chuck X,Y activity to find wafer cycles.
            % Compute combined velocity, find active vs idle periods.
            sig = posSigs(1);
            t = sig.time;
            d = sig.data;

            vel = abs(diff(d) ./ max(diff(t), 1e-9));
            velSmooth = movmean(vel, max(1, round(2 * sig.sampleRate)));
            velThresh = 0.1 * max(velSmooth);

            active = velSmooth > velThresh;
            edges = diff(double(active));
            starts = find(edges > 0) + 1;
            stops = find(edges < 0);

            if active(1), starts = [1; starts(:)]; end
            if active(end), stops = [stops(:); numel(active)]; end

            % Merge activity bursts that are close together
            intervals = struct('tStart', {}, 'tEnd', {}, 'idx', {});
            if isempty(starts), return; end

            curStart = starts(1);
            curStop = stops(1);
            si = 2;
            while si <= numel(starts)
                if t(starts(si)) - t(curStop) < obj.config.maxWaferGap
                    curStop = stops(si);
                else
                    dur = t(curStop) - t(curStart);
                    if dur >= obj.config.minWaferDuration
                        w.tStart = t(curStart);
                        w.tEnd = t(curStop);
                        w.idx = numel(intervals) + 1;
                        intervals(end+1) = w; %#ok<AGROW>
                    end
                    curStart = starts(si);
                    curStop = stops(si);
                end
                si = si + 1;
            end
            % Final interval
            dur = t(curStop) - t(curStart);
            if dur >= obj.config.minWaferDuration
                w.tStart = t(curStart);
                w.tEnd = t(curStop);
                w.idx = numel(intervals) + 1;
                intervals(end+1) = w; %#ok<AGROW>
            end
        end

        function intervals = detectWafersFromThermal(obj, tempSigs)
            % Last resort: detect wafer loading from temperature disturbances.
            sig = tempSigs(1);
            t = sig.time;
            d = sig.data;

            % Smooth and differentiate
            dSmooth = movmean(d, max(1, round(5 * sig.sampleRate)));
            dDeriv = abs(diff(dSmooth));
            derivThresh = 3 * median(dDeriv);

            disturbances = dDeriv > derivThresh;
            edges = diff(double(disturbances));
            starts = find(edges > 0) + 1;
            stops = find(edges < 0);

            if disturbances(1), starts = [1; starts(:)]; end
            if disturbances(end), stops = [stops(:); numel(disturbances)]; end

            % Cluster into wafer-length intervals
            intervals = struct('tStart', {}, 'tEnd', {}, 'idx', {});
            if isempty(starts) || isempty(stops), return; end

            curStart = starts(1);
            curStop = stops(1);
            for si = 2:numel(starts)
                if t(starts(si)) - t(curStop) > 10  % gap between wafers
                    w.tStart = t(curStart);
                    w.tEnd = t(curStop);
                    w.idx = numel(intervals) + 1;
                    intervals(end+1) = w; %#ok<AGROW>
                    curStart = starts(si);
                end
                if si <= numel(stops)
                    curStop = stops(si);
                end
            end
            w.tStart = t(curStart);
            w.tEnd = t(curStop);
            w.idx = numel(intervals) + 1;
            intervals(end+1) = w; %#ok<AGROW>
        end

        function clustered = clusterEdges(~, indices, sampleRate)
            if isempty(indices)
                clustered = [];
                return;
            end
            minGap = round(2 * sampleRate); % 2 second minimum gap
            clustered = indices(1);
            for i = 2:numel(indices)
                if indices(i) - indices(i-1) > minGap
                    clustered(end+1) = indices(i); %#ok<AGROW>
                end
            end
        end

        %% --- Time Period Detection (within wafer) ---
        function periods = detectPeriodsForWafer(obj, wf, waferIdx)
            % Hierarchical period detection within a single wafer interval.
            %
            % Strategy:
            %   1. Get all signals clipped to this wafer's time window
            %   2. Detect expose region from chuck X,Y stepping pattern
            %   3. Detect load/unload from pressure or height at boundaries
            %   4. Fill in align and pre-align from remaining time
            %   5. Subdivide expose into individual field steps

            periods = struct('name', {}, 'tStart', {}, 'tEnd', {}, ...
                'confidence', {}, 'detectedBy', {}, 'subPeriods', {});
            tS = wf.tStart;
            tE = wf.tEnd;

            % --- Detect EXPOSE from position stepping ---
            exposeRegion = obj.detectExposeFromPosition(tS, tE);

            % --- Detect LOAD (initial settle after clamp) ---
            loadEnd = tS;
            pressureSigs = obj.getSignalsByCategory('pressure');
            heightSigs = obj.getSignalsByCategory('height');

            if ~isempty(pressureSigs)
                % Load period = from clamp engage until pressure fully settled
                sig = pressureSigs(1);
                [tClip, dClip] = obj.clipSignal(sig, tS, tS + min(30, (tE-tS)/3));
                if ~isempty(tClip)
                    settled = obj.findSettleTime(tClip, dClip, 0.02);
                    loadEnd = settled;
                end
            elseif ~isempty(heightSigs)
                sig = heightSigs(1);
                [tClip, dClip] = obj.clipSignal(sig, tS, tS + min(30, (tE-tS)/3));
                if ~isempty(tClip)
                    settled = obj.findSettleTime(tClip, dClip, 0.02);
                    loadEnd = settled;
                end
            else
                % Guess: first 10% of wafer time is load
                loadEnd = tS + 0.1 * (tE - tS);
            end

            % --- Detect UNLOAD (final release) ---
            unloadStart = tE;
            if ~isempty(pressureSigs)
                sig = pressureSigs(1);
                tWindow = max(tS, tE - min(30, (tE-tS)/3));
                [tClip, dClip] = obj.clipSignal(sig, tWindow, tE);
                if ~isempty(tClip)
                    % Find when pressure starts dropping
                    dNorm = (dClip - min(dClip)) / max(max(dClip) - min(dClip), 1e-9);
                    dropIdx = find(dNorm < 0.9, 1, 'first');
                    if ~isempty(dropIdx)
                        unloadStart = tClip(dropIdx);
                    end
                end
            else
                unloadStart = tE - 0.05 * (tE - tS);
            end

            % --- Assemble periods ---
            % LOAD
            if loadEnd > tS + obj.config.minPeriodDuration
                periods(end+1) = struct('name', 'load', ...
                    'tStart', tS, 'tEnd', loadEnd, ...
                    'confidence', 0.8, 'detectedBy', 'pressure/height', ...
                    'subPeriods', []);
            end

            % PRE-ALIGN / ALIGN / EXPOSE
            if ~isempty(exposeRegion)
                % Time between load and expose → alignment
                if exposeRegion.tStart > loadEnd + obj.config.minPeriodDuration
                    % Try to split into pre-align and align
                    alignRegion = obj.detectAlignFromPosition(loadEnd, exposeRegion.tStart);
                    if ~isempty(alignRegion)
                        if alignRegion.tStart > loadEnd + obj.config.minPeriodDuration
                            periods(end+1) = struct('name', 'prealign', ...
                                'tStart', loadEnd, 'tEnd', alignRegion.tStart, ...
                                'confidence', 0.5, 'detectedBy', 'position', ...
                                'subPeriods', []);
                        end
                        periods(end+1) = struct('name', 'align', ...
                            'tStart', alignRegion.tStart, 'tEnd', alignRegion.tEnd, ...
                            'confidence', alignRegion.confidence, ...
                            'detectedBy', 'position', 'subPeriods', []);
                    else
                        periods(end+1) = struct('name', 'align', ...
                            'tStart', loadEnd, 'tEnd', exposeRegion.tStart, ...
                            'confidence', 0.5, 'detectedBy', 'inference', ...
                            'subPeriods', []);
                    end
                end

                % EXPOSE (with field sub-periods)
                periods(end+1) = struct('name', 'expose', ...
                    'tStart', exposeRegion.tStart, 'tEnd', exposeRegion.tEnd, ...
                    'confidence', exposeRegion.confidence, ...
                    'detectedBy', 'position_stepping', ...
                    'subPeriods', exposeRegion.fields);

                % Time between expose and unload → measure / post-expose
                if unloadStart > exposeRegion.tEnd + obj.config.minPeriodDuration
                    periods(end+1) = struct('name', 'post_expose', ...
                        'tStart', exposeRegion.tEnd, 'tEnd', unloadStart, ...
                        'confidence', 0.5, 'detectedBy', 'inference', ...
                        'subPeriods', []);
                end
            else
                % No expose detected — mark everything between load and unload
                % as "active" (unknown sub-periods)
                if unloadStart > loadEnd + obj.config.minPeriodDuration
                    periods(end+1) = struct('name', 'active', ...
                        'tStart', loadEnd, 'tEnd', unloadStart, ...
                        'confidence', 0.3, 'detectedBy', 'inference', ...
                        'subPeriods', []);
                end
            end

            % UNLOAD
            if tE > unloadStart + obj.config.minPeriodDuration
                periods(end+1) = struct('name', 'unload', ...
                    'tStart', unloadStart, 'tEnd', tE, ...
                    'confidence', 0.8, 'detectedBy', 'pressure/height', ...
                    'subPeriods', []);
            end

            % Sort by start time
            if ~isempty(periods)
                [~, sortIdx] = sort([periods.tStart]);
                periods = periods(sortIdx);
            end
        end

        function exposeRegion = detectExposeFromPosition(obj, tStart, tEnd)
            % Detect the expose (stepping) region from chuck X,Y positions.
            % During expose, the chuck moves in a step-settle-step pattern
            % visiting field positions on a grid.

            exposeRegion = [];
            posSigs = obj.getSignalsByCategory('position');
            if isempty(posSigs), return; end

            % Use the first position signal (preferably X)
            sig = posSigs(1);
            [t, d] = obj.clipSignal(sig, tStart, tEnd);
            if isempty(t) || numel(t) < 10, return; end

            % Compute velocity
            dt = diff(t);
            dt(dt == 0) = 1e-9;
            vel = abs(diff(d) ./ dt);
            velSmooth = movmean(vel, max(1, round(0.5 * sig.sampleRate)));

            % Find settled periods (low velocity)
            range = max(d) - min(d);
            if range == 0, return; end
            velNorm = velSmooth / (range / median(dt));
            isSettled = velNorm < obj.config.settleThreshold;

            % Find step-settle transitions
            transitions = diff(double(isSettled));
            settleStarts = find(transitions > 0) + 1;   % velocity goes low
            settleEnds = find(transitions < 0);          % velocity goes high

            if numel(settleStarts) < obj.config.exposeStepMinCount
                return; % Not enough steps for expose
            end

            % Extract settle positions — in expose these should form a grid
            settlePositions = zeros(numel(settleStarts), 1);
            settleTimes = zeros(numel(settleStarts), 1);
            for i = 1:numel(settleStarts)
                endIdx = settleStarts(i);
                if i < numel(settleStarts)
                    nextStart = settleStarts(i+1);
                    segEnd = min(endIdx + round(nextStart - endIdx), numel(d)-1);
                else
                    segEnd = min(endIdx + round(sig.sampleRate * 5), numel(d)-1);
                end
                segEnd = max(segEnd, endIdx);
                settlePositions(i) = mean(d(endIdx:segEnd));
                settleTimes(i) = t(endIdx);
            end

            % Detect grid pattern: position changes should be roughly quantized
            posChanges = abs(diff(settlePositions));
            posChanges = posChanges(posChanges > 0.1 * range);
            if isempty(posChanges), return; end

            % Check for regularity (grid-like stepping)
            stepSize = median(posChanges);
            isRegular = sum(abs(posChanges - stepSize) < 0.5 * stepSize) > 0.5 * numel(posChanges);

            if ~isRegular && numel(settleStarts) < obj.config.exposeStepMinCount * 2
                return; % Doesn't look like expose stepping
            end

            % Build expose region
            exposeRegion = struct();
            exposeRegion.tStart = t(settleStarts(1));
            exposeRegion.tEnd = t(min(settleEnds(end), numel(t)));
            exposeRegion.confidence = 0.5 + 0.5 * double(isRegular);

            % Build field sub-periods
            fields = struct('name', {}, 'tStart', {}, 'tEnd', {}, ...
                'position', {}, 'fieldIdx', {});
            for i = 1:numel(settleStarts)
                f.name = sprintf('field_%03d', i);
                f.tStart = t(settleStarts(i));
                if i <= numel(settleEnds) && settleEnds(i) > settleStarts(i)
                    f.tEnd = t(settleEnds(i));
                elseif i < numel(settleStarts)
                    f.tEnd = t(settleStarts(i+1));
                else
                    f.tEnd = exposeRegion.tEnd;
                end
                f.position = settlePositions(i);
                f.fieldIdx = i;
                fields(end+1) = f; %#ok<AGROW>
            end
            exposeRegion.fields = fields;
        end

        function alignRegion = detectAlignFromPosition(obj, tStart, tEnd)
            % Detect alignment from position: small, precise movements
            % (mark measurement pattern) distinct from the stepping pattern.

            alignRegion = [];
            posSigs = obj.getSignalsByCategory('position');
            if isempty(posSigs), return; end

            sig = posSigs(1);
            [t, d] = obj.clipSignal(sig, tStart, tEnd);
            if isempty(t) || numel(t) < 5, return; end

            % Alignment shows position activity (non-zero velocity)
            dt = diff(t); dt(dt == 0) = 1e-9;
            vel = abs(diff(d) ./ dt);
            velSmooth = movmean(vel, max(1, round(0.2 * sig.sampleRate)));
            velThresh = 0.05 * max(velSmooth);

            isActive = velSmooth > velThresh;
            if ~any(isActive), return; end

            firstActive = find(isActive, 1, 'first');
            lastActive = find(isActive, 1, 'last');

            alignRegion = struct();
            alignRegion.tStart = t(firstActive);
            alignRegion.tEnd = t(min(lastActive + 1, numel(t)));
            alignRegion.confidence = 0.6;
        end

        function [tClip, dClip] = clipSignal(~, sig, tStart, tEnd)
            % Extract signal segment within time window.
            mask = sig.time >= tStart & sig.time <= tEnd;
            tClip = sig.time(mask);
            dClip = sig.data(mask);
        end

        function tSettle = findSettleTime(~, t, d, threshold)
            % Find the time at which a signal has settled (derivative < threshold).
            if numel(d) < 3
                tSettle = t(1);
                return;
            end
            dNorm = (d - min(d)) / max(max(d) - min(d), 1e-9);
            dDeriv = abs(diff(dNorm) ./ max(diff(t), 1e-9));
            dDerivSmooth = movmean(dDeriv, max(1, round(numel(dDeriv)/20)));

            settledIdx = find(dDerivSmooth < threshold, 1, 'first');
            if isempty(settledIdx)
                tSettle = t(end);
            else
                tSettle = t(min(settledIdx + 1, numel(t)));
            end
        end

        %% --- Thermal Analysis Methods ---
        function stats = computeThermalStats(obj, sigs, tStart, tEnd)
            % Compute statistics for thermal signals within a time window.
            stats = struct();
            for i = 1:numel(sigs)
                [t, d] = obj.clipSignal(sigs(i), tStart, tEnd);
                if isempty(d), continue; end

                s = struct();
                s.name = sigs(i).name;
                s.mean = mean(d, 'omitnan');
                s.std = std(d, 'omitnan');
                s.min = min(d);
                s.max = max(d);
                s.range = s.max - s.min;
                s.median = median(d, 'omitnan');

                % Linear trend (drift)
                if numel(t) > 2
                    tNorm = t - t(1);
                    p = polyfit(tNorm, d, 1);
                    s.driftRate = p(1);             % units/second
                    s.totalDrift = p(1) * (t(end) - t(1));
                else
                    s.driftRate = 0;
                    s.totalDrift = 0;
                end

                % Peak-to-peak over time (for oscillation detection)
                if numel(d) > 10
                    windowSize = max(1, round(numel(d)/10));
                    localMax = movmax(d, windowSize);
                    localMin = movmin(d, windowSize);
                    s.p2pMean = mean(localMax - localMin);
                else
                    s.p2pMean = s.range;
                end

                sName = matlab.lang.makeValidName(sigs(i).name);
                stats.(sName) = s;
            end
        end

        function transients = computeTransients(obj, tempSigs, heaterSigs, tStart, tEnd)
            % Analyze transient behavior: settling time, time constants, overshoot.
            transients = struct();

            allSigs = [tempSigs, heaterSigs];
            for i = 1:numel(allSigs)
                [t, d] = obj.clipSignal(allSigs(i), tStart, tEnd);
                if numel(d) < 5, continue; end

                tr = struct();
                tr.name = allSigs(i).name;

                % Settling characteristics
                dNorm = (d - d(1)) / max(abs(max(d) - d(1)), 1e-9);
                finalVal = mean(d(max(1,end-round(numel(d)/10)):end));
                dToFinal = abs(d - finalVal);
                settledMask = dToFinal < 0.02 * max(dToFinal);

                firstSettled = find(settledMask, 1, 'first');
                if ~isempty(firstSettled)
                    tr.settlingTime = t(firstSettled) - t(1);
                else
                    tr.settlingTime = t(end) - t(1);
                end

                % Time constant estimation (63.2% of step response)
                if abs(d(end) - d(1)) > 0.01 * std(d)
                    target = d(1) + 0.632 * (finalVal - d(1));
                    if d(end) > d(1)
                        tcIdx = find(d >= target, 1, 'first');
                    else
                        tcIdx = find(d <= target, 1, 'first');
                    end
                    if ~isempty(tcIdx)
                        tr.timeConstant = t(tcIdx) - t(1);
                    else
                        tr.timeConstant = NaN;
                    end
                else
                    tr.timeConstant = NaN;
                end

                % Overshoot
                if abs(finalVal - d(1)) > 0.01 * std(d)
                    if finalVal > d(1)
                        tr.overshoot = (max(d) - finalVal) / (finalVal - d(1)) * 100;
                    else
                        tr.overshoot = (min(d) - finalVal) / (finalVal - d(1)) * 100;
                    end
                else
                    tr.overshoot = 0;
                end

                sName = matlab.lang.makeValidName(allSigs(i).name);
                transients.(sName) = tr;
            end
        end

        function xcorrs = computeHeaterTempXCorr(obj, heaterSigs, tempSigs, tStart, tEnd)
            % Cross-correlation between heater power and temperature response.
            % Estimates thermal transfer delay and coupling strength.
            xcorrs = struct();

            for h = 1:numel(heaterSigs)
                [tH, dH] = obj.clipSignal(heaterSigs(h), tStart, tEnd);
                if numel(dH) < 20, continue; end

                for s = 1:numel(tempSigs)
                    [tT, dT] = obj.clipSignal(tempSigs(s), tStart, tEnd);
                    if numel(dT) < 20, continue; end

                    % Resample to common time base
                    tCommon = linspace(max(tH(1), tT(1)), min(tH(end), tT(end)), ...
                        min(numel(tH), numel(tT)));
                    if numel(tCommon) < 20, continue; end

                    dH_rs = interp1(tH, dH, tCommon, 'linear', 'extrap');
                    dT_rs = interp1(tT, dT, tCommon, 'linear', 'extrap');

                    % Detrend
                    dH_rs = detrend(dH_rs);
                    dT_rs = detrend(dT_rs);

                    % Normalized cross-correlation (FFT-based, no toolbox needed)
                    [xc, lags] = WaferTraceAnalyzer.normalizedXCorr(dT_rs, dH_rs);
                    dt = median(diff(tCommon));
                    lagTimes = lags * dt;

                    % Find peak (only look at positive lags — temp responds after heater)
                    posLagMask = lagTimes >= 0;
                    xcPos = xc(posLagMask);
                    lagPos = lagTimes(posLagMask);

                    [peakCorr, peakIdx] = max(xcPos);
                    peakLag = lagPos(peakIdx);

                    pairName = sprintf('%s_to_%s', ...
                        matlab.lang.makeValidName(heaterSigs(h).name), ...
                        matlab.lang.makeValidName(tempSigs(s).name));

                    xcorrs.(pairName) = struct(...
                        'heater', heaterSigs(h).name, ...
                        'sensor', tempSigs(s).name, ...
                        'peakCorrelation', peakCorr, ...
                        'delaySeconds', peakLag, ...
                        'fullXCorr', xc, ...
                        'lagTimes', lagTimes);
                end
            end
        end

        function computeWaferDrift(obj)
            % Compute wafer-over-wafer thermal drift for each period type.
            % This reveals systematic heating/cooling trends across the lot.

            if obj.numWafers < 2, return; end

            periodNames = obj.getUniquePeriodNames();
            tempSigs = obj.getSignalsByCategory('temperature');
            heaterSigs = obj.getSignalsByCategory('heater');

            for p = 1:numel(periodNames)
                pName = periodNames{p};
                pNameValid = matlab.lang.makeValidName(pName);

                for s = 1:numel(tempSigs)
                    sName = matlab.lang.makeValidName(tempSigs(s).name);
                    means = NaN(obj.numWafers, 1);
                    drifts = NaN(obj.numWafers, 1);

                    for w = 1:obj.numWafers
                        if isfield(obj.thermalResults{w}, pNameValid)
                            pResult = obj.thermalResults{w}.(pNameValid);
                            if isfield(pResult.temperature, sName)
                                means(w) = pResult.temperature.(sName).mean;
                                drifts(w) = pResult.temperature.(sName).totalDrift;
                            end
                        end
                    end

                    % Store drift trend
                    validMask = ~isnan(means);
                    if sum(validMask) > 2
                        waferNums = (1:obj.numWafers)';
                        pFit = polyfit(waferNums(validMask), means(validMask), 1);
                        for w = 1:obj.numWafers
                            if isfield(obj.thermalResults{w}, pNameValid)
                                obj.thermalResults{w}.(pNameValid).waferDrift.(sName) = struct(...
                                    'meanPerWafer', means, ...
                                    'driftPerWafer', drifts, ...
                                    'trendSlope', pFit(1), ...
                                    'trendIntercept', pFit(2));
                            end
                        end
                    end
                end
            end
        end

        %% --- Knowledge & Summary Helpers ---
        function summary = getSignalCategorySummary(obj)
            cats = unique({obj.signals.category});
            summary = struct();
            for c = 1:numel(cats)
                catName = matlab.lang.makeValidName(cats{c});
                sigs = obj.signals(strcmp({obj.signals.category}, cats{c}));
                summary.(catName) = {sigs.name};
            end
        end

        function names = getUniquePeriodNames(obj)
            allNames = {};
            for w = 1:obj.numWafers
                if ~isempty(obj.periods{w})
                    allNames = [allNames, {obj.periods{w}.name}]; %#ok<AGROW>
                end
            end
            names = unique(allNames);
        end

        function fp = computeThermalFingerprint(obj)
            % Compute a compact "fingerprint" of the thermal state of this test.
            % Used by knowledge base for similarity matching.
            tempSigs = obj.getSignalsByCategory('temperature');
            fp = struct();
            for i = 1:numel(tempSigs)
                sName = matlab.lang.makeValidName(tempSigs(i).name);
                d = tempSigs(i).data;
                fp.(sName) = struct('globalMean', mean(d, 'omitnan'), ...
                    'globalStd', std(d, 'omitnan'), ...
                    'globalRange', max(d) - min(d));
            end
        end

        function agg = computePeriodAggregates(obj)
            % Aggregate thermal statistics across all wafers for each period.
            periodNames = obj.getUniquePeriodNames();
            agg = struct();

            for p = 1:numel(periodNames)
                pName = periodNames{p};
                pNameValid = matlab.lang.makeValidName(pName);

                % Collect stats from all wafers
                allStats = {};
                for w = 1:obj.numWafers
                    if isfield(obj.thermalResults{w}, pNameValid)
                        allStats{end+1} = obj.thermalResults{w}.(pNameValid); %#ok<AGROW>
                    end
                end

                if isempty(allStats), continue; end

                % Aggregate temperature means across wafers
                tempFields = fieldnames(allStats{1}.temperature);
                aggTemp = struct();
                for tf = 1:numel(tempFields)
                    vals = cellfun(@(x) x.temperature.(tempFields{tf}).mean, allStats);
                    aggTemp.(tempFields{tf}) = struct(...
                        'meanOfMeans', mean(vals), ...
                        'stdOfMeans', std(vals), ...
                        'minMean', min(vals), ...
                        'maxMean', max(vals));
                end

                agg.(pNameValid) = struct('temperature', aggTemp, 'nWafers', numel(allStats));
            end
        end

        %% --- Plotting Methods ---
        function plotSignalOverview(obj, outputDir)
            % Plot all signals with wafer boundaries and period annotations.
            categories = unique({obj.signals.category});
            nCats = numel(categories);

            fig = figure('Position', [100 100 1400 200*nCats], 'Visible', 'off');

            for c = 1:nCats
                ax = subplot(nCats, 1, c);
                sigs = obj.getSignalsByCategory(categories{c});

                hold(ax, 'on');
                colors = lines(numel(sigs));
                legendNames = cell(numel(sigs), 1);

                for s = 1:numel(sigs)
                    plot(ax, sigs(s).time, sigs(s).data, 'Color', colors(s,:), 'LineWidth', 0.5);
                    legendNames{s} = sigs(s).name;
                end

                % Draw wafer boundaries
                yLim = get(ax, 'YLim');
                for w = 1:obj.numWafers
                    xline(ax, obj.wafers(w).tStart, 'g--', 'LineWidth', 1.5);
                    xline(ax, obj.wafers(w).tEnd, 'r--', 'LineWidth', 1.5);
                    text(ax, obj.wafers(w).tStart, yLim(2), sprintf('W%d', w), ...
                        'VerticalAlignment', 'bottom', 'FontSize', 8);
                end

                title(ax, upper(categories{c}), 'FontWeight', 'bold');
                ylabel(ax, categories{c});
                legend(ax, legendNames, 'Location', 'eastoutside', 'FontSize', 7);
                grid(ax, 'on');
                hold(ax, 'off');
            end
            xlabel('Time (s)');
            sgtitle('Signal Overview with Wafer Boundaries');

            saveas(fig, fullfile(outputDir, 'signal_overview.png'));
            close(fig);
        end

        function plotPeriodTimeline(obj, outputDir)
            % Gantt-style chart showing time periods for each wafer.
            fig = figure('Position', [100 100 1200 50*obj.numWafers + 150], 'Visible', 'off');
            ax = axes(fig);
            hold(ax, 'on');

            periodColors = containers.Map();
            periodColors('load') = [0.2 0.6 0.2];
            periodColors('prealign') = [0.3 0.3 0.8];
            periodColors('align') = [0.1 0.1 0.9];
            periodColors('expose') = [0.9 0.1 0.1];
            periodColors('post_expose') = [0.8 0.5 0.2];
            periodColors('unload') = [0.5 0.5 0.5];
            periodColors('active') = [0.7 0.7 0.3];

            allPeriodNames = obj.getUniquePeriodNames();
            defaultColors = lines(numel(allPeriodNames));
            for i = 1:numel(allPeriodNames)
                if ~periodColors.isKey(allPeriodNames{i})
                    periodColors(allPeriodNames{i}) = defaultColors(i,:);
                end
            end

            for w = 1:obj.numWafers
                y = obj.numWafers - w + 1;
                for p = 1:numel(obj.periods{w})
                    prd = obj.periods{w}(p);
                    if periodColors.isKey(prd.name)
                        clr = periodColors(prd.name);
                    else
                        clr = [0.5 0.5 0.5];
                    end
                    dur = prd.tEnd - prd.tStart;
                    rectangle(ax, 'Position', [prd.tStart, y-0.4, dur, 0.8], ...
                        'FaceColor', clr, 'EdgeColor', 'k', 'LineWidth', 0.5);
                    if dur > 2
                        text(ax, prd.tStart + dur/2, y, prd.name, ...
                            'HorizontalAlignment', 'center', 'FontSize', 7, ...
                            'Color', 'w', 'FontWeight', 'bold');
                    end
                end
            end

            set(ax, 'YTick', 1:obj.numWafers, 'YTickLabel', ...
                arrayfun(@(w) sprintf('Wafer %d', w), obj.numWafers:-1:1, 'Uni', false));
            xlabel(ax, 'Time (s)');
            title(ax, 'Wafer Time Periods');
            grid(ax, 'on');
            hold(ax, 'off');

            saveas(fig, fullfile(outputDir, 'period_timeline.png'));
            close(fig);
        end

        function plotThermalPerPeriod(obj, outputDir)
            % Plot thermal signals per period, showing wafer-over-wafer trends.
            tempSigs = obj.getSignalsByCategory('temperature');
            heaterSigs = obj.getSignalsByCategory('heater');
            periodNames = obj.getUniquePeriodNames();

            if isempty(tempSigs) && isempty(heaterSigs), return; end

            for p = 1:numel(periodNames)
                pName = periodNames{p};
                pNameValid = matlab.lang.makeValidName(pName);

                fig = figure('Position', [100 100 1200 800], 'Visible', 'off');
                colors = parula(obj.numWafers);

                % Temperature subplot
                if ~isempty(tempSigs)
                    ax1 = subplot(2,1,1);
                    hold(ax1, 'on');
                    for w = 1:obj.numWafers
                        periods_w = obj.periods{w};
                        pIdx = find(strcmp({periods_w.name}, pName), 1);
                        if isempty(pIdx), continue; end
                        prd = periods_w(pIdx);
                        for s = 1:min(3, numel(tempSigs)) % Top 3 sensors
                            [t, d] = obj.clipSignal(tempSigs(s), prd.tStart, prd.tEnd);
                            if ~isempty(t)
                                plot(ax1, t - prd.tStart, d, 'Color', colors(w,:), 'LineWidth', 0.8);
                            end
                        end
                    end
                    title(ax1, sprintf('%s — Temperature', upper(pName)));
                    ylabel(ax1, 'Temperature');
                    grid(ax1, 'on');
                    colorbar(ax1); colormap(ax1, parula);
                    caxis(ax1, [1 max(obj.numWafers, 2)]);
                    hold(ax1, 'off');
                end

                % Heater subplot
                if ~isempty(heaterSigs)
                    ax2 = subplot(2,1,2);
                    hold(ax2, 'on');
                    for w = 1:obj.numWafers
                        periods_w = obj.periods{w};
                        pIdx = find(strcmp({periods_w.name}, pName), 1);
                        if isempty(pIdx), continue; end
                        prd = periods_w(pIdx);
                        for s = 1:min(3, numel(heaterSigs))
                            [t, d] = obj.clipSignal(heaterSigs(s), prd.tStart, prd.tEnd);
                            if ~isempty(t)
                                plot(ax2, t - prd.tStart, d, 'Color', colors(w,:), 'LineWidth', 0.8);
                            end
                        end
                    end
                    title(ax2, sprintf('%s — Heater Power', upper(pName)));
                    xlabel(ax2, 'Time within period (s)');
                    ylabel(ax2, 'Power');
                    grid(ax2, 'on');
                    hold(ax2, 'off');
                end

                sgtitle(sprintf('Thermal Behavior: %s', upper(pName)));
                saveas(fig, fullfile(outputDir, sprintf('thermal_%s.png', pNameValid)));
                close(fig);
            end
        end

        function plotWaferDrift(obj, outputDir)
            % Plot mean temperature and heater power vs wafer number per period.
            periodNames = obj.getUniquePeriodNames();
            tempSigs = obj.getSignalsByCategory('temperature');
            if isempty(tempSigs) || obj.numWafers < 2, return; end

            fig = figure('Position', [100 100 1200 300*numel(periodNames)], 'Visible', 'off');

            for p = 1:numel(periodNames)
                pNameValid = matlab.lang.makeValidName(periodNames{p});
                ax = subplot(numel(periodNames), 1, p);
                hold(ax, 'on');

                colors = lines(numel(tempSigs));
                for s = 1:numel(tempSigs)
                    sName = matlab.lang.makeValidName(tempSigs(s).name);
                    means = NaN(obj.numWafers, 1);
                    for w = 1:obj.numWafers
                        if isfield(obj.thermalResults{w}, pNameValid) && ...
                                isfield(obj.thermalResults{w}.(pNameValid).temperature, sName)
                            means(w) = obj.thermalResults{w}.(pNameValid).temperature.(sName).mean;
                        end
                    end
                    plot(ax, 1:obj.numWafers, means, '-o', 'Color', colors(s,:), ...
                        'LineWidth', 1.5, 'MarkerSize', 4, 'DisplayName', tempSigs(s).name);
                end

                title(ax, sprintf('%s — Wafer-over-Wafer Temperature Drift', upper(periodNames{p})));
                xlabel(ax, 'Wafer Number');
                ylabel(ax, 'Mean Temperature');
                legend(ax, 'Location', 'eastoutside', 'FontSize', 7);
                grid(ax, 'on');
                hold(ax, 'off');
            end

            saveas(fig, fullfile(outputDir, 'wafer_drift.png'));
            close(fig);
        end

        function plotXCorrHeatmap(obj, outputDir)
            % Heatmap of heater→temperature cross-correlation peak values.
            heaterSigs = obj.getSignalsByCategory('heater');
            tempSigs = obj.getSignalsByCategory('temperature');
            if isempty(heaterSigs) || isempty(tempSigs), return; end

            periodNames = obj.getUniquePeriodNames();

            for p = 1:numel(periodNames)
                pNameValid = matlab.lang.makeValidName(periodNames{p});

                % Collect xcorr data from first wafer with data
                corrMatrix = NaN(numel(heaterSigs), numel(tempSigs));
                delayMatrix = NaN(numel(heaterSigs), numel(tempSigs));

                for w = 1:obj.numWafers
                    if ~isfield(obj.thermalResults{w}, pNameValid), continue; end
                    xcData = obj.thermalResults{w}.(pNameValid).crossCorrelations;
                    if isempty(fieldnames(xcData)), continue; end

                    pairNames = fieldnames(xcData);
                    for pn = 1:numel(pairNames)
                        pair = xcData.(pairNames{pn});
                        hIdx = find(strcmp({heaterSigs.name}, pair.heater), 1);
                        tIdx = find(strcmp({tempSigs.name}, pair.sensor), 1);
                        if ~isempty(hIdx) && ~isempty(tIdx)
                            if isnan(corrMatrix(hIdx, tIdx))
                                corrMatrix(hIdx, tIdx) = pair.peakCorrelation;
                                delayMatrix(hIdx, tIdx) = pair.delaySeconds;
                            else
                                % Average across wafers
                                corrMatrix(hIdx, tIdx) = (corrMatrix(hIdx, tIdx) + pair.peakCorrelation) / 2;
                                delayMatrix(hIdx, tIdx) = (delayMatrix(hIdx, tIdx) + pair.delaySeconds) / 2;
                            end
                        end
                    end
                    break; % Use first wafer with data
                end

                if all(isnan(corrMatrix(:))), continue; end

                fig = figure('Position', [100 100 800 600], 'Visible', 'off');
                imagesc(corrMatrix);
                colorbar; colormap(jet);
                set(gca, 'XTick', 1:numel(tempSigs), ...
                    'XTickLabel', {tempSigs.name}, 'XTickLabelRotation', 45);
                set(gca, 'YTick', 1:numel(heaterSigs), ...
                    'YTickLabel', {heaterSigs.name});
                title(sprintf('%s — Heater→Sensor Correlation (peak xcorr)', upper(periodNames{p})));
                xlabel('Temperature Sensor');
                ylabel('Heater');

                % Annotate with delay values
                for hi = 1:numel(heaterSigs)
                    for ti = 1:numel(tempSigs)
                        if ~isnan(delayMatrix(hi, ti))
                            text(ti, hi, sprintf('%.1fs', delayMatrix(hi, ti)), ...
                                'HorizontalAlignment', 'center', 'FontSize', 8, 'Color', 'w');
                        end
                    end
                end

                saveas(fig, fullfile(outputDir, sprintf('xcorr_heatmap_%s.png', periodNames{p})));
                close(fig);
            end
        end

        function writeTextSummary(obj, filePath)
            fid = fopen(filePath, 'w');
            fprintf(fid, 'WaferTraceAnalyzer Summary\n');
            fprintf(fid, '==========================\n');
            fprintf(fid, 'File: %s\n', obj.filePath);
            fprintf(fid, 'Analysis ID: %s\n', obj.analysisID);
            fprintf(fid, 'Date: %s\n\n', datestr(now));

            fprintf(fid, 'Signals: %d discovered\n', numel(obj.signals));
            cats = unique({obj.signals.category});
            for c = 1:numel(cats)
                sigs = obj.signals(strcmp({obj.signals.category}, cats{c}));
                fprintf(fid, '  [%s] %s\n', cats{c}, strjoin({sigs.name}, ', '));
            end

            fprintf(fid, '\nWafers: %d detected\n', obj.numWafers);
            for w = 1:obj.numWafers
                wf = obj.wafers(w);
                fprintf(fid, '  Wafer %d: [%.2f – %.2f]s (%.1fs)\n', ...
                    w, wf.tStart, wf.tEnd, wf.tEnd - wf.tStart);
                if ~isempty(obj.periods{w})
                    for p = 1:numel(obj.periods{w})
                        prd = obj.periods{w}(p);
                        fprintf(fid, '    %-15s [%.2f – %.2f]s (%.2fs) conf=%.0f%%\n', ...
                            prd.name, prd.tStart, prd.tEnd, ...
                            prd.tEnd - prd.tStart, prd.confidence * 100);
                    end
                end
            end

            % Thermal summary
            fprintf(fid, '\nThermal Summary:\n');
            periodNames = obj.getUniquePeriodNames();
            tempSigs = obj.getSignalsByCategory('temperature');
            for p = 1:numel(periodNames)
                pNameValid = matlab.lang.makeValidName(periodNames{p});
                fprintf(fid, '  [%s]\n', periodNames{p});
                for s = 1:numel(tempSigs)
                    sName = matlab.lang.makeValidName(tempSigs(s).name);
                    means = [];
                    drifts = [];
                    for w = 1:obj.numWafers
                        if isfield(obj.thermalResults{w}, pNameValid) && ...
                                isfield(obj.thermalResults{w}.(pNameValid).temperature, sName)
                            st = obj.thermalResults{w}.(pNameValid).temperature.(sName);
                            means(end+1) = st.mean; %#ok<AGROW>
                            drifts(end+1) = st.driftRate; %#ok<AGROW>
                        end
                    end
                    if ~isempty(means)
                        fprintf(fid, '    %s: mean=%.4f +/- %.4f, drift=%.2e/s\n', ...
                            tempSigs(s).name, mean(means), std(means), mean(drifts));
                    end
                end
            end

            fclose(fid);
        end
    end

    methods (Static, Access = private)
        function [xc, lags] = normalizedXCorr(x, y)
            % Equivalent to xcorr(x, y, 'coeff') for equal-length vectors,
            % implemented with FFTs so the Signal Processing Toolbox is
            % not required.
            x = x(:);
            y = y(:);
            n = max(numel(x), numel(y));
            if numel(x) < n, x(n) = 0; end
            if numel(y) < n, y(n) = 0; end

            nfft = 2^nextpow2(2*n - 1);
            c = ifft(fft(x, nfft) .* conj(fft(y, nfft)), 'symmetric');
            xc = [c(end-n+2:end); c(1:n)];   % reorder to lags -(n-1):(n-1)

            denom = sqrt(sum(x.^2) * sum(y.^2));
            if denom == 0
                denom = eps;
            end
            xc = xc / denom;
            lags = -(n-1):(n-1);
        end
    end
end
