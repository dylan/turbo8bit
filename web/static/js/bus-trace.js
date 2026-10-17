//
// @fileoverview Real bus traffic for the hardware page's bus diagram
// @module bus-trace
//
// Runs a real C64Machine with a probe on its bus and records the memory
// accesses it makes, attributed to the chip the PLA selects for each one.
// The hardware page animates these instead of a script, so the diagram shows
// what the KERNAL really does when the C64 starts, reads the keyboard, draws
// the screen and plays a note.
//
// The probe replaces machine.read/write with recording wrappers. The CPU
// reaches memory only through those two methods (see machine.js), so every
// CPU access is seen, in order. The VIC-II's fetches do not pass through the
// CPU's bus in this emulator, so the screen scenario derives them from the
// same registers and memory the renderer uses.
//
// @see https://www.turbo8bit.com/
//

import { C64Machine } from './emulator/machine.js';
import { disassembleInstruction } from './emulator/assembler.js';
import { rom_chars } from './emulator/roms.js';

const hex = (value, digits = 4) => '$' + value.toString(16).toUpperCase().padStart(digits, '0');

// ----------------------------------------------------------------------------
// Which chip answers an address
// ----------------------------------------------------------------------------

//
// Name the chip the PLA selects for a CPU access, from the machine's own
// banking tables (readMap/writeMap, see machine.updateMemoryMap()).
//
export function chipFor(machine, address, write) {
    const page = address >> 8;
    const type = write
        ? [0, 4, 7][machine.writeMap[page]]
        : machine.readMap[page];
    switch (type) {
        case 0: return address < 2 ? 'CPU port' : 'RAM';
        case 1: return 'BASIC ROM';
        case 2: return 'KERNAL ROM';
        case 3: return 'Character ROM';
        case 4:
            if (address < 0xD400) return 'VIC-II';
            if (address < 0xD800) return 'SID';
            if (address < 0xDC00) return 'Colour RAM';
            if (address < 0xDD00) return 'CIA 1';
            if (address < 0xDE00) return 'CIA 2';
            return 'Expansion port';
        case 5:
        case 6:
            return 'Cartridge';
        default:
            return 'Open bus';
    }
}

// The component on the hardware page's diagram that each chip belongs to.
export const DIAGRAM_PARTS = {
    'RAM': ['RAM1', 'RAM2'],   // Each 4464 DRAM holds four bits of every byte.
    'CPU port': ['CPU'],
    'BASIC ROM': ['ROM'],
    'KERNAL ROM': ['ROM'],
    'Character ROM': ['CHAR'],
    'VIC-II': ['VIC'],
    'SID': ['SID'],
    'Colour RAM': ['CRAM'],
    'CIA 1': ['CIA'],
    'CIA 2': ['CIA']
};

// ----------------------------------------------------------------------------
// What an address is for
// ----------------------------------------------------------------------------

const VIC_REGISTERS = {
    0x11: 'screen control (display on, 25 rows, vertical scroll)',
    0x12: 'raster line',
    0x15: 'sprite enable',
    0x16: 'screen control 2 (40 columns, multicolour)',
    0x18: 'memory pointers (screen at $0400, characters)',
    0x19: 'interrupt status',
    0x1A: 'interrupt enable',
    0x20: 'border colour',
    0x21: 'background colour'
};

const SID_VOICE_REGISTERS = [
    'frequency low byte', 'frequency high byte', 'pulse width low byte',
    'pulse width high byte', 'control (waveform and gate)', 'attack/decay',
    'sustain/release'
];

const SID_REGISTERS = {
    0x15: 'filter cutoff low', 0x16: 'filter cutoff high',
    0x17: 'filter resonance and routing', 0x18: 'volume and filter mode'
};

const CIA1_REGISTERS = {
    0x00: 'port A: selects which keyboard lines to scan',
    0x01: 'port B: shows which keys on those lines are down',
    0x02: 'port A direction', 0x03: 'port B direction',
    0x04: 'timer A low byte', 0x05: 'timer A high byte',
    0x0D: 'interrupt control', 0x0E: 'timer A control', 0x0F: 'timer B control'
};

const CIA2_REGISTERS = {
    0x00: 'port A: serial bus and VIC-II bank',
    0x02: 'port A direction',
    0x0D: 'interrupt control (NMI)', 0x0E: 'timer A control', 0x0F: 'timer B control'
};

//
// A short description of what lives at an address.
//
function vicRegisterName(register) {
    if (register < 0x10) return `sprite ${register >> 1} ${register & 1 ? 'Y' : 'X'} position`;
    if (register >= 0x22 && register <= 0x24) return `background colour ${register - 0x21}`;
    if (register === 0x25 || register === 0x26) return `sprite multicolour ${register - 0x24}`;
    if (register >= 0x27 && register <= 0x2E) return `sprite ${register - 0x27} colour`;
    return VIC_REGISTERS[register] ?? `register ${hex(register, 2)}`;
}

export function describeAddress(address) {
    if (address === 0) return 'CPU port direction register';
    if (address === 1) return 'CPU port: memory banking';
    if (address === 0xC6) return 'number of keys in the keyboard buffer';
    if (address >= 0x0100 && address <= 0x01FF) return 'the stack';
    if (address >= 0x0277 && address <= 0x0280) return 'the keyboard buffer';
    if (address >= 0x0400 && address <= 0x07E7) {
        const offset = address - 0x0400;
        return `screen memory, row ${Math.floor(offset / 40)} column ${offset % 40}`;
    }
    if (address >= 0x8004 && address <= 0x8008) return 'where a cartridge would put "CBM80"';
    if (address === 0xA000 || address === 0xA001) return 'the start of BASIC ROM';
    if (address >= 0xA000 && address <= 0xBFFF) return 'the BASIC interpreter';
    if (address >= 0xE000) {
        if (address >= 0xFFFA) return ['NMI', 'reset', 'IRQ'][(address - 0xFFFA) >> 1] + ' vector';
        return 'the KERNAL';
    }
    if (address >= 0xD000 && address <= 0xD3FF) {
        return 'VIC-II ' + vicRegisterName(address & 0x3F);
    }
    if (address >= 0xD400 && address <= 0xD7FF) {
        const register = address & 0x1F;
        if (register < 21) {
            return `SID voice ${Math.floor(register / 7) + 1} ${SID_VOICE_REGISTERS[register % 7]}`;
        }
        return 'SID ' + (SID_REGISTERS[register] ?? 'register');
    }
    if (address >= 0xD800 && address <= 0xDBE7) {
        const offset = address - 0xD800;
        return `colour of row ${Math.floor(offset / 40)} column ${offset % 40}`;
    }
    if (address >= 0xDC00 && address <= 0xDCFF) {
        return 'CIA 1 ' + (CIA1_REGISTERS[address & 0x0F] ?? `register ${address & 0x0F}`);
    }
    if (address >= 0xDD00 && address <= 0xDDFF) {
        return 'CIA 2 ' + (CIA2_REGISTERS[address & 0x0F] ?? `register ${address & 0x0F}`);
    }
    return null;
}

// ----------------------------------------------------------------------------
// Recording
// ----------------------------------------------------------------------------

//
// Record every CPU bus access made while action() runs.
// @param {C64Machine} machine
// @param {Function} action - Runs the machine (step, runFrame...)
// @param {Function} keep - (event, index) => true to keep the event
// @returns {Array<Object>} { who, op, address, value, chip, at } events, where
//   at is the address of the instruction that made the access
//
export function recordAccesses(machine, action, keep = () => true) {
    const events = [];
    const cpu = machine.cpu;
    const { read, write } = Object.getPrototypeOf(machine);
    const step = Object.getPrototypeOf(cpu).step;
    // Null until the first instruction: a reset's vector fetch belongs to none.
    let instruction = null;
    let index = 0;

    const record = (op, address, value, chip) => {
        const event = { who: 'CPU', op, address, value, chip, at: instruction };
        if (keep(event, index++)) events.push(event);
    };
    cpu.step = function () {
        // An interrupt is taken instead of the instruction at PC.
        const interrupting = cpu.nmiPending || (cpu.irqPending && !(cpu.P & 0x04));
        instruction = interrupting ? 'interrupt' : cpu.PC;
        return step.call(cpu);
    };
    machine.read = function (address) {
        address &= 0xFFFF;
        const chip = chipFor(machine, address, false);
        const value = read.call(machine, address);
        record('read', address, value, chip);
        return value;
    };
    machine.write = function (address, value) {
        address &= 0xFFFF;
        const chip = chipFor(machine, address, true);
        write.call(machine, address, value);
        record('write', address, value & 0xFF, chip);
    };
    try {
        action();
    } finally {
        delete machine.read;
        delete machine.write;
        delete cpu.step;
    }
    return events;
}

//
// Counts kept events per kind, so each scenario shows a few of each.
//
function quota() {
    const counts = new Map();
    return (kind, limit) => {
        const count = (counts.get(kind) ?? 0) + 1;
        counts.set(kind, count);
        return count <= limit;
    };
}

function runUntilReady(machine, frames = 200) {
    for (let i = 0; i < frames; i++) {
        machine.runFrame();
        if (machine.ram[0xC6] === 0 && machine.peek(0x2B) === 1 && machine.peek(0x2C) === 8 &&
            readyOnScreen(machine)) return;
    }
}

function readyOnScreen(machine) {
    const ready = [18, 5, 1, 4, 25, 46];
    for (let address = 0x400; address < 0x7E8 - ready.length; address++) {
        if (ready.every((code, i) => machine.ram[address + i] === code)) return true;
    }
    return false;
}

// ----------------------------------------------------------------------------
// Narration
// ----------------------------------------------------------------------------

function narrate(machine, event) {
    const what = describeAddress(event.address);
    const where = what ? ` (${what})` : '';
    if (event.who === 'VIC') {
        return `VIC-II reads ${hex(event.value, 2)} from ${event.chip}${where}`;
    }
    const verb = event.op === 'read' ? 'reads' : 'writes';
    const direction = event.op === 'read' ? 'from' : 'to';
    return `CPU ${verb} ${hex(event.value, 2)} ${direction} ${hex(event.address)} in ${event.chip}${where}`;
}

function withNarration(machine, events, notes = {}) {
    const view = { read: address => machine.peek(address) };
    let lastInstruction = null;
    return events.map(event => {
        const step = { ...event, text: event.text ?? narrate(machine, event) };
        if (event.who === 'CPU' && event.at !== null && event.at !== lastInstruction) {
            lastInstruction = event.at;
            step.instruction = event.at === 'interrupt'
                ? 'Interrupt: PC and flags are pushed, then the vector is read'
                : `${hex(event.at)}  ${disassembleInstruction(view, event.at).text}`;
        }
        if (notes[event.address] && event.op === notes[event.address].op) {
            step.note = notes[event.address].text;
        }
        return step;
    });
}

// ----------------------------------------------------------------------------
// Scenarios
// ----------------------------------------------------------------------------

//
// Power on: the reset vector, the first instructions, the cartridge check,
// the KERNAL setting up each chip and testing RAM, then BASIC taking over
// and printing its banner.
//
export function traceBoot() {
    const machine = new C64Machine({ audioEnabled: false });
    const take = quota();
    let basic = false;
    let banner = false;
    const keep = (event, index) => {
        const { address, op, chip } = event;
        const screen = address >= 0x0400 && address < 0x07E8;
        if (index < 18) {
            if (address === 0xFFFC) {
                event.note = 'At power-on the 6510 fetches the reset vector from the top of ' +
                    'memory, where the PLA has put the KERNAL ROM.';
            }
            return true;
        }
        if (address === 0x8008 && op === 'read') {
            event.note = 'Is there an autostart cartridge? The KERNAL compares $8004-$8008 with ' +
                '"CBM80". Here is plain RAM, so the check fails at once and start-up carries on.';
            return take('cartridge', 1);
        }
        if (chip === 'CIA 1' && op === 'write') {
            if (address === 0xDC0D) event.note = 'First the KERNAL silences every CIA interrupt.';
            return take('cia1', 3);
        }
        if (chip === 'CIA 2' && op === 'write') return take('cia2', 2);
        if (chip === 'SID' && op === 'write') return take('sid', 1);
        if (screen && op === 'write' && !basic) {
            if (!take('ramtest', 2)) return false;
            event.note = 'Testing RAM: the KERNAL writes a pattern to every byte and reads it ' +
                'back, page by page, to find out how much memory there is.';
            return true;
        }
        if (chip === 'VIC-II' && op === 'write') return take('vic', 3);
        // The RAM test runs on until a byte will not read back. At $A000 the
        // PLA answers reads from BASIC ROM, which is how the KERNAL finds
        // where RAM ends: 38911 bytes free for BASIC.
        if (address === 0xA000 && !basic && machine.peek(event.at) !== 0x6C) {
            if (op === 'read' && take('ramtop', 1)) {
                event.note = 'The RAM test reaches $A000. Reads here come from BASIC ROM, so the ' +
                    'pattern it wrote (into the RAM underneath) does not read back: RAM for ' +
                    'BASIC ends at $9FFF.';
                return true;
            }
            return false;
        }
        if ((address === 0xA000 || address === 0xA001) && op === 'read') {
            basic = true;
            if (address === 0xA000) {
                event.note = "The KERNAL jumps through BASIC's cold start vector: BASIC takes over.";
            }
            return take('basic', 2);
        }
        if (basic && screen && op === 'write' && event.value !== 32) {
            if (!banner) {
                event.note = 'BASIC prints its banner by writing screen codes into screen memory.';
            }
            banner = true;
            return take('banner', 4);
        }
        if (banner && chip === 'Colour RAM' && op === 'write') {
            event.note = 'Each character also gets a colour, in the separate colour RAM.';
            return take('colour', 1);
        }
        return false;
    };
    const events = recordAccesses(machine, () => {
        machine.cpu.reset();
        runUntilReady(machine);
    }, keep);
    return withNarration(machine, events);
}

//
// A keypress: CIA 1's timer interrupts the CPU 60 times a second, and the
// KERNAL's interrupt handler scans the keyboard through CIA 1. The key
// waits in the keyboard buffer until BASIC's editor prints it.
//
export function traceKeypress() {
    const machine = new C64Machine({ audioEnabled: false });
    runUntilReady(machine);

    const take = quota();
    // The trace may start inside an interrupt handler. The key goes down
    // as the next interrupt begins, so that handler is the one to find it.
    let started = false;
    let stored = false;
    let printed = false;
    let done = false;
    let stopChecked = false;
    const keep = event => {
        const { address, op, chip } = event;
        if (done) return false;
        if (address >= 0xFFFE && op === 'read' && take('vector', 2)) {
            if (!started) {
                started = true;
                machine.setKey(1, 2, true);  // A
                event.note = "CIA 1's timer has interrupted the CPU, which fetches the IRQ vector. " +
                    'The keyboard is not interrupt-driven: it is checked 60 times a second.';
            }
            return true;
        }
        if (!started) return false;
        if (chip === 'CIA 1' && (address & 0x0F) <= 1) {
            if (address === 0xDC01 && !stopChecked) {
                stopChecked = true;
                event.note = 'First the clock routine checks the RUN/STOP key, whose keyboard line ' +
                    'the last scan left selected.';
            }
            if (address === 0xDC00 && op === 'write' && event.value === 0) {
                event.note = 'Driving every keyboard line low at once tells the KERNAL whether any ' +
                    'key is down before it scans line by line.';
            }
            return take('scan', 13);
        }
        if (address >= 0x0277 && address <= 0x0280 && op === 'write') {
            stored = true;
            event.note = `The key goes into the keyboard buffer as PETSCII ${hex(event.value, 2)} ` +
                'until BASIC asks for it.';
            return take('buffer', 1);
        }
        if (stored && address === 0xC6 && op === 'write') return take('count', 1);
        if (chip === 'CIA 1' && address === 0xDC0D && op === 'read') {
            event.note = "Reading the CIA's interrupt register at the end of the handler " +
                'acknowledges the timer interrupt.';
            return take('acknowledge', 1);
        }
        if (stored && address >= 0x0400 && address < 0x07E8 && op === 'write' &&
            (event.value & 0x7F) === 1) {
            printed = true;
            event.note = "BASIC's editor prints the key: screen code 1 for A, not its PETSCII $41.";
            return take('print', 1);
        }
        if (printed && chip === 'Colour RAM' && op === 'write') {
            done = true;
            return take('colour', 1);
        }
        return false;
    };
    const events = recordAccesses(machine, () => {
        for (let frame = 0; frame < 10 && !done; frame++) machine.runFrame();
    }, keep);
    machine.setKey(1, 2, false);
    return withNarration(machine, events);
}

//
// One Bad Line: the VIC-II stops the CPU and fetches a row of screen codes,
// then the line of each character's shape from character ROM.
//
export function traceScreenRow() {
    const machine = new C64Machine({ audioEnabled: false });
    runUntilReady(machine);
    const { vicBank, screenAddr, charAddr } = machine.vic.renderer.getMemoryAddresses(machine);
    const row = 1;       // **** COMMODORE 64 BASIC V2 ****
    const events = [];
    for (let col = 0; col < 40 && events.length < 16; col++) {
        const address = screenAddr + row * 40 + col;
        const code = machine.ram[address];
        // Spaces and the stars have empty top lines; the letters show more.
        if (code === 32 || code === 42) continue;
        const shape = screenCodeName(code);
        events.push({
            who: 'VIC', op: 'read', address, value: code, chip: 'RAM',
            text: `VIC-II reads screen code ${hex(code, 2)} (${shape}) from ${hex(address)} in RAM`
        });
        // In banks 0 and 2 the VIC-II sees character ROM at $1000-$1FFF.
        const glyph = (charAddr & 0x0800) + code * 8;
        events.push({
            who: 'VIC', op: 'read', address: vicBank + 0x1000 + glyph, value: rom_chars[glyph],
            chip: 'Character ROM',
            text: `VIC-II reads ${hex(rom_chars[glyph], 2)} = %${rom_chars[glyph].toString(2).padStart(8, '0')}, ` +
                `the top line of ${shape}, from character ROM`
        });
    }
    events[0].note = 'This raster line is a Bad Line: the VIC-II takes the bus for about 40 ' +
        'cycles, stopping the CPU, to fetch the screen codes of a whole row of text.';
    events[1].note = 'For every character it also fetches one line of its 8x8 shape. The 1 bits ' +
        'are drawn in the character\'s colour.';
    return withNarration(machine, events);
}

function screenCodeName(code) {
    const c = code & 0x7F;
    if (c >= 1 && c <= 26) return `'${String.fromCharCode(64 + c)}'`;
    if (c >= 32 && c <= 63) return `'${String.fromCharCode(c)}'`;
    return 'a graphics character';
}

//
// A note: a small program sets up voice 1 and gates it on. Every byte of
// the program is fetched from RAM before each register is written.
//
export function traceSound() {
    const machine = new C64Machine({ audioEnabled: false });
    runUntilReady(machine);
    const program = [
        0xA9, 0x0F, 0x8D, 0x18, 0xD4,   // LDA #15   STA $D418  volume
        0xA9, 0x09, 0x8D, 0x05, 0xD4,   // LDA #$09  STA $D405  attack/decay
        0xA9, 0x22, 0x8D, 0x01, 0xD4,   // LDA #$22  STA $D401  pitch
        0xA9, 0x11, 0x8D, 0x04, 0xD4,   // LDA #$11  STA $D404  triangle + gate
        0x60                            // RTS
    ];
    machine.loadCode(program, 0xC000);
    machine.cpu.PC = 0xC000;
    machine.cpu.P |= 0x04;    // keep the timer interrupt out of this trace
    const events = recordAccesses(machine, () => {
        for (let i = 0; i < 8; i++) machine.step();
    });
    return withNarration(machine, events, {
        0xD418: { op: 'write', text: 'Volume first: the SID is silent until it is set.' },
        0xD404: { op: 'write', text: 'Setting the gate bit starts the attack: the note begins.' }
    });
}

export const SCENARIO_TRACES = {
    boot: traceBoot,
    typing: traceKeypress,
    vic: traceScreenRow,
    sound: traceSound
};
