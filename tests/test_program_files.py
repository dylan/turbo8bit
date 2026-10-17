"""Drafts and share links on the lab pages keep the visitor's own program."""

import pytest

from tests.test_utils import (
    JS_STATIC_DIR,
    create_mini_racer_context,
    eval_json,
    load_js_modules,
)


@pytest.fixture
def files_context():
    ctx = create_mini_racer_context()
    ctx.eval(
        r"""
        var stored = new Map();
        window.localStorage = {
            getItem: key => stored.has(key) ? stored.get(key) : null,
            setItem: (key, value) => stored.set(key, String(value)),
            removeItem: key => stored.delete(key)
        };
        var timers = new Map();
        var nextTimer = 1;
        var setTimeout = callback => { timers.set(nextTimer, callback); return nextTimer++; };
        var clearTimeout = id => timers.delete(id);
        function runTimers() {
            const pending = [...timers.values()];
            timers.clear();
            for (const callback of pending) callback();
        }
        var location = { hash: '', pathname: '/', search: '', origin: 'https://example.test' };
        var history = { replaceState() { location.hash = ''; } };
        function fakeElement() {
            return {
                addEventListener() {}, querySelector() { return fakeElement(); },
                contains() { return false; }
            };
        }
        var document = { createElement: fakeElement, addEventListener() {} };
        function fakeEditor() {
            return {
                value: '', listeners: [],
                getValue() { return this.value; },
                setValue(text) {
                    this.value = text.replace(/\r\n?/g, '\n');
                    for (const listener of this.listeners) listener(this.value);
                },
                onValueChange(listener) { this.listeners.push(listener); },
                addToolbarItem() {}
            };
        }
        """
    )
    load_js_modules(ctx, ["lab/files.js", "lab/program-files.js"], JS_STATIC_DIR)
    ctx.eval(
        r"""
        // Share links are compressed in the browser; the tests only need
        // the decoded text.
        var sharedText = null;
        decodeShareFragment = async hash => hash ? sharedText : null;
        // Text the page would call an unedited sample.
        var pristineText = null;
        function openPage(hash) {
            location.hash = hash;
            const editor = fakeEditor();
            const files = attachProgramFiles(editor, {
                draftKey: 'draft', extension: 'bas', fileName: () => 'program',
                buildPrg: () => null, say() {},
                isPristine: text => text === pristineText
            });
            return { editor, files };
        }
        """
    )
    return ctx


def test_opening_a_share_link_keeps_the_visitors_draft(files_context):
    result = eval_json(
        files_context,
        """(() => {
            stored.set('draft', '10 PRINT "MY OWN WORK"');
            sharedText = '10 PRINT "FROM A FRIEND"\\r\\n';
            const page = openPage('#z=abc');
            globalThis.sharePage = page;
            page.files.restore().then(message => { globalThis.restoreMessage = message; });
            return null;
        })()""",
    )
    assert result is None
    files_context.eval("runTimers();")
    result = eval_json(
        files_context,
        "({ editor: sharePage.editor.getValue(), draft: stored.get('draft'),"
        " message: restoreMessage })",
    )
    assert result["editor"] == '10 PRINT "FROM A FRIEND"\n'
    assert result["draft"] == '10 PRINT "MY OWN WORK"'
    assert "shared program" in result["message"]

    # Reloading without the link brings the visitor's program back.
    files_context.eval(
        "var reloaded = openPage('');"
        " reloaded.files.restore().then(m => { globalThis.reloadMessage = m; });"
    )
    assert files_context.eval("reloaded.editor.getValue()") == '10 PRINT "MY OWN WORK"'
    assert "Welcome back" in files_context.eval("reloadMessage")


def test_editing_a_shared_program_saves_it_as_the_draft(files_context):
    files_context.eval(
        """
        stored.set('draft', '10 PRINT "OLD"');
        sharedText = '10 PRINT "SHARED"';
        var page = openPage('#code=abc');
        page.files.restore();
        """
    )
    files_context.eval(
        "runTimers(); page.editor.setValue('10 PRINT \"SHARED AND CHANGED\"'); runTimers();"
    )
    assert files_context.eval("stored.get('draft')") == '10 PRINT "SHARED AND CHANGED"'


def test_typing_saves_a_draft_after_a_pause(files_context):
    files_context.eval(
        """
        var page = openPage('');
        page.editor.setValue('10 PRINT 1');
        """
    )
    assert not files_context.eval("stored.has('draft')")
    files_context.eval("runTimers();")
    assert files_context.eval("stored.get('draft')") == "10 PRINT 1"


@pytest.mark.parametrize("replacement", ["sample", "empty"])
def test_after_a_share_link_samples_and_clearing_keep_the_hidden_draft(
    files_context, replacement
):
    files_context.eval(
        f"""
        stored.set('draft', '10 PRINT "MY OWN WORK"');
        sharedText = '10 PRINT "FROM A FRIEND"';
        pristineText = '10 PRINT "A SAMPLE"';
        var page = openPage('#z=abc');
        page.files.restore();
        """
    )
    files_context.eval("runTimers();")
    replacement_text = '10 PRINT "A SAMPLE"' if replacement == "sample" else ""
    files_context.eval(f"page.editor.setValue({replacement_text!r}); runTimers();")
    assert files_context.eval("stored.get('draft')") == '10 PRINT "MY OWN WORK"'
    # Code the visitor writes is theirs to keep, and becomes the draft.
    files_context.eval("page.editor.setValue('10 PRINT \"NEW\"'); runTimers();")
    assert files_context.eval("stored.get('draft')") == '10 PRINT "NEW"'


def test_without_a_share_link_an_unedited_sample_clears_the_draft(files_context):
    files_context.eval(
        """
        pristineText = '10 PRINT "A SAMPLE"';
        var page = openPage('');
        page.editor.setValue('10 PRINT "MINE"');
        runTimers();
        """
    )
    assert files_context.eval("stored.get('draft')") == '10 PRINT "MINE"'
    files_context.eval("page.editor.setValue(pristineText); runTimers();")
    assert not files_context.eval("stored.has('draft')")
