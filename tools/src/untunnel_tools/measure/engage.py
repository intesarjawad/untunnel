"""Checks that the headset returns to its idle rate after a client lets go of the microphone.

The reader stands in for an application that opens the virtual microphone. PortAudio caches
device formats, so the headset's own rates are read from `system_profiler` instead; that is the
only source this check trusts for the rate comparison.
"""

import argparse
import importlib
import json
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, cast

from untunnel_tools.measure.cpu import CommandRunner, run_command
from untunnel_tools.paths import repo_root

SYSTEM_PROFILER = "/usr/sbin/system_profiler"
BLUETOOTH_TRANSPORT = "coreaudio_device_type_bluetooth"
VIRTUAL_MIC_MARKERS = ("Untunnel",)
HOLD_SECONDS = 3.0
RETURN_TIMEOUT_SECONDS = 5.0
POLL_SECONDS = 0.25

type JSONValue = dict[str, JSONValue] | list[JSONValue] | str | int | float | bool | None
type DeviceReader = Callable[[], Sequence[AudioDeviceReport]]


@dataclass(frozen=True)
class AudioDeviceReport:
    """One entry of `system_profiler`'s audio report, in one direction."""

    name: str
    transport: str
    sample_rate: int
    has_input: bool
    has_output: bool
    is_default_output: bool


@dataclass(frozen=True)
class Headset:
    """The headset and the output rate it uses while nothing holds its input."""

    name: str
    idle_output_rate: int


@dataclass(frozen=True)
class WaitPlan:
    """How long to wait for the release and how often to re-read the report."""

    timeout_seconds: float = RETURN_TIMEOUT_SECONDS
    poll_seconds: float = POLL_SECONDS
    clock: Callable[[], float] = time.monotonic
    sleep: Callable[[float], None] = time.sleep


@dataclass(frozen=True)
class RateReturn:
    """The last output rate read after a release and how long it took."""

    rate: int | None
    expected_rate: int
    elapsed_seconds: float

    @property
    def passed(self) -> bool:
        """Whether the headset had already returned to its idle rate."""
        return self.rate == self.expected_rate


class InputStream(Protocol):
    """The part of a sounddevice stream this check opens and closes."""

    def start(self) -> None:
        """Begin delivering audio."""
        ...

    def stop(self) -> None:
        """Stop delivering audio."""
        ...

    def close(self) -> None:
        """Release the device."""
        ...


class SoundDeviceModule(Protocol):
    """The calls this check makes on the lazily imported sounddevice module."""

    def query_devices(self) -> Sequence[Mapping[str, object]]:
        """List every device PortAudio reports."""
        ...

    def InputStream(  # noqa: N802
        self,
        *,
        device: int,
        channels: int,
    ) -> InputStream:
        """Open a readable stream on one device."""
        ...


def parse_audio_report(output: str) -> tuple[AudioDeviceReport, ...]:
    """Read the audio devices from `system_profiler SPAudioDataType -json` output."""
    report: JSONValue = json.loads(output)
    if not isinstance(report, dict):
        message = "the audio report is not a JSON object"
        raise TypeError(message)
    sections = report.get("SPAudioDataType")
    if not isinstance(sections, list) or not sections:
        message = "the audio report lists no devices"
        raise ValueError(message)

    devices: list[AudioDeviceReport] = []
    for section in sections:
        if not isinstance(section, dict):
            message = "an audio report section is not an object"
            raise TypeError(message)
        items = section.get("_items")
        if not isinstance(items, list):
            message = "an audio report section has no items"
            raise TypeError(message)
        for item in items:
            if not isinstance(item, dict):
                message = "an audio report item is not an object"
                raise TypeError(message)
            device = _device(item)
            if device is not None:
                devices.append(device)
    return tuple(devices)


def find_headset(devices: Sequence[AudioDeviceReport]) -> Headset:
    """Pick the Bluetooth headset and the output rate it uses while idle."""
    outputs = [
        device
        for device in devices
        if device.transport == BLUETOOTH_TRANSPORT and device.has_output
    ]
    names_with_input = {
        device.name
        for device in devices
        if device.transport == BLUETOOTH_TRANSPORT and device.has_input
    }
    preferred = [device for device in outputs if device.name in names_with_input] or outputs
    if not preferred:
        message = "no Bluetooth headset output was found in system_profiler"
        raise ValueError(message)
    defaults = [device for device in preferred if device.is_default_output]
    chosen = min(defaults or preferred, key=lambda device: device.name)
    return Headset(name=chosen.name, idle_output_rate=chosen.sample_rate)


def output_rate(devices: Sequence[AudioDeviceReport], name: str) -> int | None:
    """Return the Bluetooth output rate the headset reports now."""
    for device in devices:
        if device.name == name and device.transport == BLUETOOTH_TRANSPORT and device.has_output:
            return device.sample_rate
    return None


def wait_for_output_rate(
    read: DeviceReader,
    headset_name: str,
    expected_rate: int,
    plan: WaitPlan | None = None,
) -> RateReturn:
    """Poll `system_profiler` until the headset is back at its idle rate or time runs out."""
    plan = WaitPlan() if plan is None else plan
    started = plan.clock()
    while True:
        rate = output_rate(read(), headset_name)
        elapsed = plan.clock() - started
        if rate == expected_rate or elapsed >= plan.timeout_seconds:
            return RateReturn(rate=rate, expected_rate=expected_rate, elapsed_seconds=elapsed)
        plan.sleep(min(plan.poll_seconds, plan.timeout_seconds - elapsed))


def find_input_device(
    devices: Sequence[Mapping[str, object]],
    requested: str | None,
) -> int:
    """Find the input device to open by name, defaulting to the virtual microphone."""
    inputs: list[tuple[int, str]] = []
    for index, device in enumerate(devices):
        name = device.get("name")
        channels = device.get("max_input_channels")
        if not isinstance(name, str) or type(channels) is not int or channels <= 0:
            continue
        inputs.append((index, name))

    if requested is None:
        for index, name in inputs:
            if any(marker in name for marker in VIRTUAL_MIC_MARKERS):
                return index
        names = ", ".join(name for _, name in inputs) or "none"
        message = f"no virtual microphone device was found; pass --device (inputs: {names})"
        raise ValueError(message)

    for index, name in inputs:
        if name == requested:
            return index
    for index, name in inputs:
        if requested.lower() in name.lower():
            return index
    message = f"no input device matches {requested!r}"
    raise ValueError(message)


def read_audio_devices(runner: CommandRunner = run_command) -> tuple[AudioDeviceReport, ...]:
    """Read every audio device from the system report rather than PortAudio's cache."""
    result = runner([SYSTEM_PROFILER, "SPAudioDataType", "-json"])
    if result.returncode != 0:
        message = f"system_profiler exited with status {result.returncode}"
        raise RuntimeError(message)
    return parse_audio_report(result.stdout)


def load_sounddevice() -> object:
    """Import sounddevice only when a reader is actually opened."""
    try:
        return importlib.import_module("sounddevice")
    except ModuleNotFoundError as error:
        message = (
            "sounddevice is not installed; run "
            "`uv sync --project tools --locked --group eval` first"
        )
        raise RuntimeError(message) from error


def query_input_devices(module: object) -> Sequence[Mapping[str, object]]:
    """Return the devices PortAudio knows, for name lookup only."""
    return cast("SoundDeviceModule", module).query_devices()


def open_reader(device_index: int, hold_seconds: float) -> None:
    """Open and close one mono input stream, the way a calling application would."""
    module = cast("SoundDeviceModule", load_sounddevice())
    stream = module.InputStream(device=device_index, channels=1)
    stream.start()
    try:
        time.sleep(hold_seconds)
    finally:
        stream.stop()
        stream.close()


def run(arguments: list[str]) -> int:
    """Run the engagement check and return a process status."""
    parser = _parser()
    args = parser.parse_args(arguments)
    try:
        headset = find_headset(read_audio_devices())
        index = find_input_device(query_input_devices(load_sounddevice()), args.device)
        sys.stdout.write(f"Headset: {headset.name} at {headset.idle_output_rate} Hz idle\n")
        open_reader(index, HOLD_SECONDS)
        sys.stdout.write(
            f"Reader closed; waiting up to {RETURN_TIMEOUT_SECONDS:.0f} s for the release\n"
        )
        result = wait_for_output_rate(
            read_audio_devices,
            headset.name,
            headset.idle_output_rate,
        )
    except (OSError, RuntimeError, ValueError) as error:
        sys.stderr.write(f"engage: {error}\n")
        return 2

    if result.passed:
        sys.stdout.write(
            f"PASS: {headset.name} returned to {headset.idle_output_rate} Hz "
            f"after {result.elapsed_seconds:.2f} s\n"
        )
        return 0
    last_rate = "no output rate" if result.rate is None else f"{result.rate} Hz"
    sys.stderr.write(
        f"engage: {headset.name} stayed at {last_rate} for {result.elapsed_seconds:.2f} s\n"
    )
    return 1


def _device(item: dict[str, JSONValue]) -> AudioDeviceReport | None:
    """Convert one report item, skipping entries without a name and sample rate."""
    name = item.get("_name")
    rate = item.get("coreaudio_device_srate")
    transport = item.get("coreaudio_device_transport")
    if not isinstance(name, str) or not name or type(rate) is not int or rate <= 0:
        return None
    return AudioDeviceReport(
        name=name,
        transport=transport if isinstance(transport, str) else "",
        sample_rate=rate,
        has_input=_positive(item.get("coreaudio_device_input")),
        has_output=_positive(item.get("coreaudio_device_output")),
        is_default_output=item.get("coreaudio_default_audio_output_device") == "spaudio_yes",
    )


def _positive(value: JSONValue) -> bool:
    return type(value) is int and value > 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check that the headset returns to its idle rate after a client releases.",
    )
    parser.add_argument(
        "--device",
        help="input device name; defaults to the virtual microphone",
    )
    return parser


def main() -> None:
    """Run the engagement check from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
