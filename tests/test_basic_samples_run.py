"""Every BASIC sample runs on the real C64 without a BASIC error."""

import json

import pytest

from tests.test_utils import STATIC_DIR, create_c64_context, eval_json, load_js_modules

EXAMPLES = json.loads(
    (STATIC_DIR / "basic" / "index.json").read_text(encoding="utf-8")
)["examples"]


@pytest.fixture(scope="module")
def basic_context():
    ctx = create_c64_context()
    load_js_modules(ctx, ["basic-tokenizer.js"])
    ctx.eval(
        """
        function sampleScreen(machine) {
            const rows = [];
            for (let row = 0; row < 25; row++) {
                let text = '';
                for (let col = 0; col < 40; col++) {
                    const code = machine.ram[0x400 + row * 40 + col] & 0x7F;
                    text += code >= 1 && code <= 26 ? String.fromCharCode(64 + code)
                        : code >= 32 && code < 64 ? String.fromCharCode(code) : ' ';
                }
                rows.push(text);
            }
            return rows.join('\\n');
        }
        function runSample(source, direct) {
            const machine = new C64Machine({audioEnabled: false});
            for (let i = 0; i < 150; i++) machine.runFrame();
            let errors = [];
            let text = 'RUN\\r';
            if (direct) {
                text = expandControlCodes(source).replace(/\\r?\\n/g, '\\r') + '\\r';
            } else {
                const result = new BASICTokenizer().tokenize(source);
                errors = result.errors.filter(e => e.type === 'error').map(e => e.message);
                machine.loadProgram(result.bytes);
            }
            for (const ch of text) {
                while (machine.ram[0xC6] >= 10) machine.runFrame();
                machine.addKey(ch.charCodeAt(0));
                for (let i = 0; i < 3; i++) machine.runFrame();
            }
            for (let i = 0; i < 250; i++) machine.runFrame();
            return { errors, screen: sampleScreen(machine) };
        }
        """
    )
    return ctx


@pytest.mark.parametrize("example", EXAMPLES, ids=[e["id"] for e in EXAMPLES])
def test_sample_runs_without_basic_errors(basic_context, example):
    source = (STATIC_DIR / "basic" / example["file"]).read_text(encoding="utf-8")
    result = eval_json(
        basic_context,
        f"runSample({json.dumps(source)}, {json.dumps(bool(example.get('direct')))})",
    )
    assert result["errors"] == []
    assert "ERROR" not in result["screen"], result["screen"]
