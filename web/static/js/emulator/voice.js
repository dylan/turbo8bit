//
// @fileoverview SID Voice Components - Waveform and Envelope Generators
// @module emulator/voice
//
// This module provides the building blocks for SID voice emulation.
// Inspired by libsidplayfp.
//
// Components:
// - WaveformCalculator: Pre-calculates waveform lookup tables for combined waveforms
// - WaveformGenerator: 24-bit accumulator-based waveform generation (tri, saw, pulse, noise)
// - EnvelopeGenerator: ADSR envelope with 15-bit LFSR timing
// - Voice: Combines waveform and envelope generators into a complete voice
//
// Each SID chip has 3 identical voices. Voice features include:
// - 16-bit frequency control (0-4095 Hz range)
// - 12-bit pulse width for pulse waveform
// - Waveform selection (triangle, sawtooth, pulse, noise, or combinations)
// - Ring modulation with previous voice
// - Oscillator sync with previous voice
//
// For main SID chip, see sid.js.
// For filter emulation, see filter.js.
//
// @see https://www.turbo8bit.com/
//

// ============================================================================
// WAVEFORM CALCULATOR
// ============================================================================

//
// Combined waveform model parameters
// Derived from Monte Carlo analysis of real chip samples
//
const CONFIG_AVERAGE = [
    // 6581 parameters
    [
        { distFunc: 'exponential', threshold: 0.877322257, topbit: 1.11349654, pulsestrength: 0, distance1: 2.14537621, distance2: 9.08618164 },
        { distFunc: 'linear', threshold: 0.941692829, topbit: 1, pulsestrength: 1.80072665, distance1: 0.033124879, distance2: 0.232303441 },
        { distFunc: 'linear', threshold: 1.66494179, topbit: 1.03760982, pulsestrength: 5.62705326, distance1: 0.291590303, distance2: 0.283631504 },
        { distFunc: 'linear', threshold: 1.09762526, topbit: 0.975265801, pulsestrength: 1.52196741, distance1: 0.151528224, distance2: 0.841949463 },
        { distFunc: 'exponential', threshold: 0.96, topbit: 1, pulsestrength: 2.5, distance1: 1.1, distance2: 1.2 },
    ],
    // 8580 parameters
    [
        { distFunc: 'exponential', threshold: 0.853578329, topbit: 1.09615636, pulsestrength: 0, distance1: 1.8819375, distance2: 6.80794907 },
        { distFunc: 'exponential', threshold: 0.929835618, topbit: 1, pulsestrength: 1.12836814, distance1: 1.10453653, distance2: 1.48065746 },
        { distFunc: 'quadratic', threshold: 0.911938608, topbit: 0.996440411, pulsestrength: 1.2278074, distance1: 0.000117214302, distance2: 0.18948476 },
        { distFunc: 'exponential', threshold: 0.938004673, topbit: 1.04827631, pulsestrength: 1.21178246, distance1: 0.915959001, distance2: 1.42698038 },
        { distFunc: 'exponential', threshold: 0.95, topbit: 1, pulsestrength: 1.15, distance1: 1, distance2: 1.45 },
    ],
];

const DISTANCE_FUNCTIONS = {
    exponential: (distance, i) => Math.pow(distance, -i),
    linear: (distance, i) => 1 / (1 + i * distance),
    quadratic: (distance, i) => 1 / (1 + (i * i) * distance),
};

function triXor(val) {
    return (((val & 0x800) === 0) ? val : (val ^ 0xfff)) << 1;
}

function calculatePulldown(distanceTable, topbit, pulsestrength, threshold, accumulator) {
    const bit = new Float32Array(12);
    for (let i = 0; i < 12; i++) {
        bit[i] = (accumulator & (1 << i)) !== 0 ? 1 : 0;
    }
    bit[11] *= topbit;

    const pulldown = new Float32Array(12);
    for (let sb = 0; sb < 12; sb++) {
        let avg = 0, n = 0;
        for (let cb = 0; cb < 12; cb++) {
            if (cb === sb) continue;
            const weight = distanceTable[sb - cb + 12];
            avg += (1 - bit[cb]) * weight;
            n += weight;
        }
        avg -= pulsestrength;
        pulldown[sb] = avg / n;
    }

    let value = 0;
    for (let i = 0; i < 12; i++) {
        const bitValue = bit[i] > 0 ? 1 - pulldown[i] : 0;
        if (bitValue > threshold) {
            value |= 1 << i;
        }
    }
    return value;
}

class WaveformCalculator {
    constructor() {
        this.wftable = [
            new Int16Array(4096),
            new Int16Array(4096),
            new Int16Array(4096),
            new Int16Array(4096),
        ];

        for (let idx = 0; idx < 4096; idx++) {
            const saw = idx;
            const tri = triXor(idx);
            this.wftable[0][idx] = 0xfff;
            this.wftable[1][idx] = tri;
            this.wftable[2][idx] = saw;
            this.wftable[3][idx] = saw & (saw << 1);
        }

        this.pulldownCache = new Map();
    }

    getWaveTable() {
        return this.wftable;
    }

    buildPulldownTable(model, cws = 'AVERAGE') {
        const cacheKey = `${model}_${cws}`;
        if (this.pulldownCache.has(cacheKey)) {
            return this.pulldownCache.get(cacheKey);
        }

        const modelIdx = model === 'MOS6581' ? 0 : 1;
        const config = CONFIG_AVERAGE[modelIdx];
        const pulldownTables = [];

        for (let wf = 0; wf < 5; wf++) {
            const cfg = config[wf];
            const distFunc = DISTANCE_FUNCTIONS[cfg.distFunc];

            const distanceTable = new Float32Array(25);
            for (let i = 0; i < 25; i++) {
                const dist = i < 12 ? cfg.distance1 : cfg.distance2;
                distanceTable[i] = distFunc(dist, Math.abs(i - 12));
            }

            const pulldownTable = new Int16Array(4096);
            for (let idx = 0; idx < 4096; idx++) {
                pulldownTable[idx] = calculatePulldown(
                    distanceTable, cfg.topbit, cfg.pulsestrength, cfg.threshold, idx
                );
            }
            pulldownTables.push(pulldownTable);
        }

        this.pulldownCache.set(cacheKey, pulldownTables);
        return pulldownTables;
    }
}

let waveformCalculatorInstance = null;

export function getWaveformCalculator() {
    if (!waveformCalculatorInstance) {
        waveformCalculatorInstance = new WaveformCalculator();
    }
    return waveformCalculatorInstance;
}

// ============================================================================
// ENVELOPE GENERATOR
// ============================================================================

const EnvelopeState = {
    ATTACK: 0,
    DECAY_SUSTAIN: 1,
    RELEASE: 2
};

const ADSR_TABLE = new Uint16Array([
    0x007f, 0x3000, 0x1e00, 0x0660, 0x0182, 0x5573, 0x000e, 0x3805,
    0x2424, 0x2220, 0x090c, 0x0ecd, 0x010e, 0x23f7, 0x5237, 0x64a8
]);

export class EnvelopeGenerator {
    constructor() {
        this.lfsr = 0x7fff;
        this.rate = 0;
        this.exponentialCounter = 0;
        this.exponentialCounterPeriod = 1;
        this.newExponentialCounterPeriod = 0;
        this.statePipeline = 0;
        this.envelopePipeline = 0;
        this.exponentialPipeline = 0;
        this.state = EnvelopeState.RELEASE;
        this.nextState = EnvelopeState.RELEASE;
        this.counterEnabled = true;
        this.gate = false;
        this.resetLfsr = false;
        this.envelopeCounter = 0xaa;
        this.attack = 0;
        this.decay = 0;
        this.sustain = 0;
        this.release = 0;
        this.env3 = 0;
    }

    reset() {
        this.envelopePipeline = 0;
        this.statePipeline = 0;
        this.attack = 0;
        this.decay = 0;
        this.sustain = 0;
        this.release = 0;
        this.gate = false;
        this.resetLfsr = true;
        this.exponentialCounter = 0;
        this.exponentialCounterPeriod = 1;
        this.newExponentialCounterPeriod = 0;
        this.state = EnvelopeState.RELEASE;
        this.counterEnabled = false;
        this.rate = ADSR_TABLE[this.release];
        this.envelopeCounter = 0;
    }

    clock() {
        this.env3 = this.envelopeCounter;

        if (this.newExponentialCounterPeriod > 0) {
            this.exponentialCounterPeriod = this.newExponentialCounterPeriod;
            this.newExponentialCounterPeriod = 0;
        }

        if (this.statePipeline) {
            this.stateChange();
        }

        if (this.envelopePipeline !== 0 && (--this.envelopePipeline === 0)) {
            if (this.counterEnabled) {
                // The counter is 8 bits wide. Gate changes timed against a
                // step flip it 0xff->0x00 or 0x00->0xff (the "ADSR bug"),
                // and some players rely on that; unwrapped it runs away.
                if (this.state === EnvelopeState.ATTACK) {
                    this.envelopeCounter = (this.envelopeCounter + 1) & 0xff;
                    if (this.envelopeCounter === 0xff) {
                        this.nextState = EnvelopeState.DECAY_SUSTAIN;
                        this.statePipeline = 3;
                    }
                } else if (this.state === EnvelopeState.DECAY_SUSTAIN || this.state === EnvelopeState.RELEASE) {
                    this.envelopeCounter = (this.envelopeCounter - 1) & 0xff;
                    if (this.envelopeCounter === 0x00) {
                        this.counterEnabled = false;
                    }
                }
                this.setExponentialCounter();
            }
        } else if (this.exponentialPipeline !== 0 && (--this.exponentialPipeline === 0)) {
            this.exponentialCounter = 0;
            if ((this.state === EnvelopeState.DECAY_SUSTAIN && this.envelopeCounter !== this.sustain) ||
                this.state === EnvelopeState.RELEASE) {
                this.envelopePipeline = 1;
            }
        } else if (this.resetLfsr) {
            this.lfsr = 0x7fff;
            this.resetLfsr = false;
            if (this.state === EnvelopeState.ATTACK) {
                this.exponentialCounter = 0;
                this.envelopePipeline = 2;
            } else {
                if (this.counterEnabled && (++this.exponentialCounter === this.exponentialCounterPeriod)) {
                    this.exponentialPipeline = this.exponentialCounterPeriod !== 1 ? 2 : 1;
                }
            }
        }

        if (this.lfsr !== this.rate) {
            const feedback = ((this.lfsr << 14) ^ (this.lfsr << 13)) & 0x4000;
            this.lfsr = ((this.lfsr >> 1) | feedback) & 0x7fff;
        } else {
            this.resetLfsr = true;
        }
    }

    stateChange() {
        this.statePipeline--;
        switch (this.nextState) {
            case EnvelopeState.ATTACK:
                if (this.statePipeline === 1) {
                    this.rate = ADSR_TABLE[this.decay];
                } else if (this.statePipeline === 0) {
                    this.state = EnvelopeState.ATTACK;
                    this.rate = ADSR_TABLE[this.attack];
                    this.counterEnabled = true;
                }
                break;
            case EnvelopeState.DECAY_SUSTAIN:
                if (this.statePipeline === 0) {
                    this.state = EnvelopeState.DECAY_SUSTAIN;
                    this.rate = ADSR_TABLE[this.decay];
                }
                break;
            case EnvelopeState.RELEASE:
                if ((this.state === EnvelopeState.ATTACK && this.statePipeline === 0) ||
                    (this.state === EnvelopeState.DECAY_SUSTAIN && this.statePipeline === 1)) {
                    this.state = EnvelopeState.RELEASE;
                    this.rate = ADSR_TABLE[this.release];
                }
                break;
        }
    }

    setExponentialCounter() {
        switch (this.envelopeCounter) {
            case 0xff: case 0x00: this.newExponentialCounterPeriod = 1; break;
            case 0x5d: this.newExponentialCounterPeriod = 2; break;
            case 0x36: this.newExponentialCounterPeriod = 4; break;
            case 0x1a: this.newExponentialCounterPeriod = 8; break;
            case 0x0e: this.newExponentialCounterPeriod = 16; break;
            case 0x06: this.newExponentialCounterPeriod = 30; break;
        }
    }

    output() { return this.envelopeCounter; }
    readENV() { return this.env3; }

    writeCONTROL_REG(control) {
        const gateNext = (control & 0x01) !== 0;
        if (gateNext !== this.gate) {
            this.gate = gateNext;
            if (gateNext) {
                this.nextState = EnvelopeState.ATTACK;
                this.statePipeline = 2;
                if (this.resetLfsr || this.exponentialPipeline === 2) {
                    this.envelopePipeline = (this.exponentialCounterPeriod === 1 || this.exponentialPipeline === 2) ? 2 : 4;
                } else if (this.exponentialPipeline === 1) {
                    this.statePipeline = 3;
                }
            } else {
                this.nextState = EnvelopeState.RELEASE;
                this.statePipeline = this.envelopePipeline > 0 ? 3 : 2;
            }
        }
    }

    writeATTACK_DECAY(attackDecay) {
        this.attack = (attackDecay >> 4) & 0x0f;
        this.decay = attackDecay & 0x0f;
        if (this.state === EnvelopeState.ATTACK) {
            this.rate = ADSR_TABLE[this.attack];
        } else if (this.state === EnvelopeState.DECAY_SUSTAIN) {
            this.rate = ADSR_TABLE[this.decay];
        }
    }

    writeSUSTAIN_RELEASE(sustainRelease) {
        this.sustain = (sustainRelease & 0xf0) | ((sustainRelease >> 4) & 0x0f);
        this.release = sustainRelease & 0x0f;
        if (this.state === EnvelopeState.RELEASE) {
            this.rate = ADSR_TABLE[this.release];
        }
    }
}

// ============================================================================
// WAVEFORM GENERATOR
// ============================================================================

// Cycles before a deselected waveform's output starts to fade, then between
// each fading step (libsidplayfp, measured on warm 6581R3 and 8580R5 chips).
const FLOATING_OUTPUT_TTL_6581R3 = 54000;
const FLOATING_OUTPUT_FADE_6581R3 = 1400;
const FLOATING_OUTPUT_TTL_8580R5 = 800000;
const FLOATING_OUTPUT_FADE_8580R5 = 50000;
// Cycles of held test bit before the noise register starts filling with
// ones, then between each step.
const SHIFT_REGISTER_RESET_6581R3 = 50000;
const SHIFT_REGISTER_FADE_6581R3 = 15000;
const SHIFT_REGISTER_RESET_8580R5 = 986000;
const SHIFT_REGISTER_FADE_8580R5 = 314300;

// Triangle+saw, pulse+triangle, pulse+saw, pulse+triangle+saw, and pulse+noise.
const PULLDOWN_TABLE_INDEX = [-1, -1, -1, 0, -1, 1, 2, 3, -1, -1, -1, 0, 4, 1, 2, 3];

//
// The noise generator is a 23-bit shift register, numbered as in current
// libsidplayfp: bit 22 is the input, the register shifts right, and the new
// bit 22 is (bit 0 OR test) XOR bit 5. Register bits 2, 4, 8, 11, 13, 17, 20
// and 22 drive waveform output bits 11 down to 4; the low four are grounded.
//
const NOISE_TAP_MASK = ~((1 << 2) | (1 << 4) | (1 << 8) | (1 << 11) |
    (1 << 13) | (1 << 17) | (1 << 20) | (1 << 22));

// Waveform output bits 11..4 back onto the register bits that drive them.
function noiseWriteback(output) {
    return ((output & (1 << 11)) >> 9) |
        ((output & (1 << 10)) >> 6) |
        ((output & (1 << 9)) >> 1) |
        ((output & (1 << 8)) << 3) |
        ((output & (1 << 7)) << 6) |
        ((output & (1 << 6)) << 11) |
        ((output & (1 << 5)) << 15) |
        ((output & (1 << 4)) << 18);
}

// Whether a shift latches the combined-waveform output back into the noise
// register. libsidplayfp matched each case against test programs run on real
// chips, so the special cases are empirical.
function noiseWritesBack(waveformOld, waveformNew, is6581) {
    if (waveformOld <= 8 || waveformNew < 8) return false;
    if (waveformNew === 8 && waveformOld !== 0xf) return false;
    if (is6581 && ((((waveformOld & 3) === 1) && ((waveformNew & 3) === 2)) ||
        (((waveformOld & 3) === 2) && ((waveformNew & 3) === 1)))) {
        return false;
    }
    return waveformOld !== 0xc && waveformNew !== 0xc;
}

export class WaveformGenerator {
    constructor() {
        this.modelWave = null;
        this.modelPulldown = null;
        this.wave = null;
        this.pulldown = null;
        this.pw = 0;
        this.shiftRegister = 0x7fffff;
        this.shiftLatch = 0;
        this.shiftPipeline = 0;
        this.ringMsbMask = 0;
        this.noNoise = 0;
        this.noiseOutput = 0;
        this.noNoiseOrNoiseOutput = 0;
        this.noPulse = 0;
        this.pulseOutput = 0;
        this.waveform = 0;
        this.waveformOutput = 0;
        this.accumulator = 0x555555;
        this.freq = 0;
        this.triSawPipeline = 0x555;
        this.osc3 = 0;
        this.shiftRegisterReset = 0;
        this.floatingOutputTtl = 0;
        this.test = false;
        this.sync = false;
        this.testOrReset = false;
        this.msbRising = false;
        this.msbPulldown = false;
        this.is6581 = true;
        this.prevVoice = null;
        this.nextVoice = null;
    }

    setWaveformModels(models) {
        this.modelWave = models;
        this.updateWaveformTables();
    }

    setPulldownModels(models) {
        this.modelPulldown = models;
        this.updateWaveformTables();
    }

    updateWaveformTables() {
        this.wave = this.modelWave ? this.modelWave[this.waveform & 3] : null;
        const index = PULLDOWN_TABLE_INDEX[this.waveform];
        this.pulldown = this.modelPulldown && index >= 0 ? this.modelPulldown[index] : null;
        // On the 6581, combined waveforms with sawtooth can pull the
        // accumulator's top bit low.
        this.msbPulldown = this.is6581 && (this.waveform & 2) !== 0;
    }

    setOtherWaveforms(prev, next) {
        this.prevVoice = prev;
        this.nextVoice = next;
    }

    setModel(is6581) {
        this.is6581 = is6581;
    }

    reset() {
        this.accumulator = 0x555555;
        this.freq = 0;
        this.pw = 0;
        this.waveform = 0;
        this.test = false;
        this.sync = false;
        this.msbRising = false;
        this.msbPulldown = false;
        this.pulseOutput = 0xfff;
        this.waveformOutput = 0;
        this.osc3 = 0;
        this.floatingOutputTtl = 0;
        this.shiftRegisterReset = 0;
        this.noNoise = 0xfff;
        this.noPulse = 0xfff;
        this.ringMsbMask = 0;
        this.triSawPipeline = 0x555;
        this.noiseOutput = 0;
        this.noNoiseOrNoiseOutput = this.noNoise;
        if (this.modelWave) {
            this.wave = this.modelWave[0];
        }
        this.pulldown = null;
        // Releasing reset clocks the noise register once, as releasing test does.
        this.shiftRegister = 0x7fffff;
        this.testOrReset = true;
        this.shiftLatch = this.shiftRegister;
        this.shiftPhase2(0, 0);
        this.shiftPipeline = 0;
    }

    clock() {
        if (this.test) {
            if (this.shiftRegisterReset !== 0 && --this.shiftRegisterReset === 0) {
                this.shiftregBitfade();
                this.shiftLatch = this.shiftRegister;
                this.setNoiseOutput();
            }
            this.testOrReset = true;
            this.pulseOutput = 0xfff;
        } else {
            const accumulatorOld = this.accumulator;
            this.accumulator = (this.accumulator + this.freq) & 0xffffff;
            const accumulatorBitsSet = ~accumulatorOld & this.accumulator;
            this.msbRising = (accumulatorBitsSet & 0x800000) !== 0;

            if ((accumulatorBitsSet & 0x080000) !== 0) {
                this.shiftPipeline = 2;
            } else if (this.shiftPipeline !== 0) {
                if (--this.shiftPipeline === 0) {
                    this.shiftPhase2(this.waveform, this.waveform);
                } else {
                    this.testOrReset = false;
                    this.shiftLatch = this.shiftRegister;
                }
            }
        }
    }

    output() {
        if (this.waveform !== 0) {
            const prevAcc = this.prevVoice ? this.prevVoice.accumulator : 0;
            const ix = (this.accumulator ^ (~prevAcc & this.ringMsbMask)) >>> 12;

            this.waveformOutput = (this.wave ? this.wave[ix] : 0) &
                (this.noPulse | this.pulseOutput) &
                this.noNoiseOrNoiseOutput;

            if (this.pulldown !== null) {
                this.waveformOutput = this.pulldown[this.waveformOutput];
            }

            if ((this.waveform & 3) && !this.is6581) {
                this.osc3 = this.triSawPipeline & (this.noPulse | this.pulseOutput) & this.noNoiseOrNoiseOutput;
                if (this.pulldown !== null) {
                    this.osc3 = this.pulldown[this.osc3];
                }
                this.triSawPipeline = this.wave ? this.wave[ix] : 0;
            } else {
                this.osc3 = this.waveformOutput;
            }

            if (this.msbPulldown && (this.waveformOutput & 0x800) === 0) {
                this.msbRising = false;
                this.accumulator &= 0x7fffff;
            }
            this.writeShiftRegister();
        } else {
            if (this.floatingOutputTtl !== 0 && --this.floatingOutputTtl === 0) {
                this.waveBitfade();
            }
        }
        this.pulseOutput = ((this.accumulator >>> 12) >= this.pw) ? 0xfff : 0x000;
        return this.waveformOutput;
    }

    synchronize() {
        // A sync source that is itself synced on the same cycle as its MSB
        // rises does not sync its destination (verified on chips via OSC3).
        if (this.msbRising && this.nextVoice && this.nextVoice.sync &&
            !(this.sync && this.prevVoice && this.prevVoice.msbRising)) {
            this.nextVoice.accumulator = 0;
        }
    }

    shiftPhase2(waveformOld, waveformNew) {
        if (noiseWritesBack(waveformOld, waveformNew, this.is6581)) {
            this.shiftLatch = (this.shiftRegister & NOISE_TAP_MASK) | noiseWriteback(this.waveformOutput);
        }
        // Test (or reset) forces a one into the input, which is how players
        // revive noise that a combined waveform has cleared to zero.
        const input = ((this.testOrReset ? 1 : 0) | this.shiftLatch) ^ (this.shiftLatch >> 5);
        this.shiftRegister = (this.shiftLatch >>> 1) | ((input & 1) << 22);
        this.setNoiseOutput();
    }

    setNoiseOutput() {
        const register = this.shiftRegister;
        this.noiseOutput =
            ((register & (1 << 2)) << 9) |
            ((register & (1 << 4)) << 6) |
            ((register & (1 << 8)) << 1) |
            ((register & (1 << 11)) >> 3) |
            ((register & (1 << 13)) >> 6) |
            ((register & (1 << 17)) >> 11) |
            ((register & (1 << 20)) >> 15) |
            ((register & (1 << 22)) >> 18);
        this.setNoNoiseOrNoiseOutput();
    }

    setNoNoiseOrNoiseOutput() {
        this.noNoiseOrNoiseOutput = this.noNoise | this.noiseOutput;
    }

    // Combined with another waveform, the noise output is wired back into the
    // register: low output bits pull register bits low, and repeated shifts
    // can clear it entirely. During shift phase 1, or while test is held,
    // the combined output drives the noise bits directly.
    writeShiftRegister() {
        if (this.waveform > 0x8) {
            if (this.shiftPipeline !== 1 && !this.test) {
                this.shiftRegister &= NOISE_TAP_MASK | noiseWriteback(this.waveformOutput);
                this.noiseOutput &= this.waveformOutput;
            } else {
                this.noiseOutput = this.waveformOutput;
            }
            this.setNoNoiseOrNoiseOutput();
        }
    }

    waveBitfade() {
        this.waveformOutput &= this.waveformOutput >>> 1;
        this.osc3 = this.waveformOutput;
        if (this.waveformOutput !== 0) {
            this.floatingOutputTtl = this.is6581 ? FLOATING_OUTPUT_FADE_6581R3 : FLOATING_OUTPUT_FADE_8580R5;
        }
    }

    shiftregBitfade() {
        this.shiftRegister |= this.shiftRegister >>> 1;
        this.shiftRegister |= 0x400000;
        if (this.shiftRegister !== 0x7fffff) {
            this.shiftRegisterReset = this.is6581 ? SHIFT_REGISTER_FADE_6581R3 : SHIFT_REGISTER_FADE_8580R5;
        }
    }

    writeFREQ_LO(value) { this.freq = (this.freq & 0xff00) | (value & 0xff); }
    writeFREQ_HI(value) { this.freq = ((value << 8) & 0xff00) | (this.freq & 0xff); }
    writePW_LO(value) { this.pw = (this.pw & 0xf00) | (value & 0x0ff); }
    writePW_HI(value) { this.pw = ((value << 8) & 0xf00) | (this.pw & 0x0ff); }

    writeCONTROL_REG(control) {
        const waveformPrev = this.waveform;
        const testPrev = this.test;
        this.waveform = (control >> 4) & 0x0f;
        this.test = (control & 0x08) !== 0;
        this.sync = (control & 0x02) !== 0;
        // Ring modulation substitutes the accumulator MSB while sawtooth is off.
        this.ringMsbMask = ((~control >> 5) & (control >> 2) & 1) << 23;
        this.updateWaveformTables();

        if (this.waveform !== waveformPrev) {
            this.noNoise = (this.waveform & 0x8) ? 0x000 : 0xfff;
            this.setNoNoiseOrNoiseOutput();
            this.noPulse = (this.waveform & 0x4) ? 0x000 : 0xfff;
            if (this.waveform === 0) {
                // With no waveform selected the DAC input floats, holding the
                // last output for a while before it fades.
                this.floatingOutputTtl = this.is6581 ? FLOATING_OUTPUT_TTL_6581R3 : FLOATING_OUTPUT_TTL_8580R5;
            }
        }

        if (this.test !== testPrev) {
            if (this.test) {
                this.accumulator = 0;
                this.shiftPipeline = 0;
                this.shiftLatch = this.shiftRegister;
                this.shiftRegisterReset = this.is6581 ? SHIFT_REGISTER_RESET_6581R3 : SHIFT_REGISTER_RESET_8580R5;
            } else {
                // Releasing test completes the second phase of a shift.
                this.shiftPhase2(waveformPrev, this.waveform);
            }
        }
    }

    readOSC() { return (this.osc3 >>> 4) & 0xff; }
    readAccumulator() { return this.accumulator; }
    readFreq() { return this.freq; }
    readTest() { return this.test; }
    readFollowingVoiceSync() { return this.nextVoice ? this.nextVoice.sync : false; }
}

// ============================================================================
// VOICE
// ============================================================================

export class Voice {
    constructor() {
        this.waveformGenerator = new WaveformGenerator();
        this.envelopeGenerator = new EnvelopeGenerator();
        this.wavDAC = null;
        this.envDAC = null;
        // Listening aid, not hardware: silences the voice in the final mix.
        this.muted = false;
    }

    // Waveform DAC times envelope DAC: one voice swings 1.0 peak to peak at
    // full envelope. The filter adds each chip's DC levels.
    output() {
        const wav = this.waveformGenerator.output();
        const env = this.envelopeGenerator.output();
        if (this.wavDAC && this.envDAC) {
            return this.wavDAC[wav] * this.envDAC[env];
        }
        return (wav - 2048) / 4096 * (env / 255);
    }

    setWavDAC(dac) { this.wavDAC = dac; }
    setEnvDAC(dac) { this.envDAC = dac; }

    setOtherVoices(prev, next) {
        this.waveformGenerator.setOtherWaveforms(prev.wave(), next.wave());
    }

    wave() { return this.waveformGenerator; }
    envelope() { return this.envelopeGenerator; }

    writeCONTROL_REG(control) {
        this.waveformGenerator.writeCONTROL_REG(control);
        this.envelopeGenerator.writeCONTROL_REG(control);
    }

    reset() {
        this.waveformGenerator.reset();
        this.envelopeGenerator.reset();
    }
}
