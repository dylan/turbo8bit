"""Read-only Pro Controller packets and WebHID connection lifecycles."""

import json

import pytest

from tests.test_utils import (
    JS_DIR,
    create_mini_racer_context,
    load_js_file,
    strip_es6_imports_exports,
)


@pytest.fixture
def pro_controller():
    ctx = create_mini_racer_context()
    ctx.eval("""
        function eventTarget() {
            const listeners = new Map();
            return {
                addEventListener(type, callback) {
                    if (!listeners.has(type)) listeners.set(type, new Set());
                    listeners.get(type).add(callback);
                },
                removeEventListener(type, callback) {
                    listeners.get(type)?.delete(callback);
                },
                emit(type, event) {
                    for (const callback of [...(listeners.get(type) || [])]) callback(event);
                },
                count(type) { return listeners.get(type)?.size || 0; },
                first(type) { return [...(listeners.get(type) || [])][0]; }
            };
        }
        function deferred() {
            let resolve, reject;
            const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
            return { promise, resolve, reject };
        }
        var openGate = null;
        var closeGate = null;
        var openError = null;
        var closeError = null;
        var openCalls = 0;
        var closeCalls = 0;
        var outputCalls = 0;
        var device = Object.assign(eventTarget(), {
            vendorId: 0x057e,
            productId: 0x2009,
            productName: 'Pro Controller',
            opened: false,
            async open() {
                openCalls++;
                if (openGate) await openGate.promise;
                if (openError) throw new Error(openError);
                this.opened = true;
            },
            async close() {
                closeCalls++;
                if (closeGate) await closeGate.promise;
                this.opened = false;
                if (closeError) throw new Error(closeError);
            },
            sendReport() { outputCalls++; throw new Error('Unexpected output'); },
            sendFeatureReport() { outputCalls++; throw new Error('Unexpected output'); },
            receiveFeatureReport() { outputCalls++; throw new Error('Unexpected feature request'); }
        });
        var chooser = null;
        var selected = [device];
        var requestCalls = 0;
        var requestOptions = null;
        var hid = Object.assign(eventTarget(), {
            requestDevice(options) {
                requestCalls++;
                requestOptions = options;
                return chooser ? chooser.promise : Promise.resolve(selected);
            }
        });
        var navigator = { hid };
        var changes = [];
        function report(bytes, reportId = 0x30, byteOffset = 0) {
            const buffer = new Uint8Array(bytes.length + byteOffset + 2);
            buffer.set(bytes, byteOffset);
            device.emit('inputreport', {
                device, reportId,
                data: new DataView(buffer.buffer, byteOffset, bytes.length)
            });
        }
        """)
    ctx.eval(strip_es6_imports_exports(load_js_file(JS_DIR / "pro-controller.js")))
    ctx.eval("""
        var input = new ProControllerInput(() => changes.push({
            connected: input.connected, ready: input.ready,
            gamepad: input.gamepad === null ? null : input.gamepad.id
        }));
        """)
    yield ctx
    ctx.close()


def await_js(ctx, source):
    return ctx.eval(source).get(timeout=2)


def connect(ctx):
    assert await_js(ctx, "input.connect()") is True


def test_connection_is_explicit_filtered_singleflight_and_neutral(pro_controller):
    ctx = pro_controller
    assert ctx.eval("requestCalls") == 0
    assert ctx.eval("input.gamepad === null && !input.connected && !input.ready")
    ctx.eval("chooser = deferred(); var pending = input.connect();")
    assert ctx.eval("requestCalls") == 1
    assert ctx.eval("pending === input.connect()")
    assert json.loads(ctx.eval("JSON.stringify(requestOptions)")) == {
        "filters": [{"vendorId": 0x057E, "productId": 0x2009}]
    }
    ctx.eval("chooser.resolve([device]);")
    assert await_js(ctx, "pending") is True
    assert ctx.eval("input.connected && !input.ready")
    assert ctx.eval("input.gamepad.connected && input.gamepad.mapping === 'standard'")
    assert ctx.eval("input.gamepad.id") == "Pro Controller (WebHID)"
    assert ctx.eval("JSON.stringify(input.gamepad.axes)") == "[0,0]"
    assert ctx.eval("input.gamepad.buttons.length") == 17
    assert ctx.eval(
        "input.gamepad.buttons.every(button => !button.pressed && button.value === 0)"
    )
    assert await_js(ctx, "input.connect()") is True
    assert ctx.eval("requestCalls") == 1
    assert ctx.eval("changes.length") == 1
    assert ctx.eval(
        "device.count('inputreport') === 1 && hid.count('disconnect') === 1"
    )
    assert ctx.eval("outputCalls") == 0


@pytest.mark.parametrize("cancellation", ["empty", "not_found", "wrong_device"])
def test_cancelled_or_unmatched_chooser_does_not_connect(pro_controller, cancellation):
    ctx = pro_controller
    if cancellation == "empty":
        ctx.eval("selected = [];")
    elif cancellation == "wrong_device":
        ctx.eval("selected = [{ vendorId: 0x057e, productId: 0x2006 }];")
    else:
        ctx.eval("""
            hid.requestDevice = () => Promise.reject(
                Object.assign(new Error('Cancelled'), { name: 'NotFoundError' }));
            """)
    assert await_js(ctx, "input.connect()") is False
    assert ctx.eval("!input.connected && !input.ready && input.gamepad === null")
    assert ctx.eval("openCalls === 0 && changes.length === 0")
    assert ctx.eval(
        "device.count('inputreport') === 0 && hid.count('disconnect') === 0"
    )


@pytest.mark.parametrize("failure", ["unavailable", "permission", "open"])
def test_connection_failure_is_reported_and_leaves_no_listeners(
    pro_controller, failure
):
    ctx = pro_controller
    if failure == "unavailable":
        ctx.eval("delete navigator.hid;")
        expected = "does not support WebHID"
    elif failure == "permission":
        ctx.eval(
            "hid.requestDevice = () => Promise.reject(new Error('Permission denied'));"
        )
        expected = "Permission denied"
    else:
        ctx.eval("openError = 'Device busy';")
        expected = "Could not open the Pro Controller: Device busy"
    message = await_js(ctx, "input.connect().catch(error => error.message)")
    assert expected in message
    assert ctx.eval("!input.connected && !input.ready && input.gamepad === null")
    assert ctx.eval(
        "device.count('inputreport') === 0 && hid.count('disconnect') === 0"
    )
    assert ctx.eval("changes.length === 0 && outputCalls === 0")


@pytest.mark.parametrize(
    "packed, axes",
    [
        ([0x00, 0x08, 0x80], [0, 0]),
        ([0xFF, 0x0F, 0x80], [1, 0]),
        ([0x00, 0x00, 0x80], [-1, 0]),
        ([0x00, 0xF8, 0xFF], [0, -1]),
        ([0x00, 0x08, 0x00], [0, 1]),
        ([0xFF, 0xFF, 0xFF], [1, -1]),
    ],
)
def test_full_report_packed_stick_extremes(pro_controller, packed, axes):
    ctx = pro_controller
    connect(ctx)
    packet = [0, 0, 0, 0, 0, *packed, 0, 0, 0, 0]
    ctx.eval(f"report({json.dumps(packet)});")
    assert json.loads(ctx.eval("JSON.stringify(input.gamepad.axes)")) == axes
    assert ctx.eval("input.ready && changes.length === 2 && outputCalls === 0")


@pytest.mark.parametrize(
    "buttons, expected",
    [
        ([0x04, 0, 0], 0),
        ([0x08, 0, 0], 1),
        ([0x01, 0, 0], 2),
        ([0x02, 0, 0], 3),
        ([0, 0, 0x40], 4),
        ([0x40, 0, 0], 5),
        ([0, 0, 0x80], 6),
        ([0x80, 0, 0], 7),
        ([0, 0x01, 0], 8),
        ([0, 0x02, 0], 9),
        ([0, 0x08, 0], 10),
        ([0, 0x04, 0], 11),
        ([0, 0, 0x02], 12),
        ([0, 0, 0x01], 13),
        ([0, 0, 0x08], 14),
        ([0, 0, 0x04], 15),
        ([0, 0x10, 0], 16),
    ],
)
def test_full_report_buttons_use_standard_positions(pro_controller, buttons, expected):
    ctx = pro_controller
    connect(ctx)
    packet = [0, 0, *buttons, 0x00, 0x08, 0x80, 0, 0, 0, 0]
    ctx.eval(f"report({json.dumps(packet)});")
    assert json.loads(
        ctx.eval(
            "JSON.stringify(input.gamepad.buttons.flatMap((button, i) => button.pressed ? [i] : []))"
        )
    ) == [expected]
    assert ctx.eval(f"input.gamepad.buttons[{expected}].value") == 1
    ctx.eval("report([0, 0, 0, 0, 0, 0, 8, 128, 0, 0, 0, 0]);")
    assert ctx.eval(
        "input.gamepad.buttons.every(button => !button.pressed && button.value === 0)"
    )
    assert ctx.eval("changes.length === 2 && outputCalls === 0")


def test_reply_report_dataview_offset_and_notification_deduplication(pro_controller):
    ctx = pro_controller
    connect(ctx)
    ctx.eval("""
        report([0, 0, 4, 0, 2, 255, 255, 255, 0, 0, 0, 0], 0x21, 3);
        var padIdentity = input.gamepad;
        report([0, 0, 8, 0, 8, 0, 0, 0, 0, 0, 0, 0], 0x30, 5);
        """)
    assert ctx.eval("input.gamepad === padIdentity && input.ready")
    assert ctx.eval("JSON.stringify(input.gamepad.axes)") == "[-1,1]"
    assert ctx.eval(
        "input.gamepad.buttons[1].pressed && input.gamepad.buttons[14].pressed"
    )
    assert ctx.eval(
        "!input.gamepad.buttons[0].pressed && !input.gamepad.buttons[12].pressed"
    )
    assert ctx.eval("changes.length === 2 && outputCalls === 0")


def test_unknown_and_short_reports_never_establish_readiness(pro_controller):
    ctx = pro_controller
    connect(ctx)
    ctx.eval("""
        report([0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0], 0x3f);
        report([0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0], 0x30);
        device.emit('inputreport', { reportId: 0x30, data: null });
        """)
    assert ctx.eval("!input.ready && changes.length === 1")
    assert ctx.eval("JSON.stringify(input.gamepad.axes)") == "[0,0]"
    assert ctx.eval("input.gamepad.buttons.every(button => !button.pressed)")


@pytest.mark.parametrize("unplugged", [False, True])
def test_disconnect_releases_immediately_and_removes_all_listeners(
    pro_controller, unplugged
):
    ctx = pro_controller
    connect(ctx)
    ctx.eval("""
        report([0, 0, 4, 0, 2, 255, 255, 255, 0, 0, 0, 0]);
        hid.emit('disconnect', { device: {} });
        """)
    assert ctx.eval("input.connected && input.ready")
    if unplugged:
        ctx.eval("closeError = 'Device offline'; hid.emit('disconnect', { device });")
    else:
        ctx.eval("var closing = input.disconnect();")
    assert ctx.eval("!input.connected && !input.ready && input.gamepad === null")
    assert ctx.eval(
        "device.count('inputreport') === 0 && hid.count('disconnect') === 0"
    )
    await_js(ctx, "input.disconnect()")
    assert ctx.eval("changes.length === 3 && closeCalls === 1 && outputCalls === 0")


def test_disconnect_cancels_pending_chooser_without_late_open(pro_controller):
    ctx = pro_controller
    ctx.eval("chooser = deferred(); var pending = input.connect();")
    await_js(ctx, "input.disconnect()")
    ctx.eval("chooser.resolve([device]);")
    assert await_js(ctx, "pending") is False
    assert ctx.eval("openCalls === 0 && changes.length === 0 && input.gamepad === null")
    ctx.eval("chooser = null;")
    connect(ctx)
    assert ctx.eval("openCalls === 1 && input.connected")


def test_disconnect_cancels_pending_open_and_closes_late_device(pro_controller):
    ctx = pro_controller
    ctx.eval("openGate = deferred(); var pending = input.connect();")
    await_js(ctx, "Promise.resolve()")
    assert ctx.eval("openCalls") == 1
    await_js(ctx, "input.disconnect()")
    assert ctx.eval(
        "device.count('inputreport') === 0 && hid.count('disconnect') === 0"
    )
    ctx.eval("openGate.resolve();")
    assert await_js(ctx, "pending") is False
    assert ctx.eval("!device.opened && closeCalls === 1 && changes.length === 0")
    assert ctx.eval("!input.connected && input.gamepad === null && outputCalls === 0")


def test_reconnect_waits_for_close_and_ignores_old_input_listener(pro_controller):
    ctx = pro_controller
    connect(ctx)
    ctx.eval("""
        var oldListener = device.first('inputreport');
        closeGate = deferred();
        var closing = input.disconnect();
        var pending = input.connect();
        """)
    await_js(ctx, "Promise.resolve()")
    assert ctx.eval("requestCalls === 2 && openCalls === 1 && !input.connected")
    ctx.eval("closeGate.resolve();")
    await_js(ctx, "closing")
    assert await_js(ctx, "pending") is True
    ctx.eval("""
        oldListener({ reportId: 0x30, data: new DataView(new ArrayBuffer(12)) });
        """)
    assert ctx.eval("input.connected && !input.ready")
    assert ctx.eval("openCalls === 2 && closeCalls === 1 && changes.length === 3")
    assert ctx.eval(
        "device.count('inputreport') === 1 && hid.count('disconnect') === 1"
    )
    assert ctx.eval("outputCalls") == 0


def test_retry_can_finish_while_cancelled_chooser_is_unresolved(pro_controller):
    ctx = pro_controller
    ctx.eval(
        "chooser = deferred(); var oldChooser = chooser; var oldPending = input.connect();"
    )
    await_js(ctx, "input.disconnect()")
    ctx.eval("chooser = null; var retry = input.connect();")
    assert ctx.eval("retry !== oldPending && requestCalls === 2")
    assert await_js(ctx, "retry") is True
    ctx.eval("oldChooser.resolve([device]);")
    assert await_js(ctx, "oldPending") is False
    assert ctx.eval("input.connected && openCalls === 1 && closeCalls === 0")
    assert ctx.eval("changes.length === 1 && device.count('inputreport') === 1")


def test_stale_chooser_does_not_clear_a_new_pending_connection(pro_controller):
    ctx = pro_controller
    ctx.eval(
        "chooser = deferred(); var oldChooser = chooser; var oldPending = input.connect();"
    )
    await_js(ctx, "input.disconnect()")
    ctx.eval(
        "chooser = deferred(); var retry = input.connect(); oldChooser.resolve([device]);"
    )
    assert await_js(ctx, "oldPending") is False
    assert ctx.eval("input.connect() === retry && requestCalls === 2")
    ctx.eval("chooser.resolve([device]);")
    assert await_js(ctx, "retry") is True
    assert ctx.eval("openCalls === 1 && changes.length === 1")


@pytest.mark.parametrize("same_device", [False, True])
@pytest.mark.parametrize("old_open_fails", [False, True])
def test_retry_survives_cancelled_open_completing_late(
    pro_controller, same_device, old_open_fails
):
    ctx = pro_controller
    ctx.eval(
        "openGate = deferred(); var oldOpen = openGate; var oldPending = input.connect();"
    )
    await_js(ctx, "Promise.resolve()")
    ctx.eval("""
        var oldInputListener = device.first('inputreport');
        var oldDisconnectListener = hid.first('disconnect');
        """)
    await_js(ctx, "input.disconnect()")
    if not same_device:
        ctx.eval("""
            var replacement = Object.assign(eventTarget(), {
                vendorId: 0x057e, productId: 0x2009, productName: 'Second Pro Controller',
                opened: false, open: device.open, close: device.close
            });
            selected = [replacement];
            """)
    ctx.eval("openGate = null; var retry = input.connect();")
    assert ctx.eval("retry !== oldPending && requestCalls === 2")
    assert await_js(ctx, "retry") is True
    if old_open_fails:
        ctx.eval("openError = 'Old connection failed';")
    ctx.eval("oldOpen.resolve();")
    assert await_js(ctx, "oldPending") is False
    ctx.eval("""
        oldInputListener({ reportId: 0x30, data: new DataView(new ArrayBuffer(12)) });
        oldDisconnectListener({ device });
        """)
    assert ctx.eval("input.connected && !input.ready && changes.length === 1")
    assert ctx.eval("openCalls") == 2
    assert ctx.eval("closeCalls") == int(not same_device and not old_open_fails)
    current_device = "device" if same_device else "replacement"
    assert ctx.eval(
        f"{current_device}.opened && {current_device}.count('inputreport') === 1"
    )
    assert ctx.eval("hid.count('disconnect') === 1 && outputCalls === 0")


def test_late_open_cleanup_finishes_before_retry_reuses_device(pro_controller):
    ctx = pro_controller
    ctx.eval(
        "openGate = deferred(); var oldOpen = openGate; var oldPending = input.connect();"
    )
    await_js(ctx, "Promise.resolve()")
    await_js(ctx, "input.disconnect()")
    ctx.eval("""
        chooser = deferred();
        var retry = input.connect();
        closeGate = deferred();
        oldOpen.resolve();
        """)
    await_js(ctx, "Promise.resolve()")
    assert ctx.eval("closeCalls") == 1
    ctx.eval("chooser.resolve([device]);")
    await_js(ctx, "Promise.resolve()")
    assert ctx.eval("openCalls === 1 && !input.connected")
    ctx.eval("openGate = null; closeGate.resolve();")
    assert await_js(ctx, "oldPending") is False
    assert await_js(ctx, "retry") is True
    assert ctx.eval(
        "input.connected && device.opened && openCalls === 2 && closeCalls === 1"
    )
    assert ctx.eval("changes.length === 1 && outputCalls === 0")
