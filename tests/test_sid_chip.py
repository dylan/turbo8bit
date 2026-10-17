"""SID chip accuracy: envelope, noise, filter, mixer and resampling.

Each case was a real fault in the emulation; the comments say what a real chip
does that the case checks for.
"""

import json

from tests.test_utils import eval_json


def test_envelope_counter_wraps_within_eight_bits(sid_player_context):
    # A gate pulse that ends attack before its first step leaves the counter
    # enabled at zero, so the next release step wraps it to 0xff and it counts
    # down from there (the "ADSR bug"). It must not go negative.
    result = eval_json(
        sid_player_context,
        """(() => {
            const sid = new SID();
            const buffer = new Int16Array(64);
            const envelope = sid.voice[0].envelope();
            sid.write(0x05, 0x00, 0);
            sid.write(0x06, 0x00, 0);
            sid.clock(1, buffer, 0);
            sid.write(0x04, 0x01, 1);
            sid.clock(2, buffer, 1);
            sid.write(0x04, 0x00, 3);
            const trace = [];
            for (let cycle = 3; cycle < 403; cycle++) {
                sid.clock(1, buffer, cycle);
                trace.push(envelope.envelopeCounter);
            }
            return {low: Math.min(...trace), high: Math.max(...trace), last: trace[trace.length - 1]};
        })()""",
    )
    assert result["low"] >= 0
    assert result["high"] == 0xFF
    assert 0 < result["last"] < 0xFF, "after wrapping, release keeps counting down"


def test_tune_envelopes_stay_in_hardware_range(sid_player_context, cybernoid_bytes):
    # Cybernoid's player trips the envelope wrap within its first frames.
    sid_player_context.eval(f"var cybernoidBytes = {json.dumps(cybernoid_bytes)};")
    result = eval_json(
        sid_player_context,
        """(() => {
            const machine = new C64Machine({audioEnabled: true});
            loadSidTune(machine, new Uint8Array(cybernoidBytes).buffer);
            const audio = new Int16Array(2048);
            let low = 0, high = 0;
            for (let frame = 0; frame < 100; frame++) {
                machine.runFrame(audio);
                for (const voice of machine.sid.voice) {
                    low = Math.min(low, voice.envelope().envelopeCounter);
                    high = Math.max(high, voice.envelope().envelopeCounter);
                }
            }
            return {low, high};
        })()""",
    )
    assert 0 <= result["low"] and result["high"] <= 0xFF


def test_harmonics_above_nyquist_do_not_fold_back(sid_player_context):
    result = eval_json(
        sid_player_context,
        """(() => {
            const sid = new SID();
            sid.setChipModel(ChipModel.MOS8580);
            sid.setSamplingParameters(985248, SamplingMethod.DECIMATE, 44100);
            // Voice 1: the highest-pitched sawtooth, about 3848 Hz.
            for (const [register, value] of [[0x00, 0xff], [0x01, 0xff], [0x05, 0x00],
                [0x06, 0xf0], [0x04, 0x21], [0x18, 0x0f]]) {
                sid.write(register, value, 0);
            }
            const buffer = new Int16Array(32768);
            const count = sid.clock(700000, buffer, 0);
            const samples = buffer.subarray(count - 8192, count);
            function magnitude(frequency) {
                let re = 0, im = 0;
                for (let i = 0; i < samples.length; i++) {
                    const window = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / (samples.length - 1));
                    const phase = 2 * Math.PI * frequency * i / 44100;
                    re += samples[i] * window * Math.cos(phase);
                    im -= samples[i] * window * Math.sin(phase);
                }
                return Math.hypot(re, im);
            }
            const fundamental = 0xffff * 985248 / 16777216;
            const dB = frequency => 20 * Math.log10(magnitude(frequency) / magnitude(fundamental));
            // The 8th harmonic lies above 22.05 kHz; unless it is removed before
            // decimation it folds back to 44.1 kHz minus its frequency.
            return {third: dB(3 * fundamental), alias: dB(44100 - 8 * fundamental)};
        })()""",
    )
    # A sawtooth's third harmonic is a third of the fundamental (-9.5 dB),
    # less a little from the C64's 16 kHz output filter.
    assert -13 < result["third"] < -9
    assert result["alias"] < -80


def test_resampler_passband_is_flat_and_stopband_is_quiet(sid_player_context):
    result = eval_json(
        sid_player_context,
        """(() => {
            function level(frequency) {
                const resampler = new SidResampler(985248, 44100);
                const output = [];
                for (let n = 0; n < 250000; n++) {
                    if (resampler.input(Math.sin(2 * Math.PI * frequency * n / 985248))) {
                        output.push(resampler.output);
                    }
                }
                const tail = output.slice(output.length >> 1);
                const rms = Math.sqrt(tail.reduce((total, value) => total + value * value, 0) / tail.length);
                return 20 * Math.log10(rms / Math.SQRT1_2 + 1e-12);
            }
            return {passband: [100, 1000, 10000, 19000].map(level),
                stopband: [25000, 30000, 50000, 100000, 300000].map(level)};
        })()""",
    )
    assert all(abs(level) < 0.1 for level in result["passband"]), result
    assert all(level < -90 for level in result["stopband"]), result


def test_resonance_peaks_at_cutoff_without_cutting_the_passband(sid_player_context):
    result = eval_json(
        sid_player_context,
        """(() => {
            function peak(resonance, frequency) {
                const sid = new SID();
                sid.setChipModel(ChipModel.MOS8580);
                sid.setSamplingParameters(985248, SamplingMethod.DECIMATE, 44100);
                const freq = Math.round(frequency * 16777216 / 985248);
                // Voice 1, a triangle, through the low-pass filter at 3.3 kHz.
                for (const [register, value] of [[0x00, freq & 0xff], [0x01, freq >> 8],
                    [0x05, 0x00], [0x06, 0xf0], [0x04, 0x11], [0x15, 0x00], [0x16, 0x40],
                    [0x17, (resonance << 4) | 0x01], [0x18, 0x1f]]) {
                    sid.write(register, value, 0);
                }
                const buffer = new Int16Array(16384);
                const count = sid.clock(200000, buffer, 0);
                let level = 0;
                for (let i = count >> 1; i < count; i++) level = Math.max(level, Math.abs(buffer[i]));
                return level;
            }
            return {passband: peak(15, 200) / peak(0, 200), cutoff: peak(15, 3300) / peak(0, 3300)};
        })()""",
    )
    # 8580 Q runs from 0.707 to 2.59: the response at cutoff rises about 3.7
    # times while well below cutoff the level stays put.
    assert 0.9 < result["passband"] < 1.1
    assert result["cutoff"] > 3


def test_test_bit_revives_noise_cleared_by_a_combined_waveform(sid_player_context):
    result = eval_json(
        sid_player_context,
        """(() => {
            const sid = new SID();
            const buffer = new Int16Array(4096);
            let cycle = 0;
            const run = cycles => { sid.clock(cycles, buffer, cycle); cycle += cycles; };
            const distinctOsc3 = cycles => {
                const values = new Set();
                for (let i = 0; i < cycles; i += 16) { run(16); values.add(sid.peek(0x1b)); }
                return values.size;
            };
            // Voice 3 at full rate, noise combined with a pulse held low: the
            // combined output feeds zeros back into the noise register.
            for (const [register, value] of [[0x0e, 0xff], [0x0f, 0xff], [0x10, 0xff],
                [0x11, 0x0f], [0x12, 0xc0]]) {
                sid.write(register, value, 0);
            }
            run(20000);
            const cleared = sid.voice[2].wave().shiftRegister;
            sid.write(0x12, 0x80, cycle);
            const silent = distinctOsc3(4000);
            sid.write(0x12, 0x88, cycle);
            run(100);
            sid.write(0x12, 0x80, cycle);
            return {cleared, silent, revived: distinctOsc3(4000)};
        })()""",
    )
    assert result["cleared"] == 0
    assert result["silent"] == 1
    # Releasing test shifts a one in, so the noise runs again.
    assert result["revived"] > 10


def test_volume_register_samples_play_on_6581_but_not_8580(sid_player_context):
    # The 6581's voices sit on a DC level that the volume register scales, so
    # writing $D418 alone makes sound; the 8580 has no such offsets.
    result = eval_json(
        sid_player_context,
        """(() => {
            function peak(model) {
                const sid = new SID();
                sid.setChipModel(model);
                sid.setSamplingParameters(985248, SamplingMethod.DECIMATE, 44100);
                for (let step = 0; step * 493 < 200000; step++) {
                    sid.write(0x18, step & 1 ? 0x0f : 0x00, step * 493);
                }
                const buffer = new Int16Array(16384);
                const count = sid.clock(200000, buffer, 0);
                let level = 0;
                for (let i = count >> 1; i < count; i++) level = Math.max(level, Math.abs(buffer[i]));
                return level;
            }
            return {mos6581: peak(ChipModel.MOS6581), mos8580: peak(ChipModel.MOS8580)};
        })()""",
    )
    assert result["mos6581"] > 5000
    assert result["mos8580"] < 500


def test_three_full_voices_mix_without_clipping(sid_player_context):
    # Superposition: the three voices together equal the sum of each alone.
    # Ungated voices leak through the envelope DAC, so the all-gates-off
    # render is counted out of the single-voice sums.
    result = eval_json(
        sid_player_context,
        """(() => {
            const pitches = [[0x0f, 0x11], [0x17, 0x23], [0x1d, 0x4c]];
            function render(gates) {
                const sid = new SID();
                sid.setChipModel(ChipModel.MOS8580);
                sid.setSamplingParameters(985248, SamplingMethod.DECIMATE, 44100);
                pitches.forEach(([high, low], voice) => {
                    const base = voice * 7;
                    for (const [offset, value] of [[0, low], [1, high], [3, 0x08], [5, 0x00], [6, 0xf0]]) {
                        sid.write(base + offset, value, 0);
                    }
                    sid.write(base + 4, gates[voice] ? 0x41 : 0x40, 0);
                });
                sid.write(0x18, 0x0f, 0);
                const buffer = new Int16Array(16384);
                const count = sid.clock(300000, buffer, 0);
                return Array.from(buffer.subarray(count >> 1, count));
            }
            const singles = [[1, 0, 0], [0, 1, 0], [0, 0, 1]].map(render);
            const leak = render([0, 0, 0]);
            const together = render([1, 1, 1]);
            let peak = 0, error = 0;
            together.forEach((value, i) => {
                peak = Math.max(peak, Math.abs(value));
                const sum = singles[0][i] + singles[1][i] + singles[2][i] - 2 * leak[i];
                error = Math.max(error, Math.abs(value - sum));
            });
            return {peak, error};
        })()""",
    )
    # Three full square waves in step reach about -3 dBFS, below the limiter.
    assert 20000 < result["peak"] < 28000
    assert result["error"] <= 4
