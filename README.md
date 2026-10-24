# Tapdeck

Audio routing and recording for macOS — taking in the sound of individual apps and
inputs, mixing it, and sending it to several outputs, including virtual devices,
built on Core Audio's modern APIs.

## What it is for

macOS gives every application one output and lets you pick one input. That is
fine until you want audio to go two places at once, or want to combine sources
that the operating system keeps apart:

- **Share your computer's audio on a call.** Zoom lets you share your
  microphone. It does not let you share the music, the video, or the other
  person's voice coming out of your speakers, because those are an *output* and
  Zoom wants an *input*. Tapdeck mixes them together and offers the result as an
  input device, so Zoom sees one microphone carrying both.
- **Record one app without recording everything.** System audio capture gets
  you the whole machine — notifications, other calls, whatever else is playing.
  Tapdeck can take one application's audio on its own.
- **Send different mixes to different places.** Your headphones want the full
  mix; the recording should not include the notification sounds; the stream
  wants the game but not the voice chat. Each destination gets its own device.

The common thread is that audio inside a Mac normally flows one way, from apps
to one output. Tapdeck lets you tap it, combine it, and present the result
wherever another app expects an input.

## How it works

```
app audio (process tap) ┐
all system audio        ├→ [convert] → [ring buffer] → sum → virtual device
microphone / interface  ┘                                         │
                                        Zoom / OBS read it as a microphone
```

### Mixes and outputs

A **mix** is a set of sources and a set of outputs. Any number of mixes can run
at the same time, so a meeting and a stream can each have their own.

Each mix can play to several **outputs** at once. The usual pair is a Tapdeck
device, so another app can pick the mix up, and your speakers or headphones, so
you hear what you are sending. The first output is the **main** one: its clock
drives the mix and channel placement refers to its channels. Every other output
receives a copy, converted to its own sample rate and folded to its own channel
count.

If you set the system output to a Tapdeck device so that apps play into it, you
will hear nothing — the audio went into the virtual device, not your speakers.
**Listen to a Virtual Device** creates a mix from that device's input side to
your speakers.

A mix will not start if it would create a feedback loop. Audio flows from every
device a running mix captures to every device it plays into; any cycle in that
graph, across all running mixes, is refused with the route that would loop.

### Mixing versus keeping sources apart

A stereo device has one pair of channels, so every source is summed into it and
cannot be separated afterwards. A virtual device can be made wider — 4, 6, 8 or
16 channels — and then each source can be placed on its own pair:

```
microphone    → ch 1–2 ┐
system audio  → ch 3–4 ├→ one 6-channel device → OBS or a recorder sees three tracks
music         → ch 5–6 ┘
```

This matters whenever the audio is edited or processed later: raising only the
voice in a screen recording, applying noise reduction to the microphone alone,
or cleaning up one side of a two-person conversation. For a video call it does
not matter, since the call app mixes everything to stereo anyway.

Recordings taken from a multichannel device keep this separation: the file gets
one stereo audio track per channel pair.

### Which device goes where

Leave the Mac's own output and input alone. Choose a Tapdeck device only inside
the app that should receive a mix — as the microphone in Zoom, as an audio
source in OBS — and add your speakers or headphones to the same mix to hear it.
Use one virtual device per destination: a meeting and a stream that want
different mixes each get their own device and their own mix.

A mix works from inputs to outputs in one place: sources are apps, all system
audio, microphones and interfaces; outputs are virtual devices, speakers,
headphones, Bluetooth and AirPlay.

### Shaping the sound

- **Effects per source.** Low and high cut (24 dB/octave), a five-band
  equaliser with presets, noise gate, compressor, limiter, balance, mono and
  delay. With everything off a source is bit-identical to what was captured.
- **Replace the original sound.** A source normally works on a copy while the
  app still plays straight to its device. Switched on, the app's own output is
  silenced while the mix runs, so what you hear is the processed version on the
  mix's outputs. The original comes back by itself if the mix stops or Tapdeck
  quits.
- **Even out loudness.** On a mix or a source, brings whatever plays to one
  loudness (−16 LUFS by default), so one video, site or song is about as loud
  as the next. Measured per ITU-R BS.1770; silence and short pauses hold the
  level, and a −1 dBFS limiter catches sudden jumps. Target, maximum boost and
  speed are in Settings › Audio.
- **One volume per place.** An output's fader is the device's own volume —
  the one the volume keys change — so turning it up is really louder and never
  distorts, even for a device that is not the Mac's output. Source, mix and
  master faders only turn down; Even Out lifts quiet material. Every output
  ends in a look-ahead limiter at −1 dBFS instead of clipping, and shows LIMIT
  while it works.
- **Delay per output.** Bluetooth and AirPlay play late — about 150 ms and 2 s.
  Delaying the other outputs lines them up; a mix with a wireless output offers
  **Line Up** to set typical values, to be fine-tuned by ear.

Three pieces:

1. **Per-app capture** uses Core Audio process taps (macOS 14.2+). No virtual
   audio driver and no kernel extension are involved.
2. **The virtual devices** are an `AudioServerPlugIn` — a user-space plug-in, so
   SIP stays on. They loop back: whatever is played into the output side can be
   read from the input side.
3. **The mixer** combines sources and feeds one virtual device.

Screen recording sits on top of this rather than beside it.

## Status

| Piece | State |
|---|---|
| Per-app audio capture | Working. Measured 113 dB of separation between two apps playing at once. |
| Virtual audio devices | Working. Up to 8, named, created and removed live. |
| Mixer | Working. Verified with zero discontinuities across a three-source mix. |
| Several mixes at once | Working. Each mix has its own engine; two mixes into one device measured independently. |
| Several outputs per mix | Working. A 44.1 kHz second output received the mix at the right pitch with zero discontinuities. |
| Feedback protection | Working. Loops across any number of running mixes are refused before they start. |
| Channel mapping | Working. Each source can take its own channel pair on a wide device; measured 112 dB between pairs. |
| Menu bar item | Working, but a full menu bar can leave no room for it (see below). |
| Screen recording | Working. Audio can come from ScreenCaptureKit or from the mixer, and a multichannel source is written as one audio track per channel pair. |
| Effects | Working. Filters, EQ and dynamics measured against theory, e.g. a 100 Hz low cut leaves 25 Hz at −54 dB. |
| Replace original sound | Working. The app is silent while mixing and returns within 1.5 s of Tapdeck being killed. |
| Loudness | Working. A −30/−10 dBFS pair plays at −18/−16 LUFS through a mix; the meter reads the standard's −3.01 LUFS calibration tone exactly. |
| Master, mix and output volume | Working. 0.5 × 0.5 measured −12.05 dB. Output faders set the device's own volume. |
| Output limiter | Working. A +12 dB boost that used to clip (3rd harmonic −21.5 dB) now stays at −1 dBFS with the 3rd harmonic at −105 dB. |
| Output delay | Working. 300 ms set, 300.7 ms measured. |
| Language | Working. System default, English or 日本語, chosen in Settings and applied without a restart; the app menu and file dialogs follow at the next launch. |
| AirPlay and Bluetooth | Working as outputs. The AirPlay receiver is chosen in Control Center; Tapdeck makes AirPlay the Mac's output while a mix plays to it (not yet tested with a receiver). |

## Install

Requires macOS 15 or later on Apple Silicon.

From the source folder:

```
./install.sh                 # builds and installs into /Applications
sudo ./install-driver.sh     # once, installs the virtual device driver (asks for your password)
```

From a release: download `Tapdeck-<version>.dmg` from the
[Releases page](https://github.com/kosuke-apps/Tapdeck/releases), open it, and drag
`Tapdeck.app` onto the Applications folder beside it. The app is signed but not
notarized, so macOS blocks the first launch: open System Settings › Privacy & Security
and click **Open Anyway** next to the message about Tapdeck.

To check the download, save the `.sha256` file published next to it in the same folder as
the dmg and run:

```
shasum -a 256 -c Tapdeck-<version>.dmg.sha256
```

It prints `Tapdeck-<version>.dmg: OK` when the file is intact.

The dmg holds the app only. Capturing apps, mixing, playing to several outputs and
recording all work without anything else; the virtual devices (for sending a mix into
Zoom, OBS and the like) need the driver, built and installed once from the source folder
with `sudo ./install-driver.sh`.

### About signing

Every Mac utility, Tapdeck included, is signed with one shared self-signed
certificate, **Mac Utilities Code Signing**, created once in Keychain Access.
`build.sh` and `Driver/build-driver.sh` use it when the keychain has it
(`tools/signing.sh`).

This matters more than it sounds. macOS remembers privacy permissions —
screen recording, microphone, audio capture — by an app's *designated
requirement*. Signed with the certificate, that requirement is the certificate
plus the bundle identifier, so permissions survive rebuilds:

```
designated => identifier "dev.kosuke.Tapdeck" and certificate root = H"…"
```

Without the certificate the build is signed ad-hoc, with a warning. The
requirement is then the binary's hash, every build counts as a different app,
and the permissions reset each time.

The virtual device driver is signed the same way. Core Audio's plug-in host runs
with library validation disabled, so it loads a plug-in whoever signed it:
measured, the signed driver loads and a 440 Hz tone sent to the virtual device
comes back from its input at -12 dB.

Moving an app from one signature to another means granting its permissions once
more. Re-enabling the old switch is not enough: remove the app from the list in
System Settings and add it again, so macOS records the new signature.

Releases are signed with this shared self-signed certificate, not notarized, and
distributed as a dmg. macOS therefore blocks the first launch of a downloaded copy:
open System Settings › Privacy & Security and click **Open Anyway** (see Install).

## Development

```
./build.sh                   # build without installing
./Driver/build-driver.sh     # build the driver only
swift tools/make-icon.swift  # regenerate the icon
```

`build/tapproof` is a command line harness that drives the same engine:

```
./build/tapproof list                    # processes Core Audio can see
./build/tapproof devices                 # audio devices
./build/tapproof virtual Tapdeck Podcast:4        # replace the virtual devices
./build/tapproof rec Chrome 10 out.wav            # record one app for 10s
./build/tapproof mix 5 Podcast 1234@1 5678@3      # two apps on separate pairs
./build/tapproof mix 5 Tapdeck,Monitor 1234@1     # one mix, two outputs
./build/tapproof rate Monitor 44100               # change a device's sample rate
./build/tapproof graphtest                        # feedback loop detection
./build/tapproof gaintest                         # master, mix and output gain
./build/tapproof delaytest                        # output delay line
./build/tapproof fxtest                           # effects against theory
./build/tapproof loudtest                         # loudness meter and normaliser
./build/tapproof devicetest                       # finding devices under new UIDs
./build/tapproof limittest                        # the output limiter
./build/tapproof tone Podcast 3 1000 5            # a tone on channel 3 only
./build/tapproof capture Podcast 3 out.wav        # record every channel of a device
./build/tapproof muxtest out.mov                  # multitrack muxing, offline
./build/tapproof loopback 4                       # check a device round-trips
```

`mix` also reads `TAPDECK_MASTER`, `TAPDECK_MIX_VOLUME`, `TAPDECK_OUTPUT_DELAYS`
(`Name=ms,…`), `TAPDECK_REPLACE=1` and `TAPDECK_LOUDNESS=1`, and prints each
tap's assumed, measured and clock sample rates every second.

## What macOS allows

[`docs/platform-limits.md`](docs/platform-limits.md) maps what is possible,
what is not and why, and what is still to be tested — AirPlay, device volume,
per-app routing, inputs. Features are designed inside that map.

## Implementation notes

Each of these cost real time to find, and none of them announced itself.

### Process taps are silent without NSAudioCaptureUsageDescription

Core Audio process taps are gated by TCC's `kTCCServiceAudioCapture`. The
Info.plist key that goes with it is `NSAudioCaptureUsageDescription`.

Without it, `AudioHardwareCreateProcessTap` **still succeeds** — it just
delivers silence forever. No error, no prompt, nothing in the log. The same code
run from a command line tool worked, because that inherited its parent's
permission, which made it look like an app bug.

### The tap's reported sample rate can be wrong

What reaches the IOProc is the aggregate device's input stream, and the
aggregate follows the clock of its main sub-device — the default output device.
So `kAudioTapPropertyFormat` can disagree with reality.

Measured: the built-in speakers ran at 44100 Hz while the tap reported 48000 Hz.
Trusting the tap pitch-shifts every recording by 8.8%, turning 440 Hz into
479 Hz. Read `kAudioDevicePropertyNominalSampleRate` from the aggregate instead.

### Tap buffers are interleaved

`AVAudioFile` and `AVAudioEngine` both assume the opposite. A mismatch makes
every `write(from:)` throw and leaves a file containing only a header.
`ProcessTap` normalises to non-interleaved Float32 before handing anything on.

### Don't point a tap's clock at the output device

Matching the tap's clock to the mixer's output removes the need to resample,
which seems like the right move. It also stops the tap from hearing anything
that is not already flowing to that device — measured as complete silence.

A Tapdeck virtual device cannot clock a tap's aggregate at all: with audio
flowing into it, the IOProc was never called.

### A tap's clock can change rate under it

Reading the rate once at start is not enough. During one measurement a 997 Hz
tone came out of a mix at 916 Hz from a certain moment on — 997 × 44100/48000 —
because the audio had started arriving at 48000 Hz while still being converted
as 44100 Hz. The tap now listens for nominal rate changes on its aggregate (on
the IOProc's own queue, so the format never changes mid-callback), falls back to
the rate measured from timestamps when that is more than 3% off, and each source
rebuilds its converter when buffers arrive at a new rate.

### The AirPlay device gets a new UID every time it appears

Its UID carries a long number that changes between sessions
(`…-50150987687166-Audio`, later `…-89446392180958-Audio`), so an output saved
by UID could never be found again. A missing UID now falls back to the single
device with the same name whose UID matches once such numbers are ignored.

### Wireless devices under-report their latency

AirPlay reported zero latency through the HAL while playing about two seconds
late. Reported latency is shown as a hint; lining outputs up uses typical values
and the ear.

### Published properties run their observers during init

`@Published var volume: Float = 1 { didSet { … save … } }` runs `didSet` when an
initializer assigns it, because the default value has already initialised the
wrapper. Restoring a mix whose volume was not exactly 1 therefore saved the
library while it was still being loaded — as an empty list, at every launch.
Only a later edit saved it again, which hid the bug. Restoring now never saves,
and the library refuses to save before loading finishes.

### Loudness without look-ahead has to chase jumps

Following the 400 ms momentary loudness alone left a jump from quiet to loud
audibly too loud for half a second. After a jump the estimate now follows the
newest 100 ms block with a 0.1 s time constant, which brings the output back
near the target within about 0.4 s; the limiter covers the first block.

### Ring buffers need a cushion

Sources and output run on different clocks, so matching their rates still leaves
their phase unmatched. Reading without a cushion keeps the buffer near empty and
every wobble punches a gap in the waveform. It shows up as the overall level
being right while one frequency collapses.

### The driver is not hosted by coreaudiod

It runs inside `com.apple.audio.Core-Audio-Driver-Service.helper`, which is
sandboxed far more tightly. It cannot read any path an unprivileged app can
write, so configuration files never reach it — again with no error and no denial
in the log. The device list travels through a Core Audio **custom property**
instead, which stays inside the HAL.

### AVAudioFormat refuses more than two channels without saying so

`AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` returns nil for
three channels or more. Wide formats need a channel layout
(`kAudioChannelLayoutTag_DiscreteInOrder`). `AVAudioFormat.discrete` wraps this.

### AVAudioEngine is the wrong output stage for channel mapping

Its mixer node applies its own channel handling, so a wide output can arrive
folded or reordered. `DeviceOutput` drives an AUHAL directly and writes each
device channel itself.

### Sources must stay pinned to the process that was chosen

The mixer used to find each application again by name when it started. Two
processes with the same name — two instances of one app, or two helper tools —
then both tapped whichever was found first. One source silently carried the
other's audio, which looked exactly like a channel mapping bug. The session PID
is now kept (never saved) and checked before the bundle identifier and the name.

### The driver must never reuse object IDs

Object IDs used to be derived from the slot a device occupied. Removing a device
and adding another put the new one into the same slot with the same IDs, and
because the HAL caches properties per object ID, the new device appeared wearing
the old one's UID and a mix of both stream layouts — observed as a device
reporting eight input channels and four output channels. IDs now come from a
counter that never goes backwards while Core Audio runs.

### The driver forgets its devices when Core Audio restarts

The device list lives in the driver's memory. After a reboot or a driver
reinstall only the default device exists until the app sends the list again,
which it now does at launch.

### Real-time paths must not take a lock the disk can hold

`DoIOOperation` and `GetZeroTimeStamp` run on the real-time thread. Any lock
they take must never be held by something doing file I/O, or the audio breaks up
waiting for the disk.

### SwiftUI's MenuBarExtra did not work here

In this setup — a bundle built with `swiftc`, alongside a `Window` scene — it
created no status item even in its simplest form. `NSStatusItem` is used
directly instead.

### A notched display can have no room for a status item

Status items can only occupy the strip to the right of the notch. Measured on an
1800 pt display, the notch took 790–1010, leaving 1010–1800. Once other apps
fill that, macOS allocates no slot and pushes the item's window off screen (to
y = -22) without reporting anything. `MenuBarController` detects this and says
so in the UI.

### ffmpeg's avfoundation capture is not a measuring instrument

While verifying the mixer, a 440 Hz tone came back at -32.6 dB instead of
-21.1 dB, with phase jumps every 512 frames. The ring buffer, the converter and
the tap all measured clean. Recording the same signal through the app's own
AUHAL gave -21.1 dB with zero discontinuities. The capture tool was dropping
blocks. The app has a monitor recorder now so measurements do not depend on it.

## Permissions

- **Audio capture** — to take the sound of individual apps, or of the whole
  system, into a mix. Asked on first use.
- **Microphone** — to read input devices: microphones, audio interfaces, and the
  input side of Tapdeck's own virtual devices.
- **Screen recording** — only for screen recordings in the Recording tab. macOS
  quits the app once after this is granted; launch it again.

## Privacy and third-party material

Tapdeck has no network code and sends nothing anywhere; [PRIVACY.md](PRIVACY.md) lists
what it stores and where. The language chosen in Settings is kept with the other settings, on your Mac only. It contains no third-party code and uses only frameworks that
ship with macOS; [THIRD_PARTY.md](THIRD_PARTY.md) says so in detail, including where the
virtual device driver comes from.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Kosuke Satake.

This app was built with the help of Claude (Anthropic) through Claude Code; design, review and testing are by Kosuke Satake. Anthropic does not endorse this app.
