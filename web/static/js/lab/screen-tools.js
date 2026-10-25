//
// @fileoverview Screen tools for the BASIC and Assembly labs
// @module lab/screen-tools
//
// Adds the controls a learner reaches for while a program runs - pause,
// turbo, a CRT look, snapshot and full screen - plus:
// - Paste: Ctrl+V on the focused screen types the clipboard into the C64,
//   with {CLR}-style control codes expanded as in the BASIC editor.
// - The inspector: point at the screen to see the memory behind it. For a
//   character that is its screen and colour RAM addresses, the POKEs that
//   change it and an enlarged copy of its 8x8 glyph; anywhere, the sprite
//   coordinates of that spot, which are otherwise hard to work out.
//
// The inspector reads what the VIC-II reads (physical RAM, colour RAM and
// character ROM), never machine.read(), so it cannot disturb the program.
//
// @see https://www.turbo8bit.com/
//

import { rom_chars } from '../emulator/roms.js';
import { PALETTE, MODE_STANDARD_BITMAP, MODE_MULTICOLOR_BITMAP, MODE_EXTENDED_BACKGROUND } from '../emulator/vic-ii.js';
import { expandControlCodes } from '../emulator/basic-tokenizer.js';
import { downloadBlob, storage } from './files.js';

export const COLOR_NAMES = [
    'black', 'white', 'red', 'cyan', 'purple', 'green', 'blue', 'yellow',
    'orange', 'brown', 'light red', 'dark grey', 'grey', 'light green', 'light blue', 'light grey'
];

// Canvas geometry from vic-ii.js: 384x272 with the 320x200 display window
// 32px in and 36px down.
const CANVAS_WIDTH = 384;
const CANVAS_HEIGHT = 272;
const WINDOW_LEFT = 32;
const WINDOW_TOP = 36;

const CRT_PREFERENCE = 'turbo8bit.crt';
const INSPECT_EVERY_FRAMES = 5;

const hex = (value, digits) => '$' + value.toString(16).toUpperCase().padStart(digits, '0');

//
// The printable form of a screen code, or null for a graphics character.
// Screen codes are not PETSCII: on screen A is 1, but CHR$(65) prints it.
//
export function screenCodeText(code) {
    const c = code & 0x7F;
    if (c === 0) return '@';
    if (c <= 26) return String.fromCharCode(64 + c);
    if (c <= 31) return '[£]↑←'[c - 27];
    if (c <= 63) return String.fromCharCode(c);
    return null;
}

//
// Describe what the VIC-II shows at canvas pixel (x, y).
// @param {Object} machine - Needs ram, io and vic.renderer
// @returns {Object} area is 'border', 'background', 'character' or 'bitmap'
//
export function inspectScreen(machine, x, y) {
    const io = machine.io;
    // The sprite X/Y that would put a sprite's top-left pixel here.
    const sprite = { x: x - WINDOW_LEFT + 24, y: y - WINDOW_TOP + 50 };
    const inWindow = x >= WINDOW_LEFT && x < WINDOW_LEFT + 320 &&
        y >= WINDOW_TOP && y < WINDOW_TOP + 200;
    if (!inWindow) {
        return { area: 'border', color: io[0x020] & 15, sprite };
    }

    // Text rows start on their Bad Line: YSCROLL=3 aligns row 0 with the window.
    const xscroll = io[0x016] & 7;
    const yscroll = io[0x011] & 7;
    const col = Math.floor((x - WINDOW_LEFT - xscroll) / 8);
    const row = Math.floor((y - WINDOW_TOP - yscroll + 3) / 8);
    if (col < 0 || col > 39 || row < 0 || row > 24) {
        return { area: 'background', color: io[0x021] & 15, sprite };
    }

    const renderer = machine.vic.renderer;
    const { screenAddr, charAddr, bitmapAddr, useCharROM } = renderer.getMemoryAddresses(machine);
    const mode = renderer.getGraphicsMode(machine);
    const offset = row * 40 + col;
    const cell = {
        left: WINDOW_LEFT + xscroll + col * 8,
        top: WINDOW_TOP + yscroll - 3 + row * 8
    };
    const base = {
        row, col, cell, sprite,
        screenAddress: screenAddr + offset,
        colorAddress: 0xD800 + offset
    };

    if (mode === MODE_STANDARD_BITMAP || mode === MODE_MULTICOLOR_BITMAP) {
        return {
            ...base,
            area: 'bitmap',
            screenByte: machine.ram[screenAddr + offset],
            bitmapAddress: bitmapAddr + offset * 8
        };
    }

    const code = machine.ram[screenAddr + offset];
    const glyphCode = mode === MODE_EXTENDED_BACKGROUND ? code & 0x3F : code;
    const glyph = [];
    for (let line = 0; line < 8; line++) {
        glyph.push(useCharROM
            ? rom_chars[(charAddr & 0x0800) + glyphCode * 8 + line]
            : machine.ram[(charAddr + glyphCode * 8 + line) & 0xFFFF]);
    }
    return {
        ...base,
        area: 'character',
        code,
        glyph,
        color: io[0x800 + offset] & 15,
        background: io[0x021] & 15
    };
}

//
// Wire up the screen toolbar, paste and inspector for one emulator.
// @param {C64Emulator} emulator
// @param {Object} elements - { frame, toolbar, inspector, status, gamepadStatus }
//
export function attachScreenTools(emulator, { frame, toolbar, inspector, status, gamepadStatus }) {
    const canvas = emulator.canvas;
    if (gamepadStatus) {
        gamepadStatus.textContent = emulator.gamepadStatus;
        emulator.onGamepadChange(message => { gamepadStatus.textContent = message; });
    }
    const button = action => toolbar?.querySelector(`[data-screen-action="${action}"]`);
    const say = message => {
        if (status) status.textContent = message;
    };

    const badge = document.createElement('div');
    badge.className = 'screen-badge';
    badge.hidden = true;
    const marker = document.createElement('div');
    marker.className = 'screen-cell-marker';
    marker.hidden = true;
    // Overlays are placed in canvas percentages, so they live in the stage
    // that has the canvas's exact size, even when the frame is full screen.
    (frame.querySelector('.screen-stage') ?? frame).append(marker, badge);

    // ---- Pause and turbo follow the emulator, whoever changes them ----
    const pauseButton = button('pause');
    const turboButton = button('turbo');
    const showState = () => {
        if (pauseButton) {
            pauseButton.textContent = emulator.paused ? '▶ Resume' : '⏸ Pause';
            pauseButton.setAttribute('aria-pressed', String(emulator.paused));
        }
        if (turboButton) {
            turboButton.setAttribute('aria-pressed', String(emulator.turbo));
            turboButton.classList.toggle('active', emulator.turbo);
        }
        badge.hidden = !emulator.paused && !emulator.turbo;
        badge.textContent = emulator.paused ? 'PAUSED' : 'TURBO';
        badge.classList.toggle('turbo', !emulator.paused && emulator.turbo);
    };
    emulator.onStateChange(showState);
    showState();
    pauseButton?.addEventListener('click', () => {
        if (emulator.paused) emulator.resume();
        else emulator.pause();
    });
    turboButton?.addEventListener('click', () => emulator.setTurbo(!emulator.turbo));

    // ---- CRT look, remembered between visits ----
    const crtButton = button('crt');
    const setCrt = enabled => {
        frame.classList.toggle('crt', enabled);
        crtButton?.setAttribute('aria-pressed', String(enabled));
    };
    setCrt(storage.get(CRT_PREFERENCE) === 'on');
    crtButton?.addEventListener('click', () => {
        const enabled = !frame.classList.contains('crt');
        setCrt(enabled);
        storage.set(CRT_PREFERENCE, enabled ? 'on' : 'off');
    });

    // ---- Snapshot at twice the size, in the 4:3 shape of a TV picture ----
    button('snapshot')?.addEventListener('click', () => {
        const picture = document.createElement('canvas');
        picture.width = CANVAS_WIDTH * 2;
        picture.height = CANVAS_WIDTH * 2 * 3 / 4;
        const context = picture.getContext('2d');
        context.imageSmoothingEnabled = false;
        context.drawImage(canvas, 0, 0, picture.width, picture.height);
        picture.toBlob(blob => {
            if (!blob) return;
            const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
            downloadBlob(blob, `turbo8bit-${stamp}.png`);
            say('Snapshot saved.');
        }, 'image/png');
    });

    // ---- Full screen keeps the keyboard on the C64 ----
    const fullscreenButton = button('fullscreen');
    fullscreenButton?.addEventListener('click', async () => {
        try {
            if (document.fullscreenElement) {
                await document.exitFullscreen();
            } else {
                await frame.requestFullscreen();
                canvas.focus({ preventScroll: true });
            }
        } catch (error) {
            say('Full screen is not available in this browser.');
        }
    });
    document.addEventListener('fullscreenchange', () => {
        fullscreenButton?.setAttribute('aria-pressed', String(document.fullscreenElement === frame));
    });

    // ---- Paste types the clipboard, so a listing can be dropped in ----
    document.addEventListener('paste', event => {
        if (document.activeElement !== canvas) return;
        const text = event.clipboardData?.getData('text');
        if (!text) return;
        event.preventDefault();
        emulator.typeText(expandControlCodes(text.replace(/\r\n?/g, '\n')), { lineDelay: 120 });
        say('Typing the pasted text into the C64...');
    });

    // ---- Inspector ----
    if (!inspector) return;
    inspector.replaceChildren();
    const glyphCanvas = document.createElement('canvas');
    glyphCanvas.width = 8;
    glyphCanvas.height = 8;
    glyphCanvas.className = 'inspector-glyph';
    glyphCanvas.setAttribute('aria-hidden', 'true');
    const text = document.createElement('div');
    text.className = 'inspector-text';
    const title = document.createElement('div');
    title.className = 'inspector-title';
    const poke = document.createElement('code');
    poke.className = 'inspector-poke';
    const detail = document.createElement('div');
    detail.className = 'inspector-detail';
    text.append(title, poke, detail);
    inspector.append(glyphCanvas, text);

    let pointer = null;
    let framesSinceInspect = 0;

    const showIdle = () => {
        marker.hidden = true;
        glyphCanvas.hidden = true;
        title.textContent = 'Screen inspector';
        poke.textContent = '';
        detail.textContent = 'Point at the C64 screen to see the memory behind each character.';
    };

    // Character ROM stores codes 128-255 already reversed, so the glyph bytes
    // are drawn exactly as the VIC-II draws them.
    const drawGlyph = info => {
        const context = glyphCanvas.getContext('2d');
        const pixels = context.createImageData(8, 8);
        const on = PALETTE[info.color];
        const off = PALETTE[info.background];
        for (let y = 0; y < 8; y++) {
            for (let x = 0; x < 8; x++) {
                const lit = ((info.glyph[y] >> (7 - x)) & 1) === 1;
                const rgb = lit ? on : off;
                const i = (y * 8 + x) * 4;
                pixels.data[i] = rgb >> 16;
                pixels.data[i + 1] = (rgb >> 8) & 0xFF;
                pixels.data[i + 2] = rgb & 0xFF;
                pixels.data[i + 3] = 255;
            }
        }
        context.putImageData(pixels, 0, 0);
        glyphCanvas.title = `Glyph bytes: ${info.glyph.map(b => hex(b, 2)).join(' ')}`;
        glyphCanvas.hidden = false;
    };

    const showCell = info => {
        marker.hidden = false;
        marker.style.left = `${info.cell.left / CANVAS_WIDTH * 100}%`;
        marker.style.top = `${info.cell.top / CANVAS_HEIGHT * 100}%`;
        marker.style.width = `${8 / CANVAS_WIDTH * 100}%`;
        marker.style.height = `${8 / CANVAS_HEIGHT * 100}%`;
    };

    const inspect = () => {
        if (!pointer) return;
        const info = inspectScreen(emulator.machine, pointer.x, pointer.y);
        const where = `Sprite X ${info.sprite.x}, Y ${info.sprite.y}`;
        if (info.area === 'border' || info.area === 'background') {
            const register = info.area === 'border' ? 53280 : 53281;
            marker.hidden = true;
            glyphCanvas.hidden = true;
            title.textContent = `${info.area === 'border' ? 'Border' : 'Background'}: ` +
                `${COLOR_NAMES[info.color]} (${info.color})`;
            poke.textContent = `POKE ${register},${info.color}`;
            detail.textContent = `Register ${hex(register, 4)} · ${where}`;
            return;
        }

        showCell(info);
        const position = `Row ${info.row}, column ${info.col}`;
        if (info.area === 'bitmap') {
            glyphCanvas.hidden = true;
            title.textContent = `${position}: bitmap cell`;
            poke.textContent = `POKE ${info.screenAddress},${info.screenByte}`;
            detail.textContent = `Colours in screen RAM ${hex(info.screenAddress, 4)} · ` +
                `8 pixel bytes from ${hex(info.bitmapAddress, 4)} · ${where}`;
            return;
        }

        drawGlyph(info);
        const printable = screenCodeText(info.code);
        const shape = printable === null ? 'graphics character'
            : printable === ' ' ? 'space' : `'${printable}'`;
        title.textContent = `${position}: ${shape}${info.code >= 128 ? ' (reversed)' : ''} ` +
            `in ${COLOR_NAMES[info.color]}`;
        poke.textContent = `POKE ${info.screenAddress},${info.code} : POKE ${info.colorAddress},${info.color}`;
        detail.textContent = `Screen code ${info.code} at ${hex(info.screenAddress, 4)} · ` +
            `colour ${info.color} at ${hex(info.colorAddress, 4)} · ${where}`;
    };

    canvas.addEventListener('pointermove', event => {
        const rect = canvas.getBoundingClientRect();
        if (!rect.width || !rect.height) return;
        pointer = {
            x: Math.floor((event.clientX - rect.left) / rect.width * CANVAS_WIDTH),
            y: Math.floor((event.clientY - rect.top) / rect.height * CANVAS_HEIGHT)
        };
        inspect();
    });
    canvas.addEventListener('pointerleave', () => {
        pointer = null;
        showIdle();
    });
    // Running programs change what is under a still pointer.
    emulator.onFrame(framesRun => {
        framesSinceInspect += framesRun;
        if (pointer && framesSinceInspect >= INSPECT_EVERY_FRAMES) {
            framesSinceInspect = 0;
            inspect();
        }
    });
    showIdle();
}
