const HAT_DIRECTIONS = [[12], [12, 15], [15], [13, 15], [13], [13, 14], [14], [12, 14]];
const SWITCH_BUTTONS = [
    [2, 0x04], [2, 0x08], [2, 0x01], [2, 0x02],
    [4, 0x40], [2, 0x40], [4, 0x80], [2, 0x80],
    [3, 0x01], [3, 0x02], [3, 0x08], [3, 0x04],
    [4, 0x02], [4, 0x01], [4, 0x08], [4, 0x04], [3, 0x10]
];

export function isGamepadCollection(collection) {
    return collection.usagePage === 0x01 && [0x04, 0x05].includes(collection.usage);
}

function setButton(gamepad, index, pressed) {
    gamepad.buttons[index].pressed = pressed;
    gamepad.buttons[index].value = pressed ? 1 : 0;
}

function normalizeAxis(value, minimum, maximum) {
    const center = Math.floor((minimum + maximum + 1) / 2);
    return value === center ? 0 : (value - center) / (value < center ? center - minimum : maximum - center);
}

function readField(data, field) {
    let value = 0;
    for (let bit = 0; bit < field.size; bit++) {
        const position = field.offset + bit;
        value += ((data.getUint8(position >> 3) >> (position & 7)) & 1) * 2 ** bit;
    }
    if (field.minimum < 0 && value >= 2 ** (field.size - 1)) value -= 2 ** field.size;
    return value;
}

function descriptorReports(collections) {
    const reportCounts = new Map();
    for (const collection of collections) {
        for (const report of collection.inputReports) {
            reportCounts.set(report.reportId, (reportCounts.get(report.reportId) || 0) + 1);
        }
    }
    const reports = new Map();
    const claimed = new Set();
    for (const collection of collections.filter(isGamepadCollection)) {
        // Top-level reports already flatten their children in descriptor order.
        for (const report of collection.inputReports) {
            // A shared ID across top-level collections has no exposed field offsets.
            if (reportCounts.get(report.reportId) !== 1) continue;
            const fields = [];
            let offset = 0;
            for (const item of report.items) {
                const start = offset;
                offset += item.reportSize * item.reportCount;
                if (item.isConstant || item.isArray || item.isBufferedBytes || !item.isAbsolute ||
                    item.reportSize > 32 || item.logicalMaximum <= item.logicalMinimum) continue;
                for (let index = 0; index < item.reportCount; index++) {
                    const usage = item.isRange
                        ? Math.min(item.usageMinimum + index, item.usageMaximum)
                        : item.usages?.[Math.min(index, item.usages.length - 1)];
                    let kind, target, keys;
                    if ((usage === 0x10030 || usage === 0x10031) && item.logicalMaximum - item.logicalMinimum >= 2) {
                        kind = 'axis'; target = usage - 0x10030; keys = [`axis${target}`];
                    } else if (usage === 0x10039 && [3, 7].includes(item.logicalMaximum - item.logicalMinimum)) {
                        kind = 'hat'; keys = [12, 13, 14, 15].map(button => `button${button}`);
                    } else {
                        if (usage >= 0x90001 && usage <= 0x90004) target = usage - 0x90001;
                        else target = { 0x10090: 12, 0x10091: 13, 0x10092: 15, 0x10093: 14 }[usage];
                        if (target === undefined) continue;
                        kind = 'button'; keys = [`button${target}`];
                    }
                    if (keys.some(key => claimed.has(key))) continue;
                    keys.forEach(key => claimed.add(key));
                    fields.push({ kind, target, offset: start + index * item.reportSize,
                        size: item.reportSize, minimum: item.logicalMinimum, maximum: item.logicalMaximum });
                }
            }
            if (fields.length) reports.set(report.reportId, { byteLength: Math.ceil(offset / 8), fields });
        }
    }
    const directions = (claimed.has('axis0') && claimed.has('axis1')) ||
        [12, 13, 14, 15].every(button => claimed.has(`button${button}`));
    const fire = [0, 1, 2, 3].some(button => claimed.has(`button${button}`));
    return directions && fire ? reports : new Map();
}

// Some devices describe their usable packets as vendor data, requiring a profile.
// This verified prefix is shared by Nintendo's 0x21 reply and 0x30 full reports.
function readSwitchReport(reportId, data, gamepad) {
    if (![0x21, 0x30].includes(reportId) || data.byteLength < 12) return false;
    const x = data.getUint8(5) | ((data.getUint8(6) & 0x0f) << 8);
    const y = (data.getUint8(6) >> 4) | (data.getUint8(7) << 4);
    gamepad.axes[0] = normalizeAxis(x, 0, 0xfff);
    gamepad.axes[1] = -normalizeAxis(y, 0, 0xfff);
    SWITCH_BUTTONS.forEach(([offset, mask], index) => setButton(gamepad, index, Boolean(data.getUint8(offset) & mask)));
    return true;
}

export function createHidGamepadDecoder(device) {
    const reports = descriptorReports(device.collections);
    const switchProfile = device.vendorId === 0x057e && device.productId === 0x2009;
    if (!reports.size && !switchProfile) return null;
    const seen = new Set();
    return (reportId, data, gamepad) => {
        // WebHID strips the report ID and may supply a view into a larger buffer.
        if (!data || typeof data.getUint8 !== 'function') return false;
        if (switchProfile && [0x21, 0x30].includes(reportId)) return readSwitchReport(reportId, data, gamepad);
        const report = reports.get(reportId);
        if (!report || data.byteLength < report.byteLength) return false;
        for (const field of report.fields) {
            const value = readField(data, field);
            const valid = value >= field.minimum && value <= field.maximum;
            if (field.kind === 'axis') {
                gamepad.axes[field.target] = valid ? normalizeAxis(value, field.minimum, field.maximum) : 0;
            } else if (field.kind === 'hat') {
                const direction = valid ? HAT_DIRECTIONS[(value - field.minimum) * (field.maximum - field.minimum === 3 ? 2 : 1)] : [];
                for (const button of [12, 13, 14, 15]) setButton(gamepad, button, direction.includes(button));
            } else {
                setButton(gamepad, field.target, valid && value > field.minimum);
            }
        }
        seen.add(reportId);
        return seen.size === reports.size;
    };
}
