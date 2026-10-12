# QROS Loader V2

A turbo tape loader for the **QROS / EMO** system on the **Atari XL/XE**, written in 6502 assembly (MADS).

It reads a QROS tape (132-byte blocks, SIO frames on POKEY's serial input) and parses the data **as the bytes arrive** — there is no file buffer, every byte goes straight to its final address. Two kinds of tape content are understood:

- **Atari binary (DOS) format** — the usual program file: segments, optional repeated `FF FF` headers, `INITAD` called between segments the way DOS does, `RUNAD` at the end.
- **Cassette boot images** — tapes in the form the OS boots itself (6-byte header + 128-byte records), for example DETURBO. After loading, the loader does what the OS does after a cassette boot: `JSR load+6`, `JMP (CASINI)`, `JMP (DOSVEC)`.

<p align="center">
  <img src="qrosimg.png" width="80%" alt="QROS Loader V2">
</p>

## V2: the loader lives under the OS ROM

The loader takes no memory away from the program:

1. The stub (loaded at `$0700`) copies the OS ROM into the RAM underneath it (`$C000-$CFFF`, `$E000-$FFFF`), applies the **QROS OS** modifications from `qrosos.inc` to that copy (the cassette handler `C:` in RAM — the same OS environment QROS itself installs, so programs like DETURBO run and can save through `C:`), and moves itself into the floating-point ROM area `$D800-$DFFF`.
2. The tape is loaded with the OS ROM switched off. The stub's memory at `$0700` now belongs to the program. Writes to the zero page go to a shadow and are put in place before every `INIT` and before `RUN`; writes into the loader's own pages or the stack page are refused and reported.
3. Before the program starts, `$D800-$DFFF` is restored from the ROM, so the loader leaves no trace. The program runs with the ROM off (QROS OS in RAM) and BASIC off, and may use `$0000-$BFFF` except the stack page — about 47 KB.

## Screen and keyboard

- The loader shows `QROS LOADER V2, W1K 2026 (AI)` and waits for a key press; the cassette motor starts only then.
- While loading it shows the program name from the tape header and, on the right, a percentage (when the tape carries a total block count) or a block counter `BLOK n`.
- The text line runs from the loader's own display list in protected memory. After every block the OS shadow registers (display list, DMACTL, colours, character set, PRIOR) are copied to the hardware, as the OS VBI would do — a loading picture that a segment sets up through the shadows is shown. Display list and DMACTL are written only when they change, so the picture does not jump.

## Speeds

Four POKEY divisors are tried in turn: the build's divisor, the other common QROS speed, and both of them lowered by 4 (`127, 123, 86, 82`: 6617, 6821, 9535 and 9963 baud PAL). The lowered ones exist for tapes recorded by an emulator at the exact rate — their decoder samples late, so they read only with a receiver about 3 % faster.

The speed is switched only when a block that started cleanly after an inter-record gap fails its checksum; a block the receiver ran into halfway only re-synchronises on the next gap. The tape header is sent twice, so the right speed is found before the first data block. Time-outs are measured by VCOUNT changes, not CPU cycles, so they also hold on an accelerator.

## Errors

On failure the loader stops, prints the reason on its text line and colours the border:

| Border | Message | Meaning |
|--------|---------|---------|
| red `$34` | `CHYBA - NEZNAMY FORMAT` | neither a binary (DOS) file nor a boot image |
| orange `$24` | `CHYBA - NECITATELNY BLOK` | a block is unreadable after 16 attempts |
| green `$B4` | `CHYBA - CHYBA RUN ADRESA` | the tape never set a RUN address (`$02E0`) |
| blue `$84` | `CHYBA - PREPISUJE LOADER` | the program writes into the loader's pages (`$D800-$DFFF`) or the stack page |

## Build

Requires **[Mad Assembler (MADS)](https://github.com/tebe6502/Mad-Assembler)**. `qrosos.inc` must sit next to `qrosload.asm`. Two variants come out of the same source:

```
mads qrosload.asm -d:BOOT=0 -d:LOADADR=$0700 -d:DIVISOR=127 -o:qrosload.xex
mads qrosload.asm -d:BOOT=1 -d:LOADADR=$0700 -d:DIVISOR=127 -o:qrosload.bin
```

- `BOOT=0` — a standalone `.xex` (included here as `qrosload.xex`): load it from disk, then start the tape.
- `BOOT=1` — a raw blob with a 6-byte cassette boot header (37 boot records), to be written at the head of a QROS tape by a tape generator.

`DIVISOR` is the POKEY serial divisor — `baud = clock / (2 * (DIVISOR + 7))`; `127` is the "6600" mode, `86` the "9600" mode. It only picks which speed is tried *first*.

The last four bytes of the blob can be patched by a tape generator without reassembling:

| Offset | Field | Meaning |
|--------|-------|---------|
| `len-4` | `baudiv` | POKEY divisor to try first |
| `len-2` | `total_blk` | total data blocks on the tape (0 = block counter instead of percent) |

## Files

- `qrosload.asm` — the loader
- `qrosos.inc` — the QROS OS modifications applied to the OS copy in RAM, as runs `[address, length, bytes...]`, terminated by length 0
- `qrosload.xex` — ready build (`BOOT=0`)

## Credits

- **QROS system & software** — Ing. Matúš Zubor
- **QROS hardware revival (2025)** — Aleister
- **Loader V2** — W1K 2026 (AI)
