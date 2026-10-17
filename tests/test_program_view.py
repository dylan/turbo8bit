"""The live program view reads BASIC's own bookkeeping out of C64 memory."""

import json

import pytest

from tests.test_utils import (
    JS_STATIC_DIR,
    create_c64_context,
    eval_json,
    load_js_modules,
)

PROGRAM = "\n".join(
    [
        '10 A=5.5:B%=-3:C$="HI":D=-.25:E=1E10:F=1/3:G=123456789:H=.001',
        "15 I=0:J=-1E-5:K=99.5:L=2/3:P=1E9:R=999999999:T=4*ATN(1)",
        "20 DIM N(9):FOR Q=0 TO 9:N(Q)=Q*Q:NEXT",
        '30 DIM S$(2):S$(1)="X"+"Y"',
        "40 DIM M%(2,3):M%(2,3)=7",
        "50 PRINT A:PRINT D:PRINT E:PRINT F:PRINT G:PRINT H:PRINT I",
        "55 PRINT J:PRINT K:PRINT L:PRINT P:PRINT R:PRINT B%",
        "60 GOTO 60",
    ]
)
# T is left out: PRINT rounds 4*ATN(1), stored as 3.14159265347, up to
# 3.14159266, while the view shows the stored value correctly rounded.
PRINTED = ["A", "D", "E", "F", "G", "H", "I", "J", "K", "L", "P", "R", "B%"]


@pytest.fixture(scope="module")
def monitor_context():
    ctx = create_c64_context()
    load_js_modules(ctx, ["basic-tokenizer.js"])
    load_js_modules(ctx, ["lab/basic-monitor.js", "lab/program-view.js"], JS_STATIC_DIR)
    ctx.eval(
        r"""
        function monitorBoot() {
            const machine = new C64Machine({audioEnabled: false});
            for (let i = 0; i < 150; i++) machine.runFrame();
            return machine;
        }
        function monitorType(machine, text) {
            for (const ch of text) {
                while (machine.ram[0xC6] >= 10) machine.runFrame();
                machine.addKey(ch.charCodeAt(0));
                for (let i = 0; i < 3; i++) machine.runFrame();
            }
        }
        function monitorRun(source, frames = 200) {
            const machine = monitorBoot();
            machine.loadProgram(new BASICTokenizer().tokenize(source).bytes);
            monitorType(machine, 'RUN\r');
            for (let i = 0; i < frames; i++) machine.runFrame();
            return machine;
        }
        function monitorTyped(machine, text) {
            monitorType(machine, text);
            for (let i = 0; i < 10; i++) machine.runFrame();
            return machine;
        }
        function monitorLoaded(source) {
            const machine = monitorBoot();
            machine.loadProgram(new BASICTokenizer().tokenize(source).bytes);
            return machine;
        }
        // pressStop() releases the key from a timer; run it after some frames.
        var monitorTimers = [];
        var setTimeout = callback => { monitorTimers.push(callback); return 1; };
        function monitorBreak(machine) {
            machine.pressStop();
            for (let i = 0; i < 10; i++) machine.runFrame();
            for (const release of monitorTimers.splice(0)) release();
            for (let i = 0; i < 30; i++) machine.runFrame();
            return machine;
        }
        function monitorScreenRows(machine) {
            const rows = [];
            for (let row = 0; row < 25; row++) {
                let text = '';
                for (let col = 0; col < 40; col++) {
                    const code = machine.ram[0x400 + row * 40 + col] & 0x7F;
                    text += code >= 1 && code <= 26 ? String.fromCharCode(64 + code)
                        : code >= 32 && code < 64 ? String.fromCharCode(code) : ' ';
                }
                rows.push(text.trim());
            }
            return rows;
        }
        """
    )
    return ctx


@pytest.fixture(scope="module")
def running_program(monitor_context):
    return eval_json(
        monitor_context,
        f"""(() => {{
            const machine = monitorRun({json.dumps(PROGRAM)});
            const {{ variables, arrays }} = readVariables(machine);
            return {{
                line: basicLine(machine),
                variables: variables.map(v => ({{...v, text: formatValue(v.type, v.value)}})),
                arrays,
                lines: programLineNumbers(machine),
                layout: readMemoryLayout(machine),
                programBytes: new BASICTokenizer().tokenize({json.dumps(PROGRAM)}).bytes.length,
                screen: monitorScreenRows(machine)
            }};
        }})()""",
    )


def test_running_line_is_read_from_curlin(running_program):
    assert running_program["line"] == 60


def test_variables_decode_every_type(running_program):
    by_name = {v["name"]: v for v in running_program["variables"]}
    assert by_name["A"]["value"] == 5.5
    assert by_name["A"]["type"] == "float"
    assert by_name["B%"] == {"name": "B%", "type": "integer", "value": -3, "text": "-3"}
    assert by_name["C$"]["value"] == "HI"
    assert by_name["C$"]["text"] == '"HI"'
    assert by_name["D"]["value"] == -0.25
    assert by_name["T"]["text"] == "3.14159265"
    # Variables appear in the order BASIC created them.
    names = [v["name"] for v in running_program["variables"]]
    assert names[:4] == ["A", "B%", "C$", "D"]


def test_numbers_are_formatted_exactly_as_print_shows_them(running_program):
    by_name = {v["name"]: v["text"] for v in running_program["variables"]}
    screen = running_program["screen"]
    start = screen.index("RUN") + 1
    printed = screen[start : start + len(PRINTED)]
    assert printed == [by_name[name] for name in PRINTED]


def test_arrays_decode_dimensions_and_values(running_program):
    arrays = {a["name"]: a for a in running_program["arrays"]}
    assert arrays["N"]["dimensions"] == [9]
    assert arrays["N"]["values"] == [0, 1, 4, 9, 16, 25]
    assert arrays["S$"]["dimensions"] == [2]
    assert arrays["S$"]["values"] == ["", "XY", ""]
    assert arrays["M%"]["type"] == "integer"
    assert arrays["M%"]["dimensions"] == [2, 3]


def test_program_lines_and_memory_layout_follow_the_pointers(running_program):
    assert running_program["lines"] == [10, 15, 20, 30, 40, 50, 55, 60]
    layout = running_program["layout"]
    assert layout["program"] == 0x0801
    # The tokenized file carries a two-byte load address that is not in memory.
    assert (
        layout["variables"] - layout["program"] == running_program["programBytes"] - 2
    )
    simple_variables = len(running_program["variables"])
    assert layout["arrays"] - layout["variables"] == simple_variables * 7
    assert layout["free"] > layout["arrays"]
    # "X"+"Y" built a new string, which lives at the top of memory.
    assert layout["top"] - layout["strings"] == 2


def test_direct_mode_has_no_line(monitor_context):
    result = eval_json(
        monitor_context,
        """(() => {
            const machine = monitorBoot();
            monitorType(machine, 'X=7\\r');
            for (let i = 0; i < 20; i++) machine.runFrame();
            return { line: basicLine(machine), variables: readVariables(machine).variables };
        })()""",
    )
    assert result["line"] is None
    assert result["variables"] == [{"name": "X", "type": "float", "value": 7}]


def test_boot_memory_has_no_layout(monitor_context):
    result = eval_json(
        monitor_context,
        """(() => {
            const machine = new C64Machine({audioEnabled: false});
            machine.runFrame();
            return { layout: readMemoryLayout(machine), lines: programLineNumbers(machine),
                     vars: readVariables(machine) };
        })()""",
    )
    assert result["layout"] is None
    assert result["lines"] == []
    assert result["vars"] == {"variables": [], "arrays": []}


@pytest.mark.parametrize(
    ("setup", "mode", "line", "waiting"),
    [
        # CURLIN reads 0 at the first READY, not direct mode.
        ("monitorBoot()", "ready", 0, True),
        ("monitorTyped(monitorBoot(), 'X=1\\r')", "ready", None, True),
        # END leaves CURLIN on the last line.
        ("monitorRun('10 PRINT 1', 30)", "ready", 10, True),
        ("monitorRun('10 PRINT 1/0', 30)", "ready", 10, True),
        ("monitorBreak(monitorRun('10 GOTO 10', 30))", "ready", 10, True),
        # END, STOP and BREAK leave FOR and GOSUB frames on the stack for
        # CONT, so READY's own frame sits lower down.
        (
            "monitorBreak(monitorRun('10 FOR I=1 TO 30000:NEXT', 30))",
            "ready",
            10,
            True,
        ),
        ("monitorRun('10 GOSUB 100\\n20 END\\n100 END', 30)", "ready", 100, True),
        (
            "monitorRun('10 FOR I=1 TO 9\\n20 IF I=5 THEN END\\n30 NEXT', 30)",
            "ready",
            20,
            True,
        ),
        (
            "monitorRun('10 FOR I=1 TO 9:IF I=3 THEN STOP\\n20 NEXT', 30)",
            "ready",
            10,
            True,
        ),
        # CONT carries on from a STOP inside a FOR loop.
        (
            "monitorTyped(monitorRun('10 FOR I=1 TO 1:STOP:NEXT\\n20 GOTO 20', 30),"
            " 'CONT\\r')",
            "program",
            20,
            False,
        ),
        ("monitorRun('10 INPUT A$', 30)", "program", 10, True),
        ("monitorRun('10 GOTO 10', 30)", "program", 10, False),
        ("monitorRun('10 GET K$:IF K$=\"\" THEN 10', 30)", "program", 10, False),
        # GOTO and CONT start a program without RUN.
        (
            "monitorTyped(monitorLoaded('10 GOTO 10'), 'GOTO 10\\r')",
            "program",
            10,
            False,
        ),
        (
            "monitorTyped(monitorBoot(), 'FOR I=1 TO 9999:NEXT\\r')",
            "direct",
            None,
            False,
        ),
    ],
)
def test_basic_activity_tells_ready_from_running(
    monitor_context, setup, mode, line, waiting
):
    result = eval_json(
        monitor_context,
        f"""(() => {{
            const machine = {setup};
            // Sample as the view does, but not inside the KERNAL's IRQ handler.
            for (let i = 0; i < 50; i++) {{
                machine.runFrame();
                const pc = machine.cpu.PC;
                if (pc < 0xEA31 || pc > 0xEB42) break;
            }}
            return basicActivity(machine);
        }})()""",
    )
    assert result == {"mode": mode, "line": line, "waiting": waiting}


def test_typing_a_command_after_a_stop_never_looks_like_the_program(
    monitor_context,
):
    # Every instruction from READY, through typing, reading and running a
    # direct command, and back to READY. After STOP inside a FOR loop,
    # CURLIN still names the program's line the whole time.
    result = eval_json(
        monitor_context,
        """(() => {
            const machine = monitorBreak(monitorRun('10 FOR I=1 TO 30000:NEXT', 30));
            const keys = [...'X=12345\\r'];
            const modes = {};
            let idle = 0;
            for (let steps = 0; steps < 100000 && idle < 2000; steps++) {
                if (keys.length && machine.ram[0xC6] < 4) machine.addKey(keys.shift().charCodeAt(0));
                machine.step();
                const activity = basicActivity(machine);
                modes[activity.mode] = (modes[activity.mode] || 0) + 1;
                idle = !keys.length && machine.ram[0xC6] === 0 && activity.mode === 'ready'
                    ? idle + 1 : 0;
            }
            const x = readVariables(machine).variables.find(v => v.name === 'X');
            return { modes, x: x && x.value, idle };
        })()""",
    )
    assert result["x"] == 12345
    assert result["idle"] >= 2000
    assert set(result["modes"]) == {"ready", "direct"}


def test_a_running_program_never_looks_like_ready(monitor_context):
    # Line 42117 is $A485, the READY frame's return address, so FOR and
    # GOSUB frames from it hold those bytes; the float arithmetic leaves its
    # workings on the stack too.
    program = "\n".join(
        [
            "10 GOTO 42117",
            "42117 FOR J=1 TO 1E9:X=SIN(J)*COS(J)/(J+.5)+SQR(J):GOSUB 50000:NEXT",
            "50000 Y=(X*3.3+ATN(X))/(1+X*X):RETURN",
        ]
    )
    result = eval_json(
        monitor_context,
        f"""(() => {{
            const machine = monitorRun({json.dumps(program)}, 5);
            const modes = {{}};
            for (let steps = 0; steps < 60000; steps++) {{
                machine.step();
                const mode = basicActivity(machine).mode;
                modes[mode] = (modes[mode] || 0) + 1;
            }}
            return modes;
        }})()""",
    )
    assert result == {"program": 60000}


def test_ready_and_input_wait_in_the_key_loop(monitor_context):
    result = eval_json(
        monitor_context,
        """(() => {
            const inLoop = pc => pc >= KEY_WAIT_FIRST && pc <= KEY_WAIT_LAST;
            const count = machine => {
                let hits = 0;
                for (let i = 0; i < 50; i++) {
                    machine.runFrame();
                    if (inLoop(machine.cpu.PC)) hits++;
                }
                return hits;
            };
            const ready = count(monitorBoot());
            const machine = monitorRun('10 INPUT A$\\n20 GOTO 20', 30);
            const waiting = count(machine);
            const line = basicLine(machine);
            const busy = count(monitorRun('10 GOTO 10', 30));
            return { ready, waiting, line, busy };
        })()""",
    )
    assert result["ready"] > 40
    assert result["waiting"] > 40
    assert result["line"] == 10
    assert result["busy"] == 0


@pytest.mark.parametrize(
    ("value", "text"),
    [
        (0, "0"),
        (0.5, ".5"),
        (-0.5, "-.5"),
        (1e9, "1E+09"),
        (1.5e-7, "1.5E-07"),
        (123456789, "123456789"),
        (0.01, ".01"),
    ],
)
def test_format_basic_number(monitor_context, value, text):
    assert monitor_context.eval(f"formatBasicNumber({value})") == text


def test_decode_float_handles_zero_and_sign(monitor_context):
    result = eval_json(
        monitor_context,
        "[decodeFloat([0, 0x80, 0, 0, 0]), decodeFloat([0x81, 0, 0, 0, 0]),"
        " decodeFloat([0x81, 0x80, 0, 0, 0]), decodeFloat([0x83, 0x30, 0, 0, 0])]",
    )
    assert result == [0, 1, -1, 5.5]


def test_editor_line_map_follows_c64_line_entry(monitor_context):
    result = eval_json(
        monitor_context,
        "Object.fromEntries(editorLineMap("
        "'10 PRINT 1\\r\\n20 GOTO 10\\n10 PRINT 2\\n  30 END\\n20\\nREM'))",
    )
    assert result == {"10": 3, "30": 4}


def test_line_profiler_shares_and_heat(monitor_context):
    result = eval_json(
        monitor_context,
        """(() => {
            const profiler = new LineProfiler();
            profiler.sample(10, 3);
            profiler.sample(20, 1);
            const top = profiler.top(5);
            const heat = Object.fromEntries(profiler.heat());
            profiler.reset();
            return { top, heat, empty: profiler.top(5) };
        })()""",
    )
    assert result["top"] == [{"line": 10, "share": 0.75}, {"line": 20, "share": 0.25}]
    assert result["heat"] == {"10": 1, "20": pytest.approx(1 / 3)}
    assert result["empty"] == []


@pytest.fixture
def view_context(monitor_context):
    monitor_context.eval(
        r"""
        function fakeElement(tag) {
            const element = {
                tag, innerHTML: '', textContent: '', hidden: false, open: true,
                dataset: {}, attributes: {}, children: [], listeners: {}, found: {},
                style: { setProperty() {}, removeProperty() {} },
                classList: { toggle() {}, add() {}, remove() {} },
                setAttribute(name, value) { this.attributes[name] = value; },
                addEventListener(name, listener) { this.listeners[name] = listener; },
                replaceChildren(...nodes) { this.children = nodes; },
                querySelector(selector) { return this.found[selector] ||= fakeElement(selector); },
                animate() { this.flashes = (this.flashes || 0) + 1; }
            };
            element.firstChild = tag === 'tr' ? fakeElement('th') : null;
            element.lastChild = tag === 'tr' ? fakeElement('td') : null;
            return element;
        }
        var document = { createElement: fakeElement };
        function viewHarness(source, frames) {
            const machine = monitorRun(source, frames);
            const emulator = {
                machine, bootGeneration: 1, basicReady: true, bootError: null,
                isPaused: () => false,
                onFrame(listener) { this.frameListener = listener; },
                onStateChange() {}
            };
            const editor = {
                text: source,
                getValue() { return this.text; },
                onValueChange(listener) { this.changed = listener; },
                setLineActivity(running, heat) { this.running = running; this.heat = heat; }
            };
            const root = fakeElement('details');
            const view = new ProgramView(emulator, editor, root);
            return { machine, emulator, editor, root, view };
        }
        """
    )
    return monitor_context


def test_program_view_marks_running_line_and_variables(view_context):
    result = eval_json(
        view_context,
        """(() => {
            const source = '10 X=0\\n20 X=X+1:GOTO 20';
            const h = viewHarness(source, 30);
            for (let i = 0; i < 20; i++) {
                h.machine.runFrame();
                h.emulator.frameListener(1);
            }
            h.view.refresh();
            const xBefore = h.view.rows.get('X').text;
            for (let i = 0; i < 5; i++) h.machine.runFrame();
            h.view.refresh();
            const row = h.view.rows.get('X');
            return {
                running: h.editor.running,
                heat: Object.fromEntries(h.editor.heat),
                badge: h.view.stateBadge.textContent,
                now: h.view.nowText.textContent,
                changed: row.text !== xBefore,
                flashes: row.row.flashes || 0,
                name: row.name.textContent,
                memoryLabel: h.view.memoryBar.attributes['aria-label']
            };
        })()""",
    )
    assert result["running"] == 2
    assert result["heat"] == {"2": 1}
    assert result["badge"] == "RUNNING · LINE 20"
    assert result["now"] == "20 X=X+1:GOTO 20"
    assert result["changed"]
    assert result["flashes"] >= 1
    assert result["name"] == "X"
    assert "variables 7" in result["memoryLabel"]


def test_program_view_does_not_mark_an_unrelated_editor(view_context):
    result = eval_json(
        view_context,
        """(() => {
            const h = viewHarness('10 GOTO 10', 30);
            h.editor.text = '100 PRINT "SOMETHING ELSE"';
            h.editor.changed(h.editor.text);
            h.emulator.frameListener(1);
            h.view.refresh();
            return { running: h.editor.running, heat: h.editor.heat.size,
                     now: h.view.nowText.textContent };
        })()""",
    )
    assert result["running"] is None
    assert result["heat"] == 0
    assert result["now"] == "Line 10"
