"""The BASIC page's sample gallery, its recorded previews, and the demo reel."""

import json

import pytest
from PIL import Image

from tests.test_utils import (
    JS_STATIC_DIR,
    STATIC_DIR,
    create_mini_racer_context,
    eval_json,
    load_js_modules,
)

EXAMPLES = json.loads(
    (STATIC_DIR / "basic" / "index.json").read_text(encoding="utf-8")
)["examples"]
PREVIEWS = STATIC_DIR / "basic" / "previews"


@pytest.mark.parametrize("example", EXAMPLES, ids=[e["id"] for e in EXAMPLES])
def test_every_sample_has_a_card_and_recorded_previews(example):
    assert example["description"].strip()
    assert 1 <= len(example["concepts"]) <= 4
    for name in (f"{example['id']}.webp", f"{example['id']}-still.webp"):
        with Image.open(PREVIEWS / name) as image:
            assert image.format == "WEBP"
            assert image.size == (384, 272)
    with Image.open(PREVIEWS / f"{example['id']}.webp") as animated:
        assert animated.n_frames > 1


def test_demo_reel_samples_run_as_programs():
    demos = [e for e in EXAMPLES if e.get("demo")]
    assert len(demos) >= 3
    assert not any(e.get("direct") for e in demos)
    # The reel plays by itself, so nothing in it may flash (WCAG 2.3.1).
    assert "borderFlash" not in {e["id"] for e in demos}


@pytest.mark.parametrize("example", EXAMPLES, ids=[e["id"] for e in EXAMPLES])
def test_previews_never_flash_the_border_more_than_three_times_a_second(example):
    changes = []
    elapsed = 0
    with Image.open(PREVIEWS / f"{example['id']}.webp") as animated:
        border = None
        for frame in range(animated.n_frames):
            animated.seek(frame)
            colour = animated.convert("RGB").getpixel((0, 0))
            if border is not None and colour != border:
                changes.append(elapsed)
            border = colour
            elapsed += animated.info["duration"]
    gaps = [later - earlier for earlier, later in zip(changes, changes[1:])]
    assert all(gap >= 334 for gap in gaps), gaps


@pytest.fixture
def gallery_context():
    ctx = create_mini_racer_context()
    ctx.eval(
        r"""
        function fakeElement(tag) {
            return {
                tag, innerHTML: '', textContent: '', hidden: false, dataset: {},
                attributes: {}, children: [], listeners: {}, found: {}, classes: new Set(),
                classList: {
                    toggle(name, on) { on ? this.owner.classes.add(name) : this.owner.classes.delete(name); }
                },
                setAttribute(name, value) { this.attributes[name] = value; },
                removeAttribute(name) { delete this.attributes[name]; },
                addEventListener(name, listener) { this.listeners[name] = listener; },
                appendChild(child) { this.children.push(child); },
                replaceChildren(...nodes) { this.children = nodes; },
                querySelector(selector) { return this.found[selector] ||= fakeElement(selector); }
            };
        }
        var document = {
            createElement(tag) {
                const element = fakeElement(tag);
                element.classList.owner = element;
                return element;
            }
        };
        var timers = [];
        var setTimeout = (callback, ms) => timers.push({ callback, ms });
        var clearTimeout = () => {};
        var errors = [];
        console.error = (...args) => errors.push(args.join(' '));
        """
    )
    load_js_modules(ctx, ["lab/sample-gallery.js"], JS_STATIC_DIR)
    return ctx


def test_gallery_builds_filterable_cards(gallery_context):
    result = eval_json(
        gallery_context,
        """(() => {
            const runs = [];
            const root = document.createElement('div');
            const gallery = new SampleGallery(root, {
                examples: [
                    { id: 'a', title: 'A <b>bold</b> one', category: 'Graphics',
                      description: 'Draws', concepts: ['POKE'] },
                    { id: 'b', title: 'Beep', category: 'Sound', sound: true, concepts: [] },
                    { id: 'c', title: 'Count', category: 'Graphics' }
                ],
                preview: (id, still) => `/p/${id}${still ? '-still' : ''}.webp`,
                onRun: id => runs.push(id)
            });
            const [filters, grid] = root.children;
            gallery.filter('Sound');
            const hidden = grid.children.map(card => card.hidden);
            const pressed = filters.children.map(b => b.attributes['aria-pressed']);
            gallery.setActive('c');
            grid.children[1].found['.gallery-run'].listeners.click();
            return {
                filters: filters.children.map(b => b.textContent),
                hidden, pressed, runs,
                active: grid.children.map(card => card.classes.has('active')),
                current: grid.children[2].found['.gallery-run'].attributes['aria-current'],
                first: grid.children[0].innerHTML,
                second: grid.children[1].innerHTML
            };
        })()""",
    )
    assert result["filters"] == ["All", "Graphics", "Sound"]
    assert result["hidden"] == [True, False, True]
    assert result["pressed"] == ["false", "false", "true"]
    assert result["runs"] == ["b"]
    assert result["active"] == [False, False, True]
    assert result["current"] == "true"
    assert "A &lt;b&gt;bold&lt;/b&gt; one" in result["first"]
    assert "<b>" not in result["first"]
    assert (
        'srcset="/p/a-still.webp" media="(prefers-reduced-motion: reduce)"'
        in result["first"]
    )
    assert 'src="/p/a.webp"' in result["first"]
    assert "<li>POKE</li>" in result["first"]
    assert "Run Beep, with sound" in result["second"]


def test_demo_reel_waits_for_each_sample_then_moves_on(gallery_context):
    gallery_context.eval(
        """
        var played = [];
        var changes = [];
        var finishPlay = null;
        var reel = new DemoReel({
            play: id => new Promise(resolve => { played.push(id); finishPlay = resolve; }),
            onChange: r => changes.push([r.current, r.playing]),
            seconds: 5
        });
        reel.ids = ['one', 'two'];
        reel.start();
        """
    )
    assert eval_json(gallery_context, "played") == ["one"]
    # The clock starts once the sample is running.
    assert gallery_context.eval("timers.length") == 0
    gallery_context.eval("finishPlay();")
    assert eval_json(gallery_context, "timers.map(t => t.ms)") == [5000]
    gallery_context.eval("timers.shift().callback(); finishPlay();")
    gallery_context.eval("timers.shift().callback();")
    assert eval_json(gallery_context, "played") == ["one", "two", "one"]
    assert eval_json(gallery_context, "changes.slice(0, 4)") == [
        ["one", False],
        ["one", True],
        ["two", False],
        ["two", True],
    ]


def test_demo_reel_stop_cancels_a_sample_still_loading(gallery_context):
    result = eval_json(
        gallery_context,
        """(() => {
            let finish;
            const reel = new DemoReel({
                play: () => new Promise(resolve => { finish = resolve; }),
                onChange: () => {}
            });
            reel.ids = ['one'];
            reel.start();
            reel.stop();
            globalThis.afterStop = () => ({ active: reel.active, current: reel.current,
                                            timers: timers.length });
            finish();
            return null;
        })()""",
    )
    assert result is None
    assert eval_json(gallery_context, "afterStop()") == {
        "active": False,
        "current": None,
        "timers": 0,
    }


def test_demo_reel_stops_when_a_sample_fails(gallery_context):
    gallery_context.eval(
        """
        var failing = new DemoReel({
            play: () => Promise.reject(new Error('no index')),
            onChange: () => {}
        });
        failing.ids = ['one'];
        failing.start();
        """
    )
    assert not gallery_context.eval("failing.active")
    assert "no index" in gallery_context.eval("errors.join()")


def test_a_failure_after_next_or_stop_is_ignored(gallery_context):
    gallery_context.eval(
        """
        var rejects = [];
        var superseded = new DemoReel({
            play: () => new Promise((resolve, reject) => rejects.push(reject)),
            onChange: () => {}
        });
        superseded.ids = ['one', 'two'];
        superseded.start();
        superseded.next();
        rejects[0](new Error('superseded load'));
        """
    )
    assert gallery_context.eval("superseded.active")
    assert gallery_context.eval("superseded.current") == "two"
    assert "superseded" not in gallery_context.eval("errors.join()")
