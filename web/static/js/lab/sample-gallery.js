//
// @fileoverview The BASIC page's sample gallery and demo reel
// @module lab/sample-gallery
//
// A card for every sample with a preview recorded on this emulator by
// tools/gen_sample_previews.py, filtered by category. Choosing a card asks
// the page to load and run that sample. The demo reel plays the samples
// marked `demo` in index.json one after another, like a shop-window C64.
//
// @see https://www.turbo8bit.com/
//

const ALL = 'All';

const escapeHtml = text => String(text).replace(/[&<>"]/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]
));

export class SampleGallery {
    //
    // @param {HTMLElement} root - Element to build the gallery in
    // @param {Object} options
    // @param {Array<Object>} options.examples - Entries from the sample index
    // @param {Function} options.preview - (id, still) => URL of its preview
    // @param {Function} options.onRun - (id) => called when a card is chosen
    //
    constructor(root, { examples, preview, onRun }) {
        this.root = root;
        this.cards = new Map();
        this.filterButtons = [];

        const categories = [ALL, ...new Set(examples.map(example => example.category))];
        const filters = document.createElement('div');
        filters.className = 'gallery-filters';
        filters.setAttribute('role', 'group');
        filters.setAttribute('aria-label', 'Show samples about');
        for (const category of categories) {
            const button = document.createElement('button');
            button.type = 'button';
            button.textContent = category;
            button.dataset.category = category;
            button.setAttribute('aria-pressed', String(category === ALL));
            button.addEventListener('click', () => this.filter(category));
            filters.appendChild(button);
            this.filterButtons.push(button);
        }

        const grid = document.createElement('ul');
        grid.className = 'gallery-grid';
        for (const example of examples) {
            const card = this.card(example, preview);
            card.querySelector('.gallery-run').addEventListener('click', () => onRun(example.id));
            this.cards.set(example.id, card);
            grid.appendChild(card);
        }
        root.replaceChildren(filters, grid);
    }

    card(example, preview) {
        const item = document.createElement('li');
        item.className = 'gallery-card';
        item.dataset.category = example.category;
        const title = escapeHtml(example.title);
        const describedBy = `gallery-about-${example.id}`;
        const sound = example.sound
            ? ' <span class="gallery-sound" title="Makes sound: turn the sound on to hear it">🔊</span>' : '';
        const tags = (example.concepts ?? []).map(concept => `<li>${escapeHtml(concept)}</li>`).join('');
        item.innerHTML = `
            <button type="button" class="gallery-run" aria-label="Run ${title}${example.sound ? ', with sound' : ''}"
                    aria-describedby="${describedBy}">
                <span class="gallery-preview">
                    <picture>
                        <source srcset="${preview(example.id, true)}" media="(prefers-reduced-motion: reduce)">
                        <img src="${preview(example.id, false)}" alt="" width="384" height="272"
                             loading="lazy" decoding="async">
                    </picture>
                    <span class="gallery-play" aria-hidden="true">▶ RUN</span>
                    <span class="gallery-loaded" aria-hidden="true">IN THE EDITOR</span>
                </span>
                <span class="gallery-title">${title}${sound}</span>
            </button>
            <p class="gallery-description" id="${describedBy}">${escapeHtml(example.description ?? '')}</p>
            <ul class="gallery-tags" aria-label="Topics">${tags}</ul>`;
        return item;
    }

    //
    // Show only the samples in `category`, or all of them.
    //
    filter(category) {
        for (const button of this.filterButtons) {
            button.setAttribute('aria-pressed', String(button.dataset.category === category));
        }
        for (const card of this.cards.values()) {
            card.hidden = category !== ALL && card.dataset.category !== category;
        }
    }

    //
    // Mark the sample that is in the editor, if any.
    //
    setActive(id) {
        for (const [cardId, card] of this.cards) {
            const active = cardId === id;
            card.classList.toggle('active', active);
            const button = card.querySelector('.gallery-run');
            if (active) button.setAttribute('aria-current', 'true');
            else button.removeAttribute('aria-current');
        }
    }
}

export class DemoReel {
    //
    // @param {Object} options
    // @param {Function} options.play - (id) => Promise that settles once the
    //   sample is running
    // @param {Function} options.onChange - (reel) => called whenever the
    //   reel starts, moves on, or stops
    // @param {number} [options.seconds=12] - How long each sample runs
    //
    constructor({ play, onChange, seconds = 12 }) {
        this.ids = [];
        this.play = play;
        this.onChange = onChange;
        this.seconds = seconds;
        this.active = false;
        this.playing = false;
        this.index = -1;
        this.timer = null;
        this.step = 0;
    }

    get current() {
        return this.active ? this.ids[this.index] : null;
    }

    start() {
        if (this.active || this.ids.length === 0) return;
        this.active = true;
        this.index = -1;
        this.next();
    }

    async next() {
        if (!this.active) return;
        clearTimeout(this.timer);
        const step = ++this.step;
        this.index = (this.index + 1) % this.ids.length;
        this.playing = false;
        this.onChange(this);
        try {
            await this.play(this.ids[this.index]);
        } catch (error) {
            // Once Next or stop() has moved on, this step's outcome is moot.
            if (step !== this.step) return;
            console.error('The demo reel could not play a sample:', error);
            this.stop();
            return;
        }
        // The time on screen starts once the sample is running, not while
        // the C64 resets and boots for it.
        if (!this.active || step !== this.step) return;
        this.playing = true;
        this.timer = setTimeout(() => this.next(), this.seconds * 1000);
        this.onChange(this);
    }

    stop() {
        if (!this.active) return;
        clearTimeout(this.timer);
        this.timer = null;
        this.step++;
        this.active = false;
        this.playing = false;
        this.onChange(this);
    }
}
