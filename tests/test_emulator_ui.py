"""Regression tests for the browser wrapper, without a browser or audio device."""

import json
import re

import pytest

from tests.test_utils import (
    JS_DIR,
    create_mini_racer_context,
    load_js_file,
    strip_es6_imports_exports,
)


@pytest.fixture
def emulator_ui():
    ctx = create_mini_racer_context()
    ctx.eval(
        """
        var ChipModel = { MOS6581: 0 };
        var SamplingMethod = { DECIMATE: 0 };
        var C64Machine = class {
            constructor(options) {
                this.audioEnabled = options.audioEnabled;
                this.sampleRate = options.sampleRate;
                this.clockFrequency = 985248;
                this.sid = { setSamplingParameters() {} };
                this.keys = new Set();
                this.joystick = new Set();
                this.typed = [];
                this.audioSamplesGenerated = 0;
                this.ram = new Uint8Array(65536);
            }
            setKey(row, col, pressed) {
                const key = row + ',' + col;
                if (pressed) this.keys.add(key);
                else this.keys.delete(key);
            }
            setJoystickButton(port, button, pressed) {
                const key = port + ',' + button;
                if (pressed) this.joystick.add(key);
                else this.joystick.delete(key);
            }
            releaseAllKeys() { this.keys.clear(); }
            ejectCartridge() {}
            reset() { this.keys.clear(); this.ram.fill(0); }
            peek(address) { return this.ram[address & 0xffff]; }
            runFrame() {}
            addKey(code) { this.typed.push(code); }
        };
        var VICIIRenderer = class { render() {} };
        var canvasListeners = new Map();
        var windowListeners = new Map();
        var documentListeners = new Map();
        function addListener(listeners, type, callback) {
            if (!listeners.has(type)) listeners.set(type, []);
            listeners.get(type).push(callback);
        }
        function dispatch(listeners, type) {
            for (const callback of listeners.get(type) || []) callback();
        }
        window.addEventListener = (type, callback) =>
            addListener(windowListeners, type, callback);
        var canvas = {
            getContext() { return {}; },
            addEventListener(type, callback) {
                addListener(canvasListeners, type, callback);
            },
            closest() { return null; }
        };
        var pageFocused = true;
        var document = {
            getElementById() { return canvas; },
            activeElement: canvas,
            hidden: false,
            hasFocus() { return pageFocused; },
            addEventListener(type, callback) {
                addListener(documentListeners, type, callback);
            }
        };
        var gamepads = [];
        var navigator = { getGamepads: () => gamepads };
        function standardGamepad(axes = [0, 0], pressed = []) {
            return {
                connected: true, mapping: 'standard', axes,
                buttons: Array.from({ length: 17 }, (_, index) => ({
                    pressed: pressed.includes(index),
                    value: pressed.includes(index) ? 1 : 0
                }))
            };
        }
        function activateGamepad(port = 2) {
            emulator.enableKeyboard();
            emulator.running = true;
            emulator.setActiveJoystick(port);
            const pad = standardGamepad();
            gamepads = [pad];
            return pad;
        }
        var audioContexts = [];
        window.AudioContext = class {
            constructor(options) {
                this.sampleRate = options.sampleRate;
                this.state = 'running';
                audioContexts.push(this);
            }
            createScriptProcessor() {
                return { connect() {}, disconnect() {} };
            }
            close() { this.state = 'closed'; return Promise.resolve(); }
            resume() { this.state = 'running'; return Promise.resolve(); }
        };
        var scheduledFrames = new Map();
        var scheduledTimers = new Map();
        var nextCallback = 0;
        var requestAnimationFrame = callback => {
            scheduledFrames.set(++nextCallback, callback);
            return nextCallback;
        };
        var cancelAnimationFrame = id => scheduledFrames.delete(id);
        var setTimeout = callback => {
            scheduledTimers.set(++nextCallback, callback);
            return nextCallback;
        };
        var clearTimeout = id => scheduledTimers.delete(id);
        performance.now = () => 0;
        function keyEvent(key, code, target = canvas) {
            return {
                key, code, target, defaultPrevented: false,
                preventDefault() { this.defaultPrevented = true; }
            };
        }
        function runTimers() {
            while (scheduledTimers.size) {
                const [id, callback] = scheduledTimers.entries().next().value;
                scheduledTimers.delete(id);
                callback();
            }
        }
        function markBasicReady() {
            emulator.machine.ram.set([1, 8, 3, 8], 0x2b);
            emulator.machine.ram.set([18, 5, 1, 4, 25, 46], 0x400);
        }
        """
    )
    source = re.sub(
        r"^import\s+[\s\S]*?from\s+['\"][^'\"]+['\"];",
        "",
        load_js_file(JS_DIR / "emulator.js"),
        flags=re.MULTILINE,
    )
    ctx.eval(strip_es6_imports_exports(source))
    ctx.eval("var emulator = new C64Emulator('screen', { audioEnabled: false });")
    return ctx


def test_unmute_allocates_and_feeds_audio_ring(emulator_ui):
    ctx = emulator_ui
    ctx.eval("emulator.enableAudio();")
    assert ctx.eval("emulator.audioEnabled && emulator.machine.audioEnabled")
    assert ctx.eval("emulator.audioRing instanceof Float32Array")
    assert ctx.eval("emulator.audioProcessor !== null")
    ctx.eval(
        """
        emulator.frameSamples.set([16384, -16384]);
        emulator.machine.audioSamplesGenerated = 2;
        emulator.pushFrameAudio();
        var output = new Float32Array(2);
        emulator.drainAudio(output);
        """
    )
    assert ctx.eval("output[0]") == 0.5
    assert ctx.eval("output[1]") == -0.5


def test_failed_audio_initialization_closes_context(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        window.AudioContext.prototype.createScriptProcessor = function() {
            throw new Error('Audio device unavailable');
        };
        emulator.enableAudio();
        """
    )
    assert ctx.eval("!emulator.audioEnabled && !emulator.machine.audioEnabled")
    assert ctx.eval("audioContexts[0].state") == "closed"
    assert ctx.eval("emulator.audioContext === null")


def test_key_release_uses_physical_key_identity(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        emulator.handleKeyPress(keyEvent('Shift', 'ShiftLeft'));
        emulator.handleKeyPress(keyEvent('A', 'KeyA'));
        emulator.frame++;
        emulator.handleKeyRelease(keyEvent('Shift', 'ShiftLeft'));
        emulator.handleKeyRelease(keyEvent('a', 'KeyA'));
        """
    )
    assert ctx.eval("emulator.heldKeys.size") == 0
    assert ctx.eval("emulator.machine.keys.size") == 0


def test_releasing_one_shift_keeps_other_shift_down(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        emulator.handleKeyPress(keyEvent('Shift', 'ShiftLeft'));
        emulator.handleKeyPress(keyEvent('Shift', 'ShiftRight'));
        emulator.handleKeyRelease(keyEvent('Shift', 'ShiftLeft'));
        """
    )
    assert ctx.eval("emulator.machine.keys.has('1,7')")


@pytest.mark.parametrize("tag", ["INPUT", "TEXTAREA", "SELECT", "BUTTON", "A"])
def test_native_controls_keep_their_keyboard_events(emulator_ui, tag):
    ctx = emulator_ui
    ctx.eval(
        f"""
        var control = {{ tagName: '{tag}', closest() {{ return this; }} }};
        var event = keyEvent('a', 'KeyA', control);
        emulator.handleKeyPress(event);
        """
    )
    assert not ctx.eval("event.defaultPrevented")
    assert ctx.eval("emulator.machine.keys.size") == 0


def test_deferred_release_does_not_lift_a_repressed_key(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        emulator.handleKeyPress(keyEvent('a', 'KeyA'));
        emulator.handleKeyRelease(keyEvent('a', 'KeyA'));
        emulator.handleKeyPress(keyEvent('a', 'KeyA'));
        emulator.running = true;
        emulator.lastTime = -25;
        emulator.loop();
        """
    )
    assert ctx.eval("emulator.machine.keys.has('1,2')")


def test_shared_matrix_position_stays_down_until_both_keys_release(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        emulator.handleKeyPress(keyEvent('Backspace', 'Backspace'));
        emulator.handleKeyPress(keyEvent('Delete', 'Delete'));
        emulator.frame++;
        emulator.handleKeyRelease(keyEvent('Backspace', 'Backspace'));
        """
    )
    assert ctx.eval("emulator.machine.keys.has('0,0')")


def test_stop_cancels_animation_before_restart(emulator_ui):
    ctx = emulator_ui
    ctx.eval("emulator.start(); emulator.stop(); emulator.start();")
    assert ctx.eval("scheduledFrames.size") == 1


def test_reset_resumes_and_clears_pending_input_and_audio(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        emulator.handleKeyPress(keyEvent('a', 'KeyA'));
        emulator.typeText('OLD');
        emulator.pause();
        emulator.ringWrite = 128;
        emulator.lastSample = 0.5;
        emulator.reset();
        runTimers();
        """
    )
    assert not ctx.eval("emulator.paused")
    assert ctx.eval("emulator.heldKeys.size") == 0
    assert ctx.eval("emulator.machine.typed.length") == 0
    assert ctx.eval("emulator.ringWrite - emulator.ringRead") == 0
    assert ctx.eval("emulator.lastSample") == 0


def test_synthetic_typing_is_serialized(emulator_ui):
    ctx = emulator_ui
    ctx.eval("emulator.typeText('AB'); emulator.typeText('CD');")
    assert ctx.eval("scheduledTimers.size") == 1
    ctx.eval("runTimers();")
    assert ctx.eval("String.fromCharCode(...emulator.machine.typed)") == "ABCD"


def test_short_joystick_press_is_visible_for_a_frame(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        emulator.setActiveJoystick(2);
        emulator.handleKeyPress(keyEvent('ArrowUp', 'ArrowUp'));
        emulator.handleKeyRelease(keyEvent('ArrowUp', 'ArrowUp'));
        """
    )
    assert ctx.eval("emulator.machine.joystick.has('2,up')")
    ctx.eval(
        """
        emulator.running = true;
        emulator.lastTime = -25;
        emulator.loop();
        """
    )
    assert not ctx.eval("emulator.machine.joystick.has('2,up')")


def test_joystick_mode_does_not_swallow_button_keyup(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        emulator.setActiveJoystick(2);
        var control = { closest() { return this; } };
        var down = keyEvent(' ', 'Space', control);
        var up = keyEvent(' ', 'Space', control);
        emulator.handleKeyPress(down);
        emulator.handleKeyRelease(up);
        """
    )
    assert not ctx.eval("down.defaultPrevented || up.defaultPrevented")
    assert ctx.eval("emulator.machine.joystick.size") == 0


@pytest.mark.parametrize(
    ("axes", "buttons"),
    [
        ([-0.8, 0], ["left"]),
        ([0.8, 0], ["right"]),
        ([0, -0.8], ["up"]),
        ([0, 0.8], ["down"]),
        ([-0.8, 0.8], ["down", "left"]),
        ([0.39, -0.39], []),
    ],
)
def test_gamepad_axes_use_a_dead_zone(emulator_ui, axes, buttons):
    ctx = emulator_ui
    ctx.eval(f"""
        var pad = activateGamepad();
        pad.axes = {json.dumps(axes)};
        emulator.pollGamepad();
        """)
    assert json.loads(
        ctx.eval("JSON.stringify([...emulator.machine.joystick].sort())")
    ) == ["2," + button for button in buttons]
    ctx.eval("pad.axes = [0, 0]; emulator.pollGamepad();")
    assert ctx.eval("emulator.machine.joystick.size") == 0


@pytest.mark.parametrize(
    ("index", "button"), [(12, "up"), (13, "down"), (14, "left"), (15, "right")]
)
def test_gamepad_standard_dpad_controls_the_selected_port(emulator_ui, index, button):
    ctx = emulator_ui
    ctx.eval(f"""
        activateGamepad(1);
        gamepads = [standardGamepad([0, 0], [{index}])];
        emulator.pollGamepad();
        """)
    assert ctx.eval("JSON.stringify([...emulator.machine.joystick])") == json.dumps(
        ["1," + button], separators=(",", ":")
    )


@pytest.mark.parametrize("index", range(4))
def test_gamepad_face_buttons_fire_and_release(emulator_ui, index):
    ctx = emulator_ui
    ctx.eval(f"""
        activateGamepad();
        gamepads = [standardGamepad([0, 0], [{index}])];
        emulator.pollGamepad();
        """)
    assert ctx.eval("emulator.machine.joystick.has('2,fire')")
    ctx.eval("gamepads = [standardGamepad()]; emulator.pollGamepad();")
    assert not ctx.eval("emulator.machine.joystick.has('2,fire')")


def test_gamepad_selects_the_first_connected_standard_pad_from_sparse_slots(
    emulator_ui,
):
    ctx = emulator_ui
    ctx.eval("""
        activateGamepad();
        var disconnected = standardGamepad([1, 0]);
        disconnected.connected = false;
        var unsupported = standardGamepad([1, 0]);
        unsupported.mapping = '';
        gamepads = [null, disconnected, unsupported,
            standardGamepad([-1, 0]), standardGamepad([1, 0])];
        emulator.pollGamepad();
        """)
    assert ctx.eval("emulator.machine.joystick.has('2,left')")
    assert not ctx.eval("emulator.machine.joystick.has('2,right')")
    ctx.eval("gamepads.length = 3; emulator.pollGamepad();")
    assert ctx.eval("emulator.machine.joystick.size") == 0


def test_gamepad_release_keeps_a_keyboard_direction_held(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var pad = activateGamepad();
        pad.axes = [0, -1];
        emulator.pollGamepad();
        emulator.handleKeyPress(keyEvent('ArrowUp', 'ArrowUp'));
        pad.axes = [0, 0];
        emulator.pollGamepad();
        """)
    assert ctx.eval("emulator.machine.joystick.has('2,up')")
    ctx.eval(
        "emulator.frame++; emulator.handleKeyRelease(keyEvent('ArrowUp', 'ArrowUp'));"
    )
    assert not ctx.eval("emulator.machine.joystick.has('2,up')")


def test_deferred_keyboard_release_keeps_a_gamepad_direction_held(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var pad = activateGamepad();
        pad.axes = [0, -1];
        emulator.handleKeyPress(keyEvent('ArrowUp', 'ArrowUp'));
        emulator.handleKeyRelease(keyEvent('ArrowUp', 'ArrowUp'));
        emulator.lastTime = -25;
        emulator.loop();
        """)
    assert ctx.eval("emulator.pendingJoystickReleases.length") == 0
    assert ctx.eval("emulator.machine.joystick.has('2,up')")
    ctx.eval("pad.axes = [0, 0]; emulator.pollGamepad();")
    assert not ctx.eval("emulator.machine.joystick.has('2,up')")


def test_gamepad_is_polled_once_before_a_turbo_batch(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var pad = activateGamepad();
        pad.axes = [1, 0];
        var polls = 0;
        var poll = emulator.pollGamepad.bind(emulator);
        emulator.pollGamepad = () => { polls++; poll(); };
        var frameInputs = [];
        emulator.machine.runFrame = () =>
            frameInputs.push(emulator.machine.joystick.has('2,right'));
        emulator.turbo = true;
        emulator.loop();
        """)
    assert ctx.eval("polls") == 1
    assert ctx.eval("frameInputs.length") > 1
    assert ctx.eval("frameInputs.every(Boolean)")


@pytest.mark.parametrize(
    "action",
    [
        "emulator.setActiveJoystick(0)",
        "emulator.setActiveJoystick(1)",
        "emulator.reset()",
        "emulator.stop()",
        "emulator.releaseAllKeys()",
    ],
)
def test_gamepad_lifecycle_releases_the_old_port(emulator_ui, action):
    ctx = emulator_ui
    ctx.eval(f"""
        var pad = activateGamepad();
        pad.axes = [1, 0];
        emulator.pollGamepad();
        {action};
        """)
    assert ctx.eval("emulator.machine.joystick.size") == 0
    assert ctx.eval("emulator.gamepadState.size") == 0
    if action == "emulator.setActiveJoystick(1)":
        ctx.eval("emulator.pollGamepad();")
        assert ctx.eval("emulator.machine.joystick.has('1,right')")
        assert not ctx.eval("emulator.machine.joystick.has('2,right')")
    elif action == "emulator.setActiveJoystick(0)":
        ctx.eval("emulator.pollGamepad();")
        assert ctx.eval("emulator.machine.joystick.size") == 0


@pytest.mark.parametrize(
    "inactive",
    [
        "emulator.keyboardEnabled = false",
        "emulator.running = false",
        "emulator.paused = true",
        "document.hidden = true",
        "pageFocused = false",
        "document.activeElement = {}",
    ],
)
def test_gamepad_poll_releases_input_when_the_screen_is_inactive(emulator_ui, inactive):
    ctx = emulator_ui
    ctx.eval(f"""
        var pad = activateGamepad();
        pad.axes = [-1, 0];
        emulator.pollGamepad();
        {inactive};
        emulator.pollGamepad();
        """)
    assert ctx.eval("emulator.machine.joystick.size") == 0
    assert ctx.eval("emulator.gamepadState.size") == 0


@pytest.mark.parametrize("surface", ["canvas", "window"])
def test_gamepad_blur_releases_immediately_and_stays_released(emulator_ui, surface):
    ctx = emulator_ui
    ctx.eval("""
        var pad = activateGamepad();
        pad.axes = [-1, 0];
        emulator.pollGamepad();
        emulator.handleKeyPress(keyEvent(' ', 'Space'));
        """)
    if surface == "canvas":
        ctx.eval("document.activeElement = {}; dispatch(canvasListeners, 'blur');")
    else:
        ctx.eval("pageFocused = false; dispatch(windowListeners, 'blur');")
    assert ctx.eval("emulator.machine.joystick.size") == 0
    ctx.eval("emulator.pollGamepad();")
    assert ctx.eval("emulator.machine.joystick.size") == 0


def test_gamepad_visibility_change_releases_immediately(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var pad = activateGamepad();
        pad.axes = [1, 0];
        emulator.pollGamepad();
        document.hidden = true;
        dispatch(documentListeners, 'visibilitychange');
        """)
    assert ctx.eval("emulator.machine.joystick.size") == 0
    ctx.eval("emulator.pollGamepad();")
    assert ctx.eval("emulator.machine.joystick.size") == 0


def test_pause_releases_gamepad_input_and_preserves_keyboard_holds(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var pad = activateGamepad();
        pad.axes = [1, 0];
        emulator.pollGamepad();
        emulator.handleKeyPress(keyEvent('ArrowUp', 'ArrowUp'));
        emulator.pause();
        """)
    assert not ctx.eval("emulator.machine.joystick.has('2,right')")
    assert ctx.eval("emulator.machine.joystick.has('2,up')")
    ctx.eval("emulator.loop();")
    assert not ctx.eval("emulator.machine.joystick.has('2,right')")
    assert ctx.eval("emulator.machine.joystick.has('2,up')")
    ctx.eval("emulator.resume(); emulator.pollGamepad();")
    assert ctx.eval("emulator.machine.joystick.has('2,right')")


@pytest.mark.parametrize(
    "api",
    [
        "delete navigator.getGamepads",
        "navigator.getGamepads = () => { throw new Error('SecurityError'); }",
    ],
)
def test_unavailable_gamepad_api_releases_input_and_keeps_the_loop_alive(
    emulator_ui, api
):
    ctx = emulator_ui
    ctx.eval(f"""
        var pad = activateGamepad();
        pad.axes = [1, 0];
        emulator.pollGamepad();
        {api};
        emulator.lastTime = -25;
        emulator.loop();
        """)
    assert ctx.eval("emulator.machine.joystick.size") == 0
    assert ctx.eval("scheduledFrames.size") == 1
    assert ctx.eval("emulator.frame") == 1


def test_gamepad_status_notifies_observers_only_when_it_changes(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var pad = activateGamepad();
        var statuses = [];
        emulator.onGamepadChange(message => statuses.push(message));
        emulator.pollGamepad();
        emulator.pollGamepad();
        """)
    assert ctx.eval("statuses.length") == 1
    assert ctx.eval("typeof statuses[0]") == "string"
    ctx.eval("gamepads = []; emulator.pollGamepad(); emulator.pollGamepad();")
    assert ctx.eval("statuses.length") == 2
    assert ctx.eval("statuses[0] !== statuses[1]")


@pytest.mark.parametrize(
    ("key", "code", "shifted"),
    [("*", "Digit8", False), ('"', "Quote", True), ("'", "Quote", True)],
)
def test_c64_punctuation_shift_is_preserved_through_a_short_press(
    emulator_ui, key, code, shifted
):
    ctx = emulator_ui
    ctx.eval(
        f"""
        emulator.handleKeyPress(keyEvent('Shift', 'ShiftLeft'));
        emulator.handleKeyPress(keyEvent({json.dumps(key)}, {json.dumps(code)}));
        emulator.handleKeyRelease(keyEvent({json.dumps(key)}, {json.dumps(code)}));
        emulator.handleKeyRelease(keyEvent('Shift', 'ShiftLeft'));
        """
    )
    assert ctx.eval("emulator.machine.keys.has('1,7')") == shifted
    ctx.eval(
        """
        emulator.running = true;
        emulator.lastTime = -25;
        emulator.loop();
        """
    )
    assert ctx.eval("emulator.machine.keys.size") == 0


def test_basic_loading_waits_for_a_real_fresh_boot_prompt(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        var ready = false;
        emulator.whenBasicReady().then(() => { ready = true; });
        emulator.checkBasicReady();
        """
    )
    assert not ctx.eval("ready")
    ctx.eval(
        """
        emulator.machine.ram.set([18, 5, 1, 4, 25, 46], 0x400);
        emulator.checkBasicReady();
        """
    )
    assert not ctx.eval("ready")
    ctx.eval("markBasicReady(); emulator.checkBasicReady();")
    assert ctx.eval("ready && emulator.basicReady")


def test_reset_invalidates_pending_basic_loads(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        var oldReady = false;
        var cancelled = false;
        emulator.whenBasicReady().then(
            () => { oldReady = true; },
            () => { cancelled = true; }
        );
        emulator.reset();
        var newReady = false;
        emulator.whenBasicReady().then(() => { newReady = true; });
        markBasicReady();
        emulator.checkBasicReady();
        """
    )
    assert ctx.eval("cancelled && !oldReady && newReady")


def test_basic_readiness_is_latched_until_reset(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        markBasicReady();
        emulator.checkBasicReady();
        emulator.machine.ram.fill(0);
        var ready = false;
        emulator.whenBasicReady().then(() => { ready = true; });
        """
    )
    assert ctx.eval("ready")
    ctx.eval("emulator.reset();")
    assert not ctx.eval("emulator.basicReady")


def test_boot_watchdog_reports_failure_instead_of_forcing_readiness(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        var bootError;
        emulator.whenBasicReady().catch(error => { bootError = error.message; });
        for (let i = 0; i <= 1000; i++) emulator.checkBasicReady();
        """
    )
    assert not ctx.eval("emulator.basicReady")
    assert "did not reach BASIC READY" in ctx.eval("bootError")


def test_cancelled_audio_start_cannot_close_a_newer_audio_graph(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        var resumes = [];
        var MockAudioContext = window.AudioContext;
        window.AudioContext = class extends MockAudioContext {
            constructor(options) {
                super(options);
                this.state = 'suspended';
            }
            resume() {
                return new Promise((resolve, reject) => resumes.push({
                    resolve: () => { this.state = 'running'; resolve(); },
                    reject
                }));
            }
        };
        emulator.audioEnabled = true;
        emulator.machine.audioEnabled = true;
        emulator.start();
        emulator.stop();
        emulator.start();
        resumes[0].reject(new Error('Old context was closed'));
        """
    )
    ctx.eval("resumes[1].resolve();")
    assert ctx.eval("emulator.audioContext === audioContexts[1]")
    assert ctx.eval("emulator.audioEnabled && emulator.machine.audioEnabled")
    assert ctx.eval("audioContexts[0].state") == "closed"
    assert ctx.eval("scheduledFrames.size") == 1


def test_turbo_runs_many_frames_per_refresh_and_reports_them(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        var reported = [];
        var states = [];
        emulator.onFrame(count => reported.push(count));
        emulator.onStateChange(e => states.push([e.paused, e.turbo]));
        emulator.running = true;
        emulator.lastTime = -25;
        emulator.loop();
        emulator.setTurbo(true);
        emulator.loop();
        emulator.pause();
        emulator.loop();
        emulator.resume();
        """
    )
    # One 50Hz frame in 25ms, then a whole turbo budget, then nothing while paused.
    assert ctx.eval("JSON.stringify(reported)") == "[1,40]"
    assert ctx.eval("emulator.frame") == 41
    assert ctx.eval("JSON.stringify(states)") == (
        "[[false,true],[true,true],[false,true]]"
    )


def test_a_fast_reset_boots_at_turbo_speed_without_turning_turbo_on(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        var reported = [];
        emulator.onFrame(count => reported.push(count));
        emulator.running = true;
        emulator.resetToBasic({ fast: true });
        var turboChanges = [];
        emulator.onStateChange(e => turboChanges.push(e.turbo));
        emulator.loop();
        emulator.basicReady = true;
        emulator.lastTime = -25;
        emulator.loop();
        """
    )
    # A whole turbo budget while booting, then 50Hz once BASIC is ready.
    assert ctx.eval("JSON.stringify(reported)") == "[40,1]"
    assert ctx.eval("emulator.turbo") is False
    assert ctx.eval("turboChanges.length") == 0
    # Any other reset is an ordinary one.
    ctx.eval("emulator.resetToBasic({ fast: true }); emulator.reset();")
    assert ctx.eval("emulator.fastBoot") is False


def test_a_failing_frame_listener_does_not_stop_the_loop(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        var calls = 0;
        emulator.onFrame(() => { throw new Error('broken tool'); });
        var stop = emulator.onFrame(() => calls++);
        emulator.running = true;
        emulator.lastTime = -25;
        emulator.loop();
        stop();
        emulator.lastTime = -25;
        emulator.loop();
        """
    )
    assert ctx.eval("calls") == 1
    assert ctx.eval("scheduledFrames.size") == 2


def test_typing_waits_for_room_in_the_keyboard_buffer(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        emulator.machine.ram[0xC6] = 10;
        emulator.typeText('AB');
        function runOneTimer() {
            const [id, callback] = scheduledTimers.entries().next().value;
            scheduledTimers.delete(id);
            callback();
        }
        runOneTimer();
        runOneTimer();
        """
    )
    assert ctx.eval("emulator.machine.typed.length") == 0
    assert ctx.eval("emulator.typingQueue.length") == 2
    ctx.eval("emulator.machine.ram[0xC6] = 0; runTimers();")
    assert ctx.eval("String.fromCharCode(...emulator.machine.typed)") == "AB"


def test_typed_text_uses_c64_character_codes(emulator_ui):
    ctx = emulator_ui
    ctx.eval("emulator.typeText('a\u03c0\\x93\u20ac\\n'); runTimers();")
    assert ctx.eval("JSON.stringify(emulator.machine.typed)") == "[65,255,147,13]"


def test_ctrl_v_is_left_to_the_browser_for_pasting(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        """
        var paste = keyEvent('v', 'KeyV');
        paste.ctrlKey = true;
        emulator.handleKeyPress(paste);
        """
    )
    assert not ctx.eval("paste.defaultPrevented")
    assert ctx.eval("emulator.machine.keys.size") == 0
