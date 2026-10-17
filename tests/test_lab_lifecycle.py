"""Verify browser-wrapper boot/load contracts against the actual C64 machine."""

import re

import pytest

from tests.test_utils import (
    PROJECT_ROOT,
    create_crt_context,
    load_js_file,
    load_js_modules,
    strip_es6_imports_exports,
)


@pytest.fixture
def lab():
    ctx = create_crt_context()
    ctx.eval(
        """
        var document = {
            getElementById() {
                return { getContext() { return {}; } };
            }
        };
        var requestAnimationFrame = () => 1;
        var cancelAnimationFrame = () => {};
        performance.now = () => 0;
        """
    )
    load_js_modules(ctx, ["emulator.js"])
    ctx.eval(
        """
        var emulator = new C64Emulator('screen', { audioEnabled: false });
        function bootUntilReady() {
            let frames = 0;
            while (!emulator.basicReady && frames < 1000) {
                emulator.machine.runFrame();
                emulator.frame++;
                emulator.checkBasicReady();
                frames++;
            }
            return frames;
        }
        """
    )
    return ctx


@pytest.fixture
def lab_document(lab):
    ctx = lab
    ctx.eval(
        """
        var elements = new Map();
        document.getElementById = function(id) {
            if (!elements.has(id)) elements.set(id, {
                value: '', textContent: '', listeners: {},
                classList: { add() {}, remove() {}, toggle() {} },
                style: { setProperty() {} },
                getContext() { return {}; },
                addEventListener(name, listener) { (this.listeners[name] ||= []).push(listener); },
                setAttribute() {},
                scrollIntoView() {},
                focus() {}
            });
            return elements.get(id);
        };
        document.addEventListener = () => {};
        document.querySelector = selector => document.getElementById(selector);
        document.querySelectorAll = () => [];
        var setTimeout = () => 1;
        var clearTimeout = () => {};
        var alert = message => { throw new Error(message); };
        var confirmations = [];
        var confirmAnswer = true;
        var confirm = message => { confirmations.push(message); return confirmAnswer; };
        var CodeEditor = class {
            constructor() { this.value = ''; this.shownErrors = []; this.listeners = []; }
            getValue() { return this.value; }
            setValue(value) {
                this.value = value;
                for (const listener of this.listeners) listener(value);
            }
            onValueChange(listener) { this.listeners.push(listener); }
            tokenize() { return new BASICTokenizer().tokenize(this.value); }
            setHighlightErrors() {}
            clearHighlight() {}
            highlightLine() {}
            showErrors(errors) { this.shownErrors = errors; }
            showInfo(message) { this.info = message; }
        };
        var ExampleLibrary = class {
            async populate() {}
            all() { return [{ id: 'loop', demo: true }, { id: 'direct', direct: true }]; }
            get(id) { return { direct: id === 'direct' }; }
            async select(id) {
                return { example: this.get(id), source: id === 'direct' ? 'PRINT 1' : '10 END' };
            }
        };
        // Page tools that only arrange DOM are covered by their own tests.
        var attachScreenTools = () => {};
        var restoredProgram = null;
        var attachProgramFiles = () => ({ restore: async () => restoredProgram });
        var attachProgramView = () => ({});
        var galleries = [];
        var SampleGallery = class {
            constructor(root, options) { this.options = options; this.active = null; galleries.push(this); }
            setActive(id) { this.active = id; }
        };
        var DemoReel = class {
            constructor(options) { this.options = options; this.ids = []; this.active = false; }
            start() { this.active = true; }
            next() {}
            stop() { this.active = false; }
        };
        var MemoryViewer = class {
            constructor() { this.refreshes = 0; }
            refresh() { this.refreshes++; }
            setAddress(address) { this.address = address; }
        };
        """
    )
    load_js_modules(ctx, ["basic-tokenizer.js"])
    return ctx


def load_lab_page(ctx, filename):
    template = load_js_file(PROJECT_ROOT / "web" / "templates" / filename)
    script = re.search(r'<script type="module">\s*(.*?)</script>', template, re.DOTALL)
    assert script is not None
    ctx.eval(strip_es6_imports_exports(script.group(1)))


@pytest.fixture
def basic_page(lab_document):
    ctx = lab_document
    load_lab_page(ctx, "index.html")
    ctx.eval(
        """
        var program = new Uint8Array([1, 8, 7, 8, 10, 0, 0x80, 0, 0, 0]);
        var compiled = { bytes: program, errors: [] };
        """
    )
    return ctx


@pytest.fixture
def asm_page(lab_document):
    ctx = lab_document
    load_js_modules(ctx, ["assembler.js", "debugger.js"])
    load_lab_page(ctx, "asm.html")
    ctx.eval("bootUntilReady(); emulator.pause(); emulator.machine.cpu.P |= 4;")
    return ctx


@pytest.fixture
def games_page(lab_document):
    """The Assembly Lab with the options games.html gives it."""
    ctx = lab_document
    load_js_modules(ctx, ["assembler.js", "debugger.js"])
    ctx.eval(
        """
        document.getElementById('asmLab').dataset = {
            joystick: '2', resetOnRun: '', soundOnRun: ''
        };
        // Pressing the sound button turns the sound on.
        var soundPresses = 0;
        document.getElementById('muteBtn').click = () => {
            soundPresses++;
            emulator.audioEnabled = true;
        };
        """
    )
    load_lab_page(ctx, "asm.html")
    ctx.eval(
        """
        bootUntilReady();
        var focused = false;
        emulator.canvas.focus = () => { focused = true; };
        examples.select = async id => ({
            example: {}, source: 'ORG $C000\\nLOOP INC $D020\\n    JMP LOOP'
        });
        """
    )
    return ctx


def test_prg_dropped_during_startup_is_loaded_after_ram_initialization(lab):
    ctx = lab
    ctx.eval(
        """
        var loaded = false;
        var program = new Uint8Array([1, 8, 7, 8, 10, 0, 0x80, 0, 0, 0]);
        emulator.loadPrgFile(program).then(() => { loaded = true; });
        """
    )
    assert not ctx.eval("loaded")
    assert ctx.eval("bootUntilReady()") < 1000
    assert ctx.eval("loaded && emulator.basicReady")
    assert ctx.eval("emulator.machine.peek(0x0805)") == 0x80
    assert ctx.eval("emulator.machine.peek(0x0801)") == 7
    # LOAD leaves the variable pointers after the program, then it is RUN.
    for pointer in (0x2D, 0x2F, 0x31):
        assert ctx.eval(f"emulator.machine.ram[{pointer}]") == 0x09
        assert ctx.eval(f"emulator.machine.ram[{pointer + 1}]") == 0x08
    assert (
        ctx.eval(
            "String.fromCharCode(...emulator.machine.ram.slice(0x277, 0x277 + emulator.machine.ram[0xC6]))"
        )
        == "RUN\r"
    )


def test_machine_code_prg_is_loaded_without_touching_basic(lab):
    ctx = lab
    ctx.eval(
        """
        bootUntilReady();
        var info = null;
        var vartab = emulator.machine.ram[0x2d] | (emulator.machine.ram[0x2e] << 8);
        emulator.loadPrgFile(new Uint8Array([0x00, 0xC0, 0xEE, 0x20, 0xD0, 0x60]))
            .then(result => { info = result; });
        """
    )
    assert ctx.eval("JSON.stringify(info)") == (
        '{"loadAddress":49152,"endAddress":49156,"basic":false}'
    )
    assert ctx.eval("emulator.machine.peek(0xC002)") == 0xD0
    assert ctx.eval(
        "(emulator.machine.ram[0x2d] | (emulator.machine.ram[0x2e] << 8)) === vartab"
    )
    assert ctx.eval("emulator.machine.ram[0xC6]") == 0


def test_return_to_basic_recovers_from_halt_banking_and_interrupt_changes(lab):
    ctx = lab
    ctx.eval("bootUntilReady();")
    ctx.eval(
        """
        emulator.machine.write(0xd01a, 1);
        emulator.machine.write(0xdc0d, 0x81);
        emulator.machine.write(0xdd0d, 0x82);
        emulator.machine.ram[0x0314] = 0xff;
        emulator.machine.ram[0x0315] = 0xff;
        emulator.machine.write(1, 0x30);
        emulator.machine.cpu.halted = true;
        emulator.pause();
        var returned = false;
        emulator.resetToBasic().then(() => { returned = true; });
        """
    )
    assert not ctx.eval("emulator.paused")
    assert not ctx.eval("emulator.machine.cpu.halted")
    assert ctx.eval("bootUntilReady()") < 1000
    assert ctx.eval("returned && emulator.basicReady")


def test_numbered_editor_run_always_loads_into_a_fresh_ready_machine(basic_page):
    ctx = basic_page
    ctx.eval(
        """
        bootUntilReady();
        emulator.machine.ram[0xc000] = 0xaa;
        var generation = emulator.bootGeneration;
        var loaded = false;
        loadBasicProgram(compiled).then(() => { loaded = true; });
        """
    )
    assert not ctx.eval("loaded || emulator.basicReady")
    assert ctx.eval("emulator.bootGeneration") == ctx.eval("generation + 1")
    ctx.eval("bootUntilReady();")
    assert ctx.eval("loaded")
    assert ctx.eval("emulator.machine.peek(0x0805)") == 0x80
    assert ctx.eval("emulator.machine.ram[0xc000]") == 0


def test_direct_editor_commands_preserve_existing_machine_state(basic_page):
    ctx = basic_page
    ctx.eval(
        """
        bootUntilReady();
        document.getElementById('sampleSelect').value = 'direct';
        loadSelectedSample();
        """
    )
    ctx.eval(
        """
        editor.setValue('POKE 49152,7');
        emulator.machine.ram[0xc000] = 0x55;
        var generation = emulator.bootGeneration;
        loadBasicProgram({ bytes: [], errors: [{ type: 'error' }] });
        """
    )
    assert ctx.eval("emulator.bootGeneration") == ctx.eval("generation")
    assert ctx.eval("emulator.machine.ram[0xc000]") == 0x55
    assert (
        ctx.eval("String.fromCharCode(...emulator.typingQueue.map(item => item.code))")
        == "POKE 49152,7\r"
    )


def test_screen_run_preserves_the_loaded_machine(basic_page):
    ctx = basic_page
    ctx.eval(
        """
        bootUntilReady();
        emulator.machine.ram[0xc000] = 0x77;
        var generation = emulator.bootGeneration;
        window.typeCommand('RUN\\n');
        """
    )
    assert ctx.eval("emulator.bootGeneration") == ctx.eval("generation")
    assert ctx.eval("emulator.machine.ram[0xc000]") == 0x77
    assert (
        ctx.eval("String.fromCharCode(...emulator.typingQueue.map(item => item.code))")
        == "RUN\r"
    )


def test_reset_cancels_a_numbered_program_waiting_for_startup(basic_page):
    ctx = basic_page
    ctx.eval(
        """
        loadBasicProgram(compiled);
        window.resetEmulator();
        bootUntilReady();
        """
    )
    assert ctx.eval("emulator.basicReady")
    assert ctx.eval("emulator.machine.peek(0x0801)") == 0
    assert ctx.eval("emulator.typingQueue.length") == 0


def test_slow_sample_response_preserves_edits_made_while_loading(basic_page):
    ctx = basic_page
    ctx.eval(
        """
        var finishSample;
        examples.select = () => new Promise(resolve => { finishSample = resolve; });
        document.getElementById('sampleSelect').value = 'direct';
        loadSelectedSample();
        editor.setValue('10 PRINT "MY EDITS"');
        finishSample({ example: { direct: true }, source: 'PRINT "OLD SAMPLE"' });
        """
    )
    assert ctx.eval("editor.getValue()") == '10 PRINT "MY EDITS"'
    assert ctx.eval("document.getElementById('sampleSelect').value") == "helloWorld"
    assert "kept" in ctx.eval("document.getElementById('emulator-status').textContent")


def test_slow_initial_sample_index_preserves_custom_source(basic_page):
    ctx = basic_page
    ctx.eval(
        """
        var finishIndex;
        examples.populate = () => new Promise(resolve => { finishIndex = resolve; });
        editor.setValue('');
        initExamples();
        editor.setValue('10 PRINT "CUSTOM"');
        finishIndex();
        """
    )
    assert ctx.eval("editor.getValue()") == '10 PRINT "CUSTOM"'
    assert ctx.eval("document.getElementById('sampleSelect').value") == ""


def test_gallery_runs_a_sample_like_choosing_it_and_pressing_run(basic_page):
    ctx = basic_page
    ctx.eval(
        """
        bootUntilReady();
        var generation = emulator.bootGeneration;
        galleries[0].options.onRun('loop');
        """
    )
    assert ctx.eval("document.getElementById('sampleSelect').value") == "loop"
    assert ctx.eval("galleries[0].active") == "loop"
    # A numbered sample runs on a freshly reset C64, as the editor's Run does.
    assert ctx.eval("emulator.bootGeneration") == ctx.eval("generation + 1")
    ctx.eval("bootUntilReady();")
    assert ctx.eval("emulator.machine.peek(0x0805)") == 0x80
    assert ctx.eval("confirmations.length") == 0


def test_samples_ask_before_replacing_the_visitors_code(basic_page):
    ctx = basic_page
    ctx.eval(
        """
        editor.setValue('10 PRINT "MINE"');
        confirmAnswer = false;
        galleries[0].options.onRun('loop');
        document.getElementById('sampleSelect').value = 'direct';
        loadSelectedSample();
        """
    )
    assert ctx.eval("confirmations.length") == 2
    assert ctx.eval("editor.getValue()") == '10 PRINT "MINE"'
    assert ctx.eval("document.getElementById('sampleSelect').value") == "helloWorld"


def test_demo_reel_plays_the_demo_samples_until_the_visitor_takes_over(basic_page):
    ctx = basic_page
    assert ctx.eval("JSON.stringify(demoReel.ids)") == '["loop"]'
    ctx.eval("demoReel.start(); editor.setValue('10 REM MY TURN');")
    assert not ctx.eval("demoReel.active")
    ctx.eval("demoReel.start(); window.resetEmulator();")
    assert not ctx.eval("demoReel.active")
    # The reel's own sample loads must not stop it.
    ctx.eval("demoReel.start(); demoReel.options.play('loop');")
    assert ctx.eval("demoReel.active")
    assert ctx.eval("editor.getValue()") == "10 END"


def test_editing_while_the_reel_fetches_a_sample_stops_it_and_keeps_the_code(
    basic_page,
):
    ctx = basic_page
    ctx.eval(
        """
        var finishSample;
        examples.select = () => new Promise(resolve => { finishSample = resolve; });
        demoReel.start();
        var reelOutcome = 'pending';
        demoReel.options.play('loop').then(
            () => { reelOutcome = 'played'; },
            error => { reelOutcome = error.message; });
        editor.setValue('10 REM MY OWN CODE');
        """
    )
    assert not ctx.eval("demoReel.active")
    ctx.eval("finishSample({ example: {}, source: '10 END' });")
    assert ctx.eval("editor.getValue()") == "10 REM MY OWN CODE"
    # The reel is told the sample never loaded, so it cannot start its clock.
    assert "did not load" in ctx.eval("reelOutcome")


def test_choosing_a_sample_while_the_reel_fetches_one_stops_the_reel(basic_page):
    ctx = basic_page
    ctx.eval(
        """
        examples.select = () => new Promise(() => {});
        demoReel.start();
        demoReel.options.play('loop');
        document.getElementById('sampleSelect').value = 'direct';
        loadSelectedSample();
        """
    )
    assert not ctx.eval("demoReel.active")


def test_dropping_a_file_on_the_screen_stops_the_demo_reel(basic_page):
    # The emulator's own drop handler stops propagation, so the reel has to
    # listen on the screen itself.
    ctx = basic_page
    ctx.eval(
        """(() => {
            demoReel.start();
            const drop = {
                preventDefault() {}, stopPropagation() {}, dataTransfer: { files: [] }
            };
            for (const listener of emulator.canvas.listeners.drop) listener(drop);
        })()"""
    )
    assert ctx.eval("emulator.canvas.listeners.drop.length") == 2
    assert not ctx.eval("demoReel.active")


def test_assembly_stack_changes_do_not_resume_execution(asm_page):
    ctx = asm_page
    ctx.eval(
        """
        editor.setValue('ORG $C000\\nTSX\\nINX\\nINX\\nTXS\\nNOP');
        debuggerStep();
        """
    )
    ctx.eval("for (let i = 0; i < 4; i++) debuggerStep();")
    assert ctx.eval("emulator.machine.cpu.PC") == 0xC004
    assert ctx.eval("emulator.paused")


def test_assembly_top_level_rts_resumes_without_reset(asm_page):
    ctx = asm_page
    ctx.eval(
        """
        editor.setValue('ORG $C000\\nLDA #2\\nSTA $D020\\nRTS');
        var generation = emulator.bootGeneration;
        debuggerStep();
        """
    )
    ctx.eval("for (let i = 0; i < 3; i++) debuggerStep();")
    assert not ctx.eval("emulator.paused")
    assert ctx.eval("emulator.bootGeneration") == ctx.eval("generation")
    assert ctx.eval("emulator.machine.peek(0xd020) & 15") == 2


def test_external_machine_reset_clears_assembly_debug_state(asm_page):
    ctx = asm_page
    ctx.eval("editor.setValue('ORG $C000\\nNOP\\nRTS'); debuggerStep();")
    assert ctx.eval("debugger_.codeBytes !== null && isDebugMode")
    ctx.eval("emulator.reset();")
    assert ctx.eval("debugger_.codeBytes === null && currentSourceMap === null")
    assert not ctx.eval("isDebugMode || emulator.paused")


def test_a_sample_asks_before_replacing_edited_code(asm_page):
    ctx = asm_page
    ctx.eval(
        """
        editor.setValue('ORG $C000\\nRTS ; mine');
        confirmAnswer = false;
        document.getElementById('sampleSelect').value = 'loop';
        loadSelectedSample();
        """
    )
    assert ctx.eval("confirmations.length") == 1
    assert ctx.eval("editor.getValue()") == "ORG $C000\nRTS ; mine"
    ctx.eval("confirmAnswer = true; loadSelectedSample();")
    assert ctx.eval("editor.getValue()") == "10 END"
    # An unedited sample is replaced without asking.
    ctx.eval("loadSelectedSample();")
    assert ctx.eval("confirmations.length") == 2


def test_the_games_lab_uses_joystick_two(games_page):
    assert games_page.eval("emulator.activeJoystick") == 2


def test_a_play_button_runs_its_game_on_a_freshly_booted_c64(games_page):
    ctx = games_page
    ctx.eval("var generation = emulator.bootGeneration; runSample('nova');")
    assert ctx.eval("currentExampleKey") == "nova"
    # A fast boot first: the program waits for it.
    assert ctx.eval("emulator.bootGeneration") == ctx.eval("generation + 1")
    assert ctx.eval("emulator.fastBoot && debugger_.codeBytes === null")
    ctx.eval("bootUntilReady();")
    ctx.eval("emulator.machine.runFrame();")
    assert 0xC000 <= ctx.eval("emulator.machine.cpu.PC") < 0xC006
    assert ctx.eval("currentSourceMap !== null && debugger_.codeBytes !== null")
    # The keys go to the screen, and the sound came on once.
    assert ctx.eval("focused")
    assert ctx.eval("soundPresses") == 1
    ctx.eval("assembleAndRun(); bootUntilReady();")
    assert ctx.eval("soundPresses") == 1


def test_the_games_lab_leaves_sound_off_for_a_visitor_who_chose_it(games_page):
    ctx = games_page
    ctx.eval(
        """
        for (const listener of document.getElementById('muteBtn').listeners.click) {
            listener();
        }
        emulator.audioEnabled = false;
        runSample('nova');
        """
    )
    assert ctx.eval("soundPresses") == 0


def test_basic_errors_are_marked_in_the_editor_without_resetting(basic_page):
    ctx = basic_page
    ctx.eval(
        """
        bootUntilReady();
        var generation = emulator.bootGeneration;
        loadBasicProgram({
            bytes: new Uint8Array([1, 8, 0, 0]),
            errors: [{ type: 'error', line: 2, message: 'Line must start with a line number' }]
        });
        """
    )
    assert ctx.eval("editor.shownErrors.length") == 1
    assert ctx.eval("emulator.bootGeneration") == ctx.eval("generation")
    assert "Fix the error" in ctx.eval(
        "document.getElementById('emulator-status').textContent"
    )


def test_a_restored_program_is_kept_and_announced(basic_page):
    ctx = basic_page
    ctx.eval(
        """
        restoredProgram = 'Welcome back! Your last program has been restored.';
        editor.setValue('10 PRINT "MINE"');
        initExamples();
        """
    )
    assert ctx.eval("editor.getValue()") == '10 PRINT "MINE"'
    assert ctx.eval(
        "document.getElementById('emulator-status').textContent"
    ).startswith("Welcome back")


def test_direct_mode_types_control_codes_as_keys(basic_page):
    ctx = basic_page
    ctx.eval(
        """
        bootUntilReady();
        document.getElementById('sampleSelect').value = 'direct';
        loadSelectedSample();
        """
    )
    ctx.eval(
        """
        editor.setValue('PRINT "{CLR}{RED}HI"');
        loadBasicProgram({ bytes: [], errors: [] });
        """
    )
    assert ctx.eval("JSON.stringify(emulator.typingQueue.map(item => item.code))") == (
        "[80,82,73,78,84,32,34,147,28,72,73,34,13]"
    )


def test_assembly_errors_are_marked_in_the_editor(asm_page):
    ctx = asm_page
    ctx.eval("editor.setValue('ORG $C000\\n    LDAA #1'); assembleAndRun();")
    assert ctx.eval("editor.shownErrors[0].line") == 2
    assert "Unknown instruction" in ctx.eval("editor.shownErrors[0].message")
    assert "Fix the error" in ctx.eval(
        "document.getElementById('emulator-status').textContent"
    )


def test_pausing_a_running_program_steps_from_where_it_is(asm_page):
    ctx = asm_page
    ctx.eval(
        "editor.setValue('ORG $C000\\nLOOP INC $D020\\n    JMP LOOP'); assembleAndRun();"
    )
    ctx.eval("for (let i = 0; i < 5; i++) emulator.machine.runFrame();")
    assert not ctx.eval("emulator.paused")
    ctx.eval("emulator.pause();")
    assert ctx.eval("isDebugMode")
    ctx.eval("debuggerStep(); debuggerStep();")
    assert ctx.eval("emulator.paused")
    assert 0xC000 <= ctx.eval("emulator.machine.cpu.PC") < 0xC006
    assert ctx.eval("debugger_.codeBytes !== null")


def test_a_full_speed_run_that_returns_is_noticed(asm_page):
    ctx = asm_page
    ctx.eval(
        "editor.setValue('ORG $C000\\nLDA #5\\nSTA $D021\\nRTS'); assembleAndRun();"
    )
    ctx.eval("emulator.machine.runFrame(); renderCpuState();")
    assert ctx.eval("debugger_.codeBytes === null && !isDebugMode")
    assert ctx.eval("emulator.machine.peek(0xD021) & 15") == 5
    assert "returned to BASIC" in ctx.eval(
        "document.getElementById('emulator-status').textContent"
    )


def test_a_full_speed_run_that_ends_in_brk_is_noticed(asm_page):
    ctx = asm_page
    ctx.eval(
        "editor.setValue('ORG $C000\\nLDA #1\\nSTA $D020\\nBRK'); assembleAndRun();"
    )
    ctx.eval(
        "for (let i = 0; i < 60; i++) emulator.machine.runFrame(); renderCpuState();"
    )
    assert ctx.eval("debugger_.codeBytes === null && !isDebugMode")
    assert "BRK" in ctx.eval("document.getElementById('emulator-status').textContent")
    # The KERNAL's warm start puts its own BRK vector back.
    assert (
        ctx.eval("emulator.machine.peek(0x0316) | emulator.machine.peek(0x0317) << 8")
        == 0xFE66
    )
    # Step now starts the program again rather than stepping the KERNAL.
    ctx.eval("debuggerStep();")
    assert ctx.eval("emulator.machine.cpu.PC") == 0xC000
    assert ctx.eval("isDebugMode && emulator.paused")


def test_stepping_over_brk_ends_the_session(asm_page):
    ctx = asm_page
    ctx.eval("editor.setValue('ORG $C000\\nLDA #1\\nBRK'); debuggerStep();")
    assert ctx.eval("emulator.machine.cpu.PC") == 0xC000
    ctx.eval("debuggerStep(); debuggerStep();")
    assert ctx.eval("debugger_.codeBytes === null && !isDebugMode")
    assert not ctx.eval("emulator.paused")
    assert "BRK" in ctx.eval("document.getElementById('emulator-status').textContent")


def test_step_during_a_full_speed_run_starts_afresh(asm_page):
    ctx = asm_page
    ctx.eval(
        "editor.setValue('ORG $C000\\nLOOP INC $D020\\n    JMP LOOP'); assembleAndRun();"
    )
    ctx.eval("for (let i = 0; i < 5; i++) emulator.machine.runFrame();")
    ctx.eval("debuggerStep();")
    assert ctx.eval("emulator.machine.cpu.PC") == 0xC000
    assert ctx.eval("isDebugMode && emulator.paused")


def test_a_program_assembled_over_the_traps_keeps_its_own_bytes(asm_page):
    # $02A7-$02FF is free RAM that C64 references suggest for small programs.
    ctx = asm_page
    source = "ORG $02A7\\nINC $D020\\nRTS"
    ctx.eval(
        f"""
        var borderBefore = emulator.machine.peek(0xD020) & 15;
        editor.setValue('{source}');
        assembleAndRun();
        """
    )
    ctx.eval("for (let i = 0; i < 20; i++) emulator.machine.runFrame();")
    # It ran once and returned to BASIC, without a BRK warm start.
    assert ctx.eval("emulator.machine.peek(0xD020) & 15") == ctx.eval(
        "(borderBefore + 1) & 15"
    )
    assert "BRK" not in ctx.eval(
        "document.getElementById('emulator-status').textContent"
    )
    assert ctx.eval("emulator.machine.peek(0x02A7)") == 0xEE
    assert (
        ctx.eval("emulator.machine.peek(0x0316) | emulator.machine.peek(0x0317) << 8")
        == 0xFE66
    )
    # Stepping still sees its RTS end the session.
    ctx.eval("debuggerStep();")
    assert ctx.eval("emulator.machine.cpu.PC") == 0x02A7
    ctx.eval("debuggerStep(); debuggerStep();")
    assert ctx.eval("debugger_.codeBytes === null && !isDebugMode")
    assert "returned to BASIC" in ctx.eval(
        "document.getElementById('emulator-status').textContent"
    )


@pytest.mark.parametrize(
    "body",
    [
        # Would overwrite the return trap, so the final RTS hit a BRK.
        "LDA #0\\nSTA $02A8\\nRTS",
        # Would bump the return counter, so the page saw a return.
        "LOOP INC $02A7\\nJMP LOOP",
        # An indexed store can reach the traps too.
        "LDX #8\\nLDA #0\\nSTA $02A0,X\\nRTS",
    ],
)
def test_programs_that_store_into_the_traps_run_without_them(asm_page, body):
    ctx = asm_page
    ctx.eval(f"editor.setValue('ORG $C000\\n{body}'); assembleAndRun();")
    assert ctx.eval("editor.info").startswith("Assembled")
    assert ctx.eval("emulator.machine.peek(0xC000)") != 0
    assert not ctx.eval("trapsInstalled")
    ctx.eval(
        """
        emulator.machine.ram[0x0400 + 40 * 20] = 1;
        for (let i = 0; i < 20; i++) emulator.machine.runFrame();
        renderCpuState();
        """
    )
    status = ctx.eval("document.getElementById('emulator-status').textContent")
    assert "BRK" not in status
    assert "returned" not in status
    # No BRK warm start cleared the screen.
    assert ctx.eval("emulator.machine.ram[0x0400 + 40 * 20]") == 1


def test_programs_that_leave_the_traps_alone_keep_them(asm_page):
    ctx = asm_page
    ctx.eval(
        "editor.setValue('ORG $C000\\nLDA $02A8\\nSTA $02B5\\nSTA $D020\\nRTS');"
        " assembleAndRun();"
    )
    assert ctx.eval("trapsInstalled")


def test_programs_start_with_interrupts_enabled_as_sys_starts_them(asm_page):
    # The fixture pauses inside the KERNAL's interrupt handler, as a frame
    # can, with I set. The program must still start as SYS would, or the
    # keyboard scan and clock stop for the whole run.
    ctx = asm_page
    assert 0xEA31 <= ctx.eval("emulator.machine.cpu.PC") <= 0xEB42
    ctx.eval("editor.setValue('ORG $C000\\nLOOP JMP LOOP'); assembleAndRun();")
    assert ctx.eval("emulator.machine.cpu.PC") == 0xC000
    assert ctx.eval("emulator.machine.cpu.P & 0x0C") == 0
    ctx.eval(
        """
        var jiffiesBefore = emulator.machine.peek(0xA2);
        for (let i = 0; i < 30; i++) emulator.machine.runFrame();
        """
    )
    assert ctx.eval("(emulator.machine.peek(0xA2) - jiffiesBefore) & 0xFF") >= 30
