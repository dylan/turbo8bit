//
// @fileoverview BASIC Tokenizer - Converts BASIC text to C64 memory format
// @module emulator/basic-tokenizer
//
// This module provides tokenization of Commodore BASIC V2 programs:
// - Converts BASIC text to tokenized memory format
// - Handles all BASIC keywords and their tokens
// - Supports line numbers and program structure, with the C64's own editing
//   rules: lines are sorted, a repeated number replaces, a bare number deletes
// - Expands {CLR}/{RED}/{3 DOWN} control codes inside strings
// - Provides syntax validation
//
// C64 BASIC Program Memory Layout:
//   - Programs start at $0801 (2049)
//   - Each line: [next-addr-lo] [next-addr-hi] [line-num-lo] [line-num-hi] [tokens...] [0x00]
//   - Program ends with [0x00] [0x00]
//
// @see https://www.turbo8bit.com/
//

// ============================================================================
// BASIC TOKENS
// ============================================================================

// BASIC V2 keyword tokens (0x80-0xCB)
// The token value is 0x80 + index in this array
export const BASIC_KEYWORDS = [
    'END',      // $80
    'FOR',      // $81
    'NEXT',     // $82
    'DATA',     // $83
    'INPUT#',   // $84
    'INPUT',    // $85
    'DIM',      // $86
    'READ',     // $87
    'LET',      // $88
    'GOTO',     // $89
    'RUN',      // $8A
    'IF',       // $8B
    'RESTORE',  // $8C
    'GOSUB',    // $8D
    'RETURN',   // $8E
    'REM',      // $8F
    'STOP',     // $90
    'ON',       // $91
    'WAIT',     // $92
    'LOAD',     // $93
    'SAVE',     // $94
    'VERIFY',   // $95
    'DEF',      // $96
    'POKE',     // $97
    'PRINT#',   // $98
    'PRINT',    // $99
    'CONT',     // $9A
    'LIST',     // $9B
    'CLR',      // $9C
    'CMD',      // $9D
    'SYS',      // $9E
    'OPEN',     // $9F
    'CLOSE',    // $A0
    'GET',      // $A1
    'NEW',      // $A2
    'TAB(',     // $A3
    'TO',       // $A4
    'FN',       // $A5
    'SPC(',     // $A6
    'THEN',     // $A7
    'NOT',      // $A8
    'STEP',     // $A9
    '+',        // $AA
    '-',        // $AB
    '*',        // $AC
    '/',        // $AD
    '^',        // $AE (power/exponent - NOT the up-arrow character)
    'AND',      // $AF
    'OR',       // $B0
    '>',        // $B1
    '=',        // $B2
    '<',        // $B3
    'SGN',      // $B4
    'INT',      // $B5
    'ABS',      // $B6
    'USR',      // $B7
    'FRE',      // $B8
    'POS',      // $B9
    'SQR',      // $BA
    'RND',      // $BB
    'LOG',      // $BC
    'EXP',      // $BD
    'COS',      // $BE
    'SIN',      // $BF
    'TAN',      // $C0
    'ATN',      // $C1
    'PEEK',     // $C2
    'LEN',      // $C3
    'STR$',     // $C4
    'VAL',      // $C5
    'ASC',      // $C6
    'CHR$',     // $C7
    'LEFT$',    // $C8
    'RIGHT$',   // $C9
    'MID$',     // $CA
    'GO',       // $CB (for GO TO)
];

// Create a lookup map for faster keyword matching
const KEYWORD_MAP = new Map();
BASIC_KEYWORDS.forEach((keyword, index) => {
    KEYWORD_MAP.set(keyword, 0x80 + index);
});

// Secondary keyword patterns (must match before shorter ones)
// Sorted by length descending for proper matching
const SORTED_KEYWORDS = [...BASIC_KEYWORDS].sort((a, b) => b.length - a.length);

// BASIC program start address (default: $0801 = 2049)
export const BASIC_START = 0x0801;

// Lines are scanned with an 8-bit index, so a tokenized line must stay short.
const MAX_LINE_BYTES = 250;

// $0801-$9FFF: the 38911 BASIC BYTES FREE of the start-up banner.
const MAX_PROGRAM_BYTES = 38911;

// ============================================================================
// PETSCII CONTROL CODES
// ============================================================================

//
// PETSCII control codes written as {NAME} in printed C64 listings, so that
// PRINT "{CLR}{YEL}HELLO" can be typed on a PC keyboard. Repeats are written
// {3 DOWN} or {DOWN*3}; {147} gives a code by number.
//
const CONTROL_CODES = new Map(Object.entries({
    'CLR': 147, 'CLEAR': 147, 'SHIFT CLR/HOME': 147, 'HOME': 19, 'CLR/HOME': 19,
    'RVS ON': 18, 'RVSON': 18, 'RVS': 18, 'REVERSE ON': 18,
    'RVS OFF': 146, 'RVSOFF': 146, 'OFF': 146, 'REVERSE OFF': 146,
    'DOWN': 17, 'UP': 145, 'LEFT': 157, 'RIGHT': 29,
    'CRSR DOWN': 17, 'CRSR UP': 145, 'CRSR LEFT': 157, 'CRSR RIGHT': 29,
    'DEL': 20, 'INST': 148, 'INS': 148,
    'BLK': 144, 'BLACK': 144, 'WHT': 5, 'WHITE': 5, 'RED': 28,
    'CYN': 159, 'CYAN': 159, 'PUR': 156, 'PURPLE': 156,
    'GRN': 30, 'GREEN': 30, 'BLU': 31, 'BLUE': 31, 'YEL': 158, 'YELLOW': 158,
    'ORNG': 129, 'ORANGE': 129, 'BRN': 149, 'BROWN': 149,
    'LRED': 150, 'LIGHT RED': 150, 'PINK': 150,
    'GRY1': 151, 'DARK GREY': 151, 'DARK GRAY': 151,
    'GRY2': 152, 'GREY': 152, 'GRAY': 152,
    'LGRN': 153, 'LIGHT GREEN': 153, 'LBLU': 154, 'LIGHT BLUE': 154,
    'GRY3': 155, 'LIGHT GREY': 155, 'LIGHT GRAY': 155,
    'F1': 133, 'F3': 134, 'F5': 135, 'F7': 136,
    'F2': 137, 'F4': 138, 'F6': 139, 'F8': 140,
    'SPACE': 32, 'SHIFT SPACE': 160, 'PI': 255, 'POUND': 92,
    'LOWER': 14, 'UPPER': 142
}));

//
// Decode the inside of a {...} control code.
// @param {string} body - Text between the braces, e.g. "CLR" or "3 DOWN"
// @returns {number[]|null} The PETSCII codes, or null if not a control code
//
export function parseControlCode(body) {
    const text = body.trim().toUpperCase().replace(/\s+/g, ' ');
    let name = text;
    let count = 1;
    let match;
    if ((match = text.match(/^(\d+) (.+)$/))) {
        count = Number(match[1]);
        name = match[2];
    } else if ((match = text.match(/^(.+?) ?\* ?(\d+)$/))) {
        name = match[1];
        count = Number(match[2]);
    }
    const code = /^\d+$/.test(name) ? Number(name) : CONTROL_CODES.get(name);
    if (code === undefined || code > 255 || count < 1 || count > 80) return null;
    return new Array(count).fill(code);
}

//
// Replace every {...} control code in text with the PETSCII characters it
// names. Unknown codes are left as written.
// @param {string} text
// @returns {string}
//
export function expandControlCodes(text) {
    return text.replace(/\{([^{}]*)\}/g, (whole, body) => {
        const codes = parseControlCode(body);
        return codes ? String.fromCharCode(...codes) : whole;
    });
}

// The name each control character is listed under by detokenize().
const CONTROL_NAMES = new Map([
    [147, 'CLR'], [19, 'HOME'], [18, 'RVS ON'], [146, 'RVS OFF'],
    [17, 'DOWN'], [145, 'UP'], [157, 'LEFT'], [29, 'RIGHT'], [20, 'DEL'], [148, 'INST'],
    [144, 'BLK'], [5, 'WHT'], [28, 'RED'], [159, 'CYN'], [156, 'PUR'], [30, 'GRN'],
    [31, 'BLU'], [158, 'YEL'], [129, 'ORNG'], [149, 'BRN'], [150, 'LRED'], [151, 'GRY1'],
    [152, 'GRY2'], [153, 'LGRN'], [154, 'LBLU'], [155, 'GRY3'],
    [133, 'F1'], [134, 'F3'], [135, 'F5'], [136, 'F7'],
    [137, 'F2'], [138, 'F4'], [139, 'F6'], [140, 'F8'],
    [14, 'LOWER'], [142, 'UPPER'], [160, 'SHIFT SPACE']
]);

function petsciiToText(byte) {
    if (byte >= 0x20 && byte <= 0x5B) return String.fromCharCode(byte);
    switch (byte) {
        case 0x5C: return '£';
        case 0x5D: return ']';
        case 0x5E: return '↑';
        case 0x5F: return '←';
        case 0xFF: return 'π';
    }
    return `{${byte}}`;
}

//
// List a tokenized BASIC program as LIST would: keywords spelled out, with
// control characters inside strings written as {CLR}-style codes, so the
// text tokenizes back to the same program.
// @param {Uint8Array} prg - PRG file bytes, starting with the load address
// @returns {string}
//
export function detokenize(prg) {
    const notBasic = new Error('This file does not contain a BASIC program.');
    if (prg.length < 4) throw notBasic;
    const load = prg[0] | (prg[1] << 8);
    const body = prg.subarray(2);
    const lines = [];

    let offset = 0;
    for (;;) {
        if (offset + 2 > body.length) throw notBasic;
        const next = body[offset] | (body[offset + 1] << 8);
        if (next === 0) break;
        // Each link must point forward, inside the file.
        if (next <= load + offset + 4 || next - load > body.length || offset + 4 > body.length) {
            throw notBasic;
        }

        let text = `${body[offset + 2] | (body[offset + 3] << 8)} `;
        let quoted = false;
        let i = offset + 4;
        while (i < body.length && body[i] !== 0) {
            const byte = body[i];
            if (byte === 0x22) {
                quoted = !quoted;
                text += '"';
                i++;
            } else if (quoted && CONTROL_NAMES.has(byte)) {
                let count = 1;
                while (body[i + count] === byte) count++;
                const name = CONTROL_NAMES.get(byte);
                text += count > 1 ? `{${count} ${name}}` : `{${name}}`;
                i += count;
            } else if (!quoted && byte >= 0x80 && byte < 0x80 + BASIC_KEYWORDS.length) {
                text += BASIC_KEYWORDS[byte - 0x80];
                i++;
            } else {
                text += petsciiToText(byte);
                i++;
            }
        }
        lines.push(text);
        offset = next - load;
    }
    return lines.join('\n');
}

// ============================================================================
// TOKENIZER CLASS
// ============================================================================

//
// BASICTokenizer - Converts BASIC text to C64 tokenized format
//
export class BASICTokenizer {
    constructor() {
        this.errors = [];
    }

    //
    // Tokenize a complete BASIC program
    // @param {string} source - The BASIC source code
    // @param {number} startAddress - Memory address to start (default: $0801)
    // @returns {{ bytes: Uint8Array, errors: Array, lines: Array }}
    //
    tokenize(source, startAddress = BASIC_START) {
        this.errors = [];
        const byNumber = new Map();
        const sourceLines = source.split('\n');
        let highestLineNum = -1;

        // Lines behave as if typed in order at the READY prompt: the C64 keeps
        // them sorted by number, a repeated number replaces the earlier line,
        // and a number on its own deletes that line.
        for (let i = 0; i < sourceLines.length; i++) {
            const sourceLine = sourceLines[i].trim();
            if (sourceLine === '') continue;

            const parsed = this.parseLine(sourceLine, i + 1);
            if (parsed.error) {
                this.errors.push(parsed.error);
                continue;
            }

            const { lineNum } = parsed;
            const warning = message => this.errors.push({ line: i + 1, column: 1, message, type: 'warning' });
            if (parsed.tokens.length === 0) {
                warning(`Line ${lineNum} is empty: on a C64 a bare line number deletes that line`);
                byNumber.delete(lineNum);
                continue;
            }
            if (byNumber.has(lineNum)) {
                warning(`Line ${lineNum} appears twice: the later line replaces the earlier one`);
            } else if (lineNum < highestLineNum) {
                warning(`Line ${lineNum} comes after line ${highestLineNum}: the C64 sorts lines by number`);
            }
            if (parsed.tokens.length > MAX_LINE_BYTES) {
                this.errors.push({
                    line: i + 1,
                    column: 1,
                    message: `Line ${lineNum} is too long: split it into shorter lines`,
                    type: 'error'
                });
            }
            highestLineNum = Math.max(highestLineNum, lineNum);
            byNumber.set(lineNum, parsed);
        }

        const lines = [...byNumber.values()].sort((a, b) => a.lineNum - b.lineNum);

        // Build the tokenized program
        const bytes = this.buildProgram(lines, startAddress);
        if (bytes.length - 2 > MAX_PROGRAM_BYTES) {
            this.errors.push({
                line: 1,
                column: 1,
                message: `Program is ${bytes.length - 2} bytes: BASIC only has ${MAX_PROGRAM_BYTES} free`,
                type: 'error'
            });
        }

        return { bytes, errors: this.errors, lines };
    }

    //
    // Parse a single BASIC line
    // @param {string} line - The source line
    // @param {number} sourceLineNum - Source file line number (for error reporting)
    // @returns {{ lineNum: number, tokens: Uint8Array, error?: Object }}
    //
    parseLine(line, sourceLineNum) {
        // Extract line number
        const lineNumMatch = line.match(/^(\d+)\s*/);
        if (!lineNumMatch) {
            return {
                error: {
                    line: sourceLineNum,
                    column: 1,
                    message: 'Line must start with a line number',
                    type: 'error'
                }
            };
        }

        const lineNum = parseInt(lineNumMatch[1], 10);
        if (lineNum < 0 || lineNum > 63999) {
            return {
                error: {
                    line: sourceLineNum,
                    column: 1,
                    message: `Line number ${lineNum} out of range (0-63999)`,
                    type: 'error'
                }
            };
        }

        const content = line.slice(lineNumMatch[0].length);
        const tokens = this.tokenizeLine(content, sourceLineNum);

        return { lineNum, tokens, sourceLineNum };
    }

    //
    // Tokenize the content of a single line (after the line number)
    // @param {string} content - Line content without line number
    // @param {number} sourceLineNum - Source file line number
    // @returns {Uint8Array} Tokenized bytes
    //
    tokenizeLine(content, sourceLineNum) {
        const tokens = [];
        let i = 0;
        let inString = false;
        let inRem = false;
        let inData = false;

        while (i < content.length) {
            const ch = content[i];

            // Handle strings - don't tokenize inside quotes
            if (ch === '"') {
                inString = !inString;
                tokens.push(ch.charCodeAt(0));
                i++;
                continue;
            }

            if (inString) {
                // {CLR}-style names stand for the control character itself.
                if (ch === '{') {
                    const close = content.indexOf('}', i);
                    const codes = close > i ? parseControlCode(content.slice(i + 1, close)) : null;
                    if (codes) {
                        tokens.push(...codes);
                        i = close + 1;
                        continue;
                    }
                }
                // Convert to PETSCII (uppercase letters stay the same in C64 mode)
                tokens.push(this.toPetscii(ch));
                i++;
                continue;
            }

            // Inside REM - rest of line is literal text
            if (inRem) {
                tokens.push(this.toPetscii(ch));
                i++;
                continue;
            }

            // Inside DATA - only tokenize commas and colons
            if (inData) {
                if (ch === ':') {
                    inData = false;
                    tokens.push(ch.charCodeAt(0));
                    i++;
                    continue;
                }
                tokens.push(this.toPetscii(ch));
                i++;
                continue;
            }

            if (ch === '?') {
                tokens.push(KEYWORD_MAP.get('PRINT'));
                i++;
                continue;
            }

            // BASIC keywords have no identifier boundaries: PRINT1 and FORI are valid.
            const remaining = content.slice(i).toUpperCase();
            let matched = false;

            for (const keyword of SORTED_KEYWORDS) {
                if (remaining.startsWith(keyword)) {
                    const token = KEYWORD_MAP.get(keyword);
                    tokens.push(token);
                    i += keyword.length;
                    matched = true;

                    // Track special modes
                    if (keyword === 'REM') {
                        inRem = true;
                    } else if (keyword === 'DATA') {
                        inData = true;
                    }

                    break;
                }
            }

            if (!matched) {
                // Regular character - convert to PETSCII uppercase
                tokens.push(this.toPetscii(ch));
                i++;
            }
        }

        return new Uint8Array(tokens);
    }

    //
    // Convert ASCII character to PETSCII
    // @param {string} ch - ASCII character
    // @returns {number} PETSCII code
    //
    toPetscii(ch) {
        const code = ch.charCodeAt(0);

        // ASCII and PETSCII are mostly compatible for printable chars
        // Uppercase letters: A-Z (65-90) are the same
        // Lowercase letters: a-z (97-122) -> uppercase in C64 text mode
        if (code >= 97 && code <= 122) {
            return code - 32; // Convert to uppercase
        }

        // Symbols on the C64 keyboard that ASCII lacks; π is also BASIC's pi.
        switch (ch) {
            case '£': return 0x5C;
            case '↑': return 0x5E;
            case '←': return 0x5F;
            case 'π': return 0xFF;
        }

        // Most other printable ASCII chars are the same; validate() warns
        // about the characters a C64 cannot type.
        return code > 0xFF ? 0x3F : code;
    }

    //
    // Build the complete tokenized program
    // @param {Array} lines - Array of parsed lines
    // @param {number} startAddress - Memory start address
    // @returns {Uint8Array} Complete tokenized program with PRG header
    //
    buildProgram(lines, startAddress) {
        const output = [];

        // PRG header (2 bytes: load address)
        output.push(startAddress & 0xFF);
        output.push((startAddress >> 8) & 0xFF);

        let currentAddr = startAddress;

        for (const line of lines) {
            // Calculate next line address
            // Format: next-lo, next-hi, linenum-lo, linenum-hi, tokens..., 0x00
            const lineData = [
                0, 0,  // Placeholder for next line address
                line.lineNum & 0xFF,
                (line.lineNum >> 8) & 0xFF,
                ...line.tokens,
                0x00  // Line terminator
            ];

            const nextAddr = currentAddr + lineData.length;
            lineData[0] = nextAddr & 0xFF;
            lineData[1] = (nextAddr >> 8) & 0xFF;

            output.push(...lineData);
            currentAddr = nextAddr;
        }

        // Program terminator (null next-line pointer)
        output.push(0x00, 0x00);

        return new Uint8Array(output);
    }

    //
    // Validate BASIC source and return syntax errors/warnings
    // @param {string} source - The BASIC source code
    // @returns {Array} Array of error/warning objects
    //
    validate(source) {
        this.errors = [];
        const lines = source.split('\n');
        const seen = new Set();
        let highestLineNum = -1;

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (line === '') continue;

            // Check for line number
            const lineNumMatch = line.match(/^(\d+)\s*/);
            if (!lineNumMatch) {
                this.errors.push({
                    line: i + 1,
                    column: 1,
                    message: 'Line must start with a line number',
                    type: 'error'
                });
                continue;
            }

            const lineNum = parseInt(lineNumMatch[1], 10);
            const warn = (message, column = 1) => this.errors.push({ line: i + 1, column, message, type: 'warning' });

            // Check line number range
            if (lineNum < 0 || lineNum > 63999) {
                this.errors.push({
                    line: i + 1,
                    column: 1,
                    message: `Line number ${lineNum} out of range (0-63999)`,
                    type: 'error'
                });
            }

            // Ordering only warns: the C64 sorts and replaces lines itself.
            if (line.length === lineNumMatch[0].length) {
                warn(`Line ${lineNum} is empty: on a C64 a bare line number deletes that line`);
            } else if (seen.has(lineNum)) {
                warn(`Line ${lineNum} appears twice: the later line replaces the earlier one`);
            } else if (lineNum < highestLineNum) {
                warn(`Line ${lineNum} comes after line ${highestLineNum}: the C64 sorts lines by number`);
            }
            seen.add(lineNum);
            highestLineNum = Math.max(highestLineNum, lineNum);

            const strayChar = [...line].find(ch => ch.charCodeAt(0) > 0xFF && !'£↑←π'.includes(ch));
            if (strayChar) {
                warn(`'${strayChar}' is not a C64 character`, line.indexOf(strayChar) + 1);
            }
            for (const [code, body] of line.matchAll(/\{([^{}]*)\}/g)) {
                if (!parseControlCode(body)) {
                    warn(`Unknown control code ${code}`, line.indexOf(code) + 1);
                }
            }

            // Check for unmatched quotes
            const content = line.slice(lineNumMatch[0].length);
            let quoteCount = 0;
            for (const ch of content) {
                if (ch === '"') quoteCount++;
            }
            if (quoteCount % 2 !== 0) {
                this.errors.push({
                    line: i + 1,
                    column: line.lastIndexOf('"') + 1,
                    message: 'Unmatched quote',
                    type: 'warning'
                });
            }

            // Check for empty GOTO/GOSUB targets
            const gotoMatch = content.match(/\b(GOTO|GOSUB)\s*$/i);
            if (gotoMatch) {
                this.errors.push({
                    line: i + 1,
                    column: lineNumMatch[0].length + content.indexOf(gotoMatch[1]) + 1,
                    message: `${gotoMatch[1].toUpperCase()} requires a line number`,
                    type: 'error'
                });
            }

            // Check for invalid THEN usage
            const thenMatch = content.match(/\bTHEN\s*$/i);
            if (thenMatch) {
                this.errors.push({
                    line: i + 1,
                    column: lineNumMatch[0].length + content.indexOf('THEN') + 1,
                    message: 'THEN requires a statement or line number',
                    type: 'error'
                });
            }

            // Check for unmatched parentheses
            let parenCount = 0;
            let inString = false;
            for (let j = 0; j < content.length; j++) {
                const ch = content[j];
                if (ch === '"') inString = !inString;
                if (!inString) {
                    if (ch === '(') parenCount++;
                    if (ch === ')') parenCount--;
                }
            }
            if (parenCount !== 0) {
                this.errors.push({
                    line: i + 1,
                    column: lineNumMatch[0].length + 1,
                    message: parenCount > 0 ? 'Unmatched opening parenthesis' : 'Unmatched closing parenthesis',
                    type: 'error'
                });
            }
        }

        return this.errors;
    }
}

// ============================================================================
// SYNTAX HIGHLIGHTING
// ============================================================================

// Token types for syntax highlighting
export const TokenType = {
    KEYWORD: 'keyword',
    STRING: 'string',
    NUMBER: 'number',
    OPERATOR: 'operator',
    COMMENT: 'comment',
    VARIABLE: 'variable',
    FUNCTION: 'function',
    LINENUMBER: 'linenumber',
    PUNCTUATION: 'punctuation',
    CONTROL: 'control',
    ERROR: 'error',
    DEFAULT: 'default',
};

// BASIC functions (subset of keywords that are functions)
const BASIC_FUNCTIONS = new Set([
    'SGN', 'INT', 'ABS', 'USR', 'FRE', 'POS', 'SQR', 'RND', 'LOG', 'EXP',
    'COS', 'SIN', 'TAN', 'ATN', 'PEEK', 'LEN', 'STR$', 'VAL', 'ASC', 'CHR$',
    'LEFT$', 'RIGHT$', 'MID$', 'TAB(', 'SPC(', 'FN'
]);

// BASIC statements (keywords that start statements)
const BASIC_STATEMENTS = new Set([
    'END', 'FOR', 'NEXT', 'DATA', 'INPUT#', 'INPUT', 'DIM', 'READ', 'LET',
    'GOTO', 'RUN', 'IF', 'RESTORE', 'GOSUB', 'RETURN', 'REM', 'STOP', 'ON',
    'WAIT', 'LOAD', 'SAVE', 'VERIFY', 'DEF', 'POKE', 'PRINT#', 'PRINT',
    'CONT', 'LIST', 'CLR', 'CMD', 'SYS', 'OPEN', 'CLOSE', 'GET', 'NEW', 'GO'
]);

// Operators (some are also tokens)
const OPERATORS = new Set(['+', '-', '*', '/', '^', '=', '<', '>', 'AND', 'OR', 'NOT']);

//
// Highlight BASIC source code for display
// @param {string} source - The BASIC source code
// @returns {Array<{text: string, type: string, line: number}>} Highlighted tokens
//
export function highlightBasic(source) {
    const tokens = [];
    const lines = source.split('\n');

    for (let lineIdx = 0; lineIdx < lines.length; lineIdx++) {
        const line = lines[lineIdx];
        const lineTokens = highlightLine(line, lineIdx + 1);
        tokens.push(...lineTokens);

        // Add newline token between lines
        if (lineIdx < lines.length - 1) {
            tokens.push({ text: '\n', type: TokenType.DEFAULT, line: lineIdx + 1 });
        }
    }

    return tokens;
}

//
// Highlight a single BASIC line
// @param {string} line - The line to highlight
// @param {number} lineNum - Line number in source
// @returns {Array} Array of token objects
//
function highlightLine(line, lineNum) {
    const tokens = [];
    let i = 0;

    // Skip leading whitespace
    while (i < line.length && /\s/.test(line[i])) {
        tokens.push({ text: line[i], type: TokenType.DEFAULT, line: lineNum });
        i++;
    }

    // Parse line number
    const lineNumMatch = line.slice(i).match(/^(\d+)/);
    if (lineNumMatch) {
        tokens.push({ text: lineNumMatch[1], type: TokenType.LINENUMBER, line: lineNum });
        i += lineNumMatch[1].length;
    }

    // Skip space after line number
    while (i < line.length && line[i] === ' ') {
        tokens.push({ text: ' ', type: TokenType.DEFAULT, line: lineNum });
        i++;
    }

    let inString = false;
    let inRem = false;
    let inData = false;

    while (i < line.length) {
        const ch = line[i];

        // Handle strings
        if (ch === '"') {
            if (!inRem) {
                inString = !inString;
            }
            tokens.push({ text: ch, type: inRem ? TokenType.COMMENT : TokenType.STRING, line: lineNum });
            i++;
            continue;
        }

        if (inString) {
            if (ch === '{') {
                const close = line.indexOf('}', i);
                if (close > i && parseControlCode(line.slice(i + 1, close))) {
                    tokens.push({ text: line.slice(i, close + 1), type: TokenType.CONTROL, line: lineNum });
                    i = close + 1;
                    continue;
                }
            }
            tokens.push({ text: ch, type: TokenType.STRING, line: lineNum });
            i++;
            continue;
        }

        // Inside REM
        if (inRem) {
            tokens.push({ text: ch, type: TokenType.COMMENT, line: lineNum });
            i++;
            continue;
        }

        // Inside DATA (special handling)
        if (inData) {
            if (ch === ':') {
                inData = false;
                tokens.push({ text: ch, type: TokenType.PUNCTUATION, line: lineNum });
            } else if (/\d/.test(ch)) {
                // Collect number
                let num = '';
                while (i < line.length && /[\d.]/.test(line[i])) {
                    num += line[i];
                    i++;
                }
                tokens.push({ text: num, type: TokenType.NUMBER, line: lineNum });
                continue;
            } else {
                tokens.push({ text: ch, type: TokenType.DEFAULT, line: lineNum });
            }
            i++;
            continue;
        }

        if (ch === '?') {
            tokens.push({ text: ch, type: TokenType.KEYWORD, line: lineNum });
            i++;
            continue;
        }

        // Try to match a keyword
        const remaining = line.slice(i).toUpperCase();
        let matched = false;

        for (const keyword of SORTED_KEYWORDS) {
            if (remaining.startsWith(keyword)) {
                // Determine token type
                let type = TokenType.KEYWORD;
                if (BASIC_FUNCTIONS.has(keyword)) {
                    type = TokenType.FUNCTION;
                } else if (OPERATORS.has(keyword)) {
                    type = TokenType.OPERATOR;
                }

                tokens.push({ text: line.slice(i, i + keyword.length), type, line: lineNum });
                i += keyword.length;
                matched = true;

                if (keyword === 'REM') {
                    inRem = true;
                } else if (keyword === 'DATA') {
                    inData = true;
                }

                break;
            }
        }

        if (matched) continue;

        // Numbers
        if (/\d/.test(ch) || (ch === '.' && i + 1 < line.length && /\d/.test(line[i + 1]))) {
            let num = '';
            while (i < line.length && /[\d.E+-]/.test(line[i].toUpperCase())) {
                // Handle scientific notation carefully
                if ((line[i] === '+' || line[i] === '-') &&
                    num.length > 0 &&
                    num[num.length - 1].toUpperCase() !== 'E') {
                    break;
                }
                num += line[i];
                i++;
            }
            tokens.push({ text: num, type: TokenType.NUMBER, line: lineNum });
            continue;
        }

        // Variables (letters followed by alphanumerics, ending with optional $ or %)
        if (/[A-Za-z]/.test(ch)) {
            let variable = '';
            while (i < line.length && /[A-Za-z0-9]/.test(line[i])) {
                if (variable && SORTED_KEYWORDS.some(keyword => line.slice(i).toUpperCase().startsWith(keyword))) {
                    break;
                }
                variable += line[i];
                i++;
            }
            // Check for type suffix
            if (i < line.length && (line[i] === '$' || line[i] === '%')) {
                variable += line[i];
                i++;
            }
            tokens.push({ text: variable, type: TokenType.VARIABLE, line: lineNum });
            continue;
        }

        // Operators
        if ('+-*/^=<>'.includes(ch)) {
            // Check for compound operators
            if ((ch === '<' || ch === '>') && i + 1 < line.length) {
                const next = line[i + 1];
                if (next === '=' || next === '>' || next === '<') {
                    tokens.push({ text: ch + next, type: TokenType.OPERATOR, line: lineNum });
                    i += 2;
                    continue;
                }
            }
            tokens.push({ text: ch, type: TokenType.OPERATOR, line: lineNum });
            i++;
            continue;
        }

        // Punctuation
        if (':;,()'.includes(ch)) {
            tokens.push({ text: ch, type: TokenType.PUNCTUATION, line: lineNum });
            i++;
            continue;
        }

        // Default (whitespace, unknown)
        tokens.push({ text: ch, type: TokenType.DEFAULT, line: lineNum });
        i++;
    }

    return tokens;
}

// ============================================================================
// 6502 ASSEMBLY HIGHLIGHTING
// ============================================================================

// 6502 instructions
const ASM_INSTRUCTIONS = new Set([
    'ADC', 'AND', 'ASL', 'BCC', 'BCS', 'BEQ', 'BIT', 'BMI', 'BNE', 'BPL',
    'BRK', 'BVC', 'BVS', 'CLC', 'CLD', 'CLI', 'CLV', 'CMP', 'CPX', 'CPY',
    'DEC', 'DEX', 'DEY', 'EOR', 'INC', 'INX', 'INY', 'JMP', 'JSR', 'LDA',
    'LDX', 'LDY', 'LSR', 'NOP', 'ORA', 'PHA', 'PHP', 'PLA', 'PLP', 'ROL',
    'ROR', 'RTI', 'RTS', 'SBC', 'SEC', 'SED', 'SEI', 'STA', 'STX', 'STY',
    'TAX', 'TAY', 'TSX', 'TXA', 'TXS', 'TYA'
]);

// Assembler directives
const ASM_DIRECTIVES = new Set([
    '.ORG', '.BYTE', '.WORD', '.TEXT', '.INCLUDE', '.DEFINE', '.EQU',
    '*=', '.DB', '.DW', '.DS', '.ALIGN', '.MACRO', '.ENDM', '.IF', '.ENDIF',
    '.ELSE', '.PROC', '.ENDP', '.SEGMENT', '.CODE', '.DATA', '.BSS'
]);

// Directives the assembler accepts without a dot, as in "ORG $C000".
const ASM_BARE_DIRECTIVES = new Set([
    'ORG', 'BYTE', 'BYT', 'DB', 'DFB', 'WORD', 'DW', 'TEXT', 'ASC', 'ASCII',
    'ASCIIZ', 'EQU', 'INCBIN', 'BINARY'
]);

// Index of the ; that starts a comment, ignoring semicolons inside quotes.
function asmCommentIndex(line) {
    let quote = null;
    for (let i = 0; i < line.length; i++) {
        const ch = line[i];
        if (quote) {
            if (ch === quote) quote = null;
        } else if (ch === '"' || ch === "'") {
            quote = ch;
        } else if (ch === ';') {
            return i;
        }
    }
    return -1;
}

//
// Highlight 6502 assembly code
// @param {string} source - The assembly source code
// @returns {Array} Highlighted tokens
//
export function highlightAssembly(source) {
    const tokens = [];
    const lines = source.split('\n');

    for (let lineIdx = 0; lineIdx < lines.length; lineIdx++) {
        const line = lines[lineIdx];
        const lineTokens = highlightAsmLine(line, lineIdx + 1);
        tokens.push(...lineTokens);

        if (lineIdx < lines.length - 1) {
            tokens.push({ text: '\n', type: TokenType.DEFAULT, line: lineIdx + 1 });
        }
    }

    return tokens;
}

function highlightAsmLine(line, lineNum) {
    const tokens = [];
    let i = 0;

    // Check for comment (semicolon starts comment in most assemblers)
    const commentIdx = asmCommentIndex(line);
    const codePart = commentIdx >= 0 ? line.slice(0, commentIdx) : line;
    const commentPart = commentIdx >= 0 ? line.slice(commentIdx) : '';

    // Process label at start of line; a mnemonic or directive there is code.
    const labelMatch = codePart.match(/^([A-Za-z_][A-Za-z0-9_]*)(:?)\s*/);
    const labelWord = labelMatch ? labelMatch[1].toUpperCase() : '';
    if (labelMatch && (labelMatch[2] ||
        (!ASM_INSTRUCTIONS.has(labelWord) && !ASM_BARE_DIRECTIVES.has(labelWord)))) {
        tokens.push({ text: labelMatch[0], type: TokenType.VARIABLE, line: lineNum });
        i = labelMatch[0].length;
    }

    // Skip whitespace
    while (i < codePart.length && /\s/.test(codePart[i])) {
        tokens.push({ text: codePart[i], type: TokenType.DEFAULT, line: lineNum });
        i++;
    }

    // Look for instruction or directive
    const remaining = codePart.slice(i);
    const wordMatch = remaining.match(/^([A-Za-z.!*=][A-Za-z0-9_]*)/);

    if (wordMatch) {
        const word = wordMatch[1].toUpperCase();
        let type = TokenType.DEFAULT;

        if (ASM_INSTRUCTIONS.has(word)) {
            type = TokenType.KEYWORD;
        } else if (ASM_DIRECTIVES.has(word) || ASM_BARE_DIRECTIVES.has(word) ||
            /^[.!*]/.test(word)) {
            type = TokenType.FUNCTION;
        }

        tokens.push({ text: codePart.slice(i, i + wordMatch[1].length), type, line: lineNum });
        i += wordMatch[1].length;
    }

    // Rest of the operand
    while (i < codePart.length) {
        const ch = codePart[i];

        // Hex numbers
        if (ch === '$' && i + 1 < codePart.length && /[0-9A-Fa-f]/.test(codePart[i + 1])) {
            let hex = '$';
            i++;
            while (i < codePart.length && /[0-9A-Fa-f]/.test(codePart[i])) {
                hex += codePart[i];
                i++;
            }
            tokens.push({ text: hex, type: TokenType.NUMBER, line: lineNum });
            continue;
        }

        // Binary numbers
        if (ch === '%' && i + 1 < codePart.length && /[01]/.test(codePart[i + 1])) {
            let bin = '%';
            i++;
            while (i < codePart.length && /[01]/.test(codePart[i])) {
                bin += codePart[i];
                i++;
            }
            tokens.push({ text: bin, type: TokenType.NUMBER, line: lineNum });
            continue;
        }

        // Decimal numbers
        if (/\d/.test(ch)) {
            let num = '';
            while (i < codePart.length && /\d/.test(codePart[i])) {
                num += codePart[i];
                i++;
            }
            tokens.push({ text: num, type: TokenType.NUMBER, line: lineNum });
            continue;
        }

        // String/char literals
        if (ch === '"' || ch === "'") {
            const quote = ch;
            let str = ch;
            i++;
            while (i < codePart.length && codePart[i] !== quote) {
                str += codePart[i];
                i++;
            }
            if (i < codePart.length) {
                str += codePart[i];
                i++;
            }
            tokens.push({ text: str, type: TokenType.STRING, line: lineNum });
            continue;
        }

        // Registers and special chars
        if ('#,()XYxy'.includes(ch)) {
            tokens.push({ text: ch, type: TokenType.PUNCTUATION, line: lineNum });
            i++;
            continue;
        }

        // Labels/identifiers
        if (/[A-Za-z_]/.test(ch)) {
            let id = '';
            while (i < codePart.length && /[A-Za-z0-9_]/.test(codePart[i])) {
                id += codePart[i];
                i++;
            }
            tokens.push({ text: id, type: TokenType.VARIABLE, line: lineNum });
            continue;
        }

        tokens.push({ text: ch, type: TokenType.DEFAULT, line: lineNum });
        i++;
    }

    // Add comment
    if (commentPart) {
        tokens.push({ text: commentPart, type: TokenType.COMMENT, line: lineNum });
    }

    return tokens;
}

// ============================================================================
// EXPORTS
// ============================================================================

export default BASICTokenizer;
