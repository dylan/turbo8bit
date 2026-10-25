const PRO_CONTROLLER_FILTER = { vendorId: 0x057e, productId: 0x2009 };
const PRO_CONTROLLER_BUTTONS = [
    [2, 0x04], [2, 0x08], [2, 0x01], [2, 0x02],
    [4, 0x40], [2, 0x40], [4, 0x80], [2, 0x80],
    [3, 0x01], [3, 0x02], [3, 0x08], [3, 0x04],
    [4, 0x02], [4, 0x01], [4, 0x08], [4, 0x04], [3, 0x10]
];

// Optional, read-only fallback for a Pro Controller the Gamepad API cannot expose.
export class ProControllerInput {
    constructor(onChange = () => {}) {
        this.onChange = onChange;
        this.connected = false;
        this.ready = false;
        this.gamepad = null;
        this._device = null;
        this._hid = null;
        this._inputListener = null;
        this._disconnectListener = null;
        this._generation = 0;
        this._connecting = null;
        this._closing = null;
    }

    connect() {
        if (this._connecting) return this._connecting;
        if (this.connected) return Promise.resolve(true);
        const pending = this._connect(++this._generation);
        this._connecting = pending;
        const clearPending = () => {
            if (this._connecting === pending) this._connecting = null;
        };
        pending.then(clearPending, clearPending);
        return pending;
    }

    async _connect(generation) {
        const hid = globalThis.navigator?.hid;
        if (!hid || typeof hid.requestDevice !== 'function') {
            throw new Error('This browser does not support WebHID. Use the Gamepad API or a browser with WebHID support.');
        }
        let devices;
        try {
            devices = await hid.requestDevice({ filters: [PRO_CONTROLLER_FILTER] });
        } catch (error) {
            if (generation !== this._generation || error.name === 'NotFoundError') return false;
            throw error;
        }
        if (generation !== this._generation) return false;
        const device = devices.find(candidate =>
            candidate.vendorId === PRO_CONTROLLER_FILTER.vendorId &&
            candidate.productId === PRO_CONTROLLER_FILTER.productId);
        if (!device) return false;
        if (this._closing) await this._closing;
        if (generation !== this._generation) return false;

        this._device = device;
        this._hid = hid;
        this._inputListener = event => {
            if (generation === this._generation && this._device === device && this.connected) {
                this._readReport(event.reportId, event.data);
            }
        };
        this._disconnectListener = event => {
            if (generation === this._generation && event.device === device && this._device === device) {
                void this.disconnect();
            }
        };
        device.addEventListener('inputreport', this._inputListener);
        hid.addEventListener('disconnect', this._disconnectListener);
        try {
            if (!device.opened) await device.open();
            if (generation !== this._generation) {
                await this._closeIfUnclaimed(device);
                return false;
            }
            this.gamepad = {
                id: `${device.productName || 'Nintendo Switch Pro Controller'} (WebHID)`,
                connected: true,
                mapping: 'standard',
                axes: [0, 0],
                buttons: Array.from({ length: 17 }, () => ({ pressed: false, value: 0 }))
            };
            this.connected = true;
            this.ready = false;
            this.onChange();
            return true;
        } catch (error) {
            if (generation === this._generation && this._device === device) this._detach();
            await this._closeIfUnclaimed(device);
            if (generation !== this._generation) return false;
            throw new Error(`Could not open the Pro Controller: ${error.message || error}`);
        }
    }

    async disconnect() {
        ++this._generation;
        this._connecting = null;
        const device = this._device;
        this._detach();
        const changed = this.connected || this.ready;
        this.connected = false;
        this.ready = false;
        this.gamepad = null;
        if (changed) this.onChange();
        if (device) await this._closeIfUnclaimed(device);
    }

    _detach() {
        this._device?.removeEventListener('inputreport', this._inputListener);
        this._hid?.removeEventListener('disconnect', this._disconnectListener);
        this._device = null;
        this._hid = null;
        this._inputListener = null;
        this._disconnectListener = null;
    }

    async _closeDevice(device) {
        if (!device.opened) return;
        try {
            await device.close();
        } catch {
            // Unplugged devices can reject close; input has already been released.
        }
    }

    async _closeIfUnclaimed(device) {
        if (this._device === device || !device.opened) return;
        const closing = this._closeDevice(device);
        const pending = this._closing ? Promise.all([this._closing, closing]) : closing;
        this._closing = pending;
        await pending;
        if (this._closing === pending) this._closing = null;
    }

    _readReport(reportId, data) {
        // Chromium's ControllerData prefix is shared by full 0x30 and reply 0x21.
        // WebHID data excludes the report ID. No output or calibration is requested.
        if ((reportId !== 0x21 && reportId !== 0x30) ||
            !data || data.byteLength < 12 || typeof data.getUint8 !== 'function') return;
        const rawX = data.getUint8(5) | ((data.getUint8(6) & 0x0f) << 8);
        const rawY = (data.getUint8(6) >> 4) | (data.getUint8(7) << 4);
        this.gamepad.axes[0] = this._normalizeAxis(rawX);
        this.gamepad.axes[1] = -this._normalizeAxis(rawY);
        for (let index = 0; index < PRO_CONTROLLER_BUTTONS.length; index++) {
            const [offset, mask] = PRO_CONTROLLER_BUTTONS[index];
            const pressed = (data.getUint8(offset) & mask) !== 0;
            this.gamepad.buttons[index].pressed = pressed;
            this.gamepad.buttons[index].value = pressed ? 1 : 0;
        }
        if (!this.ready) {
            this.ready = true;
            this.onChange();
        }
    }

    _normalizeAxis(raw) {
        const offset = raw - 0x800;
        return offset / (offset < 0 ? 0x800 : 0x7ff);
    }
}
