//
// @fileoverview Code Editor - Syntax-highlighted editor for C64 BASIC and Assembly
// @module emulator/editor
//
// This module provides a code editor component for C64 programs:
// - Syntax highlighting for BASIC and 6502 assembly
// - Real-time syntax error highlighting
// - Line numbers with error indicators
// - Monospace font with retro styling
// - Direct loading into C64 emulator memory
// - Copy/paste and standard editing features
//
// @see https://www.turbo8bit.com/
//

import {
    BASICTokenizer,
    highlightBasic,
    highlightAssembly,
    TokenType,
    BASIC_START
} from './basic-tokenizer.js';

// ============================================================================
// CODE EDITOR CLASS
// ============================================================================

//
// Where two versions of a text differ, as lines: lines [first, endOld) of
// the old version became lines [first, endNew) of the new one, and the
// lines before and after are the same in both.
// @param {string[]} before
// @param {string[]} after
// @returns {{first: number, endOld: number, endNew: number}}
//
export function changedLines(before, after) {
    let first = 0;
    while (first < before.length && first < after.length && before[first] === after[first]) first++;
    let endOld = before.length;
    let endNew = after.length;
    while (endOld > first && endNew > first && before[endOld - 1] === after[endNew - 1]) {
        endOld--;
        endNew--;
    }
    return { first, endOld, endNew };
}

//
// CodeEditor - A syntax-highlighted code editor for C64 BASIC and Assembly
//
export class CodeEditor {
    //
    // Create a code editor
    // @param {HTMLElement|string} container - Container element or selector
    // @param {Object} options - Configuration options
    //
    constructor(container, options = {}) {
        this.container = typeof container === 'string'
            ? document.querySelector(container)
            : container;

        if (!this.container) {
            throw new Error('CodeEditor: Container element not found');
        }

        this.options = {
            language: options.language || 'basic', // 'basic' or 'asm'
            theme: options.theme || 'c64',
            tabSize: options.tabSize || 2,
            fontSize: options.fontSize || 14,
            lineNumbers: options.lineNumbers !== false,
            highlightErrors: options.highlightErrors !== false,
            onLoad: options.onLoad || null,
            onChange: options.onChange || null,
            ...options
        };

        this.tokenizer = new BASICTokenizer();
        this.errors = [];
        // Errors reported by a build (assemble/tokenize) rather than live validation.
        this.reportedErrors = [];
        this.info = '';
        this.value = '';
        this.changeListeners = new Set();

        this.init();
    }

    //
    // Initialize the editor UI
    // @private
    //
    init() {
        // Create editor structure
        this.container.classList.add('basic-editor');

        // Determine button layout based on language
        const isAsm = this.options.language === 'asm';
        const toolbarButtons = isAsm ? `
            <button class="editor-btn run-btn" title="Assemble and Run">
                <span class="btn-icon" aria-hidden="true">▶</span> Run
            </button>
            <button class="editor-btn step-btn" title="Step one instruction">
                <span class="btn-icon" aria-hidden="true">⏭</span> Step
            </button>
            <button class="editor-btn stop-btn" title="Stop execution">
                <span class="btn-icon" aria-hidden="true">⏹</span> Stop
            </button>
        ` : `
            <button class="editor-btn load-btn" title="Load and Run">
                <span class="btn-icon" aria-hidden="true">▶</span> Run
            </button>
        `;

        this.container.innerHTML = `
            <div class="editor-toolbar">
                <div class="toolbar-left">
                    <div class="search-container">
                        <input type="text" class="search-input" aria-label="Search code" placeholder="Search..." title="F3 to search, Ctrl+F3 to search selection">
                        <button class="search-btn" aria-label="Find next" title="Find next (F3)">🔍</button>
                    </div>
                </div>
                <div class="toolbar-right">
                    ${toolbarButtons}
                </div>
            </div>
            <div class="editor-container">
                <div class="line-numbers" aria-hidden="true"></div>
                <div class="editor-wrapper">
                    <textarea class="editor-textarea" aria-label="${isAsm ? 'Assembly code editor' : 'BASIC code editor'}" title="Tab to indent, Shift+Tab to leave the editor" spellcheck="false" autocomplete="off" autocorrect="off" autocapitalize="off"></textarea>
                    <div class="editor-highlight" aria-hidden="true"></div>
                </div>
            </div>
            <div class="editor-status">
                <span class="status-text">Ready</span>
                <span class="error-count"></span>
            </div>
        `;

        // Track highlighted line for debugging
        this.highlightedLine = null;
        // Gutter marks from a running program, kept across gutter rebuilds
        this.activity = { runningLine: null, heat: new Map() };

        // Search state
        this.searchText = '';

        // Get references to elements
        this.textarea = this.container.querySelector('.editor-textarea');
        this.highlight = this.container.querySelector('.editor-highlight');
        this.lineNumbers = this.container.querySelector('.line-numbers');
        this.statusText = this.container.querySelector('.status-text');
        this.errorCount = this.container.querySelector('.error-count');
        this.editorContainer = this.container.querySelector('.editor-container');

        // Button references (may be null depending on mode)
        this.loadBtn = this.container.querySelector('.load-btn');
        this.runBtn = this.container.querySelector('.run-btn');
        this.stepBtn = this.container.querySelector('.step-btn');
        this.stopBtn = this.container.querySelector('.stop-btn');

        // Search elements
        this.searchInput = this.container.querySelector('.search-input');
        this.searchBtn = this.container.querySelector('.search-btn');

        // Bind events
        this.bindEvents();

        // Set font size
        this.setFontSize(this.options.fontSize);

        // Initial update
        this.updateHighlight();
        this.updateLineNumbers();
    }

    //
    // Bind event handlers
    // @private
    //
    bindEvents() {
        // Leave paste native: the textarea normalizes line endings and retains undo.
        this.textarea.addEventListener('input', () => {
            this.value = this.textarea.value;
            this.reportedErrors = [];
            this.info = '';
            this.updateHighlight();
            this.updateLineNumbers();
            this.validateCode();
            this.notifyChange();
        });

        // Sync scroll between textarea and highlight
        this.textarea.addEventListener('scroll', () => {
            this.highlight.scrollTop = this.textarea.scrollTop;
            this.highlight.scrollLeft = this.textarea.scrollLeft;
            this.lineNumbers.scrollTop = this.textarea.scrollTop;
        });

        // Focus handling for highlighted border
        this.textarea.addEventListener('focus', () => {
            this.editorContainer.classList.add('focused');
        });

        this.textarea.addEventListener('blur', () => {
            this.editorContainer.classList.remove('focused');
        });

        // Handle tab key and search shortcuts
        this.textarea.addEventListener('keydown', (e) => {
            if (e.key === 'Tab' && !e.shiftKey && !e.ctrlKey && !e.altKey && !e.metaKey) {
                e.preventDefault();
                this.insertText(' '.repeat(this.options.tabSize));
            }
            // Ctrl+F3: Search for selected text
            if (e.key === 'F3' && e.ctrlKey) {
                e.preventDefault();
                const selection = this.getSelectedText();
                if (selection) {
                    this.searchInput.value = selection;
                    this.searchText = selection;
                    this.findNext();
                }
            }
            // F3: Find next
            else if (e.key === 'F3') {
                e.preventDefault();
                if (this.searchInput.value) {
                    this.searchText = this.searchInput.value;
                    this.findNext();
                } else {
                    this.searchInput.focus();
                }
            }
        });

        // Search input handling
        this.searchInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === 'F3') {
                e.preventDefault();
                this.searchText = this.searchInput.value;
                this.findNext();
            }
            if (e.key === 'Escape') {
                this.textarea.focus();
            }
        });

        // Search button
        this.searchBtn.addEventListener('click', () => {
            this.searchText = this.searchInput.value;
            this.findNext();
        });

        // Load button (BASIC mode)
        if (this.loadBtn) {
            this.loadBtn.addEventListener('click', () => {
                if (this.options.onLoad) {
                    const result = this.tokenize();
                    this.options.onLoad(result);
                }
            });
        }

        // Run button (ASM mode)
        if (this.runBtn) {
            this.runBtn.addEventListener('click', () => {
                if (this.options.onRun) {
                    this.options.onRun();
                }
            });
        }

        // Step button (ASM mode)
        if (this.stepBtn) {
            this.stepBtn.addEventListener('click', () => {
                if (this.options.onStep) {
                    this.options.onStep();
                }
            });
        }

        // Stop button (ASM mode)
        if (this.stopBtn) {
            this.stopBtn.addEventListener('click', () => {
                if (this.options.onStop) {
                    this.options.onStop();
                }
            });
        }

    }

    //
    // Get currently selected text
    // @returns {string} Selected text or empty string
    //
    getSelectedText() {
        const start = this.textarea.selectionStart;
        const end = this.textarea.selectionEnd;
        return this.textarea.value.substring(start, end);
    }

    //
    // Find next occurrence of search text
    //
    findNext() {
        if (!this.searchText) {
            return;
        }

        const text = this.textarea.value.toLowerCase();
        const search = this.searchText.toLowerCase();
        const cursorPos = this.textarea.selectionEnd;

        // Search from cursor position
        let index = text.indexOf(search, cursorPos);

        // Wrap around to beginning if not found
        if (index === -1) {
            index = text.indexOf(search);
        }

        if (index !== -1) {
            this.textarea.focus();
            this.textarea.setSelectionRange(index, index + this.searchText.length);
            // Scroll the selection into view
            // Calculate line number and scroll
            const linesBefore = this.textarea.value.substring(0, index).split('\n');
            const lineNum = linesBefore.length;
            this.scrollToLine(lineNum);
        } else {
            this.statusText.textContent = `"${this.searchText}" not found`;
        }
    }

    //
    // Scroll editor to show a specific line
    // @param {number} lineNum - 1-based line number
    //
    scrollToLine(lineNum) {
        const lineHeight = parseInt(getComputedStyle(this.textarea).lineHeight) || 20;
        const targetScroll = (lineNum - 3) * lineHeight;  // Show some context above
        this.textarea.scrollTop = Math.max(0, targetScroll);
        this.highlight.scrollTop = this.textarea.scrollTop;
        this.lineNumbers.scrollTop = this.textarea.scrollTop;
    }

    //
    // Highlight a specific line in the editor (for debugging)
    // @param {number|null} lineNum - 1-based line number, or null to clear
    //
    highlightLine(lineNum) {
        this.highlightedLine = lineNum;
        this.updateLineNumbers();

        if (lineNum !== null) {
            this.scrollToLine(lineNum);
        }
    }

    //
    // Clear the debug line highlight
    //
    clearHighlight() {
        this.highlightedLine = null;
        this.updateLineNumbers();
    }

    //
    // Mark the gutter with what a running program is doing, without
    // scrolling: the line being run, and how hot each line is.
    // @param {number|null} runningLine - 1-based line, or null
    // @param {Map<number, number>} heat - 1-based line to a level from 0 to 1
    //
    setLineActivity(runningLine, heat = new Map()) {
        this.activity = { runningLine, heat };
        this.applyLineActivity();
    }

    // Decorates the existing gutter rows, so a refresh several times a
    // second neither rebuilds them nor disturbs a hovered error tooltip.
    applyLineActivity(fromRow = 0) {
        const { runningLine, heat } = this.activity;
        const rows = this.lineNumbers.children;
        for (let i = fromRow; i < rows.length; i++) {
            const row = rows[i];
            const level = heat.get(i + 1) ?? 0;
            row.classList.toggle('running', runningLine === i + 1);
            row.classList.toggle('hot', level > 0);
            if (level > 0) row.style.setProperty('--heat', level.toFixed(2));
            else row.style.removeProperty('--heat');
        }
    }

    //
    // Insert text at cursor position
    // @param {string} text - Text to insert
    //
    insertText(text) {
        this.textarea.focus();
        // Unlike assigning value or setRangeText(), this preserves native undo
        // and emits the input event that updates highlighting and onChange.
        document.execCommand('insertText', false, text);
    }

    //
    // Update the syntax highlighting overlay. The overlay holds one element
    // per line, so typing in a long program redraws only the lines between
    // the unchanged start and end of the text. When the overlay is not what
    // was last drawn, it is drawn afresh.
    // @private
    //
    updateHighlight() {
        const lines = this.textarea.value.split('\n');
        const shown = this.overlayLines;
        const rows = this.highlight.children;
        const drawLines = from => from.map(line => `<div>${this.highlightLineHtml(line)}\n</div>`).join('');
        this.overlayLines = lines;
        if (!shown || rows.length !== shown.length) {
            this.highlight.innerHTML = drawLines(lines);
            return;
        }

        const { first, endOld, endNew } = changedLines(shown, lines);
        for (let i = endOld - 1; i >= first; i--) rows[i].remove();
        const html = drawLines(lines.slice(first, endNew));
        if (!html) return;
        if (first < rows.length) rows[first].insertAdjacentHTML('beforebegin', html);
        else this.highlight.insertAdjacentHTML('beforeend', html);
    }

    // Both highlighters work a line at a time, so a line can be drawn alone.
    highlightLineHtml(line) {
        const tokens = this.options.language === 'asm'
            ? highlightAssembly(line)
            : highlightBasic(line);
        let html = '';
        for (const token of tokens) {
            const escaped = this.escapeHtml(token.text);
            html += token.type === TokenType.DEFAULT
                ? escaped
                : `<span class="token-${token.type}">${escaped}</span>`;
        }
        return html;
    }

    //
    // Update line numbers. Typing in a long program must not rebuild
    // thousands of rows, so the gutter is patched: rows come and go at the
    // end (row i is always line i + 1), and only the rows whose marker or
    // debug highlight may have changed are restyled. When the rows are not
    // what was last built, they are built afresh.
    // @private
    //
    updateLineNumbers() {
        if (!this.options.lineNumbers) {
            this.lineNumbers.style.display = 'none';
            return;
        }

        const count = this.textarea.value.split('\n').length;
        // The gutter is given the width of its longest number (plus the rows'
        // padding and its border) rather than sizing itself to its rows, so
        // that nothing else changing in the editor, such as the status bar,
        // makes the browser measure thousands of rows again.
        const digits = String(count).length;
        if (digits !== this.gutterDigits) {
            this.gutterDigits = digits;
            this.lineNumbers.style.width = `calc(${digits}ch + 1rem + 1px)`;
        }
        // One marker per line; an error outranks a warning.
        const markers = new Map();
        for (const problem of this.allErrors()) {
            const existing = markers.get(problem.line);
            if (!existing || (existing.type !== 'error' && problem.type === 'error')) {
                markers.set(problem.line, problem);
            }
        }

        const rows = this.lineNumbers.children;
        const built = this.gutter;
        this.gutter = { count, markers, highlightedLine: this.highlightedLine };
        if (!built || rows.length !== built.count) {
            let html = '';
            for (let i = 1; i <= count; i++) {
                const problem = markers.get(i);
                let cls = 'line-number';
                if (problem) cls += problem.type === 'error' ? ' error' : ' warning';
                if (this.highlightedLine === i) cls += ' debug-highlight';
                const title = problem ? ` title="${this.escapeHtml(problem.message).replace(/"/g, '&quot;')}"` : '';
                html += `<div class="${cls}"${title}>${i}</div>`;
            }
            this.lineNumbers.innerHTML = html;
            this.applyLineActivity();
            return;
        }

        let added = '';
        for (let i = built.count + 1; i <= count; i++) added += `<div class="line-number">${i}</div>`;
        if (added) this.lineNumbers.insertAdjacentHTML('beforeend', added);
        while (rows.length > count) rows[rows.length - 1].remove();

        const restyle = new Set([...built.markers.keys(), ...markers.keys(),
            built.highlightedLine, this.highlightedLine]);
        for (let line = built.count + 1; line <= count; line++) restyle.add(line);
        for (const line of restyle) {
            const row = rows[line - 1];
            if (!row) continue;
            const problem = markers.get(line);
            row.classList.toggle('error', problem?.type === 'error');
            row.classList.toggle('warning', !!problem && problem.type !== 'error');
            row.classList.toggle('debug-highlight', this.highlightedLine === line);
            if (problem) row.title = problem.message;
            else row.removeAttribute('title');
        }
        if (count > built.count) this.applyLineActivity(built.count);
    }

    //
    // Build errors first, then live validation results. The live checks
    // usually find the errors a build reported, so each counts once.
    //
    allErrors() {
        const seen = new Set();
        return [...this.reportedErrors, ...this.errors].filter(problem => {
            const key = `${problem.type}|${problem.line}|${problem.message}`;
            if (seen.has(key)) return false;
            seen.add(key);
            return true;
        });
    }

    //
    // Validate the code and update error markers
    // @private
    //
    validateCode() {
        if (!this.options.highlightErrors) {
            this.errors = [];
        } else if (this.options.validator) {
            this.errors = this.options.validator(this.textarea.value);
        } else if (this.options.language === 'basic') {
            this.errors = this.tokenizer.validate(this.textarea.value);
        } else {
            this.errors = [];
        }
        this.updateLineNumbers();
        this.updateStatus();
    }

    //
    // Update status bar
    // @private
    //
    updateStatus() {
        const lines = this.textarea.value.split('\n').length;
        const chars = this.textarea.value.length;
        const problems = this.allErrors();

        if (problems.length === 0) {
            this.statusText.textContent = this.info
                || `${lines} line${lines !== 1 ? 's' : ''}, ${chars} characters`;
            this.errorCount.textContent = '';
            this.errorCount.className = 'error-count';
        } else {
            const errorCount = problems.filter(e => e.type === 'error').length;
            const warnCount = problems.filter(e => e.type === 'warning').length;
            const first = problems.find(e => e.type === 'error') ?? problems[0];

            this.statusText.textContent = first.line ? `Line ${first.line}: ${first.message}` : first.message;

            let countText = '';
            if (errorCount > 0) countText += `${errorCount} error${errorCount !== 1 ? 's' : ''}`;
            if (warnCount > 0) {
                if (countText) countText += ', ';
                countText += `${warnCount} warning${warnCount !== 1 ? 's' : ''}`;
            }
            this.errorCount.textContent = countText;
            this.errorCount.className = 'error-count ' + (errorCount > 0 ? 'has-errors' : 'has-warnings');
        }
    }

    //
    // Escape HTML special characters
    // @private
    //
    escapeHtml(text) {
        return text
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;');
    }

    //
    // Set the editor value
    // @param {string} text - The text to set
    //
    setValue(text) {
        // A textarea reports its value with \n line endings; keep the value
        // given to listeners the same whether it was typed or set.
        text = text.replace(/\r\n?/g, '\n');
        this.textarea.value = text;
        this.value = text;
        this.reportedErrors = [];
        this.info = '';
        this.updateHighlight();
        this.updateLineNumbers();
        this.validateCode();
        this.notifyChange();
    }

    //
    // Call listener(value) whenever the text changes, by typing or setValue().
    // @returns {Function} Unsubscribe
    //
    onValueChange(listener) {
        this.changeListeners.add(listener);
        return () => this.changeListeners.delete(listener);
    }

    notifyChange() {
        if (this.options.onChange) {
            this.options.onChange(this.value);
        }
        for (const listener of this.changeListeners) listener(this.value);
    }

    //
    // Show errors found when building the program (assembling or tokenizing)
    // in the gutter and status bar, and scroll to the first one. They stay
    // until the text changes.
    // @param {Array<{line: number, message: string, type?: string}>} errors
    //
    showErrors(errors) {
        this.reportedErrors = errors.map(error => ({ type: 'error', ...error }));
        this.updateLineNumbers();
        this.updateStatus();
        const first = this.reportedErrors.find(error => error.line);
        if (first) this.scrollToLine(first.line);
    }

    //
    // Show a note about the last build in the status bar until the text changes.
    // @param {string} message
    //
    showInfo(message) {
        this.info = message;
        this.updateStatus();
    }

    //
    // Add a control to the toolbar, beside the search box.
    // @param {HTMLElement} element
    //
    addToolbarItem(element) {
        this.container.querySelector('.toolbar-left').appendChild(element);
    }

    //
    // Get the editor value
    // @returns {string} The current text
    //
    getValue() {
        return this.textarea.value;
    }

    //
    // Tokenize the current program
    // @returns {{ bytes: Uint8Array, errors: Array, lines: Array }}
    //
    tokenize() {
        return this.tokenizer.tokenize(this.textarea.value, BASIC_START);
    }

    //
    // Get current errors
    // @returns {Array} Array of error objects
    //
    getErrors() {
        return this.errors;
    }

    //
    // Set the font size
    // @param {number} size - Font size in pixels
    //
    setFontSize(size) {
        this.options.fontSize = size;
        this.textarea.style.fontSize = `${size}px`;
        this.highlight.style.fontSize = `${size}px`;
        this.lineNumbers.style.fontSize = `${size}px`;

        // Line height should be approximately 1.4x font size
        const lineHeight = Math.round(size * 1.4);
        this.textarea.style.lineHeight = `${lineHeight}px`;
        this.highlight.style.lineHeight = `${lineHeight}px`;
        this.lineNumbers.style.lineHeight = `${lineHeight}px`;
    }

    //
    // Set the language mode
    // @param {string} lang - 'basic' or 'asm'
    //
    setLanguage(lang) {
        this.options.language = lang;
        this.textarea.setAttribute('aria-label', lang === 'asm' ? 'Assembly code editor' : 'BASIC code editor');
        this.overlayLines = null;
        this.updateHighlight();
        this.validateCode();
    }

    //
    // Focus the editor
    //
    focus() {
        this.textarea.focus();
    }

    //
    // Set the onLoad callback
    // @param {Function} callback - Called when Load button is clicked
    //
    setOnLoad(callback) {
        this.options.onLoad = callback;
    }

    //
    // Set the onRun callback (ASM mode)
    // @param {Function} callback - Called when Run button is clicked
    //
    setOnRun(callback) {
        this.options.onRun = callback;
    }

    //
    // Set the onStep callback (ASM mode)
    // @param {Function} callback - Called when Step button is clicked
    //
    setOnStep(callback) {
        this.options.onStep = callback;
    }

    //
    // Set the onStop callback (ASM mode)
    // @param {Function} callback - Called when Stop button is clicked
    //
    setOnStop(callback) {
        this.options.onStop = callback;
    }

    //
    // Enable or disable error highlighting
    // @param {boolean} enabled - Whether to show errors
    //
    setHighlightErrors(enabled) {
        this.options.highlightErrors = enabled;
        this.validateCode();
        this.updateLineNumbers();
    }
}

// Backwards compatibility alias
export const BASICEditor = CodeEditor;

export default CodeEditor;
