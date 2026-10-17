//
// @fileoverview Saving, sharing and opening lab programs
// @module lab/files
//
// Small browser helpers shared by the BASIC and Assembly labs: downloads,
// drafts kept in localStorage, and share links that carry a whole program in
// the URL fragment (#z= deflate-compressed, #code= plain). A fragment is
// never sent to the server, so sharing needs no backend.
//
// @see https://www.turbo8bit.com/
//

//
// Offer bytes or text to the user as a file download.
// @param {Blob} blob
// @param {string} filename
//
export function downloadBlob(blob, filename) {
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    // Some browsers read the URL after click() returns.
    setTimeout(() => URL.revokeObjectURL(url), 1000);
}

//
// localStorage access that degrades to "nothing stored" when storage is
// blocked (private browsing, disabled cookies) instead of throwing.
//
export const storage = {
    get(key) {
        try {
            return window.localStorage.getItem(key);
        } catch {
            return null;
        }
    },
    set(key, value) {
        try {
            window.localStorage.setItem(key, value);
            return true;
        } catch {
            return false;
        }
    },
    remove(key) {
        try {
            window.localStorage.removeItem(key);
        } catch {
            // Nothing to clean up if storage is unavailable.
        }
    }
};

function toBase64Url(bytes) {
    let binary = '';
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromBase64Url(text) {
    const base64 = text.replace(/-/g, '+').replace(/_/g, '/');
    const binary = atob(base64 + '='.repeat((4 - base64.length % 4) % 4));
    return Uint8Array.from(binary, ch => ch.charCodeAt(0));
}

async function transform(bytes, stream) {
    const response = new Response(new Blob([bytes]).stream().pipeThrough(stream));
    return new Uint8Array(await response.arrayBuffer());
}

//
// Encode source text as a URL fragment such as "z=..." or "code=...".
// @param {string} source
// @returns {Promise<string>}
//
export async function encodeShareFragment(source) {
    const bytes = new TextEncoder().encode(source);
    if (typeof CompressionStream === 'function') {
        try {
            return 'z=' + toBase64Url(await transform(bytes, new CompressionStream('deflate-raw')));
        } catch {
            // Fall back to the uncompressed form below.
        }
    }
    return 'code=' + toBase64Url(bytes);
}

//
// Decode a fragment made by encodeShareFragment().
// @param {string} hash - location.hash, with or without the leading #
// @returns {Promise<string|null>} The shared source, or null if none
//
export async function decodeShareFragment(hash) {
    const params = new URLSearchParams(hash.replace(/^#/, ''));
    if (params.has('z')) {
        const bytes = await transform(fromBase64Url(params.get('z')),
            new DecompressionStream('deflate-raw'));
        return new TextDecoder().decode(bytes);
    }
    if (params.has('code')) {
        return new TextDecoder().decode(fromBase64Url(params.get('code')));
    }
    return null;
}
