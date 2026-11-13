import sys

import numpy as np
import pytest

from untunnel_tools.eval.baselines import (
    AUTO_TIER,
    command_system,
    default_systems,
    run_command_system,
    tier_key,
    upsample_input,
)
from untunnel_tools.eval.simulate_hfp import CONDITIONS, REFERENCE_RATE
from untunnel_tools.measure import FloatArray

COPY = ("/bin/cp", "{input}", "{output}")


def tone(sample_rate: int) -> FloatArray:
    """Return one second of a 1 kHz tone."""
    return np.asarray(
        0.25 * np.sin(2 * np.pi * 1_000 * np.arange(sample_rate) / sample_rate), dtype=np.float64
    )


def test_a_copying_command_returns_its_input_at_48_khz() -> None:
    """A program that writes its input back yields the same tone, resampled to 48 kHz."""
    restored = run_command_system(COPY, tone(16_000), 16_000)
    assert abs(len(restored) - REFERENCE_RATE) < 100
    assert np.allclose(restored[1_000:-1_000], tone(REFERENCE_RATE)[1_000:-1_000], atol=1e-3)


def test_output_directory_placeholder_names_where_the_result_goes() -> None:
    """A program that takes an output folder, as deep-filter does, is found by file name."""
    template = ("/bin/cp", "{input}", "{output_directory}")
    restored = run_command_system(template, tone(REFERENCE_RATE), REFERENCE_RATE)
    assert np.allclose(restored, tone(REFERENCE_RATE), atol=1e-4)


def test_tier_placeholder_reaches_the_command() -> None:
    """The tier string is passed through, so a program can refuse an unknown one."""
    template = (
        "/bin/sh",
        "-c",
        'test "$0" = 48000:8:2 && cp "$1" "$2"',
        "{tier}",
        "{input}",
        "{output}",
    )
    run_command_system(template, tone(REFERENCE_RATE), REFERENCE_RATE, "48000:8:2")
    with pytest.raises(RuntimeError, match="exited 1"):
        run_command_system(template, tone(REFERENCE_RATE), REFERENCE_RATE, "24000:4:1")


def test_failing_command_reports_its_error() -> None:
    """A non-zero exit becomes an error naming the program and its message."""
    template = ("/bin/sh", "-c", "echo broken >&2; exit 3")
    with pytest.raises(RuntimeError, match=r"/bin/sh exited 3: broken"):
        run_command_system(template, tone(REFERENCE_RATE), REFERENCE_RATE)


def test_command_that_writes_nothing_is_an_error() -> None:
    """A program that exits cleanly without producing the file is not silently accepted."""
    with pytest.raises(FileNotFoundError, match=r"wrote no utterance\.wav"):
        run_command_system(("/usr/bin/true",), tone(REFERENCE_RATE), REFERENCE_RATE)


def test_command_system_feeds_the_rate_it_declares() -> None:
    """A system that wants 16 kHz receives the 8 kHz narrowband signal upsampled to it."""
    script = (
        "import sys, soundfile\n"
        "samples, rate = soundfile.read(sys.argv[1])\n"
        "assert rate == 16000, rate\n"
        "soundfile.write(sys.argv[2], samples, rate)\n"
    )
    template = (sys.executable, "-c", script, "{input}", "{output}")
    narrowband = next(condition for condition in CONDITIONS if condition.key == "mulaw")
    restored = command_system("ap-bwe", "AP-BWE", template, 16_000).process(tone(8_000), narrowband)
    assert abs(len(restored) - REFERENCE_RATE) < 100


def test_default_systems_name_every_compared_system() -> None:
    """The auto tier and each listed tier are separate systems beside the four baselines."""
    systems = default_systems(("48000:8:2",), {}, "48000:7:1")
    assert [system.key for system in systems] == [
        "input",
        "folding",
        tier_key(AUTO_TIER),
        "untunnel-48000-8-2",
        "offline",
        "ap-bwe",
        "deepfilternet3",
    ]


def test_input_system_only_upsamples() -> None:
    """The degraded input has the 48 kHz length of its 16 kHz source."""
    msbc = CONDITIONS[0]
    assert len(upsample_input(tone(16_000), msbc)) == REFERENCE_RATE


def test_auto_system_uses_the_measured_numeric_tier() -> None:
    """The auto label stays stable while the executable receives the measured tier."""
    template = (
        "/bin/sh",
        "-c",
        'test "$0" = 48000:7:1 && cp "$1" "$2"',
        "{tier}",
        "{input}",
        "{output}",
    )
    systems = default_systems((), {"untunnel": template}, "48000:7:1")
    auto = next(system for system in systems if system.key == "untunnel-auto")
    auto.process(tone(16_000), CONDITIONS[0])
