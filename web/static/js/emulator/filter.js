//
// @fileoverview SID Filter Emulation - the analog stages after the voices
// @module emulator/filter
//
// Components:
// - Filter: voice routing, the two-integrator-loop (state variable) filter,
//   and the output mixer with its 4-bit volume
// - Filter6581 / Filter8580: each chip's cutoff curve, resonance and DC levels
// - ExternalFilter: the C64's audio output stage (RC low-pass + DC blocker)
//
// The model is Dag Lem's reSID 0.16, the long-standing linear SID model: its
// filter equations, its measured cutoff curves and the 6581's DC offsets. The
// 8580's resonance uses the curve reSID 1.0 read from the die. libsidplayfp's
// non-linear 6581 op-amp model is far more costly and is not attempted.
//
// Signals are floating point in "voice units": one voice at full envelope
// swings 1.0 peak to peak (waveform DAC x envelope DAC, see sid.js). The
// mixer output is that times the volume register, so three full voices at
// volume 15 reach +-22.5. Nothing here clips; sid.js scales and limits.
//
// For main SID chip, see sid.js.
// For voice components, see voice.js.
//
// @see https://www.turbo8bit.com/
//

// ============================================================================
// EXTERNAL FILTER
// ============================================================================

//
// The C64's audio output stage: a 10 kOhm / 1000 pF low-pass (15.9 kHz)
// followed by the 10 uF output capacitor, which blocks DC into the load.
// With a 1 kOhm load the high-pass corner is 15.9 Hz (reSID 0.16); a 10 kOhm
// load would put it at 1.6 Hz. The higher corner keeps the thump from a
// volume change short, which matters because the 6581's DC offsets make that
// thump about three times as large as a full voice.
//
export class ExternalFilter {
    constructor() {
        this.Vlp = 0;
        this.Vhp = 0;
        this.w0lp = 0;
        this.w0hp = 0;
        this.setClockFrequency(985248);
    }

    setClockFrequency(frequency) {
        const dt = 1 / frequency;
        this.w0lp = dt / (dt + 10e3 * 1000e-12);
        this.w0hp = dt / (dt + 1e3 * 10e-6);
    }

    reset() {
        this.Vlp = 0;
        this.Vhp = 0;
    }

    clock(input) {
        const dVlp = this.w0lp * (input - this.Vlp);
        const dVhp = this.w0hp * (this.Vlp - this.Vhp);
        this.Vlp += dVlp;
        this.Vhp += dVhp;
        return this.Vlp - this.Vhp;
    }
}

// ============================================================================
// CUTOFF CURVES
// ============================================================================

//
// Cutoff frequency in Hz against the 11-bit FC register, as measured for
// reSID 0.16. The 6581 curve drops at FC = $400, where the top bit of its
// cutoff DAC takes over from the others. Real chips vary, the 6581 widely.
// Points are joined by straight lines.
//
const FILTER_CUTOFF_6581 = [
    [0, 220], [128, 230], [256, 250], [384, 300], [512, 420], [640, 780],
    [768, 1600], [832, 2300], [896, 3200], [960, 4300], [992, 5000],
    [1008, 5400], [1016, 5700], [1023, 6000], [1024, 4600], [1032, 4800],
    [1056, 5300], [1088, 6000], [1120, 6600], [1152, 7200], [1280, 9500],
    [1408, 12000], [1536, 14500], [1664, 16000], [1792, 17100],
    [1920, 17700], [2047, 18000]
];

const FILTER_CUTOFF_8580 = [
    [0, 0], [128, 800], [256, 1600], [384, 2500], [512, 3300], [640, 4100],
    [768, 4800], [896, 5600], [1024, 6500], [1152, 7500], [1280, 8400],
    [1408, 9200], [1536, 9800], [1664, 10500], [1792, 11000],
    [1920, 11700], [2047, 12500]
];

function buildCutoffTable(points) {
    const table = new Float64Array(2048);
    let segment = 0;
    for (let fc = 0; fc < 2048; fc++) {
        while (segment < points.length - 2 && fc > points[segment + 1][0]) segment++;
        const [x0, y0] = points[segment];
        const [x1, y1] = points[segment + 1];
        table[fc] = y0 + (y1 - y0) * (fc - x0) / (x1 - x0);
    }
    return table;
}

// ============================================================================
// FILTER
// ============================================================================

//
// The SID filter is a two-integrator-loop biquad, which Bob Yannes confirmed
// is the chip's circuit. As in reSID:
//
//   Vhp = Vbp/Q - Vlp - Vi      (summer)
//   Vbp -= w0 * Vhp * dt        (first integrator)
//   Vlp -= w0 * Vbp * dt        (second integrator)
//
// The input is not scaled by 1/Q: resonance raises the response around the
// cutoff while the passband stays at unity gain. Filter outputs are inverted
// relative to the input, as on the chip, which matters when filtered and
// direct DC levels meet in the mixer.
//
// Chip models supply the cutoff curve, resonance(res) returning 1/Q for the
// 4-bit setting, and the DC levels.
//
export class Filter {
    constructor(cutoffPoints) {
        this.cutoffHz = buildCutoffTable(cutoffPoints);
        this.w0Table = new Float64Array(2048);

        // Registers
        this.fc = 0;
        this.filt = 0;
        this.filt1 = false;
        this.filt2 = false;
        this.filt3 = false;
        this.filtE = false;
        this.voice3off = false;
        this.hp = false;
        this.bp = false;
        this.lp = false;
        this.vol = 0;
        this.enabled = true;

        // Derived from the registers
        this.w0 = 0;
        this.oneOverQ = 1;

        // Highpass (summer), bandpass and lowpass (integrator) outputs
        this.Vhp = 0;
        this.Vbp = 0;
        this.Vlp = 0;

        // EXT IN, in voice units
        this.Ve = 0;

        // DC at each voice's mixer input and at the mixer itself; set by
        // the chip models (zero on the 8580).
        this.voiceDC = 0;
        this.mixerDC = 0;

        this.setClockFrequency(985248);
    }

    // The integrators step once per clock cycle, so w0 is per cycle.
    setClockFrequency(frequency) {
        for (let fc = 0; fc < 2048; fc++) {
            this.w0Table[fc] = 2 * Math.PI * this.cutoffHz[fc] / frequency;
        }
        this.updateCenterFrequency();
    }

    updateCenterFrequency() {
        this.w0 = this.w0Table[this.fc];
    }

    writeFC_LO(fcLo) {
        this.fc = (this.fc & 0x7f8) | (fcLo & 0x007);
        this.updateCenterFrequency();
    }

    writeFC_HI(fcHi) {
        this.fc = ((fcHi << 3) & 0x7f8) | (this.fc & 0x007);
        this.updateCenterFrequency();
    }

    writeRES_FILT(resFilt) {
        this.filt = resFilt;
        this.oneOverQ = this.resonance((resFilt >> 4) & 0x0f);
        if (this.enabled) {
            this.filt1 = (resFilt & 0x01) !== 0;
            this.filt2 = (resFilt & 0x02) !== 0;
            this.filt3 = (resFilt & 0x04) !== 0;
            this.filtE = (resFilt & 0x08) !== 0;
        }
    }

    writeMODE_VOL(modeVol) {
        this.vol = modeVol & 0x0f;
        this.lp = (modeVol & 0x10) !== 0;
        this.bp = (modeVol & 0x20) !== 0;
        this.hp = (modeVol & 0x40) !== 0;
        this.voice3off = (modeVol & 0x80) !== 0;
    }

    enable(enabled) {
        this.enabled = enabled;
        if (enabled) {
            this.writeRES_FILT(this.filt);
        } else {
            this.filt1 = this.filt2 = this.filt3 = this.filtE = false;
        }
    }

    reset() {
        this.writeFC_LO(0);
        this.writeFC_HI(0);
        this.writeMODE_VOL(0);
        this.writeRES_FILT(0);
        this.Vhp = 0;
        this.Vbp = 0;
        this.Vlp = 0;
    }

    // A signed 16-bit sample on EXT IN; full scale matches one voice's swing.
    input(value) {
        this.Ve = value / 65536;
    }

    // A muted voice keeps its DC level, so muting a voice neither clicks
    // nor changes how loud volume-register samples play.
    voiceOutput(voice) {
        const level = voice.output();
        return voice.muted ? this.voiceDC : level + this.voiceDC;
    }

    //
    // One clock cycle: route the voices, step the filter and mix.
    // @returns {number} Mixer output in voice units times the volume
    //
    clock(voice1, voice2, voice3) {
        // Every voice's output stage runs each cycle, whether muted or routed
        // away: it has side effects (noise writeback, the 6581 sawtooth MSB
        // pulldown, the pulse comparator pipeline).
        const v1 = this.voiceOutput(voice1);
        const v2 = this.voiceOutput(voice2);
        const v3 = this.voiceOutput(voice3);

        let Vi = 0;
        let Vnf = 0;
        if (this.filt1) Vi += v1; else Vnf += v1;
        if (this.filt2) Vi += v2; else Vnf += v2;
        // "Voice 3 off" only cuts voice 3's direct path to the mixer.
        if (this.filt3) Vi += v3; else if (!this.voice3off) Vnf += v3;
        if (this.filtE) Vi += this.Ve; else Vnf += this.Ve;

        const dVbp = this.w0 * this.Vhp;
        const dVlp = this.w0 * this.Vbp;
        this.Vbp -= dVbp;
        this.Vlp -= dVlp;
        this.Vhp = this.Vbp * this.oneOverQ - this.Vlp - Vi;

        let Vf = 0;
        if (this.lp) Vf += this.Vlp;
        if (this.bp) Vf += this.Vbp;
        if (this.hp) Vf += this.Vhp;

        return (Vnf + Vf + this.mixerDC) * this.vol;
    }
}

// ============================================================================
// FILTER 6581
// ============================================================================

//
// Each 6581 voice sits half a voice's swing of DC above the mixer's zero, and
// the mixer input sits 1/18 of a swing below it (reSID 0.16, measured). The
// volume register scales all of it, which is why 4-bit sample playback by
// writing $D418 is loud on a 6581. The waveform DAC's own offset is in the
// DAC table (sid.js).
//
// Resonance is reSID 0.16's Q = 0.707 + res/15. The chip's ladder would allow
// a far higher Q, but its op-amps limit it, and a linear model cannot.
//
export class Filter6581 extends Filter {
    constructor() {
        super(FILTER_CUTOFF_6581);
        this.voiceDC = 0.5;
        this.mixerDC = -1 / 18;
    }

    resonance(res) {
        return 1 / (0.707 + res / 15);
    }
}

// ============================================================================
// FILTER 8580
// ============================================================================

//
// The 8580 has no DC offsets, so $D418 samples are nearly silent on it. Its
// resonance ladder gives 1/Q = 2^((4 - res) / 8) (reSID 1.0, from the die),
// a stronger resonance than the 6581's.
//
export class Filter8580 extends Filter {
    constructor() {
        super(FILTER_CUTOFF_8580);
    }

    resonance(res) {
        return Math.pow(2, (4 - res) / 8);
    }
}
