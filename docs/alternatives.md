# Alternatives

Other ways to sound better on a call from a Mac, with what each one's own page says. Prices and
limits are quoted from the linked page on the date shown; they change, so check the page before
you rely on one. Untunnel has not been compared with any of these by ear or by measurement, so
this page says what each one offers, not how it sounds.

| Alternative | What it is | Cost and limits, as its page states them | Source, checked |
|---|---|---|---|
| Krisp | Krisp AI Meeting Assistant, with an account | "Free for 7 days"; Core shows "$16/mo/user" and "$8/mo/user", Advanced "$30/mo/user" and "$15/mo/user"; "By default, Krisp AI Meeting Assistant requires a Google or Outlook calendar connection during signup." | [krisp.ai/pricing](https://krisp.ai/pricing/), 2026-11-09 |
| Adobe Podcast Enhance Speech | Speech enhancement for audio files, with an Adobe plan | Premium comes with "Adobe Firefly Pro plan with access to Adobe Podcast Premium": "Enhance up to 4 hours a day, files up to 1 GB". The page shows no price. | [podcast.adobe.com/en/plans](https://podcast.adobe.com/en/plans), 2026-11-09 |
| Hush AI | Open-source noise removal, from your voice "while you talk, and from recordings you already have"; on macOS it "installs its own small audio driver" | "Free, no limits"; app and engine "Apache-2.0", with NVIDIA RE-USE weights under "the NVIDIA One-Way Noncommercial License". Runs on Apple silicon and Intel Macs, Windows and Linux. You pick its microphone: "Choose it once in Zoom, Google Meet, Microsoft Teams, Slack, Discord, Webex or OBS." | [github.com/alshell7/hush-ai](https://github.com/alshell7/hush-ai), 2026-11-09 |
| ReuseMic | "NVIDIA Real-time RE-USE speech enhancement as a macOS virtual microphone" | Code "dual-licensed under MIT or Apache-2.0", weights under the "NVIDIA One-Way Noncommercial License (NSCLv1)"; "macOS 11 or later (Apple Silicon recommended)". Its bundled HAL plug-in provides the device, and you pick "ReuseMic" as the input in each app. | [github.com/tsuzu/reusemic](https://github.com/tsuzu/reusemic), 2026-11-09 |
| Apple Mic Modes | Built into macOS | "To filter out background sounds, select Voice Isolation." Chosen from the menu bar in an app that supports Mic Modes, such as FaceTime; "options vary by app". | [support.apple.com, Mac User Guide, Mic Modes](https://support.apple.com/en-hk/guide/mac-help/mchle82b42f0/mac), 2026-11-09 |

Untunnel, Hush AI and ReuseMic can all run NVIDIA RE-USE models, whose streaming weights are
non-commercial. [How Untunnel works](how-it-works.md) describes what Untunnel does with the model
and which parts of it run today.
