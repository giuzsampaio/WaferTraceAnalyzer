classdef TraceExplorer < handle
    % TraceExplorer — Interactive MATLAB figure for visual state exploration.
    %
    % Opens a stacked plot of all signals with discovered states shown as
    % colored bands. Supports click-to-rename, split, merge, and keyboard
    % navigation between wafers.
    %
    % Usage:
    %   explorer = TraceExplorer(analyzerResults);
    %   explorer.open();
    %
    % Keyboard shortcuts:
    %   Left/Right  — navigate wafers
    %   Enter       — accept all labels for current wafer
    %   A           — auto-label remaining wafers from current labels
    %   M           — merge selected state with next
    %   D/Delete    — delete transition boundary (merge with neighbor)
    %   S           — split state at clicked position
    %   H           — print help
    %   Q           — quit and save

    properties
        analyzer        WaferTraceAnalyzer
        stateLibrary    StateLibrary
        currentWafer    double = 1
        fig             matlab.ui.Figure
        axes            cell        % cell array of axes handles
        stateBands      cell        % cell array of patch handles per wafer
        selectedState   double = 0  % index of selected state
        clickedTime     double = 0
        isOpen          logical = false
    end

    methods
        function obj = TraceExplorer(analyzer)
            obj.analyzer = analyzer;
            if ~isempty(analyzer.kb)
                obj.stateLibrary = analyzer.kb.stateLibrary;
            else
                obj.stateLibrary = StateLibrary(fullfile(tempdir, 'wta_state_lib'));
            end
        end

        function open(obj)
            % Open the interactive explorer figure.
            obj.fig = figure('Name', 'WaferTraceAnalyzer — TraceExplorer', ...
                'NumberTitle', 'off', ...
                'Position', [50 50 1600 900], ...
                'KeyPressFcn', @(~, evt) obj.onKeyPress(evt), ...
                'CloseRequestFcn', @(~,~) obj.onClose());

            obj.isOpen = true;
            obj.drawWafer(obj.currentWafer);
        end

        function teachFromCommandLine(obj)
            % Text-based teach interface (alternative to GUI).
            nWafers = obj.analyzer.numWafers;

            for w = 1:nWafers
                states = obj.analyzer.periods{w};
                if isempty(states), continue; end

                fprintf('\n--- Wafer %d/%d ---\n', w, nWafers);

                hasUnknown = false;
                for s = 1:numel(states)
                    st = states(s);
                    dur = st.tEnd - st.tStart;
                    confStr = sprintf('%.0f%%', st.confidence * 100);

                    if contains(st.detectedBy, 'unmatched') || st.confidence < 0.4
                        marker = '  >> ';
                        hasUnknown = true;
                    else
                        marker = '     ';
                    end

                    % Show fingerprint summary
                    fpSummary = obj.fingerprintSummary(st.fingerprint);

                    fprintf('%s[%d] %-20s %6.1f–%6.1fs (%5.1fs) conf=%s  %s\n', ...
                        marker, s, st.name, st.tStart, st.tEnd, dur, confStr, fpSummary);
                end

                if ~hasUnknown
                    fprintf('  All states recognized. Press Enter to continue, or type state# and new name.\n');
                end

                while true
                    response = input('  Label (e.g. "2 thermal_soak"), Enter=accept, p=plot, a=auto-rest, q=quit: ', 's');

                    if isempty(response) || strcmpi(response, '')
                        break; % Accept and move to next wafer
                    end

                    if strcmpi(response, 'q')
                        fprintf('  Saving and exiting teach mode.\n');
                        return;
                    end

                    if strcmpi(response, 'p')
                        obj.plotWaferStatic(w);
                        continue;
                    end

                    if strcmpi(response, 'a')
                        obj.autoLabelRemaining(w);
                        fprintf('  Auto-labeled wafers %d–%d from current labels.\n', w+1, nWafers);
                        return;
                    end

                    % Parse "stateIdx name"
                    parts = strsplit(strtrim(response), ' ', 'CollapseDelimiters', true);
                    if numel(parts) >= 2
                        sIdx = str2double(parts{1});
                        newName = strjoin(parts(2:end), '_');

                        if ~isnan(sIdx) && sIdx >= 1 && sIdx <= numel(states)
                            % Rename state
                            obj.analyzer.periods{w}(sIdx).name = newName;
                            obj.analyzer.periods{w}(sIdx).confidence = 1.0;
                            obj.analyzer.periods{w}(sIdx).detectedBy = 'user_taught';

                            % Teach the library
                            fp = obj.analyzer.periods{w}(sIdx).fingerprint;
                            if ~isempty(fp) && isstruct(fp) && ~isempty(fieldnames(fp))
                                obj.stateLibrary.teach(fp, newName);
                                fprintf('    Saved "%s" to state library.\n', newName);
                            end

                            % Show updated state
                            fprintf('    State %d → "%s"\n', sIdx, newName);
                        else
                            fprintf('    Invalid state index.\n');
                        end
                    else
                        fprintf('    Format: <state_number> <name>  (e.g., "2 thermal_soak")\n');
                    end
                end

                % After accepting, save test type if all states are labeled
                stateNames = {obj.analyzer.periods{w}.name};
                allLabeled = all(~contains(stateNames, 'state_'));
                if allLabeled
                    [ttName, ttConf] = obj.stateLibrary.matchTestType(stateNames);
                    if ttConf < 0.8
                        ttInput = input(sprintf('  Save as test type? Current match: "%s" (%.0f%%). Enter name or skip: ', ...
                            ttName, ttConf*100), 's');
                        if ~isempty(ttInput)
                            obj.stateLibrary.saveTestType(stateNames, ttInput);
                            fprintf('    Saved test type "%s".\n', ttInput);
                        end
                    end
                end
            end

            fprintf('\n  Teach mode complete. State library has %d known states, %d test types.\n', ...
                obj.stateLibrary.getStateCount(), obj.stateLibrary.getTestTypeCount());
        end
    end

    methods (Access = private)
        function drawWafer(obj, waferIdx)
            if ~obj.isOpen || ~isvalid(obj.fig), return; end

            clf(obj.fig);
            wf = obj.analyzer.wafers(waferIdx);
            states = obj.analyzer.periods{waferIdx};
            signals = obj.analyzer.signals;
            categories = unique({signals.category});
            categories = categories(~strcmp(categories, 'unknown'));
            nCats = numel(categories);

            % State band colors
            stateColors = obj.getStateColors(states);

            % Create subplots
            obj.axes = cell(nCats + 1, 1);

            for c = 1:nCats
                obj.axes{c} = subplot(nCats + 1, 1, c, 'Parent', obj.fig);
                ax = obj.axes{c};
                hold(ax, 'on');

                % Draw state bands
                yRange = [inf, -inf];
                catSigs = signals(strcmp({signals.category}, categories{c}));

                for s = 1:numel(catSigs)
                    mask = catSigs(s).time >= wf.tStart & catSigs(s).time <= wf.tEnd;
                    if ~any(mask), continue; end
                    t = catSigs(s).time(mask);
                    d = catSigs(s).data(mask);
                    plot(ax, t, d, 'LineWidth', 0.8);
                    yRange(1) = min(yRange(1), min(d));
                    yRange(2) = max(yRange(2), max(d));
                end

                if isinf(yRange(1)), yRange = [0 1]; end
                yPad = (yRange(2) - yRange(1)) * 0.05;
                ylim(ax, [yRange(1) - yPad, yRange(2) + yPad]);

                % Draw state band patches
                for si = 1:numel(states)
                    st = states(si);
                    clr = stateColors(si, :);
                    patch(ax, [st.tStart st.tEnd st.tEnd st.tStart], ...
                        [yRange(1)-yPad yRange(1)-yPad yRange(2)+yPad yRange(2)+yPad], ...
                        clr, 'FaceAlpha', 0.15, 'EdgeColor', 'none', ...
                        'ButtonDownFcn', @(~,~) obj.onStateClick(si, ax));

                    % Label
                    midT = (st.tStart + st.tEnd) / 2;
                    midY = yRange(2) + yPad * 0.5;
                    confStr = '';
                    if st.confidence < 0.6
                        confStr = ' ?';
                    end
                    text(ax, midT, midY, [st.name confStr], ...
                        'HorizontalAlignment', 'center', 'FontSize', 7, ...
                        'FontWeight', 'bold', 'Color', clr * 0.6, ...
                        'Interpreter', 'none');
                end

                title(ax, upper(categories{c}), 'FontWeight', 'bold', 'FontSize', 9);
                ylabel(ax, categories{c}, 'FontSize', 8);
                grid(ax, 'on');
                hold(ax, 'off');
            end

            % Change score subplot (if available)
            % Show a text status bar instead
            ax = subplot(nCats + 1, 1, nCats + 1, 'Parent', obj.fig);
            nStates = numel(states);
            nUnknown = sum(contains({states.detectedBy}, 'unmatched'));
            statusText = sprintf('Wafer %d/%d  |  %d states  |  %d unknown  |  [H]elp  [Q]uit  [A]uto-label  [Enter]accept  click state to rename', ...
                waferIdx, obj.analyzer.numWafers, nStates, nUnknown);
            text(ax, 0.5, 0.5, statusText, 'HorizontalAlignment', 'center', ...
                'FontSize', 10, 'FontWeight', 'bold');
            axis(ax, 'off');

            sgtitle(obj.fig, sprintf('TraceExplorer — Wafer %d', waferIdx), 'FontSize', 12);
        end

        function colors = getStateColors(~, states)
            % Assign colors to states. Known states get consistent colors,
            % unknown states get gray.
            knownColors = containers.Map();
            knownColors('load') = [0.2 0.7 0.2];
            knownColors('prealign') = [0.3 0.3 0.9];
            knownColors('align') = [0.1 0.1 0.95];
            knownColors('expose') = [0.9 0.1 0.1];
            knownColors('post_expose') = [0.9 0.5 0.2];
            knownColors('unload') = [0.6 0.6 0.6];
            knownColors('thermal_soak') = [0.9 0.4 0.7];
            knownColors('calibration') = [0.1 0.8 0.8];
            knownColors('conditioning') = [0.8 0.8 0.1];

            nStates = numel(states);
            colors = zeros(nStates, 3);
            nextColor = lines(nStates);
            usedIdx = 1;

            for i = 1:nStates
                name = states(i).name;
                % Strip trailing ? from low-confidence labels
                name = regexprep(name, '\?$', '');

                if knownColors.isKey(name)
                    colors(i, :) = knownColors(name);
                elseif contains(name, 'state_') || contains(name, 'unknown')
                    colors(i, :) = [0.5 0.5 0.5]; % gray for unknown
                else
                    colors(i, :) = nextColor(usedIdx, :);
                    usedIdx = usedIdx + 1;
                end
            end
        end

        function onStateClick(obj, stateIdx, ~)
            obj.selectedState = stateIdx;
            st = obj.analyzer.periods{obj.currentWafer}(stateIdx);

            fpSummary = obj.fingerprintSummary(st.fingerprint);
            prompt = sprintf('State "%s" [%.1f–%.1fs]\n%s\n\nNew name (or cancel):', ...
                st.name, st.tStart, st.tEnd, fpSummary);

            answer = inputdlg(prompt, 'Rename State', 1, {st.name});

            if ~isempty(answer) && ~isempty(answer{1})
                newName = matlab.lang.makeValidName(answer{1});
                newName = strrep(newName, 'x', ''); % clean up leading x from makeValidName

                % If user typed something simple, use it directly
                rawName = strtrim(answer{1});
                if ~isempty(rawName)
                    newName = rawName;
                end

                obj.analyzer.periods{obj.currentWafer}(stateIdx).name = newName;
                obj.analyzer.periods{obj.currentWafer}(stateIdx).confidence = 1.0;
                obj.analyzer.periods{obj.currentWafer}(stateIdx).detectedBy = 'user_taught';

                % Teach the library
                fp = obj.analyzer.periods{obj.currentWafer}(stateIdx).fingerprint;
                if ~isempty(fp) && isstruct(fp) && ~isempty(fieldnames(fp))
                    obj.stateLibrary.teach(fp, newName);
                end

                obj.drawWafer(obj.currentWafer);
            end
        end

        function onKeyPress(obj, evt)
            switch evt.Key
                case 'rightarrow'
                    if obj.currentWafer < obj.analyzer.numWafers
                        obj.currentWafer = obj.currentWafer + 1;
                        obj.drawWafer(obj.currentWafer);
                    end
                case 'leftarrow'
                    if obj.currentWafer > 1
                        obj.currentWafer = obj.currentWafer - 1;
                        obj.drawWafer(obj.currentWafer);
                    end
                case 'return'
                    % Accept all labels for current wafer
                    fprintf('  Accepted labels for wafer %d.\n', obj.currentWafer);
                    if obj.currentWafer < obj.analyzer.numWafers
                        obj.currentWafer = obj.currentWafer + 1;
                        obj.drawWafer(obj.currentWafer);
                    end
                case 'a'
                    obj.autoLabelRemaining(obj.currentWafer);
                    fprintf('  Auto-labeled remaining wafers.\n');
                    obj.drawWafer(obj.currentWafer);
                case 'm'
                    if obj.selectedState > 0 && obj.selectedState < numel(obj.analyzer.periods{obj.currentWafer})
                        % Merge with next state (through segmenter if available)
                        states = obj.analyzer.periods{obj.currentWafer};
                        s1 = states(obj.selectedState);
                        s2 = states(obj.selectedState + 1);
                        merged = s1;
                        merged.tEnd = s2.tEnd;
                        % Recompute fingerprint would need feature extractor access
                        obj.analyzer.periods{obj.currentWafer}(obj.selectedState) = merged;
                        obj.analyzer.periods{obj.currentWafer}(obj.selectedState + 1) = [];
                        obj.selectedState = 0;
                        obj.drawWafer(obj.currentWafer);
                    end
                case {'d', 'delete'}
                    if obj.selectedState > 0
                        % Delete = merge with previous
                        if obj.selectedState > 1
                            states = obj.analyzer.periods{obj.currentWafer};
                            s1 = states(obj.selectedState - 1);
                            s2 = states(obj.selectedState);
                            merged = s1;
                            merged.tEnd = s2.tEnd;
                            obj.analyzer.periods{obj.currentWafer}(obj.selectedState - 1) = merged;
                            obj.analyzer.periods{obj.currentWafer}(obj.selectedState) = [];
                        end
                        obj.selectedState = 0;
                        obj.drawWafer(obj.currentWafer);
                    end
                case 'h'
                    fprintf('\n--- TraceExplorer Help ---\n');
                    fprintf('  Click state band   → rename state\n');
                    fprintf('  Left/Right arrows   → navigate wafers\n');
                    fprintf('  Enter              → accept labels, next wafer\n');
                    fprintf('  A                  → auto-label remaining wafers\n');
                    fprintf('  M                  → merge selected state with next\n');
                    fprintf('  D/Delete           → delete boundary (merge with previous)\n');
                    fprintf('  H                  → this help\n');
                    fprintf('  Q                  → quit and save\n');
                case 'q'
                    obj.onClose();
            end
        end

        function onClose(obj)
            obj.isOpen = false;
            if isvalid(obj.fig)
                delete(obj.fig);
            end
            fprintf('  TraceExplorer closed. State library saved.\n');
        end

        function autoLabelRemaining(obj, fromWafer)
            % Apply current wafer's fingerprint-to-label mapping to all remaining wafers.
            sourceStates = obj.analyzer.periods{fromWafer};

            % Teach all labeled states from source wafer
            for s = 1:numel(sourceStates)
                st = sourceStates(s);
                if ~contains(st.name, 'state_') && ~contains(st.name, 'unknown')
                    fp = st.fingerprint;
                    if ~isempty(fp) && isstruct(fp) && ~isempty(fieldnames(fp))
                        obj.stateLibrary.teach(fp, st.name);
                    end
                end
            end

            % Re-label remaining wafers
            for w = (fromWafer+1):obj.analyzer.numWafers
                obj.stateLibrary.labelStates(obj.analyzer.periods(w));
            end
        end

        function plotWaferStatic(obj, waferIdx)
            % Static plot of a wafer (for command-line teach mode).
            wf = obj.analyzer.wafers(waferIdx);
            states = obj.analyzer.periods{waferIdx};
            signals = obj.analyzer.signals;
            categories = unique({signals.category});
            categories = categories(~strcmp(categories, 'unknown'));
            nCats = numel(categories);

            fig = figure('Position', [100 100 1400 200*nCats], 'Name', sprintf('Wafer %d', waferIdx));

            stateColors = obj.getStateColors(states);

            for c = 1:nCats
                ax = subplot(nCats, 1, c);
                hold(ax, 'on');

                catSigs = signals(strcmp({signals.category}, categories{c}));
                yRange = [inf, -inf];

                for s = 1:numel(catSigs)
                    mask = catSigs(s).time >= wf.tStart & catSigs(s).time <= wf.tEnd;
                    if ~any(mask), continue; end
                    t = catSigs(s).time(mask);
                    d = catSigs(s).data(mask);
                    plot(ax, t, d, 'LineWidth', 0.8, 'DisplayName', catSigs(s).name);
                    yRange(1) = min(yRange(1), min(d));
                    yRange(2) = max(yRange(2), max(d));
                end

                if isinf(yRange(1)), yRange = [0 1]; end
                yPad = (yRange(2) - yRange(1)) * 0.05;

                for si = 1:numel(states)
                    st = states(si);
                    clr = stateColors(si, :);
                    patch(ax, [st.tStart st.tEnd st.tEnd st.tStart], ...
                        [yRange(1)-yPad yRange(1)-yPad yRange(2)+yPad yRange(2)+yPad], ...
                        clr, 'FaceAlpha', 0.15, 'EdgeColor', 'none');
                    text(ax, (st.tStart + st.tEnd)/2, yRange(2)+yPad*0.5, ...
                        sprintf('[%d] %s', si, st.name), ...
                        'HorizontalAlignment', 'center', 'FontSize', 7, ...
                        'FontWeight', 'bold', 'Interpreter', 'none');
                end

                title(ax, upper(categories{c}), 'FontWeight', 'bold');
                legend(ax, 'Location', 'eastoutside', 'FontSize', 7);
                grid(ax, 'on');
                hold(ax, 'off');
            end

            sgtitle(fig, sprintf('Wafer %d — State Overview', waferIdx));
        end

        function summary = fingerprintSummary(~, fp)
            % One-line summary of a fingerprint for display.
            if isempty(fp) || ~isstruct(fp) || isempty(fieldnames(fp))
                summary = '(no fingerprint)';
                return;
            end

            parts = {};
            cats = fieldnames(fp);
            shapeNames = {'flat', 'ramp_up', 'ramp_dn', 'exp_dec', 'oscill', 'stepping'};

            for c = 1:numel(cats)
                f = fp.(cats{c});
                shapeIdx = min(max(round(f.shape) + 1, 1), numel(shapeNames));
                parts{end+1} = sprintf('%s=%s(L%.1f,A%.2f)', ...
                    cats{c}, shapeNames{shapeIdx}, f.level, f.activity); %#ok<AGROW>
            end

            summary = strjoin(parts, ', ');
        end
    end
end
