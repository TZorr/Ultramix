# Third-party notices

Ultramix is © 2026 T'Zorr and is distributed under the MIT License (see
[LICENSE](LICENSE)). It contains the third-party components listed below.
These notices must be kept with the source and with any binary distribution.

## Summary

| Component | Version | License | Where |
|---|---|---|---|
| LAME (`libmp3lame`) | 3.100 (`lame-master`, alpha 1) | LGPL-2.0 | `Ultramix/LAME/` |
| Beat This! weights (`small0`) | — | MIT | `Ultramix/Resources/BeatThis_small0.mlpackage` |
| Core ML conversion of those weights | — | MIT | same file |

Full licence texts ship with the source:

- `Ultramix/LAME/COPYING.LAME.txt` — GNU Library General Public License v2
- `Ultramix/Resources/BeatThis-LICENSE.txt` — the MIT texts for Beat This!
  and for the Core ML conversion

## LAME (MP3 encoder)

- **What:** LAME 3.100 (the `lame-master` development snapshot, patch level
  "alpha 1"), the MP3 encoding library `libmp3lame`. Used only for MP3
  export.
- **Copyright:** © The LAME Project and its contributors —
  <https://lame.sourceforge.io>.
- **License:** GNU Library General Public License, version 2 (LGPL-2.0). The
  full text ships with the source as `Ultramix/LAME/COPYING.LAME.txt`.
- **How it is used:** the unmodified library sources are compiled directly
  into the Ultramix application (`Ultramix/LAME/`). The only file added is
  `Ultramix/LAME/config.h`, a hand-written build configuration for macOS on
  Apple Silicon. The MP3 decoder, the x86 assembly and the SSE code are not
  built.
- **Relinking:** LAME is linked statically. As the LGPL requires, the
  complete source of both Ultramix and LAME is available, so Ultramix can be
  rebuilt against a modified version of LAME: replace the files in
  `Ultramix/LAME/` and build with `./build_dmg.sh`.

## Beat This! (optional beat analyser)

- **What:** the "small0" weights of Beat This!, a beat and downbeat tracking
  network, as a Core ML model (`Ultramix/Resources/BeatThis_small0.mlpackage`,
  8.6 MB). Used only when Settings › Beat Detection is set to Beat This!.
- **Copyright:** © Francesco Foscarin, Jan Schlüter and Gerhard Widmer
  (CPJKU, Johannes Kepler University Linz) —
  <https://github.com/CPJKU/beat_this>.
- **Core ML conversion:** the conversion of those weights is © 2026
  Till Toenshoff — <https://github.com/tillt/BeatIt>.
- **License:** MIT, both of them. The full texts ship with the model as
  `Ultramix/Resources/BeatThis-LICENSE.txt`.
- **How it is used:** the model file is compiled into the app bundle by Xcode
  and run through Core ML. No code from either project is compiled into
  Ultramix. `Ultramix/Analysis/BeatThisAnalyzer.swift` is Ultramix's own
  code; it feeds the model the input the network was trained on (22.05 kHz
  mono, a log-mel spectrum of 128 bands at 50 frames a second) and reads its
  output, and everything the grid is then built from is the Ultramix
  analyser's.

## Everything else

Time-stretching, the tempo and key analysers, the loudness measurement, the
mastering limiter, the MP4 and ID3 tag writers and all other audio
processing in Ultramix are its own code. No other third-party source,
binary library or model is included.
