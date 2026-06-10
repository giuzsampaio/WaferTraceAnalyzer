classdef StateSegmenter < handle
    % StateSegmenter — Cluster segments into distinct states and compute fingerprints.
    %
    % Takes transition times from ChangePointDetector and the feature extractor,
    % computes a fingerprint for each segment, clusters similar segments, and
    % assigns provisional labels.
    %
    % Usage:
    %   ss = StateSegmenter(featureExtractor, transitionTimes, waferBounds);
    %   ss.segment();
    %   states = ss.states;  % struct array with name, tStart, tEnd, fingerprint, cluster

    properties
        fe                          % SignalFeatureExtractor
        transitionTimes double
        waferBounds     struct      % struct array with .tStart, .tEnd per wafer
        states          cell        % {wafer_idx} -> struct array of states
        clusters        struct      % Cluster info: centroids, members
        config          struct
    end

    methods
        function obj = StateSegmenter(featureExtractor, transitionTimes, waferBounds, config)
            if nargin < 4, config = struct(); end
            obj.fe = featureExtractor;
            obj.transitionTimes = transitionTimes;
            obj.waferBounds = waferBounds;
            obj.config = obj.buildConfig(config);
        end

        function segment(obj)
            % Main method: build segments per wafer, fingerprint each, cluster.

            nWafers = numel(obj.waferBounds);
            obj.states = cell(nWafers, 1);

            % Build segments per wafer
            allFingerprints = {};
            allSegmentRefs = {};  % {waferIdx, segmentIdx}

            for w = 1:nWafers
                wf = obj.waferBounds(w);

                % Get transitions within this wafer
                wTrans = obj.transitionTimes(obj.transitionTimes > wf.tStart & ...
                    obj.transitionTimes < wf.tEnd);

                % Build segment boundaries
                boundaries = [wf.tStart; wTrans(:); wf.tEnd];

                segments = struct('name', {}, 'tStart', {}, 'tEnd', {}, ...
                    'fingerprint', {}, 'cluster', {}, 'confidence', {}, ...
                    'detectedBy', {}, 'subPeriods', {});

                for s = 1:(numel(boundaries) - 1)
                    % Field order must match the segments template above
                    seg = struct();
                    seg.name = '';
                    seg.tStart = boundaries(s);
                    seg.tEnd = boundaries(s+1);
                    seg.fingerprint = [];
                    seg.cluster = 0;
                    seg.confidence = 0;
                    seg.detectedBy = 'state_discovery';
                    seg.subPeriods = [];

                    duration = seg.tEnd - seg.tStart;
                    if duration < obj.config.minSegmentDuration
                        continue;
                    end

                    % Compute fingerprint
                    seg.fingerprint = obj.fe.extractForSegment(seg.tStart, seg.tEnd);
                    seg.name = sprintf('state_%d', s);

                    segments(end+1) = seg; %#ok<AGROW>
                    allFingerprints{end+1} = seg.fingerprint; %#ok<AGROW>
                    allSegmentRefs{end+1} = [w, numel(segments)]; %#ok<AGROW>
                end

                obj.states{w} = segments;
            end

            % Cluster similar segments across all wafers
            if numel(allFingerprints) >= 2
                obj.clusterSegments(allFingerprints, allSegmentRefs);
            end
        end

        function mergeStates(obj, waferIdx, stateIdx1, stateIdx2)
            % Merge two adjacent states within a wafer.
            if stateIdx2 ~= stateIdx1 + 1
                warning('Can only merge adjacent states.');
                return;
            end

            s1 = obj.states{waferIdx}(stateIdx1);
            s2 = obj.states{waferIdx}(stateIdx2);

            merged = s1;
            merged.tEnd = s2.tEnd;
            merged.fingerprint = obj.fe.extractForSegment(merged.tStart, merged.tEnd);
            merged.name = s1.name;

            obj.states{waferIdx}(stateIdx1) = merged;
            obj.states{waferIdx}(stateIdx2) = [];
        end

        function splitState(obj, waferIdx, stateIdx, splitTime)
            % Split a state at a specific time point.
            s = obj.states{waferIdx}(stateIdx);

            if splitTime <= s.tStart || splitTime >= s.tEnd
                warning('Split time must be within state boundaries.');
                return;
            end

            s1 = s;
            s1.tEnd = splitTime;
            s1.fingerprint = obj.fe.extractForSegment(s1.tStart, s1.tEnd);
            s1.name = [s.name '_a'];

            s2 = s;
            s2.tStart = splitTime;
            s2.fingerprint = obj.fe.extractForSegment(s2.tStart, s2.tEnd);
            s2.name = [s.name '_b'];

            % Replace original with two new states
            before = obj.states{waferIdx}(1:stateIdx-1);
            after = obj.states{waferIdx}(stateIdx+1:end);
            obj.states{waferIdx} = [before, s1, s2, after];
        end
    end

    methods (Access = private)
        function cfg = buildConfig(~, userConfig)
            cfg.minSegmentDuration = 0.3;   % seconds
            cfg.clusterThreshold = 0.35;    % max distance for same cluster
            cfg.maxClusters = 20;           % sanity limit

            if ~isempty(fieldnames(userConfig))
                fns = fieldnames(userConfig);
                for i = 1:numel(fns)
                    cfg.(fns{i}) = userConfig.(fns{i});
                end
            end
        end

        function clusterSegments(obj, fingerprints, segmentRefs)
            % Agglomerative clustering of segments based on fingerprint distance.

            N = numel(fingerprints);
            if N == 0, return; end

            % Convert fingerprints to feature vectors
            vectors = obj.fingerprintsToVectors(fingerprints);
            nDims = size(vectors, 2);

            if nDims == 0, return; end

            % Compute pairwise distance matrix
            distMatrix = zeros(N);
            for i = 1:N
                for j = (i+1):N
                    d = obj.fingerprintDistance(vectors(i,:), vectors(j,:));
                    distMatrix(i,j) = d;
                    distMatrix(j,i) = d;
                end
            end

            % Simple agglomerative clustering
            clusterLabels = (1:N)';
            nextLabel = N + 1;

            while true
                % Find closest pair of different clusters
                minDist = inf;
                mergeI = 0;
                mergeJ = 0;

                uniqueClusters = unique(clusterLabels);
                if numel(uniqueClusters) <= 1, break; end

                for ci = 1:numel(uniqueClusters)
                    for cj = (ci+1):numel(uniqueClusters)
                        membersI = find(clusterLabels == uniqueClusters(ci));
                        membersJ = find(clusterLabels == uniqueClusters(cj));

                        % Average linkage
                        totalDist = 0;
                        count = 0;
                        for mi = 1:numel(membersI)
                            for mj = 1:numel(membersJ)
                                totalDist = totalDist + distMatrix(membersI(mi), membersJ(mj));
                                count = count + 1;
                            end
                        end
                        avgDist = totalDist / max(count, 1);

                        if avgDist < minDist
                            minDist = avgDist;
                            mergeI = uniqueClusters(ci);
                            mergeJ = uniqueClusters(cj);
                        end
                    end
                end

                if minDist > obj.config.clusterThreshold
                    break; % No more merges below threshold
                end

                % Merge clusters
                clusterLabels(clusterLabels == mergeJ) = mergeI;
            end

            % Renumber clusters sequentially
            uniqueClusters = unique(clusterLabels);
            clusterMap = containers.Map('KeyType', 'int32', 'ValueType', 'int32');
            for i = 1:numel(uniqueClusters)
                clusterMap(int32(uniqueClusters(i))) = int32(i);
            end

            % Apply cluster labels back to states
            for i = 1:N
                ref = segmentRefs{i};
                wIdx = ref(1);
                sIdx = ref(2);
                cLabel = clusterMap(int32(clusterLabels(i)));
                obj.states{wIdx}(sIdx).cluster = cLabel;
                obj.states{wIdx}(sIdx).name = sprintf('state_%d', cLabel);
            end

            % Store cluster info
            obj.clusters = struct();
            for c = 1:numel(uniqueClusters)
                cLabel = clusterMap(int32(uniqueClusters(c)));
                members = find(clusterLabels == uniqueClusters(c));
                centroid = mean(vectors(members, :), 1);
                obj.clusters(cLabel).label = cLabel;
                obj.clusters(cLabel).centroid = centroid;
                obj.clusters(cLabel).memberCount = numel(members);
            end
        end

        function vectors = fingerprintsToVectors(~, fingerprints)
            % Convert struct fingerprints to numeric vectors.
            % Consistent ordering: sort categories alphabetically,
            % then [level, activity, trend, variability, shape] per category.

            % Find all categories across all fingerprints
            allCats = {};
            for i = 1:numel(fingerprints)
                fp = fingerprints{i};
                if ~isempty(fp) && isstruct(fp)
                    allCats = [allCats, fieldnames(fp)']; %#ok<AGROW>
                end
            end
            allCats = unique(allCats);

            if isempty(allCats)
                vectors = zeros(numel(fingerprints), 0);
                return;
            end

            nFeatPerCat = 5; % level, activity, trend, variability, shape
            nDims = numel(allCats) * nFeatPerCat;
            vectors = NaN(numel(fingerprints), nDims);

            for i = 1:numel(fingerprints)
                fp = fingerprints{i};
                if isempty(fp) || ~isstruct(fp), continue; end

                for c = 1:numel(allCats)
                    offset = (c-1) * nFeatPerCat;
                    if isfield(fp, allCats{c})
                        catFP = fp.(allCats{c});
                        vectors(i, offset+1) = catFP.level;
                        vectors(i, offset+2) = catFP.activity;
                        vectors(i, offset+3) = catFP.trend;
                        vectors(i, offset+4) = catFP.variability;
                        vectors(i, offset+5) = catFP.shape / 5; % normalize to [0,1]
                    end
                end
            end

            % Replace NaN with 0 for missing categories
            vectors(isnan(vectors)) = 0;
        end

        function d = fingerprintDistance(~, v1, v2)
            % Weighted Euclidean distance between two fingerprint vectors.
            % Within each 5-feature block: activity(3), shape(3), level(2), trend(1), variability(1)

            nFeatPerCat = 5;
            nCats = numel(v1) / nFeatPerCat;
            featureWeights = [2, 3, 1, 1, 3]; % level, activity, trend, variability, shape

            totalDist = 0;
            totalWeight = 0;

            for c = 1:nCats
                offset = (c-1) * nFeatPerCat;
                for f = 1:nFeatPerCat
                    diff_val = v1(offset+f) - v2(offset+f);
                    w = featureWeights(f);
                    totalDist = totalDist + w * diff_val^2;
                    totalWeight = totalWeight + w;
                end
            end

            d = sqrt(totalDist / max(totalWeight, 1));
        end
    end
end
