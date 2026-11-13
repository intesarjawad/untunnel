import pytest

from untunnel_tools.measure import engage

AUDIO_REPORT = """
{
  "SPAudioDataType": [
    {
      "_name": "coreaudio_device",
      "_items": [
        {
          "_name": "AirPods Pro",
          "coreaudio_device_input": 1,
          "coreaudio_device_srate": 16000,
          "coreaudio_device_transport": "coreaudio_device_type_bluetooth"
        },
        {
          "_name": "AirPods Pro",
          "coreaudio_default_audio_output_device": "spaudio_yes",
          "coreaudio_device_output": 2,
          "coreaudio_device_srate": 48000,
          "coreaudio_device_transport": "coreaudio_device_type_bluetooth"
        },
        {
          "_name": "MacBook Pro Speakers",
          "coreaudio_device_output": 2,
          "coreaudio_device_srate": 48000,
          "coreaudio_device_transport": "coreaudio_device_type_builtin"
        }
      ]
    }
  ]
}
"""


def airpods(output_rate: int) -> tuple[engage.AudioDeviceReport, ...]:
    """Describe the headset's input and output entries as system_profiler reports them."""
    return (
        engage.AudioDeviceReport(
            name="AirPods Pro",
            transport=engage.BLUETOOTH_TRANSPORT,
            sample_rate=16_000,
            has_input=True,
            has_output=False,
            is_default_output=False,
        ),
        engage.AudioDeviceReport(
            name="AirPods Pro",
            transport=engage.BLUETOOTH_TRANSPORT,
            sample_rate=output_rate,
            has_input=False,
            has_output=True,
            is_default_output=True,
        ),
    )


class FakeClock:
    """Advance only when the code under test sleeps."""

    def __init__(self) -> None:
        self.now = 0.0

    def read(self) -> float:
        """Return the current fake time."""
        return self.now

    def sleep(self, seconds: float) -> None:
        """Advance the fake time by the requested pause."""
        self.now += seconds


class FakeSoundDevice:
    """Stand in for the lazily imported sounddevice module."""

    def query_devices(self) -> list[dict[str, object]]:
        """List the app's virtual microphone as the only input."""
        return [{"name": "Untunnel Microphone", "max_input_channels": 1}]


def test_parse_audio_report_reads_each_direction_rate() -> None:
    """The headset reports 16 kHz for input and 48 kHz for output while idle."""
    devices = engage.parse_audio_report(AUDIO_REPORT)

    assert len(devices) == 3
    assert devices[0].sample_rate == 16_000
    assert devices[0].has_input
    assert devices[1].sample_rate == 48_000
    assert devices[1].has_output


def test_the_default_bluetooth_output_is_the_idle_headset_rate() -> None:
    """The rate comes from the reported output entry, not the input entry."""
    headset = engage.find_headset(engage.parse_audio_report(AUDIO_REPORT))

    assert headset == engage.Headset(name="AirPods Pro", idle_output_rate=48_000)


def test_a_headset_must_have_a_bluetooth_output() -> None:
    """Built-in speakers cannot stand in for the headset."""
    devices = [
        engage.AudioDeviceReport(
            name="MacBook Pro Speakers",
            transport="coreaudio_device_type_builtin",
            sample_rate=48_000,
            has_input=False,
            has_output=True,
            is_default_output=True,
        )
    ]

    with pytest.raises(ValueError, match="Bluetooth"):
        engage.find_headset(devices)


def test_output_rate_reports_the_headset_and_ignores_other_devices() -> None:
    """Only the named Bluetooth output contributes a rate."""
    devices = airpods(24_000)

    assert engage.output_rate(devices, "AirPods Pro") == 24_000
    assert engage.output_rate(devices, "MacBook Pro Speakers") is None


def test_wait_passes_when_the_rate_returns_inside_the_timeout() -> None:
    """The third report is the first one back at the idle rate."""
    rates = iter([24_000, 24_000, 48_000])
    clock = FakeClock()

    def read() -> tuple[engage.AudioDeviceReport, ...]:
        return airpods(next(rates))

    result = engage.wait_for_output_rate(
        read,
        "AirPods Pro",
        48_000,
        plan=engage.WaitPlan(clock=clock.read, sleep=clock.sleep),
    )

    assert result.passed
    assert result.rate == 48_000
    assert result.elapsed_seconds == pytest.approx(0.5)


def test_wait_fails_when_the_rate_stays_low() -> None:
    """A headset that never returns to its idle rate fails at the five-second limit."""
    clock = FakeClock()

    def read() -> tuple[engage.AudioDeviceReport, ...]:
        return airpods(24_000)

    result = engage.wait_for_output_rate(
        read,
        "AirPods Pro",
        48_000,
        plan=engage.WaitPlan(clock=clock.read, sleep=clock.sleep),
    )

    assert not result.passed
    assert result.rate == 24_000
    assert result.elapsed_seconds == pytest.approx(5.0)


def test_find_input_device_defaults_to_the_virtual_microphone() -> None:
    """The reader opens the app's own input without the caller naming it."""
    devices = [
        {"name": "MacBook Pro Microphone", "max_input_channels": 1},
        {"name": "Untunnel Microphone", "max_input_channels": 1},
    ]

    assert engage.find_input_device(devices, None) == 1


def test_find_input_device_matches_a_requested_name() -> None:
    """A partial name selects the device a hardware check was pointed at."""
    devices = [{"name": "BlackHole 2ch", "max_input_channels": 2}]

    assert engage.find_input_device(devices, "blackhole") == 0


def test_find_input_device_rejects_an_unknown_name() -> None:
    """A missing device fails with the requested name rather than opening another one."""
    with pytest.raises(ValueError, match="BlackHole"):
        engage.find_input_device([], "BlackHole")


def test_run_prints_pass_after_the_reader_closes(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The command opens the virtual microphone, releases it and reports the return."""
    opened: list[int] = []

    def read() -> tuple[engage.AudioDeviceReport, ...]:
        return airpods(48_000)

    def open_reader(device_index: int, _hold_seconds: float) -> None:
        opened.append(device_index)

    def load() -> object:
        return FakeSoundDevice()

    monkeypatch.setattr(engage, "read_audio_devices", read)
    monkeypatch.setattr(engage, "open_reader", open_reader)
    monkeypatch.setattr(engage, "load_sounddevice", load)

    status = engage.run([])

    assert status == 0
    assert opened == [0]
    assert "PASS" in capsys.readouterr().out


def test_run_reports_a_report_failure(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A broken system report is a tool error, not a failed return."""

    def read() -> tuple[engage.AudioDeviceReport, ...]:
        message = "system_profiler exited with status 1"
        raise RuntimeError(message)

    monkeypatch.setattr(engage, "read_audio_devices", read)

    status = engage.run([])

    assert status == 2
    assert "engage:" in capsys.readouterr().err


def test_parse_audio_report_rejects_a_missing_section() -> None:
    """Wrong JSON shapes fail at the report boundary."""
    with pytest.raises(ValueError, match="no devices"):
        engage.parse_audio_report('{"SPAudioDataType": []}')
