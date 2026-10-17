//
// @fileoverview Live view of a running BASIC program
// @module lab/basic-monitor
//
// Reads the BASIC interpreter's own bookkeeping out of C64 memory, the way a
// machine-code monitor would: the line it is executing, and the variables and
// arrays the program has created. Everything is read with peek(), so watching
// cannot change what the program does.
//
// BASIC V2 zero-page pointers, in the order the areas sit in memory:
//   $2B/$2C TXTTAB  start of program text
//   $2D/$2E VARTAB  start of simple variables, 7 bytes each
//   $2F/$30 ARYTAB  start of arrays
//   $31/$32 STREND  end of arrays; free memory starts here
//   $33/$34 FRETOP  bottom of the strings, which grow down from MEMSIZ
//   $37/$38 MEMSIZ  top of BASIC memory
//   $39/$3A CURLIN  line being executed; $FF in $3A means direct mode
//
// @see https://www.turbo8bit.com/
//

const VARIABLE_SIZE = 7;
const MAX_VARIABLES = 200;
const MAX_ARRAYS = 50;
const MAX_LINES = 2000;
const ARRAY_PREVIEW = 6;
const STRING_PREVIEW = 40;
// BASIC's main loop reads each direct-mode line with JSR INLIN at $A483,
// which stacks the return address $A485. INLIN reads the keyboard through
// JSR $E112 at $A562, stacking $A564 just below it, and prints the RETURN
// that ends the line through JSR $AB47 at $AAD9, stacking $AADB there.
// BASIC is at READY while either pair is on the stack. Where depends on
// what is under it: END, STOP and BREAK keep FOR and GOSUB frames for CONT,
// so it is searched for rather than read from a fixed address. Matching
// both return addresses also rules out a FOR or GOSUB frame on line 42117
// ($A485), or pushed float bytes that happen to look like it.
const READY_FRAMES = [[0x64, 0xA5, 0x85, 0xA4], [0xDB, 0xAA, 0x85, 0xA4]];
// Once INLIN returns, the main loop reads the line's first character with
// JSR CHRGET at $A48A, stacking $A48C, and marks direct mode at $A492.
const MAIN_LOOP_FIRST = 0xA486;
const MAIN_LOOP_LAST = 0xA492;
const CHRGET_FIRST = 0x0073;
const CHRGET_LAST = 0x008A;
const MAIN_CHRGET_RETURN = 0xA48C;
// The KERNAL screen editor's wait-for-a-key loop, where both the READY
// prompt and INPUT sit until RETURN.
export const KEY_WAIT_FIRST = 0xE5CD;
export const KEY_WAIT_LAST = 0xE5D5;

const word = (machine, address) => machine.peek(address) | (machine.peek(address + 1) << 8);

//
// BASIC's memory pointers, or null when they do not describe a consistent
// layout, as during boot or while a program has repurposed zero page.
//
export function readMemoryLayout(machine) {
    const layout = {
        program: word(machine, 0x2B),
        variables: word(machine, 0x2D),
        arrays: word(machine, 0x2F),
        free: word(machine, 0x31),
        strings: word(machine, 0x33),
        top: word(machine, 0x37)
    };
    const order = [layout.program, layout.variables, layout.arrays, layout.free, layout.strings, layout.top];
    for (let i = 1; i < order.length; i++) {
        if (order[i] < order[i - 1]) return null;
    }
    if (layout.program === 0 || (layout.arrays - layout.variables) % VARIABLE_SIZE !== 0) return null;
    return layout;
}

//
// The line numbers of the program in memory, by following each line's link
// to the next. A link of zero ends the program.
//
export function programLineNumbers(machine) {
    const layout = readMemoryLayout(machine);
    const numbers = [];
    if (!layout) return numbers;
    let address = layout.program;
    while (numbers.length < MAX_LINES) {
        const next = word(machine, address);
        if (next === 0) break;
        if (next <= address || next > layout.variables) return [];
        numbers.push(word(machine, address + 2));
        address = next;
    }
    return numbers;
}

//
// The line number in CURLIN, or null in direct mode. CURLIN alone does not
// say whether a program is running: it keeps the last line after END, BREAK
// or an error, and reads 0 at the first READY. Use basicActivity() for that.
//
export function basicLine(machine) {
    const high = machine.peek(0x3A);
    if (high === 0xFF) return null;
    return machine.peek(0x39) | (high << 8);
}

//
// True while BASIC's main loop is at READY: waiting for a line, reading it,
// or about to hand it to the interpreter.
//
function atReady(machine) {
    const pc = machine.cpu.PC;
    const top = 0x0101 + machine.cpu.SP;
    if (pc >= MAIN_LOOP_FIRST && pc <= MAIN_LOOP_LAST) return true;
    if (pc >= CHRGET_FIRST && pc <= CHRGET_LAST
        && (machine.peek(top) | (machine.peek(top + 1) << 8)) === MAIN_CHRGET_RETURN) return true;
    // The inner address may lie just below the live stack: INLIN pops it
    // between the calls it makes, but nothing overwrites it there.
    for (let address = top - 2; address <= 0x01FC; address++) {
        if (READY_FRAMES.some(frame => frame.every((byte, i) => machine.peek(address + i) === byte))) {
            return true;
        }
    }
    return false;
}

//
// What BASIC is doing now.
// @returns {{mode: string, line: number|null, waiting: boolean}} mode is
//   'ready' at the READY prompt (line is then the line a program stopped
//   on, if any), 'direct' while a typed command runs, or 'program'; waiting
//   is true while the KERNAL waits for a key, as INPUT does
//
export function basicActivity(machine) {
    const pc = machine.cpu.PC;
    const waiting = pc >= KEY_WAIT_FIRST && pc <= KEY_WAIT_LAST;
    const line = basicLine(machine);
    if (atReady(machine)) return { mode: 'ready', line, waiting };
    if (line === null) return { mode: 'direct', line, waiting };
    return { mode: 'program', line, waiting };
}

//
// Decode BASIC's 5-byte floating point format: an exponent biased by 128
// (0 means the value 0), then a 32-bit mantissa whose top bit, always 1 in
// a normalised number, is stored as the sign instead.
//
export function decodeFloat(bytes) {
    const exponent = bytes[0];
    if (exponent === 0) return 0;
    const sign = bytes[1] & 0x80 ? -1 : 1;
    const mantissa = (bytes[1] | 0x80) * 2 ** 24 + bytes[2] * 2 ** 16 + bytes[3] * 2 ** 8 + bytes[4];
    return sign * mantissa * 2 ** (exponent - 160);
}

//
// Write a number in PRINT's style: up to nine significant digits, no
// leading zero before the point, E notation outside 0.01 to 999999999.
// This is the stored value correctly rounded. PRINT itself scales by ten
// repeatedly, rounding at each step, so a value whose tenth digit is close
// to 5 can print one higher in the ninth (4*ATN(1) prints 3.14159266).
//
export function formatBasicNumber(value) {
    if (value === 0) return '0';
    const magnitude = Math.abs(value);
    let text;
    if (magnitude >= 1e9 || magnitude < 0.01) {
        const [mantissa, exponent] = value.toExponential(8).split('e');
        const digits = mantissa.includes('.') ? mantissa.replace(/\.?0+$/, '') : mantissa;
        const power = Number(exponent);
        text = `${digits}E${power < 0 ? '-' : '+'}${String(Math.abs(power)).padStart(2, '0')}`;
    } else {
        text = String(Number(value.toPrecision(9)));
    }
    return text.replace(/^(-?)0\./, '$1.');
}

function petsciiText(machine, address, length) {
    let text = '';
    for (let i = 0; i < Math.min(length, STRING_PREVIEW); i++) {
        const code = machine.peek((address + i) & 0xFFFF);
        if (code >= 0x20 && code <= 0x5A) text += String.fromCharCode(code);
        else if (code >= 0x5B && code <= 0x5F) text += '[£]↑←'[code - 0x5B];
        else text += '·';
    }
    return length > STRING_PREVIEW ? text + '…' : text;
}

//
// The name and type BASIC encodes in the high bits of a variable's two
// name bytes: neither set is a float, both an integer, the second a string,
// the first a DEF FN function.
//
function decodeName(first, second) {
    const name = String.fromCharCode(first & 0x7F) + (second & 0x7F ? String.fromCharCode(second & 0x7F) : '');
    if (first & 0x80 && second & 0x80) return { name: name + '%', type: 'integer' };
    if (second & 0x80) return { name: name + '$', type: 'string' };
    if (first & 0x80) return { name: 'FN ' + name, type: 'function' };
    return { name, type: 'float' };
}

function readValue(machine, type, address) {
    if (type === 'integer') {
        const value = (machine.peek(address) << 8) | machine.peek(address + 1);
        return value & 0x8000 ? value - 0x10000 : value;
    }
    if (type === 'string') {
        const length = machine.peek(address);
        return petsciiText(machine, word(machine, address + 1), length);
    }
    const bytes = [];
    for (let i = 0; i < 5; i++) bytes.push(machine.peek(address + i));
    return decodeFloat(bytes);
}

const ELEMENT_SIZE = { float: 5, integer: 2, string: 3 };

//
// The program's simple variables and arrays, in the order BASIC created them.
// @returns {{variables: Array, arrays: Array}} variables are
//   { name, type, value }; arrays are { name, type, dimensions, values }
//   with the first few elements of a one-dimensional array
//
export function readVariables(machine) {
    const variables = [];
    const arrays = [];
    const layout = readMemoryLayout(machine);
    if (!layout) return { variables, arrays };
    const { variables: vartab, arrays: arytab, free: strend } = layout;

    for (let address = vartab; address < arytab && variables.length < MAX_VARIABLES; address += VARIABLE_SIZE) {
        const { name, type } = decodeName(machine.peek(address), machine.peek(address + 1));
        if (type === 'function') continue;
        variables.push({ name, type, value: readValue(machine, type, address + 2) });
    }

    for (let address = arytab; address < strend && arrays.length < MAX_ARRAYS;) {
        const { name, type } = decodeName(machine.peek(address), machine.peek(address + 1));
        const length = word(machine, address + 2);
        const count = machine.peek(address + 4);
        if (length < 7 || count === 0 || address + length > strend || !ELEMENT_SIZE[type]) break;
        // Sizes are stored high byte first, last dimension first, each one
        // more than the DIM value.
        const dimensions = [];
        for (let d = 0; d < count; d++) {
            const offset = address + 5 + d * 2;
            dimensions.unshift(((machine.peek(offset) << 8) | machine.peek(offset + 1)) - 1);
        }
        const values = [];
        if (count === 1) {
            const first = address + 5 + count * 2;
            const shown = Math.min(dimensions[0] + 1, ARRAY_PREVIEW);
            for (let i = 0; i < shown; i++) {
                values.push(readValue(machine, type, first + i * ELEMENT_SIZE[type]));
            }
        }
        arrays.push({ name, type, dimensions, values });
        address += length;
    }
    return { variables, arrays };
}

//
// Show a value as BASIC would print it in a listing.
//
export function formatValue(type, value) {
    if (type === 'string') return `"${value}"`;
    if (type === 'integer') return String(value);
    return formatBasicNumber(value);
}
