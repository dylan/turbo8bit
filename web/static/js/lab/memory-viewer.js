//
// @fileoverview Live memory viewer for the Assembly lab
// @module lab/memory-viewer
//
// A hex dump of 64 bytes as the CPU sees them, refreshed as the program runs
// or steps. Bytes that changed since the last refresh are highlighted, as are
// the instruction at the program counter and the bytes on the stack, so the
// effect of each instruction on memory is visible as it happens.
//
// Reads use machine.peek(): banking-aware, but never acknowledging an
// interrupt or clearing a collision latch the program is waiting for.
//
// @see https://www.turbo8bit.com/
//

const COLUMNS = 8;
const ROWS = 8;
const PAGE_BYTES = COLUMNS * ROWS;

const hex = (value, digits) => value.toString(16).toUpperCase().padStart(digits, '0');

// PETSCII codes with an obvious ASCII look-alike; the rest show as dots.
function petsciiGlyph(byte) {
    if (byte >= 0x20 && byte <= 0x5A) return String.fromCharCode(byte);
    return '.';
}

export class MemoryViewer {
    //
    // @param {HTMLElement} container - Holds .memory-address, [data-goto],
    //   [data-step] controls and the .memory-dump grid
    // @param {C64Machine} machine
    // @param {Object} [options]
    // @param {Function} [options.resolve] - (name) => address of a symbol, or undefined
    // @param {Function} [options.programStart] - () => address of the assembled program
    //
    constructor(container, machine, { resolve = () => undefined, programStart = () => 0xC000 } = {}) {
        this.container = container;
        this.machine = machine;
        this.resolve = resolve;
        this.programStart = programStart;
        this.address = programStart();
        this.previous = null;

        this.input = container.querySelector('.memory-address');
        this.dump = container.querySelector('.memory-dump');
        this.buildGrid();

        this.input.addEventListener('change', () => this.goTo(this.input.value));
        this.input.addEventListener('keydown', event => {
            if (event.key === 'Enter') {
                event.preventDefault();
                this.goTo(this.input.value);
            }
        });
        container.addEventListener('click', event => {
            const target = event.target.closest('[data-goto], [data-step]');
            if (!target) return;
            if (target.dataset.goto === 'program') {
                this.setAddress(this.programStart());
            } else if (target.dataset.goto !== undefined) {
                this.setAddress(Number(target.dataset.goto));
            } else {
                this.setAddress(this.address + Number(target.dataset.step));
            }
        });
    }

    buildGrid() {
        this.rows = [];
        const fragment = document.createDocumentFragment();
        for (let row = 0; row < ROWS; row++) {
            const line = document.createElement('div');
            line.className = 'memory-row';
            const label = document.createElement('span');
            label.className = 'memory-row-address';
            const bytes = [];
            line.appendChild(label);
            for (let column = 0; column < COLUMNS; column++) {
                const cell = document.createElement('span');
                cell.className = 'memory-byte';
                bytes.push(cell);
                line.appendChild(cell);
            }
            const text = document.createElement('span');
            text.className = 'memory-text';
            line.appendChild(text);
            fragment.appendChild(line);
            this.rows.push({ label, bytes, text });
        }
        this.dump.replaceChildren(fragment);
    }

    //
    // Parse "$C000", "49152", "0xC000" or a symbol from the last assembly.
    //
    parseAddress(text) {
        const value = text.trim();
        let address;
        if (/^\$[0-9a-f]+$/i.test(value)) address = parseInt(value.slice(1), 16);
        else if (/^0x[0-9a-f]+$/i.test(value)) address = parseInt(value.slice(2), 16);
        else if (/^\d+$/.test(value)) address = parseInt(value, 10);
        else address = this.resolve(value.toUpperCase());
        return Number.isInteger(address) && address >= 0 && address <= 0xFFFF ? address : null;
    }

    goTo(text) {
        const address = this.parseAddress(text);
        if (address === null) {
            this.input.setAttribute('aria-invalid', 'true');
            return;
        }
        this.input.removeAttribute('aria-invalid');
        this.setAddress(address);
    }

    setAddress(address) {
        // Rows stay aligned to 8 bytes so addresses read like a monitor's.
        this.address = Math.max(0, Math.min(0x10000 - PAGE_BYTES, address & ~(COLUMNS - 1)));
        this.previous = null;
        this.refresh();
    }

    //
    // Redraw from the machine, marking bytes changed since the last refresh
    //
    refresh() {
        const machine = this.machine;
        const pc = machine.cpu.PC;
        const stackTop = 0x100 + machine.cpu.SP;
        const values = new Uint8Array(PAGE_BYTES);
        for (let i = 0; i < PAGE_BYTES; i++) values[i] = machine.peek(this.address + i);

        if (document.activeElement !== this.input) {
            this.input.value = '$' + hex(this.address, 4);
        }

        for (let row = 0; row < ROWS; row++) {
            const { label, bytes, text } = this.rows[row];
            const rowAddress = this.address + row * COLUMNS;
            label.textContent = '$' + hex(rowAddress, 4);
            let glyphs = '';
            for (let column = 0; column < COLUMNS; column++) {
                const offset = row * COLUMNS + column;
                const address = rowAddress + column;
                const value = values[offset];
                const cell = bytes[column];
                cell.textContent = hex(value, 2);
                cell.title = `$${hex(address, 4)} (${address}) = ${value} (%${value.toString(2).padStart(8, '0')})`;
                cell.classList.toggle('changed', this.previous !== null && this.previous[offset] !== value);
                cell.classList.toggle('pc', address === pc);
                cell.classList.toggle('stack', address > stackTop && address <= 0x1FF);
                glyphs += petsciiGlyph(value);
            }
            text.textContent = glyphs;
        }
        this.previous = values;
    }
}
