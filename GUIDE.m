%% ========================================================================
%  WAFERTRACEANALYZER v2 — COMPLETE GUIDE
%  ========================================================================
%
%  Your files are in TWO locations (identical copies):
%
%    Windows:  C:\Users\giuzs\WaferTraceAnalyzer\
%    WSL/tmp:  /tmp/WaferTraceAnalyzer/  (has git repo — will be lost on reboot)
%
%  RECOMMENDATION: Copy the folder to your preferred MATLAB working
%  directory and initialize git there:
%
%    >> copyfile('C:\Users\giuzs\WaferTraceAnalyzer', 'D:\MyWork\WaferTraceAnalyzer')
%
%  ========================================================================
%
%  FILE MAP (11 .m files, ~4900 lines):
%
%    ENTRY POINTS:
%      analyzeTraces.m              — Main entry point, call this
%      demo_runAnalysis.m           — Full demo, run this first
%      demo_generateTestData.m      — Generates synthetic test .mat files
%
%    CORE ENGINE:
%      WaferTraceAnalyzer.m         — Orchestrator (signal discovery,
%                                     wafer detection, thermal analysis,
%                                     plotting, reporting)
%      SignalFeatureExtractor.m     — Computes signal features at every
%                                     time step (level, activity, derivative)
%      ChangePointDetector.m        — Finds where machine behavior changes
%      StateSegmenter.m             — Clusters segments into states,
%                                     computes fingerprints
%
%    LEARNING:
%      StateLibrary.m               — Persistent store of learned state
%                                     fingerprints (teach once, recognize forever)
%      KnowledgeBase.m              — Persistent learning: thermal norms,
%                                     anomaly detection, world model
%
%    INTERACTION:
%      TraceExplorer.m              — Interactive figure for visual state
%                                     editing + command-line teach mode
%
%    OVERLAY:
%      OverlayCorrelator.m          — Thermal-to-overlay regression models
%
%  ========================================================================


%% ========================================================================
%  STEP 1: FIRST-TIME SETUP
%  ========================================================================

% Add the folder to your MATLAB path:
addpath('C:\Users\giuzs\WaferTraceAnalyzer');
% Or wherever you copied it to. Then:
cd('C:\Users\giuzs\WaferTraceAnalyzer');

% Verify it works:
which analyzeTraces    % Should show the path
which WaferTraceAnalyzer


%% ========================================================================
%  STEP 2: RUN THE DEMO (do this first!)
%  ========================================================================

% This generates 3 different test types and analyzes them all.
% Takes about 30 seconds. Watch the console output carefully —
% it shows you exactly what the system discovers.

demo_runAnalysis

% After running, check the output folders:
%   demo_standard_expose_analysis/     — plots, summary, results.mat
%   demo_thermal_conditioning_analysis/
%   demo_calibration_analysis/
%   knowledge/                         — persistent knowledge base


%% ========================================================================
%  STEP 3: ANALYZE YOUR OWN DATA
%  ========================================================================

% The simplest call — just point it at your .mat file:
results = analyzeTraces('C:\path\to\your\traces.mat');

% The system will:
%   1. Auto-discover all signals (finds time vectors, classifies by name)
%   2. Detect wafer boundaries (from clamping pressure, epin Z, etc.)
%   3. Discover states within each wafer (bottom-up from signal features)
%   4. Match states against the knowledge base
%   5. Run thermal analysis per (wafer, state)
%   6. Generate plots and reports

% Output goes to: your_traces_analysis/ (next to the .mat file)


%% ========================================================================
%  STEP 4: TEACH THE SYSTEM (the key workflow)
%  ========================================================================

% When the system encounters states it doesn't recognize, you teach it.
% This is where the magic happens — you only do this ONCE per state type.

% OPTION A: Command-line teach mode (fastest)
results = analyzeTraces('your_traces.mat', 'Interactive', true);

% The system will show you something like:
%
%   --- Wafer 1/8 ---
%     [1] state_1    0.0-3.2s   (3.2s)  conf=0%   pressure=flat(L0.9,A0.01)...
%   >> [2] state_2    3.2-15.8s  (12.6s) conf=0%   pressure=flat(L0.9,A0.01)...
%     [3] state_3   15.8-31.4s  (15.6s) conf=0%   position=stepping(L0.5,A0.80)...
%     [4] state_4   31.4-33.5s  (2.1s)  conf=0%   pressure=flat(L0.1,A0.01)...
%
%   Label (e.g. "2 thermal_soak"), Enter=accept, p=plot, a=auto-rest, q=quit:

% What you type:
%   1 load                    — labels state_1 as "load"
%   2 thermal_soak            — labels state_2 as "thermal_soak"
%   3 expose                  — labels state_3 as "expose"
%   4 unload                  — labels state_4 as "unload"
%   a                         — auto-labels all remaining wafers!
%
% After teaching, the system saves fingerprints. Next time it sees
% the same signal patterns, it auto-labels them.

% OPTION B: Visual explorer (for when you need to see the signals)
results = analyzeTraces('your_traces.mat', 'Explorer', true);

% Opens an interactive MATLAB figure:
%   - Click on a colored state band to rename it
%   - Left/Right arrows to navigate wafers
%   - Press 'A' to auto-label remaining wafers
%   - Press 'M' to merge two adjacent states
%   - Press 'D' to delete a boundary
%   - Press 'H' for help
%   - Press 'Q' to quit and save


%% ========================================================================
%  STEP 5: RE-ANALYZE — THE SYSTEM REMEMBERS
%  ========================================================================

% After teaching, re-analyze the same or similar files:
results = analyzeTraces('your_traces.mat');

% States that match learned fingerprints get auto-labeled.
% You'll see output like:
%   state_1 -> matched: "load" (confidence: 92%)
%   state_2 -> matched: "thermal_soak" (confidence: 87%)

% The more tests you feed it, the smarter it gets.


%% ========================================================================
%  STEP 6: CHECK WHAT THE SYSTEM HAS LEARNED
%  ========================================================================

kb = KnowledgeBase('knowledge');

% Full status — everything it knows:
kb.printFullStatus();

% Just the world model (thermal insights):
kb.printWorldModel();

% Query specific topics:
kb.queryKnowledge('drift trends');
kb.queryKnowledge('anomalies');
kb.queryKnowledge('history');

% See the state library:
kb.stateLibrary.printLibrary();


%% ========================================================================
%  STEP 7: BATCH ANALYSIS
%  ========================================================================

% Analyze multiple files at once:
results = analyzeTraces({'test1.mat', 'test2.mat', 'test3.mat'});

% With overlay correlation:
results = analyzeTraces('traces.mat', 'OverlayFile', 'overlay.mat');

% Custom output directory:
results = analyzeTraces('traces.mat', 'OutputDir', 'C:\my_results');

% Custom knowledge base location (share between projects):
results = analyzeTraces('traces.mat', 'KnowledgeDir', 'D:\shared_kb');


%% ========================================================================
%  STEP 8: LEGACY MODE (V1 behavior)
%  ========================================================================

% If you want the original hardcoded period detection:
results = analyzeTraces('traces.mat', 'Legacy', true);

% This bypasses the state discovery engine and uses the fixed
% load/align/expose/unload detection from V1.


%% ========================================================================
%  TIPS & TRICKS
%  ========================================================================

% TIP 1: Teach on Wafer 1, auto-label the rest
%   In teach mode, carefully label all states on the first wafer,
%   then press 'a' (auto). The system propagates your labels to all
%   remaining wafers wherever fingerprints match. Review quickly,
%   fix any mismatches, done.

% TIP 2: Use 'p' to plot before labeling
%   In command-line teach mode, type 'p' to open a static plot of the
%   current wafer with all signals. Helps you identify what each state is.

% TIP 3: Name states consistently
%   Use the same name every time you see the same physical state.
%   The fingerprint averaging (EMA) makes matching more robust over time.
%   Good: "thermal_soak", "load", "calibration_scan"
%   Bad:  "soak1", "loading_phase", "cal"

% TIP 4: Share knowledge base across teams
%   Point multiple analyses to the same KnowledgeDir:
%     results = analyzeTraces('test.mat', 'KnowledgeDir', '\\server\shared_kb');
%   Everyone's teaching accumulates in the same library.

% TIP 5: Signal classification overrides
%   If the system misclassifies a signal (calls a heater "unknown"):
%     kb = KnowledgeBase('knowledge');
%     kb.correctSignalCategory('my_weird_signal_name', 'heater');
%   It remembers the correction for all future analyses.

% TIP 6: Access raw results programmatically
%   results.periods{w}             — states for wafer w
%   results.periods{w}(s).name     — name of state s
%   results.periods{w}(s).tStart   — start time
%   results.periods{w}(s).tEnd     — end time
%   results.periods{w}(s).fingerprint  — signal fingerprint struct
%   results.thermalResults{w}      — thermal stats per state for wafer w

% TIP 7: Tune sensitivity
%   Too many states detected? Increase the change score threshold:
%     cfg.minProminence = 0.5;  % default 0.3, higher = fewer transitions
%     results = analyzeTraces('test.mat', 'SignalConfig', cfg);
%
%   Too few states? Lower it:
%     cfg.minProminence = 0.15;
%
%   Change category weights to prioritize different signals:
%     cfg.categoryWeights.temperature = 3.0;  % make temp changes matter more

% TIP 8: Different sample rates are fine
%   The system resamples everything to a common time base automatically.
%   Your .mat file can have signals at 10 Hz, 100 Hz, 1 kHz — doesn't matter.

% TIP 9: Nested structs are fine
%   Your .mat file can have flat variables, structs, nested structs,
%   matrices — the signal discovery recursively walks everything.

% TIP 10: Check anomaly detection after 3+ tests
%   The knowledge base needs at least 3 analyses before it can flag
%   anomalies. After that, it automatically warns about unusual
%   wafer counts, durations, and thermal behavior.


%% ========================================================================
%  BEST PRACTICES
%  ========================================================================

% 1. ALWAYS run demo_runAnalysis first to verify the installation works.

% 2. Start with Interactive=true on your first real .mat file.
%    Teach all the states. Then switch to batch mode for subsequent files.

% 3. Keep one knowledge base per machine/project.
%    Different machines have different thermal signatures — mixing them
%    in one KB will confuse the anomaly detection.

% 4. Back up your knowledge/ folder periodically.
%    It contains state_library.mat and knowledge_base.mat — everything
%    the system has learned. If you lose it, you have to re-teach.

% 5. When overlay data is available, always include it:
%    results = analyzeTraces('traces.mat', 'OverlayFile', 'overlay.mat');
%    The overlay correlator builds regression models over time. The more
%    test-overlay pairs you feed it, the better it predicts which thermal
%    features drive overlay errors.

% 6. Name your .mat files descriptively.
%    The analysis ID includes the filename, so "TC_test_chuck1_20260416.mat"
%    is much more useful than "data.mat" when reviewing the knowledge base.

% 7. Review the text summary (summary.txt) in each analysis folder.
%    It gives you a compact per-wafer breakdown of all states, durations,
%    thermal means, and drift rates — great for reports.


%% ========================================================================
%  SURPRISE ME SESSION: HIDDEN POWER FEATURES
%  ========================================================================

% SURPRISE 1: The system detects INDIVIDUAL FIELD EXPOSURES
%
% When a state is labeled "expose", the system automatically runs the
% expose specialist detector, which finds individual field step-settle
% patterns. Access them via:

results = analyzeTraces('demo_standard_expose.mat');
expose_state = results.periods{1}(3);  % typically the 3rd state
if ~isempty(expose_state.subPeriods)
    fprintf('Found %d individual field exposures!\n', numel(expose_state.subPeriods));
    for f = 1:min(5, numel(expose_state.subPeriods))
        fp = expose_state.subPeriods(f);
        fprintf('  Field %d: position=%.0f um, time=[%.2f-%.2f]s\n', ...
            fp.fieldIdx, fp.position, fp.tStart, fp.tEnd);
    end
end

% SURPRISE 2: Thermal transfer function discovery
%
% The cross-correlation analysis doesn't just compute correlation —
% it estimates the DELAY between heater power changes and temperature
% response. This is essentially identifying the thermal plant's
% transfer function. Access the heater-to-sensor coupling map:

results = analyzeTraces('demo_standard_expose.mat');
tr = results.thermalResults{1};
periodNames = fieldnames(tr);
for p = 1:numel(periodNames)
    xc = tr.(periodNames{p}).crossCorrelations;
    pairs = fieldnames(xc);
    for i = 1:numel(pairs)
        pair = xc.(pairs{i});
        fprintf('%s -> %s: correlation=%.3f, delay=%.2fs\n', ...
            pair.heater, pair.sensor, pair.peakCorrelation, pair.delaySeconds);
    end
end

% SURPRISE 3: Build your own state fingerprint from scratch
%
% You can manually create a fingerprint and teach it to the library
% WITHOUT having trace data. Useful if you know what a state looks like:

kb = KnowledgeBase('knowledge');
manual_fp = struct();
manual_fp.pressure = struct('level', 0.95, 'activity', 0.01, ...
    'trend', 0, 'variability', 0.01, 'shape', 0);
manual_fp.position = struct('level', 0.5, 'activity', 0.02, ...
    'trend', 0, 'variability', 0.01, 'shape', 0);
manual_fp.temperature = struct('level', 0.7, 'activity', 0.3, ...
    'trend', 0.8, 'variability', 0.05, 'shape', 1);  % shape 1 = ramp_up
kb.stateLibrary.teach(manual_fp, 'my_custom_state');
fprintf('Taught "my_custom_state" from manual fingerprint!\n');

% SURPRISE 4: Compare two tests side-by-side
%
% Run both, then compare their thermal fingerprints:

r1 = analyzeTraces('test_before_maintenance.mat');
r2 = analyzeTraces('test_after_maintenance.mat');

% Compare period-level thermal stats:
for w = 1:min(r1.numWafers, r2.numWafers)
    p1 = fieldnames(r1.thermalResults{w});
    for p = 1:numel(p1)
        t1 = r1.thermalResults{w}.(p1{p}).temperature;
        t2 = r2.thermalResults{w}.(p1{p}).temperature;
        sensors = fieldnames(t1);
        for s = 1:numel(sensors)
            delta = t2.(sensors{s}).mean - t1.(sensors{s}).mean;
            fprintf('Wafer %d, %s, %s: delta = %+.4f degC\n', ...
                w, p1{p}, sensors{s}, delta);
        end
    end
end

% SURPRISE 5: Predict overlay from thermal features (once trained)
%
% After correlating several test+overlay pairs, predict overlay
% impact of a NEW test before you even measure overlay:

kb = KnowledgeBase('knowledge');
oc = OverlayCorrelator(kb);
new_results = analyzeTraces('new_test.mat');
predictions = oc.predictOverlayImpact(new_results);
% predictions.mean_dx.predicted  — predicted overlay per wafer
% predictions.mean_dx.confidence — R^2 of the model

% SURPRISE 6: Export state timeline for PowerPoint
%
% The period timeline plot (period_timeline.png) is a Gantt chart
% showing all states for all wafers. But you can also export the
% raw data for custom visualization:

results = analyzeTraces('demo_standard_expose.mat');
for w = 1:results.numWafers
    for s = 1:numel(results.periods{w})
        st = results.periods{w}(s);
        fprintf('W%d, %s, %.1f, %.1f\n', w, st.name, st.tStart, st.tEnd);
    end
end
% Paste into Excel -> make your own Gantt chart

% SURPRISE 7: The fingerprint shape detector knows 6 patterns
%
%   0 = flat        (steady state, no change)
%   1 = ramp_up     (linear increase)
%   2 = ramp_down   (linear decrease)
%   3 = exp_decay   (exponential decay — common after load)
%   4 = oscillating (periodic — common in calibration)
%   5 = stepping    (discrete steps — expose field stepping)
%
% These shape features are the strongest discriminators between states.
% The system uses them with 3x weight in fingerprint matching.

% SURPRISE 8: Create test type templates for instant recognition
%
% After teaching states, save the full sequence as a test type:

kb = KnowledgeBase('knowledge');
kb.stateLibrary.saveTestType({'load', 'thermal_soak', 'expose', 'unload'}, ...
    'thermal_conditioning_test');
kb.stateLibrary.saveTestType({'load', 'calibration_scan', 'unload'}, ...
    'calibration_test');
kb.stateLibrary.printLibrary();

% Next time the system sees the same state sequence, it will say:
%   "Test type recognized: thermal_conditioning_test (100% match)"


%% ========================================================================
%  QUICK REFERENCE CARD
%  ========================================================================
%
%  BASIC USAGE:
%    results = analyzeTraces('file.mat')              % auto-analyze
%    results = analyzeTraces('file.mat', 'Interactive', true)  % teach mode
%    results = analyzeTraces('file.mat', 'Explorer', true)     % GUI mode
%    results = analyzeTraces('file.mat', 'Legacy', true)       % V1 mode
%
%  EXPLORER KEYS:
%    Click state    — rename
%    Left/Right     — navigate wafers
%    Enter          — accept, next wafer
%    A              — auto-label remaining
%    M              — merge with next state
%    D              — delete boundary
%    H              — help
%    Q              — quit
%
%  TEACH MODE COMMANDS:
%    2 thermal_soak — label state 2
%    p              — plot current wafer
%    a              — auto-label remaining
%    Enter          — accept, next wafer
%    q              — quit
%
%  KNOWLEDGE BASE:
%    kb = KnowledgeBase('knowledge');
%    kb.printFullStatus()
%    kb.printWorldModel()
%    kb.queryKnowledge('drift')
%    kb.stateLibrary.printLibrary()
%    kb.correctSignalCategory('signal_name', 'category')
%
%  SENSITIVITY TUNING:
%    cfg.minProminence = 0.3       % higher = fewer states (default 0.3)
%    cfg.minWaferDuration = 5      % min seconds to count as a wafer
%    cfg.minPeriodDuration = 0.5   % min seconds for a valid state
%    cfg.clampThresholdFraction = 0.5  % pressure on/off threshold
%    results = analyzeTraces('f.mat', 'SignalConfig', cfg);
%
%  ========================================================================
%  Happy analyzing!
%  ========================================================================
