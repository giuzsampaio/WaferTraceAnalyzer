%% analyzeTraces.m — Entry point for WaferTraceAnalyzer
%
% Usage:
%   analyzeTraces('path/to/traces.mat')
%   analyzeTraces('path/to/traces.mat', 'Interactive', true)   % teach mode
%   analyzeTraces('path/to/traces.mat', 'Explorer', true)      % GUI explorer
%   analyzeTraces('path/to/traces.mat', 'Legacy', true)        % V1 behavior
%   analyzeTraces({'file1.mat', 'file2.mat'})                  % batch mode
%
% This script:
%   1. Loads .mat file(s) and auto-discovers all signals
%   2. Classifies signals (position, temperature, heater, pressure, height)
%   3. Discovers states using bottom-up signal analysis (V2)
%      — or detects hardcoded periods in legacy mode
%   4. Matches states against learned fingerprints (teach-once learning)
%   5. Runs thermal analysis per (wafer, state)
%   6. Updates persistent knowledge base with learned patterns
%   7. Generates comprehensive reports and figures

function results = analyzeTraces(matFiles, varargin)
    p = inputParser;
    addRequired(p, 'matFiles');
    addParameter(p, 'KnowledgeDir', fullfile(fileparts(mfilename('fullpath')), 'knowledge'), @ischar);
    addParameter(p, 'OutputDir', '', @ischar);
    addParameter(p, 'SignalConfig', struct(), @isstruct);
    addParameter(p, 'Interactive', false, @islogical);
    addParameter(p, 'Explorer', false, @islogical);
    addParameter(p, 'Legacy', false, @islogical);
    addParameter(p, 'OverlayFile', '', @ischar);
    parse(p, matFiles, varargin{:});

    opts = p.Results;

    % Normalize to cell array
    if ischar(matFiles)
        matFiles = {matFiles};
    end

    % Initialize knowledge base
    kb = KnowledgeBase(opts.KnowledgeDir);
    fprintf('\n=== WaferTraceAnalyzer v2 ===\n');
    fprintf('Knowledge base: %s (%d analyses, %d known states, %d test types)\n', ...
        opts.KnowledgeDir, kb.getAnalysisCount(), ...
        kb.stateLibrary.getStateCount(), kb.stateLibrary.getTestTypeCount());

    if opts.Legacy
        fprintf('Mode: LEGACY (hardcoded period detection)\n');
    else
        fprintf('Mode: STATE DISCOVERY (bottom-up)\n');
    end

    allResults = cell(numel(matFiles), 1);

    for f = 1:numel(matFiles)
        fprintf('\n--- Analyzing: %s ---\n', matFiles{f});

        % Create analyzer for this file
        analyzer = WaferTraceAnalyzer(matFiles{f}, ...
            'KnowledgeBase', kb, ...
            'SignalConfig', opts.SignalConfig);

        analyzer.useStateDiscovery = ~opts.Legacy;

        % Step 1: Discover and classify signals
        fprintf('[1/5] Discovering signals...\n');
        analyzer.discoverSignals();
        analyzer.printSignalSummary();

        % Step 2: Detect wafer boundaries
        fprintf('[2/5] Detecting wafer boundaries...\n');
        analyzer.detectWaferBoundaries();
        fprintf('  Found %d wafers\n', analyzer.numWafers);

        % Step 3: Detect states / time periods
        if opts.Legacy
            fprintf('[3/5] Detecting time periods (legacy)...\n');
        else
            fprintf('[3/5] Discovering states...\n');
        end
        analyzer.detectTimePeriods();

        % Report discovered states
        nUnknown = 0;
        for w = 1:analyzer.numWafers
            for s = 1:numel(analyzer.periods{w})
                if contains(analyzer.periods{w}(s).detectedBy, 'unmatched')
                    nUnknown = nUnknown + 1;
                end
            end
        end

        analyzer.printPeriodSummary();

        if nUnknown > 0
            fprintf('  %d unknown states detected.\n', nUnknown);
        end

        % Interactive modes
        if opts.Explorer
            fprintf('[3b] Opening TraceExplorer...\n');
            analyzer.openExplorer();
            fprintf('  Explorer closed. Continuing analysis with updated labels.\n');
        elseif opts.Interactive && nUnknown > 0
            fprintf('[3b] Entering teach mode...\n');
            analyzer.teachStates();
            fprintf('  Teach mode complete.\n');
        elseif opts.Interactive
            fprintf('  All states recognized — skipping teach mode.\n');
        end

        % Step 4: Thermal analysis
        fprintf('[4/5] Running thermal analysis...\n');
        analyzer.analyzeThermal();

        % Step 5: Update knowledge base
        fprintf('[5/5] Updating knowledge base...\n');
        analyzer.updateKnowledge();

        % Generate report
        if isempty(opts.OutputDir)
            [fdir, fname] = fileparts(matFiles{f});
            outDir = fullfile(fdir, [fname '_analysis']);
        else
            outDir = opts.OutputDir;
        end

        analyzer.generateReport(outDir);
        allResults{f} = analyzer.getResults();
    end

    % If overlay file provided, run correlation
    if ~isempty(opts.OverlayFile)
        fprintf('\n--- Overlay Correlation ---\n');
        oc = OverlayCorrelator(kb);
        oc.correlate(allResults, opts.OverlayFile);
    end

    % Cross-test knowledge synthesis
    if numel(matFiles) > 1
        fprintf('\n--- Cross-Test Synthesis ---\n');
        kb.synthesize();
    end

    results = allResults;
    if numel(results) == 1
        results = results{1};
    end

    fprintf('\n=== Analysis Complete ===\n');
    fprintf('Results saved to: %s\n', outDir);
    fprintf('Knowledge base: %d analyses, %d known states, %d test types\n', ...
        kb.getAnalysisCount(), kb.stateLibrary.getStateCount(), ...
        kb.stateLibrary.getTestTypeCount());
end
