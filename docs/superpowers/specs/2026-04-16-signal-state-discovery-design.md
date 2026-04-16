# Signal-State Discovery & Teach-Once Learning

**Date:** 2026-04-16
**Status:** Approved
**Scope:** WaferTraceAnalyzer v2 — replace hardcoded period detection with data-driven state discovery and persistent learning

## Problem

The current system assumes every test follows a load/align/expose/unload sequence. When it encounters non-standard tests (thermal conditioning, calibration scans, chuck swaps — roughly 5-10 recurring test types), it collapses everything into a single "active" period with 30% confidence. The user must manually inspect traces for each new test type.

## Solution

Bottom-up state discovery that works on any test, combined with a teach-once learning loop:

1. **Discover** states from signal features (velocity, level, derivative, variability, shape)
2. **Match** discovered states against a persistent library of learned fingerprints
3. **Teach** the system when it encounters unknown states — user labels them once, system remembers forever
4. **Analyze** thermal behavior per discovered state, regardless of what that state is

## Architecture

```
Signals → SignalFeatureExtractor → ChangePointDetector → StateSegmenter → StateLibrary match → User review
```

### New Classes

#### SignalFeatureExtractor

Computes per-signal features at every time step in sliding windows:

- `normalized_level` (1s window): `(mean(window) - signal_min) / signal_range`
- `activity` (0.5s window): `std(diff(window)) / signal_range`
- `derivative_sign` (1s window): `sign(linear_fit_slope)`

All signals resampled to a common time base (min sample rate across signals, floor 10 Hz).

Output: feature matrix `F` of size `[N_samples x (N_signals * 3)]`.

#### ChangePointDetector

Finds transitions where signal behavior changes across multiple signals simultaneously.

Algorithm:
1. At each time point, compare feature means in a 2s window before vs. after
2. Compute normalized difference per feature, weighted by category importance
3. Sum weighted differences into a change score
4. Select peaks with minimum prominence (30% above local 10s median) and minimum separation (0.5s)

Category weights: pressure=3.0, height=2.5, position=2.0, heater=1.0, temperature=0.5.

Adaptive threshold: if StateLibrary suggests an expected transition count for this test type, adjust prominence to approximate that count (soft constraint).

Fallback: if no peaks detected, use single-signal edge detection on highest-weight available signal (current behavior).

Output: ordered list of transition times.

#### StateSegmenter

Takes segments between transition times and:
1. Computes a fingerprint for each segment (see Fingerprint Spec below)
2. Clusters similar segments within the same test (e.g., all "expose" segments across wafers)
3. Assigns provisional labels (`state_1`, `state_2`, ...) to each cluster

Clustering: Euclidean distance on fingerprint vectors, agglomerative with distance threshold = 0.3 (normalized).

#### StateLibrary

Persistent store of learned state fingerprints. Stored as a .mat file alongside the knowledge base.

Methods:
- `match(fingerprint)` → `{name, confidence}` or `{unknown, 0}`
- `teach(fingerprint, name)` → saves/updates fingerprint under that name
- `getTestType(stateSequence)` → matches ordered sequence against known test types
- `saveTestType(stateSequence, name)` → stores a new test type template

Matching: weighted Euclidean distance. Weights: activity=3, shape=3, level=2, trend=1, variability=1. Confidence = `1 - distance/maxDistance`, thresholded at 0.6 for auto-label, 0.4 for low-confidence label.

Fingerprint evolution: exponential moving average (alpha=0.1) on each match, so fingerprints adapt to process drift.

#### TraceExplorer

Interactive MATLAB figure for visual exploration and teaching.

Layout: stacked subplots per signal category + change score subplot + state bands as colored patches.

Interactions:
- Click state band → rename (input dialog)
- Shift+click within state → split (insert transition)
- Select two adjacent states + press M → merge
- Click transition line + Delete → remove boundary
- Left/Right arrows → navigate wafers
- Enter → accept all labels for current wafer
- A → auto-label remaining wafers from current wafer's fingerprints

Command-line alternative: text-based teach mode via `analyzeTraces('file.mat', 'Interactive', true)`.

### Fingerprint Specification

Per signal category present in the test:

| Field | Type | Range | Computation |
|-------|------|-------|-------------|
| level | float | [0, 1] | Normalized mean value within segment |
| activity | float | [0, 1] | Normalized velocity magnitude (capped at 1) |
| trend | float | [-1, +1] | Sign and magnitude of linear drift |
| variability | float | [0, 1] | Coefficient of variation (capped at 1) |
| shape | enum | 0-5 | 0=flat, 1=ramp_up, 2=ramp_down, 3=exponential_decay, 4=oscillating, 5=stepping |

Fingerprints are category-based, not signal-name-based. A fingerprint from a test with signal `wt_temp_sensor1` matches against a test with signal `chuck_thermocouple_3` as long as both are classified as `temperature`.

When multiple signals exist in one category, the fingerprint uses the mean across signals for scalar features and the mode for shape.

### Modifications to Existing Classes

#### WaferTraceAnalyzer

- `detectTimePeriods` replaced: calls `SignalFeatureExtractor` → `ChangePointDetector` → `StateSegmenter` → `StateLibrary.match`
- `detectExposeFromPosition` kept as specialist detector: after general state discovery, if a state is labeled "expose", the specialist refines it into individual field sub-periods
- `analyzeThermal` unchanged in logic, but now operates on discovered states instead of hardcoded period names
- New property: `states` (cell array per wafer of discovered state structs)

#### KnowledgeBase

- New property: `stateLibrary` (StateLibrary instance)
- `addAnalysis` now stores state sequences and fingerprints
- `updateWorldModel` generates state-aware insights (e.g., "thermal_soak duration correlates with expose temperature stability")
- New method: `recognizeTestType(stateSequence)` — delegates to StateLibrary
- New anomaly type: unexpected state sequence for a known test type

#### analyzeTraces.m

- New `Interactive` parameter routes to TraceExplorer when true
- Batch mode enhanced: reports unknown states and suggests entering teach mode

### Backward Compatibility

- Default behavior (no StateLibrary data) falls back to current detection logic
- Existing knowledge base data is preserved; new fields are added alongside
- `periods` property still populated (from discovered states) for compatibility with existing thermal analysis and plotting code

## Testing

- Demo generates 3 test types: standard expose, thermal conditioning, calibration scan
- Demo shows teach workflow: label test type 1, then auto-recognize it on second encounter
- All existing plots and reports work unchanged with discovered states
