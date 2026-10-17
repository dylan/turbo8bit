//
// @fileoverview MOS6581/MOS8580 SID Chip Emulation
// @module emulator/sid
//
// Cycle-accurate emulation of the SID sound chip used in the Commodore 64.
// Inspired by libsidplayfp.
//
// This module contains:
// - Dac: Digital to Analog Converter with non-linear behavior modeling
// - SidResampler: band-limited conversion from the clock rate to audio rate
// - SID: Main SID chip combining 3 voices, filters, and audio resampling
//
// The SID chip features:
// - 3 independent voices with multiple waveforms (triangle, sawtooth, pulse, noise)
// - Programmable ADSR envelope generators
// - Resonant multi-mode filter (low-pass, band-pass, high-pass)
// - Ring modulation and oscillator sync
//
// Signal path, once per clock cycle: waveform and envelope generators (via
// their DAC tables) -> filter and mixer -> C64 output stage -> resampler ->
// output level and limiter -> 16-bit samples.
//
// For SID file playback, see sid-player.js.
// For voice and envelope details, see voice.js.
// For filter details, see filter.js.
//
// @see https://www.turbo8bit.com/
//

import { Voice, getWaveformCalculator } from './voice.js';
import { Filter6581, Filter8580, ExternalFilter } from './filter.js';

// ============================================================================
// DAC
// ============================================================================

const MOSFET_LEAKAGE_6581 = 0.0075;
const MOSFET_LEAKAGE_8580 = 0.0035;

class Dac {
    constructor(bits) {
        this.dacLength = bits;
        this.dac = new Float64Array(bits);
        this.leakage = MOSFET_LEAKAGE_6581;
    }

    getOutput(input, saturate = false) {
        let dacValue = 0;
        for (let i = 0; i < this.dacLength; i++) {
            const transistorOn = (input & (1 << i)) !== 0;
            dacValue += transistorOn ? this.dac[i] : this.dac[i] * this.leakage;
        }
        if (saturate) {
            const GAIN = 1.1;
            const SAT = 1.1;
            dacValue = GAIN * dacValue + (1 - GAIN) * SAT * dacValue * dacValue * dacValue;
        }
        return dacValue;
    }

    kinkedDac(chipModel) {
        const R_INFINITY = 1e6;
        const _2R_div_R = chipModel === 'MOS6581' ? 2.20 : 2.00;
        const term = chipModel === 'MOS8580';
        this.leakage = chipModel === 'MOS6581' ? MOSFET_LEAKAGE_6581 : MOSFET_LEAKAGE_8580;

        let Vsum = 0;
        for (let setBit = 0; setBit < this.dacLength; setBit++) {
            let Vn = 1;
            const R = 1;
            const _2R = _2R_div_R * R;
            let Rn = term ? _2R : R_INFINITY;
            let bit;

            for (bit = 0; bit < setBit; bit++) {
                Rn = Rn === R_INFINITY ? R + _2R : R + (_2R * Rn) / (_2R + Rn);
            }

            if (Rn === R_INFINITY) {
                Rn = _2R;
            } else {
                Rn = (_2R * Rn) / (_2R + Rn);
                Vn = Vn * Rn / _2R;
            }

            for (++bit; bit < this.dacLength; bit++) {
                Rn += R;
                const I = Vn / Rn;
                Rn = (_2R * Rn) / (_2R + Rn);
                Vn = Rn * I;
            }

            this.dac[setBit] = Vn;
            Vsum += Vn;
        }

        for (let i = 0; i < this.dacLength; i++) {
            this.dac[i] /= Vsum;
        }
    }
}

// ============================================================================
// RESAMPLER
// ============================================================================
//
// The SID runs at the C64's ~1 MHz clock and its waveforms carry harmonics
// far above 20 kHz. Keeping only every 22nd cycle would fold them back into
// the audible band as inharmonic noise, so the stream is low-passed first.
// As in libsidplayfp's TwoPassSincResampler, two stages keep that affordable:
// a whole-number decimation to roughly 100 kHz, then a polyphase sinc that
// lands on the output rate. Both use Kaiser windows for a 96 dB stopband,
// below 16-bit quantization.
//

const RESAMPLER_STOPBAND_DB = 96.33;
const RESAMPLER_KAISER_BETA = 0.1102 * (RESAMPLER_STOPBAND_DB - 8.7);

// Modified Bessel function of the first kind, order zero, for the window.
function besselI0(x) {
    let sum = 1;
    let term = 1;
    const half = x / 2;
    for (let n = 1; term >= 1e-6 * sum; n++) {
        const ratio = half / n;
        term *= ratio * ratio;
        sum += term;
    }
    return sum;
}

const RESAMPLER_KAISER_SCALE = 1 / besselI0(RESAMPLER_KAISER_BETA);

// A sinc with zeros every `zeroSpacing` samples, under a Kaiser window that
// reaches zero at +-halfWidth.
function windowedSinc(x, zeroSpacing, halfWidth) {
    const t = x / halfWidth;
    if (Math.abs(t) >= 1) return 0;
    const window = besselI0(RESAMPLER_KAISER_BETA * Math.sqrt(1 - t * t)) * RESAMPLER_KAISER_SCALE;
    const wt = Math.PI * x / zeroSpacing;
    return Math.abs(wt) < 1e-8 ? window : window * Math.sin(wt) / wt;
}

// Kaiser's estimate of the filter order for a transition band given in
// radians per sample.
function kaiserOrder(transition) {
    return (RESAMPLER_STOPBAND_DB - 7.95) / (2.285 * transition);
}

//
// Both stages keep each input sample twice, `size` apart, so the newest
// `taps` samples are always contiguous and a dot product never wraps.
//

// Stage 1: low-pass, then keep every `factor`-th sample.
class DecimationStage {
    constructor(inputRate, factor, passband) {
        this.factor = factor;
        // Content above (outputRate - passband) would fold into the passband.
        const transition = 2 * Math.PI * (inputRate / factor - 2 * passband) / inputRate;
        const taps = (Math.ceil(kaiserOrder(transition)) + 1) | 1;
        const half = (taps - 1) / 2;
        this.taps = taps;
        this.coefficients = new Float32Array(taps);
        let sum = 0;
        for (let i = 0; i < taps; i++) {
            this.coefficients[i] = windowedSinc(i - half, factor, half + 1);
            sum += this.coefficients[i];
        }
        for (let i = 0; i < taps; i++) this.coefficients[i] /= sum;
        this.size = 1 << Math.ceil(Math.log2(taps + 1));
        this.history = new Float32Array(2 * this.size);
        this.reset();
    }

    reset() {
        this.history.fill(0);
        this.index = 0;
        this.phase = 0;
        this.output = 0;
    }

    input(sample) {
        const size = this.size;
        const history = this.history;
        history[this.index] = sample;
        history[this.index + size] = sample;
        this.index = (this.index + 1) & (size - 1);
        if (++this.phase < this.factor) return false;
        this.phase = 0;

        const taps = this.taps;
        const coefficients = this.coefficients;
        const start = this.index + size - taps;
        let sum = 0;
        for (let i = 0; i < taps; i++) sum += history[start + i] * coefficients[i];
        this.output = sum;
        return true;
    }
}

// Stage 2: libsidplayfp's SincResampler. Each output interpolates between
// the two precomputed filter phases nearest its fractional position.
class PolyphaseStage {
    constructor(inputRate, outputRate, passband) {
        const ratio = inputRate / outputRate;
        // From the passband edge to its mirror image above the output Nyquist
        // frequency, where the sinc is centred. In output samples.
        const transition = 2 * Math.PI * (1 - 2 * passband / outputRate);
        let order = Math.round(kaiserOrder(transition));
        order += order & 1;
        const taps = ((order * ratio) | 0) + 1 | 1;
        const half = (taps - 1) / 2;
        // Enough phases that interpolating between them stays below 16-bit error.
        const phases = Math.ceil(Math.sqrt(1.234 * (1 << 16)) / ratio);
        const table = new Float32Array(phases * taps);
        for (let p = 0; p < phases; p++) {
            let sum = 0;
            for (let j = 0; j < taps; j++) {
                table[p * taps + j] = windowedSinc(j - half - p / phases, ratio, half);
                sum += table[p * taps + j];
            }
            for (let j = 0; j < taps; j++) table[p * taps + j] /= sum;
        }
        this.ratio = ratio;
        this.taps = taps;
        this.phases = phases;
        this.table = table;
        this.size = 1 << Math.ceil(Math.log2(taps + 2));
        this.history = new Float32Array(2 * this.size);
        this.reset();
    }

    reset() {
        this.history.fill(0);
        this.index = 0;
        // Where the next output falls, in input samples after the newest one.
        this.position = 0;
        this.output = 0;
    }

    input(sample) {
        const size = this.size;
        this.history[this.index] = sample;
        this.history[this.index + size] = sample;
        this.index = (this.index + 1) & (size - 1);
        let ready = false;
        if (this.position < 1) {
            this.output = this.interpolate(this.position);
            this.position += this.ratio;
            ready = true;
        }
        this.position -= 1;
        return ready;
    }

    interpolate(fraction) {
        const taps = this.taps;
        const table = this.table;
        const history = this.history;
        const scaled = fraction * this.phases;
        let phase = scaled | 0;
        const blend = scaled - phase;
        let start = this.index + this.size - taps - 1;

        let a = 0;
        let offset = phase * taps;
        for (let j = 0; j < taps; j++) a += history[start + j] * table[offset + j];
        if (++phase === this.phases) {
            phase = 0;
            start++;
        }
        let b = 0;
        offset = phase * taps;
        for (let j = 0; j < taps; j++) b += history[start + j] * table[offset + j];
        return a + blend * (b - a);
    }
}

export class SidResampler {
    constructor(clockFrequency, samplingFrequency) {
        const passband = samplingFrequency > 44000 ? 20000 : samplingFrequency * 0.45;
        // libsidplayfp's intermediate rate (after Laurent Ganier), rounded down
        // to a whole decimation factor and kept at or above the output rate.
        const intermediate = 2 * passband + Math.sqrt(2 * passband * clockFrequency *
            (samplingFrequency - 2 * passband) / samplingFrequency);
        const factor = Math.max(1, Math.min(Math.floor(clockFrequency / intermediate),
            Math.floor(clockFrequency / samplingFrequency)));
        this.decimator = new DecimationStage(clockFrequency, factor, passband);
        this.interpolator = new PolyphaseStage(clockFrequency / factor, samplingFrequency, passband);
        this.output = 0;
    }

    reset() {
        this.decimator.reset();
        this.interpolator.reset();
        this.output = 0;
    }

    // Feed one sample at the clock rate; true when an output sample is ready.
    input(sample) {
        if (!this.decimator.input(sample) || !this.interpolator.input(this.decimator.output)) {
            return false;
        }
        this.output = this.interpolator.output;
        return true;
    }
}

// ============================================================================
// OUTPUT LEVEL
// ============================================================================

// Three full voices at volume 15 (+-22.5 voice units, see filter.js) reach
// -3 dBFS: reSID leaves 6 dB of headroom, libsidplayfp about 1 dB. Rarer
// peaks, such as an 8580's resonance or a 6581 volume step, meet the limiter.
const SID_OUTPUT_SCALE = 32768 * Math.pow(10, -3 / 20) / 22.5;
const OUTPUT_LIMIT_KNEE = 28000;

// libsidplayfp's limiter: linear below the knee, then a tanh curve that
// approaches but never passes the 16-bit limits.
function softClip(sample) {
    const magnitude = Math.abs(sample);
    if (magnitude < OUTPUT_LIMIT_KNEE) return Math.round(sample);
    const headroom = 32767 - OUTPUT_LIMIT_KNEE;
    const limited = OUTPUT_LIMIT_KNEE + headroom * Math.tanh((magnitude - OUTPUT_LIMIT_KNEE) / headroom);
    return Math.round(sample < 0 ? -limited : limited);
}

// ============================================================================
// SID CHIP
// ============================================================================

export const ChipModel = {
    MOS6581: 'MOS6581',
    MOS8580: 'MOS8580'
};

export const CombinedWaveforms = {
    AVERAGE: 'AVERAGE',
    WEAK: 'WEAK',
    STRONG: 'STRONG'
};

// Accepted for API compatibility: the band-limited resampler above is used
// whichever method is asked for, because plain decimation aliases.
export const SamplingMethod = {
    DECIMATE: 'DECIMATE',
    RESAMPLE: 'RESAMPLE'
};

const BUS_TTL_6581 = 0x01d00;
const BUS_TTL_8580 = 0xa2000;
const ENV_DAC_BITS = 8;
const OSC_DAC_BITS = 12;
// The 6581 waveform DAC's zero level, measured by reSID; the 8580's is mid-scale.
const OSC_DAC_ZERO_6581 = 0x380;

export class SID {
    constructor() {
        this.voice = [new Voice(), new Voice(), new Voice()];
        this.voice[0].setOtherVoices(this.voice[2], this.voice[1]);
        this.voice[1].setOtherVoices(this.voice[0], this.voice[2]);
        this.voice[2].setOtherVoices(this.voice[1], this.voice[0]);

        this.filter6581 = new Filter6581();
        this.filter8580 = new Filter8580();
        this.filter = this.filter8580;
        this.externalFilter = new ExternalFilter();

        this.envDAC = new Float32Array(1 << ENV_DAC_BITS);
        this.oscDAC = new Float32Array(1 << OSC_DAC_BITS);

        this.clockFrequency = 985248;
        this.samplingFrequency = 44100;
        this.resampler = new SidResampler(this.clockFrequency, this.samplingFrequency);

        this.model = ChipModel.MOS8580;
        this.cws = CombinedWaveforms.AVERAGE;
        this.modelTTL = BUS_TTL_8580;

        this.busValue = 0;
        this.busValueTtl = 0;
        this.nextVoiceSync = 0x7fffffff;

        this.writeQueue = [];
        this.writeQueueIndex = 0;  // Index pointer to avoid shift() overhead
        this.currentCycle = 0;

        this.setChipModel(ChipModel.MOS8580);
        this.reset();
    }

    setChipModel(model) {
        switch (model) {
            case ChipModel.MOS6581:
                this.filter = this.filter6581;
                this.modelTTL = BUS_TTL_6581;
                break;
            case ChipModel.MOS8580:
                this.filter = this.filter8580;
                this.modelTTL = BUS_TTL_8580;
                break;
            default:
                throw new Error('Unknown chip model');
        }

        this.model = model;

        const waveCalc = getWaveformCalculator();
        const wavetables = waveCalc.getWaveTable();
        const pulldowntables = waveCalc.buildPulldownTable(model, this.cws);

        const envDac = new Dac(ENV_DAC_BITS);
        envDac.kinkedDac(model);
        for (let i = 0; i < (1 << ENV_DAC_BITS); i++) {
            this.envDAC[i] = envDac.getOutput(i);
        }

        const is6581 = model === ChipModel.MOS6581;
        const oscDac = new Dac(OSC_DAC_BITS);
        oscDac.kinkedDac(model);
        const offset = oscDac.getOutput(is6581 ? OSC_DAC_ZERO_6581 : 0x800, is6581);
        for (let i = 0; i < (1 << OSC_DAC_BITS); i++) {
            const dacValue = oscDac.getOutput(i, is6581);
            this.oscDAC[i] = dacValue - offset;
        }

        for (let i = 0; i < 3; i++) {
            this.voice[i].setEnvDAC(this.envDAC);
            this.voice[i].setWavDAC(this.oscDAC);
            this.voice[i].wave().setModel(is6581);
            this.voice[i].wave().setWaveformModels(wavetables);
            this.voice[i].wave().setPulldownModels(pulldowntables);
        }
    }

    getChipModel() { return this.model; }

    setCombinedWaveforms(cws) {
        this.cws = cws;
        const waveCalc = getWaveformCalculator();
        const pulldowntables = waveCalc.buildPulldownTable(this.model, cws);
        for (let i = 0; i < 3; i++) {
            this.voice[i].wave().setPulldownModels(pulldowntables);
        }
    }

    reset() {
        for (let i = 0; i < 3; i++) {
            this.voice[i].reset();
        }
        this.filter6581.reset();
        this.filter8580.reset();
        this.externalFilter.reset();
        this.resampler.reset();
        this.busValue = 0;
        this.busValueTtl = 0;
        this.writeQueue = [];
        this.writeQueueIndex = 0;
        this.currentCycle = 0;
        this.voiceSync(false);
    }

    input(value) {
        this.filter6581.input(value);
        this.filter8580.input(value);
    }

    ageBusValue(n) {
        if (this.busValueTtl !== 0) {
            this.busValueTtl -= n;
            if (this.busValueTtl <= 0) {
                this.busValue = 0;
                this.busValueTtl = 0;
            }
        }
    }

    voiceSync(sync) {
        if (sync) {
            for (let i = 0; i < 3; i++) {
                this.voice[i].wave().synchronize();
            }
        }
        this.nextVoiceSync = 0x7fffffff;
        for (let i = 0; i < 3; i++) {
            const wave = this.voice[i].wave();
            const freq = wave.readFreq();
            if (wave.readTest() || freq === 0 || !wave.readFollowingVoiceSync()) {
                continue;
            }
            const accumulator = wave.readAccumulator();
            const thisVoiceSync = (((0x7fffff - accumulator) & 0xffffff) / freq + 1) | 0;
            if (thisVoiceSync < this.nextVoiceSync) {
                this.nextVoiceSync = thisVoiceSync;
            }
        }
    }

    // Device inspection must not refresh or replace the SID's floating bus latch.
    peek(offset) {
        switch (offset) {
            case 0x19: case 0x1a: return 0xff;
            case 0x1b: return this.voice[2].wave().readOSC();
            case 0x1c: return this.voice[2].envelope().readENV();
            default: return this.busValue;
        }
    }

    read(offset) {
        switch (offset) {
            case 0x19: case 0x1a: case 0x1b: case 0x1c:
                this.busValue = this.peek(offset);
                this.busValueTtl = this.modelTTL;
                break;
            default:
                this.busValueTtl = (this.busValueTtl / 2) | 0;
                break;
        }
        return this.busValue;
    }

    write(offset, value, cycle = null) {
        const writeCycle = cycle !== null ? cycle : this.currentCycle;
        this.writeQueue.push({
            offset: offset & 0x1f,
            value: value & 0xff,
            cycle: writeCycle
        });
    }

    applyRegisterWrite(offset, value) {
        this.busValue = value;
        this.busValueTtl = this.modelTTL;

        switch (offset) {
            case 0x00: this.voice[0].wave().writeFREQ_LO(value); break;
            case 0x01: this.voice[0].wave().writeFREQ_HI(value); break;
            case 0x02: this.voice[0].wave().writePW_LO(value); break;
            case 0x03: this.voice[0].wave().writePW_HI(value); break;
            case 0x04: this.voice[0].writeCONTROL_REG(value); break;
            case 0x05: this.voice[0].envelope().writeATTACK_DECAY(value); break;
            case 0x06: this.voice[0].envelope().writeSUSTAIN_RELEASE(value); break;
            case 0x07: this.voice[1].wave().writeFREQ_LO(value); break;
            case 0x08: this.voice[1].wave().writeFREQ_HI(value); break;
            case 0x09: this.voice[1].wave().writePW_LO(value); break;
            case 0x0a: this.voice[1].wave().writePW_HI(value); break;
            case 0x0b: this.voice[1].writeCONTROL_REG(value); break;
            case 0x0c: this.voice[1].envelope().writeATTACK_DECAY(value); break;
            case 0x0d: this.voice[1].envelope().writeSUSTAIN_RELEASE(value); break;
            case 0x0e: this.voice[2].wave().writeFREQ_LO(value); break;
            case 0x0f: this.voice[2].wave().writeFREQ_HI(value); break;
            case 0x10: this.voice[2].wave().writePW_LO(value); break;
            case 0x11: this.voice[2].wave().writePW_HI(value); break;
            case 0x12: this.voice[2].writeCONTROL_REG(value); break;
            case 0x13: this.voice[2].envelope().writeATTACK_DECAY(value); break;
            case 0x14: this.voice[2].envelope().writeSUSTAIN_RELEASE(value); break;
            case 0x15:
                this.filter6581.writeFC_LO(value);
                this.filter8580.writeFC_LO(value);
                break;
            case 0x16:
                this.filter6581.writeFC_HI(value);
                this.filter8580.writeFC_HI(value);
                break;
            case 0x17:
                this.filter6581.writeRES_FILT(value);
                this.filter8580.writeRES_FILT(value);
                break;
            case 0x18:
                this.filter6581.writeMODE_VOL(value);
                this.filter8580.writeMODE_VOL(value);
                break;
        }
        this.voiceSync(false);
    }

    setCycleCount(cycle) { this.currentCycle = cycle; }

    applyPendingWrites() {
        while (this.writeQueueIndex < this.writeQueue.length) {
            const cmd = this.writeQueue[this.writeQueueIndex++];
            this.applyRegisterWrite(cmd.offset, cmd.value);
        }
        // Clear queue when fully consumed
        if (this.writeQueueIndex >= this.writeQueue.length) {
            this.writeQueue.length = 0;
            this.writeQueueIndex = 0;
        }
    }

    beginFrame() {
        // Reset queue index and sort pending writes
        this.writeQueueIndex = 0;
        this.writeQueue.sort((a, b) => a.cycle - b.cycle);
    }

    // The filters' cutoff coefficients and the output stage depend on the
    // clock, so a change of video standard rebuilds them with the resampler.
    setSamplingParameters(clockFrequency, method, samplingFrequency) {
        this.clockFrequency = clockFrequency;
        this.samplingFrequency = samplingFrequency;
        this.externalFilter.setClockFrequency(clockFrequency);
        this.filter6581.setClockFrequency(clockFrequency);
        this.filter8580.setClockFrequency(clockFrequency);
        this.resampler = new SidResampler(clockFrequency, samplingFrequency);
    }

    clock(cycles, buf, startCycle = 0) {
        this.ageBusValue(cycles);
        let s = 0;
        const endCycle = startCycle + cycles;
        let currentCycle = startCycle;

        // Cache voice/wave/envelope references to avoid repeated property lookups in hot loop
        const v0 = this.voice[0], v1 = this.voice[1], v2 = this.voice[2];
        const w0 = v0.wave(), w1 = v1.wave(), w2 = v2.wave();
        const e0 = v0.envelope(), e1 = v1.envelope(), e2 = v2.envelope();
        const filter = this.filter;
        const externalFilter = this.externalFilter;
        const resampler = this.resampler;
        const writeQueue = this.writeQueue;

        while (currentCycle < endCycle) {
            // Process pending writes using index pointer (avoids O(n) shift)
            while (this.writeQueueIndex < writeQueue.length && writeQueue[this.writeQueueIndex].cycle <= currentCycle) {
                const cmd = writeQueue[this.writeQueueIndex++];
                this.applyRegisterWrite(cmd.offset, cmd.value);
            }

            let nextEventCycle = endCycle;
            if (this.writeQueueIndex < writeQueue.length) {
                nextEventCycle = Math.min(nextEventCycle, writeQueue[this.writeQueueIndex].cycle);
            }

            const cyclesToRun = Math.min(
                nextEventCycle - currentCycle,
                this.nextVoiceSync
            );

            if (cyclesToRun <= 0) {
                currentCycle++;
                continue;
            }

            for (let i = 0; i < cyclesToRun; i++) {
                w0.clock();
                w1.clock();
                w2.clock();
                e0.clock();
                e1.clock();
                e2.clock();

                if (resampler.input(externalFilter.clock(filter.clock(v0, v1, v2)))) {
                    buf[s++] = softClip(resampler.output * SID_OUTPUT_SCALE);
                }
            }

            currentCycle += cyclesToRun;
            this.nextVoiceSync -= cyclesToRun;

            if (this.nextVoiceSync <= 0) {
                this.voiceSync(true);
            }
        }

        // Clear consumed queue entries
        if (this.writeQueueIndex >= writeQueue.length) {
            writeQueue.length = 0;
            this.writeQueueIndex = 0;
        }

        this.currentCycle = endCycle;
        return s;
    }

    clockSilent(cycles) {
        this.ageBusValue(cycles);
        while (cycles > 0) {
            const deltaT = Math.min(this.nextVoiceSync, cycles);
            if (deltaT > 0) {
                for (let i = 0; i < deltaT; i++) {
                    this.voice[0].wave().clock();
                    this.voice[1].wave().clock();
                    this.voice[2].wave().clock();
                    this.voice[0].wave().output();
                    this.voice[1].wave().output();
                    this.voice[2].wave().output();
                    this.voice[2].envelope().clock();
                }
                cycles -= deltaT;
                this.nextVoiceSync -= deltaT;
            }
            if (this.nextVoiceSync === 0) {
                this.voiceSync(true);
            }
        }
    }

    enableFilter(enable) {
        this.filter6581.enable(enable);
        this.filter8580.enable(enable);
    }
}