import os
import shutil
import subprocess
import wave
from pathlib import Path

import numpy as np


def test_ffmpeg_msbc_round_trip(tmp_path: Path) -> None:
    """The local codec preserves a mono 16 kHz tone through real mSBC frames."""
    ffmpeg = shutil.which("ffmpeg")
    assert ffmpeg is not None, "Install the pinned ffmpeg before running codec tests."
    sample_rate = 16_000
    samples_per_frame = 120
    frame_bytes = 57
    frame_count = 160
    sample_count = frame_count * samples_per_frame
    time_seconds = np.arange(sample_count) / sample_rate
    tone = 0.25 * np.sin(2 * np.pi * 997 * time_seconds)
    pcm = np.round(tone * 32767).astype("<i2")
    original = tmp_path / "tone.wav"
    encoded = tmp_path / "tone.sbc"
    decoded = tmp_path / "decoded.wav"
    with wave.open(str(original), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(pcm.tobytes())
    subprocess.run(
        [
            "/bin/sh",
            "-c",
            (
                'exec "$UNTUNNEL_FFMPEG" -v error -nostdin -i "$UNTUNNEL_INPUT" '
                '-c:a sbc -msbc 1 -f sbc "$UNTUNNEL_OUTPUT"'
            ),
        ],
        env={
            **os.environ,
            "UNTUNNEL_FFMPEG": ffmpeg,
            "UNTUNNEL_INPUT": str(original),
            "UNTUNNEL_OUTPUT": str(encoded),
        },
        check=True,
        capture_output=True,
    )
    frames = encoded.read_bytes()
    assert len(frames) == frame_count * frame_bytes
    assert all(frames[index] == 0xAD for index in range(0, len(frames), frame_bytes))
    subprocess.run(
        [
            "/bin/sh",
            "-c",
            (
                'exec "$UNTUNNEL_FFMPEG" -v error -nostdin -f sbc -i "$UNTUNNEL_INPUT" '
                '-c:a pcm_s16le "$UNTUNNEL_OUTPUT"'
            ),
        ],
        env={
            **os.environ,
            "UNTUNNEL_FFMPEG": ffmpeg,
            "UNTUNNEL_INPUT": str(encoded),
            "UNTUNNEL_OUTPUT": str(decoded),
        },
        check=True,
        capture_output=True,
    )
    with wave.open(str(decoded), "rb") as restored:
        assert restored.getframerate() == sample_rate
        assert restored.getnchannels() == 1
        assert restored.getnframes() == sample_count
        output_pcm = np.frombuffer(restored.readframes(sample_count), dtype="<i2")
    # SBC's filter bank adds delay; compare the steady-state signal after alignment.
    correlation = np.correlate(output_pcm.astype(float), pcm.astype(float), mode="full")
    delay = int(np.argmax(correlation)) - sample_count + 1
    assert 0 <= delay < samples_per_frame * 2
    reference = pcm[samples_per_frame : sample_count - samples_per_frame].astype(float)
    actual = output_pcm[
        samples_per_frame + delay : sample_count - samples_per_frame + delay
    ].astype(float)
    snr_db = 10 * np.log10(np.sum(reference**2) / np.sum((actual - reference) ** 2))
    assert snr_db > 20, f"mSBC tone round-trip SNR was {snr_db:.2f} dB"
