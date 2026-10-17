"""The hardware page animates real bus traffic recorded from the emulator."""

import json

import pytest

from tests.test_utils import (
    JS_STATIC_DIR,
    create_mini_racer_context,
    eval_json,
    load_js_modules,
)


@pytest.fixture(scope="module")
def trace_context():
    ctx = create_mini_racer_context()
    load_js_modules(
        ctx,
        [
            "roms.js",
            "voice.js",
            "filter.js",
            "sid.js",
            "mos6510.js",
            "vic-ii.js",
            "machine.js",
            "assembler.js",
        ],
    )
    load_js_modules(ctx, ["bus-trace.js"], JS_STATIC_DIR)
    return ctx


def trace(ctx, name):
    return json.loads(
        ctx.eval(f"JSON.stringify(SCENARIO_TRACES[{json.dumps(name)}]())")
    )


def test_pla_decoding_follows_the_banking_bits(trace_context):
    result = eval_json(
        trace_context,
        """(() => {
            const m = new C64Machine({audioEnabled: false});
            const at = (address, write = false) => chipFor(m, address, write);
            const standard = [at(0xA000), at(0xD020), at(0xD400), at(0xD800), at(0xDC00),
                              at(0xDD00), at(0xE000), at(0xA000, true), at(0x0001)];
            m.write(1, 0x30);
            return { standard, allRam: [at(0xA000), at(0xD020), at(0xE000)] };
        })()""",
    )
    assert result["standard"] == [
        "BASIC ROM",
        "VIC-II",
        "SID",
        "Colour RAM",
        "CIA 1",
        "CIA 2",
        "KERNAL ROM",
        "RAM",
        "CPU port",
    ]
    assert result["allRam"] == ["RAM", "RAM", "RAM"]


def test_recording_restores_the_machine(trace_context):
    result = eval_json(
        trace_context,
        """(() => {
            const m = new C64Machine({audioEnabled: false});
            m.loadCode([0xA9, 0x05, 0x8D, 0x20, 0xD0], 0xC000);
            m.cpu.PC = 0xC000;
            m.cpu.P |= 4;
            const events = recordAccesses(m, () => { m.step(); m.step(); });
            const own = (object, name) => Object.prototype.hasOwnProperty.call(object, name);
            return {
                events: events.map(e => [e.op, e.address, e.value, e.chip]),
                restored: !own(m, 'read') && !own(m, 'write') && !own(m.cpu, 'step'),
                border: m.peek(0xD020) & 15
            };
        })()""",
    )
    assert result["events"] == [
        ["read", 0xC000, 0xA9, "RAM"],
        ["read", 0xC001, 0x05, "RAM"],
        ["read", 0xC002, 0x8D, "RAM"],
        ["read", 0xC003, 0x20, "RAM"],
        ["read", 0xC004, 0xD0, "RAM"],
        ["write", 0xD020, 0x05, "VIC-II"],
    ]
    assert result["restored"] is True
    assert result["border"] == 5


def test_boot_trace_tells_the_real_start_up_story(trace_context):
    steps = trace(trace_context, "boot")
    first = steps[0]
    assert (first["op"], first["address"], first["chip"]) == (
        "read",
        0xFFFC,
        "KERNAL ROM",
    )
    assert first["value"] | (steps[1]["value"] << 8) == 0xFCE2
    texts = [step.get("note", "") for step in steps]
    assert any("autostart cartridge" in note for note in texts)
    assert any("RAM for BASIC ends at $9FFF" in note for note in texts)
    assert any("BASIC takes over" in note for note in texts)
    jump = next(s for s in steps if "BASIC takes over" in s.get("note", ""))
    assert jump["instruction"].endswith("JMP ($A000)")
    banner = [
        s["value"]
        for s in steps
        if s["chip"] == "RAM" and 0x42C <= s["address"] < 0x440
    ]
    assert banner[:4] == [42, 42, 42, 42]  # ****


def test_keypress_trace_scans_the_matrix_then_buffers_and_prints(trace_context):
    steps = trace(trace_context, "typing")
    assert steps[0]["address"] == 0xFFFE and steps[0]["instruction"].startswith(
        "Interrupt"
    )
    scan = [(s["op"], s["address"], s["value"]) for s in steps if s["chip"] == "CIA 1"]
    # Line 1 driven low ($FD) reports A's column, bit 2, as $FB.
    line1 = scan.index(("write", 0xDC00, 0xFD))
    assert scan[line1 + 1] == ("read", 0xDC01, 0xFB)
    buffered = next(s for s in steps if s["address"] == 0x0277)
    assert buffered["value"] == 0x41  # PETSCII A
    printed = next(
        s for s in steps if 0x0400 <= s["address"] < 0x07E8 and s["op"] == "write"
    )
    assert printed["value"] == 0x01  # screen code A
    assert steps[-1]["chip"] == "Colour RAM"


def test_screen_row_trace_reads_codes_then_glyphs(trace_context):
    steps = trace(trace_context, "vic")
    assert len(steps) == 16
    assert all(s["who"] == "VIC" for s in steps)
    assert [s["chip"] for s in steps[:2]] == ["RAM", "Character ROM"]
    glyph = trace_context.eval(f"rom_chars[{steps[0]['value']} * 8]")
    assert steps[1]["value"] == glyph


def test_sound_trace_writes_the_sid_registers_in_program_order(trace_context):
    steps = trace(trace_context, "sound")
    writes = [(s["address"], s["value"]) for s in steps if s["op"] == "write"]
    assert writes == [(0xD418, 0x0F), (0xD405, 0x09), (0xD401, 0x22), (0xD404, 0x11)]
    assert all(s["chip"] == "RAM" for s in steps if s["op"] == "read")
