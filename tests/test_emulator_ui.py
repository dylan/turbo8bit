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
    ctx.eval("""
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
                this.mouseEnabled = false;
                this.mouseButtons = new Set();
                this.mouseMoves = [];
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
            setMouseEnabled(enabled) {
                this.mouseEnabled = enabled;
                if (!enabled) this.mouseButtons.clear();
            }
            moveMouse(dx, dy) { this.mouseMoves.push([dx, dy]); }
            setMouseButton(button, pressed) {
                if (!this.mouseEnabled) return;
                if (pressed) this.mouseButtons.add(button);
                else this.mouseButtons.delete(button);
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
        function dispatch(listeners, type, event = {}) {
            for (const callback of listeners.get(type) || []) callback(event);
        }
        window.addEventListener = (type, callback) =>
            addListener(windowListeners, type, callback);
        var canvas = {
            getContext() { return {}; },
            addEventListener(type, callback) {
                addListener(canvasListeners, type, callback);
            },
            closest() { return null; },
            getBoundingClientRect() { return { width: 384, height: 272 }; },
            focus() { document.activeElement = canvas; }
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
        var hidGamepadInputs = [];
        var HidGamepadInput = class {
            constructor(onChange) {
                this.onChange = onChange;
                this.connected = false;
                this.ready = false;
                this.gamepad = null;
                hidGamepadInputs.push(this);
            }
            async connect(options) {
                this.options = options;
                const devices = await navigator.hid.requestDevice();
                if (!devices.length) return false;
                this.connected = true;
                this.ready = false;
                this.gamepad = standardGamepad();
                this.gamepad.id = devices[0].productName + ' (WebHID)';
                this.onChange();
                return true;
            }
            async disconnect() {
                this.connected = false;
                this.ready = false;
                this.gamepad = null;
                this.onChange();
            }
            report(axes = [0, 0], pressed = []) {
                const first = !this.ready;
                const id = this.gamepad.id;
                this.gamepad = standardGamepad(axes, pressed);
                this.gamepad.id = id;
                this.ready = true;
                if (first) this.onChange();
            }
        };
        function activateGamepad(port = 2) {
            emulator.enableKeyboard();
            emulator.running = true;
            document.activeElement = canvas;
            emulator.setActiveJoystick(port);
            const pad = standardGamepad();
            gamepads = [pad];
            emulator.setGamepadEnabled(true);
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
        """)
    ctx.eval(strip_es6_imports_exports(load_js_file(JS_DIR / "gamepad-mapping.js")))
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
        unsupported.id = 'Unmapped controller';
        gamepads = [null, disconnected, unsupported,
            standardGamepad([-1, 0]), standardGamepad([1, 0])];
        gamepads[3].id = 'First standard controller';
        emulator.pollGamepad();
        """)
    assert ctx.eval("emulator.machine.joystick.has('2,left')")
    assert not ctx.eval("emulator.machine.joystick.has('2,right')")
    assert (
        ctx.eval("emulator.getInputState().gamepad.name") == "First standard controller"
    )
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


def test_input_snapshots_notify_only_when_state_changes_and_preserve_status_text(
    emulator_ui,
):
    ctx = emulator_ui
    ctx.eval("""
        var statuses = [];
        emulator.onInputChange(state => statuses.push(state));
        emulator.enableKeyboard();
        emulator.running = true;
        emulator.setGamepadEnabled(true);
        emulator.pollGamepad();
        emulator.pollGamepad();
        """)
    assert ctx.eval("statuses.length") == 1
    assert ctx.eval("typeof statuses[0].gamepad.status") == "string"
    assert ctx.eval("emulator.gamepadConnection") == "waiting"
    ctx.eval("""
        gamepads = [standardGamepad([-1, 0])];
        emulator.pollGamepad();
        emulator.pollGamepad();
        """)
    assert ctx.eval("statuses.length") == 2
    assert ctx.eval("emulator.gamepadConnection") == "active"
    assert ctx.eval("emulator.machine.joystick.has('2,left')")
    assert ctx.eval("statuses[0].gamepad.status !== statuses[1].gamepad.status")
    ctx.eval("gamepads = []; emulator.pollGamepad(); emulator.pollGamepad();")
    assert ctx.eval("statuses.length") == 3
    assert ctx.eval("emulator.gamepadConnection") == "waiting"
    ctx.eval("emulator.setGamepadEnabled(false); emulator.setGamepadEnabled(false);")
    assert ctx.eval("statuses.length") == 4
    assert ctx.eval("statuses[2].gamepad.status === statuses[3].gamepad.status")
    assert ctx.eval("statuses[2].gamepad.enabled && !statuses[3].gamepad.enabled")
    assert ctx.eval("emulator.gamepadConnection") == "waiting"


def test_gamepad_api_is_not_queried_before_explicit_discovery_or_capture(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var queries = 0;
        navigator.getGamepads = () => {
            queries++;
            return [standardGamepad([1, 0])];
        };
        emulator.enableKeyboard();
        dispatch(windowListeners, 'gamepadconnected');
        dispatch(windowListeners, 'gamepaddisconnected');
        emulator.running = true;
        emulator.setActiveJoystick(2);
        emulator.pollGamepad();
        emulator.lastTime = -25;
        emulator.loop();
        """)
    assert ctx.eval("emulator.gamepadEnabled") is False
    assert ctx.eval("emulator.gamepadConnection") == "off"
    assert ctx.eval("queries") == 0
    assert ctx.eval("emulator.machine.joystick.size") == 0
    assert ctx.eval("(windowListeners.get('gamepadconnected') || []).length") == 0
    assert ctx.eval("(windowListeners.get('gamepaddisconnected') || []).length") == 0


@pytest.mark.parametrize(("selected", "expected"), [(0, 2), (1, 1), (2, 2)])
def test_enabling_gamepad_polls_immediately_and_uses_the_selected_port(
    emulator_ui, selected, expected
):
    ctx = emulator_ui
    ctx.eval(f"""
        emulator.enableKeyboard();
        emulator.running = true;
        emulator.setActiveJoystick({selected});
        var queries = 0;
        navigator.getGamepads = () => {{
            queries++;
            return [standardGamepad([1, 0])];
        }};
        emulator.setGamepadEnabled(true);
        """)
    assert ctx.eval("emulator.gamepadEnabled") is True
    assert ctx.eval("emulator.activeJoystick") == expected
    assert ctx.eval("queries") == 1
    assert ctx.eval("emulator.gamepadConnection") == "active"
    assert ctx.eval(f"emulator.machine.joystick.has('{expected},right')")


def test_disabling_gamepad_releases_only_controller_input(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var pad = activateGamepad();
        pad.axes = [1, -1];
        emulator.pollGamepad();
        emulator.handleKeyPress(keyEvent('ArrowRight', 'ArrowRight'));
        emulator.setGamepadEnabled(false);
        """)
    assert ctx.eval("emulator.gamepadEnabled") is False
    assert ctx.eval("emulator.gamepadConnection") == "connected"
    assert ctx.eval("emulator.gamepadState.size") == 0
    assert not ctx.eval("emulator.machine.joystick.has('2,up')")
    assert ctx.eval("emulator.machine.joystick.has('2,right')")
    assert ctx.eval("emulator.activeJoystick") == 2
    ctx.eval("emulator.pollGamepad();")
    assert not ctx.eval("emulator.machine.joystick.has('2,up')")
    assert ctx.eval("emulator.machine.joystick.has('2,right')")


@pytest.mark.parametrize(
    ("setup", "connection"),
    [
        ("gamepads = []", "waiting"),
        ("document.activeElement = {}", "connected"),
        ("gamepads[0].mapping = ''", "unsupported"),
        ("delete navigator.getGamepads", "unavailable"),
        (
            "navigator.getGamepads = () => { throw new Error('SecurityError'); }",
            "unavailable",
        ),
    ],
)
def test_gamepad_connection_reports_detection_and_capture_state(
    emulator_ui, setup, connection
):
    ctx = emulator_ui
    ctx.eval(f"""
        activateGamepad();
        {setup};
        emulator.pollGamepad();
        """)
    assert ctx.eval("emulator.gamepadConnection") == connection
    assert ctx.eval("typeof emulator.gamepadStatus") == "string"
    assert ctx.eval("emulator.machine.joystick.size") == 0


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


# Mouse deltas are observed at complete emulated frames, independently of display
# refreshes. Button and lifecycle checks use the wrapper's real event listeners.
def activate_mouse(ctx):
    ctx.eval("""
        emulator.enableKeyboard();
        emulator.running = true;
        document.activeElement = canvas;
        emulator.setMouseEnabled(true);
        function mouseEvent(button = 0, movementX = 0, movementY = 0) {
            return { pointerType: 'mouse', button, movementX, movementY,
                defaultPrevented: false,
                preventDefault() { this.defaultPrevented = true; } };
        }
        """)


def test_input_observer_is_changes_only_and_snapshots_do_not_mutate_the_core(
    emulator_ui,
):
    ctx = emulator_ui
    ctx.eval("""
        var changes = [];
        var unsubscribe = emulator.onInputChange(state => changes.push(state));
        var initial = emulator.getInputState();
        initial.gamepad.enabled = true;
        initial.mouse.enabled = true;
        """)
    assert ctx.eval("changes.length") == 0
    assert not ctx.eval("emulator.getInputState().gamepad.enabled")
    assert not ctx.eval("emulator.getInputState().mouse.enabled")
    ctx.eval("emulator.setMouseEnabled(true); emulator.setMouseEnabled(true);")
    assert ctx.eval("changes.length") == 1
    assert ctx.eval("changes[0].mouse.enabled")
    ctx.eval("unsubscribe(); emulator.setMouseEnabled(false);")
    assert ctx.eval("changes.length") == 1


def test_gamepad_discovery_continues_after_capture_is_disabled_and_names_notify(
    emulator_ui,
):
    ctx = emulator_ui
    ctx.eval("""
        var pad = activateGamepad();
        pad.id = 'First controller';
        pad.axes = [1, 0];
        emulator.pollGamepad();
        emulator.setGamepadEnabled(false);
        var changes = [];
        var oldStatus = emulator.getInputState().gamepad.status;
        emulator.onInputChange(state => changes.push(state));
        pad.id = 'Second controller';
        emulator.pollGamepad();
        emulator.pollGamepad();
        """)
    assert ctx.eval("emulator.getInputState().gamepad.name") == "Second controller"
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "connected"
    assert not ctx.eval("emulator.getInputState().gamepad.enabled")
    assert "Capture is off" in ctx.eval("emulator.getInputState().gamepad.status")
    assert ctx.eval("emulator.machine.joystick.size") == 0
    assert ctx.eval("changes.length") == 1
    assert ctx.eval("changes[0].gamepad.status === oldStatus")
    ctx.eval("gamepads = []; dispatch(windowListeners, 'gamepaddisconnected');")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "waiting"


def test_device_setters_do_not_move_focus_or_capture_from_page_controls(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        emulator.enableKeyboard(); emulator.running = true;
        var control = {}; document.activeElement = control;
        gamepads = [standardGamepad([1, 0])];
        emulator.setGamepadEnabled(true); emulator.setMouseEnabled(true);
        """)
    assert ctx.eval("document.activeElement === control")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "connected"
    assert not ctx.eval("emulator.getInputState().mouse.captured")
    assert ctx.eval("emulator.machine.joystick.size") == 0
    ctx.eval("canvas.focus(); dispatch(canvasListeners, 'focus');")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "active"
    assert ctx.eval("emulator.getInputState().mouse.captured")


def test_mouse_scales_relative_motion_and_accumulates_fractional_pixels(emulator_ui):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval("""
        canvas.getBoundingClientRect = () => ({ width: 768, height: 544 });
        dispatch(canvasListeners, 'pointermove', mouseEvent(0, 1, -1));
        emulator.runOneFrame();
        """)
    assert ctx.eval("emulator.machine.mouseMoves.length") == 0
    ctx.eval("""
        dispatch(canvasListeners, 'pointermove', mouseEvent(0, 1, -1));
        emulator.runOneFrame();
        """)
    assert ctx.eval("JSON.stringify(emulator.machine.mouseMoves)") == "[[1,-1]]"


def test_mouse_bursts_are_bounded_per_emulated_frame_without_stale_replay(emulator_ui):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval("""
        dispatch(canvasListeners, 'pointermove', mouseEvent(0, 1000, -1000));
        emulator.turbo = true; emulator.lastTime = -25; emulator.loop();
        """)
    assert ctx.eval("emulator.frame") == 40
    assert ctx.eval("JSON.stringify(emulator.machine.mouseMoves)") == "[[24,-24]]"


def test_mouse_left_right_chord_and_release_outside_canvas(emulator_ui):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval("""
        var press = mouseEvent();
        dispatch(canvasListeners, 'pointerdown', press);
        var chord = mouseEvent(); chord.buttons = 3;
        dispatch(canvasListeners, 'pointermove', chord);
        """)
    assert ctx.eval("press.defaultPrevented")
    assert ctx.eval("emulator.machine.mouseButtons.size") == 2
    ctx.eval("""
        var rightOnly = mouseEvent(); rightOnly.buttons = 2;
        dispatch(canvasListeners, 'pointermove', rightOnly);
        var release = mouseEvent(2); release.buttons = 0;
        dispatch(windowListeners, 'pointerup', release);
        """)
    assert ctx.eval("emulator.machine.mouseButtons.size") == 0
    assert ctx.eval("release.defaultPrevented")


@pytest.mark.parametrize(
    "action",
    [
        "document.activeElement = {}; dispatch(canvasListeners, 'blur')",
        "pageFocused = false; dispatch(windowListeners, 'blur')",
        "document.hidden = true; dispatch(documentListeners, 'visibilitychange')",
        "emulator.pause()",
        "emulator.reset()",
        "emulator.stop()",
        "emulator.setMouseEnabled(false)",
        "dispatch(windowListeners, 'pointercancel', mouseEvent())",
    ],
)
def test_mouse_lifecycle_releases_buttons_and_discards_queued_motion(
    emulator_ui, action
):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval(f"""
        dispatch(canvasListeners, 'pointerdown', mouseEvent());
        dispatch(canvasListeners, 'pointermove', mouseEvent(0, 12, 9));
        {action};
        """)
    assert ctx.eval("emulator.machine.mouseButtons.size") == 0
    assert ctx.eval("emulator.mouseButtons.size") == 0
    assert ctx.eval("emulator.mouseDeltaX === 0 && emulator.mouseDeltaY === 0")


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
def test_mouse_capture_requires_the_active_screen_and_stays_released(
    emulator_ui, inactive
):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval(f"""
        dispatch(canvasListeners, 'pointerdown', mouseEvent());
        dispatch(canvasListeners, 'pointermove', mouseEvent(0, 3, 4));
        {inactive}; emulator.pollGamepad();
        var press = mouseEvent();
        dispatch(canvasListeners, 'pointerdown', press);
        """)
    assert ctx.eval("emulator.machine.mouseButtons.size") == 0
    assert ctx.eval("emulator.mouseDeltaX === 0 && emulator.mouseDeltaY === 0")
    assert not ctx.eval("press.defaultPrevented")
    assert not ctx.eval("emulator.getInputState().mouse.captured")


def test_mouse_ignores_touch_invalid_motion_and_uncaptured_context_menus(emulator_ui):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval("""
        var touch = mouseEvent(0, 5, 7); touch.pointerType = 'touch';
        dispatch(canvasListeners, 'pointerdown', touch);
        dispatch(canvasListeners, 'pointermove', touch);
        dispatch(canvasListeners, 'pointermove', mouseEvent(0, NaN, Infinity));
        emulator.runOneFrame();
        var capturedMenu = mouseEvent(2);
        dispatch(canvasListeners, 'contextmenu', capturedMenu);
        document.activeElement = {};
        var nativeMenu = mouseEvent(2);
        dispatch(canvasListeners, 'contextmenu', nativeMenu);
        """)
    assert ctx.eval("emulator.machine.mouseMoves.length") == 0
    assert ctx.eval("emulator.machine.mouseButtons.size") == 0
    assert not ctx.eval("touch.defaultPrevented")
    assert ctx.eval("capturedMenu.defaultPrevented")
    assert not ctx.eval("nativeMenu.defaultPrevented")


def test_mouse_toggle_preserves_port_one_keyboard_and_gamepad_holds(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var pad = activateGamepad(1); pad.axes = [1, 0];
        emulator.pollGamepad();
        emulator.handleKeyPress(keyEvent('ArrowUp', 'ArrowUp'));
        emulator.setMouseEnabled(true);
        """)
    assert ctx.eval("emulator.activeJoystick") == 1
    assert ctx.eval("emulator.machine.joystick.has('1,right')")
    assert ctx.eval("emulator.machine.joystick.has('1,up')")
    ctx.eval("emulator.setMouseEnabled(false);")
    assert ctx.eval("emulator.activeJoystick") == 1
    assert ctx.eval("emulator.machine.joystick.has('1,right')")
    assert ctx.eval("emulator.machine.joystick.has('1,up')")
    assert ctx.eval("emulator.gamepadEnabled")


def test_selecting_joystick_one_keeps_mouse_buttons_and_queued_motion(emulator_ui):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval("""
        emulator.setActiveJoystick(2);
        dispatch(canvasListeners, 'pointerdown', mouseEvent());
        dispatch(canvasListeners, 'pointermove', mouseEvent(0, 5, 4));
        emulator.setActiveJoystick(1);
        """)
    assert ctx.eval("emulator.activeJoystick") == 1
    assert ctx.eval("emulator.mouseEnabled && emulator.machine.mouseEnabled")
    assert ctx.eval("emulator.machine.mouseButtons.has('left')")
    ctx.eval("emulator.runOneFrame();")
    assert ctx.eval("JSON.stringify(emulator.machine.mouseMoves)") == "[[5,4]]"


def test_port_one_gamepad_keyboard_and_mouse_release_independently(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var pad = activateGamepad(1); pad.buttons[0].pressed = true;
        emulator.pollGamepad();
        emulator.handleKeyPress(keyEvent(' ', 'Space'));
        """)
    activate_mouse(ctx)
    ctx.eval("""
        dispatch(canvasListeners, 'pointerdown', mouseEvent());
        pad.buttons[0].pressed = false;
        emulator.pollGamepad();
        """)
    assert ctx.eval("emulator.activeJoystick") == 1
    assert ctx.eval("emulator.machine.joystick.has('1,fire')")
    assert ctx.eval("emulator.machine.mouseButtons.has('left')")
    ctx.eval("""
        emulator.runOneFrame();
        emulator.handleKeyRelease(keyEvent(' ', 'Space'));
        """)
    assert not ctx.eval("emulator.machine.joystick.has('1,fire')")
    assert ctx.eval("emulator.machine.mouseButtons.has('left')")
    ctx.eval("""
        var release = mouseEvent(); release.buttons = 0;
        dispatch(windowListeners, 'pointerup', release);
        """)
    assert ctx.eval("emulator.machine.mouseButtons.size") == 0


@pytest.mark.parametrize("final_button", [1, 2])
def test_last_untracked_button_release_clears_mouse_buttons_captured_earlier(
    emulator_ui, final_button
):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval(f"""
        dispatch(canvasListeners, 'pointerdown', mouseEvent(0));
        var finalRelease = mouseEvent({final_button}); finalRelease.buttons = 0;
        dispatch(windowListeners, 'pointerup', finalRelease);
        """)
    assert ctx.eval("emulator.mouseButtons.size") == 0
    assert ctx.eval("emulator.machine.mouseButtons.size") == 0
    assert ctx.eval("finalRelease.defaultPrevented")


def test_outside_chord_changes_release_owned_buttons_without_capturing_new_ones(
    emulator_ui,
):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval("""
        dispatch(canvasListeners, 'pointerdown', mouseEvent(0));
        dispatch(canvasListeners, 'pointermove', mouseEvent(0, 5, 7));
        var outsideChord = mouseEvent(); outsideChord.buttons = 3;
        dispatch(windowListeners, 'pointermove', outsideChord);
        """)
    assert ctx.eval("emulator.machine.mouseButtons.has('left')")
    assert not ctx.eval("emulator.machine.mouseButtons.has('right')")
    ctx.eval("""
        outsideChord.buttons = 2;
        dispatch(windowListeners, 'pointermove', outsideChord);
        """)
    assert ctx.eval("emulator.machine.mouseButtons.size") == 0
    assert not ctx.eval("outsideChord.defaultPrevented")
    ctx.eval("emulator.runOneFrame();")
    assert ctx.eval("JSON.stringify(emulator.machine.mouseMoves)") == "[[5,7]]"


def test_unowned_mouse_release_keeps_the_native_event_untouched(emulator_ui):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval("""
        var release = mouseEvent(2); release.buttons = 0;
        dispatch(windowListeners, 'pointerup', release);
        """)
    assert not ctx.eval("release.defaultPrevented")


@pytest.mark.parametrize("port", [0, 1, 2])
def test_observation_only_discovery_preserves_capture_and_port(emulator_ui, port):
    ctx = emulator_ui
    ctx.eval(f"""
        emulator.setGamepadAutoCapture(false);
        emulator.enableKeyboard(); emulator.running = true;
        emulator.setActiveJoystick({port});
        var pad = standardGamepad([1, -1], [0]); pad.id = 'Controller';
        var queries = 0;
        navigator.getGamepads = () => {{ queries++; return [null, pad]; }};
        emulator.pollGamepad();
        emulator.getInputState();
        """)
    assert ctx.eval("queries") == 0
    ctx.eval("emulator.startGamepadDiscovery();")
    assert ctx.eval("queries") == 1
    assert ctx.eval("emulator.activeJoystick") == port
    assert not ctx.eval("emulator.gamepadEnabled")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "connected"
    assert ctx.eval("emulator.getInputState().gamepad.name") == "Controller"
    assert ctx.eval("emulator.machine.joystick.size") == 0
    ctx.eval("pad.id = 'Reconnected'; emulator.pollGamepad();")
    assert ctx.eval("queries") == 2
    assert ctx.eval("emulator.getInputState().gamepad.name") == "Reconnected"
    assert ctx.eval("emulator.machine.joystick.size") == 0


def test_discovery_failure_does_not_enable_capture_or_change_the_port(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        emulator.enableKeyboard(); emulator.running = true;
        emulator.setActiveJoystick(1);
        navigator.getGamepads = () => { throw new Error('SecurityError'); };
        emulator.startGamepadDiscovery();
        """)
    assert ctx.eval("emulator.activeJoystick") == 1
    assert not ctx.eval("emulator.gamepadEnabled")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "unavailable"
    assert ctx.eval("emulator.machine.joystick.size") == 0


@pytest.mark.parametrize(
    "start", ["emulator.startGamepadDiscovery()", "emulator.setGamepadEnabled(true)"]
)
def test_discovery_observes_connection_events_while_stopped_without_keyboard(
    emulator_ui, start
):
    ctx = emulator_ui
    ctx.eval(f"""
        {start};
        """)
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "waiting"
    ctx.eval("""
        var pad = standardGamepad([1, 0], [0]); pad.id = 'Later controller';
        gamepads = [null, pad];
        dispatch(windowListeners, 'gamepadconnected');
        """)
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "connected"
    assert ctx.eval("emulator.getInputState().gamepad.name") == "Later controller"
    assert ctx.eval("emulator.machine.joystick.size") == 0
    ctx.eval("gamepads = []; dispatch(windowListeners, 'gamepaddisconnected');")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "waiting"
    assert ctx.eval("emulator.getInputState().gamepad.name") == ""
    assert not ctx.eval("emulator.keyboardEnabled || emulator.running")
    assert ctx.eval("scheduledFrames.size + scheduledTimers.size") == 0


def test_repeated_discovery_and_capture_install_one_connection_observer(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        emulator.startGamepadDiscovery();
        emulator.startGamepadDiscovery();
        emulator.setGamepadEnabled(true);
        emulator.setGamepadEnabled(true);
        emulator.enableKeyboard();
        emulator.enableKeyboard();
        emulator.setGamepadEnabled(false);
        var queries = 0;
        navigator.getGamepads = () => { queries++; return gamepads; };
        dispatch(windowListeners, 'gamepadconnected');
        """)
    assert ctx.eval("queries") == 1
    assert ctx.eval("windowListeners.get('gamepadconnected').length") == 1
    assert ctx.eval("windowListeners.get('gamepaddisconnected').length") == 1
    ctx.eval("dispatch(windowListeners, 'gamepaddisconnected');")
    assert ctx.eval("queries") == 2
    ctx.eval("emulator.running = true; emulator.loop();")
    assert ctx.eval("queries") == 3
    assert ctx.eval("scheduledFrames.size") == 1
    assert ctx.eval("scheduledTimers.size") == 0


def test_unsupported_controller_keeps_its_browser_identity_without_forwarding_input(
    emulator_ui,
):
    ctx = emulator_ui
    ctx.eval("""
        activateGamepad();
        var raw = standardGamepad([1, -1], [0]);
        raw.mapping = ''; raw.id = 'Raw controller';
        var disconnected = standardGamepad(); disconnected.connected = false;
        gamepads = [null, disconnected, raw, { connected: true, id: 'Other raw' }];
        emulator.pollGamepad();
        var changes = [];
        emulator.onInputChange(state => changes.push(state));
        """)
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "unsupported"
    assert ctx.eval("emulator.getInputState().gamepad.name") == "Raw controller"
    assert ctx.eval("emulator.machine.joystick.size") == 0
    ctx.eval("raw.id = 'Renamed raw controller'; emulator.pollGamepad();")
    assert ctx.eval("changes.length") == 1
    assert ctx.eval("changes[0].gamepad.name") == "Renamed raw controller"
    assert ctx.eval("changes[0].gamepad.connection") == "unsupported"
    assert ctx.eval("emulator.machine.joystick.size") == 0


def connect_hid(ctx):
    ctx.eval("""
        navigator.hid = {
            requestDevice() { return Promise.resolve([{ productName: 'USB gamepad' }]); }
        };
        var hidResult = null;
        emulator.connectGamepadHid().then(result => { hidResult = result; });
        """)
    assert ctx.eval("hidResult") is True


def test_hid_is_lazy_and_requests_only_in_the_explicit_connection_call(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var requests = 0, enumerations = 0;
        navigator.hid = {
            requestDevice() { requests++; return Promise.resolve([]); },
            getDevices() { enumerations++; return Promise.resolve([]); }
        };
        emulator.enableKeyboard(); emulator.running = true;
        emulator.getInputState(); emulator.pollGamepad(); emulator.loop();
        emulator.startGamepadDiscovery(); emulator.setGamepadEnabled(true);
        """)
    assert ctx.eval("hidGamepadInputs.length") == 0
    assert ctx.eval("requests + enumerations") == 0
    assert ctx.eval("emulator.getInputState().gamepad.hidAvailable")
    ctx.eval("""
        var requestedSynchronously = false;
        emulator.connectGamepadHid();
        requestedSynchronously = requests === 1;
        """)
    assert ctx.eval("requestedSynchronously")
    assert ctx.eval("hidGamepadInputs.length") == 1
    assert ctx.eval("enumerations") == 0


def test_connecting_hid_starts_capture_and_preserves_port_and_other_sources(
    emulator_ui,
):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval("""
        emulator.setActiveJoystick(1);
        emulator.handleKeyPress(keyEvent('ArrowUp', 'ArrowUp'));
        emulator.handleKeyPress(keyEvent('a', 'KeyA'));
        dispatch(canvasListeners, 'pointerdown', mouseEvent());
        dispatch(canvasListeners, 'pointermove', mouseEvent(0, 5, 4));
        """)
    connect_hid(ctx)
    assert ctx.eval("emulator.getInputState().gamepad.enabled")
    assert ctx.eval("emulator.getInputState().gamepad.hidConnected")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "connected"
    assert ctx.eval("emulator.getInputState().gamepad.transport") == "hid"
    assert not ctx.eval("emulator.getInputState().gamepad.ready")
    assert (
        ctx.eval("emulator.getInputState().gamepad.name") == "USB gamepad (WebHID)"
    )
    assert "Waiting for controller input" in ctx.eval(
        "emulator.getInputState().gamepad.status"
    )
    assert "Capture is off" not in ctx.eval("emulator.getInputState().gamepad.status")
    assert ctx.eval("emulator.activeJoystick") == 1
    assert ctx.eval("document.activeElement === canvas")
    assert ctx.eval("emulator.machine.joystick.has('1,up')")
    assert ctx.eval("emulator.machine.keys.has('1,2')")
    assert ctx.eval("emulator.machine.mouseButtons.has('left')")
    ctx.eval("emulator.runOneFrame();")
    assert ctx.eval("JSON.stringify(emulator.machine.mouseMoves)") == "[[5,4]]"


def test_hid_auto_capture_waits_for_first_report_and_respects_manual_off(emulator_ui):
    ctx = emulator_ui
    ctx.eval(
        "emulator.enableKeyboard(); emulator.running = true; emulator.setActiveJoystick(1);"
    )
    connect_hid(ctx)
    assert ctx.eval(
        "emulator.gamepadEnabled && emulator.getInputState().gamepad.autoCapture"
    )
    ctx.eval("""
        var hid = hidGamepadInputs[0];
        hid.gamepad.axes = [1, 0];
        hid.gamepad.buttons[0].pressed = true;
        """)
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "connected"
    assert not ctx.eval("emulator.getInputState().gamepad.ready")
    assert ctx.eval("emulator.machine.joystick.size") == 0
    ctx.eval("emulator.setGamepadEnabled(false); hid.report([1, 0], [0]);")
    assert ctx.eval("emulator.getInputState().gamepad.ready")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "connected"
    assert ctx.eval("emulator.machine.joystick.size") == 0
    ctx.eval("emulator.setGamepadEnabled(true);")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "active"
    assert ctx.eval("emulator.machine.joystick.has('1,right')")
    assert ctx.eval("emulator.machine.joystick.has('1,fire')")
    ctx.eval("document.activeElement = {}; dispatch(canvasListeners, 'blur');")
    assert ctx.eval("emulator.machine.joystick.size") == 0
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "connected"


@pytest.mark.parametrize(
    "api",
    [
        "delete navigator.getGamepads",
        "navigator.getGamepads = () => { throw new Error('SecurityError'); }",
    ],
)
def test_hid_fallback_works_when_the_gamepad_api_is_unavailable(emulator_ui, api):
    ctx = emulator_ui
    ctx.eval(f"""
        emulator.enableKeyboard(); emulator.running = true;
        emulator.setGamepadEnabled(true);
        {api};
        """)
    connect_hid(ctx)
    ctx.eval("hidGamepadInputs[0].report([-1, 0], [0]);")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "active"
    assert ctx.eval("emulator.getInputState().gamepad.transport") == "hid"
    assert ctx.eval("emulator.machine.joystick.has('2,left')")
    assert ctx.eval("emulator.machine.joystick.has('2,fire')")


def test_native_standard_gamepad_has_priority_and_survives_hid_disconnect(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var native = activateGamepad(); native.id = 'Native controller';
        native.axes = [1, 0]; emulator.pollGamepad();
        """)
    connect_hid(ctx)
    ctx.eval("hidGamepadInputs[0].report([-1, 0], [0]);")
    assert ctx.eval("emulator.getInputState().gamepad.transport") == "gamepad"
    assert ctx.eval("emulator.getInputState().gamepad.name") == "Native controller"
    assert ctx.eval("emulator.getInputState().gamepad.ready")
    assert ctx.eval("emulator.machine.joystick.has('2,right')")
    assert not ctx.eval("emulator.machine.joystick.has('2,left')")
    assert not ctx.eval("emulator.machine.joystick.has('2,fire')")
    ctx.eval("emulator.disconnectGamepadHid();")
    assert not ctx.eval("emulator.getInputState().gamepad.hidConnected")
    assert ctx.eval("emulator.getInputState().gamepad.transport") == "gamepad"
    assert ctx.eval("emulator.machine.joystick.has('2,right')")


def test_hid_takes_over_when_native_gamepad_disconnects_without_combining_holds(
    emulator_ui,
):
    ctx = emulator_ui
    ctx.eval("var native = activateGamepad(); native.axes = [1, 0];")
    connect_hid(ctx)
    ctx.eval("""
        hidGamepadInputs[0].report([-1, 0], [0]);
        gamepads = []; dispatch(windowListeners, 'gamepaddisconnected');
        """)
    assert ctx.eval("emulator.getInputState().gamepad.transport") == "hid"
    assert ctx.eval("emulator.machine.joystick.has('2,left')")
    assert ctx.eval("emulator.machine.joystick.has('2,fire')")
    assert not ctx.eval("emulator.machine.joystick.has('2,right')")


def test_hid_disconnect_releases_only_its_joystick_holds(emulator_ui):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval("""
        emulator.setGamepadEnabled(true);
        emulator.handleKeyPress(keyEvent('ArrowRight', 'ArrowRight'));
        emulator.handleKeyPress(keyEvent('a', 'KeyA'));
        dispatch(canvasListeners, 'pointerdown', mouseEvent());
        """)
    connect_hid(ctx)
    ctx.eval("""
        hidGamepadInputs[0].report([1, -1], [0]);
        emulator.disconnectGamepadHid();
        """)
    assert ctx.eval("emulator.gamepadEnabled")
    assert ctx.eval("emulator.machine.joystick.has('2,right')")
    assert not ctx.eval("emulator.machine.joystick.has('2,up')")
    assert not ctx.eval("emulator.machine.joystick.has('2,fire')")
    assert ctx.eval("emulator.machine.keys.has('1,2')")
    assert ctx.eval("emulator.machine.mouseButtons.has('left')")
    assert ctx.eval("emulator.getInputState().gamepad.transport") is None
    assert not ctx.eval("emulator.getInputState().gamepad.ready")


@pytest.mark.parametrize("capture", [False, True])
@pytest.mark.parametrize("outcome", ["cancel", "error"])
def test_hid_cancel_and_failure_preserve_capture_and_other_input_sources(
    emulator_ui, capture, outcome
):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval(f"""
        emulator.setActiveJoystick(1);
        emulator.setGamepadEnabled({str(capture).lower()});
        emulator.handleKeyPress(keyEvent('ArrowUp', 'ArrowUp'));
        emulator.handleKeyPress(keyEvent('a', 'KeyA'));
        dispatch(canvasListeners, 'pointerdown', mouseEvent());
        navigator.hid = {{ requestDevice() {{
            return {'Promise.resolve([])' if outcome == 'cancel' else "Promise.reject(new Error('Could not open controller'))"};
        }} }};
        var result = null, error = null;
        emulator.connectGamepadHid().then(value => {{ result = value; }},
            reason => {{ error = reason.message; }});
        """)
    assert ctx.eval("emulator.gamepadEnabled") is capture
    assert ctx.eval("emulator.activeJoystick") == 1
    assert not ctx.eval("emulator.getInputState().gamepad.hidConnected")
    assert ctx.eval("emulator.machine.joystick.has('1,up')")
    assert ctx.eval("emulator.machine.keys.has('1,2')")
    assert ctx.eval("emulator.machine.mouseButtons.has('left')")
    if outcome == "cancel":
        assert ctx.eval("result") is False
        assert ctx.eval("error") is None
    else:
        assert ctx.eval("result") is None
        assert ctx.eval("error") == "Could not open controller"


def test_hid_reports_update_input_without_emitting_repeated_state_notifications(
    emulator_ui,
):
    ctx = emulator_ui
    ctx.eval(
        "emulator.enableKeyboard(); emulator.running = true; emulator.setGamepadEnabled(true);"
    )
    connect_hid(ctx)
    ctx.eval("""
        var changes = [];
        emulator.onInputChange(state => changes.push(state));
        var hid = hidGamepadInputs[0];
        hid.report([1, 0]);
        hid.report([-1, 0]);
        emulator.pollGamepad(); emulator.pollGamepad();
        """)
    assert ctx.eval("changes.length") == 1
    assert ctx.eval("changes[0].gamepad.ready")
    assert ctx.eval("changes[0].gamepad.connection") == "active"
    assert ctx.eval("emulator.machine.joystick.has('2,left')")
    assert not ctx.eval("emulator.machine.joystick.has('2,right')")
    ctx.eval("emulator.disconnectGamepadHid(); emulator.pollGamepad();")
    assert ctx.eval("changes.length") == 2
    assert not ctx.eval("changes[1].gamepad.hidConnected")
    assert ctx.eval("emulator.machine.joystick.size") == 0


def test_descriptor_controller_reaches_joystick_and_preserves_keyboard_and_mouse(
    emulator_ui,
):
    ctx = emulator_ui
    ctx.eval(strip_es6_imports_exports(load_js_file(JS_DIR / "gamepad-hid-reports.js")))
    adapter = strip_es6_imports_exports(load_js_file(JS_DIR / "gamepad-hid.js"))
    ctx.eval(adapter.replace("class HidGamepadInput", "HidGamepadInput = class", 1))
    activate_mouse(ctx)
    ctx.eval("""
        emulator.setActiveJoystick(1);
        emulator.setGamepadEnabled(true);
        emulator.handleKeyPress(keyEvent('ArrowRight', 'ArrowRight'));
        dispatch(canvasListeners, 'pointerdown', mouseEvent());
        var inputReport;
        var descriptorDevice = {
            vendorId: 0x1209, productId: 1, productName: 'HID joystick', opened: false,
            collections: [{ usagePage: 1, usage: 4, inputReports: [{ reportId: 0, items: [
                { isAbsolute: true, reportSize: 8, reportCount: 2,
                  logicalMinimum: -127, logicalMaximum: 127, usages: [0x10030, 0x10031] },
                { isAbsolute: true, reportSize: 8, reportCount: 1,
                  logicalMinimum: 0, logicalMaximum: 1, usages: [0x90001] }
            ] }] }],
            async open() { this.opened = true; },
            async close() { this.opened = false; },
            addEventListener(type, listener) { inputReport = listener; },
            removeEventListener() {}
        };
        navigator.hid = {
            requestDevice: async () => [descriptorDevice],
            addEventListener() {}, removeEventListener() {}
        };
    """)
    ctx.eval("""
        var decodeFails = false;
        var wrappedDecoder = info => {
            const decode = createHidGamepadDecoder(info);
            return (...args) => {
                if (decodeFails) throw new Error('Unreadable packet');
                return decode(...args);
            };
        };
    """)
    assert ctx.eval(
        "emulator.connectGamepadHid({ createDecoder: wrappedDecoder })"
    ).get(timeout=2)
    ctx.eval("""
        inputReport({ reportId: 0, data: new DataView(new Uint8Array([129, 129, 1]).buffer) });
        emulator.pollGamepad();
    """)
    assert ctx.eval("emulator.getInputState().gamepad.name") == "HID joystick (WebHID)"
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "active"
    assert ctx.eval(
        "emulator.machine.joystick.has('1,left') && emulator.machine.joystick.has('1,up') && emulator.machine.joystick.has('1,fire')"
    )
    assert ctx.eval(
        "emulator.machine.joystick.has('1,right') && emulator.machine.mouseButtons.has('left')"
    )
    ctx.eval("""
        inputReport({ reportId: 0, data: new DataView(new Uint8Array([0, 0, 0]).buffer) });
        emulator.pollGamepad();
    """)
    assert ctx.eval(
        "!emulator.machine.joystick.has('1,left') && !emulator.machine.joystick.has('1,up') && !emulator.machine.joystick.has('1,fire')"
    )
    assert ctx.eval(
        "emulator.machine.joystick.has('1,right') && emulator.machine.mouseButtons.has('left')"
    )
    ctx.eval("""
        decodeFails = true;
        inputReport({ reportId: 0, data: new DataView(new Uint8Array([129, 129, 1]).buffer) });
    """)
    assert not ctx.eval("emulator.getInputState().gamepad.ready")
    assert "Unreadable packet" in ctx.eval("emulator.getInputState().gamepad.error")
    assert ctx.eval(
        "!emulator.machine.joystick.has('1,left') && !emulator.machine.joystick.has('1,fire')"
    )
    assert ctx.eval(
        "emulator.machine.joystick.has('1,right') && emulator.machine.mouseButtons.has('left')"
    )
    ctx.eval("""
        decodeFails = false;
        inputReport({ reportId: 0, data: new DataView(new Uint8Array([129, 129, 1]).buffer) });
    """)
    assert ctx.eval("emulator.getInputState().gamepad.error") == ""
    assert ctx.eval("emulator.getInputState().gamepad.ready")
    assert ctx.eval(
        "emulator.machine.joystick.has('1,left') && emulator.machine.joystick.has('1,fire')"
    )
    ctx.eval("emulator.disconnectGamepadHid()").get(timeout=2)
    assert ctx.eval(
        "emulator.gamepadEnabled && emulator.mouseEnabled && emulator.activeJoystick === 1"
    )
    assert ctx.eval(
        "emulator.machine.joystick.has('1,right') && emulator.machine.mouseButtons.has('left')"
    )


def test_custom_mapper_accepts_raw_controller_layout_and_keeps_capture_and_port(
    emulator_ui,
):
    ctx = emulator_ui
    ctx.eval("""
        var raw = activateGamepad(1);
        raw.id = 'Raw layout'; raw.mapping = ''; raw.axes = [0, 0, -1, 1];
        raw.buttons[7].pressed = true;
        emulator.setGamepadMapper((pad, { transport }) => {
            if (pad.id !== 'Raw layout' || transport !== 'gamepad') return null;
            const actions = [];
            if (pad.axes[2] < -0.2) actions.push('left');
            if (pad.axes[3] > 0.2) actions.push('up');
            if (pad.buttons[7].pressed) actions.push('fire');
            return actions;
        });
    """)
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "active"
    assert ctx.eval("emulator.getInputState().gamepad.mapping") == "custom"
    assert ctx.eval("emulator.gamepadEnabled && emulator.activeJoystick === 1")
    assert ctx.eval(
        "['left', 'up', 'fire'].every(action => emulator.machine.joystick.has('1,' + action))"
    )
    assert "custom controller bindings" in ctx.eval(
        "emulator.getInputState().gamepad.status"
    )
    ctx.eval("emulator.setGamepadMapper(null);")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "unsupported"
    assert ctx.eval(
        "emulator.machine.joystick.size === 0 && emulator.gamepadEnabled && emulator.activeJoystick === 1"
    )


def test_mapper_can_select_a_device_and_restore_automatic_selection(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var first = activateGamepad(); first.id = 'First'; first.axes = [-1, 0];
        var second = standardGamepad([1, 0]); second.id = 'Second';
        gamepads = [null, first, null, second];
        emulator.setGamepadMapper((pad) => pad.id === 'Second' ? mapGamepadToJoystick(pad) : null);
    """)
    assert ctx.eval("emulator.getInputState().gamepad.name") == "Second"
    assert ctx.eval(
        "emulator.machine.joystick.has('2,right') && !emulator.machine.joystick.has('2,left')"
    )
    ctx.eval("emulator.setGamepadMapper();")
    assert ctx.eval("emulator.getInputState().gamepad.name") == "First"
    assert ctx.eval(
        "emulator.machine.joystick.has('2,left') && !emulator.machine.joystick.has('2,right')"
    )


def test_custom_dead_zone_and_mutable_mapper_output_release_old_holds(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var pad = activateGamepad(); pad.axes = [0.3, 0];
        emulator.setGamepadMapper(pad => mapGamepadToJoystick(pad, { deadZone: 0.2 }));
    """)
    assert ctx.eval("emulator.machine.joystick.has('2,right')")
    ctx.eval("""
        var held = new Set(['left', 'fire']);
        emulator.setGamepadMapper(() => held);
        held.clear(); emulator.pollGamepad();
    """)
    assert ctx.eval("emulator.machine.joystick.size") == 0


@pytest.mark.parametrize(
    "failure",
    [
        "throw new Error('Bad profile')",
        "throw null",
        "return ['jump']",
        "return 'left'",
        "return undefined",
        "return Promise.resolve(['left'])",
    ],
)
def test_mapper_errors_release_gamepad_only_and_recover(emulator_ui, failure):
    ctx = emulator_ui
    activate_mouse(ctx)
    ctx.eval(f"""
        emulator.setActiveJoystick(1);
        var pad = standardGamepad([-1, 0], [0]); gamepads = [pad];
        emulator.setGamepadEnabled(true);
        emulator.handleKeyPress(keyEvent('ArrowRight', 'ArrowRight'));
        dispatch(canvasListeners, 'pointerdown', mouseEvent());
        emulator.setGamepadMapper(() => {{ {failure}; }});
    """)
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "unsupported"
    assert "Controller mapping failed:" in ctx.eval(
        "emulator.getInputState().gamepad.error"
    )
    assert ctx.eval(
        "!emulator.machine.joystick.has('1,left') && !emulator.machine.joystick.has('1,fire')"
    )
    assert ctx.eval(
        "emulator.machine.joystick.has('1,right') && emulator.machine.mouseButtons.has('left')"
    )
    ctx.eval("emulator.setGamepadMapper(null);")
    assert ctx.eval("emulator.getInputState().gamepad.error") == ""
    assert ctx.eval(
        "emulator.machine.joystick.has('1,left') && emulator.machine.joystick.has('1,fire')"
    )


def test_configuring_mapper_does_not_start_discovery_or_enable_capture(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var polls = 0; navigator.getGamepads = () => { polls++; return []; };
        emulator.setGamepadMapper(() => []);
    """)
    assert ctx.eval(
        "polls === 0 && !emulator.gamepadEnabled && !emulator.gamepadDiscoveryStarted"
    )
    assert ctx.eval("emulator.activeJoystick") == 0
    assert "must be a function" in ctx.eval(
        "(() => { try { emulator.setGamepadMapper(42); } catch (error) { return error.message; } })()"
    )


def test_custom_hid_factory_respects_observation_only_capture_policy(emulator_ui):
    ctx = emulator_ui
    ctx.eval("emulator.setGamepadAutoCapture(false);")
    connect_hid(ctx)
    ctx.eval("emulator.disconnectGamepadHid(); var customDecoder = () => null;")
    assert ctx.eval("emulator.connectGamepadHid({ createDecoder: customDecoder })").get(
        timeout=2
    )
    assert ctx.eval("hidGamepadInputs[0].options.createDecoder === customDecoder")
    assert ctx.eval("!emulator.gamepadEnabled && emulator.activeJoystick === 0")


@pytest.mark.parametrize("port", [0, 1, 2])
def test_discovery_automatically_captures_a_supported_controller(emulator_ui, port):
    ctx = emulator_ui
    ctx.eval(f"""
        emulator.enableKeyboard(); emulator.running = true;
        emulator.setActiveJoystick({port});
        gamepads = [standardGamepad([1, -1], [0])];
        emulator.startGamepadDiscovery();
    """)
    selected_port = port or 2
    assert ctx.eval("emulator.getInputState().gamepad.autoCapture")
    assert ctx.eval("emulator.getInputState().gamepad.enabled")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "active"
    assert ctx.eval("emulator.activeJoystick") == selected_port
    assert ctx.eval(
        f"['right', 'up', 'fire'].every(button => emulator.machine.joystick.has('{selected_port},' + button))"
    )


def test_manual_capture_off_survives_polling_reconnect_and_transport_changes(
    emulator_ui,
):
    ctx = emulator_ui
    ctx.eval("""
        emulator.enableKeyboard(); emulator.running = true;
        gamepads = [standardGamepad([1, 0], [0])];
        emulator.startGamepadDiscovery();
        emulator.setGamepadEnabled(false);
        gamepads = [standardGamepad([-1, 0], [1])];
        emulator.pollGamepad();
        gamepads = []; dispatch(windowListeners, 'gamepaddisconnected');
        gamepads = [standardGamepad([1, 0], [0])];
        dispatch(windowListeners, 'gamepadconnected');
    """)
    assert ctx.eval(
        "!emulator.gamepadEnabled && !emulator.getInputState().gamepad.autoCapture"
    )
    assert ctx.eval("emulator.machine.joystick.size") == 0
    ctx.eval("gamepads = [];")
    connect_hid(ctx)
    ctx.eval("hidGamepadInputs[0].report([1, 0], [0]); emulator.pollGamepad();")
    assert ctx.eval(
        '!emulator.gamepadEnabled && emulator.getInputState().gamepad.transport === "hid"'
    )
    assert ctx.eval("emulator.machine.joystick.size") == 0
    ctx.eval("emulator.setGamepadAutoCapture(true);")
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "active"
    assert ctx.eval(
        "emulator.machine.joystick.has('2,right') && emulator.machine.joystick.has('2,fire')"
    )


def test_constructor_can_keep_gamepad_discovery_observation_only(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        emulator = new C64Emulator('screen', { audioEnabled: false, gamepadAutoCapture: false });
        emulator.enableKeyboard(); emulator.running = true;
        gamepads = [standardGamepad([1, 0], [0])];
        emulator.startGamepadDiscovery();
    """)
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "connected"
    assert ctx.eval(
        "!emulator.gamepadEnabled && !emulator.getInputState().gamepad.autoCapture"
    )
    assert ctx.eval(
        "emulator.activeJoystick === 0 && emulator.machine.joystick.size === 0"
    )


@pytest.mark.parametrize(
    "context",
    [
        "emulator.paused = true",
        "emulator.running = false",
        "emulator.keyboardEnabled = false",
        "document.hidden = true",
        "document.activeElement = {}",
        "pageFocused = false",
    ],
)
def test_auto_capture_keeps_input_gated_until_the_screen_can_receive_it(
    emulator_ui, context
):
    ctx = emulator_ui
    ctx.eval(f"""
        emulator.enableKeyboard(); emulator.running = true;
        {context};
        gamepads = [standardGamepad([1, 0], [0])];
        emulator.startGamepadDiscovery();
    """)
    assert ctx.eval("emulator.gamepadEnabled")
    assert ctx.eval("emulator.machine.joystick.size") == 0
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "connected"
    ctx.eval("""
        emulator.paused = false; emulator.running = true; emulator.keyboardEnabled = true;
        document.hidden = false; document.activeElement = canvas; pageFocused = true;
        emulator.pollGamepad();
    """)
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "active"
    assert ctx.eval(
        "emulator.machine.joystick.has('2,right') && emulator.machine.joystick.has('2,fire')"
    )


def test_manual_off_during_a_pending_connection_is_preserved(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var chooseDevice;
        navigator.hid = { requestDevice: () => new Promise(resolve => { chooseDevice = resolve; }) };
        var pendingConnection = emulator.connectGamepadHid();
        emulator.setGamepadEnabled(false);
        chooseDevice([{ productName: 'Bluetooth controller' }]);
    """)
    assert ctx.eval("pendingConnection").get(timeout=2)
    ctx.eval("hidGamepadInputs[0].report([1, 0], [0]);")
    assert ctx.eval("emulator.getInputState().gamepad.hidConnected")
    assert ctx.eval(
        "!emulator.gamepadEnabled && !emulator.getInputState().gamepad.autoCapture"
    )
    assert ctx.eval(
        "emulator.activeJoystick === 0 && emulator.machine.joystick.size === 0"
    )


@pytest.mark.parametrize(
    "outcome", ["Promise.resolve([])", "Promise.reject(new Error('Device busy'))"]
)
def test_cancel_or_failure_does_not_start_automatic_capture(emulator_ui, outcome):
    ctx = emulator_ui
    ctx.eval(f"navigator.hid = {{ requestDevice: () => {outcome} }};")
    ctx.eval("emulator.connectGamepadHid().catch(() => false)").get(timeout=2)
    assert ctx.eval(
        "!emulator.gamepadEnabled && emulator.getInputState().gamepad.autoCapture"
    )
    assert ctx.eval(
        "emulator.activeJoystick === 0 && emulator.machine.joystick.size === 0"
    )


def test_turning_off_automatic_capture_preserves_capture_already_enabled(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        emulator.enableKeyboard(); emulator.running = true;
        gamepads = [standardGamepad([1, 0], [0])];
        emulator.startGamepadDiscovery(); emulator.setGamepadAutoCapture(false);
    """)
    assert ctx.eval(
        "emulator.gamepadEnabled && !emulator.getInputState().gamepad.autoCapture"
    )
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "active"


def test_unsupported_controller_does_not_enable_capture_or_change_port(emulator_ui):
    ctx = emulator_ui
    ctx.eval("""
        var raw = standardGamepad([1, 0], [0]); raw.mapping = '';
        gamepads = [raw]; emulator.startGamepadDiscovery();
    """)
    assert ctx.eval("emulator.getInputState().gamepad.connection") == "unsupported"
    assert ctx.eval("!emulator.gamepadEnabled && emulator.activeJoystick === 0")
