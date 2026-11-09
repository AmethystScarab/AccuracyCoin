# AccuracyCoin PAL port

Status: **PAL source conversion complete; hardware validation still required.**

Target hardware: PAL NES with a **Ricoh RP2C07 PPU** and **RP2A07 CPU/APU**.

The shared frame/VBlank timing layer now uses PAL timing. The ROM does not use
NTSC frame-length waits or NTSC-only menu tests. Fourteen PAL-specific entries
cover the areas where NTSC and PAL behavior differ.

## PAL reference timing

- 312 scanlines per frame; 341 PPU dots per scanline.
- 70 VBlank scanlines instead of 20; NMI remains at scanline 241.
- 3.2 PPU dots per CPU cycle (16:5), not 3:1.
- 33247.5 CPU cycles per frame; 50.007 Hz nominal frame rate.
- The PAL pre-render line is never shortened; there is no NTSC-style short frame.
- NMI to start of rendering is about 7459 CPU cycles.
- OAM can only be written during the first 24 scanlines after NMI. The 2C07
  forcibly refreshes OAM during scanlines 265-310.
- The 2A07 APU uses PAL period tables. The 4-step frame IRQ is about 33254 CPU
  cycles, not the NTSC 29830-cycle period.

## Implemented PAL work

- PAL frame, VBlank, pre-render, and NMI timing helpers.
- PAL frame-counter waits for APU IRQ and VBlank-flag tests.
- Fourteen PAL-specific tests: frame length, 4-step frame IRQ, NMI control,
  VBlank length, 5-step APU timing, NMI at VBlank end, NMI disabled at VBlank,
  forced sprite evaluation, sprite-zero hit, $2002 flags, sprite-size switching,
  misaligned OAM hit, OAM write window, and DMC playback rate.
- Warm reset clears test RAM and reinitializes PPU/APU/OAM state; power-on
  snapshot tests are intentionally skipped on reset.

## Hardware validation still required

These are validation limits, not unfinished NTSC timing code:

1. Exact dot/HBlank phase, OAM refresh, and PPU emphasis behavior need a real
   PAL NES or a PAL-accurate emulator.
2. The 2A07 APU/DMC period tables and sample-position timing should be checked
   on PAL hardware; DMC waits in the source are CPU-cycle sample waits.
3. Power-on RAM/VRAM snapshots require a true power cycle. A warm reset cannot
   recreate uninitialized power-on state, so those tests are skipped after reset.

## Build

Assemble `AccuracyCoinPAL.asm` with the original `Sprites.pcx` and `Tiles.pcx`
assets. The source assembles with NESASM CE; use the checkout's CHR assets rather
than a generated ROM.
