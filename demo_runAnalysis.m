%% demo_runAnalysis.m — Full demo of WaferTraceAnalyzer v2
%
% Demonstrates:
%   1. State discovery on a standard expose test
%   2. State discovery on a thermal conditioning test (unknown states!)
%   3. Teach mode: label the unknown states
%   4. Re-analyze: system recognizes previously unknown states
%   5. Knowledge base status showing accumulated learning
%
% Usage:
%   cd WaferTraceAnalyzer
%   demo_runAnalysis

%% Clean knowledge base for fresh demo
kbDir = fullfile(fileparts(mfilename('fullpath')), 'knowledge');
if exist(kbDir, 'dir')
    rmdir(kbDir, 's');
end
fprintf('=== WaferTraceAnalyzer v2 Demo ===\n\n');

%% Step 1: Generate and analyze a standard expose test
fprintf('====================================================\n');
fprintf('STEP 1: Standard expose test (should auto-discover states)\n');
fprintf('====================================================\n');
demo_generateTestData('nWafers', 4, 'testType', 'standard_expose');
results1 = analyzeTraces(fullfile(fileparts(mfilename('fullpath')), 'demo_standard_expose.mat'));

%% Step 2: Generate a thermal conditioning test
fprintf('\n====================================================\n');
fprintf('STEP 2: Thermal conditioning test (will have unknown states)\n');
fprintf('====================================================\n');
demo_generateTestData('nWafers', 4, 'testType', 'thermal_conditioning');
results2 = analyzeTraces(fullfile(fileparts(mfilename('fullpath')), 'demo_thermal_conditioning.mat'));

%% Step 3: Generate a calibration test
fprintf('\n====================================================\n');
fprintf('STEP 3: Calibration test (different unknown states)\n');
fprintf('====================================================\n');
demo_generateTestData('nWafers', 3, 'testType', 'calibration');
results3 = analyzeTraces(fullfile(fileparts(mfilename('fullpath')), 'demo_calibration.mat'));

%% Step 4: Show knowledge base status
fprintf('\n====================================================\n');
fprintf('STEP 4: Knowledge base status\n');
fprintf('====================================================\n');
kb = KnowledgeBase(kbDir);
kb.printFullStatus();

%% Step 5: Interactive teach mode example
fprintf('\n====================================================\n');
fprintf('STEP 5: To teach unknown states interactively, run:\n');
fprintf('====================================================\n');
fprintf('\n  %% Command-line teach mode:\n');
fprintf('  results = analyzeTraces(''demo_thermal_conditioning.mat'', ''Interactive'', true);\n');
fprintf('\n  %% Or GUI explorer:\n');
fprintf('  results = analyzeTraces(''demo_thermal_conditioning.mat'', ''Explorer'', true);\n');
fprintf('\n  %% After teaching, re-analyze the same file:\n');
fprintf('  results = analyzeTraces(''demo_thermal_conditioning.mat'');\n');
fprintf('  %% The system will auto-label previously unknown states!\n');

fprintf('\n=== Demo Complete ===\n');
fprintf('Output directories:\n');
fprintf('  demo_standard_expose_analysis/\n');
fprintf('  demo_thermal_conditioning_analysis/\n');
fprintf('  demo_calibration_analysis/\n');
fprintf('Knowledge base: knowledge/\n');
