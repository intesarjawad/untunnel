# Design: the project page

Files, all in `site/`: `index.html`, `style.css`, `score.js` (the shader), `sdf.js` (the distance field),
`clip/` (generated), `fonts/`, `credits.json`. The mic test in `site/test/` shares the palette
and text face through `site/tokens.css`.

## The idea

A headset call cuts a voice at 8 kHz, where s, f and t live. The page sets one spoken line as
type, twice, and lets the type carry the loss: each word is as wide as it was said, each letter
takes its share of that time, and letter height is frequency, 0 at the baseline to 24 kHz at the
cap line. Above, through the headset, every letter is sliced flat at a third of its height, so
the line becomes hard to read the way the consonants become hard to hear. Below, through
Untunnel, the same letters have their tops drawn back in red, so each word compares with itself.
It reads with the sound off, which is how a README hero and a social card are seen.

What it takes from Robert Massin's *La Cantatrice chauve* (Gallimard, 1964): type scored to a
performance, letterforms physically stretched to how a line was spoken, every distortion caused
by the performance and none decorative. Nothing of his typefaces, layouts or photographs is used.

## The signature moment

The score (`#score`) is one WebGL2 fragment shader over a signed distance field of the line, set
as a pair of staves: the headset's above, Untunnel's below (on a phone, two pairs, half the line
each).

- Letter widths: `clip.py` splits each word's time among its letters by a least-cost alignment
  on the headset take (voiced level, hiss over the voiced band, loudness per 20 ms frame, with a
  typical length per sound class so vowels hold and stops stay short). `score.js` gives each
  letter 70% of its width from that time and 30% from its natural width, so a 20 ms stop stays
  a letter, and never less than 80% of its natural width, so a quick B keeps both bowls. A narrow
  capital such as I keeps its own width centred in its time, never a slab.
- Each stave is measured: a hairline at 24 kHz on the cap line, the dashed cut at 8 kHz, and a
  scale (24 kHz, 8 kHz, 0) in a left column. On a wide screen the stave's name hangs from its cap
  line in that column, at the same offset on both staves; on a phone the column holds only the
  scale and the first pair is named above its cap lines, once. The README hero and social card
  carry the same scale, so the empty band over the headset stave reads as measured loss.
- `sdf.js` builds the field on the page from the letters as drawn, using the exact Euclidean
  distance transform. No atlas is shipped; the field is rebuilt on resize (about 50 ms for a
  1440 px wide score).
- Below the 8 kHz line the letters print solid ink on both staves. Above it the headset stave
  shows nothing: the cut is meant to hurt. Ahead of the front, the Untunnel stave is in the same
  cut state, so the front visibly redraws the tops.
- Above it on the Untunnel stave, behind the front, the letters print as an amplitude halftone:
  full `--red` dots on the ground, on one 45-degree screen per stave of one cell per 26th of
  its height, inside a solid red rim about 2 px deep that keeps every letter's outline. The
  restored take's real spectrum sets each dot's size continuously, from small dots where the
  band is quiet up to just short of touching; frames louder than 70% of the scale print dense,
  about 85% of each cell, so a stroke still reads as a letter and no two letters join. A letter
  whose stems cannot hold two of the screen's dot columns keeps its clean rim instead of a finer
  screen, and prints solid only where it is loudest, as the s of "because" does (`HALFTONE` in
  `score.js`). No pixel is ever a tint of red. The spectrum is filtered linearly between
  20 ms frames and read across two frames either side, so a letter shades from one frame to
  the next instead of switching. `clip.py` measures each
  frame's predicted band against the frame's own voiced band and normalises each 100 Hz row on
  the dB scale, then mixes in the frame mean, so hiss over a quiet mouth reads darkest. The test
  `test_committed_clip_burns_the_s_of_stop_brighter_than_the_vowel_of_not` holds that to the
  committed clip (the s of "stop" reads more than twice the o of "not").
- The front is a solid 1.5 px `--red` rule from 24 kHz to 0, with "Restoring, 20 ms at a time"
  riding it ("Paused" while paused): right of the rule at the top of the empty band ahead, or
  left of it above the cap line near the end. Letters
  ahead of it carry no red. Fresh dots grow to their size over 50 ms. A hissy frame flashes full
  `--hot` for the one 20 ms frame the front has just passed; nothing else goes hot.
- "Play the line" plays `clip/untunnel.flac` and the front is its `currentTime`. While it plays
  the button stays black in every state, hover included, and keeps its width, showing a pause
  mark and the time into the line;
  a second press pauses and a third resumes. "Hear the headset alone" plays `clip/headset.flac`
  and runs an ink playhead on the headset stave.
- Hovering a word, or focusing it in the ruler, redraws that word alone from the left, at the
  pace it was said (never faster than 0.45 s). Pressing it plays that word's slice of the
  restored take with the front on the audio. Sound plays only on a press.
- On load the front sweeps silently along the whole line, then rests past its end: the resting
  frame is the still, headset and Untunnel stacked, before and after with no sound or motion.
- The masthead is a menu bar, and its status item (the s; while bypassed its top is faint) is a
  button that opens Untunnel's menu: the app's own lines in the system face at one row height,
  the one place with corners and a shadow, with the app's microphone line as its single status
  row ("Restoring at 48 kHz", "Microphone bypassed"). From 1100 px wide it starts open, and the
  headline's column runs right up to it; narrower, it opens on a press; on a phone it opens as a
  sheet over the headline holding only the band, then the status and Bypass on one row, so it
  ends above the Play button and the staves stay in view. Its header is the whole line in small, shaped by the spectrum: one bar per
  20 ms frame, ink as loud as the band under the cut, red as loud as the band above it, drawn
  only where the top is restored.
- "Bypass Restore" works as the app's does, and the cut is part of the audio. Pressed while the
  line plays, the takes swap on that frame with a 40 ms crossfade, and the one front turns ink
  and stops drawing tops; its label reads "Bypassed, the headset alone", and the tops drawn
  before the bypass turn to the same dots in ink-grey, heard but no longer sent. The stretch
  played bypassed stays cut after Resume.
  Pressed at rest, the tops come off from the end of the line back to the start under the plain
  red rule, and the play button reads "Play bypassed", which plays the headset take. The
  item becomes "Resume Restore", and the system accent marks it on hover and focus.
- The ruler's buttons are placed from the glyph extents `score.js` records while drawing the
  letters, under each pair's Untunnel stave, so each word's button sits under its glyphs on a
  phone as well. `test_ruler_words_sit_under_their_glyphs` checks the centres agree within 3 px
  on a rendered 1440 px page.
- Under the score, the provenance note takes the left half at a 66-character measure and a key
  to the three marks (ink, the red halftone, the dashed cut) takes the right.

## Tokens

| Token | Value | Use |
|---|---|---|
| `--ground` | `#fbfbf8` | page, a printed white |
| `--ink` | `#121212` | text, the surviving band (18.1:1) |
| `--ink-soft` | `#4f4f4b` | secondary text (7.9:1) |
| `--red` | `#d02a19` | the predicted band and the words that name it, nothing else (5.0:1) |
| `--hot` | `#ff4a1c` | the 20 ms flash just behind the moving front only, never text |
| `--code-ground` | `#efefea` | code blocks |
| `--accent` | `#0a5cd0` | the menu picture's highlighted row only, as macOS draws it (6.0:1 with white) |

Links, focus rings and controls are ink. Red never marks a link, a pressed button or focus.

## Type

- League Gothic (OFL), the 1903 Alternate Gothic revived: every display line, the score, section
  heads, buttons. Section heads carry the cut: a hairline of ground through each line at a third
  of the cap height (`--scar-low`, `--scar-high`, set from the font's line box: 23 units below
  the baseline, 97 above, caps 73.5).
- Source Serif 4 (OFL), optical sizes on: everything read. Italic only for the ruler's words.
- The system monospace for commands and paths.
- Both fonts are self-hosted in `site/fonts/` with their licences; `credits.json` lists them.

## Motion

- The intro sweep and playback run on `requestAnimationFrame` only while something moves; the
  page renders nothing at rest, off screen or in a hidden tab.
- The glow cools over about half a second once the front stops.
- `prefers-reduced-motion`: no intro, no hover sweeps, no drying or flash; during playback the front steps
  word by word, so a whole word's tops print at once; Bypass cuts and restores at once. The
  resting frame is the same still.
- No WebGL: `#score` keeps `data-state="still"` and `clip/still-wide.png` or `still-narrow.png`
  stays in place under the DOM labels and scale. Ground-coloured veils cover the tops the front
  has not reached and any stretch played bypassed, down to the cut line so no rim shows ahead of
  the front, with a red edge at the front and its riding label, so the fallback follows
  playback, the intro and Bypass; the line and every word still play.
- The canvas never carries the only copy of anything: the line is in the figure caption, the
  stave names, scales and cut lines are DOM, the words are buttons in the ruler.

## The mic test

`site/test/` carries the main page's bar, left margin and two controls: the black slab in the
display face for the one action, underlined text for the rest. Its first control is "Record
your microphone" under the intro. Before a visitor records, any result shown is headed
"A sample, until you record", with the record button above the sample's reading; the verdict
heading appears only for the visitor's own take. Each rolloff is said in Hz in the verdict or
the comparison list, and the figure labels its dashed line with the same value (the headset's
cut in whole kHz). From 1000 px wide
the figure takes a right column beside the controls. It is the main page's own "stop": its
letter timings and the restored take's spectrum under it ship as `site/test/stop.js`, so the
letters take the score's time-stretched widths and the red dots, on the same single screen and
rim rule, are sized by the real spectrum, dense where the s hisses. Before a take it shows the headset's 8 kHz cut; after one, the
measured top.

## Numbers and where they come from

| On the page | Script |
|---|---|
| 8 kHz cut, 24 kHz top, 20 ms hop, 40 ms window | `uv run --project tools python -m untunnel_tools.site.clip`, written to `site/clip/clip.json` and `docs/clip.md` |
| The source MP3 stops at 10.9 kHz | the same script's rolloff of the clean excerpt (`docs/clip.md`) |
| 16 kHz and 8 kHz call rates | `tools/src/untunnel_tools/eval/simulate_hfp.py` and README "How it works" |
| Engine timing | `untunnel bench`; run it on the target Mac, since call latency is unmeasured |
| Menu lines, in the masthead menu and "What the menu holds" | `Sources/Untunnel/App/MenuView.swift`, `State/AppState.swift` |
| Mic test previews: 7035 Hz, 10875 Hz | the sample call recording is `fixtures/narrowband/sample.wav`, measured by the page in `tools/tests/test_site_browser.py` against `fixtures/narrowband/sample.rolloff.json`; the line before the headset is in `docs/clip.md`. The page itself names neither path. |
| Word onsets and per-letter time | `tools/reference/clip-words.json`, `clip.py` (`--frames` prints the landmarks the onsets were set from) |
| The mic test's STOP: letter times, spectrum, 8 kHz cut | `uv run --project tools python -m untunnel_tools.site.stop`, copied from `site/clip/clip.json` to `site/test/stop.js`; `test_microphone_check_carries_the_committed_clips_stop` keeps them equal |

`untunnel_tools.claims` reads `docs/clip.md` as evidence, so a number on the page that no script
wrote fails the lint.

## Replacing the clip

The line is the LibriVox reading the parity goldens pin, through the mSBC simulation. To use a
recording of a real call instead:

1. Record a mono WAV of the call as the headset sent it.
2. Write its word onsets in the format of `tools/reference/clip-words.json` (any word-level
   transcriber; the current file came from whisper.cpp large-v3-turbo, then moved by hand onto
   the closures and bursts the headset take shows).
3. `uv run --project tools python -m untunnel_tools.site.clip --headset call.wav --words words.json`,
   then `--frames` to print each frame's voiced level and hiss and check the onsets against them.
4. `uv run --project tools python -m untunnel_tools.site.stop` copies the new "stop" to the mic
   test (if the line has no "stop", change `WORD` there and in `mic-test.js`).
5. `uv run --project tools --group site python -m untunnel_tools.site.stills` redraws the
   fallback stills, `docs/hero.png` and `site/social-card.png` from the page itself.

If the new line has a different number of words, change `PAIRS` in `score.js`, which says how
many words each headset and Untunnel pair carries, wide and narrow.

## What must not change

- Letter height is frequency and letter width is spoken time. Nothing is drawn for effect.
- The headset stave sits directly above the Untunnel stave, the same words in the same places.
- The cut sits where the data puts it (`cut_hz / top_hz`), and red only ever means predicted.
- The page says the red is predicted, not recovered, and that the source MP3 has no top above
  10.9 kHz to check it against.
- Audio never plays without a press.
