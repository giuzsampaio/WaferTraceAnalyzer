classdef StateLibrary < handle
    % StateLibrary — Persistent store of learned state fingerprints.
    %
    % When the user teaches the system ("this state is thermal_soak"),
    % the fingerprint is saved here. On future analyses, discovered states
    % are matched against the library for automatic labeling.
    %
    % Also stores test type templates (ordered state sequences).
    %
    % Usage:
    %   sl = StateLibrary('path/to/library');
    %   [name, confidence] = sl.match(fingerprint);
    %   sl.teach(fingerprint, 'thermal_soak');

    properties
        libDir          char
        entries         struct      % Array of {name, fingerprint, count, lastSeen}
        testTypes       struct      % Array of {name, stateSequence, count}
        matchWeights    double      % [level, activity, trend, variability, shape]
        autoLabelThreshold   double % Confidence above which auto-label is applied
        lowConfThreshold     double % Confidence above which low-conf label is applied
        emaAlpha        double      % Exponential moving average rate for fingerprint updates
    end

    methods
        function obj = StateLibrary(libDir)
            obj.libDir = libDir;
            obj.matchWeights = [2, 3, 1, 1, 3]; % level, activity, trend, variability, shape
            obj.autoLabelThreshold = 0.60;
            obj.lowConfThreshold = 0.40;
            obj.emaAlpha = 0.1;

            if ~exist(libDir, 'dir')
                mkdir(libDir);
            end
            obj.load();
        end

        function [name, confidence] = match(obj, fingerprint)
            % Match a fingerprint against the library.
            % Returns the best matching name and confidence, or {'unknown', 0}.

            name = 'unknown';
            confidence = 0;

            if isempty(obj.entries) || isempty(fieldnames(fingerprint))
                return;
            end

            bestDist = inf;
            bestIdx = 0;

            for i = 1:numel(obj.entries)
                d = obj.computeDistance(fingerprint, obj.entries(i).fingerprint);
                if d < bestDist
                    bestDist = d;
                    bestIdx = i;
                end
            end

            if bestIdx == 0, return; end

            % Convert distance to confidence (0 = no match, 1 = perfect)
            % Max meaningful distance is ~1.0 (fully different across all features)
            confidence = max(0, 1 - bestDist);

            if confidence >= obj.lowConfThreshold
                name = obj.entries(bestIdx).name;
            end
        end

        function teach(obj, fingerprint, name)
            % Save or update a fingerprint under the given name.

            existingIdx = obj.findByName(name);

            if existingIdx > 0
                % Update existing entry with EMA
                obj.entries(existingIdx).fingerprint = obj.emaUpdate(...
                    obj.entries(existingIdx).fingerprint, fingerprint);
                obj.entries(existingIdx).count = obj.entries(existingIdx).count + 1;
                obj.entries(existingIdx).lastSeen = datetime('now');
            else
                % New entry
                entry = struct();
                entry.name = name;
                entry.fingerprint = fingerprint;
                entry.count = 1;
                entry.firstSeen = datetime('now');
                entry.lastSeen = datetime('now');

                if isempty(obj.entries)
                    obj.entries = entry;
                else
                    obj.entries(end+1) = entry;
                end
            end

            obj.save();
        end

        function states = labelStates(obj, states)
            % Match all states in a cell array of per-wafer state structs.
            % Cell arrays are value types in MATLAB, so the labeled copy is
            % returned and the caller must reassign it.

            for w = 1:numel(states)
                for s = 1:numel(states{w})
                    fp = states{w}(s).fingerprint;
                    if isempty(fp) || ~isstruct(fp) || isempty(fieldnames(fp))
                        continue;
                    end

                    [name, conf] = obj.match(fp);

                    if conf >= obj.autoLabelThreshold
                        states{w}(s).name = name;
                        states{w}(s).confidence = conf;
                        states{w}(s).detectedBy = 'state_library';
                    elseif conf >= obj.lowConfThreshold
                        states{w}(s).name = [name '?'];
                        states{w}(s).confidence = conf;
                        states{w}(s).detectedBy = 'state_library_low_conf';
                    else
                        % Keep provisional name, mark as unknown
                        states{w}(s).confidence = conf;
                        states{w}(s).detectedBy = 'unmatched';
                    end
                end
            end
        end

        function [testTypeName, conf] = matchTestType(obj, stateSequence)
            % Match an ordered sequence of state names against known test types.
            testTypeName = 'unknown';
            conf = 0;

            if isempty(obj.testTypes)
                return;
            end

            for i = 1:numel(obj.testTypes)
                storedSeq = obj.testTypes(i).stateSequence;
                if isequal(stateSequence, storedSeq)
                    testTypeName = obj.testTypes(i).name;
                    conf = 1.0;
                    return;
                end

                % Partial match: check Jaccard similarity
                intersection = numel(intersect(stateSequence, storedSeq));
                union = numel(unique([stateSequence(:); storedSeq(:)]));
                jaccard = intersection / max(union, 1);
                if jaccard > conf
                    conf = jaccard;
                    testTypeName = obj.testTypes(i).name;
                end
            end

            if conf < 0.5
                testTypeName = 'unknown';
                conf = 0;
            end
        end

        function saveTestType(obj, stateSequence, name)
            % Save a test type template.
            existingIdx = 0;
            for i = 1:numel(obj.testTypes)
                if strcmp(obj.testTypes(i).name, name)
                    existingIdx = i;
                    break;
                end
            end

            if existingIdx > 0
                obj.testTypes(existingIdx).stateSequence = stateSequence;
                obj.testTypes(existingIdx).count = obj.testTypes(existingIdx).count + 1;
            else
                entry = struct();
                entry.name = name;
                entry.stateSequence = stateSequence;
                entry.count = 1;

                if isempty(obj.testTypes)
                    obj.testTypes = entry;
                else
                    obj.testTypes(end+1) = entry;
                end
            end

            obj.save();
        end

        function n = getStateCount(obj)
            if isempty(obj.entries)
                n = 0;
            else
                n = numel(obj.entries);
            end
        end

        function n = getTestTypeCount(obj)
            if isempty(obj.testTypes)
                n = 0;
            else
                n = numel(obj.testTypes);
            end
        end

        function printLibrary(obj)
            fprintf('\n--- State Library ---\n');
            fprintf('Known states: %d\n', obj.getStateCount());
            for i = 1:numel(obj.entries)
                e = obj.entries(i);
                cats = fieldnames(e.fingerprint);
                catStr = strjoin(cats, ', ');
                fprintf('  [%d] "%s" — seen %dx, categories: %s\n', ...
                    i, e.name, e.count, catStr);
            end
            fprintf('\nKnown test types: %d\n', obj.getTestTypeCount());
            for i = 1:numel(obj.testTypes)
                tt = obj.testTypes(i);
                fprintf('  [%d] "%s" — {%s} (seen %dx)\n', ...
                    i, tt.name, strjoin(tt.stateSequence, ' -> '), tt.count);
            end
        end
    end

    methods (Access = private)
        function load(obj)
            libFile = fullfile(obj.libDir, 'state_library.mat');
            if exist(libFile, 'file')
                data = load(libFile);
                if isfield(data, 'entries'), obj.entries = data.entries; end
                if isfield(data, 'testTypes'), obj.testTypes = data.testTypes; end
            else
                obj.entries = struct([]);
                obj.testTypes = struct([]);
            end
        end

        function save(obj)
            entries = obj.entries; %#ok<PROP,NASGU>
            testTypes = obj.testTypes; %#ok<PROP,NASGU>
            libFile = fullfile(obj.libDir, 'state_library.mat');
            save(libFile, 'entries', 'testTypes', '-v7.3');
        end

        function d = computeDistance(obj, fp1, fp2)
            % Weighted distance between two fingerprints (structs).
            cats1 = fieldnames(fp1);
            cats2 = fieldnames(fp2);
            allCats = unique([cats1; cats2]);

            totalDist = 0;
            totalWeight = 0;

            featureFields = {'level', 'activity', 'trend', 'variability', 'shape'};
            shapeNorm = 5; % max shape value

            for c = 1:numel(allCats)
                cat = allCats{c};
                has1 = isfield(fp1, cat);
                has2 = isfield(fp2, cat);

                if has1 && has2
                    f1 = fp1.(cat);
                    f2 = fp2.(cat);

                    for fi = 1:numel(featureFields)
                        fn = featureFields{fi};
                        if isfield(f1, fn) && isfield(f2, fn)
                            v1 = f1.(fn);
                            v2 = f2.(fn);
                            if strcmp(fn, 'shape')
                                v1 = v1 / shapeNorm;
                                v2 = v2 / shapeNorm;
                            end
                            w = obj.matchWeights(fi);
                            totalDist = totalDist + w * (v1 - v2)^2;
                            totalWeight = totalWeight + w;
                        end
                    end
                elseif has1 || has2
                    % One fingerprint has a category the other doesn't — penalize
                    totalDist = totalDist + sum(obj.matchWeights) * 0.5;
                    totalWeight = totalWeight + sum(obj.matchWeights);
                end
            end

            d = sqrt(totalDist / max(totalWeight, 1));
        end

        function idx = findByName(obj, name)
            idx = 0;
            for i = 1:numel(obj.entries)
                if strcmp(obj.entries(i).name, name)
                    idx = i;
                    return;
                end
            end
        end

        function updated = emaUpdate(obj, oldFP, newFP)
            % Exponential moving average update of a fingerprint.
            alpha = obj.emaAlpha;
            updated = oldFP;

            cats = fieldnames(newFP);
            for c = 1:numel(cats)
                cat = cats{c};
                if ~isfield(updated, cat)
                    updated.(cat) = newFP.(cat);
                    continue;
                end

                featureFields = {'level', 'activity', 'trend', 'variability'};
                for fi = 1:numel(featureFields)
                    fn = featureFields{fi};
                    if isfield(newFP.(cat), fn) && isfield(updated.(cat), fn)
                        updated.(cat).(fn) = (1 - alpha) * updated.(cat).(fn) + alpha * newFP.(cat).(fn);
                    end
                end

                % Shape: take mode (most common) — use new if different enough times
                if isfield(newFP.(cat), 'shape') && isfield(updated.(cat), 'shape')
                    if newFP.(cat).shape ~= updated.(cat).shape
                        % Only change shape if the new one is consistently different
                        % For now, keep old shape (conservative)
                    end
                end
            end
        end
    end
end
