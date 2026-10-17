//
// @fileoverview The BASIC page's live view of a running program
// @module lab/program-view
//
// Between frames it reads what BASIC is doing (see basic-monitor.js) and
// shows the line being run, where the running time goes, the variables and
// arrays, and how BASIC has divided its memory. While the program in memory
// is the one in the editor, the editor's gutter marks the running line and
// glows on the lines that take the most time.
//
// The time profile is a sampling profiler: one look at the current line per
// display update, weighted by the frames it covered. A line collects samples
// in proportion to the time BASIC spends on it, including time spent waiting
// in INPUT or in a delay loop.
//
// @see https://www.turbo8bit.com/
//

import { basicActivity, formatValue, programLineNumbers, readMemoryLayout, readVariables } from './basic-monitor.js';

const REFRESH_MS = 100;
const HOT_LINES = 5;
const MAX_ROWS = 60;

const STATE_LABELS = {
    booting: 'STARTING',
    ready: 'READY',
    direct: 'DIRECT MODE',
    running: 'RUNNING',
    input: 'WAITING FOR INPUT',
    paused: 'PAUSED',
    nobasic: 'NO BASIC'
};

const TYPE_NOTES = {
    float: 'Floating point: 5 bytes, about 9 digits',
    integer: 'Integer: 2 bytes, -32768 to 32767',
    string: 'String: a length and a pointer to the characters'
};

const MEMORY_AREAS = [
    { key: 'program', label: 'Program', from: 'program', to: 'variables' },
    { key: 'variables', label: 'Variables', from: 'variables', to: 'arrays' },
    { key: 'arrays', label: 'Arrays', from: 'arrays', to: 'free' },
    { key: 'free', label: 'Free', from: 'free', to: 'strings' },
    { key: 'strings', label: 'Strings', from: 'strings', to: 'top' }
];

//
// Map BASIC line numbers to 1-based editor lines. As on the C64, a repeated
// number replaces the earlier line and a number on its own deletes it.
//
export function editorLineMap(text) {
    const map = new Map();
    text.split(/\r?\n/).forEach((line, index) => {
        const match = /^\s*(\d+)(.*)$/.exec(line);
        if (!match) return;
        const number = Number(match[1]);
        if (match[2].trim()) map.set(number, index + 1);
        else map.delete(number);
    });
    return map;
}

//
// Counts samples per BASIC line.
//
export class LineProfiler {
    constructor() {
        this.counts = new Map();
        this.total = 0;
    }

    reset() {
        this.counts.clear();
        this.total = 0;
    }

    sample(line, weight = 1) {
        this.counts.set(line, (this.counts.get(line) ?? 0) + weight);
        this.total += weight;
    }

    // The hottest lines first, each with its share of all samples
    top(count) {
        return [...this.counts]
            .sort((a, b) => b[1] - a[1] || a[0] - b[0])
            .slice(0, count)
            .map(([line, samples]) => ({ line, share: samples / this.total }));
    }

    // Each line's samples relative to the hottest line, from 0 to 1
    heat() {
        let hottest = 0;
        for (const samples of this.counts.values()) hottest = Math.max(hottest, samples);
        const heat = new Map();
        for (const [line, samples] of this.counts) heat.set(line, samples / hottest);
        return heat;
    }
}

const escapeHtml = text => String(text).replace(/[&<>"]/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]
));

export class ProgramView {
    //
    // @param {C64Emulator} emulator
    // @param {CodeEditor} editor
    // @param {HTMLDetailsElement} root - Empty <details> to build the view in
    //
    constructor(emulator, editor, root) {
        this.emulator = emulator;
        this.editor = editor;
        this.root = root;
        this.profiler = new LineProfiler();
        this.generation = emulator.bootGeneration;
        this.lastLine = null;
        this.stoppedLine = null;
        this.votes = new Map();
        this.lastRefresh = -Infinity;
        this.rows = new Map();
        this.rowOrder = '';
        this.motion = typeof matchMedia === 'function'
            ? matchMedia('(prefers-reduced-motion: reduce)') : null;
        this.setSource(editor.getValue());
        this.build();

        emulator.onFrame(frames => this.observe(frames));
        emulator.onStateChange(() => this.refresh());
        editor.onValueChange(text => {
            this.setSource(text);
            this.refresh();
        });
        root.addEventListener('toggle', () => this.refresh());
    }

    setSource(text) {
        this.sourceLines = text.split(/\r?\n/);
        this.lineMap = editorLineMap(text);
    }

    build() {
        this.root.innerHTML = `
            <summary>
                <span class="program-view-title">Inside the program</span>
                <span class="program-view-state" data-state="booting">STARTING</span>
            </summary>
            <div class="program-view-body">
                <p class="program-view-now"><span class="program-view-label">Now</span> <code></code></p>
                <div class="program-view-columns">
                    <section aria-label="Where the time goes">
                        <h4 title="Each line's share of the time since RUN, sampled every frame">Where the time goes</h4>
                        <ol class="program-view-hot"></ol>
                        <p class="program-view-empty" data-empty="hot">Run a program to see which lines take the time.</p>
                    </section>
                    <section aria-label="Variables">
                        <h4>Variables</h4>
                        <table class="program-view-vars"><tbody></tbody></table>
                        <p class="program-view-empty" data-empty="vars">No variables yet. Assigning one, such as A=5, creates it.</p>
                    </section>
                </div>
                <div class="program-view-memory">
                    <h4>BASIC memory</h4>
                    <div class="basic-memory-bar" role="img"></div>
                    <ul class="basic-memory-legend"></ul>
                </div>
            </div>`;
        const find = selector => this.root.querySelector(selector);
        this.stateBadge = find('.program-view-state');
        this.nowText = find('.program-view-now code');
        this.hotList = find('.program-view-hot');
        this.hotEmpty = find('[data-empty="hot"]');
        this.varBody = find('.program-view-vars tbody');
        this.varEmpty = find('[data-empty="vars"]');
        this.memoryBar = find('.basic-memory-bar');
        this.memoryLegend = find('.basic-memory-legend');
    }

    //
    // Sample the machine once per display update.
    // @param {number} frames - Emulated frames since the last update
    //
    observe(frames) {
        if (this.emulator.bootGeneration !== this.generation) {
            this.generation = this.emulator.bootGeneration;
            this.profiler.reset();
            this.lastLine = null;
            this.stoppedLine = null;
        }
        const activity = this.emulator.basicReady ? basicActivity(this.emulator.machine) : null;
        const line = activity?.mode === 'program' ? activity.line : null;
        if (line !== null) {
            // A program starting (RUN, GOTO or CONT) begins a new profile.
            if (this.lastLine === null) this.profiler.reset();
            this.profiler.sample(line, frames);
        }
        this.lastLine = line;
        // Only a program's CURLIN at READY says where it stopped; a typed
        // command sets direct mode, and the first READY reads line 0.
        if (activity?.mode === 'ready' && this.profiler.total > 0) this.stoppedLine = activity.line;
        const state = this.machineState(activity);
        this.votes.set(state, (this.votes.get(state) ?? 0) + frames);

        const now = performance.now();
        if (now - this.lastRefresh >= REFRESH_MS) this.refresh(now);
    }

    machineState(activity) {
        if (this.emulator.bootError) return 'nobasic';
        if (!activity) return 'booting';
        if (activity.mode !== 'program') return activity.mode;
        return activity.waiting ? 'input' : 'running';
    }

    //
    // The state seen most often since the last refresh, so a sample that
    // happens to land in an interrupt handler does not flicker the badge.
    //
    takeState() {
        let best = null;
        let bestVotes = 0;
        for (const [state, votes] of this.votes) {
            if (votes > bestVotes) {
                best = state;
                bestVotes = votes;
            }
        }
        this.votes.clear();
        return best ?? this.lastState ?? 'booting';
    }

    refresh(now = performance.now()) {
        this.lastRefresh = now;
        const state = this.emulator.isPaused?.() ? 'paused' : this.takeState();
        this.lastState = state;
        const machine = this.emulator.machine;
        const line = this.lastLine;
        const programLines = this.emulator.basicReady ? programLineNumbers(machine) : [];
        const inProgram = new Set(programLines);
        // Gutter marks only make sense while the editor holds the program
        // in memory; line numbers are the link between the two.
        const linked = programLines.length > 0 && programLines.every(number => this.lineMap.has(number));

        let badge = STATE_LABELS[state];
        if ((state === 'running' || state === 'input') && line !== null) badge += ` · LINE ${line}`;
        if (this.stateBadge.textContent !== badge) this.stateBadge.textContent = badge;
        this.stateBadge.dataset.state = state;

        const heat = new Map();
        let running = null;
        if (linked) {
            for (const [number, level] of this.profiler.heat()) {
                const editorLine = this.lineMap.get(number);
                if (editorLine) heat.set(editorLine, level);
            }
            if (line !== null && state !== 'ready') running = this.lineMap.get(line) ?? null;
        }
        this.editor.setLineActivity(running, heat);

        if (!this.root.open) return;
        this.renderNow(state, line, linked && inProgram.has(line));
        this.renderHotLines(linked, inProgram);
        this.renderVariables(machine);
        this.renderMemory(machine);
    }

    lineText(number) {
        const editorLine = this.lineMap.get(number);
        return editorLine ? this.sourceLines[editorLine - 1].trim() : String(number);
    }

    renderNow(state, line, linked) {
        let text;
        if (state === 'booting') text = 'The C64 is starting up.';
        else if (state === 'nobasic') text = 'BASIC is not running.';
        else if (line !== null) text = linked ? this.lineText(line) : `Line ${line}`;
        else if (state === 'direct') text = 'Running a command typed without a line number.';
        else if (this.profiler.total > 0) {
            text = this.stoppedLine !== null
                ? `The program stopped at line ${this.stoppedLine}. The time profile is from that run.`
                : 'The program has stopped. The time profile is from its last run.';
        } else text = 'Direct mode: a command typed without a line number runs at once.';
        if (this.nowText.textContent !== text) this.nowText.textContent = text;
    }

    renderHotLines(linked, inProgram) {
        const top = this.profiler.total > 0
            ? this.profiler.top(HOT_LINES).filter(({ line }) => inProgram.has(line)) : [];
        this.hotEmpty.hidden = top.length > 0;
        const html = top.map(({ line, share }) => {
            const percent = Math.round(share * 100);
            const text = linked ? this.lineText(line) : `${line}`;
            return `<li style="--share: ${share.toFixed(3)}" title="${escapeHtml(text)}">` +
                `<span class="hot-percent">${percent}%</span>` +
                `<code>${escapeHtml(text)}</code></li>`;
        }).join('');
        if (this.hotHtml !== html) {
            this.hotHtml = html;
            this.hotList.innerHTML = html;
        }
    }

    renderVariables(machine) {
        const { variables, arrays } = this.emulator.basicReady
            ? readVariables(machine) : { variables: [], arrays: [] };
        const items = [];
        for (const { name, type, value } of variables) {
            items.push({ key: name, label: name, type, text: formatValue(type, value) });
        }
        for (const { name, type, dimensions, values } of arrays) {
            const label = `${name}(${dimensions.join(',')})`;
            let text;
            if (dimensions.length === 1) {
                text = values.map(value => formatValue(type, value)).join(', ');
                if (dimensions[0] + 1 > values.length) text += ', …';
            } else {
                text = `${dimensions.map(size => size + 1).join(' × ')} elements`;
            }
            items.push({ key: `${name}()`, label, type, text });
        }
        const shown = items.slice(0, MAX_ROWS);
        this.varEmpty.hidden = items.length > 0;

        const seen = new Set();
        for (const item of shown) {
            seen.add(item.key);
            let entry = this.rows.get(item.key);
            if (!entry) {
                const row = document.createElement('tr');
                row.innerHTML = '<th scope="row"></th><td></td>';
                entry = { row, name: row.firstChild, value: row.lastChild, text: null, label: null };
                entry.name.title = TYPE_NOTES[item.type] ?? '';
                this.rows.set(item.key, entry);
            }
            if (entry.label !== item.label) {
                entry.label = item.label;
                entry.name.textContent = item.label;
            }
            if (entry.text !== item.text) {
                if (entry.text !== null) this.flash(entry.row);
                entry.text = item.text;
                entry.value.textContent = item.text;
            }
        }
        for (const key of this.rows.keys()) {
            if (!seen.has(key)) this.rows.delete(key);
        }
        const order = shown.map(item => item.key).join('\n') + (items.length > MAX_ROWS ? `\n+${items.length}` : '');
        if (order !== this.rowOrder) {
            this.rowOrder = order;
            const rows = shown.map(item => this.rows.get(item.key).row);
            if (items.length > MAX_ROWS) {
                const more = document.createElement('tr');
                more.innerHTML = `<td colspan="2" class="program-view-more">and ${items.length - MAX_ROWS} more</td>`;
                rows.push(more);
            }
            this.varBody.replaceChildren(...rows);
        }
    }

    flash(row) {
        if (this.motion?.matches || typeof row.animate !== 'function') return;
        row.animate(
            [{ backgroundColor: 'rgba(255, 200, 50, 0.35)' }, { backgroundColor: 'rgba(255, 200, 50, 0)' }],
            { duration: 700, easing: 'ease-out' }
        );
    }

    renderMemory(machine) {
        const layout = this.emulator.basicReady ? readMemoryLayout(machine) : null;
        if (!layout) {
            this.memoryHtml = '';
            this.memoryBar.replaceChildren();
            this.memoryLegend.replaceChildren();
            this.memoryBar.setAttribute('aria-label', 'BASIC memory is not set up yet.');
            return;
        }
        const total = layout.top - layout.program;
        const sizes = MEMORY_AREAS.map(area => ({ ...area, bytes: layout[area.to] - layout[area.from] }));
        const bar = sizes.map(({ key, label, bytes }) => bytes > 0
            ? `<span class="basic-memory-${key}" style="flex-grow: ${bytes}" title="${label}: ${bytes} bytes"></span>`
            : '').join('');
        const legend = sizes.map(({ key, label, from, bytes }) =>
            `<li title="From $${layout[from].toString(16).toUpperCase().padStart(4, '0')}">` +
            `<span class="basic-memory-swatch basic-memory-${key}"></span>${label} <b>${bytes}</b></li>`).join('');
        const html = bar + legend;
        if (html === this.memoryHtml) return;
        this.memoryHtml = html;
        this.memoryBar.innerHTML = bar;
        this.memoryLegend.innerHTML = legend;
        this.memoryBar.setAttribute('aria-label', `BASIC memory, ${total} bytes: ` +
            sizes.map(({ label, bytes }) => `${label.toLowerCase()} ${bytes}`).join(', '));
    }
}

//
// Show the live program view in `root`.
// @returns {ProgramView}
//
export function attachProgramView(emulator, editor, root) {
    return new ProgramView(emulator, editor, root);
}
