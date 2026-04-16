classdef KnowledgeBase < handle
    % KnowledgeBase — Persistent learning system for wafer trace analysis.
    %
    % Stores analysis results, learned signal patterns, thermal norms, and
    % anomaly detection baselines. Each new analysis enriches the knowledge,
    % enabling:
    %   - Signal classification overrides (learned from user corrections)
    %   - Anomaly detection (deviations from historical norms)
    %   - Thermal fingerprinting (test similarity matching)
    %   - Wafer-over-wafer trend understanding
    %   - Eventually: overlay correlation models
    %
    % Data is stored as .mat files in a dedicated directory.

    properties
        kbDir           char                % Path to knowledge base directory
        analyses        struct              % Array of analysis entries
        signalOverrides struct              % User corrections to signal classification
        thermalNorms    struct              % Running statistics for thermal behavior
        periodNorms     struct              % Normal period durations/sequences
        overlayModels   struct              % Learned overlay correlation models
        worldModel      struct              % The system's "understanding of the world"
        stateLibrary    StateLibrary        % Persistent state fingerprint store (v2)
    end

    methods
        function obj = KnowledgeBase(kbDir)
            obj.kbDir = kbDir;
            if ~exist(kbDir, 'dir')
                mkdir(kbDir);
            end
            obj.load();
            obj.stateLibrary = StateLibrary(kbDir);
        end

        function n = getAnalysisCount(obj)
            if isempty(obj.analyses)
                n = 0;
            else
                n = numel(obj.analyses);
            end
        end

        function addAnalysis(obj, entry)
            % Add a new analysis entry and update norms.
            if isempty(obj.analyses)
                obj.analyses = entry;
            else
                obj.analyses(end+1) = entry;
            end

            % Update thermal norms
            obj.updateThermalNorms(entry);

            % Update period norms
            obj.updatePeriodNorms(entry);

            % Update world model
            obj.updateWorldModel(entry);

            % Recognize test type via state library
            if ~isempty(entry.periodNames) && ~isempty(obj.stateLibrary)
                [ttName, ttConf] = obj.stateLibrary.matchTestType(entry.periodNames);
                if ttConf >= 0.8
                    fprintf('  Test type recognized: "%s" (%.0f%% match)\n', ttName, ttConf*100);
                end
            end

            % Persist
            obj.save();
        end

        function anomalies = detectAnomalies(obj, entry)
            % Compare this analysis against historical norms.
            % Returns cell array of anomaly description strings.
            anomalies = {};

            if obj.getAnalysisCount() < 3
                return; % Need at least 3 prior analyses for baselines
            end

            % Check wafer count anomaly
            historicalCounts = [obj.analyses(1:end-1).numWafers];
            meanCount = mean(historicalCounts);
            stdCount = max(std(historicalCounts), 1);
            if abs(entry.numWafers - meanCount) > 2 * stdCount
                anomalies{end+1} = sprintf('Unusual wafer count: %d (norm: %.0f +/- %.0f)', ...
                    entry.numWafers, meanCount, stdCount);
            end

            % Check wafer duration anomaly
            if ~isempty(entry.waferDurations)
                meanDur = mean(entry.waferDurations);
                historicalDurs = [];
                for i = 1:numel(obj.analyses)-1
                    if isfield(obj.analyses(i), 'waferDurations')
                        historicalDurs = [historicalDurs, obj.analyses(i).waferDurations]; %#ok<AGROW>
                    end
                end
                if ~isempty(historicalDurs)
                    normMean = mean(historicalDurs);
                    normStd = max(std(historicalDurs), 0.1);
                    if abs(meanDur - normMean) > 3 * normStd
                        anomalies{end+1} = sprintf('Unusual wafer duration: %.1fs (norm: %.1f +/- %.1f)', ...
                            meanDur, normMean, normStd);
                    end
                end
            end

            % Check thermal fingerprint anomaly
            if isfield(entry, 'thermalFingerprint') && ~isempty(fieldnames(entry.thermalFingerprint))
                fp = entry.thermalFingerprint;
                sensorNames = fieldnames(fp);
                for s = 1:numel(sensorNames)
                    sn = sensorNames{s};
                    if isfield(obj.thermalNorms, sn)
                        norm = obj.thermalNorms.(sn);
                        currMean = fp.(sn).globalMean;
                        if abs(currMean - norm.meanOfMeans) > 3 * max(norm.stdOfMeans, 0.01)
                            anomalies{end+1} = sprintf('Thermal anomaly in %s: mean=%.3f (norm: %.3f +/- %.3f)', ...
                                sn, currMean, norm.meanOfMeans, norm.stdOfMeans); %#ok<AGROW>
                        end
                    end
                end
            end

            % Check period sequence anomaly
            if isfield(entry, 'periodNames')
                if isfield(obj.periodNorms, 'commonSequence') && ~isempty(obj.periodNorms.commonSequence)
                    if ~isequal(sort(entry.periodNames), sort(obj.periodNorms.commonSequence))
                        anomalies{end+1} = sprintf('Unusual period set: {%s} vs norm {%s}', ...
                            strjoin(entry.periodNames, ','), ...
                            strjoin(obj.periodNorms.commonSequence, ','));
                    end
                end
            end
        end

        function discovered = applySignalOverrides(obj, discovered)
            % Apply user-corrected signal classifications.
            if isempty(fieldnames(obj.signalOverrides))
                return;
            end
            for i = 1:numel(discovered)
                nm = discovered(i).name;
                if isfield(obj.signalOverrides, matlab.lang.makeValidName(nm))
                    discovered(i).category = obj.signalOverrides.(matlab.lang.makeValidName(nm));
                end
            end
        end

        function correctSignalCategory(obj, signalName, correctCategory)
            % User correction: remember that this signal is a specific category.
            obj.signalOverrides.(matlab.lang.makeValidName(signalName)) = correctCategory;
            obj.save();
            fprintf('  Knowledge base updated: "%s" → category "%s"\n', signalName, correctCategory);
        end

        function synthesize(obj)
            % Cross-test synthesis: identify patterns across all stored analyses.
            fprintf('  Synthesizing knowledge across %d analyses...\n', obj.getAnalysisCount());

            if obj.getAnalysisCount() < 2
                return;
            end

            % Update world model with cross-test insights
            obj.updateWorldModel([]);
            obj.save();
        end

        function printWorldModel(obj)
            % Print the system's current understanding of the physical world.
            wm = obj.worldModel;
            fprintf('\n=== World Model ===\n');

            if isfield(wm, 'thermalCoupling') && ~isempty(fieldnames(wm.thermalCoupling))
                fprintf('\nThermal Coupling (heater → sensor):\n');
                pairs = fieldnames(wm.thermalCoupling);
                for i = 1:numel(pairs)
                    cp = wm.thermalCoupling.(pairs{i});
                    fprintf('  %s → %s: correlation=%.3f, delay=%.2fs\n', ...
                        cp.heater, cp.sensor, cp.avgCorrelation, cp.avgDelay);
                end
            end

            if isfield(wm, 'periodThermalSignatures') && ~isempty(fieldnames(wm.periodThermalSignatures))
                fprintf('\nPeriod Thermal Signatures:\n');
                periods = fieldnames(wm.periodThermalSignatures);
                for p = 1:numel(periods)
                    sig = wm.periodThermalSignatures.(periods{p});
                    fprintf('  [%s]:\n', periods{p});
                    if isfield(sig, 'characterization')
                        fprintf('    %s\n', sig.characterization);
                    end
                    if isfield(sig, 'typicalDriftRate')
                        fprintf('    Typical drift rate: %.2e/s\n', sig.typicalDriftRate);
                    end
                end
            end

            if isfield(wm, 'waferThermalEvolution')
                fprintf('\nWafer-over-Wafer Thermal Evolution:\n');
                fprintf('  %s\n', wm.waferThermalEvolution);
            end

            if isfield(wm, 'insights') && ~isempty(wm.insights)
                fprintf('\nLearned Insights:\n');
                for i = 1:numel(wm.insights)
                    fprintf('  %d. %s\n', i, wm.insights{i});
                end
            end

            fprintf('\n');
        end

        function printFullStatus(obj)
            % Print complete status of knowledge base and state library.
            fprintf('\n=== Knowledge Base Status ===\n');
            fprintf('  Analyses stored: %d\n', obj.getAnalysisCount());
            fprintf('  Signal overrides: %d\n', numel(fieldnames(obj.signalOverrides)));

            if ~isempty(obj.stateLibrary)
                fprintf('  Known states: %d\n', obj.stateLibrary.getStateCount());
                fprintf('  Known test types: %d\n', obj.stateLibrary.getTestTypeCount());
                obj.stateLibrary.printLibrary();
            end

            obj.printWorldModel();
        end

        function queryKnowledge(obj, question)
            % Natural-language-ish query interface for the knowledge base.
            % Supports keywords: "thermal", "drift", "coupling", "anomaly",
            % "period", "expose", "load", "history"

            q = lower(question);

            if contains(q, 'coupling') || contains(q, 'transfer')
                obj.printWorldModel();
                return;
            end

            if contains(q, 'drift') || contains(q, 'trend')
                obj.reportDriftTrends();
                return;
            end

            if contains(q, 'anomal')
                obj.reportHistoricalAnomalies();
                return;
            end

            if contains(q, 'histor') || contains(q, 'summary')
                obj.reportHistory();
                return;
            end

            % Default: print world model
            obj.printWorldModel();
        end
    end

    methods (Access = private)
        function load(obj)
            kbFile = fullfile(obj.kbDir, 'knowledge_base.mat');
            if exist(kbFile, 'file')
                data = load(kbFile);
                if isfield(data, 'analyses'), obj.analyses = data.analyses; end
                if isfield(data, 'signalOverrides'), obj.signalOverrides = data.signalOverrides; end
                if isfield(data, 'thermalNorms'), obj.thermalNorms = data.thermalNorms; end
                if isfield(data, 'periodNorms'), obj.periodNorms = data.periodNorms; end
                if isfield(data, 'overlayModels'), obj.overlayModels = data.overlayModels; end
                if isfield(data, 'worldModel'), obj.worldModel = data.worldModel; end
            else
                obj.analyses = struct([]);
                obj.signalOverrides = struct();
                obj.thermalNorms = struct();
                obj.periodNorms = struct();
                obj.overlayModels = struct();
                obj.worldModel = struct('thermalCoupling', struct(), ...
                    'periodThermalSignatures', struct(), ...
                    'waferThermalEvolution', '', ...
                    'insights', {{}});
            end
        end

        function save(obj)
            analyses = obj.analyses; %#ok<PROP,NASGU>
            signalOverrides = obj.signalOverrides; %#ok<PROP,NASGU>
            thermalNorms = obj.thermalNorms; %#ok<PROP,NASGU>
            periodNorms = obj.periodNorms; %#ok<PROP,NASGU>
            overlayModels = obj.overlayModels; %#ok<PROP,NASGU>
            worldModel = obj.worldModel; %#ok<PROP,NASGU>

            kbFile = fullfile(obj.kbDir, 'knowledge_base.mat');
            save(kbFile, 'analyses', 'signalOverrides', 'thermalNorms', ...
                'periodNorms', 'overlayModels', 'worldModel', '-v7.3');
        end

        function updateThermalNorms(obj, entry)
            % Update running statistics of thermal behavior.
            if ~isfield(entry, 'thermalFingerprint') || isempty(fieldnames(entry.thermalFingerprint))
                return;
            end
            fp = entry.thermalFingerprint;
            sensors = fieldnames(fp);
            for s = 1:numel(sensors)
                sn = sensors{s};
                curr = fp.(sn);
                if ~isfield(obj.thermalNorms, sn)
                    obj.thermalNorms.(sn) = struct(...
                        'meanOfMeans', curr.globalMean, ...
                        'stdOfMeans', 0, ...
                        'allMeans', curr.globalMean, ...
                        'count', 1);
                else
                    norm = obj.thermalNorms.(sn);
                    norm.allMeans(end+1) = curr.globalMean;
                    norm.count = norm.count + 1;
                    norm.meanOfMeans = mean(norm.allMeans);
                    norm.stdOfMeans = std(norm.allMeans);
                    obj.thermalNorms.(sn) = norm;
                end
            end
        end

        function updatePeriodNorms(obj, entry)
            % Track what period sequences are normal.
            if ~isfield(entry, 'periodNames'), return; end

            if ~isfield(obj.periodNorms, 'sequences')
                obj.periodNorms.sequences = {};
                obj.periodNorms.commonSequence = {};
            end

            obj.periodNorms.sequences{end+1} = sort(entry.periodNames);

            % Find most common sequence
            seqStrs = cellfun(@(x) strjoin(x, ','), obj.periodNorms.sequences, 'Uni', false);
            [uniqueSeqs, ~, ic] = unique(seqStrs);
            counts = accumarray(ic, 1);
            [~, maxIdx] = max(counts);
            obj.periodNorms.commonSequence = strsplit(uniqueSeqs{maxIdx}, ',');
        end

        function updateWorldModel(obj, entry)
            % Build up the system's understanding of the physical world.
            wm = obj.worldModel;

            % Update thermal coupling knowledge from cross-correlations
            if ~isempty(entry) && isfield(entry, 'periodAggregates')
                periods = fieldnames(entry.periodAggregates);
                for p = 1:numel(periods)
                    pName = periods{p};
                    % Store period thermal signature
                    if isfield(entry.periodAggregates.(pName), 'temperature')
                        tempAgg = entry.periodAggregates.(pName).temperature;
                        sensors = fieldnames(tempAgg);
                        for s = 1:numel(sensors)
                            sigKey = sprintf('%s_%s', pName, sensors{s});
                            if ~isfield(wm.periodThermalSignatures, sigKey)
                                wm.periodThermalSignatures.(sigKey) = struct();
                            end
                            wm.periodThermalSignatures.(sigKey).meanTemp = tempAgg.(sensors{s}).meanOfMeans;
                            wm.periodThermalSignatures.(sigKey).spread = tempAgg.(sensors{s}).stdOfMeans;
                        end
                    end
                end
            end

            % Generate insights from accumulated knowledge
            if obj.getAnalysisCount() >= 3
                wm.insights = obj.generateInsights();
            end

            % Characterize wafer-over-wafer evolution
            if obj.getAnalysisCount() >= 2
                wm.waferThermalEvolution = obj.characterizeWaferEvolution();
            end

            obj.worldModel = wm;
        end

        function insights = generateInsights(obj)
            % Auto-generate insights from accumulated data.
            insights = {};

            % Insight: thermal stability across tests
            sensors = fieldnames(obj.thermalNorms);
            for s = 1:numel(sensors)
                norm = obj.thermalNorms.(sensors{s});
                if norm.count >= 3
                    cv = norm.stdOfMeans / max(abs(norm.meanOfMeans), 1e-6);
                    if cv < 0.01
                        insights{end+1} = sprintf('%s is thermally stable across tests (CV=%.2f%%)', ...
                            sensors{s}, cv*100); %#ok<AGROW>
                    elseif cv > 0.05
                        insights{end+1} = sprintf('%s shows significant thermal variation across tests (CV=%.1f%%)', ...
                            sensors{s}, cv*100); %#ok<AGROW>
                    end
                end
            end

            % Insight: period consistency
            if isfield(obj.periodNorms, 'sequences') && numel(obj.periodNorms.sequences) >= 3
                seqStrs = cellfun(@(x) strjoin(x, ','), obj.periodNorms.sequences, 'Uni', false);
                uniqueSeqs = unique(seqStrs);
                if numel(uniqueSeqs) == 1
                    insights{end+1} = 'All tests show identical period sequences — highly consistent process.';
                else
                    insights{end+1} = sprintf('%d different period sequences observed across %d tests — check for process variations.', ...
                        numel(uniqueSeqs), numel(obj.periodNorms.sequences));
                end
            end

            % Insight: wafer count consistency
            if obj.getAnalysisCount() >= 3
                counts = [obj.analyses.numWafers];
                if all(counts == counts(1))
                    insights{end+1} = sprintf('All tests run exactly %d wafers.', counts(1));
                else
                    insights{end+1} = sprintf('Wafer counts vary: %d to %d (mean %.1f).', ...
                        min(counts), max(counts), mean(counts));
                end
            end
        end

        function desc = characterizeWaferEvolution(obj)
            % Describe how thermal behavior evolves wafer-over-wafer.
            if obj.getAnalysisCount() < 1
                desc = 'Insufficient data.';
                return;
            end

            % Use the latest analysis
            latest = obj.analyses(end);
            if ~isfield(latest, 'waferDurations') || numel(latest.waferDurations) < 3
                desc = 'Too few wafers for evolution analysis.';
                return;
            end

            durations = latest.waferDurations;
            p = polyfit(1:numel(durations), durations, 1);

            if abs(p(1)) < 0.1
                desc = sprintf('Wafer durations stable across lot (%.1fs +/- %.1fs).', ...
                    mean(durations), std(durations));
            elseif p(1) > 0
                desc = sprintf('Wafer durations increase through lot (trend: +%.2fs/wafer) — possible thermal drift.', p(1));
            else
                desc = sprintf('Wafer durations decrease through lot (trend: %.2fs/wafer) — thermal settling.', p(1));
            end
        end

        function reportDriftTrends(obj)
            fprintf('\n--- Drift Trends ---\n');
            if obj.getAnalysisCount() < 1
                fprintf('No analyses stored yet.\n');
                return;
            end
            sensors = fieldnames(obj.thermalNorms);
            for s = 1:numel(sensors)
                norm = obj.thermalNorms.(sensors{s});
                if norm.count >= 2
                    trend = diff(norm.allMeans);
                    fprintf('  %s: %d measurements, mean=%.4f, trend=%+.4f/test\n', ...
                        sensors{s}, norm.count, norm.meanOfMeans, mean(trend));
                end
            end
        end

        function reportHistoricalAnomalies(obj)
            fprintf('\n--- Historical Anomaly Review ---\n');
            if obj.getAnalysisCount() < 3
                fprintf('Need at least 3 analyses for anomaly detection.\n');
                return;
            end
            for i = 3:obj.getAnalysisCount()
                anomalies = obj.detectAnomalies(obj.analyses(i));
                if ~isempty(anomalies)
                    fprintf('  Analysis %d (%s):\n', i, obj.analyses(i).analysisID);
                    for a = 1:numel(anomalies)
                        fprintf('    - %s\n', anomalies{a});
                    end
                end
            end
        end

        function reportHistory(obj)
            fprintf('\n--- Analysis History ---\n');
            for i = 1:obj.getAnalysisCount()
                a = obj.analyses(i);
                fprintf('  %d. %s — %d wafers, periods: {%s}\n', ...
                    i, a.analysisID, a.numWafers, ...
                    strjoin(a.periodNames, ', '));
            end
        end
    end
end
