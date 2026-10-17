
import json
import pytest

from tests.test_utils import call_js_test_with_bytes


class TestSidRegisters:
    """Tests for SID register writes during playback."""

    def test_register_writes_detected(self, sid_player_context, giana_sisters_bytes):
        """Test that SID registers are written to during playback."""
        result = call_js_test_with_bytes(sid_player_context, "testSidRegisterWrites", giana_sisters_bytes, 50)
        
        print(f"Writes detected: {result['totalWrites']}")
        print(f"First few writes: {result['sampleWrites']}")
        print(f"Final PC: {result['pc']:x}")
        
        assert result['totalWrites'] > 0, "No SID register writes detected!"


def test_muted_voice_is_silent_but_keeps_running(sid_player_context):
    from tests.test_utils import eval_json

    result = eval_json(
        sid_player_context,
        """(() => {
            function play(muted) {
                const sid = new SID();
                sid.setChipModel(ChipModel.MOS6581);
                sid.setSamplingParameters(985248, SamplingMethod.DECIMATE, 44100);
                sid.voice[2].muted = muted;
                const buffer = new Int16Array(16384);
                // Turning the volume up steps the 6581's DC level, which thumps
                // whatever the voices do; let that decay first.
                sid.write(0x18, 0x0F, 0);
                sid.clock(200000, buffer, 0);
                // Voice 3: a held sawtooth at full volume.
                for (const [register, value] of [[0x0F, 0x20], [0x13, 0], [0x14, 0xF0], [0x12, 0x21]]) {
                    sid.write(register, value, 200000);
                }
                const count = sid.clock(60000, buffer, 200000);
                let peak = 0;
                for (let i = count / 2; i < count; i++) peak = Math.max(peak, Math.abs(buffer[i]));
                const osc = new Set();
                for (let i = 0; i < 20; i++) {
                    sid.clock(37, buffer, 260000 + i * 37);
                    osc.add(sid.peek(0x1B));
                }
                return { peak, oscValues: osc.size };
            }
            return { audible: play(false), muted: play(true) };
        })()""",
    )
    assert result["audible"]["peak"] > 1000
    assert result["muted"]["peak"] < result["audible"]["peak"] / 20
    # OSC3 still follows the oscillator, so tunes that read it behave the same.
    assert result["muted"]["oscValues"] > 5

