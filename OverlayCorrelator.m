classdef OverlayCorrelator < handle
    % OverlayCorrelator — Correlate thermal signatures with overlay results.
    %
    % This is the bridge between thermal trace analysis and overlay impact.
    % It builds regression models between thermal features (drift, transients,
    % coupling) and overlay metrics (mean, 3sigma, specific Zernike terms).
    %
    % Usage:
    %   oc = OverlayCorrelator(knowledgeBase);
    %   oc.correlate(traceResults, 'overlay.mat');
    %   oc.predictOverlayImpact(newTraceResults);

    properties
        kb                              % KnowledgeBase
        models          struct          % Trained correlation models
        featureNames    cell            % Names of thermal features used
    end

    methods
        function obj = OverlayCorrelator(kb)
            obj.kb = kb;
            obj.models = struct();
            obj.featureNames = {};
        end

        function correlate(obj, traceResults, overlayFile)
            % Build correlation models between thermal features and overlay.
            %
            % overlayFile should be a .mat with overlay data structured as:
            %   overlay.wafer(w).x, .y, .dx, .dy  (per-field overlay vectors)
            %   or overlay.wafer(w).mean_x, .mean_y, .sigma3_x, .sigma3_y

            fprintf('  Loading overlay data: %s\n', overlayFile);
            ovData = load(overlayFile);

            % Extract thermal features per wafer
            if ~iscell(traceResults)
                traceResults = {traceResults};
            end

            [features, featureNames] = obj.extractThermalFeatures(traceResults);
            obj.featureNames = featureNames;

            % Extract overlay metrics per wafer
            overlayMetrics = obj.extractOverlayMetrics(ovData);

            % Match wafers between traces and overlay
            nWafers = min(size(features, 1), size(overlayMetrics, 1));
            if nWafers < 3
                fprintf('  Need at least 3 wafers for correlation. Got %d.\n', nWafers);
                return;
            end

            features = features(1:nWafers, :);
            overlayMetrics = overlayMetrics(1:nWafers, :);

            % Build regression models for each overlay metric
            metricNames = {'mean_dx', 'mean_dy', 'sigma3_dx', 'sigma3_dy'};
            for m = 1:size(overlayMetrics, 2)
                if m <= numel(metricNames)
                    mName = metricNames{m};
                else
                    mName = sprintf('metric_%d', m);
                end

                y = overlayMetrics(:, m);
                if all(isnan(y)), continue; end

                validMask = ~any(isnan(features), 2) & ~isnan(y);
                X = features(validMask, :);
                y = y(validMask);

                if size(X, 1) < 3, continue; end

                % Stepwise regression to find significant thermal predictors
                mdl = obj.fitStepwiseModel(X, y, featureNames);

                obj.models.(matlab.lang.makeValidName(mName)) = mdl;

                fprintf('  %s: R²=%.3f, significant features: %s\n', ...
                    mName, mdl.Rsquared, strjoin(mdl.significantFeatures, ', '));
            end

            % Store models in knowledge base
            obj.kb.overlayModels = obj.models;

            % Generate insights
            obj.generateOverlayInsights();
        end

        function predictions = predictOverlayImpact(obj, traceResults)
            % Use trained models to predict overlay impact from thermal features.
            if isempty(fieldnames(obj.models))
                fprintf('  No overlay models trained yet. Run correlate() first.\n');
                predictions = struct();
                return;
            end

            [features, ~] = obj.extractThermalFeatures(traceResults);

            modelNames = fieldnames(obj.models);
            predictions = struct();
            for m = 1:numel(modelNames)
                mdl = obj.models.(modelNames{m});
                featureIdx = mdl.featureIdx;
                X = features(:, featureIdx);
                yPred = X * mdl.coefficients(2:end) + mdl.coefficients(1);
                predictions.(modelNames{m}) = struct(...
                    'predicted', yPred, ...
                    'confidence', mdl.Rsquared);
            end
        end
    end

    methods (Access = private)
        function [features, featureNames] = extractThermalFeatures(~, traceResults)
            % Extract a feature matrix from trace results.
            % Each row = one wafer, each column = one thermal feature.
            %
            % Features include:
            %   - Mean temperature per sensor per period
            %   - Drift rate per sensor per period
            %   - Settling time per sensor per period
            %   - Heater mean power per period

            if ~iscell(traceResults)
                traceResults = {traceResults};
            end

            % Discover all possible features from the first result
            r = traceResults{1};
            featureNames = {};
            nWafers = r.numWafers;

            % First pass: build feature name list
            for w = 1:min(1, nWafers)
                if isempty(r.thermalResults) || w > numel(r.thermalResults)
                    continue;
                end
                tr = r.thermalResults{w};
                periods = fieldnames(tr);
                for p = 1:numel(periods)
                    pData = tr.(periods{p});
                    % Temperature features
                    if isfield(pData, 'temperature')
                        sensors = fieldnames(pData.temperature);
                        for s = 1:numel(sensors)
                            featureNames{end+1} = sprintf('%s_%s_mean', periods{p}, sensors{s}); %#ok<AGROW>
                            featureNames{end+1} = sprintf('%s_%s_drift', periods{p}, sensors{s}); %#ok<AGROW>
                            featureNames{end+1} = sprintf('%s_%s_range', periods{p}, sensors{s}); %#ok<AGROW>
                        end
                    end
                    % Heater features
                    if isfield(pData, 'heater')
                        heaters = fieldnames(pData.heater);
                        for h = 1:numel(heaters)
                            featureNames{end+1} = sprintf('%s_%s_mean', periods{p}, heaters{h}); %#ok<AGROW>
                        end
                    end
                    % Transient features
                    if isfield(pData, 'transients')
                        tNames = fieldnames(pData.transients);
                        for t = 1:numel(tNames)
                            featureNames{end+1} = sprintf('%s_%s_settleTime', periods{p}, tNames{t}); %#ok<AGROW>
                        end
                    end
                end
            end

            % Second pass: extract features for all wafers
            nFeatures = numel(featureNames);
            features = NaN(nWafers, nFeatures);

            for w = 1:nWafers
                if w > numel(r.thermalResults) || isempty(r.thermalResults{w})
                    continue;
                end
                tr = r.thermalResults{w};
                fIdx = 0;
                periods = fieldnames(tr);
                for p = 1:numel(periods)
                    pData = tr.(periods{p});
                    if isfield(pData, 'temperature')
                        sensors = fieldnames(pData.temperature);
                        for s = 1:numel(sensors)
                            fIdx = fIdx + 1;
                            features(w, fIdx) = pData.temperature.(sensors{s}).mean;
                            fIdx = fIdx + 1;
                            features(w, fIdx) = pData.temperature.(sensors{s}).driftRate;
                            fIdx = fIdx + 1;
                            features(w, fIdx) = pData.temperature.(sensors{s}).range;
                        end
                    end
                    if isfield(pData, 'heater')
                        heaters = fieldnames(pData.heater);
                        for h = 1:numel(heaters)
                            fIdx = fIdx + 1;
                            features(w, fIdx) = pData.heater.(heaters{h}).mean;
                        end
                    end
                    if isfield(pData, 'transients')
                        tNames = fieldnames(pData.transients);
                        for t = 1:numel(tNames)
                            fIdx = fIdx + 1;
                            features(w, fIdx) = pData.transients.(tNames{t}).settlingTime;
                        end
                    end
                end
            end
        end

        function metrics = extractOverlayMetrics(~, ovData)
            % Extract overlay metrics from loaded overlay data.
            % Flexible: handles multiple common formats.

            metrics = [];

            % Try common field names
            if isfield(ovData, 'overlay')
                ov = ovData.overlay;
            elseif isfield(ovData, 'ovl')
                ov = ovData.ovl;
            else
                fns = fieldnames(ovData);
                ov = ovData.(fns{1});
            end

            if isstruct(ov) && isfield(ov, 'wafer')
                nWafers = numel(ov.wafer);
                metrics = NaN(nWafers, 4); % [mean_dx, mean_dy, sigma3_dx, sigma3_dy]

                for w = 1:nWafers
                    wf = ov.wafer(w);
                    if isfield(wf, 'mean_dx')
                        metrics(w, 1) = wf.mean_dx;
                        metrics(w, 2) = wf.mean_dy;
                        if isfield(wf, 'sigma3_dx')
                            metrics(w, 3) = wf.sigma3_dx;
                            metrics(w, 4) = wf.sigma3_dy;
                        end
                    elseif isfield(wf, 'dx') && isfield(wf, 'dy')
                        metrics(w, 1) = mean(wf.dx, 'omitnan');
                        metrics(w, 2) = mean(wf.dy, 'omitnan');
                        metrics(w, 3) = 3 * std(wf.dx, 'omitnan');
                        metrics(w, 4) = 3 * std(wf.dy, 'omitnan');
                    end
                end
            elseif ismatrix(ov)
                % Assume matrix format: rows=wafers, cols=metrics
                metrics = ov;
            end
        end

        function mdl = fitStepwiseModel(~, X, y, featureNames)
            % Simple forward stepwise regression.
            nFeatures = size(X, 2);
            nObs = size(X, 1);

            % Start with intercept-only model
            selectedIdx = [];
            bestRsq = 0;

            for step = 1:min(nFeatures, floor(nObs/3))
                bestNewIdx = 0;
                bestNewRsq = bestRsq;

                for f = 1:nFeatures
                    if ismember(f, selectedIdx), continue; end

                    testIdx = [selectedIdx, f];
                    Xtest = [ones(nObs, 1), X(:, testIdx)];

                    % Check for rank deficiency
                    if rank(Xtest) < size(Xtest, 2), continue; end

                    b = Xtest \ y;
                    yHat = Xtest * b;
                    ssRes = sum((y - yHat).^2);
                    ssTot = sum((y - mean(y)).^2);
                    rsq = 1 - ssRes / max(ssTot, 1e-12);

                    % Adjusted R² (penalize extra features)
                    rsqAdj = 1 - (1 - rsq) * (nObs - 1) / max(nObs - numel(testIdx) - 1, 1);

                    if rsqAdj > bestNewRsq + 0.02 % Require meaningful improvement
                        bestNewRsq = rsqAdj;
                        bestNewIdx = f;
                    end
                end

                if bestNewIdx > 0
                    selectedIdx(end+1) = bestNewIdx; %#ok<AGROW>
                    bestRsq = bestNewRsq;
                else
                    break;
                end
            end

            % Final model
            if isempty(selectedIdx)
                mdl = struct('coefficients', mean(y), 'featureIdx', [], ...
                    'significantFeatures', {{'(none)'}}, 'Rsquared', 0);
            else
                Xfinal = [ones(nObs, 1), X(:, selectedIdx)];
                b = Xfinal \ y;
                yHat = Xfinal * b;
                ssRes = sum((y - yHat).^2);
                ssTot = sum((y - mean(y)).^2);
                rsq = 1 - ssRes / max(ssTot, 1e-12);

                mdl = struct('coefficients', b, 'featureIdx', selectedIdx, ...
                    'significantFeatures', {featureNames(selectedIdx)}, ...
                    'Rsquared', rsq);
            end
        end

        function generateOverlayInsights(obj)
            % Generate human-readable insights about thermal→overlay relationships.
            modelNames = fieldnames(obj.models);
            insights = {};

            for m = 1:numel(modelNames)
                mdl = obj.models.(modelNames{m});
                if mdl.Rsquared > 0.5
                    insights{end+1} = sprintf('Strong thermal predictor of %s (R²=%.2f): %s', ...
                        modelNames{m}, mdl.Rsquared, ...
                        strjoin(mdl.significantFeatures, ' + ')); %#ok<AGROW>
                end
            end

            if ~isempty(insights)
                fprintf('\n  Overlay-Thermal Insights:\n');
                for i = 1:numel(insights)
                    fprintf('    %d. %s\n', i, insights{i});
                end

                % Add to world model
                existingInsights = obj.kb.worldModel.insights;
                obj.kb.worldModel.insights = [existingInsights, insights];
            end
        end
    end
end
