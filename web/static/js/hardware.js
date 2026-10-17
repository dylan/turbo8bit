//
// @fileoverview C64 Architecture Simulator - 2D hardware visualization
// @module hardware
//
// Interactive 2D visualization of Commodore 64 hardware communication.
// Shows the C64 motherboard with chips (CPU, VIC-II, SID, CIA, ROM, RAM)
// connected via address and data buses. The traffic is real: each scenario
// is a trace of a running C64Machine (see bus-trace.js), played back one bus
// access at a time with the KERNAL instruction that made it.
//
// Features:
// - Canvas-based 2D rendering of C64 motherboard layout
// - Animated bus signals (red = address bus, yellow = data bus)
// - The chips selected for each access light up, with the PLA that chose them
// - A log of every access and what it was for; pause, step and speed controls
// - Optional 3D chip images via chip3d.js
//
// Used on the /hardware page of Turbo8bit.
//
// @see https://www.turbo8bit.com/
//

import { SCENARIO_TRACES, DIAGRAM_PARTS } from './bus-trace.js';

const canvas = document.getElementById('simCanvas');
const ctx = canvas.getContext('2d');
const logPanel = document.getElementById('logPanel');
const reducedMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false;

// --- Pre-rendered 3D chip images (set by module script) ---
let chipImages = {};
let chipImageOpacity = {}; // Track fade-in opacity for each chip type

// Function to set chip images from external module
window.setChipImages = function (images) {
    chipImages = images;
    // Initialize fade-in for each new image
    for (const key of Object.keys(images)) {
        if (chipImageOpacity[key] === undefined) {
            chipImageOpacity[key] = reducedMotion ? 1 : 0;
        }
    }
};

// --- Configuration ---
const COLORS = {
    bg: '#352879',           // C64 board color
    text: '#ffffff',
    addressBus: '#ff5555',   // Red
    dataBus: '#ffff55',      // Yellow
    highlight: '#9ae29b',
    dimRed: '#553333',
    dimYellow: '#555533',
    wireRed: '#774444',
    wireYellow: '#777744',
    busBackground: 'rgba(0,0,0,0.2)',
    labelDim: 'rgba(255,255,255,0.3)'
};

const LABEL_FONT = "'Consolas', 'Monaco', 'Courier New', monospace";

// --- Component Layout (Short Board 250469 - matches C64C motherboard photo) ---
// Note: This board has an MMU (252535-01) that combines PLA + glue logic,
// and a Super ROM (251913-01) that holds BASIC + KERNAL; the character ROM
// is still a separate chip (901225-01)
const components = {
    // Processor Chips (left side)
    CPU: { x: 50, y: 50, w: 120, h: 100, label1: "CPU", label2: "MOS 6510", type: "proc", chipType: "CPU_6510" },
    VIC: { x: 50, y: 200, w: 120, h: 100, label1: "VIC-II", label2: "MOS 6569", type: "proc", chipType: "VIC_6569" },
    SID: { x: 50, y: 350, w: 120, h: 80, label1: "SID", label2: "MOS 6581", type: "io", chipType: "SID_6581" },
    CIA: { x: 50, y: 460, w: 120, h: 80, label1: "CIA 1 + 2", label2: "MOS 6526", type: "io", chipType: "CIA_6526" },

    // The Bus is the central spine
    BUS: { x: 250, y: 26, w: 200, h: 540, label1: "SYSTEM", label2: "BUS", type: "bus" },

    // Memory/Logic Chips (right side - Short Board 250469 layout)
    MMU: { x: 550, y: 26, w: 110, h: 55, label1: "SUPERPLA", label2: "252535-01", type: "mem", chipType: "MMU" },
    ROM: { x: 550, y: 117, w: 110, h: 55, label1: "BASIC + KERNAL", label2: "251913-01", type: "mem", chipType: "ROM_COMBINED" },
    CHAR: { x: 550, y: 208, w: 110, h: 55, label1: "CHARACTER ROM", label2: "901225-01", type: "mem", chipType: "CHAROM" },
    // Each 4464 stores four of the eight bits of every byte, so both answer every RAM access.
    RAM1: { x: 550, y: 299, w: 100, h: 55, label1: "DRAM U9 (4 bits)", label2: "4464", type: "mem", chipType: "RAM_4464" },
    RAM2: { x: 550, y: 390, w: 100, h: 55, label1: "DRAM U10 (4 bits)", label2: "4464", type: "mem", chipType: "RAM_4464" },
    CRAM: { x: 550, y: 481, w: 100, h: 50, label1: "COLOUR RAM", label2: "1K x 4 bits", type: "mem", chipType: "RAM_4464" }
};

// Connections define where wires are drawn
const connections = [
    { from: 'CPU', to: 'BUS' },
    { from: 'VIC', to: 'BUS' },
    { from: 'SID', to: 'BUS' },
    { from: 'CIA', to: 'BUS' },
    { from: 'BUS', to: 'MMU' },
    { from: 'BUS', to: 'ROM' },
    { from: 'BUS', to: 'CHAR' },
    { from: 'BUS', to: 'RAM1' },
    { from: 'BUS', to: 'RAM2' },
    { from: 'BUS', to: 'CRAM' }
];

// --- State ---
let packets = []; // Flying dots
let active = new Set(); // Components lit by the current access

// --- Helper Functions ---
function logLine(text, className = '') {
    const div = document.createElement('div');
    div.className = 'log-entry' + (className ? ' ' + className : '');
    div.textContent = text;
    logPanel.appendChild(div);
    // Keep the log readable on long traces.
    while (logPanel.childElementCount > 300) logPanel.firstElementChild.remove();
    logPanel.scrollTop = logPanel.scrollHeight;
}

function clearLog() {
    logPanel.replaceChildren();
}

// --- Drawing System ---

function drawDIPChip(key, comp) {
    const x = comp.x;
    const y = comp.y;
    const w = comp.w;
    const h = comp.h;
    const padding = 8;

    if (active.has(key)) {
        ctx.save();
        ctx.shadowColor = COLORS.highlight;
        ctx.shadowBlur = 24;
        ctx.strokeStyle = COLORS.highlight;
        ctx.lineWidth = 3;
        ctx.strokeRect(x - padding, y - padding, w + padding * 2, h + padding * 2);
        ctx.restore();
    }

    // Always draw the label first (visible immediately)
    ctx.fillStyle = active.has(key) ? COLORS.highlight : COLORS.text;
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    ctx.font = `bold 12px ${LABEL_FONT}`;
    ctx.fillText(comp.label1, x + w / 2, y + h + padding + 2);
    ctx.font = `10px ${LABEL_FONT}`;
    ctx.fillStyle = '#aaaaaa';
    ctx.fillText(comp.label2, x + w / 2, y + h + padding + 16);

    // Draw 3D chip image with fade-in effect when available
    if (comp.chipType && chipImages[comp.chipType]) {
        const img = chipImages[comp.chipType];

        // Update opacity for fade-in effect
        if (chipImageOpacity[comp.chipType] < 1) {
            chipImageOpacity[comp.chipType] = Math.min(1, chipImageOpacity[comp.chipType] + 0.02);
        }

        // Draw with current opacity
        ctx.save();
        ctx.globalAlpha = chipImageOpacity[comp.chipType];
        ctx.drawImage(img, x - padding, y - padding, w + padding * 2, h + padding * 2);
        ctx.restore();
    } else {
        ctx.fillStyle = '#222';
        ctx.fillRect(x, y, w, h);
    }
}

function spineX(type) {
    const bus = components.BUS;
    return type === 'addr' ? bus.x + bus.w * 0.33 : bus.x + bus.w * 0.66;
}

function drawBus() {
    const bus = components.BUS;

    // Background for Bus Area
    ctx.fillStyle = COLORS.busBackground;
    ctx.fillRect(bus.x, bus.y, bus.w, bus.h);

    // Draw physical lines (Address = Red, Data = Yellow)
    ctx.lineWidth = 12;

    // Vertical Bus Lines
    ctx.strokeStyle = COLORS.dimRed;
    ctx.beginPath();
    ctx.moveTo(spineX('addr'), bus.y);
    ctx.lineTo(spineX('addr'), bus.y + bus.h);
    ctx.stroke();

    ctx.strokeStyle = COLORS.dimYellow;
    ctx.beginPath();
    ctx.moveTo(spineX('data'), bus.y);
    ctx.lineTo(spineX('data'), bus.y + bus.h);
    ctx.stroke();

    // Connect components to spine
    ctx.lineWidth = 6;
    connections.forEach(conn => {
        const fromBus = conn.from === 'BUS';
        const part = components[fromBus ? conn.to : conn.from];
        const y = part.y + part.h / 2;
        const x = fromBus ? part.x : part.x + part.w;

        // Draw Wire Traces
        ctx.strokeStyle = COLORS.wireRed;
        ctx.beginPath();
        ctx.moveTo(x, y - 5);
        ctx.lineTo(spineX('addr'), y - 5);
        ctx.stroke();

        ctx.strokeStyle = COLORS.wireYellow;
        ctx.beginPath();
        ctx.moveTo(x, y + 5);
        ctx.lineTo(spineX('data'), y + 5);
        ctx.stroke();
    });

    // Label the bus lines
    ctx.fillStyle = COLORS.labelDim;
    ctx.font = `14px ${LABEL_FONT}`;
    ctx.textAlign = "center";
    ctx.fillText("ADDR", spineX('addr'), bus.y + 20);
    ctx.fillText("DATA", spineX('data'), bus.y + 20);
}

function drawPackets(dt) {
    const step = packetSpeed() * dt;
    packets.forEach(p => {
        // Draw packet with glow effect
        ctx.shadowColor = p.type === 'addr' ? COLORS.addressBus : COLORS.dataBus;
        ctx.shadowBlur = 10;

        ctx.fillStyle = p.type === 'addr' ? COLORS.addressBus : COLORS.dataBus;
        ctx.beginPath();
        ctx.arc(p.x, p.y, 6, 0, Math.PI * 2);
        ctx.fill();

        ctx.shadowBlur = 0;

        // Move packet
        const dx = p.tx - p.x;
        const dy = p.ty - p.y;
        const dist = Math.sqrt(dx * dx + dy * dy);

        if (dist <= step) {
            p.finished = true;
        } else {
            p.x += (dx / dist) * step;
            p.y += (dy / dist) * step;
        }
    });
    // Remove finished packets, then start the next leg of each signal. A
    // signal cleared from `packets` is simply never continued.
    const finished = packets.filter(p => p.finished);
    packets = packets.filter(p => !p.finished);
    for (const packet of finished) packet.next?.();
}

let lastFrameTime = 0;

function render(now = 0) {
    if (!renderRunning) return;
    const dt = lastFrameTime ? Math.min(now - lastFrameTime, 50) : 16;
    lastFrameTime = now;

    // Clear canvas with background color
    ctx.fillStyle = COLORS.bg;
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    drawBus();

    for (const key in components) {
        if (key !== 'BUS') drawDIPChip(key, components[key]);
    }

    drawPackets(dt);

    requestAnimationFrame(render);
}

// The canvas animates continuously, so only run it while it is on screen.
let renderRunning = false;

function startRender() {
    if (renderRunning) return;
    renderRunning = true;
    lastFrameTime = 0;
    requestAnimationFrame(render);
}

// --- Playback ---

const SPEEDS = { slow: 1400, normal: 700, fast: 250 };
let stepMs = SPEEDS.normal;
let trace = [];
let position = 0;
let playing = false;
let timer = null;

// Pixels per millisecond, so a signal crosses the board within one step.
function packetSpeed() {
    return 700 / stepMs;
}

//
// A signal travels component -> spine -> component.
//
function sendSignal(from, to, type) {
    if (reducedMotion) return;
    const start = components[from];
    const end = components[to];
    const startY = start.y + start.h / 2 + (type === 'addr' ? -5 : 5);
    const endY = end.y + end.h / 2 + (type === 'addr' ? -5 : 5);
    const startX = from === 'CPU' || from === 'VIC' || from === 'SID' || from === 'CIA'
        ? start.x + start.w : start.x;
    const endX = to === 'CPU' || to === 'VIC' || to === 'SID' || to === 'CIA'
        ? end.x + end.w : end.x;
    const x = spineX(type);
    // Three legs, chained so they read as one signal.
    const legs = [
        [startX, startY, x, startY],
        [x, startY, x, endY],
        [x, endY, endX, endY]
    ];
    const launch = i => {
        if (i >= legs.length) return;
        const [sx, sy, tx, ty] = legs[i];
        packets.push({ x: sx, y: sy, tx, ty, type, finished: false, next: () => launch(i + 1) });
    };
    launch(0);
}

function showStep(step) {
    const parts = DIAGRAM_PARTS[step.chip] ?? [];
    const master = step.who === 'VIC' ? 'VIC' : 'CPU';
    active = new Set([master, 'MMU', ...parts]);
    for (const part of parts) {
        sendSignal(master, part, 'addr');
        if (step.op === 'read') sendSignal(part, master, 'data');
        else sendSignal(master, part, 'data');
    }
    if (step.instruction) logLine(step.instruction, 'log-instruction');
    logLine(step.text, step.op === 'write' ? 'log-write' : 'log-read');
    if (step.note) logLine(step.note, 'log-note');
}

function scheduleNext() {
    clearTimeout(timer);
    timer = null;
    if (!playing) return;
    if (position >= trace.length) {
        finish();
        return;
    }
    showStep(trace[position++]);
    updateControls();
    timer = setTimeout(scheduleNext, trace[position - 1]?.note ? stepMs * 2.2 : stepMs);
}

function finish() {
    playing = false;
    active = new Set();
    logLine('--- End of trace. Every access above was made by the emulated C64. ---', 'log-end');
    updateControls();
}

const pauseButton = document.getElementById('tracePause');
const stepButton = document.getElementById('traceStep');
const speedSelect = document.getElementById('traceSpeed');

function updateControls() {
    const loaded = trace.length > 0 && position < trace.length;
    if (pauseButton) {
        pauseButton.disabled = !loaded;
        pauseButton.textContent = playing ? '⏸ Pause' : '▶ Play';
        pauseButton.setAttribute('aria-pressed', String(!playing && loaded));
    }
    if (stepButton) stepButton.disabled = playing || !loaded;
}

function runScenario(name) {
    const record = SCENARIO_TRACES[name];
    if (!record) return;
    clearTimeout(timer);
    packets = [];
    clearLog();
    startRender();
    const title = document.querySelector(`[data-scenario="${name}"]`)?.textContent.trim() ?? name;
    logLine(`--- ${title.toUpperCase()} ---`, 'log-title');
    try {
        trace = record();
    } catch (error) {
        console.error('Bus trace failed:', error);
        logLine('The emulator could not record this scenario.', 'log-note');
        trace = [];
    }
    position = 0;
    playing = true;
    scheduleNext();
}

document.querySelectorAll('[data-scenario]').forEach(button => {
    button.addEventListener('click', () => runScenario(button.dataset.scenario));
});

pauseButton?.addEventListener('click', () => {
    playing = !playing;
    if (playing) scheduleNext();
    else clearTimeout(timer);
    updateControls();
});

stepButton?.addEventListener('click', () => {
    if (position < trace.length) {
        packets = [];
        showStep(trace[position++]);
        if (position >= trace.length) finish();
        updateControls();
    }
});

speedSelect?.addEventListener('change', () => {
    stepMs = SPEEDS[speedSelect.value] ?? SPEEDS.normal;
});

updateControls();

// Draw the board immediately, then keep animating only while it is visible.
startRender();
new IntersectionObserver(([entry]) => {
    if (entry.isIntersecting) {
        startRender();
    } else {
        renderRunning = false;
    }
}).observe(canvas);
