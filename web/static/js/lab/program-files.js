//
// @fileoverview File menu, drafts and share links for a lab editor
// @module lab/program-files
//
// Gives a CodeEditor a small File menu - open a file, save the source, save a
// runnable .prg, copy a share link - keeps a draft of the editor in
// localStorage, and restores a shared program (from the URL) or the draft
// when the page opens. The page decides what a .prg means for its language
// through the buildPrg/openPrg callbacks.
//
// @see https://www.turbo8bit.com/
//

import { downloadBlob, storage, encodeShareFragment, decodeShareFragment } from './files.js';

const DRAFT_SAVE_DELAY_MS = 400;

//
// @param {CodeEditor} editor
// @param {Object} options
// @param {string} options.draftKey - localStorage key for the draft
// @param {string} options.extension - Source file extension, e.g. 'bas'
// @param {Function} options.fileName - () => base name for downloads
// @param {Function} options.buildPrg - () => Uint8Array|null (reports its own errors)
// @param {Function} [options.openPrg] - (bytes) => source text, throws if unreadable
// @param {Function} options.say - (message) => void, for status messages
// @param {Function} [options.isPristine] - (text) => true if the text is an
//   unedited sample, which is not worth keeping as a draft
// @returns {{restore: Function}}
//
export function attachProgramFiles(editor, {
    draftKey, extension, fileName, buildPrg, openPrg, say, isPristine = () => false
}) {
    let saveTimer = null;
    // After a share link the visitor's own draft is out of sight. Until they
    // write code of their own, nothing may replace or remove it: not the
    // shared program, an unedited sample, or an empty editor.
    let sharedText = null;
    editor.onValueChange(value => {
        clearTimeout(saveTimer);
        saveTimer = setTimeout(() => {
            // Checked when saving: the page marks a sample as pristine only
            // after putting it in the editor.
            const worthKeeping = value.trim() !== '' && !isPristine(value);
            if (sharedText !== null) {
                if (!worthKeeping || value === sharedText) return;
                sharedText = null;
            }
            if (worthKeeping) storage.set(draftKey, value);
            else storage.remove(draftKey);
        }, DRAFT_SAVE_DELAY_MS);
    });

    const menu = document.createElement('details');
    menu.className = 'editor-menu';
    menu.innerHTML = `
        <summary title="Open, save and share your program">File</summary>
        <div class="editor-menu-items">
            <button type="button" data-file-action="open">📂 Open file…</button>
            <button type="button" data-file-action="source">📄 Save source (.${extension})</button>
            <button type="button" data-file-action="prg">💾 Save program (.prg)</button>
            <button type="button" data-file-action="share">🔗 Copy share link</button>
        </div>
    `;
    const picker = document.createElement('input');
    picker.type = 'file';
    picker.accept = openPrg ? `.${extension},.txt,.prg` : `.${extension},.txt`;
    picker.hidden = true;
    editor.addToolbarItem(menu);
    // Outside the <details>, which stops rendering its content when closed.
    editor.addToolbarItem(picker);

    const close = () => {
        menu.open = false;
    };
    document.addEventListener('click', event => {
        if (menu.open && !menu.contains(event.target)) close();
    });
    menu.addEventListener('keydown', event => {
        if (event.key === 'Escape' && menu.open) {
            close();
            menu.querySelector('summary').focus();
        }
    });

    const actions = {
        open: () => picker.click(),

        source: () => {
            downloadBlob(new Blob([editor.getValue()], { type: 'text/plain' }),
                `${fileName()}.${extension}`);
            say(`Saved ${fileName()}.${extension}.`);
        },

        prg: () => {
            const bytes = buildPrg();
            if (!bytes) return;
            downloadBlob(new Blob([bytes], { type: 'application/octet-stream' }), `${fileName()}.prg`);
            say(`Saved ${fileName()}.prg - it also runs in other C64 emulators.`);
        },

        share: async () => {
            const url = `${location.origin}${location.pathname}#${await encodeShareFragment(editor.getValue())}`;
            try {
                await navigator.clipboard.writeText(url);
                say('Share link copied. Anyone who opens it gets this program.');
            } catch {
                history.replaceState(null, '', url);
                say('Copy the share link from the address bar.');
            }
        }
    };

    menu.addEventListener('click', event => {
        const action = event.target.closest('[data-file-action]')?.dataset.fileAction;
        if (!action) return;
        close();
        Promise.resolve(actions[action]()).catch(error => {
            console.error(`File action ${action} failed:`, error);
            say('That did not work. Please try again.');
        });
    });

    picker.addEventListener('change', async () => {
        const file = picker.files[0];
        picker.value = '';
        if (!file) return;
        try {
            const bytes = new Uint8Array(await file.arrayBuffer());
            const isPrg = file.name.toLowerCase().endsWith('.prg');
            const text = isPrg ? openPrg(bytes) : new TextDecoder().decode(bytes);
            editor.setValue(text.replace(/\r\n?/g, '\n'));
            say(`Opened ${file.name}.`);
        } catch (error) {
            say(`Could not open ${file.name}: ${error.message}`);
        }
    });

    //
    // Put a shared program (from the URL fragment) or the saved draft into an
    // empty editor. The fragment is removed afterwards, so reloading brings
    // back the visitor's own draft, or their edits to the shared program.
    // @returns {Promise<string|null>} A message describing what was restored
    //
    async function restore() {
        let shared = null;
        try {
            shared = await decodeShareFragment(location.hash);
        } catch (error) {
            console.warn('Ignoring an unreadable share link:', error);
        }
        if (shared !== null) {
            history.replaceState(null, '', location.pathname + location.search);
            if (!editor.getValue()) {
                sharedText = shared.replace(/\r\n?/g, '\n');
                editor.setValue(shared);
                return 'Loaded a shared program. Press Run to try it.';
            }
        }
        const draft = storage.get(draftKey);
        if (draft && !editor.getValue()) {
            editor.setValue(draft);
            return 'Welcome back! Your last program has been restored.';
        }
        return null;
    }

    return { restore };
}
