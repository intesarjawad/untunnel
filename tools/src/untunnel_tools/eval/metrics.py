"""Metrics against the clean reference, and the backends that need model weights.

LSD is computed here at the full 48 kHz rate. Every other metric resamples first (PESQ-WB,
ECAPA, Whisper and DNSMOS to 16 kHz, ESTOI to 10 kHz), so only LSD sees energy above 8 kHz.
The packages and weights behind PESQ, ESTOI, ECAPA, WER and DNSMOS load on first use so the
rest of the module works without the optional `eval` dependency group.
"""

import importlib
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, cast

import numpy as np
from numpy.typing import NDArray

from untunnel_tools import paths
from untunnel_tools.eval.simulate_hfp import resample
from untunnel_tools.measure import FloatArray

WINDOW_SAMPLES = 1024
OVERLAP_SAMPLES = 768
LSD_POWER_FLOOR = 1e-10
HIGH_BAND_HZ = 8_000
MAX_ALIGN_LAG_SECONDS = 0.1
WIDEBAND_RATE = 16_000
DNSMOS_WINDOW_SECONDS = 9.01
DNSMOS_HOP_SECONDS = 1.0
# Microsoft's polynomial fit from raw model output to P.835 scores, in the order
# overall, signal, background (DNS-Challenge dnsmos_local.py, non-personalised).
DNSMOS_OVRL_FIT = (-0.06766283, 1.11546468, 0.04602535)
DNSMOS_SIG_FIT = (-0.08397278, 1.22083953, 0.0052439)
DNSMOS_BAK_FIT = (-0.13166888, 1.60915514, -0.39604546)

type ComplexArray = NDArray[np.complex128]
type SampleArray = NDArray[np.float32 | np.float64]
type Embedder = Callable[[FloatArray], FloatArray]
type Transcriber = Callable[[FloatArray], str]


@dataclass(frozen=True)
class MetricInfo:
    """How a metric reads and whether it can see above 8 kHz."""

    key: str
    label: str
    lower_is_better: bool
    sees_above_8khz: bool


METRICS = (
    MetricInfo("lsd_full", "LSD, full band (dB)", lower_is_better=True, sees_above_8khz=True),
    MetricInfo("lsd_high", "LSD above 8 kHz (dB)", lower_is_better=True, sees_above_8khz=True),
    MetricInfo("pesq_wb", "PESQ-WB", lower_is_better=False, sees_above_8khz=False),
    MetricInfo("estoi", "ESTOI", lower_is_better=False, sees_above_8khz=False),
    MetricInfo("ecapa", "ECAPA cosine similarity", lower_is_better=False, sees_above_8khz=False),
    MetricInfo("wer", "WER", lower_is_better=True, sees_above_8khz=False),
    MetricInfo("dnsmos_ovrl", "DNSMOS OVRL", lower_is_better=False, sees_above_8khz=False),
    MetricInfo("dnsmos_sig", "DNSMOS SIG", lower_is_better=False, sees_above_8khz=False),
    MetricInfo("dnsmos_bak", "DNSMOS BAK", lower_is_better=False, sees_above_8khz=False),
)


class _Signal(Protocol):
    """The scipy.signal calls used here, typed because scipy ships partial annotations."""

    def stft(
        self, x: FloatArray, *, fs: int, nperseg: int, noverlap: int
    ) -> tuple[FloatArray, FloatArray, ComplexArray]: ...

    def correlate(
        self, in1: FloatArray, in2: FloatArray, *, mode: str, method: str
    ) -> FloatArray: ...


def _signal() -> _Signal:
    return cast("_Signal", importlib.import_module("scipy.signal"))


def stft(samples: FloatArray, sample_rate: int) -> tuple[FloatArray, ComplexArray]:
    """Return bin frequencies and a Hann-windowed spectrogram with 75 % overlap."""
    frequencies, _, spectrum = _signal().stft(
        samples, fs=sample_rate, nperseg=WINDOW_SAMPLES, noverlap=OVERLAP_SAMPLES
    )
    return frequencies, spectrum


class DnsmosSession(Protocol):
    """The call this module makes on an onnxruntime inference session."""

    def run(
        self, output_names: None, input_feed: Mapping[str, SampleArray]
    ) -> Sequence[FloatArray]:
        """Return the raw signal, background and overall scores for one window."""
        ...


@dataclass(frozen=True)
class Backends:
    """The model-backed parts of scoring, supplied by the caller."""

    embed: Embedder
    transcribe: Transcriber
    dnsmos: DnsmosSession


def estimate_lag(reference: FloatArray, output: FloatArray, sample_rate: int) -> int:
    """Find the shift in samples at which `output` best matches `reference`, within 100 ms."""
    max_lag = round(MAX_ALIGN_LAG_SECONDS * sample_rate)
    correlation = _signal().correlate(output, reference, mode="full", method="fft")
    lags = np.arange(-(len(reference) - 1), len(output))
    window = np.abs(lags) <= max_lag
    return int(lags[window][np.argmax(correlation[window])])


def align(
    reference: FloatArray, output: FloatArray, sample_rate: int
) -> tuple[FloatArray, FloatArray]:
    """Remove the delay between a reference and a system output and trim both to one length."""
    lag = estimate_lag(reference, output, sample_rate)
    if lag > 0:
        output = output[lag:]
    else:
        reference = reference[-lag:]
    length = min(len(reference), len(output))
    return reference[:length], output[:length]


def to_reference_time(reference: FloatArray, output: FloatArray, sample_rate: int) -> FloatArray:
    """Shift an output onto the reference's timeline, padding or cutting to its length."""
    lag = estimate_lag(reference, output, sample_rate)
    shifted = output[lag:] if lag >= 0 else np.concatenate([np.zeros(-lag), output])
    fitted = np.zeros(len(reference))
    length = min(len(reference), len(shifted))
    fitted[:length] = shifted[:length]
    return fitted


def log_spectral_distance(
    reference: FloatArray, degraded: FloatArray, sample_rate: int, min_hz: float = 0.0
) -> float:
    """Mean over frames of the RMS dB difference between power spectra above `min_hz`."""
    frequencies, reference_spectrum = stft(reference, sample_rate)
    _, degraded_spectrum = stft(degraded, sample_rate)
    band = frequencies >= min_hz
    reference_power = np.abs(reference_spectrum[band]) ** 2 + LSD_POWER_FLOOR
    degraded_power = np.abs(degraded_spectrum[band]) ** 2 + LSD_POWER_FLOOR
    difference_db = 10 * np.log10(reference_power / degraded_power)
    return float(np.mean(np.sqrt(np.mean(difference_db**2, axis=0))))


def cosine_similarity(first: FloatArray, second: FloatArray) -> float:
    """Return the cosine of the angle between two vectors."""
    return float(np.dot(first, second) / (np.linalg.norm(first) * np.linalg.norm(second)))


def ecapa_similarity(
    reference: FloatArray, degraded: FloatArray, sample_rate: int, embed: Embedder
) -> float:
    """Cosine similarity of the two signals' speaker embeddings, taken at 16 kHz."""
    return cosine_similarity(
        embed(resample(reference, sample_rate, WIDEBAND_RATE)),
        embed(resample(degraded, sample_rate, WIDEBAND_RATE)),
    )


class _PesqModule(Protocol):
    def pesq(self, fs: int, ref: FloatArray, deg: FloatArray, mode: str) -> float: ...


class _StoiModule(Protocol):
    def stoi(self, x: FloatArray, y: FloatArray, fs_sig: int, *, extended: bool) -> float: ...


def pesq_wideband(reference: FloatArray, degraded: FloatArray, sample_rate: int) -> float:
    """PESQ P.862.2 wideband at 16 kHz; it scores repair below 8 kHz, not extension."""
    module = cast("_PesqModule", importlib.import_module("pesq"))
    return float(
        module.pesq(
            WIDEBAND_RATE,
            resample(reference, sample_rate, WIDEBAND_RATE),
            resample(degraded, sample_rate, WIDEBAND_RATE),
            "wb",
        )
    )


def estoi(reference: FloatArray, degraded: FloatArray, sample_rate: int) -> float:
    """Score extended short-time objective intelligibility; pystoi works at 10 kHz."""
    module = cast("_StoiModule", importlib.import_module("pystoi"))
    return float(module.stoi(reference, degraded, sample_rate, extended=True))


class _JiwerModule(Protocol):
    def Compose(self, transforms: Sequence[object]) -> object: ...  # noqa: N802
    def ToLowerCase(self) -> object: ...  # noqa: N802
    def RemovePunctuation(self) -> object: ...  # noqa: N802
    def RemoveMultipleSpaces(self) -> object: ...  # noqa: N802
    def Strip(self) -> object: ...  # noqa: N802
    def ReduceToListOfListOfWords(self) -> object: ...  # noqa: N802
    def wer(
        self,
        reference: str,
        hypothesis: str,
        reference_transform: object,
        hypothesis_transform: object,
    ) -> float: ...


def word_error_rate(reference_text: str, hypothesis_text: str) -> float:
    """Word error rate after lower-casing and removing punctuation, as jiwer normalises."""
    jiwer = cast("_JiwerModule", importlib.import_module("jiwer"))
    transform = jiwer.Compose(
        [
            jiwer.ToLowerCase(),
            jiwer.RemovePunctuation(),
            jiwer.RemoveMultipleSpaces(),
            jiwer.Strip(),
            jiwer.ReduceToListOfListOfWords(),
        ]
    )
    return float(jiwer.wer(reference_text, hypothesis_text, transform, transform))


def dnsmos_scores(
    samples: FloatArray, sample_rate: int, session: DnsmosSession
) -> dict[str, float]:
    """DNSMOS P.835 overall, signal and background, averaged over 9.01 s windows hopped by 1 s."""
    audio = resample(samples, sample_rate, WIDEBAND_RATE)
    window = round(DNSMOS_WINDOW_SECONDS * WIDEBAND_RATE)
    while len(audio) < window:
        audio = np.concatenate([audio, audio])
    hops = int(np.floor(len(audio) / WIDEBAND_RATE) - DNSMOS_WINDOW_SECONDS) + 1
    scores = np.zeros((hops, 3))
    for index in range(hops):
        start = round(index * DNSMOS_HOP_SECONDS * WIDEBAND_RATE)
        features = np.asarray(audio[start : start + window], dtype=np.float32)[np.newaxis, :]
        signal_raw, background_raw, overall_raw = np.asarray(
            session.run(None, {"input_1": features})[0]
        )[0]
        scores[index] = (
            np.polyval(DNSMOS_OVRL_FIT, overall_raw),
            np.polyval(DNSMOS_SIG_FIT, signal_raw),
            np.polyval(DNSMOS_BAK_FIT, background_raw),
        )
    overall, signal_score, background = scores.mean(axis=0)
    return {
        "dnsmos_ovrl": float(overall),
        "dnsmos_sig": float(signal_score),
        "dnsmos_bak": float(background),
    }


def score_output(
    reference: FloatArray,
    output: FloatArray,
    sample_rate: int,
    reference_text: str,
    backends: Backends,
) -> dict[str, float]:
    """Score one aligned output against its clean reference with every metric."""
    transcript = backends.transcribe(resample(output, sample_rate, WIDEBAND_RATE))
    return {
        "lsd_full": log_spectral_distance(reference, output, sample_rate),
        "lsd_high": log_spectral_distance(reference, output, sample_rate, HIGH_BAND_HZ),
        "pesq_wb": pesq_wideband(reference, output, sample_rate),
        "estoi": estoi(reference, output, sample_rate),
        "ecapa": ecapa_similarity(reference, output, sample_rate, backends.embed),
        "wer": word_error_rate(reference_text, transcript),
        **dnsmos_scores(output, sample_rate, backends.dnsmos),
    }


class _Tensor(Protocol):
    def squeeze(self) -> "_Tensor": ...
    def numpy(self) -> FloatArray: ...


class _Classifier(Protocol):
    def encode_batch(self, wavs: _Tensor) -> _Tensor: ...


class _EncoderClassifier(Protocol):
    def from_hparams(self, *, source: str, savedir: str) -> _Classifier: ...


class _TorchModule(Protocol):
    def from_numpy(self, array: SampleArray) -> _Tensor: ...


class _WhisperModule(Protocol):
    def transcribe(
        self, audio: SampleArray, *, path_or_hf_repo: str, language: str
    ) -> Mapping[str, object]: ...


class _OnnxModule(Protocol):
    def InferenceSession(  # noqa: N802
        self, path: str, *, providers: Sequence[str]
    ) -> DnsmosSession: ...


def load_embedder(directory: Path) -> Embedder:
    """Load the ECAPA-TDNN speaker encoder from a local SpeechBrain model directory."""
    speaker = importlib.import_module("speechbrain.inference.speaker")
    torch = cast("_TorchModule", importlib.import_module("torch"))
    encoder = cast("_EncoderClassifier", speaker.EncoderClassifier)
    classifier = encoder.from_hparams(source=str(directory), savedir=str(directory))

    def embed(samples: FloatArray) -> FloatArray:
        waveform = torch.from_numpy(samples.astype(np.float32)[np.newaxis, :])
        return np.asarray(classifier.encode_batch(waveform).squeeze().numpy(), dtype=np.float64)

    return embed


def load_transcriber(directory: Path) -> Transcriber:
    """Load Whisper large-v3-turbo from the pinned local MLX model directory."""
    whisper = cast("_WhisperModule", importlib.import_module("mlx_whisper"))

    def transcribe(samples: FloatArray) -> str:
        result = whisper.transcribe(
            samples.astype(np.float32), path_or_hf_repo=str(directory), language="en"
        )
        return str(result["text"])

    return transcribe


def load_dnsmos_session(model: Path) -> DnsmosSession:
    """Open the pinned DNSMOS P.835 model on the CPU."""
    onnx = cast("_OnnxModule", importlib.import_module("onnxruntime"))
    return onnx.InferenceSession(str(model), providers=["CPUExecutionProvider"])


# Shared with the other tool modules so `--print-root` works from each of them.
main = paths.main
repo_root = paths.repo_root

if __name__ == "__main__":
    main()
