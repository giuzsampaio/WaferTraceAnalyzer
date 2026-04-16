# WaferTraceAnalyzer

MATLAB toolkit for analyzing multi-wafer process traces from `.mat` files. Auto-discovers and classifies signals (position, temperature, heater, pressure, height), detects wafer boundaries, segments each wafer into states via a bottom-up signal-analysis engine, and accumulates learned state fingerprints in a persistent knowledge base.

## Usage

```matlab
analyzeTraces('path/to/traces.mat')
analyzeTraces('path/to/traces.mat', 'Interactive', true)   % teach mode
analyzeTraces('path/to/traces.mat', 'Explorer', true)      % GUI explorer
analyzeTraces('path/to/traces.mat', 'Legacy', true)        % V1 behavior
analyzeTraces({'file1.mat', 'file2.mat'})                  % batch mode
```

## Demo

```matlab
demo_generateTestData   % writes synthetic trace .mat
demo_runAnalysis        % runs analyzeTraces on it
```

## Components

- `WaferTraceAnalyzer` — orchestrator (signal discovery, wafer detection, thermal analysis)
- `SignalFeatureExtractor` / `ChangePointDetector` / `StateSegmenter` — state discovery engine (V2)
- `StateLibrary` / `KnowledgeBase` — persistent learned-pattern storage
- `TraceExplorer` / `OverlayCorrelator` / `GUIDE` — visualization and interactive tools

## Requirements

MATLAB (tested with standard toolboxes). Run from this directory so the classes are on the MATLAB path.
