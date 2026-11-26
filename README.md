# HAMLOG64

A ham radio QSO logger for the Commodore 64 + REU, written in 6502 assembly with Kick Assembler.

Callsign: KC2NIK

## Features

- 9-field QSO entry form: call, RST sent / received, band, mode, frequency, name, grid, notes
- Band and mode selectors, with type-to-jump
- 128-byte QSO records stored in the REU, newest first
- Recent-QSO list on the main screen, plus a full log viewer (F2) with paging, edit, delete, and find-by-date
- CIA1 TOD clock with BCD date handling, including leap years and midnight rollover
- Automatic clock setting from the Ultimate RTC over the Ultimate Command Interface (UCI)
- Backup / restore of the whole log through the Ultimate's file system
- ADIF export and import, with duplicate detection

## Keys

- RETURN / CRSR down: next field, CRSR up: previous field
- CRSR left / right: move in field, DEL: backspace
- F1: save QSO, F2: view log, F3: menu, F7: quit to BASIC

## Building

Assemble with Kick Assembler:

```
java -jar KickAss.jar HAMLOG64.asm
```

Target hardware: C64 Ultimate (also works on a stock C64 with a REU, with `USE_UCI = false`).

## Version history

- v1.21: initial release in version control
