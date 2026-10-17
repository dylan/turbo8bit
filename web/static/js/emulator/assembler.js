//
// @fileoverview 6502 Assembler for Turbo8bit
// @module emulator/assembler
//
// A simple but educational 6502 assembler that converts assembly source code
// into machine code that can be executed by the C64 emulator.
//
// Features:
// - All official 6502 opcodes
// - Common addressing modes (immediate, zero page, absolute, indexed, indirect)
// - Labels, with a colon or starting in the first column
// - Expressions: $hex, %binary, decimal, 'c', symbols, * (current address),
//   + - * / and parentheses, with < and > selecting the low or high byte
// - ORG or *= to set the address, SYMBOL = value / EQU for constants
// - BYTE/WORD/TEXT/ASCIIZ data (also .byte or ACME-style !byte); quoted
//   text is stored as PETSCII, so "Hello" prints in the C64's upper case
// - Detailed error messages for learning
//
// Usage:
//   import { Assembler } from './assembler.js';
//   const asm = new Assembler();
//   const result = asm.assemble(sourceCode);
//   if (result.success) {
//     machine.loadCode(result.bytes, result.startAddress);
//   }
//
// @see https://www.turbo8bit.com/
//

// ============================================================================
// OPCODE TABLES
// ============================================================================

//
// Addressing mode constants
//
const MODE = {
    IMP: 'implied',      // No operand (e.g., RTS)
    ACC: 'accumulator',  // Operates on A (e.g., ASL A)
    IMM: 'immediate',    // #$nn
    ZP: 'zeropage',     // $nn
    ZPX: 'zeropage,x',   // $nn,X
    ZPY: 'zeropage,y',   // $nn,Y
    ABS: 'absolute',     // $nnnn
    ABX: 'absolute,x',   // $nnnn,X
    ABY: 'absolute,y',   // $nnnn,Y
    IND: 'indirect',     // ($nnnn)
    IZX: 'indirect,x',   // ($nn,X)
    IZY: 'indirect,y',   // ($nn),Y
    REL: 'relative'      // Branch offset
};

//
// Complete 6502 instruction set with opcodes for each addressing mode
// Format: { mnemonic: { mode: opcode, ... } }
//
const OPCODES = {
    // Load/Store
    LDA: { [MODE.IMM]: 0xA9, [MODE.ZP]: 0xA5, [MODE.ZPX]: 0xB5, [MODE.ABS]: 0xAD, [MODE.ABX]: 0xBD, [MODE.ABY]: 0xB9, [MODE.IZX]: 0xA1, [MODE.IZY]: 0xB1 },
    LDX: { [MODE.IMM]: 0xA2, [MODE.ZP]: 0xA6, [MODE.ZPY]: 0xB6, [MODE.ABS]: 0xAE, [MODE.ABY]: 0xBE },
    LDY: { [MODE.IMM]: 0xA0, [MODE.ZP]: 0xA4, [MODE.ZPX]: 0xB4, [MODE.ABS]: 0xAC, [MODE.ABX]: 0xBC },
    STA: { [MODE.ZP]: 0x85, [MODE.ZPX]: 0x95, [MODE.ABS]: 0x8D, [MODE.ABX]: 0x9D, [MODE.ABY]: 0x99, [MODE.IZX]: 0x81, [MODE.IZY]: 0x91 },
    STX: { [MODE.ZP]: 0x86, [MODE.ZPY]: 0x96, [MODE.ABS]: 0x8E },
    STY: { [MODE.ZP]: 0x84, [MODE.ZPX]: 0x94, [MODE.ABS]: 0x8C },

    // Transfer
    TAX: { [MODE.IMP]: 0xAA },
    TAY: { [MODE.IMP]: 0xA8 },
    TXA: { [MODE.IMP]: 0x8A },
    TYA: { [MODE.IMP]: 0x98 },
    TSX: { [MODE.IMP]: 0xBA },
    TXS: { [MODE.IMP]: 0x9A },

    // Stack
    PHA: { [MODE.IMP]: 0x48 },
    PHP: { [MODE.IMP]: 0x08 },
    PLA: { [MODE.IMP]: 0x68 },
    PLP: { [MODE.IMP]: 0x28 },

    // Arithmetic
    ADC: { [MODE.IMM]: 0x69, [MODE.ZP]: 0x65, [MODE.ZPX]: 0x75, [MODE.ABS]: 0x6D, [MODE.ABX]: 0x7D, [MODE.ABY]: 0x79, [MODE.IZX]: 0x61, [MODE.IZY]: 0x71 },
    SBC: { [MODE.IMM]: 0xE9, [MODE.ZP]: 0xE5, [MODE.ZPX]: 0xF5, [MODE.ABS]: 0xED, [MODE.ABX]: 0xFD, [MODE.ABY]: 0xF9, [MODE.IZX]: 0xE1, [MODE.IZY]: 0xF1 },

    // Compare
    CMP: { [MODE.IMM]: 0xC9, [MODE.ZP]: 0xC5, [MODE.ZPX]: 0xD5, [MODE.ABS]: 0xCD, [MODE.ABX]: 0xDD, [MODE.ABY]: 0xD9, [MODE.IZX]: 0xC1, [MODE.IZY]: 0xD1 },
    CPX: { [MODE.IMM]: 0xE0, [MODE.ZP]: 0xE4, [MODE.ABS]: 0xEC },
    CPY: { [MODE.IMM]: 0xC0, [MODE.ZP]: 0xC4, [MODE.ABS]: 0xCC },

    // Logical
    AND: { [MODE.IMM]: 0x29, [MODE.ZP]: 0x25, [MODE.ZPX]: 0x35, [MODE.ABS]: 0x2D, [MODE.ABX]: 0x3D, [MODE.ABY]: 0x39, [MODE.IZX]: 0x21, [MODE.IZY]: 0x31 },
    ORA: { [MODE.IMM]: 0x09, [MODE.ZP]: 0x05, [MODE.ZPX]: 0x15, [MODE.ABS]: 0x0D, [MODE.ABX]: 0x1D, [MODE.ABY]: 0x19, [MODE.IZX]: 0x01, [MODE.IZY]: 0x11 },
    EOR: { [MODE.IMM]: 0x49, [MODE.ZP]: 0x45, [MODE.ZPX]: 0x55, [MODE.ABS]: 0x4D, [MODE.ABX]: 0x5D, [MODE.ABY]: 0x59, [MODE.IZX]: 0x41, [MODE.IZY]: 0x51 },
    BIT: { [MODE.ZP]: 0x24, [MODE.ABS]: 0x2C },

    // Shift/Rotate
    ASL: { [MODE.ACC]: 0x0A, [MODE.ZP]: 0x06, [MODE.ZPX]: 0x16, [MODE.ABS]: 0x0E, [MODE.ABX]: 0x1E },
    LSR: { [MODE.ACC]: 0x4A, [MODE.ZP]: 0x46, [MODE.ZPX]: 0x56, [MODE.ABS]: 0x4E, [MODE.ABX]: 0x5E },
    ROL: { [MODE.ACC]: 0x2A, [MODE.ZP]: 0x26, [MODE.ZPX]: 0x36, [MODE.ABS]: 0x2E, [MODE.ABX]: 0x3E },
    ROR: { [MODE.ACC]: 0x6A, [MODE.ZP]: 0x66, [MODE.ZPX]: 0x76, [MODE.ABS]: 0x6E, [MODE.ABX]: 0x7E },

    // Increment/Decrement
    INC: { [MODE.ZP]: 0xE6, [MODE.ZPX]: 0xF6, [MODE.ABS]: 0xEE, [MODE.ABX]: 0xFE },
    DEC: { [MODE.ZP]: 0xC6, [MODE.ZPX]: 0xD6, [MODE.ABS]: 0xCE, [MODE.ABX]: 0xDE },
    INX: { [MODE.IMP]: 0xE8 },
    INY: { [MODE.IMP]: 0xC8 },
    DEX: { [MODE.IMP]: 0xCA },
    DEY: { [MODE.IMP]: 0x88 },

    // Branch
    BPL: { [MODE.REL]: 0x10 },
    BMI: { [MODE.REL]: 0x30 },
    BVC: { [MODE.REL]: 0x50 },
    BVS: { [MODE.REL]: 0x70 },
    BCC: { [MODE.REL]: 0x90 },
    BCS: { [MODE.REL]: 0xB0 },
    BNE: { [MODE.REL]: 0xD0 },
    BEQ: { [MODE.REL]: 0xF0 },

    // Jump/Call
    JMP: { [MODE.ABS]: 0x4C, [MODE.IND]: 0x6C },
    JSR: { [MODE.ABS]: 0x20 },
    RTS: { [MODE.IMP]: 0x60 },
    RTI: { [MODE.IMP]: 0x40 },

    // Flags
    CLC: { [MODE.IMP]: 0x18 },
    SEC: { [MODE.IMP]: 0x38 },
    CLI: { [MODE.IMP]: 0x58 },
    SEI: { [MODE.IMP]: 0x78 },
    CLV: { [MODE.IMP]: 0xB8 },
    CLD: { [MODE.IMP]: 0xD8 },
    SED: { [MODE.IMP]: 0xF8 },

    // Other
    BRK: { [MODE.IMP]: 0x00 },
    NOP: { [MODE.IMP]: 0xEA }
};

//
// Get instruction size in bytes based on addressing mode
//
function getInstructionSize(mode) {
    switch (mode) {
        case MODE.IMP:
        case MODE.ACC:
            return 1;
        case MODE.IMM:
        case MODE.ZP:
        case MODE.ZPX:
        case MODE.ZPY:
        case MODE.IZX:
        case MODE.IZY:
        case MODE.REL:
            return 2;
        case MODE.ABS:
        case MODE.ABX:
        case MODE.ABY:
        case MODE.IND:
            return 3;
        default:
            return 1;
    }
}

// ============================================================================
// SOURCE TEXT HELPERS
// ============================================================================

//
// Directive names, accepted bare, with a dot (.byte) or ACME-style bang (!byte).
//
const DIRECTIVES = new Map([
    ['ORG', 'ORG'],
    ['BYTE', 'BYTE'], ['BYT', 'BYTE'], ['DB', 'BYTE'], ['DFB', 'BYTE'],
    ['WORD', 'WORD'], ['DW', 'WORD'],
    ['TEXT', 'TEXT'], ['ASC', 'TEXT'], ['ASCII', 'TEXT'],
    ['ASCIIZ', 'ASCIIZ'],
    ['EQU', 'EQU'],
    ['INCBIN', 'INCBIN'], ['BINARY', 'INCBIN']
]);

function directiveName(word) {
    return DIRECTIVES.get(word.replace(/^[.!]/, '').toUpperCase()) ?? null;
}

function isReservedWord(word) {
    return OPCODES[word.toUpperCase()] !== undefined || directiveName(word) !== null;
}

//
// Remove a trailing ; comment, leaving semicolons inside quotes alone.
//
function stripComment(line) {
    let quote = null;
    for (let i = 0; i < line.length; i++) {
        const ch = line[i];
        if (quote) {
            if (ch === quote) quote = null;
        } else if (ch === '"' || ch === "'") {
            quote = ch;
        } else if (ch === ';') {
            return line.slice(0, i);
        }
    }
    return line;
}

//
// Split a comma-separated operand list, keeping quoted commas.
//
function splitList(text) {
    const items = [];
    let start = 0;
    let quote = null;
    for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        if (quote) {
            if (ch === quote) quote = null;
        } else if (ch === '"' || ch === "'") {
            quote = ch;
        } else if (ch === ',') {
            items.push(text.slice(start, i).trim());
            start = i + 1;
        }
    }
    items.push(text.slice(start).trim());
    return items;
}

//
// The text of a "string" (or multi-character 'string'), or null. A single
// quoted character is left to the expression parser as a character code.
//
function stringLiteral(item) {
    const match = item.match(/^"(.*)"$/) || item.match(/^'(.{2,})'$/);
    return match ? match[1] : null;
}

//
// Store text the way it would be typed on a C64 in its default mode: letters
// as unshifted (upper case) PETSCII, plus the few symbols ASCII lacks.
//
function toPetscii(ch) {
    const code = ch.charCodeAt(0);
    if (code >= 0x61 && code <= 0x7A) return code - 0x20;
    switch (ch) {
        case '£': return 0x5C;
        case '↑': return 0x5E;
        case '←': return 0x5F;
        case 'π': return 0xFF;
    }
    if (code > 0xFF) throw new Error(`Character '${ch}' has no PETSCII code`);
    return code;
}

//
// The expression part of an operand, without its addressing-mode syntax.
//
function operandExpression(operand, mode) {
    const op = operand.trim();
    switch (mode) {
        case MODE.IMM: return op.slice(1);
        case MODE.IZX: return op.replace(/^\(/, '').replace(/,\s*X\s*\)$/i, '');
        case MODE.IZY: return op.replace(/^\(/, '').replace(/\)\s*,\s*Y$/i, '');
        case MODE.IND: return op.slice(1, -1);
        case MODE.ZPX:
        case MODE.ABX:
        case MODE.ZPY:
        case MODE.ABY:
            return op.replace(/,\s*[XY]$/i, '');
        default:
            return op;
    }
}

// ============================================================================
// ASSEMBLER
// ============================================================================

//
// 6502 Assembler
//
// Converts assembly source code into machine code bytes.
//
export class Assembler {
    constructor() {
        this.symbols = new Map();
        this.errors = [];
        this.warnings = [];
        this.currentAddress = 0x0800;  // Default start address (BASIC area)
        this.output = [];
        this.sourceMap = [];  // Maps output bytes to source lines
        this.files = new Map(); // Virtual file system for INCBIN
    }

    //
    // Set virtual files for INCBIN
    // @param {Object} files - Map of filename to Uint8Array or Array of bytes
    //
    setFiles(files) {
        for (const [name, data] of Object.entries(files)) {
            this.files.set(name, data);
        }
    }

    //
    // Assemble source code into machine code
    // @param {string} source - Assembly source code
    // @returns {Object} Assembly result with bytes, errors, and metadata
    //
    assemble(source) {
        this.symbols = new Map();
        this.errors = [];
        this.warnings = [];
        this.output = [];
        this.sourceMap = [];
        this.startAddress = null;
        this.lineAddress = null;
        // Pass-1 mode cache: lineNum -> addressing mode. Pass-2 reuses these so
        // a forward-referenced label that turns out to be zero-page can't shrink
        // an instruction pass-1 sized as absolute (which would mis-align addresses).
        this.lineModes = new Map();
        // Equates whose value was already known before any label was placed.
        this.earlyEquates = new Set();

        const lines = source.split('\n').map((line, index) => {
            const code = stripComment(line);
            return {
                text: line,
                lineNum: index + 1,
                trimmed: code.trim(),
                // A word in the first column is a label even without a colon.
                labelColumn: /^[A-Za-z_]/.test(code)
            };
        });

        // Two-pass assembly
        // Pass 1: Calculate addresses and collect symbols
        this.pass1(lines);

        if (this.errors.length > 0) {
            return this.getResult();
        }

        // Pass 2: Generate code with resolved symbols
        this.pass2(lines);

        return this.getResult();
    }

    //
    // Pass 1: Calculate addresses and collect symbols
    //
    pass1(lines) {
        this.currentAddress = 0x0800;

        // Instruction sizes depend on whether operands fit in zero page, so
        // constants are defined before any instruction is sized, even when
        // they are written below their first use. Equates that refer to
        // labels are resolved in source order by the main pass instead.
        for (const line of lines) {
            if (!line.trimmed) continue;
            try {
                const parsed = this.parseLine(line.trimmed, line.labelColumn);
                if (parsed.directive !== 'EQU' || !parsed.label) continue;
                const value = this.evaluate(parsed.operand);
                if (value !== null && !this.symbols.has(parsed.label)) {
                    this.symbols.set(parsed.label, value);
                    this.earlyEquates.add(line.lineNum);
                }
            } catch (e) {
                // Reported against its line by the main pass.
            }
        }

        for (const line of lines) {
            if (!line.trimmed) continue;
            this.lineAddress = this.currentAddress;

            try {
                const parsed = this.parseLine(line.trimmed, line.labelColumn);

                if (parsed.directive === 'EQU') {
                    this.defineEquate(parsed, line.lineNum);
                    continue;
                }

                if (parsed.label) {
                    this.defineSymbol(parsed.label, this.currentAddress, line.lineNum, 'label');
                }

                if (parsed.directive) {
                    this.handleDirectivePass1(parsed, line.lineNum);
                    continue;
                }

                if (parsed.mnemonic) {
                    this.lineModes.set(line.lineNum, parsed.mode);
                    this.currentAddress += getInstructionSize(parsed.mode);
                }
            } catch (e) {
                this.error(line.lineNum, e.message);
            }
        }
    }

    //
    // Pass 2: Generate machine code
    //
    pass2(lines) {
        this.currentAddress = 0x0800;
        this.output = [];
        this.sourceMap = [];
        this.startAddress = null;

        for (const line of lines) {
            if (!line.trimmed) continue;
            this.lineAddress = this.currentAddress;

            try {
                const parsed = this.parseLine(line.trimmed, line.labelColumn);

                // Handle directives
                if (parsed.directive) {
                    this.handleDirectivePass2(parsed, line.lineNum);
                    continue;
                }

                // Handle instruction
                if (parsed.mnemonic) {
                    // Force the same addressing mode chosen in pass 1 so byte counts match.
                    if (this.lineModes.has(line.lineNum)) {
                        parsed.mode = this.lineModes.get(line.lineNum);
                    }
                    this.emitInstruction(parsed, line.lineNum);
                }
            } catch (e) {
                this.error(line.lineNum, e.message);
            }
        }
    }

    defineEquate(parsed, lineNum) {
        if (!parsed.label) throw new Error('EQU requires a symbol name');
        if (this.earlyEquates.has(lineNum)) return;
        const value = this.evaluate(parsed.operand, { strict: true });
        this.defineSymbol(parsed.label, value, lineNum, 'symbol');
    }

    defineSymbol(name, value, lineNum, kind) {
        if (this.symbols.has(name)) {
            this.error(lineNum, `Duplicate ${kind}: ${name}`);
        } else {
            this.symbols.set(name, value);
        }
    }

    //
    // Parse a single line of assembly whose comment has been removed
    // @param {string} text - Trimmed source text
    // @param {boolean} labelColumn - The text started in the first column
    //
    parseLine(text, labelColumn = false) {
        const result = {
            label: null,
            mnemonic: null,
            directive: null,
            operand: null,
            mode: null
        };

        // Origin: *= $C000
        const origin = text.match(/^\*\s*=\s*(.*)$/);
        if (origin) {
            result.directive = 'ORG';
            result.operand = origin[1].trim();
            return result;
        }

        // Equates: SYMBOL = VALUE, SYMBOL EQU VALUE or SYMBOL: EQU VALUE
        const equate = text.match(/^([A-Za-z_]\w*)\s*=\s*(.*)$/)
            || text.match(/^([A-Za-z_]\w*):?\s+[.!]?EQU(?:\s+(.*))?$/i);
        if (equate) {
            result.directive = 'EQU';
            result.label = equate[1].toUpperCase();
            result.operand = (equate[2] ?? '').trim();
            return result;
        }

        let remaining = text;
        const colonLabel = remaining.match(/^([A-Za-z_]\w*):/);
        if (colonLabel) {
            result.label = colonLabel[1].toUpperCase();
            remaining = remaining.slice(colonLabel[0].length).trim();
        } else if (labelColumn) {
            const word = remaining.match(/^[A-Za-z_]\w*(?=\s|$)/);
            if (word && !isReservedWord(word[0])) {
                result.label = word[0].toUpperCase();
                remaining = remaining.slice(word[0].length).trim();
            }
        }

        if (!remaining) return result;

        // The operand keeps its spacing: TEXT "A  B" has two spaces.
        const first = remaining.match(/^\S+/)[0];
        const operand = remaining.slice(first.length).trim();

        const directive = directiveName(first);
        if (directive) {
            result.directive = directive;
            result.operand = operand;
            return result;
        }
        if (/^[.!]/.test(first)) {
            throw new Error(`Unknown directive: ${first}`);
        }

        const mnemonic = first.toUpperCase();
        if (!OPCODES[mnemonic]) {
            throw new Error(`Unknown instruction: ${mnemonic}`);
        }

        result.mnemonic = mnemonic;
        result.operand = operand;
        result.mode = this.parseAddressingMode(operand, mnemonic);

        return result;
    }

    //
    // Parse addressing mode from operand
    //
    parseAddressingMode(operand, mnemonic) {
        const modes = OPCODES[mnemonic];
        const op = operand.trim();

        // Implied or Accumulator
        if (!op || /^A$/i.test(op)) {
            return modes[MODE.ACC] !== undefined ? MODE.ACC : MODE.IMP;
        }

        // Immediate: #$nn or #nn
        if (op.startsWith('#')) {
            return MODE.IMM;
        }

        // Relative (branches)
        if (modes[MODE.REL] !== undefined) {
            return MODE.REL;
        }

        // Indirect X: ($nn,X) and indirect Y: ($nn),Y
        if (/^\(.*,\s*X\s*\)$/i.test(op)) return MODE.IZX;
        if (/^\(.*\)\s*,\s*Y$/i.test(op)) return MODE.IZY;

        // Indirect: ($nnnn) exists only for JMP; elsewhere parentheses group.
        if (modes[MODE.IND] !== undefined && /^\(.*\)$/.test(op)) {
            return MODE.IND;
        }

        // Indexed: $nnnn,X / $nn,X / $nnnn,Y / $nn,Y
        const indexed = op.match(/^(.*?),\s*([XY])$/i);
        if (indexed) {
            const byX = indexed[2].toUpperCase() === 'X';
            const zeroPage = byX ? MODE.ZPX : MODE.ZPY;
            const value = this.evaluate(indexed[1]);
            if (value !== null && value >= 0 && value <= 0xFF && modes[zeroPage] !== undefined) {
                return zeroPage;
            }
            return byX ? MODE.ABX : MODE.ABY;
        }

        // Zero page or Absolute
        const value = this.evaluate(op);
        if (value !== null && value >= 0 && value <= 0xFF && modes[MODE.ZP] !== undefined) {
            return MODE.ZP;
        }

        return MODE.ABS;
    }

    //
    // Evaluate an expression: numbers ($hex, %binary, decimal, 'c'), symbols,
    // * (the address of the current line), + - * / and parentheses. A leading
    // < or > selects the low or high byte of the whole expression.
    //
    // @param {string} text - Expression source
    // @param {{strict?: boolean}} options - strict reports undefined symbols
    // @returns {number|null} The value, or null if a symbol is not yet defined
    //
    evaluate(text, { strict = false } = {}) {
        const source = text.trim();
        let pos = 0;
        let unresolved = null;

        const invalid = () => new Error(source ? `Invalid expression: ${source}` : 'Missing value');
        const skipSpace = () => {
            while (pos < source.length && /\s/.test(source[pos])) pos++;
        };

        const primary = () => {
            skipSpace();
            const rest = source.slice(pos);
            let match;
            if (rest.startsWith('-')) {
                pos++;
                const value = primary();
                return value === null ? null : -value;
            }
            if (rest.startsWith('(')) {
                pos++;
                const value = sum();
                skipSpace();
                if (source[pos] !== ')') throw invalid();
                pos++;
                return value;
            }
            if (rest.startsWith('*')) {
                pos++;
                if (this.lineAddress === null) unresolved ??= '*';
                return this.lineAddress;
            }
            if ((match = rest.match(/^'(.)'/))) {
                pos += 3;
                return toPetscii(match[1]);
            }
            if ((match = rest.match(/^\$([0-9A-F]+)(?![\w$])/i))) {
                pos += match[0].length;
                return parseInt(match[1], 16);
            }
            if ((match = rest.match(/^0x([0-9A-F]+)(?![\w$])/i))) {
                pos += match[0].length;
                return parseInt(match[1], 16);
            }
            if ((match = rest.match(/^%([01]+)(?![\w$])/))) {
                pos += match[0].length;
                return parseInt(match[1], 2);
            }
            if ((match = rest.match(/^(\d+)(?![\w$])/))) {
                pos += match[0].length;
                return parseInt(match[1], 10);
            }
            if ((match = rest.match(/^[A-Za-z_]\w*/))) {
                pos += match[0].length;
                const name = match[0].toUpperCase();
                if (this.symbols.has(name)) return this.symbols.get(name);
                unresolved ??= match[0];
                return null;
            }
            throw invalid();
        };

        // After a value, * means multiply; where a value is expected, it is the address.
        const product = () => {
            let value = primary();
            for (;;) {
                skipSpace();
                const op = source[pos];
                if (op !== '*' && op !== '/') return value;
                pos++;
                const right = primary();
                if (value === null || right === null) {
                    value = null;
                } else if (op === '*') {
                    value *= right;
                } else if (right === 0) {
                    throw new Error(`Division by zero: ${source}`);
                } else {
                    value = Math.trunc(value / right);
                }
            }
        };

        const sum = () => {
            let value = product();
            for (;;) {
                skipSpace();
                const op = source[pos];
                if (op !== '+' && op !== '-') return value;
                pos++;
                const right = product();
                value = value === null || right === null ? null
                    : op === '+' ? value + right : value - right;
            }
        };

        skipSpace();
        const byteSelector = source[pos] === '<' || source[pos] === '>' ? source[pos++] : null;
        let value = sum();
        skipSpace();
        if (pos < source.length) throw invalid();

        if (value === null) {
            if (strict) throw new Error(`Undefined symbol: ${unresolved}`);
            return null;
        }
        if (byteSelector === '<') value &= 0xFF;
        if (byteSelector === '>') value = (value >> 8) & 0xFF;
        return value;
    }

    //
    // Get the value of an instruction's operand, reporting undefined symbols
    //
    operandValue(parsed) {
        return this.evaluate(operandExpression(parsed.operand, parsed.mode), { strict: true });
    }

    //
    // Get instruction size
    //
    getInstructionSize(parsed) {
        if (!parsed.mnemonic) return 0;
        return getInstructionSize(parsed.mode);
    }

    //
    // Handle directive in pass 1
    //
    handleDirectivePass1(parsed, lineNum) {
        switch (parsed.directive) {
            case 'ORG': {
                const address = this.evaluate(parsed.operand, { strict: true });
                if (address < 0 || address > 0xFFFF) {
                    this.error(lineNum, `Invalid address: ${parsed.operand}`);
                } else {
                    this.currentAddress = address;
                }
                break;
            }

            case 'BYTE':
            case 'TEXT':
            case 'ASCIIZ':
                this.currentAddress += this.dataBytes(parsed, true).length;
                break;

            case 'WORD':
                this.currentAddress += splitList(parsed.operand).length * 2;
                break;

            case 'INCBIN': {
                const filename = stringLiteral(parsed.operand) ?? parsed.operand;
                if (this.files.has(filename)) {
                    this.currentAddress += this.files.get(filename).length;
                } else {
                    this.error(lineNum, `File not found: ${filename}`);
                }
                break;
            }
        }
    }

    //
    // Handle directive in pass 2
    //
    handleDirectivePass2(parsed, lineNum) {
        switch (parsed.directive) {
            case 'ORG': {
                const address = this.evaluate(parsed.operand, { strict: true });
                if (this.output.length > 0) {
                    if (address < this.currentAddress) {
                        throw new Error('ORG cannot move backwards after emitting code or data');
                    }
                    while (this.currentAddress < address) {
                        this.emit(0, lineNum);
                    }
                }
                this.currentAddress = address;
                break;
            }

            case 'EQU':
                // EQU is fully handled in pass 1, no code generation needed
                break;

            case 'BYTE':
            case 'TEXT':
            case 'ASCIIZ':
                for (const byte of this.dataBytes(parsed, false)) {
                    this.emit(byte, lineNum);
                }
                break;

            case 'WORD':
                for (const item of splitList(parsed.operand)) {
                    if (!item) throw new Error('WORD requires a value for each operand');
                    const value = this.evaluate(item, { strict: true });
                    if (value < -0x8000 || value > 0xFFFF) {
                        throw new Error(`Value ${value} does not fit in a word`);
                    }
                    this.emit(value & 0xFF, lineNum);
                    this.emit((value >> 8) & 0xFF, lineNum);
                }
                break;

            case 'INCBIN': {
                const filename = stringLiteral(parsed.operand) ?? parsed.operand;
                const data = this.files.get(filename) ?? [];  // missing files fail pass 1
                for (let i = 0; i < data.length; i++) {
                    this.emit(data[i], lineNum);
                }
                break;
            }
        }
    }

    //
    // The bytes of a BYTE, TEXT or ASCIIZ list: strings and byte expressions
    // @param {boolean} allowUnresolved - Forward references reserve a byte (pass 1)
    //
    dataBytes(parsed, allowUnresolved) {
        const bytes = [];
        for (const item of splitList(parsed.operand)) {
            if (!item) {
                throw new Error(`${parsed.directive} requires a value for each operand`);
            }
            const text = stringLiteral(item);
            if (text !== null) {
                for (const ch of text) bytes.push(toPetscii(ch));
                continue;
            }
            const value = this.evaluate(item, { strict: !allowUnresolved });
            if (value === null) {
                bytes.push(0);
            } else if (value < -128 || value > 0xFF) {
                throw new Error(`Value ${value} does not fit in a byte`);
            } else {
                bytes.push(value & 0xFF);
            }
        }
        if (parsed.directive === 'ASCIIZ') bytes.push(0);
        return bytes;
    }

    /**
    * Emit an instruction
    */
    emitInstruction(parsed, lineNum) {
        const opcode = OPCODES[parsed.mnemonic][parsed.mode];
        if (opcode === undefined) {
            throw new Error(`${parsed.mnemonic} cannot use ${parsed.mode} addressing`);
        }

        this.emit(opcode, lineNum);

        const size = getInstructionSize(parsed.mode);
        if (size === 1) return;

        let operandBytes;
        try {
            operandBytes = this.encodeOperand(parsed, size);
        } catch (error) {
            // Keep later lines at the addresses pass 1 gave them.
            for (let i = 1; i < size; i++) this.emit(0, lineNum);
            throw error;
        }
        for (const byte of operandBytes) {
            this.emit(byte, lineNum);
        }
    }

    //
    // Encode the operand bytes of the instruction whose opcode was just emitted
    //
    encodeOperand(parsed, size) {
        const value = this.operandValue(parsed);

        if (parsed.mode === MODE.REL) {
            const offset = value - (this.currentAddress + 1);
            if (offset < -128 || offset > 127) {
                throw new Error(`Branch target out of range: ${offset} (a branch reaches -128 to +127 bytes)`);
            }
            return [offset & 0xFF];
        }

        if (size === 2) {
            const lowest = parsed.mode === MODE.IMM ? -128 : 0;
            if (value < lowest || value > 0xFF) {
                throw new Error(`Value ${value} does not fit in a byte`);
            }
            return [value & 0xFF];
        }

        if (value < 0 || value > 0xFFFF) {
            throw new Error(`Address ${value} is outside $0000-$FFFF`);
        }
        return [value & 0xFF, (value >> 8) & 0xFF];
    }

    /**
    * Emit a byte
    */
    emit(byte, lineNum) {
        if (!Number.isInteger(this.currentAddress) || this.currentAddress < 0 || this.currentAddress > 0xFFFF) {
            throw new Error('Output exceeds the 16-bit address space');
        }
        // EQU and leading ORGs do not establish the output origin; the first byte does.
        if (this.startAddress === null) {
            this.startAddress = this.currentAddress;
        }
        this.output.push(byte & 0xFF);
        this.sourceMap.push({
            address: this.currentAddress,
            lineNum: lineNum
        });
        this.currentAddress++;
    }

    /**
    * Add error
    */
    error(lineNum, message) {
        this.errors.push({ lineNum, message });
    }

    /**
    * Add warning
    */
    warning(lineNum, message) {
        this.warnings.push({ lineNum, message });
    }

    /**
    * Get assembly result
    */
    getResult() {
        return {
            success: this.errors.length === 0,
            bytes: new Uint8Array(this.output),
            startAddress: this.startAddress ?? 0x0800,
            symbols: Object.fromEntries(this.symbols),
            sourceMap: this.sourceMap,
            errors: this.errors,
            warnings: this.warnings
        };
    }
}

/**
* Read a byte from a memory source for disassembly.
*
* Accepts either a plain indexable buffer (Uint8Array) or anything exposing a
* `read(addr)` method, such as C64Machine. Using the bus is what makes banked-in
* ROM and I/O disassemble correctly instead of showing the RAM underneath.
*
* @param {Uint8Array|{read: function(number): number}} memory
* @param {number} address
* @returns {number} Byte value
*/
function readMemoryByte(memory, address) {
    return (typeof memory.read === 'function' ? memory.read(address) : memory[address]) & 0xFF;
}

/**
* Disassemble a single instruction
* @param {Uint8Array|{read: function(number): number}} memory - Memory buffer or bus
* @param {number} address - Address to disassemble
* @returns {Object} Disassembly result
*/
export function disassembleInstruction(memory, address) {
    const opcode = readMemoryByte(memory, address);

    const entry = getOpcodeTable().get(opcode);
    if (entry) {
        const { mnemonic, mode } = entry;
        const size = getInstructionSize(mode);
        let operand = '';
        let bytes = [opcode];

        if (size === 2) {
            const value = readMemoryByte(memory, address + 1);
            bytes.push(value);
            operand = formatOperand(mode, value, address + 2);
        } else if (size === 3) {
            const lo = readMemoryByte(memory, address + 1);
            const hi = readMemoryByte(memory, address + 2);
            bytes.push(lo, hi);
            operand = formatOperand(mode, lo | (hi << 8), address + 3);
        }

        return {
            address,
            bytes,
            size,
            mnemonic,
            mode,
            operand,
            text: `${mnemonic} ${operand}`.trim()
        };
    }

    // Unknown opcode
    return {
        address,
        bytes: [opcode],
        size: 1,
        mnemonic: '???',
        mode: MODE.IMP,
        operand: '',
        text: `??? ($${opcode.toString(16).padStart(2, '0').toUpperCase()})`
    };
}

// Reverse lookup from opcode byte to { mnemonic, mode }, built on first use.
let opcodeTable = null;

function getOpcodeTable() {
    if (!opcodeTable) {
        opcodeTable = new Map();
        for (const [mnemonic, modes] of Object.entries(OPCODES)) {
            for (const [mode, code] of Object.entries(modes)) {
                if (!opcodeTable.has(code)) {
                    opcodeTable.set(code, { mnemonic, mode });
                }
            }
        }
    }
    return opcodeTable;
}

/**
* Format operand for display
*/
function formatOperand(mode, value, nextAddress) {
    switch (mode) {
        case MODE.IMP:
        case MODE.ACC:
            return mode === MODE.ACC ? 'A' : '';
        case MODE.IMM:
            return `#$${value.toString(16).padStart(2, '0').toUpperCase()}`;
        case MODE.ZP:
            return `$${value.toString(16).padStart(2, '0').toUpperCase()}`;
        case MODE.ZPX:
            return `$${value.toString(16).padStart(2, '0').toUpperCase()},X`;
        case MODE.ZPY:
            return `$${value.toString(16).padStart(2, '0').toUpperCase()},Y`;
        case MODE.ABS:
            return `$${value.toString(16).padStart(4, '0').toUpperCase()}`;
        case MODE.ABX:
            return `$${value.toString(16).padStart(4, '0').toUpperCase()},X`;
        case MODE.ABY:
            return `$${value.toString(16).padStart(4, '0').toUpperCase()},Y`;
        case MODE.IND:
            return `($${value.toString(16).padStart(4, '0').toUpperCase()})`;
        case MODE.IZX:
            return `($${value.toString(16).padStart(2, '0').toUpperCase()},X)`;
        case MODE.IZY:
            return `($${value.toString(16).padStart(2, '0').toUpperCase()}),Y`;
        case MODE.REL:
            const target = nextAddress + (value > 127 ? value - 256 : value);
            return `$${target.toString(16).padStart(4, '0').toUpperCase()}`;
        default:
            return `$${value.toString(16).toUpperCase()}`;
    }
}

/**
* Disassemble a range of memory
* @param {Uint8Array} memory - Memory buffer
* @param {number} start - Start address
* @param {number} length - Number of bytes to disassemble
* @returns {Array} Array of disassembly results
*/
export function disassemble(memory, start, length) {
    const instructions = [];
    let address = start;
    const end = start + length;

    while (address < end) {
        const instr = disassembleInstruction(memory, address);
        instructions.push(instr);
        address += instr.size;
    }

    return instructions;
}

// Export for browser usage
if (typeof window !== 'undefined') {
    window.Assembler = Assembler;
    window.disassembleInstruction = disassembleInstruction;
    window.disassemble = disassemble;
}
