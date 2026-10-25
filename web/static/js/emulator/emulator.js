//
// @fileoverview C64 Emulator UI - Entry point for visual C64 emulation in Turbo8bit
// @module emulator/emulator
//
// This is the main entry point for the visual C64 emulator. Import this module
// in index.html or any page that needs the full C64 experience with screen output.
//
// Provides:
// - Canvas rendering with VIC-II character and sprite display
// - Web Audio API output for SID sound
// - Keyboard and gamepad input handling
// - Session persistence (snapshot/restore)
//
// Browser Usage (index.html):
//   <script type="module">
//     import { C64Emulator } from '/static/js/emulator/emulator.js';
//     const emulator = new C64Emulator('screen');
//     emulator.start();
//   </script>
//
// For SID-only playback without visual emulation, see sid-player.js.
// For the core machine emulation (CPU, memory, I/O), see machine.js.
// For VIC-II graphics rendering, see vic-ii.js.
//
// @see https://www.turbo8bit.com/
//

import { C64Machine } from './machine.js';
import { ChipModel, SamplingMethod } from './sid.js';
import { VICIIRenderer } from './vic-ii.js';
import { HidGamepadInput } from './gamepad-hid.js';

// Ring buffer between the emulation loop and the Web Audio callback. Both run
// on the main thread, but at unrelated rates (50Hz frames vs 2048-sample
// blocks), so the buffer is what decouples them. Size must be a power of two
// so the index can be masked.
const AUDIO_RING_SIZE = 8192;
const AUDIO_RING_MASK = AUDIO_RING_SIZE - 1;

// Upper bound on the samples one emulated frame can produce (a 50Hz PAL frame
// is ~882 samples at 44.1kHz, ~960 at 48kHz). Resized in initAudio() once the
// real sample rate is known.
const AUDIO_FRAME_SAMPLES = 2048;

// How far ahead of the audio callback the emulation loop is allowed to get.
// This is the output latency, so keep it to a couple of ScriptProcessor blocks.
// Excess builds up during start-up, before the first callback fires, and is
// trimmed once.
const AUDIO_MAX_LEAD = 4096;
const BASIC_BOOT_FRAME_LIMIT = 1000;
const BASIC_READY_CODES = [18, 5, 1, 4, 25, 46];

// PAL frames per second: 985248 cycles / (63 cycles x 312 lines).
const PAL_FRAME_RATE = 50.125;

// Turbo runs whole frames for most of each display refresh, capped so a slow
// device still gets to paint and handle input.
const TURBO_BUDGET_MS = 12;
const TURBO_MAX_FRAMES = 40;

// The KERNAL keyboard buffer at $0277 holds this many keys ($C6 counts them).
const KEYBOARD_BUFFER_SIZE = 10;
const GAMEPAD_DEAD_ZONE = 0.4;
const MOUSE_FRAME_DELTA = 24;

// ============================================================================
// KEYBOARD MATRIX MAPPING
// ============================================================================
//
// The C64 matrix is 8 rows (CIA1 port A) by 8 columns (CIA1 port B). Mapping a
// PC keyboard onto it is not a straight lookup, because the two keyboards put
// SHIFT in different places: `*` is SHIFT+8 on a PC but an unshifted key on the
// C64, while `'` is unshifted on a PC and SHIFT+7 on the C64. So each entry also
// records what the C64's SHIFT must be doing while that key is down.

// Keys that take the C64 SHIFT from whatever the user is physically holding.
// Letters are here deliberately: unshifted letters already produce uppercase
// PETSCII, and SHIFT+letter is a graphics character, exactly as on real hardware.
const KEY_MATRIX = {
    'Backspace': [0, 0], 'Delete': [0, 0],
    'Enter': [0, 1],
    'ArrowRight': [0, 2],
    'F7': [0, 3], 'F1': [0, 4], 'F3': [0, 5], 'F5': [0, 6],
    'ArrowDown': [0, 7],

    '3': [1, 0], 'w': [1, 1], 'a': [1, 2], '4': [1, 3],
    'z': [1, 4], 's': [1, 5], 'e': [1, 6],

    '5': [2, 0], 'r': [2, 1], 'd': [2, 2], '6': [2, 3],
    'c': [2, 4], 'f': [2, 5], 't': [2, 6], 'x': [2, 7],

    '7': [3, 0], 'y': [3, 1], 'g': [3, 2], '8': [3, 3],
    'b': [3, 4], 'h': [3, 5], 'u': [3, 6], 'v': [3, 7],

    '9': [4, 0], 'i': [4, 1], 'j': [4, 2], '0': [4, 3],
    'm': [4, 4], 'k': [4, 5], 'o': [4, 6], 'n': [4, 7],

    'p': [5, 1], 'l': [5, 2],

    'Home': [6, 3],

    '1': [7, 0], 'Control': [7, 2], '2': [7, 3], ' ': [7, 4],
    'Alt': [7, 5], 'q': [7, 6], 'Escape': [7, 7]
};

// Unshifted C64 keys. Several of these need SHIFT on a PC to type at all, so the
// C64's SHIFT has to be forced off or the KERNAL decodes a graphics character.
const UNSHIFTED_KEY_MATRIX = {
    '+': [5, 0], '-': [5, 3], '.': [5, 4], ':': [5, 5], '@': [5, 6], ',': [5, 7],
    '\\': [6, 0], '*': [6, 1], ';': [6, 2], '=': [6, 5], '^': [6, 6], '/': [6, 7]
};

// Shifted C64 keys. CRSR left/up are shifted CRSR right/down, F2/F4/F6/F8 are
// shifted F1/F3/F5/F7, and the punctuation sits on the shifted number row.
const SHIFTED_KEY_MATRIX = {
    'ArrowLeft': [0, 2], 'ArrowUp': [0, 7],
    'F8': [0, 3], 'F2': [0, 4], 'F4': [0, 5], 'F6': [0, 6],
    '!': [7, 0],   // SHIFT+1
    '"': [7, 3],   // SHIFT+2
    '#': [1, 0],   // SHIFT+3
    '$': [1, 3],   // SHIFT+4
    '%': [2, 0],   // SHIFT+5
    '&': [2, 3],   // SHIFT+6
    "'": [3, 0],   // SHIFT+7
    '(': [3, 3],   // SHIFT+8
    ')': [4, 0],   // SHIFT+9
    '[': [5, 5],   // SHIFT+:
    ']': [6, 2],   // SHIFT+;
    '>': [5, 4],   // SHIFT+.
    '<': [5, 7],   // SHIFT+,
    '?': [6, 7]    // SHIFT+/
};

// Left SHIFT. Only updateShiftKey() may touch this position.
const SHIFT_KEY = [1, 7];

//
// The PETSCII code a typed character produces in the C64's default mode, or
// null for characters it has no key for. Letters type as unshifted (upper
// case); codes 128-255 pass through so expanded {CLR}-style codes work.
//
function petsciiForTyping(ch) {
    if (ch >= 'a' && ch <= 'z') return ch.charCodeAt(0) - 32;
    switch (ch) {
        case '£': return 0x5C;
        case '↑': return 0x5E;
        case '←': return 0x5F;
        case 'π': return 0xFF;
    }
    const code = ch.charCodeAt(0);
    return code <= 0xFF ? code : null;
}

//
// Resolve a KeyboardEvent.key into a matrix position and its SHIFT requirement.
// @returns {{row: number, col: number, shift: 'on'|'off'|'auto'}|null}
//
function lookupKey(key) {
    const shifted = SHIFTED_KEY_MATRIX[key];
    if (shifted) return { row: shifted[0], col: shifted[1], shift: 'on' };

    const unshifted = UNSHIFTED_KEY_MATRIX[key];
    if (unshifted) return { row: unshifted[0], col: unshifted[1], shift: 'off' };

    const normal = KEY_MATRIX[key] || KEY_MATRIX[key.toLowerCase()];
    if (normal) return { row: normal[0], col: normal[1], shift: 'auto' };

    return null;
}

//
// C64Emulator - Visual C64 emulator with canvas rendering and audio
//
// Wraps a C64Machine and provides:
// - Visual output via canvas rendering
// - Audio output via Web Audio API
// - Keyboard input handling
// - Main loop with frame timing
//
export class C64Emulator {
    constructor(id, options = {}) {
        this.canvas = document.getElementById(id);
        this.ctx = this.canvas.getContext('2d');
        this.ctx.imageSmoothingEnabled = false;

        // Internal resolution includes border: 384x272. The displayed size and
        // its 4:3 CRT aspect ratio are CSS's job (see #screen in style.css).
        this.canvas.width = 384;
        this.canvas.height = 272;

        // Audio settings
        this.audioEnabled = options.audioEnabled !== false;
        this.sampleRate = options.sampleRate || 44100;

        // Create machine with audio settings
        this.machine = new C64Machine({
            audioEnabled: this.audioEnabled,
            sampleRate: this.sampleRate,
            chipModel: options.chipModel || ChipModel.MOS6581
        });

        this.frame = 0;
        this.running = false;
        this.paused = false;  // For debug stepping mode
        this.turbo = false;   // Run as fast as the host allows
        this.fastBoot = false; // Run at turbo speed until BASIC is ready
        this.lastTime = 0;
        this.timeAccumulator = 0;
        this.animationId = null;
        this.runGeneration = 0;
        this.audioGeneration = 0;
        this.bootGeneration = 0;
        this.basicReady = false;
        this.bootFrames = 0;
        this.bootError = null;
        this.bootWaiters = [];
        this.onReset = options.onReset || null;

        // Page tools observe emulated frames and pause/turbo changes here
        // rather than running their own timers.
        this.frameListeners = new Set();
        this.stateListeners = new Set();
        this.inputListeners = new Set();

        // Joystick emulation state
        // When activeJoystick is 1 or 2, arrow keys and the gamepad use that port
        // When 0, arrow keys work as normal cursor keys
        this.activeJoystick = 0;
        this.joystickState = { up: false, down: false, left: false, right: false, fire: false };
        // Keyboard and controller holds are independent: releasing either must
        // not lift a button the other still holds.
        this.gamepadState = new Set();
        this.gamepadEnabled = false;
        this.gamepadConnection = 'off';
        this.gamepadStatus = 'Gamepad capture is off.';
        this.gamepadName = '';
        this.gamepadDiscoveryStarted = false;
        this.gamepadDevice = null;
        this.gamepadAvailable = true;
        this.gamepadUnmapped = false;
        this.gamepadHidInput = null;
        this.gamepadTransport = null;
        this.gamepadReady = false;
        this.mouseEnabled = false;
        this.mouseButtons = new Set();
        this.mouseDeltaX = 0;
        this.mouseDeltaY = 0;
        this.inputStateKey = JSON.stringify(this.getInputState());

        // True while the user is physically holding a PC Shift key.
        this.physicalShift = false;
        this.heldShiftKeys = new Set();
        this.heldJoystickKeys = new Map();
        this.pendingJoystickReleases = [];

        // Keys currently down, mapped to their matrix position and the frame
        // they went down on, plus releases deferred until that frame has run.
        this.heldKeys = new Map();
        this.pendingReleases = [];
        this.typingQueue = [];
        this.typingTimer = null;

        // VIC-II renderer
        this.vicRenderer = new VICIIRenderer(this.canvas.width, this.canvas.height);

        // Audio driver (initialized when started)
        this.audioContext = null;
        this.audioProcessor = null;

        // The emulation loop is the audio producer and the Web Audio callback is
        // the consumer, so samples pass between them through a ring buffer. One
        // PAL frame is ~882 samples at 44.1kHz; 8192 gives ~9 frames of slack.
        this.audioRing = new Float32Array(AUDIO_RING_SIZE);
        this.ringWrite = 0;
        this.ringRead = 0;
        this.frameSamples = new Int16Array(AUDIO_FRAME_SAMPLES);
        this.lastSample = 0;
    }

    reset({ keepCartridge = false } = {}) {
        this.fastBoot = false;
        this.cancelTyping();
        this.releaseAllInput();
        this.beginBasicBoot(keepCartridge
            ? new Error('Reset the C64 before loading a BASIC program with a cartridge mounted.')
            : null);
        if (!keepCartridge) this.machine.ejectCartridge();
        this.machine.reset();
        this.ringWrite = 0;
        this.ringRead = 0;
        this.lastSample = 0;
        this.timeAccumulator = 0;
        this.lastTime = performance.now();
        this.resume();
        this.onReset?.();
    }

    //
    // Reset and wait for BASIC READY. With fast, the boot runs at turbo speed
    // (about a tenth of a second) without touching the user's turbo setting;
    // a page that starts every program on a fresh machine needs that.
    //
    resetToBasic({ fast = false } = {}) {
        this.reset();
        this.fastBoot = fast;
        if (!this.running) this.start();
        return this.whenBasicReady();
    }

    beginBasicBoot(error = null) {
        for (const waiter of this.bootWaiters.splice(0)) {
            waiter.reject(new Error('BASIC startup was interrupted by a reset or cartridge change.'));
        }
        this.bootGeneration++;
        this.basicReady = false;
        this.bootFrames = 0;
        this.bootError = error;
    }

    whenBasicReady() {
        if (this.basicReady) return Promise.resolve();
        if (this.bootError) return Promise.reject(this.bootError);
        return new Promise((resolve, reject) => this.bootWaiters.push({ resolve, reject }));
    }

    checkBasicReady() {
        if (this.basicReady || this.bootError) return;
        if (++this.bootFrames > BASIC_BOOT_FRAME_LIMIT) {
            this.bootError = new Error('The C64 did not reach BASIC READY. Reset and try again.');
            for (const waiter of this.bootWaiters.splice(0)) waiter.reject(this.bootError);
            return;
        }

        // Only recognize the empty READY prompt of a fresh boot, never use
        // screen text to decide whether an arbitrary running program has ended.
        const peek = address => this.machine.peek(address);
        if (peek(0x2b) !== 1 || peek(0x2c) !== 8
            || peek(0x2d) !== 3 || peek(0x2e) !== 8) return;
        for (let address = 0x400; address <= 0x7e8 - BASIC_READY_CODES.length; address++) {
            if (!BASIC_READY_CODES.every((code, offset) => peek(address + offset) === code)) continue;
            this.basicReady = true;
            for (const waiter of this.bootWaiters.splice(0)) waiter.resolve();
            return;
        }
    }

    //
    // Start the emulator with optional audio
    //
    async start() {
        if (this.running) return;

        this.running = true;
        this.updateInputState();
        const generation = ++this.runGeneration;

        // Initialize audio if enabled
        if (this.audioEnabled) {
            await this.initAudio();
        }
        if (!this.running || generation !== this.runGeneration) return;

        this.lastTime = performance.now();
        this.timeAccumulator = 0;
        this.loop();
    }

    //
    // Initialize Web Audio API for sound output
    //
    async initAudio() {
        const generation = ++this.audioGeneration;
        try {
            this.audioContext = new (window.AudioContext || window.webkitAudioContext)({
                sampleRate: this.sampleRate
            });

            // The browser is free to ignore the requested rate (Safari always
            // uses the hardware rate), so resample the SID to whatever we got.
            if (this.audioContext.sampleRate !== this.sampleRate) {
                this.sampleRate = this.audioContext.sampleRate;
                this.machine.sampleRate = this.sampleRate;
                this.machine.sid.setSamplingParameters(
                    this.machine.clockFrequency,
                    SamplingMethod.DECIMATE,
                    this.sampleRate
                );
            }

            this.ringWrite = 0;
            this.ringRead = 0;
            this.audioRing.fill(0);

            // One frame's worth of samples, plus slack for rounding.
            const frameSamples = Math.ceil(this.sampleRate / 50) + 64;
            if (this.frameSamples.length < frameSamples) {
                this.frameSamples = new Int16Array(frameSamples);
            }

            // Create a ScriptProcessorNode for audio generation
            // Note: This is deprecated but widely supported. AudioWorklet requires more setup.
            const bufferSize = 2048;
            this.audioProcessor = this.audioContext.createScriptProcessor(bufferSize, 0, 1);

            this.audioProcessor.onaudioprocess = (event) => {
                this.drainAudio(event.outputBuffer.getChannelData(0));
            };

            this.audioProcessor.connect(this.audioContext.destination);
            // Modern browsers start the AudioContext in 'suspended' state until
            // explicitly resumed; enableAudio() is invoked from a user gesture
            // so this is allowed.
            if (this.audioContext.state === 'suspended') {
                await this.audioContext.resume();
            }
            return generation === this.audioGeneration;
        } catch (e) {
            if (generation !== this.audioGeneration) return false;
            console.warn('Failed to initialize audio:', e);
            this.audioEnabled = false;
            // Otherwise runFrame keeps queueing SID writes nothing will retire.
            this.machine.audioEnabled = false;
            this.teardownAudio();
            return false;
        }
    }

    //
    // Copy one emulated frame's SID output into the ring buffer.
    // Audio produced while the ring is full is dropped rather than allowed to
    // overwrite samples the audio thread has not played yet.
    // @private
    //
    pushFrameAudio() {
        const count = this.machine.audioSamplesGenerated;
        if (count <= 0) return;

        const free = AUDIO_RING_SIZE - (this.ringWrite - this.ringRead);
        const toCopy = Math.min(count, free);

        for (let i = 0; i < toCopy; i++) {
            this.audioRing[(this.ringWrite + i) & AUDIO_RING_MASK] = this.frameSamples[i] / 32768;
        }
        this.ringWrite += toCopy;

        // Keep latency bounded by discarding audio the listener has not reached
        // yet, rather than letting the backlog grow up to the ring size.
        const lead = this.ringWrite - this.ringRead;
        if (lead > AUDIO_MAX_LEAD) {
            this.ringRead = this.ringWrite - AUDIO_MAX_LEAD;
        }
    }

    //
    // Fill a Web Audio output block from the ring buffer.
    // On underrun the last sample is held rather than dropping to zero, which
    // would produce an audible click on every gap.
    // @private
    //
    drainAudio(output) {
        const available = this.ringWrite - this.ringRead;
        const toCopy = Math.min(output.length, available);

        for (let i = 0; i < toCopy; i++) {
            output[i] = this.audioRing[(this.ringRead + i) & AUDIO_RING_MASK];
        }
        this.ringRead += toCopy;

        if (toCopy > 0) {
            this.lastSample = output[toCopy - 1];
        }
        for (let i = toCopy; i < output.length; i++) {
            this.lastSample *= 0.995;  // decay towards silence
            output[i] = this.lastSample;
        }
    }

    stop() {
        this.running = false;
        this.runGeneration++;
        if (this.animationId !== null) {
            cancelAnimationFrame(this.animationId);
            this.animationId = null;
        }
        this.cancelTyping();
        this.releaseAllInput();
        for (const waiter of this.bootWaiters.splice(0)) {
            waiter.reject(new Error('Emulation stopped before BASIC was ready.'));
        }
        this.teardownAudio();
    }

    //
    // Disconnect and release the Web Audio graph
    // @private
    //
    teardownAudio() {
        this.audioGeneration++;
        if (this.audioProcessor) {
            this.audioProcessor.onaudioprocess = null;
            this.audioProcessor.disconnect();
            this.audioProcessor = null;
        }
        if (this.audioContext) {
            if (this.audioContext.state !== 'closed') {
                this.audioContext.close().catch(error => {
                    console.warn('Failed to close audio:', error);
                });
            }
            this.audioContext = null;
        }
        this.ringWrite = 0;
        this.ringRead = 0;
        this.lastSample = 0;
    }

    //
    // Pause emulator execution (for debug stepping)
    // The emulator loop keeps running but doesn't execute CPU cycles
    //
    pause() {
        this.paused = true;
        this.setGamepadButtons(new Set());
        this.releaseMouse();
        this.updateInputState();
        this.notifyStateChange();
    }

    //
    // Resume emulator execution after pausing
    //
    resume() {
        this.paused = false;
        this.updateInputState();
        this.notifyStateChange();
    }

    //
    // Check if emulator is paused
    //
    isPaused() {
        return this.paused;
    }

    //
    // Run frames as fast as the host allows instead of at 50Hz.
    //
    setTurbo(enabled) {
        this.turbo = !!enabled;
        this.timeAccumulator = 0;
        this.notifyStateChange();
    }

    //
    // Call listener(framesRun) after each display update that ran frames.
    // @returns {Function} Unsubscribe
    //
    onFrame(listener) {
        this.frameListeners.add(listener);
        return () => this.frameListeners.delete(listener);
    }

    //
    // Call listener(emulator) when pause or turbo changes.
    // @returns {Function} Unsubscribe
    //
    onStateChange(listener) {
        this.stateListeners.add(listener);
        return () => this.stateListeners.delete(listener);
    }

    // Input observers receive changes only; getInputState() supplies the initial state.
    onInputChange(listener) {
        this.inputListeners.add(listener);
        return () => this.inputListeners.delete(listener);
    }

    getInputState() {
        const captured = this.mouseEnabled && this.inputCaptured();
        let status = '1351 mouse input is off.';
        if (this.mouseEnabled) {
            if (this.paused) status = '1351 mouse on port 1. Resume the C64 to use it.';
            else if (!this.running) status = '1351 mouse on port 1. Start the C64 to use it.';
            else if (!captured) status = '1351 mouse on port 1. Click the C64 screen to use it.';
            else status = '1351 mouse active on port 1. Move and use the left or right button.';
        }
        return {
            gamepad: { enabled: this.gamepadEnabled, connection: this.gamepadConnection,
                status: this.gamepadStatus, name: this.gamepadName,
                hidAvailable: typeof navigator !== 'undefined' && typeof navigator.hid?.requestDevice === 'function',
                hidConnected: Boolean(this.gamepadHidInput?.connected),
                transport: this.gamepadTransport, ready: this.gamepadReady },
            mouse: { enabled: this.mouseEnabled, captured, status }
        };
    }

    notifyInputChange() {
        const state = this.getInputState();
        const key = JSON.stringify(state);
        if (key === this.inputStateKey) return;
        this.inputStateKey = key;
        for (const listener of this.inputListeners) listener(state);
    }

    inputCaptured() {
        return Boolean(this.keyboardEnabled && this.running && !this.paused &&
            !document.hidden && document.activeElement === this.canvas && document.hasFocus());
    }

    notifyStateChange() {
        for (const listener of this.stateListeners) listener(this);
    }

    //
    // Enable audio output (lazy initialization)
    // Called when user unmutes - audio will start when SID is written to
    //
    async enableAudio() {
        if (this.audioEnabled) return this.audioProcessor !== null;

        this.audioEnabled = true;
        this.machine.audioEnabled = true;
        return this.initAudio();
    }

    //
    // Disable audio output
    //
    disableAudio() {
        if (!this.audioEnabled) return; // Already disabled

        this.audioEnabled = false;
        this.machine.audioEnabled = false;
        this.teardownAudio();
    }

    bindMuteButton(button, statusElement) {
        this.statusElement = statusElement;
        const update = () => {
            button.textContent = this.audioEnabled ? '\u{1f50a} SOUND' : '\u{1f507} MUTED';
            button.classList.toggle('muted', !this.audioEnabled);
            button.setAttribute('aria-pressed', String(this.audioEnabled));
        };
        update();
        button.addEventListener('click', async () => {
            button.disabled = true;
            statusElement.textContent = '';
            try {
                if (this.audioEnabled) {
                    this.disableAudio();
                } else if (!await this.enableAudio()) {
                    statusElement.textContent = 'Sound could not start. Check your audio device and try again.';
                }
            } finally {
                update();
                button.disabled = false;
            }
        });
    }

    breakExecution() {
        this.cancelTyping();
        // Force a CPU break (emulates RUN/STOP key behavior in software)
        this.machine.pressStop();
    }

    loop() {
        if (!this.running) return;

        this.pollGamepad();

        const now = performance.now();
        let dt = now - this.lastTime;
        this.lastTime = now;

        // Cap dt to prevent spiral of death if tab is backgrounded
        if (dt > 100) dt = 100;

        // If paused (debug stepping mode), don't run frames but keep loop alive
        if (this.paused) {
            // Just render the current state and continue the loop
            this.render();
            this.animationId = requestAnimationFrame(() => this.loop());
            return;
        }

        let framesRun = 0;
        if (this.turbo || (this.fastBoot && !this.basicReady && !this.bootError)) {
            const deadline = now + TURBO_BUDGET_MS;
            do {
                this.runOneFrame();
                framesRun++;
            } while (framesRun < TURBO_MAX_FRAMES && performance.now() < deadline);
            this.timeAccumulator = 0;
        } else {
            this.timeAccumulator += dt;
            const frameTime = 1000 / PAL_FRAME_RATE;

            while (this.timeAccumulator >= frameTime) {
                this.runOneFrame();
                this.timeAccumulator -= frameTime;
                framesRun++;

                // Don't run too many frames in one go to keep UI responsive
                if (framesRun > 5) {
                    this.timeAccumulator = 0;
                    break;
                }
            }
        }

        // Render if we updated the state
        if (framesRun > 0) {
            this.render();
            for (const listener of this.frameListeners) {
                try {
                    listener(framesRun);
                } catch (error) {
                    console.error('Frame listener failed:', error);
                }
            }
        }

        // Every deferred key has now been held through a full frame, so the
        // KERNAL's scan has had a chance to see it.
        if (framesRun > 0 && this.pendingReleases.length > 0) {
            const released = this.pendingReleases.splice(0);
            for (const held of released) {
                this.updateMatrixKey(held.row, held.col);
            }
            this.updateShiftKey();
        }
        if (framesRun > 0 && this.pendingJoystickReleases.length > 0) {
            const released = this.pendingJoystickReleases.splice(0);
            for (const held of released) this.updateJoystickKey(held.key);
        }

        this.animationId = requestAnimationFrame(() => this.loop());
    }

    //
    // Run one emulated frame, feeding its SID output to Web Audio when sound
    // is on. Nothing else may clock the SID (see machine.runFrame).
    // @private
    //
    runOneFrame() {
        this.flushMouseMovement();
        if (this.audioEnabled && this.audioProcessor) {
            this.machine.runFrame(this.frameSamples);
            this.pushFrameAudio();
        } else {
            this.machine.runFrame();
        }
        this.frame++;
        this.checkBasicReady();
    }

    render() {
        this.vicRenderer.render(this.ctx, this.machine.vic);
    }

    enableKeyboard() {
        if (this.keyboardEnabled) return;
        this.keyboardEnabled = true;
        document.addEventListener('keydown', event => this.handleKeyPress(event));
        document.addEventListener('keyup', event => this.handleKeyRelease(event));
        this.canvas.addEventListener('blur', () => this.releaseAllInput());
        window.addEventListener('blur', () => this.releaseAllInput());
        this.canvas.addEventListener('focus', () => this.pollGamepad());
        window.addEventListener('focus', () => this.pollGamepad());
        document.addEventListener('visibilitychange', () => {
            if (document.hidden) this.releaseAllInput();
            else this.pollGamepad();
        });
        this.canvas.addEventListener('pointermove', event => this.handleMouseMove(event));
        this.canvas.addEventListener('pointerdown', event => this.handleMousePress(event));
        window.addEventListener('pointerup', event => this.handleMouseRelease(event), true);
        window.addEventListener('pointermove', event => {
            if (event.pointerType === 'mouse' && typeof event.buttons === 'number') {
                this.releaseMissingMouseButtons(event.buttons);
            }
        }, true);
        window.addEventListener('pointercancel', event => {
            if (event.pointerType === 'mouse') this.releaseMouse();
        }, true);
        this.canvas.addEventListener('contextmenu', event => {
            if (this.mouseEnabled && this.inputCaptured()) event.preventDefault();
        });
        this.updateInputState();
    }

    handleKeyPress(e) {
        if (e.defaultPrevented || e.isComposing || e.metaKey) return;
        if (e.target !== this.canvas && e.target?.closest(
            'input, textarea, select, button, a, [contenteditable]:not([contenteditable="false"])'
        )) return;
        // Ctrl+V stays a browser paste, which the page types into the C64.
        if (e.ctrlKey && (e.key === 'v' || e.key === 'V')) return;

        // event.key can change between keydown and keyup when Shift is released.
        const keyId = e.code || e.key;
        // If joystick mode is active, handle arrow keys and space as joystick
        if (this.activeJoystick > 0) {
            const k = e.key;
            if (k === 'ArrowUp' || k === 'ArrowDown' || k === 'ArrowLeft' || k === 'ArrowRight' || k === ' ') {
                if (!this.heldJoystickKeys.has(keyId)) {
                    this.heldJoystickKeys.set(keyId, { key: k, frame: this.frame });
                }
                this.handleJoystickKey(k, true);
                e.preventDefault();
                return;
            }
        }

        if (e.key === 'Shift') {
            this.heldShiftKeys.add(keyId);
            this.physicalShift = true;
            this.updateShiftKey();
            e.preventDefault();
            return;
        }

        const mapped = lookupKey(e.key);
        if (!mapped) return;
        e.preventDefault();

        // The OS repeats keydown while a key is held. Ignore the repeats: the
        // C64's own repeat comes from the KERNAL scanning the held matrix, and
        // re-recording the press would keep pushing the release frame forward.
        if (this.heldKeys.has(keyId)) return;

        this.heldKeys.set(keyId, { ...mapped, frame: this.frame });
        this.machine.setKey(mapped.row, mapped.col, true);
        this.updateShiftKey();
    }

    //
    // Handle key release events
    //
    handleKeyRelease(e) {
        const keyId = e.code || e.key;
        const joystickKey = this.heldJoystickKeys.get(keyId);
        if (joystickKey) {
            this.heldJoystickKeys.delete(keyId);
            if (joystickKey.frame === this.frame) {
                this.pendingJoystickReleases.push(joystickKey);
            } else {
                this.updateJoystickKey(joystickKey.key);
            }
            e.preventDefault();
            return;
        }

        if (this.heldShiftKeys.delete(keyId)) {
            this.physicalShift = this.heldShiftKeys.size > 0;
            this.updateShiftKey();
            e.preventDefault();
            return;
        }

        const held = this.heldKeys.get(keyId);
        if (!held) return;
        this.heldKeys.delete(keyId);
        e.preventDefault();

        // The KERNAL only scans the matrix once per frame. A keypress that both
        // starts and ends inside the same frame would never be seen, so defer
        // its release until at least one frame has run with the key down.
        if (held.frame === this.frame) {
            this.pendingReleases.push(held);
        } else {
            this.updateMatrixKey(held.row, held.col);
        }
        this.updateShiftKey();
    }

    updateMatrixKey(row, col) {
        const down = [...this.heldKeys.values(), ...this.pendingReleases]
            .some(held => held.row === row && held.col === col);
        this.machine.setKey(row, col, down);
    }

    //
    // Drive the C64's SHIFT key. A held key can demand SHIFT (C64 shifted
    // punctuation), forbid it (a C64 unshifted key the PC can only reach with
    // shift, like `*`), or defer to whatever the user is physically holding.
    // Keys awaiting a deferred release still count, so SHIFT cannot drop before
    // the KERNAL has scanned them.
    // @private
    //
    updateShiftKey() {
        let required = null;
        for (const held of [...this.heldKeys.values(), ...this.pendingReleases]) {
            if (held.shift === 'on') { required = true; break; }
            if (held.shift === 'off') required = false;
        }
        const down = required === null ? this.physicalShift : required;
        this.machine.setKey(SHIFT_KEY[0], SHIFT_KEY[1], down);
    }

    //
    // Release every held key. Called when the page loses focus so that keys
    // held during an alt-tab do not stay down in the emulated machine.
    //
    releaseAllKeys() {
        this.machine.releaseAllKeys();
        this.heldKeys.clear();
        this.heldShiftKeys.clear();
        this.heldJoystickKeys.clear();
        this.pendingJoystickReleases.length = 0;
        this.gamepadState.clear();
        this.pendingReleases.length = 0;
        this.physicalShift = false;
        if (this.activeJoystick > 0) {
            for (const button of Object.keys(this.joystickState)) {
                this.joystickState[button] = false;
                this.machine.setJoystickButton(this.activeJoystick, button, false);
            }
        }
    }

    //
    // Handle a joystick key press/release
    // @param {string} key - Key name ('ArrowUp', 'ArrowDown', etc. or ' ')
    // @param {boolean} pressed - True if pressed, false if released
    //
    handleJoystickKey(key, pressed) {
        let button = null;
        switch (key) {
            case 'ArrowUp': button = 'up'; break;
            case 'ArrowDown': button = 'down'; break;
            case 'ArrowLeft': button = 'left'; break;
            case 'ArrowRight': button = 'right'; break;
            case ' ': button = 'fire'; break;
        }
        if (button) {
            this.joystickState[button] = pressed;
            this.syncJoystickButton(button);
        }
    }

    syncJoystickButton(button) {
        if (this.activeJoystick > 0) {
            this.machine.setJoystickButton(this.activeJoystick, button,
                this.joystickState[button] || this.gamepadState.has(button));
        }
    }

    setGamepadButtons(buttons) {
        const changed = new Set([...this.gamepadState, ...buttons]);
        const previous = this.gamepadState;
        this.gamepadState = buttons;
        for (const button of changed) {
            if (previous.has(button) !== buttons.has(button)) this.syncJoystickButton(button);
        }
    }

    startGamepadDiscovery() {
        if (!this.gamepadDiscoveryStarted) {
            this.gamepadDiscoveryStarted = true;
            window.addEventListener('gamepadconnected', () => this.pollGamepad());
            window.addEventListener('gamepaddisconnected', () => this.pollGamepad());
        }
        this.pollGamepad();
    }

    setGamepadEnabled(enabled) {
        enabled = Boolean(enabled);
        if (enabled && !this.activeJoystick) this.setActiveJoystick(2);
        this.gamepadEnabled = enabled;
        if (enabled) this.startGamepadDiscovery();
        else this.pollGamepad();
    }

    async connectGamepadHid() {
        this.startGamepadDiscovery();
        if (!this.gamepadHidInput) {
            this.gamepadHidInput = new HidGamepadInput(() => this.pollGamepad());
        }
        try {
            return await this.gamepadHidInput.connect();
        } finally {
            this.pollGamepad();
        }
    }

    async disconnectGamepadHid() {
        if (!this.gamepadHidInput) return;
        try {
            await this.gamepadHidInput.disconnect();
        } finally {
            this.pollGamepad();
        }
    }

    // Observe connection after the first opt-in, independently of capture.
    // Poll once per display update, including while paused.
    pollGamepad() {
        let pads = [];
        let available = typeof navigator !== 'undefined' && typeof navigator.getGamepads === 'function';
        if (this.gamepadDiscoveryStarted && available) {
            try {
                pads = Array.from(navigator.getGamepads());
            } catch {
                available = false;
            }
        }
        const connected = pads.find(candidate => candidate?.connected);
        const nativePad = pads.find(candidate => candidate?.connected && candidate.mapping === 'standard');
        const hidConnected = Boolean(this.gamepadHidInput?.connected);
        const pad = nativePad ?? (hidConnected ? this.gamepadHidInput.gamepad : null);
        this.gamepadDevice = pad ?? null;
        this.gamepadTransport = nativePad ? 'gamepad' : hidConnected ? 'hid' : null;
        this.gamepadReady = Boolean(nativePad || (hidConnected && this.gamepadHidInput.ready));
        this.gamepadAvailable = available;
        this.gamepadName = (pad ?? connected)?.id ?? '';
        const buttons = new Set();
        if (this.gamepadEnabled && pad && this.gamepadReady && this.inputCaptured() && this.activeJoystick > 0) {
            const held = index => pad.buttons[index]?.pressed;
            const x = pad.axes[0] ?? 0, y = pad.axes[1] ?? 0;
            if (x < -GAMEPAD_DEAD_ZONE || held(14)) buttons.add('left');
            if (x > GAMEPAD_DEAD_ZONE || held(15)) buttons.add('right');
            if (y < -GAMEPAD_DEAD_ZONE || held(12)) buttons.add('up');
            if (y > GAMEPAD_DEAD_ZONE || held(13)) buttons.add('down');
            if ([0, 1, 2, 3].some(held)) buttons.add('fire');
        }
        this.setGamepadButtons(buttons);
        if (!this.inputCaptured()) this.releaseMouse();
        this.gamepadUnmapped = Boolean(connected) && !pad;
        this.updateInputState();
    }

    updateInputState() {
        let connection, message;
        if (!this.gamepadDiscoveryStarted) {
            connection = 'off';
            message = 'Gamepad capture is off.';
        } else if (!this.gamepadAvailable && !this.gamepadDevice) {
            connection = 'unavailable';
            message = 'Gamepad controls are unavailable in this browser.';
        } else if (!this.gamepadDevice) {
            connection = this.gamepadUnmapped ? 'unsupported' : 'waiting';
            message = this.gamepadUnmapped
                ? 'This controller has no standard mapping. Use a standard gamepad.'
                : 'Waiting for a controller. Press a face button so this browser can detect it.';
        } else {
            connection = this.gamepadEnabled && this.gamepadReady && this.inputCaptured() && this.activeJoystick ? 'active' : 'connected';
            if (!this.gamepadReady) {
                message = 'Controller connection open. Waiting for controller input.';
                if (!this.gamepadEnabled) message += ' Capture is off.';
            } else if (!this.gamepadEnabled) message = 'Controller connected. Capture is off.';
            else if (!this.activeJoystick) message = 'Gamepad connected. Joystick mode is off.';
            else if (this.paused) message = 'Gamepad connected. Resume to play.';
            else if (!this.running) message = 'Gamepad connected. Start the C64 to play.';
            else if (!this.inputCaptured()) message = 'Gamepad connected. Click the C64 screen to play.';
            else {
                const controls = this.gamepadTransport === 'hid'
                    ? 'D-pad or stick moves; the first four buttons fire.'
                    : 'D-pad or left stick moves; any face button fires.';
                message = `Gamepad active on joystick ${this.activeJoystick}. ${controls}`;
            }
        }
        this.gamepadConnection = connection;
        this.gamepadStatus = message;
        this.notifyInputChange();
    }

    setMouseEnabled(enabled) {
        enabled = Boolean(enabled);
        if (enabled !== this.mouseEnabled) {
            this.releaseMouse();
            this.mouseEnabled = enabled;
            this.machine.setMouseEnabled(enabled);
        }
        this.updateInputState();
    }

    releaseMouse() {
        this.mouseDeltaX = this.mouseDeltaY = 0;
        for (const button of this.mouseButtons) this.machine.setMouseButton(button, false);
        this.mouseButtons.clear();
    }

    releaseAllInput() {
        this.releaseAllKeys();
        this.releaseMouse();
        this.updateInputState();
    }

    handleMouseMove(event) {
        if (event.pointerType !== 'mouse' || !this.mouseEnabled || !this.inputCaptured()) return;
        const rect = this.canvas.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return;
        const dx = event.movementX * 384 / rect.width;
        const dy = event.movementY * 272 / rect.height;
        if (!Number.isFinite(dx) || !Number.isFinite(dy)) return;
        this.mouseDeltaX += dx;
        this.mouseDeltaY += dy;
        // A second mouse button in a chord changes buttons through pointermove,
        // rather than delivering another pointerdown.
        if (typeof event.buttons === 'number') {
            this.setMouseButton('left', Boolean(event.buttons & 1));
            this.setMouseButton('right', Boolean(event.buttons & 2));
        }
    }

    setMouseButton(button, pressed) {
        if (this.mouseButtons.has(button) === pressed) return;
        if (pressed) this.mouseButtons.add(button);
        else this.mouseButtons.delete(button);
        this.machine.setMouseButton(button, pressed);
    }

    handleMousePress(event) {
        if (event.pointerType !== 'mouse' || !this.mouseEnabled || !this.inputCaptured()) return;
        const button = event.button === 0 ? 'left' : event.button === 2 ? 'right' : null;
        if (!button) return;
        this.setMouseButton(button, true);
        event.preventDefault();
    }

    releaseMissingMouseButtons(buttons) {
        let released = false;
        for (const button of this.mouseButtons) {
            const mask = button === 'left' ? 1 : 2;
            if (!(buttons & mask)) {
                this.setMouseButton(button, false);
                released = true;
            }
        }
        return released;
    }

    handleMouseRelease(event) {
        if (event.pointerType !== 'mouse') return;
        // The final button can have been pressed outside the canvas. Its up
        // still proves that every button captured earlier is now released.
        if (event.buttons === 0) {
            if (this.releaseMissingMouseButtons(0)) event.preventDefault();
            return;
        }
        const button = event.button === 0 ? 'left' : event.button === 2 ? 'right' : null;
        if (!this.mouseButtons.has(button)) return;
        this.setMouseButton(button, false);
        event.preventDefault();
    }

    flushMouseMovement() {
        if (!this.mouseEnabled || !this.inputCaptured()) {
            this.releaseMouse();
            return;
        }
        // Bound a burst between emulated frames to keep six-bit deltas unambiguous.
        // Keep subpixel motion, but never replay a large stale movement later.
        const dx = Math.max(-MOUSE_FRAME_DELTA, Math.min(MOUSE_FRAME_DELTA, Math.trunc(this.mouseDeltaX)));
        const dy = Math.max(-MOUSE_FRAME_DELTA, Math.min(MOUSE_FRAME_DELTA, Math.trunc(this.mouseDeltaY)));
        this.mouseDeltaX %= 1;
        this.mouseDeltaY %= 1;
        if (dx || dy) this.machine.moveMouse(dx, dy);
    }

    updateJoystickKey(key) {
        const down = [...this.heldJoystickKeys.values(), ...this.pendingJoystickReleases]
            .some(held => held.key === key);
        this.handleJoystickKey(key, down);
    }

    //
    // Enable joystick mode (arrow keys + space control joystick)
    // @param {number} port - Joystick port (1 or 2), or 0 to disable
    //
    setActiveJoystick(port) {
        if (port === this.activeJoystick) return;
        this.releaseAllKeys();
        this.activeJoystick = port;
        this.updateInputState();
    }

    //
    // Toggle joystick mode for a specific port
    // @param {number} port - Joystick port (1 or 2)
    // @returns {boolean} True if joystick is now active, false if disabled
    //
    toggleJoystick(port) {
        if (this.activeJoystick === port) {
            this.setActiveJoystick(0);
            return false;
        } else {
            this.setActiveJoystick(port);
            return true;
        }
    }

    //
    // Type text into the machine programmatically.
    //
    // This injects PETSCII straight into the KERNAL keyboard buffer rather than
    // going through the matrix, so it cannot collide with keys the user is
    // physically holding and needs no press/release timing.
    //
    typeText(t, { lineDelay = 70 } = {}) {
        for (const ch of t) {
            if (ch === '\r') continue;  // CR/LF pairs are handled by the LF
            const code = ch === '\n' ? 13 : petsciiForTyping(ch);
            if (code === null) continue;
            this.typingQueue.push({ code, delay: ch === '\n' ? lineDelay : 30 });
        }
        if (this.typingTimer !== null || this.typingQueue.length === 0) return;
        const typeNext = () => {
            this.typingTimer = null;
            if (this.typingQueue.length === 0) return;
            // A busy C64 (storing a long line, running a command) stops
            // emptying the buffer; wait for room rather than drop keys.
            if (this.machine.ram[0xC6] >= KEYBOARD_BUFFER_SIZE) {
                this.typingTimer = setTimeout(typeNext, 20);
                return;
            }
            const next = this.typingQueue.shift();
            this.machine.addKey(next.code);
            this.typingTimer = setTimeout(typeNext, next.delay);
        };
        this.typingTimer = setTimeout(typeNext, 0);
    }

    cancelTyping() {
        if (this.typingTimer !== null) clearTimeout(this.typingTimer);
        this.typingTimer = null;
        this.typingQueue.length = 0;
    }

    snapshot() {
        return {
            ram: Array.from(this.machine.ram),
            cpu: {
                A: this.machine.cpu.A,
                X: this.machine.cpu.X,
                Y: this.machine.cpu.Y,
                SP: this.machine.cpu.SP,
                PC: this.machine.cpu.PC,
                P: this.machine.cpu.P
            },
            frame: this.frame
        };
    }

    restore(state) {
        if (!state || !state.ram || !state.cpu) return;
        try {
            const r = state.ram;
            if (r.length === 65536) {
                this.machine.ram.set(r);
            }
            // Handle both old and new property names
            this.machine.cpu.A = state.cpu.A ?? state.cpu.a ?? 0;
            this.machine.cpu.X = state.cpu.X ?? state.cpu.x ?? 0;
            this.machine.cpu.Y = state.cpu.Y ?? state.cpu.y ?? 0;
            this.machine.cpu.SP = state.cpu.SP ?? state.cpu.sp ?? 0xff;
            this.machine.cpu.PC = state.cpu.PC ?? state.cpu.pc ?? 0;
            this.machine.cpu.P = state.cpu.P ?? state.cpu.status ?? 0x24;
            this.frame = state.frame || 0;
        } catch (e) {
            console.warn('Failed to restore C64 state', e);
        }
    }

    //
    // Enable drag-and-drop of PRG files onto the emulator canvas
    //
    // PRG files are loaded after startup; CRT files reset into the cartridge.
    //
    enableDragAndDrop() {
        const canvas = this.canvas;

        // Prevent default drag behaviors
        canvas.addEventListener('dragover', (e) => {
            e.preventDefault();
            e.stopPropagation();
            canvas.classList.add('drag-over');
        });

        canvas.addEventListener('dragleave', (e) => {
            e.preventDefault();
            e.stopPropagation();
            canvas.classList.remove('drag-over');
        });

        canvas.addEventListener('drop', async (e) => {
            e.preventDefault();
            e.stopPropagation();
            canvas.classList.remove('drag-over');

            const files = e.dataTransfer.files;
            if (files.length === 0) return;

            const file = files[0];
            const name = file.name.toLowerCase();

            try {
                if (!name.endsWith('.prg') && !name.endsWith('.crt')) {
                    throw new Error('Unsupported file type. Choose a .prg or .crt file.');
                }
                const arrayBuffer = await file.arrayBuffer();
                const data = new Uint8Array(arrayBuffer);

                let message = `Loaded ${file.name}.`;
                if (name.endsWith('.prg')) {
                    const program = await this.loadPrgFile(data, file.name);
                    message = program.basic
                        ? `Loaded ${file.name} and typed RUN.`
                        : `Loaded ${file.name} at $${program.loadAddress.toString(16).toUpperCase()}. ` +
                          `Type SYS ${program.loadAddress} to start it.`;
                } else {
                    this.loadCrtFile(data, file.name);
                }
                if (this.statusElement) this.statusElement.textContent = message;
            } catch (err) {
                console.error('Failed to load file:', err);
                if (this.statusElement) this.statusElement.textContent = `Could not load file: ${err.message}`;
            }
        });
    }

    //
    // Load a PRG file into memory
    //
    // A BASIC program (loaded at the start of BASIC text) is RUN, as an
    // autostarting emulator would; machine code is left for the user to SYS.
    //
    // @param {Uint8Array} data - The PRG file data (with 2-byte load address header)
    // @param {string} [filename] - Optional filename for logging
    // @returns {Promise<{loadAddress: number, endAddress: number, basic: boolean}>}
    //
    async loadPrgFile(data, filename = 'program.prg') {
        if (data.length < 3) {
            throw new Error('PRG file must contain a load address and program data.');
        }
        const generation = this.bootGeneration;
        await this.whenBasicReady();
        if (generation !== this.bootGeneration) throw new Error('Program loading was interrupted by reset.');

        const program = this.machine.loadProgram(data);
        const hex = value => '$' + value.toString(16).padStart(4, '0');
        console.log(`Loaded ${filename}: ${hex(program.loadAddress)}-${hex(program.endAddress - 1)} (${data.length - 2} bytes)`);

        if (program.basic) {
            // "RUN" and RETURN fit the 10-key KERNAL buffer, so no timed typing is needed.
            this.cancelTyping();
            for (const ch of 'RUN\r') this.machine.addKey(ch.charCodeAt(0));
        }
        return program;
    }

    //
    // Load a CRT cartridge file and reset the machine
    //
    // @param {Uint8Array} data - The CRT file data
    // @param {string} [filename] - Optional filename for logging
    //
    loadCrtFile(data, filename = 'cartridge.crt') {
        this.machine.loadCrt(data);
        this.reset({ keepCartridge: true });
    }
}

// Session persistence helpers
if (typeof window !== 'undefined') {
    function saveState() {
        if (window.c64Emu && typeof window.c64Emu.snapshot === 'function') {
            try {
                const snap = window.c64Emu.snapshot();
                sessionStorage.setItem('c64State', JSON.stringify(snap));
            } catch (e) {
                // ignore
            }
        }
    }
    window.addEventListener('beforeunload', saveState);
    window.addEventListener('pagehide', saveState);
}