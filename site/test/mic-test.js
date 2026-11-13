"use strict";

// The page mirrors the app's spectrum measurement: a 2048-point periodic Hann window,
// 1024-sample hops, 1024 log-spaced rows from 125 Hz to 24 kHz, and a 40 dB drop from the
// loudest row. Keeping these constants together makes any drift obvious.
const TAKE_SECONDS = 5;
const FFT_LENGTH = 2048;
const HOP_LENGTH = 1024;
const ROW_COUNT = 1024;
const AXIS_LOWER_HZ = 125;
const AXIS_UPPER_HZ = 24000;
const DROP_DB = 40;
const RESULT_BUDGET_MS = 1000;
const SAVE_WIDTH = 1200;
const SAVE_HEIGHT = 630;
const WORKLET_NAME = "take-recorder";
const WORKLET_URL = "mic-worklet.js";

const STATES = Object.freeze([
    "idle",
    "requesting",
    "denied",
    "unsupported",
    "ready",
    "taking",
    "result",
    "compare",
    "comparing",
    "compared",
    "error",
]);

const STATE_ALIASES = {
    default: "idle",
    intro: "idle",
    prompt: "idle",
    loading: "requesting",
    permission: "requesting",
    picker: "ready",
    "device-picker": "ready",
    recording: "taking",
    analysing: "taking",
    analyzing: "taking",
    "no-device": "error",
    "no-headset": "error",
    saved: "result",
};

const STATUS = {
    idle: "Ready when you are.",
    requesting: "Waiting for microphone permission…",
    denied: "Microphone access was blocked.",
    unsupported: "This browser cannot record audio through a worklet.",
    ready: "Microphone ready. Record a five-second take.",
    taking: "Recording five seconds…",
    result: "Rolloff measured.",
    compare: "The built-in microphone can be recorded next.",
    comparing: "Recording the built-in microphone…",
    compared: "Comparison ready.",
    error: "The microphone could not be used.",
};

// The main page's line, through the simulated headset and restored, stands in until a listening
// page publishes takes from real headsets.
const EXAMPLE = { headset: "../clip/headset.flac", restored: "../clip/untunnel.flac" };
const WORD = "STOP";

// Previews of each state show a real measurement, never a made-up device: the repository's
// sample call recording, which this page measures at 7035 Hz (fixtures/narrowband/
// sample.rolloff.json, checked by tools/tests/test_site_browser.py), and the page's line before
// the headset simulation, 10875 Hz in docs/clip.md.
const REFERENCE = {
    deviceId: "default",
    deviceName: "sample call recording",
    rolloffHz: 7035,
    sampleRateHz: 16000,
    sample: "A sample call recording at 16 kHz, measured by this page, shown until you record your own.",
};
const BEFORE_THE_HEADSET = {
    deviceId: "builtin",
    deviceName: "same line before the headset",
    rolloffHz: 10875,
    sampleRateHz: 48000,
    sample: "Beside it, the main page's spoken line before the headset.",
};

const FIXTURES = {
    idle: {},
    requesting: {},
    denied: {
        message: "Microphone access was blocked. Allow it in the site settings, then try again.",
    },
    unsupported: {
        message:
            "This browser cannot record through an audio worklet. Use a current Safari, Chrome, Firefox or Edge.",
    },
    ready: {
        devices: [
            { deviceId: "default", label: "Default microphone" },
            { deviceId: "builtin", label: "Built-in Microphone" },
        ],
    },
    taking: { secondsLeft: 2.4 },
    result: REFERENCE,
    compare: REFERENCE,
    comparing: { ...REFERENCE, secondsLeft: 1.2 },
    compared: { current: REFERENCE, comparison: BEFORE_THE_HEADSET },
    error: { message: "No microphone was found. Connect one and try again." },
};

const HANN = new Float64Array(FFT_LENGTH);
for (let index = 0; index < FFT_LENGTH; index += 1) {
    HANN[index] = 0.5 - 0.5 * Math.cos((2 * Math.PI * index) / FFT_LENGTH);
}

const rowCache = new Map();

function rowsFor(sampleRate) {
    const cached = rowCache.get(sampleRate);
    if (cached) {
        return cached;
    }
    const half = FFT_LENGTH / 2;
    const binHz = sampleRate / FFT_LENGTH;
    const edges = new Float64Array(ROW_COUNT + 1);
    const first = new Int32Array(ROW_COUNT);
    const last = new Int32Array(ROW_COUNT);
    for (let row = 0; row <= ROW_COUNT; row += 1) {
        const position = row / ROW_COUNT;
        edges[row] = AXIS_LOWER_HZ * Math.pow(AXIS_UPPER_HZ / AXIS_LOWER_HZ, position);
    }
    for (let row = 0; row < ROW_COUNT; row += 1) {
        const low = Math.round(edges[row] / binHz);
        const high = Math.round(edges[row + 1] / binHz);
        first[row] = Math.max(1, low);
        last[row] = Math.min(half - 1, Math.max(high, low, 1));
    }
    const rows = { edges, first, last, half };
    rowCache.set(sampleRate, rows);
    return rows;
}

function fft(real, imaginary) {
    const length = real.length;
    for (let index = 1, reversed = 0; index < length; index += 1) {
        let bit = length >> 1;
        for (; reversed & bit; bit >>= 1) {
            reversed ^= bit;
        }
        reversed ^= bit;
        if (index < reversed) {
            const realValue = real[index];
            const imaginaryValue = imaginary[index];
            real[index] = real[reversed];
            imaginary[index] = imaginary[reversed];
            real[reversed] = realValue;
            imaginary[reversed] = imaginaryValue;
        }
    }
    for (let size = 2; size <= length; size <<= 1) {
        const angle = (-2 * Math.PI) / size;
        const stepReal = Math.cos(angle);
        const stepImaginary = Math.sin(angle);
        for (let start = 0; start < length; start += size) {
            let twiddleReal = 1;
            let twiddleImaginary = 0;
            for (let offset = 0; offset < size / 2; offset += 1) {
                const even = start + offset;
                const odd = even + size / 2;
                const oddReal =
                    real[odd] * twiddleReal - imaginary[odd] * twiddleImaginary;
                const oddImaginary =
                    real[odd] * twiddleImaginary + imaginary[odd] * twiddleReal;
                real[odd] = real[even] - oddReal;
                imaginary[odd] = imaginary[even] - oddImaginary;
                real[even] += oddReal;
                imaginary[even] += oddImaginary;
                const nextReal = twiddleReal * stepReal - twiddleImaginary * stepImaginary;
                twiddleImaginary = twiddleReal * stepImaginary + twiddleImaginary * stepReal;
                twiddleReal = nextReal;
            }
        }
    }
}

// Welch's method: average the periodograms of Hann-windowed 2048-point segments with 50 %
// overlap, then take the loudest bin in each log-spaced row.
function welchRowPower(samples, sampleRate) {
    const rows = rowsFor(sampleRate);
    const power = new Float64Array(ROW_COUNT);
    const real = new Float64Array(FFT_LENGTH);
    const imaginary = new Float64Array(FFT_LENGTH);
    let frames = 0;
    let pushed = 0;
    for (let start = 0; start < samples.length; start += HOP_LENGTH) {
        const end = Math.min(start + HOP_LENGTH, samples.length);
        pushed += end - start;
        if (pushed < FFT_LENGTH) {
            continue;
        }
        const frameStart = pushed - FFT_LENGTH;
        for (let index = 0; index < FFT_LENGTH; index += 1) {
            real[index] = samples[frameStart + index] * HANN[index];
            imaginary[index] = 0;
        }
        fft(real, imaginary);
        for (let row = 0; row < ROW_COUNT; row += 1) {
            let loudest = 0;
            for (let bin = rows.first[row]; bin <= rows.last[row]; bin += 1) {
                const binPower = real[bin] * real[bin] + imaginary[bin] * imaginary[bin];
                if (binPower > loudest) {
                    loudest = binPower;
                }
            }
            power[row] += loudest;
        }
        frames += 1;
    }
    if (frames === 0) {
        throw new Error("The take was too short to measure.");
    }
    for (let row = 0; row < ROW_COUNT; row += 1) {
        power[row] /= frames;
    }
    return { edges: rows.edges, power };
}

// The report's rolloff_40db_hz: the upper edge of the last row within 40 dB of the peak.
function rolloff40dbHz(samples, sampleRate) {
    if (!(sampleRate > 0) || samples.length < FFT_LENGTH) {
        throw new Error("The take was too short to measure.");
    }
    const { edges, power } = welchRowPower(samples, sampleRate);
    let peak = 0;
    for (let row = 0; row < ROW_COUNT; row += 1) {
        if (power[row] > peak) {
            peak = power[row];
        }
    }
    if (!(peak > 0)) {
        throw new Error("The take was silent. Read the passage aloud with the headset on.");
    }
    const threshold = peak / Math.pow(10, DROP_DB / 10);
    let top = 0;
    for (let row = 0; row < ROW_COUNT; row += 1) {
        if (power[row] >= threshold) {
            top = row;
        }
    }
    const edge = Math.min(edges[top + 1], sampleRate / 2);
    return Math.round(edge);
}

const api = {
    states: STATES,
    ready: false,
    state: "loading",
    lastRolloffHz: null,
    takeEndedAt: null,
    resultShownAt: null,
    resultBudgetMs: RESULT_BUDGET_MS,
    computeRolloff: rolloff40dbHz,
};

let audioContext = null;
let workletFailure = null;
let workletPromise = Promise.resolve();
let currentResult = null;
let devices = [];

function element(tag, attributes = {}, ...children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attributes)) {
        if (value === null || value === undefined || value === false) {
            continue;
        }
        if (key === "text") {
            node.textContent = String(value);
        } else if (key === "onClick") {
            node.addEventListener("click", value);
        } else if (value === true) {
            node.setAttribute(key, "");
        } else {
            node.setAttribute(key, String(value));
        }
    }
    for (const child of children.flat()) {
        if (child === null || child === undefined) {
            continue;
        }
        node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return node;
}

function messageOf(error) {
    if (error && typeof error === "object" && "message" in error) {
        return String(error.message);
    }
    return String(error);
}

function setState(name) {
    api.state = name;
    const main = document.getElementById("main");
    const status = document.getElementById("status");
    if (main) {
        main.dataset.state = name;
    }
    if (status) {
        status.textContent = STATUS[name] || "";
    }
}

function panel() {
    return document.getElementById("panel");
}

function formatKhz(hz) {
    const kilohertz = hz / 1000;
    return Number.isInteger(kilohertz) ? kilohertz.toFixed(0) : kilohertz.toFixed(1);
}

function formatHertz(hz) {
    return String(Math.round(hz));
}

function verdictFor(result) {
    const subject = result.sample ? `The ${result.deviceName}` : `Your ${result.deviceName}`;
    return `${subject}: this take’s −40 dB rolloff is ${formatHertz(result.rolloffHz)} Hz`;
}

function supportsRecording() {
    return Boolean(
        navigator.mediaDevices &&
            navigator.mediaDevices.getUserMedia &&
            globalThis.AudioContext &&
            globalThis.AudioWorkletNode,
    );
}

function audioConstraints(deviceId) {
    // Keep the chosen device and turn off the three processing stages a call would otherwise add.
    const audio = {
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
    };
    if (deviceId) {
        audio.deviceId = { exact: deviceId };
    }
    return { audio };
}

function renderIdle() {
    setState("idle");
    panel().replaceChildren(
        element(
            "button",
            { id: "start", class: "button button--primary", type: "button", onClick: requestMicrophone },
            "Record your microphone",
        ),
        element(
            "p",
            { class: "fine-print" },
            "The take stays in this tab. Only the rolloff number is shown, and the image is saved to your computer.",
        ),
        shelfFigure(
            STOP.cut_hz,
            `The word ${WORD} from the main page's line as a headset call sends it: nothing above ${formatKhz(STOP.cut_hz)} kHz, the rest drawn back by Untunnel in red. Record to see where your microphone stops.`,
        ),
    );
}

function renderRequesting() {
    setState("requesting");
    panel().replaceChildren(
        element("p", { class: "big" }, "Waiting for permission…"),
        element("p", {}, "Choose Allow when the browser asks for the microphone."),
    );
}

function renderDenied(message) {
    setState("denied");
    panel().replaceChildren(
        element("p", { class: "error" }, message || FIXTURES.denied.message),
        retryButton(),
    );
}

function renderUnsupported(message) {
    setState("unsupported");
    panel().replaceChildren(element("p", { class: "error" }, message || FIXTURES.unsupported.message));
}

function retryButton() {
    return element(
        "button",
        { id: "start", class: "button button--primary", type: "button", onClick: requestMicrophone },
        "Try again",
    );
}

function renderReady(availableDevices) {
    devices = availableDevices;
    setState("ready");
    const select = element("select", { id: "device", name: "device" });
    availableDevices.forEach((device, index) => {
        select.append(
            element(
                "option",
                { value: device.deviceId || "" },
                device.label || `Microphone ${index + 1}`,
            ),
        );
    });
    const preferred = availableDevices.findIndex((device) => /default/i.test(device.label));
    select.selectedIndex = preferred >= 0 ? preferred : 0;
    panel().replaceChildren(
        element("label", { class: "field", for: "device" }, "Microphone"),
        select,
        element(
            "p",
            { class: "fine-print" },
            "The device list comes from the browser after permission. A headset in call mode may appear as a different device.",
        ),
        element(
            "button",
            { id: "take", class: "button button--primary", type: "button", onClick: takePrimary },
            "Record five seconds",
        ),
    );
}

function renderTaking(secondsLeft) {
    setState("taking");
    const elapsed = secondsLeft === null ? 0 : Math.max(0, TAKE_SECONDS - secondsLeft);
    panel().replaceChildren(
        element("p", { class: "big" }, "Recording…"),
        element("progress", {
            max: TAKE_SECONDS,
            value: elapsed,
            "aria-label": "Take progress",
        }),
        element(
            "p",
            {},
            secondsLeft === null
                ? "Read a sentence aloud in your normal call voice."
                : `${Number(secondsLeft).toFixed(1)} seconds left. Read a sentence aloud.`,
        ),
    );
}

function renderError(message) {
    setState("error");
    panel().replaceChildren(
        element("p", { class: "error" }, message || FIXTURES.error.message),
        retryButton(),
    );
}

// Before a take the figure shows the main page's STOP as a headset call sends it; after one, as
// the measured microphone does.
function shelfFigure(rolloffHz, caption) {
    const canvas = element("canvas", {
        id: "shelf",
        width: 1280,
        height: 520,
        role: "img",
        "aria-label": `The word ${WORD} from the main page's line, letter height standing for 0 to 24 kHz: black up to ${formatHertz(rolloffHz)} Hz, red above it where Untunnel predicts the rest.`,
    });
    const figure = element("figure", { class: "shelf" }, canvas, element("figcaption", {}, caption));
    // The scale is set in the page's own face, so both faces load before anything is drawn.
    Promise.allSettled(
        ['100px "League Gothic"', '400 16px "Source Serif 4"', '600 16px "Source Serif 4"'].map((font) =>
            document.fonts.load(font),
        ),
    ).then(() => {
        const context = canvas.getContext("2d");
        if (context) {
            context.clearRect(0, 0, canvas.width, canvas.height);
            // The scale reads at 13 CSS px however far the canvas is scaled down.
            const size = 13 * (canvas.width / (canvas.clientWidth || canvas.width));
            drawSlicedWord(context, 0, 0, canvas.width, canvas.height, rolloffHz, paletteFor(canvas), size);
        }
    });
    return figure;
}

function exampleSection() {
    const audio = element("audio", { id: "restored-example", preload: "none" });
    const status = element("p", { class: "fine-print", role: "status" }, "");
    const play = (source, button) => {
        const playing = !audio.paused && audio.dataset.source === source;
        audio.pause();
        for (const other of section.querySelectorAll("button")) {
            other.setAttribute("aria-pressed", "false");
        }
        if (playing) {
            status.textContent = "";
            return;
        }
        audio.dataset.source = source;
        audio.src = source;
        audio.onended = () => {
            button.setAttribute("aria-pressed", "false");
            status.textContent = "";
        };
        button.setAttribute("aria-pressed", "true");
        status.textContent = "Playing.";
        audio.play().catch(() => {
            button.setAttribute("aria-pressed", "false");
            status.textContent = "This browser could not play the example.";
        });
    };
    const button = (label, source) => {
        const control = element("button", { class: "button", type: "button", "aria-pressed": "false" }, label);
        control.addEventListener("click", () => play(source, control));
        return control;
    };
    const section = element(
        "section",
        { class: "example", "aria-labelledby": "example-heading" },
        element("h3", { id: "example-heading" }, "Hear what the band sounds like"),
        element(
            "p",
            {},
            "One line, through a simulated headset and then restored. It is not your recording.",
        ),
        element(
            "div",
            { class: "actions" },
            button("Through the headset", EXAMPLE.headset),
            button("Through Untunnel", EXAMPLE.restored),
        ),
        audio,
        status,
    );
    return section;
}

function resultCard(result, options = {}) {
    const comparison = options.comparison || null;
    const card = element("section", {
        id: "result",
        class: "card",
        "aria-labelledby": "result-heading",
    });
    // Until the visitor records, the result is a labelled sample and the first action is to record.
    card.append(
        result.sample
            ? element("h2", { id: "result-heading", tabindex: "-1" }, "A sample, until you record")
            : element("h2", { id: "result-heading", class: "verdict", tabindex: "-1" }, verdictFor(result)),
        result.sample ? element("p", { class: "fine-print" }, result.sample) : "",
        result.sample
            ? element(
                  "button",
                  { id: "start", class: "button button--primary", type: "button", onClick: requestMicrophone },
                  "Record your microphone",
              )
            : "",
        result.sample && !comparison ? element("p", { class: "verdict verdict--sample" }, `${verdictFor(result)}.`) : "",
        shelfFigure(
            result.rolloffHz,
            "Black is what the microphone sends, up to the dashed line, where the take falls 40 dB below its loudest. Red is the band Untunnel predicts above it, up to 24 kHz, printed from the main page's restored line.",
        ),
    );
    if (comparison) {
        card.append(
            element(
                "ul",
                { class: "comparison", "aria-label": "Measured rolloffs, 40 dB below the loudest part of each take" },
                element(
                    "li",
                    {},
                    element("span", {}, result.deviceName),
                    element("strong", {}, `${formatHertz(result.rolloffHz)} Hz`),
                ),
                element(
                    "li",
                    {},
                    element("span", {}, comparison.deviceName),
                    element("strong", {}, `${formatHertz(comparison.rolloffHz)} Hz`),
                ),
            ),
        );
    }
    if (options.note) {
        card.append(element("p", {}, options.note));
    }
    card.append(
        result.sample
            ? ""
            : element(
                  "div",
                  { class: "actions" },
                  element(
                      "button",
                      { id: "start", class: "button button--primary", type: "button", onClick: requestMicrophone },
                      "Record another microphone",
                  ),
                  element(
                      "button",
                      { id: "save", class: "button", type: "button", onClick: () => saveImage(result) },
                      "Save image",
                  ),
                  element(
                      "button",
                      { id: "compare", class: "button", type: "button", onClick: compareBuiltIn },
                      "Compare with the built-in microphone",
                  ),
              ),
        exampleSection(),
    );
    return card;
}

function renderResult(result, options = {}) {
    currentResult = result;
    api.lastRolloffHz = result.rolloffHz;
    setState(options.state || "result");
    panel().replaceChildren(resultCard(result, options));
    api.resultShownAt = performance.now();
    const heading = document.getElementById("result-heading");
    if (heading) {
        heading.focus();
    }
}

function renderCompared(current, comparison) {
    currentResult = current;
    api.lastRolloffHz = current.rolloffHz;
    setState("compared");
    panel().replaceChildren(resultCard(current, { comparison }));
    api.resultShownAt = performance.now();
}

async function requestMicrophone() {
    if (!supportsRecording()) {
        renderUnsupported();
        return;
    }
    if (workletFailure) {
        // Safari can refuse an audio context created before the first gesture; the click that
        // reaches here is a gesture, so give the worklet one more chance.
        workletFailure = null;
        audioContext = null;
    }
    renderRequesting();
    try {
        if (!audioContext) {
            preloadWorklet();
        }
        await workletPromise;
        if (workletFailure || !audioContext) {
            renderUnsupported(workletFailure);
            return;
        }
        const probe = await navigator.mediaDevices.getUserMedia(audioConstraints());
        probe.getTracks().forEach((track) => track.stop());
        const found = (await navigator.mediaDevices.enumerateDevices()).filter(
            (device) => device.kind === "audioinput",
        );
        if (found.length === 0) {
            renderError("No microphone was found. Connect one and try again.");
            return;
        }
        renderReady(found);
    } catch (error) {
        if (error && (error.name === "NotAllowedError" || error.name === "SecurityError")) {
            renderDenied();
        } else {
            renderError(messageOf(error));
        }
    }
}

async function takePrimary() {
    const select = document.getElementById("device");
    const option = select && select.selectedOptions[0];
    const deviceId = option ? option.value : "";
    const label = option ? option.textContent.trim() : "Microphone";
    const deviceName = label.replace(/^Default\s*[-–]\s*/i, "") || "Microphone";
    renderTaking(null);
    try {
        const result = await recordTake(deviceId, deviceName);
        if (!result) {
            return;
        }
        renderResult(result);
    } catch (error) {
        renderError(messageOf(error));
    }
}

async function compareBuiltIn() {
    if (!currentResult) {
        return;
    }
    const builtIn = devices.find(
        (device) =>
            device.deviceId !== currentResult.deviceId &&
            !/^(default|communications)$/i.test(device.deviceId) &&
            !/^(default|communications)(?:\s*[-–]|$)/i.test(device.label) &&
            /built[- ]?in|internal|macbook/i.test(device.label),
    );
    if (!builtIn) {
        renderResult(currentResult, {
            state: "compare",
            note: "No built-in microphone was found to compare with.",
        });
        return;
    }
    renderTaking(null);
    try {
        const comparison = await recordTake(builtIn.deviceId, builtIn.label);
        if (!comparison) {
            return;
        }
        renderCompared(currentResult, comparison);
    } catch (error) {
        renderError(messageOf(error));
    }
}

function recordTake(deviceId, deviceName) {
    if (!audioContext || workletFailure) {
        return Promise.reject(new Error(workletFailure || "The audio worklet is not ready."));
    }
    return audioContext.resume().then(
        () =>
            new Promise((resolve, reject) => {
                navigator.mediaDevices
                    .getUserMedia(audioConstraints(deviceId))
                    .then((stream) => {
                        const sampleRate = audioContext.sampleRate;
                        const samples = new Float32Array(Math.ceil(TAKE_SECONDS * sampleRate));
                        let source;
                        let worklet;
                        try {
                            source = audioContext.createMediaStreamSource(stream);
                            worklet = new AudioWorkletNode(audioContext, WORKLET_NAME, {
                                numberOfInputs: 1,
                                numberOfOutputs: 1,
                                channelCount: 1,
                                channelCountMode: "explicit",
                            });
                        } catch (error) {
                            stream.getTracks().forEach((track) => track.stop());
                            throw error;
                        }
                        const sink = audioContext.createGain();
                        sink.gain.value = 0;
                        source.connect(worklet);
                        worklet.connect(sink);
                        sink.connect(audioContext.destination);
                        let written = 0;
                        let finished = false;
                        let timer = null;
                        const release = () => {
                            clearTimeout(timer);
                            source.disconnect();
                            worklet.disconnect();
                            sink.disconnect();
                            stream.getTracks().forEach((track) => track.stop());
                        };
                        const finish = () => {
                            if (finished) {
                                return;
                            }
                            finished = true;
                            api.takeEndedAt = performance.now();
                            release();
                            try {
                                resolve({
                                    deviceId,
                                    deviceName: deviceName || "Microphone",
                                    rolloffHz: rolloff40dbHz(samples, sampleRate),
                                    sampleRateHz: sampleRate,
                                });
                            } catch (error) {
                                reject(error);
                            }
                        };
                        worklet.port.onmessage = (event) => {
                            const chunk = event.data;
                            if (finished || !(chunk instanceof Float32Array)) {
                                return;
                            }
                            const room = samples.length - written;
                            const count = Math.min(chunk.length, room);
                            samples.set(chunk.subarray(0, count), written);
                            written += count;
                            const progress = panel().querySelector("progress");
                            if (progress) progress.value = written / sampleRate;
                            if (written >= samples.length) {
                                finish();
                            }
                        };
                        worklet.port.onmessageerror = () => {
                            if (finished) {
                                return;
                            }
                            finished = true;
                            release();
                            reject(new Error("The recording stream failed."));
                        };
                        timer = setTimeout(finish, TAKE_SECONDS * 1000 + 50);
                    })
                    .catch(reject);
            }),
    );
}

function preloadWorklet() {
    if (audioContext) {
        api.ready = true;
        return;
    }
    if (!supportsRecording()) {
        api.ready = true;
        return;
    }
    try {
        audioContext = new AudioContext();
    } catch (error) {
        workletFailure = messageOf(error);
        api.ready = true;
        return;
    }
    workletPromise = audioContext.audioWorklet
        .addModule(WORKLET_URL)
        .then(() => {
            api.ready = true;
        })
        .catch((error) => {
            workletFailure = messageOf(error);
            api.ready = true;
        });
}

function paletteFor(node) {
    const styles = getComputedStyle(node);
    return {
        ground: styles.getPropertyValue("--color-bg").trim() || "#fbfbf8",
        ink: styles.getPropertyValue("--color-text").trim() || "#121212",
        muted: styles.getPropertyValue("--color-muted").trim() || "#4f4f4b",
        accent: styles.getPropertyValue("--color-accent").trim() || "#d02a19",
        face: styles.fontFamily,
    };
}

// The main page's lettering and halftone, for its STOP (stop.js): each letter mostly as wide as
// it was said and partly its natural width, and red dots on one 45-degree screen sized by the
// restored take's spectrum under them, inside a solid red rim that fills any stem too thin for
// two cells. These match site/score.js. Coverage is the share of a cell the main page's
// smallest, largest and dense dots fill.
const LETTERS = { timeShare: 0.7, minNatural: 0.8, maxStretch: 1.6 };
const HALFTONE = { cellsPerCap: 26, stemCells: 2, smallest: 0.16, largest: 0.36, dense: 0.85, denseFrom: 0.7, rim: 2 };

const stopSpectrum = Uint8Array.from(atob(STOP.spectrum), (character) => character.charCodeAt(0));

// The restored band's loudness at a time and frequency, blended over two frames either side.
function loudness(time, hertz) {
    const bin = Math.min(STOP.bins - 1, Math.floor((hertz / STOP.top_hz) * STOP.bins));
    const frame = Math.floor(time / (STOP.hop_ms / 1000)) - STOP.first_frame;
    let sum = 0;
    for (const [offset, weight] of [[-2, 1], [-1, 2], [0, 3], [1, 2], [2, 1]]) {
        const row = Math.min(STOP.frames - 1, Math.max(0, frame + offset));
        sum += weight * stopSpectrum[row * STOP.bins + bin];
    }
    return sum / 9 / 255;
}

function letterBoxes(left, right, naturalWidths) {
    const span = STOP.end - STOP.start;
    const natural = naturalWidths.reduce((sum, width) => sum + width, 0);
    const shares = STOP.letters.map(([, start, end], index) =>
        Math.max(
            LETTERS.timeShare * ((end - start) / span) + (1 - LETTERS.timeShare) * (naturalWidths[index] / natural),
            LETTERS.minNatural * (naturalWidths[index] / natural),
        ),
    );
    const total = shares.reduce((sum, share) => sum + share, 0);
    let x = left;
    return STOP.letters.map(([letter], index) => {
        const box = { letter, x0: x, x1: x + (shares[index] / total) * (right - left), natural: naturalWidths[index] };
        x = box.x1;
        return box;
    });
}

function printPrediction(context, draw, area, word, cell, colour) {
    const { left, top, width, height, baseline, capHeight } = area;
    const step = cell / Math.SQRT2;
    const blank = () => {
        const canvas = document.createElement("canvas");
        canvas.width = context.canvas.width;
        canvas.height = context.canvas.height;
        return canvas;
    };
    // The letters drawn once, so each layer keeps only what falls inside any of them.
    const mask = blank();
    draw(mask.getContext("2d"), "fill");
    const layer = (paint) => {
        const canvas = blank();
        const ink = canvas.getContext("2d");
        ink.fillStyle = colour;
        ink.strokeStyle = colour;
        paint(ink);
        ink.globalCompositeOperation = "destination-in";
        ink.drawImage(mask, 0, 0);
        return canvas;
    };
    const dots = layer((ink) => {
        ink.beginPath();
        // The screen's cell centres, rotated 45 degrees: rows half a diagonal apart, every other
        // row offset by half a step. Each dot grows with the band's loudness there, up to just
        // short of touching; the loudest cells print solid.
        for (let row = 0, y = top; y < top + height + step; row += 1, y += step) {
            const hertz = ((baseline - y) / capHeight) * STOP.top_hz;
            for (let x = left + (row % 2 ? step : 0); x < left + width + step; x += 2 * step) {
                const time = word.start + ((x - word.left) / (word.right - word.left)) * (STOP.end - STOP.start);
                const m = loudness(time, hertz);
                const coverage =
                    m >= HALFTONE.denseFrom
                        ? HALFTONE.dense
                        : HALFTONE.smallest + ((HALFTONE.largest - HALFTONE.smallest) * m) / HALFTONE.denseFrom;
                const radius = Math.sqrt(coverage / Math.PI) * cell;
                ink.moveTo(x + radius, y);
                ink.arc(x, y, radius, 0, 2 * Math.PI);
            }
        }
        ink.fill();
    });
    const rim = layer((ink) => draw(ink, "stroke"));
    for (const canvas of [dots, rim]) {
        context.drawImage(canvas, left, top, width, height, left, top, width, height);
    }
}

// The main page's STOP set tall, letter height 0 to 24 kHz, in ink up to the microphone's top
// and in the main page's red halftone above it, where Untunnel predicts the rest. The scale sits
// in a left column, as on the main page, with the measured top marked at the dashed line.
function drawSlicedWord(context, left, top, width, height, rolloffHz, colors, labelSize) {
    const size = Math.round(labelSize);
    context.save();
    context.font = `400 ${size}px ${colors.face}`;
    // The measured top, in the unit the script reported it: a whole kHz for the headset's cut.
    const cutLabel = rolloffHz % 1000 === 0 ? `${formatKhz(rolloffHz)} kHz` : `${formatHertz(rolloffHz)} Hz`;
    // The scale column is as wide as its widest mark, with a gap, so the marks never reach the word.
    const scaleWidth = context.measureText("24 kHz").width;
    context.font = `600 ${size}px ${colors.face}`;
    const widest = Math.max(scaleWidth, context.measureText(cutLabel).width);
    const labelRoom = Math.max(Math.round(width * 0.12), Math.ceil(widest + size));
    const capHeight = height * 0.86;
    const baseline = top + height * 0.93;
    const wordLeft = left + labelRoom;
    const wordRight = left + width;
    context.font = '100px "League Gothic"';
    const capRatio = context.measureText("H").actualBoundingBoxAscent / 100;
    const stem = context.measureText("I");
    const stemRatio = (stem.actualBoundingBoxLeft + stem.actualBoundingBoxRight) / 100;
    const wordFont = `${capHeight / capRatio}px "League Gothic"`;
    context.font = wordFont;
    const boxes = letterBoxes(
        wordLeft,
        wordRight,
        STOP.letters.map(([letter]) => context.measureText(letter).width),
    ).map((box) => {
        const room = box.x1 - box.x0 - 2;
        const stretch = Math.min(room / box.natural, LETTERS.maxStretch);
        return { ...box, stretch, x: box.x0 + (room - box.natural * stretch) / 2 };
    });
    const cell = capHeight / HALFTONE.cellsPerCap;
    const rimDepth = HALFTONE.rim * (capHeight / 200);
    for (const box of boxes) {
        const stemWidth = (stemRatio * capHeight * box.stretch) / capRatio;
        box.rim = stemWidth < HALFTONE.stemCells * cell ? Math.max(rimDepth, stemWidth / 2 + rimDepth / 2) : rimDepth;
    }
    const cutY = baseline - capHeight * Math.min(1, rolloffHz / AXIS_UPPER_HZ);
    const word = (target, mode) => {
        target.font = wordFont;
        for (const box of boxes) {
            target.setTransform(box.stretch, 0, 0, 1, box.x, baseline);
            // The stroke is drawn in the letter's squeezed space, so its width is unsqueezed for the stems.
            target.lineWidth = (2 * box.rim) / box.stretch;
            target[mode === "stroke" ? "strokeText" : "fillText"](box.letter, 0, 0);
        }
        target.setTransform(1, 0, 0, 1, 0, 0);
    };
    context.save();
    context.beginPath();
    context.rect(left, cutY, width, baseline - cutY + height);
    context.clip();
    context.fillStyle = colors.ink;
    word(context, "fill");
    context.restore();
    printPrediction(
        context,
        word,
        { left: wordLeft, top, width: width - labelRoom, height: cutY - top, baseline, capHeight },
        { left: wordLeft, right: wordRight, start: STOP.start },
        cell,
        colors.accent,
    );
    // One CSS pixel at any scale: the label size is 13 CSS px in canvas pixels.
    context.lineWidth = Math.max(1, size / 13);
    context.setLineDash([6, 5]);
    context.strokeStyle = colors.ink;
    context.beginPath();
    context.moveTo(wordLeft - labelRoom * 0.08, cutY);
    context.lineTo(wordRight, cutY);
    context.stroke();
    context.setLineDash([]);
    // The 24 kHz hairline, so the band above the cut reads as measured, as on the main page.
    context.strokeStyle = colors.muted;
    context.beginPath();
    context.moveTo(left, baseline - capHeight);
    context.lineTo(wordRight, baseline - capHeight);
    context.stroke();
    const labelX = wordLeft - size * 0.6;
    context.textAlign = "right";
    context.textBaseline = "middle";
    context.fillStyle = colors.ink;
    context.font = `600 ${size}px ${colors.face}`;
    context.fillText(cutLabel, labelX, Math.max(baseline - capHeight + size * 1.8, Math.min(cutY, baseline - size * 2)));
    context.fillStyle = colors.muted;
    context.font = `400 ${size}px ${colors.face}`;
    context.textBaseline = "top";
    context.fillText("24 kHz", labelX, baseline - capHeight + size * 0.3);
    context.textBaseline = "bottom";
    context.fillText("0", labelX, baseline);
    context.restore();
}

function drawCard(context, result, width, height) {
    const colors = {
        ground: "#fbfbf8",
        ink: "#121212",
        muted: "#4f4f4b",
        accent: "#d02a19",
        face: '"Source Serif 4", Georgia, serif',
    };
    context.fillStyle = colors.ground;
    context.fillRect(0, 0, width, height);
    context.fillStyle = colors.ink;
    context.font = '400 44px "League Gothic"';
    context.fillText("CALL MICROPHONE CHECK", 72, 96);
    context.font = '400 34px "Source Serif 4", Georgia, serif';
    const words = verdictFor(result).split(/\s+/);
    const lines = [];
    let line = "";
    for (const word of words) {
        const next = line ? `${line} ${word}` : word;
        if (line && context.measureText(next).width > width - 144) {
            lines.push(line);
            line = word;
        } else {
            line = next;
        }
    }
    lines.push(line);
    lines.forEach((text, index) => context.fillText(text, 72, 150 + index * 38));
    const top = 170 + lines.length * 38;
    drawSlicedWord(context, 72, top, width - 144, Math.max(120, 520 - top), result.rolloffHz, colors, 20);
    context.fillStyle = colors.muted;
    context.font = '400 22px "Source Serif 4", Georgia, serif';
    context.fillText(
        "Rolloff measured in this browser. Red shows an example spectrum, not your restored audio.",
        72,
        574,
        width - 144,
    );
    context.fillStyle = colors.ink;
    context.font = '400 30px "League Gothic"';
    context.fillText("UNTUNNEL", 72, 612);
}

function saveImage(result) {
    const canvas = document.createElement("canvas");
    canvas.width = SAVE_WIDTH;
    canvas.height = SAVE_HEIGHT;
    const context = canvas.getContext("2d");
    if (!context) {
        renderError("The image could not be drawn in this browser.");
        return;
    }
    drawCard(context, result, SAVE_WIDTH, SAVE_HEIGHT);
    canvas.toBlob((blob) => {
        if (!blob) {
            renderError("The image could not be saved in this browser.");
            return;
        }
        const link = document.createElement("a");
        const slug = result.deviceName.toLowerCase().replace(/[^a-z0-9]+/g, "-");
        const downloadUrl = URL.createObjectURL(blob);
        link.href = downloadUrl;
        link.download = `call-mic-${slug || "result"}.png`;
        document.body.append(link);
        link.click();
        link.remove();
        setTimeout(() => URL.revokeObjectURL(downloadUrl), 1000);
    }, "image/png");
}

function renderFixture(requested) {
    const name = STATE_ALIASES[requested] || requested;
    const fixture = FIXTURES[name];
    if (!fixture) {
        renderIdle();
        return;
    }
    switch (name) {
        case "idle":
            renderIdle();
            break;
        case "requesting":
            renderRequesting();
            break;
        case "denied":
            renderDenied(fixture.message);
            break;
        case "unsupported":
            renderUnsupported(fixture.message);
            break;
        case "ready":
            renderReady(fixture.devices);
            break;
        case "taking":
            renderTaking(fixture.secondsLeft);
            break;
        case "result":
            renderResult(fixture);
            break;
        case "compare":
            renderResult(fixture, {
                state: "compare",
                note: "Record the built-in microphone next to see the difference.",
            });
            break;
        case "comparing":
            renderResult(fixture, {
                state: "comparing",
                note: "Recording the built-in microphone…",
                secondsLeft: fixture.secondsLeft,
            });
            break;
        case "compared":
            renderCompared(fixture.current, fixture.comparison);
            break;
        case "error":
            renderError(fixture.message);
            break;
        default:
            renderIdle();
    }
    if (requested !== name) {
        api.state = requested;
        const main = document.getElementById("main");
        if (main) {
            main.dataset.state = requested;
        }
    }
}

function stateFromHash() {
    const match = /^#state=([a-z_-]+)$/.exec(location.hash);
    return match ? match[1].replaceAll("_", "-") : null;
}

function renderFromHash() {
    const state = stateFromHash();
    if (state) {
        renderFixture(state);
        api.ready = true;
        return;
    }
    renderIdle();
    preloadWorklet();
}

function start() {
    api.ready = false;
    api.state = "loading";
    // The result draws in League Gothic; fetch it now so nothing loads once a take starts.
    document.fonts.load('100px "League Gothic"');
    renderFromHash();
    window.addEventListener("hashchange", renderFromHash);
}

globalThis.MIC_TEST = api;
if (typeof module === "object" && module.exports) {
    module.exports = api;
}

if (typeof document !== "undefined") {
    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", start);
    } else {
        start();
    }
}
