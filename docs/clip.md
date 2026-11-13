# The line on the project page

Written by `uv run --project tools python -m untunnel_tools.site.clip`; do not edit.

- Recording: LibriVox, Emily Dickinson, "Because I could not stop for Death", 11 s into the file (tools/reference/realtime_goldens.py SPEECH).
- Headset: the mSBC simulation in `simulate_hfp.py`, which carries 8 kHz.
- Restored by `untunnel enhance --model streaming --bwe 48000`, which writes 48 kHz audio and so predicts up to 24 kHz.
- Spectrum: 40 ms Hann window, 20 ms hop, 100 Hz columns; 82 frames.
- Rolloff, the upper edge of the last FFT bin within 40 dB of the loudest (2048-point Hann, half overlap):
  - headset: 7.7 kHz (7727 Hz)
  - untunnel: 12.4 kHz (12352 Hz)
  - original: 10.9 kHz (10875 Hz)
