import time

import pytest

from untunnel_tools.measure import engage, reconnect

LOG_OUTPUT = """
[
  {
    "timestamp": "2026-11-06 18:00:01.250000-0800",
    "eventMessage": "input_device_lost"
  },
  {
    "timestamp": "2026-11-06 18:00:03.000000-0800",
    "eventMessage": "microphone_engine_started"
  },
  {
    "timestamp": "2026-11-06 18:00:05.500000-0800",
    "eventMessage": "input_device_restored"
  }
]
"""


def airpods_devices() -> tuple[engage.AudioDeviceReport, ...]:
    """Describe the headset and the virtual microphone as system_profiler reports them."""
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
            sample_rate=48_000,
            has_input=False,
            has_output=True,
            is_default_output=True,
        ),
        engage.AudioDeviceReport(
            name="Untunnel Microphone",
            transport="coreaudio_device_type_virtual",
            sample_rate=48_000,
            has_input=True,
            has_output=True,
            is_default_output=False,
        ),
    )


def recovery_events() -> tuple[reconnect.RecoveryEvent, ...]:
    """One loss and one return, five seconds apart."""
    return (
        reconnect.RecoveryEvent(message=reconnect.LOST_MESSAGE, timestamp=100.0),
        reconnect.RecoveryEvent(message=reconnect.RESTORED_MESSAGE, timestamp=105.0),
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


def test_parse_log_entries_keeps_only_the_recovery_events() -> None:
    """Other lines from the same subsystem are ignored and the rest is in time order."""
    events = reconnect.parse_log_entries(LOG_OUTPUT)

    assert [event.message for event in events] == [
        reconnect.LOST_MESSAGE,
        reconnect.RESTORED_MESSAGE,
    ]
    assert events[1].timestamp - events[0].timestamp == pytest.approx(4.25)


def test_parse_log_entries_rejects_a_non_list() -> None:
    """Wrong JSON shapes fail at the log boundary."""
    with pytest.raises(TypeError, match="list"):
        reconnect.parse_log_entries('{"eventMessage": "input_device_lost"}')


def test_parse_log_entries_rejects_an_unknown_timestamp() -> None:
    """A timestamp the tool cannot place fails instead of being dropped silently."""
    output = '[{"timestamp": "yesterday", "eventMessage": "input_device_lost"}]'

    with pytest.raises(ValueError, match="yesterday"):
        reconnect.parse_log_entries(output)


def test_a_virtual_microphone_is_recognized_by_either_name() -> None:
    """The spec's name and the app's own name both count as the virtual microphone."""
    assert reconnect.has_virtual_mic(airpods_devices())
    assert reconnect.has_virtual_mic(
        (
            engage.AudioDeviceReport(
                name="Untunnel Microphone",
                transport="coreaudio_device_type_virtual",
                sample_rate=48_000,
                has_input=True,
                has_output=True,
                is_default_output=False,
            ),
        )
    )
    assert not reconnect.has_virtual_mic(
        (
            engage.AudioDeviceReport(
                name="MacBook Pro Speakers",
                transport="coreaudio_device_type_builtin",
                sample_rate=48_000,
                has_input=False,
                has_output=True,
                is_default_output=True,
            ),
        )
    )


def test_headset_input_presence_follows_the_reported_input_entry() -> None:
    """Only the entry that offers input counts as the headset coming back."""
    devices = airpods_devices()

    assert reconnect.headset_input_present(devices, "AirPods Pro")
    assert not reconnect.headset_input_present(devices, "MacBook Pro Speakers")
    without_input = tuple(device for device in devices if not device.has_input)
    assert not reconnect.headset_input_present(without_input, "AirPods Pro")


def test_wait_for_event_returns_the_first_match() -> None:
    """The event arrives on the first poll, so no time passes."""
    plan = reconnect.WaitPlan(clock=lambda: 0.0, sleep=lambda _seconds: None)

    found = reconnect.wait_for_event(recovery_events, reconnect.RESTORED_MESSAGE, 0.0, plan)

    assert found == recovery_events()[1]


def test_wait_for_event_gives_up_at_the_limit() -> None:
    """A step the tester never performs ends at the timeout rather than hanging."""
    clock = FakeClock()
    plan = reconnect.WaitPlan(
        event_timeout_seconds=2.0,
        clock=clock.read,
        sleep=clock.sleep,
    )

    assert reconnect.wait_for_event(lambda: (), reconnect.LOST_MESSAGE, 0.0, plan) is None
    assert clock.now == pytest.approx(2.0)


def test_wait_for_resume_reports_when_the_input_entry_returns() -> None:
    """Two absent samples put the return two seconds after the request."""
    clock = FakeClock()
    plan = reconnect.WaitPlan(clock=clock.read, sleep=clock.sleep)
    absent = tuple(device for device in airpods_devices() if not device.has_input)
    reports = iter([absent, absent, airpods_devices()])

    elapsed = reconnect.wait_for_resume(
        "AirPods Pro",
        lambda: next(reports),
        plan,
    )

    assert elapsed == pytest.approx(2.0)


def test_wait_for_resume_fails_after_the_three_second_limit() -> None:
    """A headset that never returns fails the resumption check."""
    clock = FakeClock()
    plan = reconnect.WaitPlan(clock=clock.read, sleep=clock.sleep)
    absent = tuple(device for device in airpods_devices() if not device.has_input)

    assert reconnect.wait_for_resume("AirPods Pro", lambda: absent, plan) is None
    assert clock.now == pytest.approx(3.0)


def test_samples_are_taken_once_a_second() -> None:
    """A sample between two one-second marks is skipped."""
    clock = FakeClock()
    clock.now = 2.0
    plan = reconnect.WaitPlan(clock=clock.read, sleep=clock.sleep)
    sampler = reconnect.VirtualMicSamples(airpods_devices, plan)

    sampler.sample_if_due()
    clock.now = 2.5
    sampler.sample_if_due()
    clock.now = 3.0
    sampler.sample_if_due()

    assert sampler.present == (True, True)


def test_verify_passes_one_ordered_recovery_with_the_microphone_listed() -> None:
    """One loss, one return, a fast resumption and no missing samples."""
    report = reconnect.verify(recovery_events(), [True, True, True], 2.5)

    assert report.passed
    assert report.samples == 3


def test_verify_fails_a_slow_resumption() -> None:
    """Audio that comes back after three seconds misses the limit."""
    report = reconnect.verify(recovery_events(), [True], 3.5)

    assert not report.resumed_in_time
    assert not report.passed


def test_verify_fails_a_sample_without_the_virtual_microphone() -> None:
    """The virtual microphone must be listed at every sample."""
    report = reconnect.verify(recovery_events(), [True, False], 1.0)

    assert report.missing_samples == (1,)
    assert not report.passed


def test_verify_counts_a_repeated_log_line_once() -> None:
    """Polling the log returns the same lines more than once."""
    repeated = (recovery_events()[0], recovery_events()[0], recovery_events()[1])

    report = reconnect.verify(repeated, [True], 1.0)

    assert report.lost == 1
    assert report.passed


def test_verify_fails_two_losses() -> None:
    """Exactly one loss is the acceptance condition."""
    events = (
        reconnect.RecoveryEvent(message=reconnect.LOST_MESSAGE, timestamp=90.0),
        reconnect.RecoveryEvent(message=reconnect.LOST_MESSAGE, timestamp=100.0),
        reconnect.RecoveryEvent(message=reconnect.RESTORED_MESSAGE, timestamp=105.0),
    )

    report = reconnect.verify(events, [True], 1.0)

    assert report.lost == 2
    assert not report.passed


def test_verify_fails_a_return_before_the_loss() -> None:
    """The two events have to belong to one reconnect in order."""
    events = (
        reconnect.RecoveryEvent(message=reconnect.LOST_MESSAGE, timestamp=105.0),
        reconnect.RecoveryEvent(message=reconnect.RESTORED_MESSAGE, timestamp=100.0),
    )

    report = reconnect.verify(events, [True], 1.0)

    assert not report.ordered
    assert not report.passed


def test_run_reports_pass_after_one_reconnect(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The command follows the tester through the loss and the return."""
    now = time.time()
    recovered = (
        reconnect.RecoveryEvent(message=reconnect.LOST_MESSAGE, timestamp=now),
        reconnect.RecoveryEvent(message=reconnect.RESTORED_MESSAGE, timestamp=now + 4),
    )

    def read_events(since: float) -> tuple[reconnect.RecoveryEvent, ...]:
        return tuple(event for event in recovered if event.timestamp >= since)

    monkeypatch.setattr(reconnect, "read_audio_devices", airpods_devices)
    monkeypatch.setattr(reconnect, "read_recovery_events", read_events)

    status = reconnect.run([])

    assert status == 0
    assert "PASS" in capsys.readouterr().out


def test_run_reports_a_missing_event(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A loss the log never shows is a tool error, not a failed reconnect."""
    monkeypatch.setattr(reconnect, "read_audio_devices", airpods_devices)
    monkeypatch.setattr(reconnect, "wait_for_event", _never)

    status = reconnect.run([])

    assert status == 2
    assert "reconnect:" in capsys.readouterr().err


def _never(*_args: object, **_kwargs: object) -> None:
    """Stand in for a poll that never sees the event."""
    return
