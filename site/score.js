// The spoken line set as type, twice: what the headset sends above, what Untunnel makes of it
// below, so each word compares with itself. Each word is as wide as it was said and each letter
// takes its share of that time; letter height is frequency, 0 at the baseline to the top of the
// restored band at the cap line. The headset keeps only the part of each letter under its cut;
// Untunnel draws the rest back, textured by the restored take's own spectrum, behind a front
// that follows the audio.

import { signedDistance } from "./sdf.js";

const score = document.getElementById("score");
const canvas = score.querySelector(".score__canvas");
const staveLayer = score.querySelector(".score__staves");
const veilLayer = score.querySelector(".score__veils");
const frontLabel = score.querySelector(".score__front");
const rulerWords = document.querySelector(".ruler__words");
const status = document.querySelector(".listen__status");
const buttons = [...document.querySelectorAll("[data-take]")];
const playButton = document.querySelector(".button--play");
const menubar = document.querySelector(".menubar");
const menuItem = menubar.querySelector(".menubar__item");
const bypassButton = menubar.querySelector(".menubar__bypass");
const strip = menubar.querySelector(".menubar__strip");
const menuStatus = menubar.querySelector(".menubar__status");

const query = new URLSearchParams(location.search);
// The stills script renders the page's own frames: ?frame=still|hero|card, &at=<seconds>.
const frame = query.get("frame");
if (frame) {
    document.documentElement.dataset.frame = frame;
}
// The README hero and social card: no ruler under the line, and larger stave names.
const framed = frame === "hero" || frame === "card";
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const still = () => reducedMotion.matches || frame !== null;

const SDF_RANGE = 18;
const NARROW = 700;
// Words per headset and Untunnel pair: the whole line on a wide screen, two halves on a phone.
const PAIRS = { wide: [7], narrow: [3, 4] };
// A letter's width is mostly its share of the word's time and partly its natural width, so a
// clipped stop stays a letter instead of a sliver.
const TIME_SHARE = 0.7;
const MAX_STRETCH = 1.6;
// No letter gets less than this share of the width its natural shape asks for, so a quick B keeps
// both bowls.
const MIN_NATURAL = 0.8;
const INTRO_DELAY_MS = 600;
// A hovered word redraws at the pace it was said, but never in less time than the eye can follow.
const MIN_SWEEP_SECONDS = 0.45;
const RUN_ON = 0.2;
// Bypass takes the tops off from the end back to the start, three times faster than speech.
const RETREAT_SPEED = 3;
// The smallest pointer target a word's button gets, in CSS pixels.
const MIN_TARGET = 24;
// The halftone the restored band prints in: red dots on the ground, on one screen per stave
// (cells per stave height), inside a solid red rim. A letter whose stems are too thin to hold two
// cells keeps a clean outline rather than a finer screen, filled solid only where it is loudest.
// A quiet frame prints small dots and louder frames grow them up to just short of touching; the
// loudest print dense, about 85% of each cell, so a stroke still reads as a letter. Dot sizes are
// thresholds of the screen's spot function.
const HALFTONE = { cellsPerStave: 26, stemCells: 2, smallest: 0.22, largest: 0.42, dense: 0.79, denseFrom: 0.7 };

const VERTEX = `#version 300 es
in vec2 corner;
out vec2 uv;
void main() {
    uv = corner * 0.5 + 0.5;
    gl_Position = vec4(corner, 0.0, 1.0);
}`;

const FRAGMENT = `#version 300 es
precision highp float;
in vec2 uv;
out vec4 color;
uniform sampler2D shapes;
uniform sampler2D spectrum;
uniform vec2 size;
uniform vec4 staveX[4];
uniform vec3 staveY[4];
// Along each stave, 1 under letters that hold the screen and 0 under those that keep only a rim.
uniform sampler2D screened;
uniform int staveCount;
uniform float cut;
uniform float front;
uniform vec3 sweep;
uniform float playhead;
// A stretch of the line played bypassed, which stays cut whatever the front has passed.
uniform vec2 gap;
uniform float frames;
uniform float hop;
uniform float range;
uniform float glow;
// 1 while the line plays bypassed: the tops drawn before the bypass dim, and the front turns ink.
uniform float bypassing;
uniform vec3 ink;
uniform vec3 red;
uniform vec3 hot;

const float SMALLEST = ${HALFTONE.smallest.toFixed(2)};
const float LARGEST = ${HALFTONE.largest.toFixed(2)};
const float DENSE = ${HALFTONE.dense.toFixed(2)};
const float DENSE_FROM = ${HALFTONE.denseFrom.toFixed(2)};
const float CELLS = ${HALFTONE.cellsPerStave.toFixed(1)};

// The restored band prints as an amplitude halftone of full red dots on a 45-degree screen:
// every inked pixel is the same red, and the spectrum sets how big each dot grows.
float screen(vec2 p, float density, float cell, float pixel) {
    vec2 q = mat2(0.7071, 0.7071, -0.7071, 0.7071) * p / cell;
    float spot = 0.5 - 0.25 * (cos(6.2832 * q.x) + cos(6.2832 * q.y));
    float aa = 1.2 * pixel / cell;
    return 1.0 - smoothstep(density - aa, density + aa, spot);
}

void over(inout vec4 under, vec3 rgb, float alpha) {
    under = vec4(rgb * alpha, alpha) + under * (1.0 - alpha);
}

// The front: a solid 1.5 px rule from the cap line to the baseline.
void rule(inout vec4 layer, vec2 p, float x, vec3 tone, float pixel) {
    over(layer, tone, 1.0 - smoothstep(0.75 - 0.5 * pixel, 0.75 + 0.5 * pixel, abs(p.x - x)));
}

void main() {
    vec2 p = vec2(uv.x, 1.0 - uv.y) * size;
    // One device pixel in CSS pixels, taken here where every fragment runs the same path.
    float pixel = max(fwidth(p.x), 1e-3);
    color = vec4(0.0);
    for (int i = 0; i < 4; i++) {
        if (i >= staveCount) break;
        vec4 sx = staveX[i];
        vec3 sy = staveY[i];
        if (p.y < sy.x - 4.0 || p.y > sy.y + 2.0 || p.x < sx.x - 8.0 || p.x > sx.y + 8.0) continue;

        float height = sy.y - sy.x;
        float t = mix(sx.z, sx.w, (p.x - sx.x) / (sx.y - sx.x));
        float level = (sy.y - p.y) / height;
        float d = (texture(shapes, vec2(uv.x, 1.0 - uv.y)).r - 0.5) * 2.0 * range;
        float aa = max(fwidth(d), 1e-3);
        float inside = smoothstep(-aa, aa, d);
        bool restored = sy.z > 0.5;

        vec4 layer = vec4(0.0);
        if (level < cut) {
            over(layer, ink, inside);
        } else if (restored) {
            bool local = t >= sweep.x && t < sweep.y;
            float age = !local && t >= gap.x && t < gap.y ? -1.0 : (local ? sweep.z : front) - t;
            if (age > 0.0) {
                // Rows are frames, filtered linearly between them; the ink also reads two frames
                // either side, so a letter shades from frame to frame instead of switching.
                float row = (t / hop + 0.5) / frames;
                float next = 1.0 / frames;
                float m = (texture(spectrum, vec2(level, row - 2.0 * next)).r
                    + 2.0 * texture(spectrum, vec2(level, row - next)).r
                    + 3.0 * texture(spectrum, vec2(level, row)).r
                    + 2.0 * texture(spectrum, vec2(level, row + next)).r
                    + texture(spectrum, vec2(level, row + 2.0 * next)).r) / 9.0;
                float fill = mix(1.0, clamp(age / 0.05, 0.0, 1.0), glow);
                float grow = clamp(m / DENSE_FROM, 0.0, 1.0);
                float dot = m < DENSE_FROM ? mix(SMALLEST, LARGEST, grow) : DENSE;
                float held = texture(screened, vec2(p.x / size.x, (float(i) + 0.5) / 4.0)).r;
                // A letter too thin for the screen prints its loudest frames solid instead of dense.
                float dots = held > 0.5
                    ? screen(p, fill * dot, height / CELLS, pixel)
                    : fill * smoothstep(DENSE_FROM - 0.02, DENSE_FROM + 0.02, m);
                // A solid red rim keeps each letter's outline, so a stem never dissolves.
                float rim = 1.0 - smoothstep(1.2, 2.2, d);
                // Played bypassed, what was drawn back before the bypass turns ink-grey: the same
                // dots, heard but no longer sent.
                bool heard = bypassing > 0.5 && t < gap.x;
                over(layer, heard ? ink : red, inside * max(dots, rim * fill) * (heard ? 0.35 : 1.0));
                // A hissy frame flashes full hot for the one 20 ms frame the front has just passed.
                float hiss = (texture(spectrum, vec2(0.5, row)).r + texture(spectrum, vec2(0.7, row)).r
                    + texture(spectrum, vec2(0.9, row)).r) / 3.0;
                float flash = glow * step(age, hop) * smoothstep(0.55, 0.72, hiss);
                over(layer, hot, heard ? 0.0 : inside * flash);
            }
        }

        if (p.y > sy.x && p.y < sy.y) {
            if (restored && front > sx.z && front < sx.w) {
                rule(layer, p, mix(sx.x, sx.y, (front - sx.z) / (sx.w - sx.z)), mix(red, ink, bypassing), pixel);
            }
            if (restored && sweep.z >= sweep.x && sweep.z < sweep.y && sweep.z > sx.z && sweep.z < sx.w) {
                rule(layer, p, mix(sx.x, sx.y, (sweep.z - sx.z) / (sx.w - sx.z)), red, pixel);
            }
            if (!restored && playhead > sx.z && playhead < sx.w) {
                float x = mix(sx.x, sx.y, (playhead - sx.z) / (sx.w - sx.z));
                over(layer, ink, 1.0 - smoothstep(0.5, 1.2, abs(p.x - x)));
            }
        }
        color = layer + color * (1.0 - layer.a);
    }
}`;

function hexToRgb(hex) {
    const value = Number.parseInt(hex.trim().slice(1), 16);
    return [(value >> 16) / 255, ((value >> 8) & 255) / 255, (value & 255) / 255];
}

// Where each stave sits, in CSS pixels, which stretch of the line it carries, and whether it
// is the headset's or Untunnel's. A left column holds each stave's 0 to 24 kHz scale; on a wide
// screen the stave's name hangs there too, and on a phone the first pair is named above its cap
// lines. Under each pair is room for its words.
function layoutStaves(words, width, height, narrow) {
    const pairs = narrow ? PAIRS.narrow : PAIRS.wide;
    const margin = narrow ? 16 : 32;
    const column = narrow ? 40 : framed ? 240 : 216;
    const top = narrow ? 0 : 8;
    const caption = narrow ? 20 : 0;
    const inner = narrow ? 16 : 32;
    const ruler = framed ? 16 : 44;
    const staveHeight =
        (height - top - 2 * caption - pairs.length * (inner + ruler)) / (2 * pairs.length);
    const staves = [];
    let first = 0;
    let y = top;
    for (const [pair, count] of pairs.entries()) {
        const group = words.slice(first, first + count);
        first += count;
        for (const restored of [false, true]) {
            const named = !narrow || pair === 0;
            y += narrow && named ? caption : 0;
            staves.push({
                words: group,
                restored,
                named,
                margin,
                x0: margin + column,
                x1: width - margin,
                t0: group[0].start,
                t1: group.at(-1).end,
                y0: y,
                y1: y + staveHeight,
            });
            y += staveHeight + (restored ? ruler : inner);
        }
    }
    return staves;
}

// Each letter's horizontal span inside its word: mostly its spoken time, partly its natural width.
function letterBoxes(word, left, right, naturalWidths) {
    const span = word.end - word.start;
    const natural = naturalWidths.reduce((sum, width) => sum + width, 0);
    const shares = word.letters.map(([, start, end], index) =>
        Math.max(
            TIME_SHARE * ((end - start) / span) + (1 - TIME_SHARE) * (naturalWidths[index] / natural),
            MIN_NATURAL * (naturalWidths[index] / natural),
        ),
    );
    const total = shares.reduce((sum, share) => sum + share, 0);
    let x = left;
    return word.letters.map(([letter], index) => {
        const box = { letter, x0: x, x1: x + (shares[index] / total) * (right - left) };
        x = box.x1;
        return box;
    });
}

function drawWords(staves, width, height, scale) {
    const ink = document.createElement("canvas");
    ink.width = Math.round(width * scale);
    ink.height = Math.round(height * scale);
    const context = ink.getContext("2d", { willReadFrequently: true });
    context.fillStyle = "#000";
    context.textBaseline = "alphabetic";
    context.font = '100px "League Gothic"';
    const capRatio = context.measureText("H").actualBoundingBoxAscent / 100;
    const stem = context.measureText("I");
    const stemRatio = (stem.actualBoundingBoxLeft + stem.actualBoundingBoxRight) / 100;
    for (const stave of staves) {
        const capHeight = (stave.y1 - stave.y0) * scale;
        context.font = `${capHeight / capRatio}px "League Gothic"`;
        const toX = (time) =>
            stave.x0 * scale + ((time - stave.t0) / (stave.t1 - stave.t0)) * (stave.x1 - stave.x0) * scale;
        const letters = stave.words.flatMap((word, wordIndex) => {
            const left = toX(word.start);
            const right = toX(word.end);
            const inset = Math.min(18 * scale, (right - left) * 0.1);
            const widths = word.letters.map(([letter]) => context.measureText(letter).width);
            return letterBoxes(word, left + inset, right, widths).map((box, index) => ({
                ...box,
                wordIndex,
                natural: widths[index],
                room: Math.max(1, box.x1 - box.x0 - 2 * scale),
            }));
        });
        // A narrow capital such as I takes the stave's typical squeeze, so its stem matches the
        // stems around it and never becomes a slab.
        const typical =
            letters.reduce((sum, box) => sum + box.room, 0) / letters.reduce((sum, box) => sum + box.natural, 0);
        // Where each word's glyphs actually landed, in CSS pixels: the ruler registers to this.
        stave.extents = stave.words.map(() => [Infinity, -Infinity]);
        // Which letters hold the stave's screen: those whose stems take two of its dot columns, which
        // stand a cell over the square root of 2 apart on the 45-degree screen.
        const cell = (stave.y1 - stave.y0) / HALFTONE.cellsPerStave;
        stave.screened = new Uint8Array(width).fill(255);
        for (const box of letters) {
            const limit = box.natural < capHeight * 0.3 ? Math.min(typical, MAX_STRETCH) : MAX_STRETCH;
            const stretch = Math.min(box.room / box.natural, limit);
            const drawn = box.natural * stretch;
            const x = box.x0 + (box.room - drawn) / 2;
            const stemWidth = (stemRatio * capHeight * stretch) / capRatio / scale;
            stave.screened.fill(
                stemWidth < HALFTONE.stemCells * cell * Math.SQRT1_2 ? 0 : 255,
                Math.floor(x / scale),
                Math.ceil((x + drawn) / scale),
            );
            context.setTransform(stretch, 0, 0, 1, x, stave.y1 * scale);
            context.fillText(box.letter, 0, 0);
            const extent = stave.extents[box.wordIndex];
            extent[0] = Math.min(extent[0], x / scale);
            extent[1] = Math.max(extent[1], (x + drawn) / scale);
        }
        context.setTransform(1, 0, 0, 1, 0, 0);
    }
    return context.getImageData(0, 0, ink.width, ink.height);
}

function compile(gl) {
    const program = gl.createProgram();
    for (const [type, source] of [
        [gl.VERTEX_SHADER, VERTEX],
        [gl.FRAGMENT_SHADER, FRAGMENT],
    ]) {
        const shader = gl.createShader(type);
        gl.shaderSource(shader, source);
        gl.compileShader(shader);
        if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
            throw new Error(gl.getShaderInfoLog(shader));
        }
        gl.attachShader(program, shader);
    }
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
        throw new Error(gl.getProgramInfoLog(program));
    }
    return program;
}

function texture(gl, unit, width, height, pixels, filter = gl.LINEAR) {
    const handle = gl.createTexture();
    gl.activeTexture(gl.TEXTURE0 + unit);
    gl.bindTexture(gl.TEXTURE_2D, handle);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, width, height, 0, gl.RED, gl.UNSIGNED_BYTE, pixels);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return handle;
}

function formatKhz(hertz) {
    return `${(hertz / 1000).toFixed(1).replace(/\.0$/, "")} kHz`;
}

function setUp(gl, clip, spectrum, cut) {
    const program = compile(gl);
    gl.useProgram(program);
    const quad = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    const corner = gl.getAttribLocation(program, "corner");
    gl.enableVertexAttribArray(corner);
    gl.vertexAttribPointer(corner, 2, gl.FLOAT, false, 0, 0);
    const uniform = (name) => gl.getUniformLocation(program, name);
    texture(gl, 1, clip.bins, clip.frames, spectrum);
    gl.uniform1i(uniform("shapes"), 0);
    gl.uniform1i(uniform("spectrum"), 1);
    gl.uniform1i(uniform("screened"), 2);
    gl.uniform1f(uniform("cut"), cut);
    gl.uniform1f(uniform("frames"), clip.frames);
    gl.uniform1f(uniform("hop"), clip.hop_ms / 1000);
    gl.uniform1f(uniform("range"), SDF_RANGE);
    const styles = getComputedStyle(document.documentElement);
    gl.uniform3fv(uniform("ink"), hexToRgb(styles.getPropertyValue("--ink")));
    gl.uniform3fv(uniform("red"), hexToRgb(styles.getPropertyValue("--red")));
    gl.uniform3fv(uniform("hot"), hexToRgb(styles.getPropertyValue("--hot")));
    return uniform;
}

const bare = (text) => text.replace(/[^\p{L}]/gu, "");

// The status item opens the app's menu. Where there is room it starts open, the way the app is
// shown; on smaller screens it opens on a press, as a sheet on a phone.
const roomy = matchMedia("(min-width: 1100px)");
const menuOpen = () => menuItem.getAttribute("aria-expanded") === "true";
const openMenu = (open) => menuItem.setAttribute("aria-expanded", String(open));
openMenu(roomy.matches && frame === null);
menuItem.addEventListener("click", () => openMenu(!menuOpen()));
document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && menuOpen() && !roomy.matches) {
        openMenu(false);
        menuItem.focus();
    }
});
document.addEventListener("pointerdown", (event) => {
    if (menuOpen() && !roomy.matches && !menubar.contains(event.target)) {
        openMenu(false);
    }
});

async function start() {
    const clip = await (await fetch("clip/clip.json")).json();
    const words = clip.words;
    const duration = clip.seconds;
    const hop = clip.hop_ms / 1000;
    const cut = clip.cut_hz / clip.top_hz;
    const spectrum = Uint8Array.from(atob(clip.spectrum), (character) => character.charCodeAt(0));
    const parked = duration + RUN_ON;

    const wordButtons = words.map((word, index) => {
        const item = document.createElement("li");
        const button = document.createElement("button");
        button.type = "button";
        button.className = "ruler__word";
        button.textContent = bare(word.text);
        button.addEventListener("pointerenter", () => sweepWord(index));
        button.addEventListener("focus", () => sweepWord(index));
        button.addEventListener("click", () => playWord(index));
        item.append(button);
        rulerWords.append(item);
        return button;
    });

    await document.fonts.load('100px "League Gothic"');
    const gl = canvas.getContext("webgl2", { antialias: false, premultipliedAlpha: true });
    const uniform = gl ? setUp(gl, clip, spectrum, cut) : null;

    const state = {
        staves: [],
        front: parked,
        playhead: -1,
        sweep: null,
        take: null,
        word: -1,
        audio: null,
        intro: null,
        retreat: null,
        bypassed: false,
        gap: [1e6, 1e6],
        other: null,
        paused: false,
        lastTick: 0,
        visible: true,
        glow: 0,
    };
    let shapes = null;
    let screenTexture = null;
    let raf = 0;

    function relayout() {
        const width = score.clientWidth;
        const height = score.clientHeight;
        const narrow = width < NARROW;
        const ratio = Math.min(devicePixelRatio || 1, 2);
        state.staves = layoutStaves(words, width, height, narrow);
        drawStaveLabels();
        // The distance field is built at CSS resolution or a little above; the shader's edges stay sharp at any ratio.
        const scale = Math.min(ratio, 1.5, 2_000_000 / (width * height));
        const image = drawWords(state.staves, width, height, scale);
        registerRuler();
        if (!gl) {
            return;
        }
        canvas.width = Math.round(width * ratio);
        canvas.height = Math.round(height * ratio);
        const field = signedDistance(image.data, image.width, image.height, SDF_RANGE * scale);
        if (shapes) {
            gl.deleteTexture(shapes);
        }
        shapes = texture(gl, 0, image.width, image.height, field);
        const rows = new Uint8Array(width * 4);
        for (const [index, stave] of state.staves.entries()) {
            rows.set(stave.screened, index * width);
        }
        if (screenTexture) {
            gl.deleteTexture(screenTexture);
        }
        screenTexture = texture(gl, 2, width, 4, rows, gl.NEAREST);
        gl.uniform2f(uniform("size"), width, height);
        gl.uniform1i(uniform("staveCount"), state.staves.length);
        const padded = (values, length) => values.concat(Array(length).fill(0)).slice(0, length);
        gl.uniform4fv(uniform("staveX"), padded(state.staves.flatMap((s) => [s.x0, s.x1, s.t0, s.t1]), 16));
        gl.uniform3fv(uniform("staveY"), padded(state.staves.flatMap((s) => [s.y0, s.y1, s.restored ? 1 : 0]), 12));
        gl.viewport(0, 0, canvas.width, canvas.height);
        draw();
    }

    // Each word's button sits under the glyphs the shader drew for it, on its own pair's stave.
    function registerRuler() {
        for (const stave of state.staves.filter((s) => s.restored)) {
            for (const [index, word] of stave.words.entries()) {
                const [x0, x1] = stave.extents[index];
                const width = Math.max(x1 - x0, MIN_TARGET);
                const item = wordButtons[words.indexOf(word)].parentElement;
                item.style.left = `${(x0 + x1 - width) / 2}px`;
                item.style.width = `${width}px`;
                item.style.top = `${stave.y1 + 8}px`;
            }
        }
    }

    function restoredDetail() {
        return state.bypassed ? "bypassed" : `drawn back up to ${formatKhz(clip.top_hz)}`;
    }

    function scaleMark(at, text) {
        const mark = document.createElement("span");
        mark.className = `stave__tick stave__tick--${at}`;
        mark.textContent = text;
        return mark;
    }

    function drawStaveLabels() {
        staveLayer.replaceChildren(
            ...state.staves.map((stave) => {
                const row = document.createElement("div");
                row.className = `stave${stave.restored ? " stave--restored" : ""}`;
                row.style.left = `${stave.x0}px`;
                row.style.top = `${stave.y0}px`;
                row.style.width = `${stave.x1 - stave.x0}px`;
                row.style.height = `${stave.y1 - stave.y0}px`;
                row.style.setProperty("--column", `${stave.x0 - stave.margin}px`);
                row.style.setProperty("--cut-at", `${(stave.y1 - stave.y0) * (1 - cut)}px`);
                const cap = document.createElement("div");
                cap.className = "stave__cap";
                const line = document.createElement("div");
                line.className = "stave__cut";
                row.append(
                    cap,
                    line,
                    scaleMark("top", formatKhz(clip.top_hz)),
                    scaleMark("cut", formatKhz(clip.cut_hz)),
                    scaleMark("base", "0"),
                );
                if (stave.named) {
                    const label = document.createElement("p");
                    label.className = "stave__label";
                    const name = document.createElement("span");
                    name.className = "stave__name";
                    name.textContent = stave.restored ? "Through Untunnel" : "Through the headset";
                    const detail = document.createElement("span");
                    detail.className = "stave__detail";
                    detail.textContent = stave.restored ? restoredDetail() : `cut at ${formatKhz(clip.cut_hz)}`;
                    label.append(name, " ", detail);
                    row.append(label);
                }
                return row;
            }),
        );
    }

    // Whether the top of the line at a time is drawn back: behind the front, outside a bypassed stretch.
    const NONE = [1e6, 1e6];
    const restoredAt = (time) => time < state.front && !(time >= state.gap[0] && time < state.gap[1]);

    // The menu header carries the whole line in small, shaped by its spectrum: each column is a
    // 20 ms frame, ink up from the floor as loud as the band under the cut, red up from the cut
    // as loud as the band above it, drawn only where the top is restored.
    const bands = Array.from({ length: clip.frames }, (_, frame) => {
        const row = spectrum.subarray(frame * clip.bins, (frame + 1) * clip.bins);
        const split = Math.round(cut * clip.bins);
        const mean = (values) => values.reduce((sum, value) => sum + value, 0) / values.length / 255;
        return [mean(row.subarray(0, split)), mean(row.subarray(split))];
    });
    const [inkColour, redColour] = ["--ink", "--red"].map((name) =>
        getComputedStyle(document.documentElement).getPropertyValue(name).trim(),
    );
    let stripDrawn = "";
    function drawStrip() {
        const ratio = Math.min(devicePixelRatio || 1, 2);
        const width = Math.round(strip.clientWidth * ratio);
        const height = Math.round(strip.clientHeight * ratio);
        const key = `${width}x${height}:${state.front.toFixed(2)}:${state.gap}`;
        if (!width || !height || key === stripDrawn) {
            return;
        }
        stripDrawn = key;
        strip.width = width;
        strip.height = height;
        const context = strip.getContext("2d");
        const cutY = height * (1 - cut);
        const column = width / clip.frames;
        for (const [frame, [low, high]] of bands.entries()) {
            const x = frame * column;
            const w = Math.max(1, column - ratio);
            context.fillStyle = inkColour;
            const lowHeight = (height - cutY) * Math.min(1, 0.15 + low);
            context.fillRect(x, height - lowHeight, w, lowHeight);
            if (restoredAt((frame + 0.5) * hop)) {
                context.fillStyle = redColour;
                const highHeight = cutY * Math.min(1, 0.1 + high);
                context.fillRect(x, cutY - highHeight, w, highHeight);
            }
        }
    }

    // Without WebGL the still stays in place and ground-coloured veils cover the tops that are
    // not drawn back yet, so the fallback still follows playback and Bypass.
    function drawVeils() {
        const veils = [];
        for (const stave of state.staves.filter((s) => s.restored)) {
            const toX = (time) =>
                stave.x0 + ((Math.min(Math.max(time, stave.t0), stave.t1) - stave.t0) / (stave.t1 - stave.t0)) * (stave.x1 - stave.x0);
            const spans = [[state.front, stave.t1]];
            if (state.gap[0] < state.front) {
                spans.push([state.gap[0], Math.min(state.gap[1], state.front)]);
            }
            // Played bypassed, the tops drawn back before the bypass stay, dimmed.
            const dimmed = state.bypassed && state.take === "line" ? [stave.t0, Math.min(state.gap[0], state.front)] : null;
            if (dimmed) {
                spans.push(dimmed);
            }
            for (const span of spans) {
                const [from, to] = span;
                const x0 = toX(from);
                const x1 = toX(to);
                if (x1 - x0 < 0.5) {
                    continue;
                }
                const veil = document.createElement("div");
                veil.className = "score__veil";
                veil.classList.toggle("is-front", from === state.front && from > stave.t0);
                veil.classList.toggle("is-dim", span === dimmed);
                veil.style.left = `${x0}px`;
                veil.style.width = `${x1 - x0 + 2}px`;
                // From just above the cap line, where the still's letter edges soften, to just above the cut.
                veil.style.top = `${stave.y0 - 4}px`;
                veil.style.height = `${(stave.y1 - stave.y0) * (1 - cut) + 4}px`;
                veils.push(veil);
            }
        }
        veilLayer.replaceChildren(...veils);
    }

    // The label rides the front while it moves: right of the rule in the empty band ahead, or
    // left of it above the cap line once the line runs out of room.
    function drawFrontLabel() {
        const stave = state.staves.find((s) => s.restored && state.front > s.t0 && state.front < s.t1);
        const riding = state.take === "line" || state.intro !== null || state.retreat !== null || query.has("at");
        const on = stave !== undefined && riding;
        frontLabel.classList.toggle("is-on", on);
        if (!on) {
            return;
        }
        const playingBypassed = state.bypassed && state.take === "line";
        const text =
            state.retreat !== null
                ? "Bypassed"
                : state.paused
                  ? "Paused"
                  : playingBypassed
                    ? "Bypassed, the headset alone"
                    : `Restoring, ${clip.hop_ms} ms at a time`;
        if (frontLabel.textContent !== text) {
            frontLabel.textContent = text;
        }
        frontLabel.classList.toggle("is-bypassed", playingBypassed || state.paused);
        const x = stave.x0 + ((state.front - stave.t0) / (stave.t1 - stave.t0)) * (stave.x1 - stave.x0);
        const room = x + 8 + frontLabel.offsetWidth <= stave.x1;
        frontLabel.style.left = `${room ? x + 8 : x - 8 - frontLabel.offsetWidth}px`;
        frontLabel.style.top = `${room ? stave.y0 + 6 : stave.y0 - 16}px`;
    }

    function draw() {
        const active = state.sweep ? state.sweep.index : state.take === "word" ? state.word : -1;
        for (const [index, button] of wordButtons.entries()) {
            button.classList.toggle("is-active", index === active);
        }
        if (!gl) {
            drawVeils();
        } else {
            const sweep = state.sweep ? [state.sweep.t0, state.sweep.t1, state.sweep.at] : [0, 0, -1];
            gl.uniform2fv(uniform("gap"), state.gap);
            gl.uniform1f(uniform("front"), state.front);
            gl.uniform3fv(uniform("sweep"), sweep);
            gl.uniform1f(uniform("playhead"), state.playhead);
            gl.uniform1f(uniform("glow"), state.glow);
            gl.uniform1f(uniform("bypassing"), state.bypassed && state.take === "line" ? 1 : 0);
            gl.clearColor(0, 0, 0, 0);
            gl.clear(gl.COLOR_BUFFER_BIT);
            gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
            if (score.dataset.state !== "live") {
                score.dataset.state = "live";
            }
        }
        drawFrontLabel();
        drawStrip();
    }

    function moving() {
        return (
            state.intro !== null ||
            state.retreat !== null ||
            (state.take === "line" && !state.paused) ||
            state.sweep !== null
        );
    }

    function tick(now) {
        raf = 0;
        const dt = Math.min(0.05, state.lastTick ? (now - state.lastTick) / 1000 : 0);
        state.lastTick = now;
        const time = state.audio ? state.audio.currentTime : 0;
        if (state.intro !== null) {
            state.front = Math.min(parked, (now - state.intro) / 1000);
            if (state.front >= parked) {
                state.intro = null;
            }
        } else if (state.retreat !== null) {
            state.front = Math.max(0, state.retreat.from - ((now - state.retreat.started) / 1000) * RETREAT_SPEED);
            if (state.front <= 0) {
                state.retreat = null;
            }
        } else if (state.take === "line") {
            const word = words.find((item) => time >= item.start && time < item.end);
            state.front = reducedMotion.matches && word ? word.end : time;
            elapsed.textContent = `${time.toFixed(2)} s`;
        } else if (state.take === "headset") {
            state.playhead = time;
        }
        if (state.take === "word") {
            const word = words[state.word];
            if (state.sweep) {
                state.sweep.at = time;
            }
            if (time >= word.end) {
                stop(true);
            }
        } else if (state.sweep) {
            const { t0, t1, started } = state.sweep;
            const pace = (t1 - t0) / Math.max(t1 - t0, MIN_SWEEP_SECONDS);
            state.sweep.at = t0 + ((now - started) / 1000) * pace;
            if (state.sweep.at >= t1 + 0.05) {
                state.sweep = null;
            }
        }
        const going = moving();
        // The edge burns while the front moves and cools over about half a second once it stops.
        // Reduced motion keeps the ink still: no drying, no flash.
        // Bypass cuts with the plain red rule: no glow while the tops come off.
        const target = going && state.retreat === null && !reducedMotion.matches ? 1 : 0;
        state.glow += (target - state.glow) * (1 - Math.exp(-(target ? 20 : 4) * dt));
        draw();
        if (going || (state.take !== null && !state.paused) || state.glow > 0.01) {
            kick();
        } else {
            state.glow = 0;
            state.lastTick = 0;
            draw();
        }
    }

    function kick() {
        if (!raf && state.visible && !document.hidden) {
            raf = requestAnimationFrame(tick);
        }
    }

    function sweepWord(index) {
        if (reducedMotion.matches || state.bypassed || state.take !== null || state.sweep?.index === index) {
            return;
        }
        const word = words[index];
        state.intro = null;
        state.front = parked;
        state.sweep = { index, t0: word.start, t1: word.end, at: word.start, started: performance.now() };
        kick();
    }

    function wordAtPointer(event) {
        const box = score.getBoundingClientRect();
        const x = event.clientX - box.left;
        const y = event.clientY - box.top;
        const stave = state.staves.find((s) => y >= s.y0 - 24 && y <= s.y1 + 8);
        if (!stave || x < stave.x0 || x > stave.x1) {
            return -1;
        }
        const time = stave.t0 + ((x - stave.x0) / (stave.x1 - stave.x0)) * (stave.t1 - stave.t0);
        return words.findIndex((word) => stave.words.includes(word) && time >= word.start && time < word.end);
    }

    const onRuler = (event) => event.target.closest(".ruler") !== null;
    score.addEventListener("pointermove", (event) => {
        const index = event.pointerType === "mouse" && !onRuler(event) ? wordAtPointer(event) : -1;
        if (index >= 0) {
            sweepWord(index);
        }
    });
    score.addEventListener("click", (event) => {
        const index = onRuler(event) ? -1 : wordAtPointer(event);
        if (index >= 0) {
            playWord(index);
        }
    });

    const takes = { line: "clip/untunnel.flac", word: "clip/untunnel.flac", headset: "clip/headset.flac" };
    const labels = new Map(buttons.map((button) => [button, button.textContent.trim()]));
    const playLabel = () => (state.bypassed ? "Play bypassed" : labels.get(playButton));

    function stop(finished) {
        const take = state.take;
        state.audio?.pause();
        state.other?.pause();
        state.other = null;
        state.take = null;
        state.paused = false;
        state.playhead = -1;
        for (const button of buttons) {
            button.replaceChildren(button === playButton ? playLabel() : labels.get(button));
        }
        quiet.setAttribute("aria-pressed", "false");
        if (take === "line") {
            state.front = state.bypassed ? 0 : parked;
            state.gap = NONE;
            status.textContent = !finished
                ? "Stopped."
                : state.bypassed
                  ? "That is the line as the headset sends it."
                  : "Every top drawn back. Press again to hear it again.";
        } else if (take === "headset") {
            status.textContent = finished ? "That is the call as the other side hears it." : "Stopped.";
        } else if (take === "word") {
            state.sweep = null;
            state.word = -1;
            status.textContent = finished ? "" : "Stopped.";
        }
        drawStaveLabels();
        kick();
    }

    function endsTake(audio) {
        audio.addEventListener("ended", () => {
            if (state.audio === audio) {
                stop(true);
            }
        });
        return audio;
    }

    async function play(take, from = 0) {
        stop(false);
        const bypassed = take === "line" && state.bypassed;
        const audio = endsTake(new Audio(bypassed ? takes.headset : takes[take]));
        state.audio = audio;
        state.intro = null;
        state.take = take;
        if (take === "line") {
            // The other take waits, loaded and silent, so Bypass can switch to it on the frame.
            state.other = endsTake(new Audio(bypassed ? takes.line : takes.headset));
            state.other.preload = "auto";
            state.other.load();
            state.gap = bypassed ? [-1e6, 1e6] : NONE;
        } else if (take === "word") {
            setBypass(false, false);
        }
        drawStaveLabels();
        try {
            if (from > 0) {
                await new Promise((resolve, reject) => {
                    audio.addEventListener("loadedmetadata", resolve, { once: true });
                    audio.addEventListener("error", reject, { once: true });
                    audio.load();
                });
                audio.currentTime = from;
            }
            await audio.play();
        } catch {
            stop(false);
            status.textContent = "This browser could not play the clip. Press play to retry.";
        }
        kick();
    }

    // Bypass mid-line swaps takes on the frame it was pressed, fading over 40 ms so it never clicks.
    async function crossfade() {
        const from = state.audio;
        const to = state.other;
        state.audio = to;
        state.other = from;
        try {
            if (to.readyState < 1) {
                await new Promise((resolve, reject) => {
                    to.addEventListener("loadedmetadata", resolve, { once: true });
                    to.addEventListener("error", reject, { once: true });
                    if (to.error) reject(to.error);
                });
            }
            to.currentTime = from.currentTime;
            if (state.paused) return;
            to.volume = 0;
            await to.play();
        } catch {
            stop(false);
            status.textContent = "This browser could not switch takes. Press play to retry.";
            return;
        }
        const started = performance.now();
        const fade = () => {
            const k = Math.min(1, (performance.now() - started) / 40);
            to.volume = k;
            from.volume = 1 - k;
            if (k < 1) {
                requestAnimationFrame(fade);
            } else {
                from.pause();
                from.volume = 1;
            }
        };
        requestAnimationFrame(fade);
    }

    function playWord(index) {
        const word = words[index];
        const started = play("word", word.start);
        state.word = index;
        state.sweep = null;
        status.textContent = `Playing “${bare(word.text)}” through Untunnel.`;
        started.then(() => {
            if (state.take === "word" && state.word === index && !reducedMotion.matches) {
                state.sweep = { index, t0: word.start, t1: word.end, at: word.start, started: performance.now() };
                kick();
            }
        });
    }

    // While the line plays, the play button keeps its width and shows a pause or play mark and the
    // time into the line, never the word "stop" and never a red fill.
    const quiet = buttons.find((button) => button !== playButton);
    let elapsed = document.createElement("span");
    function showPlayback(glyph, name) {
        const mark = document.createElement("span");
        mark.className = `button__mark button__mark--${glyph}`;
        mark.setAttribute("aria-hidden", "true");
        const time = document.createElement("span");
        time.className = "button__time";
        time.setAttribute("aria-hidden", "true");
        time.textContent = elapsed.textContent || "0.00 s";
        const label = document.createElement("span");
        label.className = "visually-hidden";
        label.textContent = name;
        playButton.replaceChildren(mark, time, label);
        elapsed = time;
    }

    quiet.setAttribute("aria-pressed", "false");
    quiet.addEventListener("click", () => {
        if (state.take === "headset") {
            stop(false);
            return;
        }
        play("headset");
        state.sweep = null;
        quiet.setAttribute("aria-pressed", "true");
        status.textContent = "Playing what the headset sends. Nothing above the cut.";
    });

    playButton.addEventListener("click", () => {
        if (state.take === "line") {
            state.paused = !state.paused;
            if (state.paused) {
                state.audio.pause();
                showPlayback("play", "Resume the line");
                status.textContent = "Paused.";
            } else {
                state.audio.play().catch(() => {
                    stop(false);
                    status.textContent = "This browser could not play the clip. Press play to retry.";
                });
                showPlayback("pause", "Pause the line");
                status.textContent = "Playing through Untunnel.";
            }
            kick();
            return;
        }
        play("line");
        state.sweep = null;
        state.front = reducedMotion.matches ? parked : 0;
        elapsed.textContent = "";
        showPlayback("pause", "Pause the line");
        status.textContent = state.bypassed
            ? "Playing the line bypassed, as the headset sends it."
            : "Playing through Untunnel. The red follows the sound.";
    });

    // The menu picture's Bypass Restore does what the app's does: the tops go, and come back on Resume.
    function setBypass(on, animate = true) {
        if (state.bypassed === on) {
            return;
        }
        state.bypassed = on;
        menubar.dataset.bypassed = String(on);
        bypassButton.firstChild.textContent = on ? "Resume Restore " : "Bypass Restore ";
        // The app's microphone line, as it reads in each state.
        menuStatus.textContent = on ? "Microphone bypassed" : `Restoring at ${formatKhz(2 * clip.top_hz)}`;
        drawStaveLabels();
        // Mid-line the cut is part of the audio: the takes swap on this frame, and the stretch
        // played bypassed stays cut. Only the latest bypassed stretch is kept.
        if (state.take === "line") {
            const at = state.audio.currentTime;
            state.gap = on ? [at, 1e6] : [state.gap[0], at];
            crossfade();
            kick();
            return;
        }
        if (state.take === null) {
            playButton.replaceChildren(playLabel());
        }
        state.sweep = null;
        state.intro = null;
        state.retreat = null;
        if (!animate || reducedMotion.matches) {
            state.front = on ? 0 : parked;
        } else if (on) {
            state.retreat = { from: Math.min(state.front, duration), started: performance.now() };
        } else {
            state.front = 0;
            state.intro = performance.now();
        }
        kick();
    }
    bypassButton.addEventListener("click", () => {
        if (state.take === "word" || state.take === "headset") {
            stop(false);
        }
        const at = state.take === "line" ? ` at ${state.audio.currentTime.toFixed(2)} s` : "";
        setBypass(!state.bypassed);
        status.textContent = state.bypassed
            ? `Bypassed${at}: the call gets what the headset sends.`
            : `Restoring again${at}.`;
    });

    new ResizeObserver(drawStrip).observe(strip);
    new IntersectionObserver(([entry]) => {
        state.visible = entry.isIntersecting;
        kick();
    }).observe(score);
    document.addEventListener("visibilitychange", kick);
    let resizeTimer = 0;
    new ResizeObserver(() => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(relayout, 120);
    }).observe(score);

    if (query.has("at")) {
        state.front = Number(query.get("at"));
    }
    relayout();
    if (!still()) {
        state.front = 0;
        draw();
        setTimeout(() => {
            if (state.take === null && state.sweep === null && !state.bypassed) {
                state.intro = performance.now();
                kick();
            } else {
                state.front = parked;
                draw();
            }
        }, INTRO_DELAY_MS);
    }
    buttons.forEach((button) => { button.disabled = false; });
    document.documentElement.dataset.ready = "true";
}

// Start after the first paint, so the page reads before the GPU wakes.
requestAnimationFrame(() =>
    setTimeout(() => {
        start().catch((error) => {
            score.dataset.state = "still";
            document.documentElement.dataset.ready = "error";
            status.textContent = "The clip could not load. Reload the page to retry.";
            console.error(error);
        });
    }),
);
