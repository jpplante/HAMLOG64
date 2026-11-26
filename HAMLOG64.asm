//==============================================================================
// HAMLOG64 - ham radio logger for C64 + REU        (KickAssembler)
// Version V1.22  (the text Settings shows is txt_version, near the bottom of the file)
//
// Keys:   RETURN / CRSR down = next field    CRSR up = previous field
//         CRSR left/right    = move in field DEL = backspace
//         F1 = save QSO   F3 = menu (log, clock, theme, files, clear form)
//         F7 = quit to BASIC
//==============================================================================

//------------------------------------------------------------------------------
// Labels and Constants
//------------------------------------------------------------------------------
.label SCREEN      = $0400
.label COLORRAM    = $d800
.label GETIN       = $ffe4

// zero page pointers (free in BASIC)
.label zp_src      = $fb
.label zp_dst      = $fd
// Duplicate table for the importer: four columns of DH_MAX ..bytes in free RAM above the
// program (not part of the file). The program must end below dh0 - see the check at the end.
.label dh0         = $7000
.label dh1         = $7800
.label dh2         = $8000
.label dh3         = $8800
.label zp_in       = $f9         // read pointer into in_buf (RS-232 area, unused here)
.label zp_out      = $f7         // write pointer into out_buf (RS-232 area, unused here)

// REU registers
.label REU_STATUS  = $df00
.label REU_COMMAND = $df01
.label REU_C64ADDR = $df02        // lo/hi
.label REU_REUADDR = $df04        // lo/mid/bank
.label REU_LENGTH  = $df07        // lo/hi
.label REU_ADDRCTL = $df0a
.const CMD_STASH   = $90          // C64 -> REU, execute now
.const CMD_FETCH   = $91          // REU -> C64, execute now

// Set to false to build a stock-C64-only version with no Ultimate RTC probing.
.const USE_UCI     = true

// Ultimate Command Interface (UCI) registers, cartridge I/O area
.label UCI_CTRL    = $df1c        // write: control
.label UCI_STATUS  = $df1c        // read:  status
.label UCI_CMD     = $df1d        // write: command data
.label UCI_IDENT   = $df1d        // read:  identification ($C9 when present)
.label UCI_RESP    = $df1e        // read:  response data
.label UCI_STATD   = $df1f        // read:  status text data
.const UCI_PUSH    = $01
.const UCI_ACC     = $02
.const UCI_ABORT   = $04
.const UCI_DATMAX  = 140          // ..bytes of command reply kept in uci_dat
.const ST_MAX      = 38           // characters of status text kept (fits one screen row)
.const FN_MAX      = 12           // longest file name the prompt accepts (8.3)
.const ADIF_FIELDS  = 11           // fields written for each QSO (see the at_* tables)
.const NOTES_LEN    = 28           // notes field width (the most that fits next to its label)
.const IMP_FN_MAX   = 26           // longest file name the import prompt accepts
.const IN_CHUNK     = 512          // ..bytes asked for per READ_DATA while importing
.const VAL_MAX      = 32           // longest field value kept while importing
.const TAG_MAX      = 12           // tag names are compared up to this many characters
.const WT_COUNT     = 15           // ADIF tag names the importer recognises
.const DH_MAX       = 2048         // QSOs tracked by the duplicate table (the most recent ones)
.const TITLE_SECONDS = 10          // how long the title screen stays up
.const FLD_MAX     = 28           // longest Ultimate folder path we remember

// Record layout (128 ..bytes). Text fields are PETSCII/ASCII uppercase,
// space padded. Date/time are BCD.
.const RECORD_SIZE = 128
.const RECORD_SHIFT = 7           // log2(RECORD_SIZE): REU address = record number << 7
.const REC_CALL    = 0            // 10
.const REC_DATE    = 10           // 4  BCD CCYYMMDD
.const REC_TIME    = 14           // 2  BCD HHMM UTC
.const REC_RSTS    = 16           // 3
.const REC_RSTR    = 19           // 3
.const REC_BAND    = 22           // 4
.const REC_MODE    = 26           // 4
.const REC_NAME    = 30           // 12
.const REC_GRID    = 42           // 6
.const REC_NOTES   = 48           // 28
.const REC_FREQ    = 76           // 10 text, MHz e.g. 14.074 (ADIF FREQ is MHz)
                                  // 86-127 reserved for future fields

.const NFIELDS     = 9
.const PICK_LEN    = 4            // characters per selector list entry
.const LOG_ROWS    = 8
.const NTHEMES     = 4            // colour themes (see th_* tables)
.const LV_RECS     = 5            // QSOs per page in the full log viewer (4 rows each)

// REU layout: record 0 = header (magic + QSO count), QSO n lives at record n.

//------------------------------------------------------------------------------
// Macros
//------------------------------------------------------------------------------
.macro Puts(row, col, msg) {
    lda #<(SCREEN + row*40 + col)
    sta zp_dst
    lda #>(SCREEN + row*40 + col)
    sta zp_dst+1
    lda #<msg
    sta zp_src
    lda #>msg
    sta zp_src+1
    jsr puts
}

.macro HLine(row) {
    lda #<(SCREEN + row*40)
    sta zp_dst
    lda #>(SCREEN + row*40)
    sta zp_dst+1
    jsr hline
}

// Seg: copy a record field from view_buf to the current row (rb) at a column
.macro Seg(col, off, len) {
    lda #col
    jsr dst_col
    lda #off
    jsr src_set
    ldx #len
    jsr copy_scr
}

// ColorKeys: colour the "Fn" key names of a help string already drawn at (row, col)
.macro ColorKeys(row, col, msg) {
    lda #<msg
    sta zp_src
    lda #>msg
    sta zp_src+1
    lda #<(COLORRAM + row*40 + col)
    sta zp_dst
    lda #>(COLORRAM + row*40 + col)
    sta zp_dst+1
    jsr color_keys
}

.macro SetBuf(addr) {
    lda #<addr
    sta reu_buf
    lda #>addr
    sta reu_buf+1
}

//------------------------------------------------------------------------------
// BASIC stub + entry
//------------------------------------------------------------------------------
:BasicUpstart2(title_set)
title_set:
        cli                     // interrupts must be ON: the KERNAL IRQ is what advances the jiffy clock ($A2)
        jsr init_screen
        ldx #0
title:  lda petscii_title,x
        sta $0400,x
        lda petscii_title+256,x
        sta $0400+256,x
        lda petscii_title+512,x
        sta $0400+512,x
        lda petscii_title+768,x
        sta $0400+768,x
        inx
        bne title
        ldx #0
load_colors:
        lda petscii_colors,x
        sta $d800,x
        lda petscii_colors+256,x
        sta $d800+256,x
        lda petscii_colors+512,x
        sta $d800+512,x
        lda petscii_colors+768,x
        sta $d800+768,x
        inx
        bne load_colors
        jsr wait_title
        jmp start 

wait_title:
wt_drain:
        jsr GETIN               // throw away any key already waiting (the RETURN that ran
        cmp #0                  // the program, for instance), or it would skip the title at once
        bne wt_drain
        ldx $02a6               // 0 = NTSC (60 jiffies a second), 1 = PAL (50)
        lda title_jif_lo,x
        sta wt_cnt
        lda title_jif_hi,x
        sta wt_cnt+1
wt_next:
        lda $a2                 // low byte of the jiffy clock (TI)
wt_tick:
        cmp $a2
        beq wt_tick             // wait until the next jiffy arrives
        jsr GETIN               // checked once per jiffy: any key ends the wait early
        cmp #0
        bne wt_done
        lda wt_cnt              // one jiffy used up: 16-bit count down
        bne wt_dec
        dec wt_cnt+1
wt_dec: dec wt_cnt
        lda wt_cnt
        ora wt_cnt+1
        bne wt_next
wt_done:
        rts

// jiffies to wait for TITLE_SECONDS seconds: NTSC, then PAL
title_jif_lo: .byte <(TITLE_SECONDS*60), <(TITLE_SECONDS*50)
title_jif_hi: .byte >(TITLE_SECONDS*60), >(TITLE_SECONDS*50)
start:
        jsr init_screen
        jsr reu_detect
        bcs reu_ok
        lda #<msg_noreu
        ldx #>msg_noreu
        jsr show_msg
nokey:  jsr GETIN
        beq nokey
        jmp quit

reu_ok:
        jsr init_tod
        jsr init_log
        jsr apply_theme         // theme saved in the REU header
        jsr init_form
        jsr draw_static
        jsr draw_log
        jsr update_count
.if (USE_UCI) {
        lda $028d               // keyboard shift flags
        and #$03                // SHIFT or C= held at startup = skip RTC, ask manually
        bne manual_clock
        jsr auto_clock          // carry clear = clock and date set from Ultimate RTC
        bcc clock_done
}
manual_clock:
        jsr set_clock           // full-screen date and time setup
clock_done:

main_loop:
        jsr redraw_form
        jsr draw_cursor
wait:   jsr show_clock
        jsr GETIN
        beq wait

        // Dispatch: every test is a short branch over a JMP, so handler
        // distance never matters.
        cmp #$88                // F7: Quit (or cancel an edit in progress)
        bne d1
        lda edit_idx
        ora edit_idx+1
        bne d0
        jmp quit
d0:     jsr edit_cancel
        jmp main_loop
d1:     cmp #$85                // F1: Save QSO to Log
        bne d2
        jmp k_save
d2:     cmp #$86                // F3: settings (Set Clock, Set Theme, Backup/Restore)
        bne d3
        jsr settings_menu
        jmp main_loop
d3:     cmp #$89                // F2: View Logbook
        bne d4
        lda edit_idx
        ora edit_idx+1
        bne d3x                 // not while an edit is in progress
        jsr log_view
d3x:    jmp main_loop
d4:     cmp #$0d                // RETURN
        beq d_next
        cmp #$11                // CRSR down
        bne d5
d_next: jmp key_next
d5:     cmp #$91                // CRSR up
        bne d6
        jmp key_prev
d6:     cmp #$1d                // CRSR right
        bne d7
        jmp key_right
d7:     cmp #$9d                // CRSR left
        bne d8
        jmp key_left
d8:     cmp #$14                // DEL
        bne d9
        jmp key_del
d9:     cmp #$20
        bcc ignore
        cmp #$5b                // accept $20-$5A (space, digits, punct, A-Z)
        bcs ignore
        ldx cur_field
        ldy field_n,x           // selector field? (A still holds the key)
        beq d10
        jsr pick_type           // selector: typed character jumps to a matching entry
        jmp main_loop
d10:     ldx cur_field
        ldy field_kind,x        // A still holds the key
        beq d11                 // 0 = any printable character
        cmp #$2e                // numeric field: '.' and digits only
        beq d11
        cmp #$30
        bcc ignore
        cmp #$3a
        bcs ignore
d11:    jsr put_char
        jmp key_right
ignore: jmp main_loop

k_save: jsr save_qso
        jmp main_loop

key_next:
        inc cur_field
        lda cur_field
        cmp #NFIELDS
        bcc kn_done
        lda #0
        sta cur_field
kn_done:
        lda #0
        sta cur_pos
        jmp main_loop

key_prev:
        dec cur_field
        bpl kp_done
        lda #NFIELDS-1
        sta cur_field
kp_done:
        lda #0
        sta cur_pos
        jmp main_loop

key_right:
        ldx cur_field
        lda field_n,x
        beq kr_txt
        lda #1                  // selector: next entry
        jsr pick_move
        jmp main_loop
kr_txt: lda cur_pos
        clc
        adc #1
        cmp field_len,x
        bcs kr_done             // already on last char of field
        sta cur_pos
kr_done:
        jmp main_loop

key_left:
        ldx cur_field
        lda field_n,x
        beq kl_txt
        lda #$ff                // selector: previous entry
        jsr pick_move
        jmp main_loop
kl_txt: lda cur_pos
        beq kl_done
        dec cur_pos
kl_done:
        jmp main_loop

key_del:
        ldx cur_field
        lda field_n,x
        beq kd_txt
        jmp main_loop           // nothing to delete in a selector
kd_txt: lda cur_pos
        beq kd_blank
        dec cur_pos
kd_blank:
        lda #$20
        jsr put_char
        jmp main_loop

quit:
        lda #0
        sta $cc                 // re-enable KERNAL cursor blink
        lda #14
        sta $d020
        lda #6
        sta $d021
        lda #14
        sta $0286
        jmp $e544               // clear screen, returns to BASIC

//------------------------------------------------------------------------------
// Screen setup / drawing
//------------------------------------------------------------------------------
init_screen:
        lda #1
        sta $cc                 // disable KERNAL cursor blink
        jsr $e544               // clear + home
        lda #$20
        sta $0400
        lda #0
        sta $cf                 // cursor not currently displayed
        // falls through into apply_theme

// apply_theme: border/background/text colours from the current theme, fill colour
// RAM with the text colour, and set the two alternating colours of the log viewer
apply_theme:
        ldx theme
        lda th_border,x
        sta $d020
        lda th_bg,x
        sta $d021
        lda th_text,x
        sta lv_cols
        lda th_alt,x
        sta lv_cols+1
        lda th_text,x
        ldx #0
ic_fill:
        sta COLORRAM,x
        sta COLORRAM+$100,x
        sta COLORRAM+$200,x
        sta COLORRAM+$300,x
        inx
        bne ic_fill
        rts

// cycle_theme: next theme, apply it, and remember it in the REU header
cycle_theme:
        ldx theme
        inx
        cpx #NTHEMES
        bcc ct_ok
        ldx #0
ct_ok:  stx theme
        jsr apply_theme
        lda theme
        sta hdr_buf+10
        lda #0
        sta rec_idx
        sta rec_idx+1
        :SetBuf(hdr_buf)
        jmp reu_stash

draw_static:
        :Puts(0, 1, txt_title)
        :HLine(1)
        :Puts(3, 1, txt_call)
        :Puts(4, 1, txt_rsts)
        :Puts(5, 1, txt_rstr)
        :Puts(6, 1, txt_band)
        :Puts(7, 1, txt_mode)
        :Puts(8, 1, txt_freq)
        :Puts(8, 23, txt_mhz)
        :Puts(9, 1, txt_name)
        :Puts(10, 1, txt_grid)
        :Puts(11, 1, txt_notes)
        :HLine(12)
        :Puts(13, 1, txt_recent)
        :Puts(13, 29, txt_qsos)
        :Puts(24, 1, txt_help)
        :ColorKeys(24, 1, txt_help)
        rts

// color_keys: colour every key name ("F" followed by a digit 1-8) in a screen-code
// string with the theme's alternate colour.
//   in: zp_src = the string, zp_dst = colour RAM address of the string's first character
// Colour RAM holds one colour .byte per screen cell, so we only touch those ..bytes.
color_keys:
        ldx theme
        lda th_alt,x
        sta hl_col
        ldy #0
ck_l:   lda (zp_src),y
        beq ck_d                // zero .byte = end of string
        cmp #$06                // screen code of 'F'
        bne ck_n
        iny
        lda (zp_src),y          // the character after the F
        dey
        cmp #$31                // '1'..'8'?
        bcc ck_n
        cmp #$39
        bcs ck_n
        lda hl_col              // colour the F ...
        sta (zp_dst),y
        iny
        sta (zp_dst),y          // ... and the digit
        dey
ck_n:   iny
        bne ck_l
ck_d:   rts

// puts: copy 0-terminated screen-code string (zp_src) to screen (zp_dst)
puts:
        ldy #0
pu_l:   lda (zp_src),y
        beq pu_d
        sta (zp_dst),y
        iny
        bne pu_l
pu_d:   rts

hline:
        ldy #39
        lda #$40
hl_l:   sta (zp_dst),y
        dey
        bpl hl_l
        rts

// show_msg: A/X = lo/hi of 0-terminated string, shown on row 23
show_msg:
        sta zp_src
        stx zp_src+1
        lda #<(SCREEN + 23*40)
        sta zp_dst
        lda #>(SCREEN + 23*40)
        sta zp_dst+1
        ldy #39
        lda #$20
sm_l:   sta (zp_dst),y
        dey
        bpl sm_l
        jmp puts

// pet2scr: PETSCII $20-$5F in A -> screen code
pet2scr:
        cmp #$40
        bcc p2s_d
        sbc #$40                // carry is set here
p2s_d:  rts

// copy_scr: copy X chars from (zp_src) to (zp_dst), converting to screen code
copy_scr:
        ldy #0
cs_l:   lda (zp_src),y
        jsr pet2scr
        sta (zp_dst),y
        iny
        dex
        bne cs_l
        rts

// src_set: zp_src = view_buf + A
src_set:
        clc
        adc #<view_buf
        sta zp_src
        lda #>view_buf
        adc #0
        sta zp_src+1
        rts

// dst_add: zp_dst += A
dst_add:
        clc
        adc zp_dst
        sta zp_dst
        bcc da_d
        inc zp_dst+1
da_d:   rts

// put_bcd: A = BCD .byte, writes 2 digits at (zp_dst),y and advances y
put_bcd:
        pha
        lsr
        lsr
        lsr
        lsr
        ora #$30
        sta (zp_dst),y
        iny
        pla
        and #$0f
        ora #$30
        sta (zp_dst),y
        iny
        rts

//------------------------------------------------------------------------------
// Entry form
//------------------------------------------------------------------------------
init_form:
        ldx #RECORD_SIZE-1
if_l:   lda rec_default,x
        sta rec_buf,x
        dex
        bpl if_l
        lda #0
        sta cur_field
        sta cur_pos
        rts

// after a save: reset call, RST rcvd, name, grid, notes; keep band/mode/RST sent
clear_for_next:
        ldx #REC_CALL
        ldy #REC_CALL+10
        jsr tpl_range
        ldx #REC_RSTR
        ldy #REC_RSTR+3
        jsr tpl_range
        ldx #REC_NAME
        ldy #REC_FREQ           // name, grid, notes; frequency is kept between QSOs
        jsr tpl_range
        lda #0
        sta cur_field
        sta cur_pos
        rts

// copy template .bytes X .. Y-1 into rec_buf
tpl_range:
        sty tr_end
tr_l:   lda rec_default,x
        sta rec_buf,x
        inx
        cpx tr_end
        bne tr_l
        rts

redraw_form:
        ldx #0
rf_field:
        lda field_scr_lo,x
        sta zp_dst
        lda field_scr_hi,x
        sta zp_dst+1
        lda #<rec_buf
        clc
        adc field_off,x
        sta zp_src
        lda #>rec_buf
        adc #0
        sta zp_src+1
        stx tmp_f
        lda field_len,x
        tax
        jsr copy_scr
        ldx tmp_f
        lda field_n,x
        beq rf_nx
        ldy field_len,x         // selector field: show "<>" after it
        iny
        lda #$3c
        sta (zp_dst),y
        iny
        lda #$3e
        sta (zp_dst),y
rf_nx:  inx
        cpx #NFIELDS
        bne rf_field
        rts

draw_cursor:
        ldx cur_field
        lda field_scr_lo,x
        clc
        adc cur_pos
        sta zp_dst
        lda field_scr_hi,x
        adc #0
        sta zp_dst+1
        lda field_n,x
        beq dc_one
        ldy field_len,x         // selector field: reverse the whole field
        dey
dc_all: lda (zp_dst),y
        eor #$80
        sta (zp_dst),y
        dey
        bpl dc_all
        rts
dc_one: ldy #0
        lda (zp_dst),y
        eor #$80                // reverse video
        sta (zp_dst),y
        rts

//------------------------------------------------------------------------------
// selector fields: a field with a list (field_n > 0) is chosen from the list instead
// of typed. CRSR left/right step through the entries; typing a character jumps to
// the next entry that starts with it (press again to move on to the next match).
// Entries are PICK_LEN characters, space padded; the chosen text is copied into
// the record, so logs stay plain text and older records still display.
//------------------------------------------------------------------------------
// pick_find: locate the current field's text in its list.
// Carry clear = found, index in pk_idx. Carry set = not in the list.
pick_find:
        ldx cur_field
        lda #<rec_buf
        clc
        adc field_off,x
        sta zp_dst
        lda #>rec_buf
        adc #0
        sta zp_dst+1
        lda field_lst_lo,x
        sta zp_src
        lda field_lst_hi,x
        sta zp_src+1
        lda #0
        sta pk_idx
pf_ent: ldy #0
pf_cmp: lda (zp_src),y
        cmp (zp_dst),y
        bne pf_next
        iny
        cpy #PICK_LEN
        bne pf_cmp
        clc
        rts
pf_next:
        lda zp_src
        clc
        adc #PICK_LEN
        sta zp_src
        bcc pf_nc
        inc zp_src+1
pf_nc:  inc pk_idx
        lda pk_idx
        ldx cur_field
        cmp field_n,x
        bcc pf_ent
        sec
        rts

// pick_entry: zp_src = address of list entry pk_idx for the current field
pick_entry:
        ldx cur_field
        lda field_lst_lo,x
        sta zp_src
        lda field_lst_hi,x
        sta zp_src+1
        lda pk_idx
        asl
        asl                     // * PICK_LEN (4)
        clc
        adc zp_src
        sta zp_src
        bcc pe_d
        inc zp_src+1
pe_d:   rts

// pick_store: copy entry pk_idx into the record field
pick_store:
        jsr pick_entry
        ldx cur_field
        lda #<rec_buf
        clc
        adc field_off,x
        sta zp_dst
        lda #>rec_buf
        adc #0
        sta zp_dst+1
        ldy #PICK_LEN-1
ps_c:   lda (zp_src),y
        sta (zp_dst),y
        dey
        bpl ps_c
        rts

// pick_move: A = 1 (next) or $ff (previous); wraps around the list
pick_move:
        sta pk_dir
        jsr pick_find
        bcs pm_first            // text not in the list: select entry 0
        lda pk_idx
        clc
        adc pk_dir
        cmp #$ff
        bne pm_hi
        ldx cur_field           // stepped back from entry 0: wrap to the last
        lda field_n,x
        sec
        sbc #1
        jmp pm_set
pm_hi:  ldx cur_field
        cmp field_n,x
        bcc pm_set              // still inside the list
pm_first:
        lda #0                  // stepped past the end: wrap to the first
pm_set: sta pk_idx
        jmp pick_store

// pick_type: A = typed PETSCII character. Select the next entry (after the current
// one, wrapping) whose first character matches; ignore the key if none does.
pick_type:
        sta pk_chr
        jsr pick_find
        ldx cur_field
        bcc pt_have
        lda field_n,x
        sec
        sbc #1
        sta pk_idx              // not in list: pretend we are on the last entry
pt_have:
        lda field_n,x
        sta pk_cnt              // how many entries to examine
pt_next:
        inc pk_idx
        lda pk_idx
        ldx cur_field
        cmp field_n,x
        bcc pt_chk
        lda #0
        sta pk_idx
pt_chk: jsr pick_entry
        ldy #0
        lda (zp_src),y
        cmp pk_chr
        beq pt_hit
        dec pk_cnt
        bne pt_next
        rts                     // nothing starts with that character
pt_hit: jmp pick_store

// put_char: store A into current field at cur_pos
put_char:
        pha
        ldx cur_field
        lda #<rec_buf
        clc
        adc field_off,x
        sta zp_src
        lda #>rec_buf
        adc #0
        sta zp_src+1
        ldy cur_pos
        pla
        sta (zp_src),y
        rts

//------------------------------------------------------------------------------
// Save a QSO
//------------------------------------------------------------------------------
save_qso:
        lda edit_idx            // editing an existing QSO? then F1 rewrites it
        ora edit_idx+1
        beq sq_new
        jmp save_edit
sq_new: lda rec_buf+REC_CALL
        cmp #$20
        bne sq_go
        lda #<msg_nocall
        ldx #>msg_nocall
        jmp show_msg

sq_go:  jsr tod_read
        lda t_hh
        sta rec_buf+REC_TIME
        lda t_mm
        sta rec_buf+REC_TIME+1
        ldx #3                  // stamp date (after tod_read, which may roll it)
sq_dt:  lda cur_date,x
        sta rec_buf+REC_DATE,x
        dex
        bpl sq_dt

        inc qso_count
        bne sq_nc
        inc qso_count+1
sq_nc:  lda qso_count
        sta rec_idx
        lda qso_count+1
        sta rec_idx+1
        :SetBuf(rec_buf)
        jsr reu_stash           // QSO record n -> REU record n

        lda qso_count           // update header record
        sta hdr_buf+4
        lda qso_count+1
        sta hdr_buf+5
        ldx #3                  // remember last-used date in header
sq_hd:  lda cur_date,x
        sta hdr_buf+6,x
        dex
        bpl sq_hd
        lda #0
        sta rec_idx
        sta rec_idx+1
        :SetBuf(hdr_buf)
        jsr reu_stash

        jsr clear_for_next
        jsr draw_log
        jsr update_count
        lda #<msg_saved
        ldx #>msg_saved
        jmp show_msg

//------------------------------------------------------------------------------
// Recent-QSO list (newest first), fetched from the REU
//------------------------------------------------------------------------------
draw_log:
        ldx #0
dl_row: lda view_row_lo,x
        sta zp_dst
        lda view_row_hi,x
        sta zp_dst+1
        ldy #39
        lda #$20
dl_c:   sta (zp_dst),y
        dey
        bpl dl_c
        inx
        cpx #LOG_ROWS
        bne dl_row

        lda #0
        sta log_i
dl_next:
        lda log_i
        cmp #LOG_ROWS
        bcs dl_done
        lda qso_count+1
        bne dl_have             // 256+ QSOs: always have data
        lda log_i
        cmp qso_count
        bcs dl_done             // log_i >= count: no more records
dl_have:
        sec                     // rec_idx = qso_count - log_i
        lda qso_count
        sbc log_i
        sta rec_idx
        lda qso_count+1
        sbc #0
        sta rec_idx+1
        :SetBuf(view_buf)
        jsr reu_fetch
        jsr draw_log_row
        inc log_i
        jmp dl_next
dl_done:
        rts

draw_log_row:
        ldx log_i
        lda view_row_lo,x
        sta zp_dst
        lda view_row_hi,x
        sta zp_dst+1
        lda #REC_CALL
        jsr src_set
        ldx #10
        jsr copy_scr
        lda #11
        jsr dst_add             // -> col 12
        ldy #0
        lda view_buf+REC_TIME
        jsr put_bcd
        lda #$3a                // ':'
        sta (zp_dst),y
        iny
        lda view_buf+REC_TIME+1
        jsr put_bcd
        lda #6
        jsr dst_add             // -> col 18
        lda #REC_RSTS
        jsr src_set
        ldx #3
        jsr copy_scr
        lda #4
        jsr dst_add             // -> col 22
        lda #REC_RSTR
        jsr src_set
        ldx #3
        jsr copy_scr
        lda #4
        jsr dst_add             // -> col 26
        lda #REC_BAND
        jsr src_set
        ldx #4
        jsr copy_scr
        lda #5
        jsr dst_add             // -> col 31
        lda #REC_MODE
        jsr src_set
        ldx #4
        jmp copy_scr

update_count:
        lda qso_count
        sta dec_val
        lda qso_count+1
        sta dec_val+1
        jsr bin2dec
        lda #<(SCREEN + 13*40 + 35)
        sta zp_dst
        lda #>(SCREEN + 13*40 + 35)
        sta zp_dst+1
        ldy #4
uc_l:   lda dec_buf,y
        sta (zp_dst),y
        dey
        bpl uc_l
        rts

// bin2dec: dec_val (16 bit) -> dec_buf[0..4] as screen-code digits
bin2dec:
        ldx #0
bd_digit:
        lda #$30
        sta dec_buf,x
bd_sub: lda dec_val
        sec
        sbc dec_lo,x
        sta dec_tmp
        lda dec_val+1
        sbc dec_hi,x
        bcc bd_next
        sta dec_val+1
        lda dec_tmp
        sta dec_val
        inc dec_buf,x
        jmp bd_sub
bd_next:
        inx
        cpx #5
        bne bd_digit
        rts

//------------------------------------------------------------------------------
// REU
//------------------------------------------------------------------------------
// reu_detect: carry set if REU registers read back what we write.
// Two passes with inverted patterns to rule out open-bus echo.
reu_detect:
        lda #$00
        sta tmp_mask
rd_pass:
        ldx #3
rd_w:   lda reu_pat,x
        eor tmp_mask
        sta REU_C64ADDR,x
        dex
        bpl rd_w
        ldx #3
rd_r:   lda REU_C64ADDR,x
        eor tmp_mask
        cmp reu_pat,x
        bne rd_fail
        dex
        bpl rd_r
        lda tmp_mask
        eor #$ff
        sta tmp_mask
        bne rd_pass             // mask $FF -> run second pass; $00 -> done
        sec
        rts
rd_fail:
        clc
        rts

// reu_setup: program DMA for record rec_idx <-> buffer at reu_buf (64 .bytes)
// REU address = rec_idx * 64 (24 bit)
reu_setup:
        lda rec_idx             // 24-bit value = record number, then shifted left
        sta r_t0
        lda rec_idx+1
        sta r_t1
        lda #0
        sta r_t2
        ldx #RECORD_SHIFT
rs_sh:  asl r_t0
        rol r_t1
        rol r_t2
        dex
        bne rs_sh
        lda r_t0
        sta REU_REUADDR
        lda r_t1
        sta REU_REUADDR+1
        lda r_t2
        sta REU_REUADDR+2
        lda reu_buf
        sta REU_C64ADDR
        lda reu_buf+1
        sta REU_C64ADDR+1
        lda #<RECORD_SIZE       // every transfer is one record
        sta REU_LENGTH
        lda #>RECORD_SIZE
        sta REU_LENGTH+1
        lda #0
        sta REU_ADDRCTL         // increment both addresses
        rts

reu_stash:
        jsr reu_setup
        lda #CMD_STASH
        sta REU_COMMAND         // CPU is halted during the DMA
        rts

reu_fetch:
        jsr reu_setup
        lda #CMD_FETCH
        sta REU_COMMAND
        rts

// init_log: read header (record 0). Valid magic -> keep count, else format.
init_log:
        :SetBuf(hdr_buf)
        lda #0
        sta rec_idx
        sta rec_idx+1
        jsr reu_fetch
        ldx #2                  // first three magic characters: "HLG"
il_m:   lda hdr_buf,x
        cmp hdr_magic,x
        bne il_new
        dex
        bpl il_m
        lda hdr_buf+3
        cmp #$34                // '4' = the current format; anything else is formatted fresh
        bne il_new
il_load:
        lda hdr_buf+4
        sta qso_count
        lda hdr_buf+5
        sta qso_count+1
        lda hdr_buf+6           // 0 = header from older version, no date
        beq il_nd
        ldx #3
il_dt:  lda hdr_buf+6,x
        sta cur_date,x
        dex
        bpl il_dt
il_nd:  lda hdr_buf+10          // saved colour theme (0 = default)
        cmp #NTHEMES
        bcc il_th
        lda #0
il_th:  sta theme
        lda hdr_buf+16          // remembered Ultimate folder (length, then text)
        cmp #FLD_MAX+1
        bcc il_f1
        lda #0
il_f1:  sta fld_len
        ldx #0
il_f2:  lda hdr_buf+17,x
        sta fld_buf,x
        inx
        cpx #FLD_MAX
        bne il_f2
        rts
il_new: ldx #RECORD_SIZE-1
        lda #0
il_z:   sta hdr_buf,x
        dex
        bpl il_z
        ldx #3
il_c:   lda hdr_magic,x
        sta hdr_buf,x
        dex
        bpl il_c
        lda #0
        sta qso_count
        sta qso_count+1
        jmp reu_stash           // rec_idx=0, reu_buf=hdr_buf still set

//------------------------------------------------------------------------------
// Clock (CIA1 TOD)
//------------------------------------------------------------------------------
// TODO: F3 "set clock" prompt. For now the clock starts at 00:00:00 each run.
init_tod:
        lda $dc0e
        and #$7f                // 60 Hz TOD input (use ora #$80 for 50 Hz)
        sta $dc0e
        lda $dc0f
        and #$7f                // writes go to TOD, not alarm
        sta $dc0f
        lda #$12                // 12 AM (bit 7 clear) = 00:xx 24h; halts TOD
        sta $dc0b
        lda #0
        sta $dc0a
        sta $dc09
        sta $dc08               // writing tenths starts the clock
        rts

// tod_read: t_hh (24h BCD), t_mm, t_ss. Reading hours latches; tenths unlatches.
tod_read:
        lda $dc0b
        pha
        and #$1f
        cmp #$12
        bne tr_h
        lda #0                  // 12 AM -> 00, 12 PM -> 00 + $12
tr_h:   sta t_hh
        pla
        bpl tr_am               // bit 7 clear = AM
        sei                     // IRQ keyboard scan must not run in decimal mode
        sed
        lda t_hh
        clc
        adc #$12
        sta t_hh
        cld
        cli
tr_am:  lda $dc0a
        sta t_mm
        lda $dc09
        sta t_ss
        lda $dc08
        lda t_hh                // midnight rollover: 23 -> 00 bumps the date
        cmp last_hh
        beq tr_same
        ldx last_hh
        sta last_hh
        cpx #$23
        bne tr_same
        cmp #$00
        bne tr_same
        jsr date_inc
tr_same:
        rts

show_clock:
        jsr tod_read
        lda #<(SCREEN + 31)
        sta zp_dst
        lda #>(SCREEN + 31)
        sta zp_dst+1
        ldy #0
        lda t_hh
        jsr put_bcd
        lda #$3a
        sta (zp_dst),y
        iny
        lda t_mm
        jsr put_bcd
        lda #$3a
        sta (zp_dst),y
        iny
        lda t_ss
        jsr put_bcd
        lda #$1a                // 'Z'
        sta (zp_dst),y
        jmp show_date

// show_date: YYYY-MM-DD at row 0, col 20
show_date:
        lda #<(SCREEN + 20)
        sta zp_dst
        lda #>(SCREEN + 20)
        sta zp_dst+1
        ldy #0
        lda cur_date
        jsr put_bcd
        lda cur_date+1
        jsr put_bcd
        lda #$2d
        sta (zp_dst),y
        iny
        lda cur_date+2
        jsr put_bcd
        lda #$2d
        sta (zp_dst),y
        iny
        lda cur_date+3
        jmp put_bcd

// bcd2bin: A = BCD .byte -> A = binary
bcd2bin:
        pha
        lsr
        lsr
        lsr
        lsr
        asl
        sta b_t                 // hi*2
        asl
        asl                     // hi*8
        clc
        adc b_t                 // hi*10
        sta b_t
        pla
        and #$0f
        clc
        adc b_t
        rts

// is_leap: carry set if cur_date year is a leap year
is_leap:
        lda cur_date+1
        beq lp_cent
        jsr bcd2bin
        and #3
        beq lp_yes
        clc
        rts
lp_cent:
        lda cur_date            // year xx00: leap only if century divisible by 4
        jsr bcd2bin
        and #3
        beq lp_yes
        clc
        rts
lp_yes: sec
        rts

// dim_get: A = days in cur_date's month (BCD)
dim_get:
        lda cur_date+2
        jsr bcd2bin
        tax
        lda dim_tab,x
        cpx #2
        bne dg_d
        pha
        jsr is_leap
        pla                     // PLA leaves carry alone
        bcc dg_d
        lda #$29
dg_d:   rts

// date_inc: advance cur_date by one day (BCD, with month lengths and leap years)
date_inc:
        sei
        sed
        lda cur_date+3
        clc
        adc #1
        sta cur_date+3
        cld
        cli
        jsr dim_get
        cmp cur_date+3
        bcs di_done             // days-in-month >= day: fine
        lda #1
        sta cur_date+3
        sei
        sed
        lda cur_date+2
        clc
        adc #1
        sta cur_date+2
        cld
        cli
        cmp #$13
        bcc di_done
        lda #1
        sta cur_date+2
        sei
        sed
        lda cur_date+1
        clc
        adc #1
        sta cur_date+1
        lda cur_date
        adc #0
        sta cur_date
        cld
        cli
di_done: rts

// sc_pair: X = index into clk_buf -> A = BCD of clk_buf[X], clk_buf[X+1]
sc_pair:
        lda clk_buf,x
        and #$0f
        asl
        asl
        asl
        asl
        sta c_t
        lda clk_buf+1,x
        and #$0f
        ora c_t
        rts

// sc_date: parse typed YYYYMMDD into cur_date. Carry set = invalid (old date restored)
sc_date:
        ldx #3
sdt_s:  lda cur_date,x
        sta old_date,x
        dex
        bpl sdt_s
        ldx #0
        jsr sc_pair
        sta cur_date
        ldx #2
        jsr sc_pair
        sta cur_date+1
        ldx #4
        jsr sc_pair
        sta cur_date+2
        ldx #6
        jsr sc_pair
        sta cur_date+3
        lda cur_date+2          // month 01-12
        beq sdt_bad
        cmp #$13
        bcs sdt_bad
        lda cur_date+3          // day 01..days-in-month
        beq sdt_bad
        jsr dim_get
        cmp cur_date+3
        bcc sdt_bad
        clc
        rts
sdt_bad:
        ldx #3
sdt_r:  lda old_date,x
        sta cur_date,x
        dex
        bpl sdt_r
        sec
        rts

//------------------------------------------------------------------------------
// Set date and clock: a full screen (settings menu option 1, and asked at start-up
// when no Ultimate clock is found). The twelve digits YYYYMMDDHHMM live in clk_buf;
// clk_pos is the cursor. Digits overwrite, CRSR moves, RETURN sets, U reads the
// Ultimate's own clock, F7 cancels. The live clock stays visible on the top line.
//------------------------------------------------------------------------------
set_clock:
        jsr init_screen
        :Puts(0, 1, txt_sctitle)
        :HLine(1)
        :Puts(4, 3, txt_scdate)
        :Puts(8, 3, txt_sctime)
        :Puts(12, 3, txt_sci1)
        :Puts(13, 3, txt_sci2)
        :Puts(14, 3, txt_sci3)
        :Puts(15, 3, txt_sci4)
        :Puts(17, 3, txt_sci5)
        :Puts(24, 1, txt_schelp)
        :ColorKeys(24, 1, txt_schelp)
        lda #$2d                // '-' between year, month and day
        sta SCREEN + 6*40 + 7
        sta SCREEN + 6*40 + 10
        lda #$3a                // ':' between hours and minutes
        sta SCREEN + 9*40 + 5
        ldx #0                  // start from today's date and the current time
        lda cur_date
        jsr bcd2clk
        lda cur_date+1
        jsr bcd2clk
        lda cur_date+2
        jsr bcd2clk
        lda cur_date+3
        jsr bcd2clk
        jsr tod_read
        lda t_hh
        jsr bcd2clk
        lda t_mm
        jsr bcd2clk
        lda #8                  // cursor on the first digit of the time
        sta clk_pos
sk_loop:
        jsr cx_draw
sk_wait:
        jsr show_clock          // live clock and date, top right
        jsr GETIN
        beq sk_wait
        cmp #$0d                // RETURN: set the clock
        bne sk1
        jmp sk_set
sk1:    cmp #$55                // U: read the Ultimate's clock
        bne sk2
        jmp sk_rtc
sk2:    cmp #$88                // F7: cancel
        bne sk3
        jmp redraw_main
sk3:    cmp #$03                // RUN/STOP: cancel
        bne sk4
        jmp redraw_main
sk4:    cmp #$1d                // CRSR right
        bne sk5
        lda clk_pos
        cmp #11
        bcs sk_ign
        inc clk_pos
        jmp sk_loop
sk5:    cmp #$9d                // CRSR left
        beq sk_lft
        cmp #$14                // DEL: back up one digit
        beq sk_lft
        cmp #$11                // CRSR down: to the time
        beq sk_dn
        cmp #$91                // CRSR up: to the date
        beq sk_up
        cmp #$30                // digits overwrite the digit under the cursor
        bcc sk_ign
        cmp #$3a
        bcs sk_ign
        ldx clk_pos
        sta clk_buf,x
        cpx #11
        bcs sk_lp               // on the last digit: stay there
        inc clk_pos
sk_lp:  jmp sk_loop
sk_ign: jmp sk_wait
sk_lft: lda clk_pos
        bne sk_l1
        jmp sk_wait
sk_l1:  dec clk_pos
        jmp sk_loop
sk_dn:  lda #8
        sta clk_pos
        jmp sk_loop
sk_up:  lda #0
        sta clk_pos
        jmp sk_loop

sk_set: lda #0                  // the clock starts at HH:MM:00 right now
        sta set_ss
        jsr apply_clock
        bcc sk_ok
        lda #<msg_badtime       // invalid date or time: stay on this screen
        ldx #>msg_badtime
        jsr show_msg
        jmp sk_loop
sk_ok:  jsr redraw_main
        lda #<msg_clockset
        ldx #>msg_clockset
        jmp show_msg

sk_rtc: jsr auto_clock          // carry clear = set from the Ultimate's clock
        bcc sk_rok
        lda #<msg_nortc
        ldx #>msg_nortc
        jsr show_msg
        jmp sk_loop
sk_rok: jsr redraw_main
        lda #<msg_rtc
        ldx #>msg_rtc
        jmp show_msg

// cx_draw: show the twelve digits at their screen positions; the cursor digit is reversed
cx_draw:
        ldx #0
cxd_l:  lda cx_lo,x
        sta zp_dst
        lda cx_hi,x
        sta zp_dst+1
        lda clk_buf,x
        cpx clk_pos
        bne cxd_n
        ora #$80                // reverse video = the cursor
cxd_n:  ldy #0
        sta (zp_dst),y
        inx
        cpx #12
        bne cxd_l
        rts

// bcd2clk: A = BCD .byte, X = index into clk_buf. Stores two ASCII digits, X += 2.
bcd2clk:
        pha
        lsr
        lsr
        lsr
        lsr
        ora #$30
        sta clk_buf,x
        inx
        pla
        and #$0f
        ora #$30
        sta clk_buf,x
        inx
        rts

// apply_clock: clk_buf holds YYYYMMDDHHMM (12 digits). Sets cur_date and starts
// the CIA TOD at HH:MM:set_ss. Carry set = invalid.
apply_clock:
        jsr sc_date
        bcs ap_bad
        ldx #8
        jsr sc_pair
        sta c_hh
        ldx #10
        jsr sc_pair
        sta c_mm
        lda c_hh
        cmp #$24
        bcs ap_bad
        lda c_mm
        cmp #$60
        bcs ap_bad
        // 24h BCD -> TOD hours register (12h with PM in bit 7)
        lda c_hh
        beq ap_midnight         // 00 -> 12 AM
        cmp #$12
        beq ap_noon             // 12 -> 12 PM
        bcs ap_pm               // 13-23 -> 1-11 PM
        bcc ap_set              // 01-11 -> AM as-is
ap_midnight:
        lda #$12
        bne ap_set
ap_noon:
        lda #$92
        bne ap_set
ap_pm:  sei
        sed
        sec
        sbc #$12
        cld
        cli
        ora #$80
ap_set: sta $dc0b               // hours first: halts TOD
        lda c_mm
        sta $dc0a
        lda set_ss
        sta $dc09
        lda #0
        sta $dc08               // tenths last: starts TOD
        lda c_hh
        sta last_hh             // so 00:xx doesn't look like a midnight crossing
        clc
        rts
ap_bad: sec
        rts

//------------------------------------------------------------------------------
// Ultimate RTC via the Ultimate Command Interface (UCI)
// Works on Ultimate 64 / C64 Ultimate / Ultimate-II+ with the Command Interface
// enabled in the Ultimate's configuration. On a stock C64 the identification
// register does not read $C9, so everything here fails cleanly and the caller
// falls back to the manual prompt.
//------------------------------------------------------------------------------
// auto_clock: carry clear = set from RTC, carry set = not available / failed
auto_clock:
        jsr uci_get_time
        bcs ac_fail
        jsr ac_parse
        bcs ac_fail
        lda #12
        sta clk_n
        jsr apply_clock
        bcs ac_fail
        lda #<msg_rtc
        ldx #>msg_rtc
        jsr show_msg
        clc
        rts
ac_fail:
        sec
        rts

// ac_parse: validate "yyyy/mm/dd hh:mm:ss" in uci_buf; fill clk_buf (12 digits)
// and set_ss (BCD seconds). Carry set = bad format.
ac_parse:
        ldy #0
acp_s:  ldx ac_seps,y           // index of a separator
        lda uci_buf,x
        cmp ac_seps+1,y         // expected character
        bne acp_bad
        iny
        iny
        cpy #10
        bne acp_s
        ldx #0
acp_d:  ldy ac_src,x
        lda uci_buf,y
        cmp #$30
        bcc acp_bad
        cmp #$3a
        bcs acp_bad
        sta clk_buf,x
        inx
        cpx #12
        bne acp_d
        lda uci_buf+17          // seconds, tens digit 0-5
        cmp #$30
        bcc acp_bad
        cmp #$36
        bcs acp_bad
        and #$0f
        asl
        asl
        asl
        asl
        sta set_ss
        lda uci_buf+18
        cmp #$30
        bcc acp_bad
        cmp #$3a
        bcs acp_bad
        and #$0f
        ora set_ss
        sta set_ss
        clc
        rts
acp_bad:
        sec
        rts

// uci_get_time: DOS_CMD_GET_TIME (target $01, cmd $26) -> 19 chars in uci_buf.
// Carry set = no UCI or no valid reply.
uci_get_time:
        lda #0
        sta uci_idleok
        lda UCI_IDENT
        cmp #$c9
        beq ug_ok
        cmp #$49                // $49 = UCI interrupt pending variant
        bne ug_none
ug_ok:  lda UCI_STATUS
        and #$30                // STATE bits: 00 = idle
        beq ug_idle
        lda #UCI_ABORT          // stale command: abort and wait for idle
        sta UCI_CTRL
        jsr uci_wait_idle
        bcs ug_fail
ug_idle:
        lda #$01                // target 1: Ultimate DOS
        sta UCI_CMD
        lda #$26                // GET_TIME, default format yyyy/mm/dd hh:mm:ss
        sta UCI_CMD
        lda #UCI_PUSH
        sta UCI_CTRL
        jsr uci_wait_data
        bcs ug_fail
        lda UCI_STATUS
        bpl ug_fail             // bit 7 = DATA_AV must be set
        ldx #0
ug_rd:  lda UCI_RESP
        sta uci_buf,x
        inx
        cpx #19
        bne ug_rd
        lda #UCI_ACC            // release the response
        sta UCI_CTRL
        jsr uci_wait_idle       // best effort
        clc
        rts
ug_fail:
        lda #UCI_ABORT
        sta UCI_CTRL
ug_none:
        sec
        rts

// uci_wait_idle: wait for STATE = idle. Carry set on timeout. The timeout is
// uci_tmo units of roughly one second (default 2; file operations ask for more).
uci_wait_idle:
        lda uci_tmo
        sta uci_to2
uwi_o:  lda #0
        sta uci_to
        sta uci_to+1
uwi_l:  lda UCI_STATUS
        and #$30
        beq uwi_ok
        inc uci_to
        bne uwi_l
        inc uci_to+1
        bne uwi_l
        dec uci_to2
        bne uwi_o
        sec
        rts
uwi_ok: clc
        rts

// uci_wait_data: wait for STATE = data last/more (bit 5). Carry set on timeout.
uci_wait_data:
        lda uci_tmo
        sta uci_to2
uwd_o:  lda #0
        sta uci_to
        sta uci_to+1
uwd_l:  lda UCI_STATUS
        and #$20
        bne uwd_ok
        lda uci_idleok          // for a command that may finish with no reply at all
        beq uwd_c               // (WRITE_DATA): back to idle with nothing pending is done too
        lda UCI_STATUS
        and #$31
        beq uwd_ok
uwd_c:  inc uci_to
        bne uwd_l
        inc uci_to+1
        bne uwd_l
        dec uci_to2
        bne uwd_o
        sec
        rts
uwd_ok: clc
        rts

//------------------------------------------------------------------------------
// Full log viewer (F2): LV_RECS QSOs per page, 4 rows each, every field, newest first
//   CRSR down/right/SPACE = older page   CRSR up/left = newer page
//   HOME = newest page                   F7 / RETURN / RUN-STOP = back
//------------------------------------------------------------------------------
log_view:
        jsr init_screen
        :Puts(0, 1, txt_lvtitle)
        :HLine(1)
        :HLine(22)
        :Puts(24, 1, txt_lvhelp)
        lda qso_count
        ora qso_count+1
        bne lv_have
        :Puts(12, 11, txt_nolog)
lv_nokey:
        jsr GETIN
        beq lv_nokey
        jmp lv_exit
lv_have:
        lda lv_resume           // coming back from an edit: keep page and selection
        beq lv_fresh
        lda #0
        sta lv_resume
        jsr calc_pages
        jmp lv_show
lv_fresh:
        lda qso_count
        sta lv_top
        lda qso_count+1
        sta lv_top+1
        lda #1
        sta lv_page
        lda #0
        sta lv_page+1
        sta lv_sel
        jsr calc_pages
lv_show:
        jsr lv_draw_page
lv_key: jsr GETIN
        beq lv_key
        cmp #$88                // F7
        bne lk1
        jmp lv_exit
lk1:    cmp #$03                // RUN/STOP
        bne lk2
        jmp lv_exit
lk2:    cmp #$8a                // F4: next theme
        bne lk3
        jsr cycle_theme
        jmp lv_show
lk3:    cmp #$11                // CRSR down: next record (older)
        bne lk4
        jmp lv_down
lk4:    cmp #$91                // CRSR up: previous record (newer)
        bne lk5
        jmp lv_up
lk5:    cmp #$1d                // CRSR right
        beq lv_t1
        cmp #$20                // SPACE
        beq lv_t1
        cmp #$9d                // CRSR left
        beq lv_t2
        cmp #$13                // HOME
        beq lv_t3
        cmp #$45                // E
        beq lv_t4
        cmp #$0d                // RETURN
        beq lv_t4
        cmp #$44                // D
        beq lv_t5
        cmp #$14                // DEL
        beq lv_t5
        cmp #$46                // F: find a date
        beq lv_t6
        cmp #$4e                // N: next match
        beq lv_t7
        jmp lv_key
lv_t1:  jmp lv_older
lv_t2:  jmp lv_newer
lv_t3:  jmp lv_home
lv_t4:  jmp lv_edit
lv_t5:  jmp lv_delete
lv_t6:  jmp lv_find
lv_t7:  jmp lv_next

// ---- paging: page tops are count, count-LV_RECS, count-2*LV_RECS, ...
lv_older:
        lda lv_top+1
        bne lo_ok
        lda lv_top
        cmp #LV_RECS+1
        bcc lo_no               // top <= LV_RECS: already on the oldest page
lo_ok:  jsr lv_pgdn
        lda #0
        sta lv_sel
        jmp lv_show
lo_no:  jmp lv_key

lv_newer:
        lda lv_top
        cmp qso_count
        bne ln_ok
        lda lv_top+1
        cmp qso_count+1
        bne ln_ok
        jmp lv_key              // already on the newest page
ln_ok:  jsr lv_pgup
        lda #0
        sta lv_sel
        jmp lv_show

lv_home:
        lda qso_count
        sta lv_top
        lda qso_count+1
        sta lv_top+1
        lda #1
        sta lv_page
        lda #0
        sta lv_page+1
        sta lv_sel
        jmp lv_show

lv_pgdn:                        // one page older: top -= LV_RECS, page++
        sec
        lda lv_top
        sbc #LV_RECS
        sta lv_top
        lda lv_top+1
        sbc #0
        sta lv_top+1
        inc lv_page
        bne pgd_d
        inc lv_page+1
pgd_d:   rts

lv_pgup:                        // one page newer: top += LV_RECS, page--
        clc
        lda lv_top
        adc #LV_RECS
        sta lv_top
        lda lv_top+1
        adc #0
        sta lv_top+1
        lda lv_page
        bne pgu_d
        dec lv_page+1
pgu_d:   dec lv_page
        rts

// ---- selection: lv_sel is the highlighted record on this page (0 = first on the page)
lv_down:
        lda lv_sel
        clc
        adc #1
        cmp lv_cnt
        bcs ld_pg               // last record of this page: continue on the next one
        sta lv_sel
        jmp lv_show
ld_pg:  jmp lv_older            // (does nothing on the oldest page)

lv_up:
        lda lv_sel
        beq lu_pg
        dec lv_sel
        jmp lv_show
lu_pg:  lda lv_top
        cmp qso_count
        bne lu_ok
        lda lv_top+1
        cmp qso_count+1
        bne lu_ok
        jmp lv_key              // already at the very first record
lu_ok:  jsr lv_pgup
        lda #LV_RECS-1          // earlier pages are always full
        sta lv_sel
        jmp lv_show

lv_selnum:                      // sel_n = number of the highlighted record
        sec
        lda lv_top
        sbc lv_sel
        sta sel_n
        lda lv_top+1
        sbc #0
        sta sel_n+1
        rts

// ---- edit: load the highlighted record into the entry form (the form in progress
// is set aside and comes back afterwards), return to the entry screen
lv_edit:
        jsr lv_selnum
        lda sel_n
        sta edit_idx
        lda sel_n+1
        sta edit_idx+1
        ldx #RECORD_SIZE-1
le_s:   lda rec_buf,x
        sta form_save,x
        dex
        bpl le_s
        lda edit_idx
        sta rec_idx
        lda edit_idx+1
        sta rec_idx+1
        :SetBuf(rec_buf)
        jsr reu_fetch
        lda #0
        sta cur_field
        sta cur_pos
        lda #1
        sta lv_resume           // F1 / F7 bring us back to this page
        jsr redraw_main
        jmp edit_banner

// ---- delete: ask, then remove the highlighted record and close the gap
lv_delete:
        jsr lv_selnum
        lda sel_n
        sta rec_idx
        lda sel_n+1
        sta rec_idx+1
        :SetBuf(view_buf)
        jsr reu_fetch           // so the question can name the callsign
        lda #<msg_del1
        ldx #>msg_del1
        jsr show_msg
        lda #<(SCREEN + 23*40 + 7)
        sta zp_dst
        lda #>(SCREEN + 23*40 + 7)
        sta zp_dst+1
        lda #REC_CALL
        jsr src_set
        ldx #10
        jsr copy_scr
        :Puts(23, 18, msg_del2)
ldl_k:  jsr GETIN
        beq ldl_k
        cmp #$59                // 'Y'
        beq ldl_go
        lda #<msg_cancel
        ldx #>msg_cancel
        jsr show_msg
        jmp lv_key
ldl_go: lda sel_n
        sta dl_k
        lda sel_n+1
        sta dl_k+1
        jsr delete_rec
        lda #0
        sta fd_len              // record numbers have shifted: the last search no longer applies
        lda qso_count
        ora qso_count+1
        bne ldl_more
        jsr redraw_main         // that was the last QSO: back to the entry screen
        lda #<msg_deleted
        ldx #>msg_deleted
        jmp show_msg
ldl_more:
        jsr calc_pages
        lda lv_pages+1          // if lv_page > lv_pages, step back to the last page
        cmp lv_page+1
        bcc pg_set
        bne pg_ok
        lda lv_pages
        cmp lv_page
        bcs pg_ok
pg_set: lda lv_pages
        sta lv_page
        lda lv_pages+1
        sta lv_page+1
pg_ok:  lda qso_count           // lv_top = count - (lv_page - 1) * LV_RECS
        sta lv_top
        lda qso_count+1
        sta lv_top+1
        sec
        lda lv_page
        sbc #1
        sta dl_t
        lda lv_page+1
        sbc #0
        sta dl_t+1
lt_l:   lda dl_t
        ora dl_t+1
        beq lt_d
        sec
        lda lv_top
        sbc #LV_RECS
        sta lv_top
        lda lv_top+1
        sbc #0
        sta lv_top+1
        lda dl_t
        bne lt_n
        dec dl_t+1
lt_n:   dec dl_t
        jmp lt_l
lt_d:   lda #<msg_deleted
        ldx #>msg_deleted
        jsr show_msg
        jmp lv_show

//------------------------------------------------------------------------------
// Find a date in the logbook (F), and the next match (N).
// The typed date may be a year (YYYY), a month (YYYYMM) or a full date (YYYYMMDD);
// the separators - / . are ignored. The search starts at the newest QSO and goes
// back; the viewer then jumps to the page holding the match and highlights it.
//------------------------------------------------------------------------------
lv_find:
        lda #0
        sta fn_len              // start with an empty entry
        lda #10
        sta fn_max
        lda #<txt_fdprompt
        ldx #>txt_fdprompt
        jsr input_line
        bcc fdf_in
        lda #<msg_cancel
        ldx #>msg_cancel
        jsr show_msg
        jmp lv_key
fdf_in: jsr fd_parse            // fn_buf -> fd_buf / fd_len; carry set = not a usable date
        bcc fdf_ok
        lda #<msg_fdbad
        ldx #>msg_fdbad
        jsr show_msg
        jmp lv_key
fdf_ok: lda #0
        sta fd_n                // a fresh search, not a "next"
        lda qso_count
        sta fd_from
        lda qso_count+1
        sta fd_from+1
        jmp fds_go

lv_next:                        // N: carry on below the last match
        lda fd_len
        bne fdn_1
        lda #<msg_fdnone
        ldx #>msg_fdnone
        jsr show_msg
        jmp lv_key
fdn_1:  lda #1
        sta fd_n
        sec
        lda fd_last
        sbc #1
        sta fd_from
        lda fd_last+1
        sbc #0
        sta fd_from+1
        lda fd_from
        ora fd_from+1
        bne fds_go
        lda #<msg_fdend         // the last match was record 1
        ldx #>msg_fdend
        jsr show_msg
        jmp lv_key

fds_go:  lda #<msg_fdsrch
        ldx #>msg_fdsrch
        jsr show_msg
        jsr fd_scan             // from fd_from down to record 1; carry clear = found (gt_n)
        bcc fdg_hit
        lda fd_n
        bne fdg_end
        lda #<msg_fdmiss
        ldx #>msg_fdmiss
        jsr show_msg
        jmp lv_key
fdg_end:
        lda #<msg_fdend
        ldx #>msg_fdend
        jsr show_msg
        jmp lv_key
fdg_hit:
        lda gt_n
        sta fd_last
        lda gt_n+1
        sta fd_last+1
        jsr lv_goto             // page, top and selection for record gt_n
        lda #<msg_found         // "FOUND #nnnnn  N=NEXT"
        ldx #>msg_found
        jsr show_msg
        lda gt_n
        sta dec_val
        lda gt_n+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_lz
        lda #<(SCREEN + 23*40 + 7)
        sta zp_dst
        lda #>(SCREEN + 23*40 + 7)
        sta zp_dst+1
        jsr put_dec5
        :Puts(23, 12, msg_fn2)
        jmp lv_show

// fd_parse: fn_buf -> fd_buf (digits only) and fd_len (4, 6 or 8). Carry set = invalid.
fd_parse:
        ldx #0
        ldy #0
fp_l:   cpx fn_len
        bcs fp_end
        lda fn_buf,x
        inx
        cmp #$2d                // '-', '/' and '.' are only separators
        beq fp_l
        cmp #$2f
        beq fp_l
        cmp #$2e
        beq fp_l
        cmp #$30
        bcc fp_bad
        cmp #$3a
        bcs fp_bad
        cpy #8
        bcs fp_bad              // more than 8 digits
        sta fd_buf,y
        iny
        jmp fp_l
fp_end: cpy #4
        beq fp_ok
        cpy #6
        beq fp_ok
        cpy #8
        beq fp_ok
fp_bad: lda #0
        sta fd_len              // no usable search: N has nothing to continue
        sec
        rts
fp_ok:  sty fd_len
        clc
        rts

// fd_scan: look at records fd_from, fd_from-1, ... 1 for one whose date starts with the
// typed digits. Carry clear = found, record number in gt_n. Carry set = no (more) matches.
fd_scan:
        lda fd_from
        sta gt_n
        lda fd_from+1
        sta gt_n+1
fs_lp:  lda gt_n
        sta rec_idx
        lda gt_n+1
        sta rec_idx+1
        :SetBuf(view_buf)
        jsr reu_fetch
        jsr fd_match
        bcs fs_hit
        lda gt_n                // next older record
        bne fs_d
        dec gt_n+1
fs_d:   dec gt_n
        lda gt_n
        ora gt_n+1
        bne fs_lp
        sec                     // ran out of records
        rts
fs_hit: clc
        rts

// fd_match: carry set if the date of the record in view_buf starts with fd_buf[0..fd_len-1].
// The date is stored as BCD (CCYYMMDD in four bytes), two digits per byte.
fd_match:
        ldx #0
fdm_l:   cpx fd_len
        bcs fm_yes
        txa
        lsr                     // byte = digit / 2; carry = odd digit (low nibble)
        tay
        lda view_buf+REC_DATE,y
        bcs fm_lo
        lsr
        lsr
        lsr
        lsr                     // even digit: the high nibble
fm_lo:  and #$0f
        ora #$30
        cmp fd_buf,x
        bne fm_no
        inx
        jmp fdm_l
fm_yes: sec
        rts
fm_no:  clc
        rts

// lv_goto: make the viewer show record gt_n: page tops are count, count-LV_RECS, ...
// so d = count - gt_n gives page (d / LV_RECS) and row (d mod LV_RECS).
lv_goto:
        sec
        lda qso_count
        sbc gt_n
        sta gt_d
        lda qso_count+1
        sbc gt_n+1
        sta gt_d+1
        lda qso_count
        sta lv_top
        lda qso_count+1
        sta lv_top+1
        lda #1
        sta lv_page
        lda #0
        sta lv_page+1
gt_lp:  lda gt_d+1              // while d >= LV_RECS: one page older
        bne gt_sub
        lda gt_d
        cmp #LV_RECS
        bcc gt_done
gt_sub: sec
        lda gt_d
        sbc #LV_RECS
        sta gt_d
        lda gt_d+1
        sbc #0
        sta gt_d+1
        jsr lv_pgdn             // top -= LV_RECS, page++
        jmp gt_lp
gt_done:
        lda gt_d
        sta lv_sel
        rts

redraw_main:                    // rebuild the main screen (also used by the file menu)
lv_exit:
        jsr init_screen
        jsr draw_static
        jsr draw_log
        jsr update_count
        lda #<msg_ready
        ldx #>msg_ready
        jmp show_msg

// delete_rec: remove record dl_k. Every later record moves down one place (one at a
// time through view_buf), then the count drops by one and the header is rewritten.
delete_rec:
dr_lp:  lda dl_k+1              // while dl_k < qso_count
        cmp qso_count+1
        bcc dr_do
        bne dr_end
        lda dl_k
        cmp qso_count
        bcs dr_end
dr_do:  clc                     // fetch record dl_k+1 ...
        lda dl_k
        adc #1
        sta rec_idx
        lda dl_k+1
        adc #0
        sta rec_idx+1
        :SetBuf(view_buf)
        jsr reu_fetch
        lda dl_k                // ... and store it at dl_k
        sta rec_idx
        lda dl_k+1
        sta rec_idx+1
        jsr reu_stash
        inc dl_k
        bne dr_lp
        inc dl_k+1
        jmp dr_lp
dr_end: lda qso_count
        bne dr_d1
        dec qso_count+1
dr_d1:  dec qso_count
        jmp stash_header

// edit_banner: "EDIT QSO #nnnnn  F1 SAVE  F7 CANCEL" on row 23
edit_banner:
        lda #<msg_edit1
        ldx #>msg_edit1
        jsr show_msg
        lda edit_idx
        sta dec_val
        lda edit_idx+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_lz
        lda #<(SCREEN + 23*40 + 10)
        sta zp_dst
        lda #>(SCREEN + 23*40 + 10)
        sta zp_dst+1
        ldy #4
eb_l:   lda dec_buf,y
        sta (zp_dst),y
        dey
        bpl eb_l
        :Puts(23, 16, msg_edit2)
        rts

// save_edit: F1 while editing. Write the form back to the same slot, then return
// to the logbook page we came from. Date and time are left as they were.
save_edit:
        lda rec_buf+REC_CALL
        cmp #$20
        bne se_go
        lda #<msg_nocall
        ldx #>msg_nocall
        jmp show_msg
se_go:  lda edit_idx
        sta rec_idx
        lda edit_idx+1
        sta rec_idx+1
        :SetBuf(rec_buf)
        jsr reu_stash
        jsr edit_finish
        jmp log_view            // lv_resume is set: same page, same selection

// edit_cancel: F7 while editing. Nothing is written.
edit_cancel:
        jsr edit_finish
        jmp log_view

// edit_finish: leave edit mode and bring back the entry form that was in progress
edit_finish:
        lda #0
        sta edit_idx
        sta edit_idx+1
        ldx #RECORD_SIZE-1
ef_l:   lda form_save,x
        sta rec_buf,x
        dex
        bpl ef_l
        lda #0
        sta cur_field
        sta cur_pos
        rts

// calc_pages: lv_pages = ceil(qso_count / LV_RECS)   (qso_count >= 1)
calc_pages:
        lda qso_count
        sta cp_t
        lda qso_count+1
        sta cp_t+1
        lda #0
        sta lv_pages
        sta lv_pages+1
cp_l:   inc lv_pages
        bne cp_c
        inc lv_pages+1
cp_c:   lda cp_t+1
        bne cp_sub
        lda cp_t
        cmp #LV_RECS+1
        bcc cp_d                // remaining <= LV_RECS: that was the last page
cp_sub: sec
        lda cp_t
        sbc #LV_RECS
        sta cp_t
        lda cp_t+1
        sbc #0
        sta cp_t+1
        jmp cp_l
cp_d:   rts

// lv_draw_page: header page counter, clear rows 2-22, draw up to LV_RECS records
lv_draw_page:
        lda #<(SCREEN + 22)     // clear right side of header
        sta zp_dst
        lda #>(SCREEN + 22)
        sta zp_dst+1
        ldy #17
        lda #$20
ldp_c:  sta (zp_dst),y
        dey
        bpl ldp_c
        :Puts(0, 22, txt_page)
        lda #<(SCREEN + 27)
        sta zp_dst
        lda #>(SCREEN + 27)
        sta zp_dst+1
        ldy #0
        lda lv_page
        sta dec_val
        lda lv_page+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_out
        lda #$2f                // '/'
        sta (zp_dst),y
        iny
        lda lv_pages
        sta dec_val
        lda lv_pages+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_out

        ldx #0                  // clear record area, rows 2-22
ldp_r:  jsr set_rb
        lda rb
        sta zp_dst
        lda rb+1
        sta zp_dst+1
        ldy #39
        lda #$20
ldp_f:  sta (zp_dst),y
        dey
        bpl ldp_f
        inx
        cpx #LV_RECS*4
        bne ldp_r

        lda #0
        sta lv_k
ldp_n:  lda lv_k
        cmp #LV_RECS
        bcs ldp_d
        sec                     // lv_seq = lv_top - lv_k, must be >= 1
        lda lv_top
        sbc lv_k
        sta lv_seq
        lda lv_top+1
        sbc #0
        sta lv_seq+1
        bcc ldp_d
        ora lv_seq
        beq ldp_d
        lda lv_seq
        sta rec_idx
        lda lv_seq+1
        sta rec_idx+1
        :SetBuf(view_buf)
        jsr reu_fetch
        jsr lv_draw_rec
        inc lv_k
        jmp ldp_n
ldp_d:  lda lv_k
        sta lv_cnt              // records on this page
        beq ldp_x
        lda lv_sel
        cmp lv_cnt
        bcc ldp_h
        lda lv_cnt              // selection past the end (after a delete): last record
        sec
        sbc #1
        sta lv_sel
ldp_h:  jsr lv_hilite
ldp_x:  rts

// lv_hilite: reverse the first row of the selected record
lv_hilite:
        lda lv_sel
        asl
        asl                     // 4 rows per record
        tax
        jsr set_rb
        lda rb
        sta zp_dst
        lda rb+1
        sta zp_dst+1
        ldy #39
lh_l:   lda (zp_dst),y
        eor #$80
        sta (zp_dst),y
        dey
        bpl lh_l
        rts

// lv_draw_rec: draw the record in view_buf (number lv_seq) as record slot lv_k
//   row 1:  #####  CALL       YYYY-MM-DD HH:MMZ
//   row 2:   BAND FREQ         MODE  S:rst R:rst
//   row 3:   NAME              G:GRID
//   row 4:   N:NOTES
lv_draw_rec:
        lda lv_k
        asl
        asl
        sta lv_r                // first row index = 4*k
        lda lv_k
        and #1
        tax
        lda lv_cols,x           // alternate colours per record
        sta lv_col
        jsr lv_color

        ldx lv_r                // ---- row 1
        jsr set_rb
        lda lv_seq
        sta dec_val
        lda lv_seq+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_lz
        lda #0
        jsr dst_col
        ldy #4
lvr_sq: lda dec_buf,y
        sta (zp_dst),y
        dey
        bpl lvr_sq
        :Seg(6, REC_CALL, 10)
        lda #17
        jsr dst_col
        ldy #0
        lda view_buf+REC_DATE
        jsr put_bcd
        lda view_buf+REC_DATE+1
        jsr put_bcd
        lda #$2d                // '-'
        sta (zp_dst),y
        iny
        lda view_buf+REC_DATE+2
        jsr put_bcd
        lda #$2d
        sta (zp_dst),y
        iny
        lda view_buf+REC_DATE+3
        jsr put_bcd
        lda #28
        jsr dst_col
        ldy #0
        lda view_buf+REC_TIME
        jsr put_bcd
        lda #$3a                // ':'
        sta (zp_dst),y
        iny
        lda view_buf+REC_TIME+1
        jsr put_bcd
        lda #$1a                // 'Z'
        sta (zp_dst),y

        ldx lv_r                // ---- row 2: band, frequency, mode, RST
        inx
        jsr set_rb
        :Seg(2, REC_BAND, 4)
        :Seg(7, REC_FREQ, 10)
        :Seg(18, REC_MODE, 4)
        lda #23
        jsr dst_col
        lda #$13                // 'S'
        jsr put_tag
        :Seg(25, REC_RSTS, 3)
        lda #29
        jsr dst_col
        lda #$12                // 'R'
        jsr put_tag
        :Seg(31, REC_RSTR, 3)

        ldx lv_r                // ---- row 3: name, grid
        inx
        inx
        jsr set_rb
        :Seg(2, REC_NAME, 12)
        lda #16
        jsr dst_col
        lda #$07                // 'G'
        jsr put_tag
        :Seg(18, REC_GRID, 6)

        ldx lv_r                // ---- row 4: notes
        inx
        inx
        inx
        jsr set_rb
        lda #2
        jsr dst_col
        lda #$0e                // 'N'
        jsr put_tag
        :Seg(4, REC_NOTES, NOTES_LEN)
        rts

// lv_color: colour RAM for the 4 rows starting at row index lv_r := lv_col
lv_color:
        ldx lv_r
        lda #4
        sta lv_j
lc_row: jsr set_rb
        lda rb
        sta zp_dst
        lda rb+1
        clc
        adc #$d4                // screen $04xx..$07xx -> colour RAM $d8xx..$dbxx
        sta zp_dst+1
        ldy #39
        lda lv_col
lc_fill:
        sta (zp_dst),y
        dey
        bpl lc_fill
        inx
        dec lv_j
        bne lc_row
        rts

// set_rb: rb = screen address of viewer row index X (0 = screen row 2). Keeps X.
set_rb:
        lda lv_row_lo,x
        sta rb
        lda lv_row_hi,x
        sta rb+1
        rts

// dst_col: zp_dst = rb + A
dst_col:
        clc
        adc rb
        sta zp_dst
        lda rb+1
        adc #0
        sta zp_dst+1
        rts

// put_tag: A = screen code letter; writes "<letter>:" at (zp_dst)
put_tag:
        ldy #0
        sta (zp_dst),y
        iny
        lda #$3a
        sta (zp_dst),y
        rts

// dec_lz: blank leading zeros of dec_buf (keeps the last digit)
dec_lz:
        ldx #0
lz_l:   cpx #4
        beq lz_d
        lda dec_buf,x
        cmp #$30
        bne lz_d
        lda #$20
        sta dec_buf,x
        inx
        bne lz_l
lz_d:   rts

// dec_out: write dec_buf at (zp_dst),y without leading zeros; advances y
dec_out:
        ldx #0
do_s:   cpx #4
        beq do_e
        lda dec_buf,x
        cmp #$30
        bne do_e
        inx
        bne do_s
do_e:   lda dec_buf,x
        sta (zp_dst),y
        iny
        inx
        cpx #5
        bne do_e
        rts

//------------------------------------------------------------------------------
// Main menu (F3): everything except saving a QSO and quitting
//------------------------------------------------------------------------------
settings_menu:
mn_draw:
        jsr init_screen
        :Puts(0, 1, txt_mntitle)
        :HLine(1)
        :Puts(4, 3, txt_mn1)
        :Puts(6, 3, txt_mn2)
        :Puts(8, 3, txt_mn3)
        lda #<(SCREEN + 8*40 + 19)      // current theme name after the label
        sta zp_dst
        lda #>(SCREEN + 8*40 + 19)
        sta zp_dst+1
        lda theme
        asl
        asl
        clc
        adc theme               // theme * 5
        tax
        ldy #0
mn_nm:  lda th_names,x
        sta (zp_dst),y
        inx
        iny
        cpy #5
        bne mn_nm
        :Puts(22, 3, txt_version)
        :Puts(24, 1, txt_mnhelp)
mn_key: jsr GETIN
        beq mn_key
        cmp #$31                // 1: Set Clock and Date
        bne mn_k2
        jmp set_clock           // full-screen date and time setup
mn_k2:  cmp #$32                // 2: File Menu for BACKUP/RESTORE Functions
        bne mn_k3
        jmp file_menu
mn_k3:  cmp #$33                // 3: next colour theme (stay in the menu)
        bne mn_k4
        jsr cycle_theme
        jmp mn_draw
mn_k4:  cmp #$88                // F7
        beq mn_exit
        cmp #$0d                // RETURN
        beq mn_exit
        cmp #$03                // RUN/STOP
        beq mn_exit
        jmp mn_key
mn_exit:
        jmp redraw_main

//------------------------------------------------------------------------------
// File menu (menu option 4): backup / restore the whole log through the Ultimate's file system
// The current folder is shown on row 14 (show_path); row 23 is for status messages.
//------------------------------------------------------------------------------
file_menu:
        jsr init_screen
        :Puts(0, 1, txt_fmtitle)
        :HLine(1)
        :Puts(4, 3, txt_fm1)
        :Puts(6, 3, txt_fm2)
        :Puts(8, 3, txt_fm3)
        :Puts(10, 3, txt_fm4)
        :Puts(12, 3, txt_fm5)
        :Puts(24, 1, txt_fmhelp)
        jsr show_path
fm_key: jsr GETIN
        beq fm_key
        cmp #$31                // '1'
        bne fm_k2
        jsr do_backup
        jmp fm_done
fm_k2:  cmp #$32                // '2'
        bne fm_k2b
        jsr do_restore
        jmp fm_done
fm_k2b: cmp #$33                // '3': export an ADIF file
        bne fm_k2c
        jsr do_export
        jmp fm_done
fm_k2c: cmp #$34                // '4': import an ADIF file
        bne fm_k2d
        jsr do_import
        jmp fm_done
fm_k2d: cmp #$35                // '5': choose the folder
        bne fm_k3
        jsr do_folder
        jmp fm_done
fm_k3:  cmp #$88                // F7
        beq fm_exit
        cmp #$0d                // RETURN
        beq fm_exit
        cmp #$03                // RUN/STOP
        beq fm_exit
        jmp fm_key
fm_done:
        jsr show_path           // redraw the folder line (row 14); row 23 message is left alone
        jmp fm_key
fm_exit:
        jmp redraw_main

// do_backup: write the header record and every QSO (record 0 .. count) to a file.
// The Ultimate copies the REU block straight to the file (DOS_CMD_SAVE_REU), so
// the C64 never loops over the data.
do_backup:
        jsr uci_present
        bcc bk_have
        lda #<msg_nouci
        ldx #>msg_nouci
        jmp show_msg
bk_have:
        jsr need_folder         // carry set = message already shown
        bcc bk_nf
        rts
bk_nf:  jsr default_fname
        lda #FN_MAX
        sta fn_max
        lda #<txt_bkprompt
        ldx #>txt_bkprompt
        jsr input_line
        bcc bk_go
        lda #<msg_cancel
        ldx #>msg_cancel
        jmp show_msg
bk_go:  jsr stash_header        // make sure the REU header matches RAM
        jsr cmd_clear
        lda #$01                // target: Ultimate DOS
        jsr cmd_put
        lda #$02                // DOS_CMD_OPEN_FILE
        jsr cmd_put
        lda #$0e                // write | create new | create always (overwrite)
        jsr cmd_put
        jsr cmd_name
        ldx #5
        jsr uci_run
        bcc bk_o1
        jmp bk_err
bk_o1:  lda qso_count           // length = (count + 1) records * 128 .bytes
        sta bl_n
        lda qso_count+1
        sta bl_n+1
        jsr calc_len
        jsr cmd_clear
        lda #$01
        jsr cmd_put
        lda #$22                // DOS_CMD_SAVE_REU
        jsr cmd_put
        lda #0                  // REU address 0 (4 .bytes, LSB first)
        jsr cmd_put
        jsr cmd_put
        jsr cmd_put
        jsr cmd_put
        lda bl_0                // length (4 .bytes, LSB first)
        jsr cmd_put
        lda bl_1
        jsr cmd_put
        lda bl_2
        jsr cmd_put
        lda #0
        jsr cmd_put
        ldx #60
        jsr uci_run
        bcc bk_ok
        jsr err_close
        jmp bk_err
bk_ok:  jsr close_file
        lda #<msg_bkok
        ldx #>msg_bkok
        jsr show_msg
        lda #<(SCREEN + 23*40 + 14)     // append the file name after the message
        sta zp_dst
        lda #>(SCREEN + 23*40 + 14)
        sta zp_dst+1
        ldy #0
bk_nm:  cpy fn_len
        beq bk_dn
        lda fn_buf,y
        jsr asc2scr
        sta (zp_dst),y
        iny
        bne bk_nm
bk_dn:  rts
bk_err: lda st_scr
        bne be_show
        lda #<msg_uerr          // no text from the Ultimate: still say something
        ldx #>msg_uerr
        jmp show_msg
be_show:
        lda #<st_scr            // show the Ultimate's own status text
        ldx #>st_scr
        jmp show_msg

// do_restore: replace the whole log with a backup file. The file is checked before
// anything is overwritten: header magic, then size >= (count + 1) * 128.
do_restore:
        jsr uci_present
        bcc rs_have
        lda #<msg_nouci
        ldx #>msg_nouci
        jmp show_msg
rs_have:
        jsr need_folder
        bcc rs_nf
        rts
rs_nf:  jsr default_fname
        lda #FN_MAX
        sta fn_max
        lda #<txt_rsprompt
        ldx #>txt_rsprompt
        jsr input_line
        bcc rs_open
        lda #<msg_cancel
        ldx #>msg_cancel
        jmp show_msg
rs_open:
        jsr cmd_clear
        lda #$01
        jsr cmd_put
        lda #$02                // DOS_CMD_OPEN_FILE
        jsr cmd_put
        lda #$01                // read
        jsr cmd_put
        jsr cmd_name
        ldx #5
        jsr uci_run
        bcc rs_hd
        jmp bk_err              // e.g. file not found: nothing is open
rs_hd:  jsr cmd_clear           // read the first record (the header)
        lda #$01
        jsr cmd_put
        lda #$04                // DOS_CMD_READ_DATA
        jsr cmd_put
        lda #RECORD_SIZE
        jsr cmd_put
        lda #0
        jsr cmd_put
        lda #1                  // READ_DATA sends no "00,OK" on success
        sta uci_qok
        ldx #5
        jsr uci_run
        bcc rs_h2
        jmp rs_errc
rs_h2:  lda uci_dn
        cmp #RECORD_SIZE
        beq rs_h3
        jmp rs_notbk
rs_h3:  ldx #3                  // "HLG4"
rs_mg:  lda uci_dat,x
        cmp hdr_magic,x
        beq rs_mok
        jmp rs_notbk
rs_mok: dex
        bpl rs_mg
        lda uci_dat+4           // QSO count from the backup's header
        sta bl_n
        lda uci_dat+5
        sta bl_n+1
        jsr calc_len
        jsr cmd_clear           // how big is the file?
        lda #$01
        jsr cmd_put
        lda #$07                // DOS_CMD_FILE_INFO (first 4 ..bytes = size, LSB first)
        jsr cmd_put
        ldx #5
        jsr uci_run
        bcc rs_sz
        jmp rs_errc
rs_sz:  lda uci_dat+3           // size >= expected length?
        bne rs_big
        lda uci_dat+2
        cmp bl_2
        bcc rs_tr
        bne rs_big
        lda uci_dat+1
        cmp bl_1
        bcc rs_tr
        bne rs_big
        lda uci_dat
        cmp bl_0
        bcs rs_big
rs_tr:  jmp rs_short
rs_big: lda #<msg_confirm
        ldx #>msg_confirm
        jsr show_msg
rs_ask: jsr GETIN
        beq rs_ask
        cmp #$59                // 'Y'
        beq rs_go
        jsr close_file
        lda #<msg_cancel
        ldx #>msg_cancel
        jmp show_msg
rs_go:  jsr cmd_clear           // back to the start of the file
        lda #$01
        jsr cmd_put
        lda #$06                // DOS_CMD_FILE_SEEK to 0
        jsr cmd_put
        lda #0
        jsr cmd_put
        jsr cmd_put
        jsr cmd_put
        jsr cmd_put
        ldx #5
        jsr uci_run
        bcc rs_sk
        jmp rs_errc
rs_sk:  jsr cmd_clear
        lda #$01
        jsr cmd_put
        lda #$21                // DOS_CMD_LOAD_REU
        jsr cmd_put
        lda #0                  // REU address 0
        jsr cmd_put
        jsr cmd_put
        jsr cmd_put
        jsr cmd_put
        lda bl_0                // length
        jsr cmd_put
        lda bl_1
        jsr cmd_put
        lda bl_2
        jsr cmd_put
        lda #0
        jsr cmd_put
        ldx #60
        jsr uci_run
        bcc rs_ld
        jmp rs_errc
rs_ld:  jsr close_file
        ldx #3                  // keep today's date and this machine's theme,
rs_sd:  lda cur_date,x          // not the ones stored in the backup
        sta bk_date,x
        dex
        bpl rs_sd
        lda theme
        sta bk_theme
        jsr fld_save
        jsr init_log            // reload count (and date/theme) from the restored header
        ldx #3
rs_rd:  lda bk_date,x
        sta cur_date,x
        dex
        bpl rs_rd
        lda bk_theme
        sta theme
        jsr fld_restore
        jsr stash_header        // header in the REU now matches this session
        jsr apply_theme
        jmp restore_done
rs_notbk:
        jsr close_file
        lda #<msg_notbk
        ldx #>msg_notbk
        jmp show_msg
rs_short:
        jsr close_file
        lda #<msg_short
        ldx #>msg_short
        jmp show_msg
rs_errc:
        jsr err_close
        jmp bk_err

// do_folder: choose the folder on the Ultimate where backups live. It is remembered in
// the REU header. Type a path such as /USB0/HAMLOG (the last folder is created if it
// does not exist). The Ultimate's own file browser shows the exact top-level names.
do_folder:
        jsr uci_present
        bcc fd_have
        lda #<msg_nouci
        ldx #>msg_nouci
        jmp show_msg
fd_have:
        ldx #0                  // pre-fill the editor with the current folder
fd_cp:  cpx fld_len
        bcs fd_cd
        lda fld_buf,x
        sta fn_buf,x
        inx
        bne fd_cp
fd_cd:  lda fld_len
        sta fn_len
        lda #FLD_MAX
        sta fn_max
        lda #<txt_fldprompt
        ldx #>txt_fldprompt
        jsr input_line
        bcc fd_go
        lda #<msg_cancel
        ldx #>msg_cancel
        jmp show_msg
fd_go:  jsr fld_save            // keep the old folder in case the new one fails
        ldx #0
fd_c2:  cpx fn_len
        bcs fd_c3
        lda fn_buf,x
        sta fld_buf,x
        inx
        bne fd_c2
fd_c3:  lda fn_len
        sta fld_len
        jsr apply_folder
        bcc fd_ok
        jsr fld_restore
        lda #<st_scr            // the Ultimate's own error text
        ldx #>st_scr
        jmp show_msg
fd_ok:  jsr stash_header
        lda #<msg_fldsaved
        ldx #>msg_fldsaved
        jsr show_msg            // row 23: confirmation; show_path below only touches row 14
        jmp show_path

// show_path: show the remembered folder on row 14, its own line.
// Row 23 is the status-message line (show_msg / input_line), so anything
// drawn there is wiped by the next backup / error / prompt. Row 14 is
// only touched here, and file_menu redraws it after every operation
// (fm_done), so the folder stays visible while messages come and go.
// Source is fld_buf, the folder HAMLOG will actually use in need_folder,
// not a fresh DOS_CMD_GET_PATH query: no UCI call, no failure mode, and
// it always fits - FLD_MAX 28 chars at col 11 ends at col 38.
// Old code also started the path at col 8, overwriting "FOLDER: " in
// "CURRENT FOLDER: " (16 chars, so the path belonged at col 16).
show_path:
        lda #<(SCREEN + 14*40)
        sta zp_dst
        lda #>(SCREEN + 14*40)
        sta zp_dst+1
        ldy #39
        lda #$20
sp_clr: sta (zp_dst),y          // clear the whole row first, or a shorter
        dey                     // new folder leaves ghost characters behind
        bpl sp_clr
        :Puts(14, 3, txt_fldlabel)
        lda fld_len
        bne sp_have
        :Puts(14, 11, txt_fldnone)
        rts
sp_have:
        lda #<(SCREEN + 14*40 + 11)
        sta zp_dst
        lda #>(SCREEN + 14*40 + 11)
        sta zp_dst+1
        ldy #0
sp_l:   cpy fld_len
        bcs sp_d
        lda fld_buf,y
        jsr asc2scr
        sta (zp_dst),y
        iny
        bne sp_l
sp_d:   rts

// need_folder: enter the remembered folder before a file operation.
// Carry set = failed; the reason is already on screen.
need_folder:
        lda fld_len
        bne nf_go
        lda #<msg_nofolder
        ldx #>msg_nofolder
        jsr show_msg
        sec
        rts
nf_go:  jsr apply_folder
        bcc nf_ok
        lda #<st_scr
        ldx #>st_scr
        jsr show_msg
        sec
        rts
nf_ok:  clc
        rts

// apply_folder: go to the root of the Ultimate's file system (".." a few times; at the
// root that just fails, harmlessly), then enter each component of fld_buf in turn.
// If the LAST component does not exist it is created. Carry set = failed (text in st_scr).
apply_folder:
        lda #6
        sta af_i
af_up:  jsr cmd_clear
        lda #$01
        jsr cmd_put
        lda #$11                // DOS_CMD_CHANGE_DIR
        jsr cmd_put
        lda #$2e                // ".."
        jsr cmd_put
        jsr cmd_put
        ldx #5
        jsr uci_run
        dec af_i
        bne af_up
        lda #0
        sta af_pos
af_nxt: ldy af_pos              // skip separators
        cpy fld_len
        bcs af_ok
        lda fld_buf,y
        cmp #$2f
        bne af_beg
        inc af_pos
        jmp af_nxt
af_beg: sty af_start
af_scan:
        ldy af_pos
        cpy fld_len
        bcs af_cmp
        lda fld_buf,y
        cmp #$2f
        beq af_cmp
        inc af_pos
        jmp af_scan
af_cmp: lda af_pos
        sta af_end
        lda #$11                // enter it
        jsr af_cmd
        ldx #5
        jsr uci_run
        bcc af_nxt
        jsr af_more             // failed: only the last component may be created
        bcs af_fail
        lda #$16                // DOS_CMD_CREATE_DIR
        jsr af_cmd
        ldx #5
        jsr uci_run
        bcs af_fail
        lda #$11
        jsr af_cmd
        ldx #5
        jsr uci_run
        bcs af_fail
        jmp af_nxt
af_ok:  clc
        rts
af_fail:
        sec
        rts

// af_cmd: command = $01, A (CHANGE_DIR / CREATE_DIR), then fld_buf[af_start .. af_end-1]
af_cmd: pha
        jsr cmd_clear
        lda #$01
        jsr cmd_put
        pla
        jsr cmd_put
        ldy af_start
af_cc:  cpy af_end
        bcs af_cd
        lda fld_buf,y
        jsr cmd_put
        iny
        bne af_cc
af_cd:  rts

// af_more: carry set if anything other than '/' follows position af_pos
af_more:
        ldy af_pos
am_l:   cpy fld_len
        bcs am_no
        lda fld_buf,y
        cmp #$2f
        bne am_yes
        iny
        bne am_l
am_no:  clc
        rts
am_yes: sec
        rts

// fld_save / fld_restore: keep fld_len + fld_buf in bk_fld (they are adjacent in memory)
fld_save:
        ldx #FLD_MAX
fs_l:   lda fld_len,x
        sta bk_fld,x
        dex
        bpl fs_l
        rts
fld_restore:
        ldx #FLD_MAX
fr_l:   lda bk_fld,x
        sta fld_len,x
        dex
        bpl fr_l
        rts

// restore_done: "LOG RESTORED: nnnnn QSOS" so you can see the restored count
restore_done:
        lda #<msg_rsok
        ldx #>msg_rsok
        jsr show_msg
        lda qso_count
        sta dec_val
        lda qso_count+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_lz
        lda #<(SCREEN + 23*40 + 14)
        sta zp_dst
        lda #>(SCREEN + 23*40 + 14)
        sta zp_dst+1
        ldy #4
rd_dg:  lda dec_buf,y
        sta (zp_dst),y
        dey
        bpl rd_dg
        :Puts(23, 19, msg_qsos)
        rts

//------------------------------------------------------------------------------
// ADIF export (file menu option 3). Every QSO, oldest first, as one ADIF file written
// to the chosen folder on the Ultimate. The text is built in out_buf and sent in chunks.
//------------------------------------------------------------------------------
do_export:
        jsr uci_present
        bcc ex_have
        lda #<msg_nouci
        ldx #>msg_nouci
        jmp show_msg
ex_have:
        lda qso_count
        ora qso_count+1
        bne ex_some
        lda #<msg_noqso
        ldx #>msg_noqso
        jmp show_msg
ex_some:
        jsr need_folder         // carry set = message already shown
        bcc ex_nf
        rts
ex_nf:  lda #4                  // default name ends in .ADI
        sta fn_ext
        jsr default_fname
        lda #0
        sta fn_ext
        lda #FN_MAX
        sta fn_max
        lda #<txt_exprompt
        ldx #>txt_exprompt
        jsr input_line
        bcc ex_go
        lda #<msg_cancel
        ldx #>msg_cancel
        jmp show_msg
ex_go:  jsr cmd_clear           // open for writing, overwriting any old file
        lda #$01
        jsr cmd_put
        lda #$02                // DOS_CMD_OPEN_FILE
        jsr cmd_put
        lda #$0e
        jsr cmd_put
        jsr cmd_name
        ldx #5
        jsr uci_run
        bcc ex_o1
        jmp bk_err
ex_o1:  lda #<out_buf           // the file starts with the ADIF header
        sta zp_out
        lda #>out_buf
        sta zp_out+1
        lda #<adif_hdr
        sta zp_src
        lda #>adif_hdr
        sta zp_src+1
        jsr out_str
        lda #1
        sta ex_n
        lda #0
        sta ex_n+1
ex_lp:  lda qso_count+1         // while ex_n <= qso_count
        cmp ex_n+1
        bcc ex_end
        bne ex_do
        lda qso_count
        cmp ex_n
        bcc ex_end
ex_do:  lda ex_n
        sta rec_idx
        lda ex_n+1
        sta rec_idx+1
        :SetBuf(view_buf)
        jsr reu_fetch
        jsr adif_record
        lda zp_out+1
        cmp #(>out_buf)+1
        bcc ex_nfl              // fewer than 256 ..bytes waiting
        jsr flush_out
        bcc ex_nfl
        jmp ex_fail
ex_nfl: lda ex_n                // progress on every 16th record
        and #$0f
        bne ex_nx
        jsr ex_progress
ex_nx:  inc ex_n
        bne ex_lp
        inc ex_n+1
        jmp ex_lp
ex_end: jsr flush_out           // whatever is left
        bcc ex_cl
        jmp ex_fail
ex_cl:  jsr close_file
        lda #<msg_exok
        ldx #>msg_exok
        jsr show_msg
        lda qso_count
        sta dec_val
        lda qso_count+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_lz
        lda #<(SCREEN + 23*40 + 9)
        sta zp_dst
        lda #>(SCREEN + 23*40 + 9)
        sta zp_dst+1
        jsr put_dec5
        :Puts(23, 14, msg_exq)
        lda #<(SCREEN + 23*40 + 21)
        sta zp_dst
        lda #>(SCREEN + 23*40 + 21)
        sta zp_dst+1
        ldy #0
ex_nm:  cpy fn_len
        beq ex_dn
        lda fn_buf,y
        jsr asc2scr
        sta (zp_dst),y
        iny
        bne ex_nm
ex_dn:  rts
ex_fail:
        jsr err_close
        jmp bk_err

// ex_progress: "EXPORTING nnnnn OF nnnnn"
ex_progress:
        lda #<msg_exp1
        ldx #>msg_exp1
        jsr show_msg
        lda ex_n
        sta dec_val
        lda ex_n+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_lz
        lda #<(SCREEN + 23*40 + 10)
        sta zp_dst
        lda #>(SCREEN + 23*40 + 10)
        sta zp_dst+1
        jsr put_dec5
        :Puts(23, 15, msg_exp2)
        lda qso_count
        sta dec_val
        lda qso_count+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_lz
        lda #<(SCREEN + 23*40 + 19)
        sta zp_dst
        lda #>(SCREEN + 23*40 + 19)
        sta zp_dst+1
        jmp put_dec5

put_dec5:                       // dec_buf (5 digits) -> (zp_dst)
        ldy #4
pd5_l:  lda dec_buf,y
        sta (zp_dst),y
        dey
        bpl pd5_l
        rts

// out_put: append A to out_buf (A and Y are preserved)
out_put:
        sty op_y
        ldy #0
        sta (zp_out),y
        inc zp_out
        bne op_d
        inc zp_out+1
op_d:   ldy op_y
        rts

// out_str: append the zero-terminated string at zp_src
out_str:
        ldy #0
os_l:   lda (zp_src),y
        beq os_d
        jsr out_put
        iny
        bne os_l
os_d:   rts

// flush_out: send everything waiting in out_buf to the open file. Carry set = failed.
flush_out:
        sec
        lda zp_out
        sbc #<out_buf
        sta out_len
        lda zp_out+1
        sbc #>out_buf
        sta out_len+1
        ora out_len
        bne fo_go
        clc                     // nothing waiting
        rts
fo_go:  lda #<out_buf           // the buffer is empty again as soon as it has been sent
        sta zp_out
        lda #>out_buf
        sta zp_out+1
        // falls through into uci_write

// uci_write: DOS_CMD_WRITE_DATA with out_len ..bytes from out_buf.
// Carry clear = written. Like uci_run, but the command is too long for uci_cmd.
uci_write:
        ldx #10
        stx uci_tmo
        lda UCI_IDENT
        cmp #$c9
        beq uw_ok1
        cmp #$49
        beq uw_ok1
        jmp ur_none
uw_ok1: lda UCI_STATUS
        and #$30
        beq uw_idle
        lda #UCI_ABORT
        sta UCI_CTRL
        jsr uci_wait_idle
        bcc uw_idle
        jmp ur_fail
uw_idle:
        lda #$01                // target: Ultimate DOS
        sta UCI_CMD
        lda #$05                // DOS_CMD_WRITE_DATA
        sta UCI_CMD
        lda #0                  // two dummy ..bytes keep the data long-word aligned
        sta UCI_CMD
        sta UCI_CMD
        lda #<out_buf
        sta zp_src
        lda #>out_buf
        sta zp_src+1
        ldy #0
uw_lp:  lda out_len
        ora out_len+1
        beq uw_go
        lda (zp_src),y
        sta UCI_CMD
        iny
        bne uw_nc
        inc zp_src+1
uw_nc:  lda out_len
        bne uw_dc
        dec out_len+1
uw_dc:  dec out_len
        jmp uw_lp
uw_go:  lda #1
        sta uci_qok             // WRITE_DATA's documentation lists no "00,OK" on success
        sta uci_idleok          // and it may return to idle without any reply
        jmp ur_push

// adif_record: the record in view_buf -> ADIF text in out_buf, ending in <EOR>
adif_record:
        lda #0
        sta xf_n
ar_lp:  ldx xf_n
        jsr emit_field
        inc xf_n
        lda xf_n
        cmp #ADIF_FIELDS
        bne ar_lp
        lda #<adif_eor
        sta zp_src
        lda #>adif_eor
        sta zp_src+1
        jmp out_str

// emit_field: X = field number (see at_* tables). Writes <TAG:length>value and a space,
// or nothing at all if the field is empty.
emit_field:
        lda at_tag_lo,x
        sta xf_tag
        lda at_tag_hi,x
        sta xf_tag+1
        lda at_kind,x
        sta xf_kind
        lda at_off,x
        sta xf_off
        lda at_len,x
        sta xf_max
        lda xf_kind
        cmp #2
        bcs xf_bcd
        ldx xf_off              // text: copy the field into fld_tmp
        ldy #0
xf_c:   lda view_buf,x
        sta fld_tmp,y
        inx
        iny
        cpy xf_max
        bne xf_c
        lda xf_kind
        beq xf_trim             // kind 0: as stored
        ldy #0                  // kind 1: upper-case letters become lower case
xf_l:   lda fld_tmp,y
        cmp #$41
        bcc xf_ln
        cmp #$5b
        bcs xf_ln
        ora #$20
        sta fld_tmp,y
xf_ln:  iny
        cpy xf_max
        bne xf_l
        jmp xf_trim
xf_bcd: lda xf_kind             // kinds 2 and 3: BCD ..bytes -> ASCII digits
        cmp #2
        bne xf_b0
        ldx xf_off              // a date whose century ..byte is 0 was never set: leave it out
        lda view_buf,x
        bne xf_b0
        jmp xf_skip
xf_b0:  lda xf_max
        sta xf_cnt
        ldx xf_off
        ldy #0
xf_b1:  lda view_buf,x
        pha
        lsr
        lsr
        lsr
        lsr
        ora #$30
        sta fld_tmp,y
        iny
        pla
        and #$0f
        ora #$30
        sta fld_tmp,y
        iny
        inx
        dec xf_cnt
        bne xf_b1
        sty xf_max              // number of digits
xf_trim:
        ldy xf_max              // drop trailing spaces
xt_l:   bne xt_nz
        jmp xf_skip             // nothing left: the field is empty
xt_nz:  lda fld_tmp-1,y
        cmp #$20
        bne xt_d
        dey
        jmp xt_l
xt_d:   sty xf_len
        lda #$3c                // '<'
        jsr out_put
        lda xf_tag
        sta zp_src
        lda xf_tag+1
        sta zp_src+1
        jsr out_str             // tag name
        lda #$3a                // ':'
        jsr out_put
        lda xf_len              // length as decimal (1..28)
        cmp #10
        bcc xf_d1
        cmp #20
        bcc xf_t1
        lda #$32                // tens digit 2
        ldx #20
        jmp xf_t2
xf_t1:  lda #$31                // tens digit 1
        ldx #10
xf_t2:  stx xf_ty
        jsr out_put
        lda xf_len
        sec
        sbc xf_ty
        clc
        adc #$30
        jmp xf_d2
xf_d1:  clc
        adc #$30
xf_d2:  jsr out_put
        lda #$3e                // '>'
        jsr out_put
        ldy #0
xf_o:   lda fld_tmp,y
        jsr out_put
        iny
        cpy xf_len
        bne xf_o
        lda #$20                // space between fields
        jsr out_put
xf_skip:
        rts

//------------------------------------------------------------------------------
// ADIF import (file menu option 4). Reads an ADIF file from the chosen Ultimate folder
// as a ..byte stream and appends its QSOs to the log. The file is read 512 ..bytes at a
// time; fields we do not store are skipped by their declared length, so only about
// 5% of a typical QRZ export is actually looked at. A QSO is skipped if the log already
// holds one with the same call, date, time and band (the most recent DH_MAX QSOs are
// checked, so re-importing the same file adds nothing).
//------------------------------------------------------------------------------
do_import:
        jsr uci_present
        bcc di_have
        lda #<msg_nouci
        ldx #>msg_nouci
        jmp show_msg
di_have:
        jsr need_folder
        bcc di_nf
        rts
di_nf:  lda #0
        sta fn_len              // no default name: you type the file's name
        lda #IMP_FN_MAX
        sta fn_max
        lda #<txt_improm
        ldx #>txt_improm
        jsr input_line
        bcc di_go
        lda #<msg_cancel
        ldx #>msg_cancel
        jmp show_msg
di_go:  jsr cmd_clear
        lda #$01
        jsr cmd_put
        lda #$02                // DOS_CMD_OPEN_FILE
        jsr cmd_put
        lda #$01                // for reading
        jsr cmd_put
        jsr cmd_name
        ldx #5
        jsr uci_run
        bcc di_o1
        jmp bk_err
di_o1:  lda #0
        sta imp_ok
        sta imp_ok+1
        sta imp_skip
        sta imp_skip+1
        sta imp_err
        sta imp_stop
        sta imp_tick
        sta in_left
        sta in_left+1
        jsr dupe_preload
        jsr new_record
        jsr imp_loop
        lda imp_err
        bne di_bad
        jsr close_file
        jmp di_fin
di_bad: jsr err_close           // keeps the Ultimate's error text
di_fin: jsr stash_header        // the count now includes everything imported
        lda imp_ok
        ora imp_ok+1
        ora imp_skip
        ora imp_skip+1
        bne di_cnt              // something was read: show the summary
        lda imp_err
        beq di_none
        jmp bk_err              // an error and nothing imported: show the Ultimate's text
di_none:
        lda #<msg_noimp
        ldx #>msg_noimp
        jmp show_msg
di_cnt: lda #<msg_imok
        ldx #>msg_imok
        jsr show_msg
        lda imp_ok
        sta dec_val
        lda imp_ok+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_lz
        lda #<(SCREEN + 23*40 + 9)
        sta zp_dst
        lda #>(SCREEN + 23*40 + 9)
        sta zp_dst+1
        jsr put_dec5
        :Puts(23, 14, msg_imp2)
        lda imp_skip
        sta dec_val
        lda imp_skip+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_lz
        lda #<(SCREEN + 23*40 + 23)
        sta zp_dst
        lda #>(SCREEN + 23*40 + 23)
        sta zp_dst+1
        jmp put_dec5

// imp_progress: "IMPORTING nnnnn SKIPPED nnnnn"; RUN/STOP or F7 stops the import
imp_progress:
        lda #<msg_imp1
        ldx #>msg_imp1
        jsr show_msg
        lda imp_ok
        sta dec_val
        lda imp_ok+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_lz
        lda #<(SCREEN + 23*40 + 10)
        sta zp_dst
        lda #>(SCREEN + 23*40 + 10)
        sta zp_dst+1
        jsr put_dec5
        :Puts(23, 15, msg_imp2)
        lda imp_skip
        sta dec_val
        lda imp_skip+1
        sta dec_val+1
        jsr bin2dec
        jsr dec_lz
        lda #<(SCREEN + 23*40 + 24)
        sta zp_dst
        lda #>(SCREEN + 23*40 + 24)
        sta zp_dst+1
        jsr put_dec5
        jsr GETIN
        cmp #$03
        beq ipg_stop
        cmp #$88
        bne ipg_d
ipg_stop:
        lda #1
        sta imp_stop
ipg_d:  rts

// imp_loop: tag by tag through the file. Wanted fields are read and stored in imp_buf;
// <EOR> finishes the QSO; <EOH> (end of header) starts afresh; everything else is skipped.
imp_loop:
ip_find:
        lda imp_stop
        bne ip_end
        jsr read_tag
        bcs ip_end
        jsr match_tag           // X = field number, $ff = not one of ours
        cpx #$ff
        beq ip_skv
        cpx #13
        beq ip_eor
        cpx #14
        beq ip_eoh
        stx cur_f
        jsr read_value
        bcs ip_end
        ldx cur_f
        jsr apply_field
        jmp ip_find
ip_skv: lda vl
        sta sn_n
        lda vl+1
        sta sn_n+1
        jsr skip_n
        bcs ip_end
        jmp ip_find
ip_eor: jsr fin_rec
        jmp ip_find
ip_eoh: jsr new_record
        jmp ip_find
ip_end: rts

// read_tag: find the next '<' and read the whole tag. Name -> tag_buf (upper case, tag_n
// characters), length -> vl. Carry set = end of file.
read_tag:
        lda #0
        sta tag_n
        sta vl
        sta vl+1
rt_find:
        jsr get_byte
        bcs rt_eof
        cmp #$3c
        bne rt_find
rt_name:
        jsr get_byte
        bcs rt_eof
        cmp #$3a                // ':' the length follows
        beq rt_col
        cmp #$3e                // '>' end of tag
        beq rt_ok
        ldx tag_n
        cpx #TAG_MAX
        bcs rt_name             // too long to be one of ours: just consume it
        cmp #$61
        bcc rt_ts
        cmp #$7b
        bcs rt_ts
        and #$df                // a-z -> A-Z
rt_ts:  sta tag_buf,x
        inc tag_n
        jmp rt_name
rt_col: jsr read_len
        bcs rt_eof
rt_ok:  clc
        rts
rt_eof: sec
        rts

// read_len: the decimal length after "<NAME:", then an optional ":type", up to the '>'
read_len:
rl_lp:  jsr get_byte
        bcs rl_eof
        cmp #$3e
        beq rl_ok
        cmp #$3a
        beq rl_typ
        sec
        sbc #$30
        cmp #10
        bcs rl_lp               // not a digit: ignore it
        sta ip_dg
        jsr mul10add
        jmp rl_lp
rl_typ: jsr get_byte            // skip the type indicator
        bcs rl_eof
        cmp #$3e
        bne rl_typ
rl_ok:  clc
        rts
rl_eof: sec
        rts

// mul10add: vl = vl * 10 + ip_dg
mul10add:
        lda vl
        asl
        sta ip_mt
        lda vl+1
        rol
        sta ip_mt+1             // ip_mt = vl * 2
        asl vl
        rol vl+1
        asl vl
        rol vl+1
        asl vl
        rol vl+1                // vl = vl * 8
        clc
        lda vl
        adc ip_mt
        sta vl
        lda vl+1
        adc ip_mt+1
        sta vl+1
        clc
        lda vl
        adc ip_dg
        sta vl
        bcc m10_d
        inc vl+1
m10_d:  rts

// match_tag: compare tag_buf with the wanted names. X = index, or $ff if none matches.
match_tag:
        ldx #0
mt_nx:  lda wt_len,x
        cmp tag_n
        bne mt_no
        lda wt_lo,x
        sta zp_src
        lda wt_hi,x
        sta zp_src+1
        ldy #0
mt_cm:  lda (zp_src),y
        cmp tag_buf,y
        bne mt_no
        iny
        cpy tag_n
        bne mt_cm
        rts
mt_no:  inx
        cpx #WT_COUNT
        bne mt_nx
        ldx #$ff
        rts

// get_..byte: the next ..byte of the file in A. Carry set = end of file (or a read error).
get_byte:
        lda in_left
        ora in_left+1
        bne gb_ok
        jsr refill
        bcs gb_eof
gb_ok:  ldy #0
        lda (zp_in),y
        tax
        inc zp_in
        bne gb_1
        inc zp_in+1
gb_1:   lda in_left
        bne gb_2
        dec in_left+1
gb_2:   dec in_left
        txa
        clc
        rts
gb_eof: sec
        rts

// skip_n: skip sn_n ..bytes of the file (whole stretches of the buffer at a time)
skip_n:
sn_lp:  lda sn_n
        ora sn_n+1
        bne sn_go
        jmp sn_done
sn_go:  lda in_left
        ora in_left+1
        bne sn_have
        jsr refill
        bcc sn_have
        jmp sn_eof
sn_have:
        lda in_left+1           // take = the smaller of in_left and sn_n
        cmp sn_n+1
        bcc sn_all
        bne sn_part
        lda in_left
        cmp sn_n
        bcc sn_all
sn_part:                        // sn_n <= in_left: step over exactly sn_n ..bytes
        clc
        lda zp_in
        adc sn_n
        sta zp_in
        lda zp_in+1
        adc sn_n+1
        sta zp_in+1
        sec
        lda in_left
        sbc sn_n
        sta in_left
        lda in_left+1
        sbc sn_n+1
        sta in_left+1
        lda #0
        sta sn_n
        sta sn_n+1
        jmp sn_lp
sn_all: sec                     // in_left < sn_n: use up the rest of the buffer
        lda sn_n
        sbc in_left
        sta sn_n
        lda sn_n+1
        sbc in_left+1
        sta sn_n+1
        lda #0
        sta in_left
        sta in_left+1
        jmp sn_lp
sn_done:
        clc
        rts
sn_eof: sec
        rts

// refill: read the next chunk into in_buf. Carry set = no more data (end of file or error;
// imp_err tells them apart).
refill:
        jsr uci_read
        bcs rfl_err
        lda in_left
        ora in_left+1
        beq rfl_eof
        lda #<in_buf
        sta zp_in
        lda #>in_buf
        sta zp_in+1
        clc
        rts
rfl_err:
        lda #1
        sta imp_err
rfl_eof:
        lda #0
        sta in_left
        sta in_left+1
        sec
        rts

// uci_read: DOS_CMD_READ_DATA for IN_CHUNK ..bytes into in_buf; in_left = ..bytes received.
// Carry clear = OK. (READ_DATA sends no "00,OK" when all is well, hence uci_qok.)
uci_read:
        ldx #10
        stx uci_tmo
        lda #0
        sta uci_idleok
        lda UCI_IDENT
        cmp #$c9
        beq urd_1
        cmp #$49
        beq urd_1
        jmp ur_none
urd_1:  lda UCI_STATUS
        and #$30
        beq urd_2
        lda #UCI_ABORT
        sta UCI_CTRL
        jsr uci_wait_idle
        bcc urd_2
        jmp ur_fail
urd_2:  lda #$01                // target: Ultimate DOS
        sta UCI_CMD
        lda #$04                // DOS_CMD_READ_DATA
        sta UCI_CMD
        lda #<IN_CHUNK
        sta UCI_CMD
        lda #>IN_CHUNK
        sta UCI_CMD
        lda #1
        sta uci_qok
        lda #UCI_PUSH
        sta UCI_CTRL
        jsr uci_wait_data
        bcc urd_3
        jmp ur_fail
urd_3:  lda #<in_buf
        sta zp_src
        lda #>in_buf
        sta zp_src+1
        lda #0
        sta in_left
        sta in_left+1
        tay
urd_rd: lda UCI_STATUS
        bpl urd_end             // bit 7 (DATA_AV) clear: that was everything
        lda UCI_RESP
        ldx in_left+1
        cpx #>IN_CHUNK
        bcs urd_rd              // more than we asked for (cannot happen): drop it
        sta (zp_src),y
        iny
        bne urd_c
        inc zp_src+1
urd_c:  inc in_left
        bne urd_rd
        inc in_left+1
        jmp urd_rd
urd_end:
        jmp ur_st               // status text, release the reply, set the carry

// read_value: read the next vl ..bytes of the file into val_buf, cleaned (see clean_char).
// val_n = characters kept (at most VAL_MAX). Carry set = end of file.
read_value:
        lda #0
        sta val_n
rv_lp:  lda vl
        ora vl+1
        beq rv_done
        jsr get_byte
        bcs rv_eof
        jsr clean_char
        bcs rv_dec              // dropped
        ldx val_n
        cpx #VAL_MAX
        bcs rv_dec
        sta val_buf,x
        inc val_n
rv_dec: lda vl
        bne rv_d1
        dec vl+1
rv_d1:  dec vl
        jmp rv_lp
rv_done:
        clc
        rts
rv_eof: sec
        rts

// clean_char: a file ..byte -> a character the C64 can show and store.
//   lower case -> upper case; control characters -> space; `{|}~ and DEL -> '?';
//   UTF-8: each multi-..byte character becomes one '?' (its continuation ..bytes are dropped).
// Carry set = drop this ..byte.
clean_char:
        cmp #$20
        bcs cc_1
        lda #$20
        clc
        rts
cc_1:   cmp #$80
        bcs cc_hi
        cmp #$61
        bcc cc_2
        cmp #$7b
        bcs cc_q                // $7B-$7F
        and #$df                // a-z -> A-Z
        clc
        rts
cc_2:   cmp #$60
        beq cc_q
        clc                     // $20-$5F as they are
        rts
cc_q:   lda #$3f
        clc
        rts
cc_hi:  cmp #$c0
        bcc cc_drop             // continuation ..byte
        lda #$3f                // lead ..byte of a multi-..byte character
        clc
        rts
cc_drop:
        sec
        rts

// apply_field: X = field number. Stores val_buf (val_n characters) into imp_buf.
apply_field:
        lda ih_kind,x
        sta ia_k
        lda ih_off,x
        sta ia_off
        lda ih_max,x
        sta ia_max
        lda #0
        sta ia_s
        lda ia_k
        bne ia_k1
        jmp ia_copy             // 0: plain text
ia_k1:  cmp #3
        bcc ia_k12
        bne ia_k4
        jmp ia_sub              // 3: submode
ia_k4:  cmp #4
        bne ia_k5
        jmp ia_name             // 4: name (first word)
ia_k5:  cmp #5
        bne ia_k6
        jmp ia_band             // 5: band (must fit 4 characters)
ia_k6:  cmp #6
        bne ia_k7
        jmp ia_cmt              // 6: comment
ia_k7:  jmp ia_note             // 7: notes (only if there is no comment)
ia_k12: jmp ia_date             // 1 and 2: date and time

ia_copy:                        // val_buf[ia_s ..] -> imp_buf+ia_off, at most ia_max characters
        ldx ia_s
        ldy ia_off
        lda #0
        sta ia_c
ic_l:   cpx val_n
        bcs ic_d
        lda ia_c
        cmp ia_max
        bcs ic_d
        lda val_buf,x
        sta imp_buf,y
        inx
        iny
        inc ia_c
        jmp ic_l
ic_d:   rts

ia_date:                        // ia_max = number of BCD ..bytes (4 for the date, 2 for the time)
        lda ia_max
        asl
        sta ia_need
        lda val_n
        cmp ia_need
        bcs ia_d1
        rts                     // too few digits
ia_d1:  ldx #0
        ldy #0
ia_dl:  jsr ia_bcd
        bcs ia_dx
        sta ia_tmp,y
        inx
        inx
        iny
        cpy ia_max
        bne ia_dl
        ldx #0
        ldy ia_off
ia_dm:  lda ia_tmp,x
        sta imp_buf,y
        inx
        iny
        cpx ia_max
        bne ia_dm
ia_dx:  rts

ia_bcd:                         // A = BCD of the two digits at val_buf[X]; carry set = not digits
        lda val_buf,x
        sec
        sbc #$30
        cmp #10
        bcs ib_bad
        asl
        asl
        asl
        asl
        sta ia_t
        lda val_buf+1,x
        sec
        sbc #$30
        cmp #10
        bcs ib_bad
        ora ia_t
        clc
        rts
ib_bad: sec
        rts

ia_sub:                         // SUBMODE -> sub_buf (used when MODE is MFSK)
        ldx #3
        lda #$20
ias_c:  sta sub_buf,x
        dex
        bpl ias_c
        lda val_n
        beq ias_x
        ldx #0
ias_l:  cpx val_n
        bcs ias_d
        cpx #4
        bcs ias_d
        lda val_buf,x
        sta sub_buf,x
        inx
        jmp ias_l
ias_d:  lda #1
        sta sub_n
ias_x:  rts

ia_name:                        // first word only: QRZ gives full names, we have 12 characters
        ldx #0
ian_s:  cpx val_n
        bcs ian_x
        lda val_buf,x
        cmp #$20
        bne ian_f
        inx
        jmp ian_s
ian_f:  stx ia_s
ian_e:  cpx val_n
        bcs ian_d
        lda val_buf,x
        cmp #$20
        beq ian_d
        cmp #$2c                // a comma ends it too
        beq ian_d
        inx
        jmp ian_e
ian_d:  stx val_n               // cut the value at the end of the first word
        jmp ia_copy
ian_x:  rts

ia_band:                        // 1 to 4 characters, else we cannot store it (e.g. 1.25M)
        lda val_n
        beq iab_x
        cmp #5
        bcs iab_x
        jmp ia_copy
iab_x:  rts

ia_cmt: lda #1                  // COMMENT wins over NOTES
        sta got_cmt
        jsr ia_clr
        jmp ia_copy
ia_note:
        lda got_cmt
        bne ian_x
        jsr ia_clr
        jmp ia_copy
ia_clr: ldy #REC_NOTES
        ldx #NOTES_LEN
        lda #$20
icl_l:  sta imp_buf,y
        iny
        dex
        bne icl_l
        rts

// new_record: imp_buf = a blank record (the template)
new_record:
        ldx #RECORD_SIZE-1
nr_l:   lda rec_default,x
        sta imp_buf,x
        dex
        bpl nr_l
        lda #0
        sta sub_n
        sta got_cmt
        rts

// fin_rec: <EOR> reached. Finish imp_buf and append it to the log unless it has no
// callsign or looks like a duplicate.
fin_rec:
        lda sub_n               // MODE "MFSK" with a submode (FT4 ...): the submode is the real mode
        beq fin_a
        ldx #3
fin_m:  lda imp_buf+REC_MODE,x
        cmp mfsk_txt,x
        bne fin_a
        dex
        bpl fin_m
        ldx #3
fin_s:  lda sub_buf,x
        sta imp_buf+REC_MODE,x
        dex
        bpl fin_s
fin_a:  lda imp_buf+REC_CALL
        cmp #$20
        bne fin_c
        jmp fin_sk              // no callsign: skip it
fin_c:  lda #<imp_buf
        sta zp_src
        lda #>imp_buf
        sta zp_src+1
        jsr mk_key
        jsr fp_make
        jsr dupe_check
        bcc fin_new
fin_sk: inc imp_skip
        bne fin_end
        inc imp_skip+1
        jmp fin_end
fin_new:
        inc qso_count
        bne fin_n1
        inc qso_count+1
fin_n1: lda qso_count
        sta rec_idx
        lda qso_count+1
        sta rec_idx+1
        :SetBuf(imp_buf)
        jsr reu_stash
        jsr dh_add              // the new QSO is part of the log from now on
        inc imp_ok
        bne fin_n2
        inc imp_ok+1
fin_n2: lda imp_ok
        and #$1f                // every 32 QSOs: save the header (so a stop or crash loses little)
        bne fin_end
        jsr stash_header
fin_end:
        inc imp_tick
        lda imp_tick
        and #7
        bne fin_r
        jsr imp_progress
fin_r:  jmp new_record

// mk_key / mk_key2: the duplicate key of the record at zp_src -> kb / kb2:
// call (10), date and time (6), band (4)
mk_key: ldy #9
mk_a:   lda (zp_src),y
        sta kb,y
        dey
        bpl mk_a
        ldy #REC_TIME+1
mk_b:   lda (zp_src),y
        sta kb,y
        dey
        cpy #REC_DATE-1
        bne mk_b
        ldy #REC_BAND+3
mk_c:   lda (zp_src),y
        sta kb-6,y
        dey
        cpy #REC_BAND-1
        bne mk_c
        rts
mk_key2:
        ldy #9
mk2_a:  lda (zp_src),y
        sta kb2,y
        dey
        bpl mk2_a
        ldy #REC_TIME+1
mk2_b:  lda (zp_src),y
        sta kb2,y
        dey
        cpy #REC_DATE-1
        bne mk2_b
        ldy #REC_BAND+3
mk2_c:  lda (zp_src),y
        sta kb2-6,y
        dey
        cpy #REC_BAND-1
        bne mk2_c
        rts

// The duplicate table: four columns (dh0..dh3) of DH_MAX ..bytes, one 4-..byte "fingerprint"
// per QSO of the log, entry j belonging to record dh_base+j. Scanning one column is fast;
// a fingerprint that matches all four columns is confirmed against the real record.
// fp_make: fingerprint of the record at zp_src -> fpn
//   0: sum of the callsign ..bytes  1: minute  2: day  3: first two band characters added
fp_make:
        lda #0
        clc
        ldy #9
fm_l:   adc (zp_src),y
        dey
        bpl fm_l
        sta fpn
        ldy #REC_TIME+1
        lda (zp_src),y
        sta fpn+1
        ldy #REC_DATE+3
        lda (zp_src),y
        sta fpn+2
        ldy #REC_BAND
        lda (zp_src),y
        ldy #REC_BAND+1
        clc
        adc (zp_src),y
        sta fpn+3
        rts

// dh_add: append fpn to the table (if there is room)
dh_add: lda dh_n+1
        cmp #>DH_MAX
        bcs dha_x               // full: the newest QSOs are simply not tracked
        ldx #0
dha_c:  lda dh_n
        sta zp_dst
        lda dh_col,x
        clc
        adc dh_n+1
        sta zp_dst+1
        ldy #0
        lda fpn,x
        sta (zp_dst),y
        inx
        cpx #4
        bne dha_c
        inc dh_n
        bne dha_x
        inc dh_n+1
dha_x:  rts

// dupe_check: carry set if the log already holds a QSO with the key in kb (fingerprint in fpn)
dupe_check:
        lda #0
        sta dc_p
dck_pg: lda dc_p
        cmp dh_n+1
        beq dck_lst
        bcs dck_no              // past the last page
        ldy #0                  // a full page: 256 entries (y counts down from 0 = 256)
        jmp dck_sc
dck_lst:
        ldy dh_n                // the last, partly filled page
        beq dck_no
dck_sc: lda #<dh0
        sta zp_dst
        lda #>dh0
        clc
        adc dc_p
        sta zp_dst+1
dck_y:  dey
        lda (zp_dst),y
        cmp fpn
        bne dck_n
        sty dc_y
        jsr dck_cand
        bcs dck_yes
        ldy dc_y
dck_n:  cpy #0
        bne dck_y
        inc dc_p
        jmp dck_pg
dck_yes:
        sec
        rts
dck_no: clc
        rts

// dck_cand: entry dc_p*256+dc_y matched in column 0. Check the other three columns, then
// fetch the real record and compare keys. Carry set = the same QSO.
dck_cand:
        ldx #1
dcc_c:  lda dc_y
        sta zp_out
        lda dh_col,x
        clc
        adc dc_p
        sta zp_out+1
        ldy #0
        lda (zp_out),y
        cmp fpn,x
        bne dcc_no
        inx
        cpx #4
        bne dcc_c
        clc                     // record number = dh_base + entry number
        lda dh_base
        adc dc_y
        sta rec_idx
        lda dh_base+1
        adc dc_p
        sta rec_idx+1
        :SetBuf(view_buf)
        jsr reu_fetch
        lda #<view_buf
        sta zp_src
        lda #>view_buf
        sta zp_src+1
        jsr mk_key2
        ldy #19
dcc_k:  lda kb2,y
        cmp kb,y
        bne dcc_no
        dey
        bpl dcc_k
        sec                     // all 20 ..bytes equal
        rts
dcc_no: clc
        rts

// dupe_preload: fingerprints of the last DH_MAX QSOs already in the log
dupe_preload:
        lda #0
        sta dh_n
        sta dh_n+1
        lda #1
        sta dh_base
        lda #0
        sta dh_base+1
        lda qso_count
        ora qso_count+1
        bne dp_go
        jmp dp_done
dp_go:  sec                     // dh_base = count - (DH_MAX-1), but at least 1
        lda qso_count
        sbc #<(DH_MAX-1)
        sta dp_i
        lda qso_count+1
        sbc #>(DH_MAX-1)
        sta dp_i+1
        bcc dp_lp0              // the log is smaller than the table: start at record 1
        lda dp_i
        ora dp_i+1
        beq dp_lp0
        lda dp_i
        sta dh_base
        lda dp_i+1
        sta dh_base+1
dp_lp0: lda dh_base
        sta dp_i
        lda dh_base+1
        sta dp_i+1
dp_lp:  lda dp_i
        sta rec_idx
        lda dp_i+1
        sta rec_idx+1
        :SetBuf(view_buf)
        jsr reu_fetch
        lda #<view_buf
        sta zp_src
        lda #>view_buf
        sta zp_src+1
        jsr fp_make
        jsr dh_add
        inc dp_i
        bne dp_c
        inc dp_i+1
dp_c:   lda qso_count+1         // continue while dp_i <= qso_count
        cmp dp_i+1
        bcc dp_done
        bne dp_lp
        lda qso_count
        cmp dp_i
        bcs dp_lp
dp_done:
        rts

// stash_header: refresh the header record in RAM (count, date, theme) and write it to the REU
stash_header:
        lda qso_count
        sta hdr_buf+4
        lda qso_count+1
        sta hdr_buf+5
        ldx #3
sh_d:   lda cur_date,x
        sta hdr_buf+6,x
        dex
        bpl sh_d
        lda theme
        sta hdr_buf+10
        lda fld_len
        sta hdr_buf+16
        ldx #0
sh_f:   lda fld_buf,x
        sta hdr_buf+17,x
        inx
        cpx #FLD_MAX
        bne sh_f
        lda #0
        sta rec_idx
        sta rec_idx+1
        :SetBuf(hdr_buf)
        jmp reu_stash

// calc_len: bl_0..bl_2 = (bl_n + 1) * RECORD_SIZE  (24-bit, LSB first)
calc_len:
        lda bl_n
        clc
        adc #1
        sta bl_0
        lda bl_n+1
        adc #0
        sta bl_1
        lda #0
        sta bl_2
        ldx #RECORD_SHIFT
cl_l:   asl bl_0
        rol bl_1
        rol bl_2
        dex
        bne cl_l
        rts

// default_fname: fn_buf = "HLyymmdd.BAK" from today's date (ASCII, 12 characters)
default_fname:
        lda #$48                // 'H'
        sta fn_buf
        lda #$4c                // 'L'
        sta fn_buf+1
        ldx #1                  // cur_date+1..+3 = yy mm dd (BCD)
        ldy #2
df_l:   lda cur_date,x
        lsr
        lsr
        lsr
        lsr
        ora #$30
        sta fn_buf,y
        iny
        lda cur_date,x
        and #$0f
        ora #$30
        sta fn_buf,y
        iny
        inx
        cpx #4
        bne df_l
        lda fn_ext              // 0 = ".BAK", 4 = ".ADI"
        clc
        adc #4
        sta df_end
        ldx fn_ext
df_e:   lda bak_ext,x
        sta fn_buf,y
        iny
        inx
        cpx df_end
        bne df_e
        lda #12
        sta fn_len
        rts

// input_line: show the prompt (A/X = zero-terminated screen-code string) on row 23 and
// let the user edit fn_buf / fn_len (at most fn_max). Letters, digits, . - /; DEL backs up;
// RETURN accepts (carry clear); F7 or RUN/STOP cancels (carry set).
input_line:
        jsr show_msg
        sty fn_col              // puts leaves Y = prompt length
        lda fn_max              // caller sets fn_max (longest accepted entry)
        clc
        adc #1
        sta fn_lim
in_draw:
        lda #<(SCREEN + 23*40)
        clc
        adc fn_col
        sta zp_dst
        lda #>(SCREEN + 23*40)
        adc #0
        sta zp_dst+1
        ldy #0
ind_l:  cpy fn_len
        bcc ind_ch
        lda #$20
        bne ind_p
ind_ch: lda fn_buf,y
        jsr asc2scr
ind_p:  cpy fn_len
        bne ind_s
        ora #$80                // reversed = the cursor
ind_s:  sta (zp_dst),y
        iny
        cpy fn_lim
        bne ind_l
in_key: jsr GETIN
        beq in_key
        cmp #$0d
        beq in_ok
        cmp #$88
        beq in_cancel
        cmp #$03
        beq in_cancel
        cmp #$14
        beq in_del
        cmp #$2d                // '-'
        beq in_add
        cmp #$2e                // '.'
        beq in_add
        cmp #$2f                // '/'
        beq in_add
        cmp #$30
        bcc in_key
        cmp #$3a
        bcc in_add              // digits
        cmp #$41
        bcc in_key
        cmp #$5b
        bcc in_add              // letters A-Z
        cmp #$5f                // the left-arrow key types '_' (ASCII $5F)
        bne in_key
in_add: ldx fn_len
        cpx fn_max
        bcs in_key
        sta fn_buf,x
        inc fn_len
        jmp in_draw
in_del: lda fn_len
        beq in_key
        dec fn_len
        jmp in_draw
in_ok:  lda fn_len
        beq in_key              // an empty name is not accepted
        clc
        rts
in_cancel:
        sec
        rts

// asc2scr: ASCII/PETSCII in A -> screen code (also lower case, for Ultimate status text)
asc2scr:
        cmp #$61
        bcc a2s_p
        cmp #$7b
        bcs a2s_p
        sec
        sbc #$60
        rts
a2s_p:  jmp pet2scr

//------------------------------------------------------------------------------
// Ultimate DOS commands: uci_cmd buffer -> uci_run -> status text in st_scr
//------------------------------------------------------------------------------
cmd_clear:
        lda #0
        sta uci_clen
        sta uci_qok             // see uci_run: only READ_DATA may answer with no status text
        rts

cmd_put:                        // append A to the command (A is preserved)
        ldx uci_clen
        sta uci_cmd,x
        inc uci_clen
        rts

cmd_name:                       // append fn_buf (fn_len characters) to the command
        ldy #0
cn_l:   cpy fn_len
        beq cn_d
        lda fn_buf,y
        jsr cmd_put
        iny
        bne cn_l
cn_d:   rts

close_file:
        jsr cmd_clear
        lda #$01
        jsr cmd_put
        lda #$03                // DOS_CMD_CLOSE_FILE
        jsr cmd_put
        ldx #5
        jmp uci_run

err_close:                      // close the file but keep the error text in st_scr
        ldx #ST_MAX+1
ec_s:   lda st_scr,x
        sta st_keep,x
        dex
        bpl ec_s
        jsr close_file
        ldx #ST_MAX+1
ec_r:   lda st_keep,x
        sta st_scr,x
        dex
        bpl ec_r
        rts

// uci_present: carry clear if the Ultimate Command Interface answers
uci_present:
        lda UCI_IDENT
        cmp #$c9
        beq up_yes
        cmp #$49
        beq up_yes
        sec
        rts
up_yes: clc
        rts

// set_st: copy the zero-terminated string at A/X into st_scr
set_st:
        sta zp_src
        stx zp_src+1
        ldy #0
ss_l:   lda (zp_src),y
        sta st_scr,y
        beq ss_d
        iny
        bne ss_l
ss_d:   rts

// uci_run: send the command in uci_cmd (uci_clen ..bytes) to the Ultimate, wait for the
// reply and read it. X = timeout in units of about a second.
//   reply data  -> uci_dat (first UCI_DATMAX ..bytes), count in uci_dn
//   status text -> st_scr (screen codes, zero-terminated)
//   carry clear = status "00,..." (OK); carry set = error / no answer (text in st_scr)
uci_run:
        stx uci_tmo
        lda #0
        sta uci_idleok
        lda UCI_IDENT
        cmp #$c9
        beq ur_ok1
        cmp #$49
        beq ur_ok1
        jmp ur_none
ur_ok1: lda UCI_STATUS
        and #$30
        beq ur_idle
        lda #UCI_ABORT          // leftover state: abort and wait for idle
        sta UCI_CTRL
        jsr uci_wait_idle
        bcc ur_idle
        jmp ur_fail
ur_idle:
        ldx #0
ur_send:
        cpx uci_clen
        beq ur_push
        lda uci_cmd,x
        sta UCI_CMD
        inx
        bne ur_send
ur_push:
        lda #UCI_PUSH
        sta UCI_CTRL
        jsr uci_wait_data
        bcc ur_got
        jmp ur_fail
ur_got: lda #0
        sta uci_dn
ur_rd:  lda UCI_STATUS
        bpl ur_st               // bit 7 (DATA_AV) clear: no more data
        lda UCI_RESP
        ldx uci_dn
        cpx #UCI_DATMAX
        bcs ur_rd               // buffer full: read and drop the rest
        sta uci_dat,x
        inc uci_dn
        jmp ur_rd
ur_st:  ldy #0
ur_sl:  lda UCI_STATUS
        and #$40                // bit 6 (STAT_AV): status text available
        beq ur_sd
        lda UCI_STATD
        cmp #$20
        bcc ur_sl               // skip control characters
        cpy #ST_MAX
        bcs ur_sl
        jsr asc2scr
        sta st_scr,y
        iny
        jmp ur_sl
ur_sd:  lda #0
        sta st_scr,y
        lda #UCI_ACC            // release the reply
        sta UCI_CTRL
        jsr uci_wait_idle
        lda #2
        sta uci_tmo
        lda st_scr
        beq ur_emp              // no status text at all
        cmp #$30
        bne ur_bad
        lda st_scr+1
        cmp #$30
        bne ur_bad
        clc
        rts
ur_emp: lda uci_qok             // READ_DATA stays quiet when everything is fine;
        beq ur_bad              // for any other command, silence is not success
        clc
        rts
ur_bad: sec
        rts
ur_fail:
        lda #UCI_ABORT
        sta UCI_CTRL
        lda #2
        sta uci_tmo
        lda #<msg_timeout
        ldx #>msg_timeout
        jsr set_st
        sec
        rts
ur_none:
        lda #2
        sta uci_tmo
        lda #<msg_nouci
        ldx #>msg_nouci
        jsr set_st
        sec
        rts

//------------------------------------------------------------------------------
// Data
//------------------------------------------------------------------------------
// Field tables (order = form order top to bottom)
field_off:  .byte REC_CALL, REC_RSTS, REC_RSTR, REC_BAND, REC_MODE, REC_FREQ, REC_NAME, REC_GRID, REC_NOTES
field_len:  .byte 10, 3, 3, 4, 4, 10, 12, 6, NOTES_LEN
// selector lists: entry count per field (0 = free text) and the list address.
// BAND (field 3) and MODE (field 4) are selectors; to make another field a selector,
// give it a list below and fill in its three table entries.
field_n:      .byte 0, 0, 0, (band_end-band_list)/PICK_LEN, (mode_end-mode_list)/PICK_LEN, 0, 0, 0, 0
field_lst_lo: .byte 0, 0, 0, <band_list, <mode_list, 0, 0, 0, 0
field_lst_hi: .byte 0, 0, 0, >band_list, >mode_list, 0, 0, 0, 0
// Input filter per field: 0 = any printable character, 1 = numeric (digits and '.')
field_kind:   .byte 0, 0, 0, 0, 0, 1, 0, 0, 0
field_scr_lo: .fill NFIELDS, <(SCREEN + (3+i)*40 + 12)
field_scr_hi: .fill NFIELDS, >(SCREEN + (3+i)*40 + 12)

view_row_lo:  .fill LOG_ROWS, <(SCREEN + (14+i)*40 + 1)
view_row_hi:  .fill LOG_ROWS, >(SCREEN + (14+i)*40 + 1)

// full-log viewer: screen rows 2..22, and per-record colours
lv_row_lo:  .fill 21, <(SCREEN + (2+i)*40)
lv_row_hi:  .fill 21, >(SCREEN + (2+i)*40)
lv_cols:    .byte 5, 13
dec_lo: .byte <10000, <1000, <100, <10, <1
dec_hi: .byte >10000, >1000, >100, >10, >1

// Themes: 0 = C64 classic, 1 = white on black, 2 = green on black, 3 = amber on black
// Colour names are KickAssembler built-ins: BLACK WHITE RED CYAN PURPLE GREEN BLUE
// YELLOW ORANGE BROWN LIGHT_RED DARK_GRAY GRAY LIGHT_GREEN LIGHT_BLUE LIGHT_GRAY
// To add a theme: one entry in each table below, one name in th_names, bump NTHEMES.
th_border:  .byte BLUE, BLACK, BLACK, BLACK
th_bg:      .byte BLUE, BLACK, BLACK, BLACK
th_text:    .byte LIGHT_BLUE, WHITE, GREEN, ORANGE
th_alt:     .byte CYAN, LIGHT_GRAY, LIGHT_GREEN, YELLOW
// UCI time string "yyyy/mm/dd hh:mm:ss": (index, expected ASCII) separator pairs
ac_seps:   .byte 4, $2f, 7, $2f, 10, $20, 13, $3a, 16, $3a
// source index of each of the 12 digits YYYYMMDDHHMM
ac_src:    .byte 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15
// screen address of each of the 12 clock digits: date on row 6, time on row 9
cx_lo:     .byte <(SCREEN+6*40+3), <(SCREEN+6*40+4), <(SCREEN+6*40+5), <(SCREEN+6*40+6)
           .byte <(SCREEN+6*40+8), <(SCREEN+6*40+9), <(SCREEN+6*40+11), <(SCREEN+6*40+12)
           .byte <(SCREEN+9*40+3), <(SCREEN+9*40+4), <(SCREEN+9*40+6), <(SCREEN+9*40+7)
cx_hi:     .byte >(SCREEN+6*40+3), >(SCREEN+6*40+4), >(SCREEN+6*40+5), >(SCREEN+6*40+6)
           .byte >(SCREEN+6*40+8), >(SCREEN+6*40+9), >(SCREEN+6*40+11), >(SCREEN+6*40+12)
           .byte >(SCREEN+9*40+3), >(SCREEN+9*40+4), >(SCREEN+9*40+6), >(SCREEN+9*40+7)
// ADIF fields in the order they are written. kind: 0 = text as stored, 1 = text in
// lower case (band), 2 = BCD date (4 ..bytes -> 8 digits), 3 = BCD time (2 ..bytes -> 4 digits).
// For kinds 2 and 3 the length is the number of BCD ..bytes.
at_tag_lo: .byte <at_call, <at_qd, <at_ton, <at_band, <at_freq, <at_mode, <at_rsts, <at_rstr, <at_name, <at_grid, <at_cmt
at_tag_hi: .byte >at_call, >at_qd, >at_ton, >at_band, >at_freq, >at_mode, >at_rsts, >at_rstr, >at_name, >at_grid, >at_cmt
at_off:    .byte REC_CALL, REC_DATE, REC_TIME, REC_BAND, REC_FREQ, REC_MODE, REC_RSTS, REC_RSTR, REC_NAME, REC_GRID, REC_NOTES
at_len:    .byte 10, 4, 2, 4, 10, 4, 3, 3, 12, 6, NOTES_LEN
at_kind:   .byte 0, 2, 3, 1, 0, 0, 0, 0, 0, 0, 0
// Import: the tag names we recognise, in field-number order, and what to do with each.
// 0 CALL 1 QSO_DATE 2 TIME_ON 3 BAND 4 MODE 5 SUBMODE 6 FREQ 7 RST_SENT 8 RST_RCVD
// 9 NAME 10 GRIDSQUARE 11 COMMENT 12 NOTES 13 EOR 14 EOH
// kind: 0 text, 1/2 date/time (BCD), 3 submode, 4 first word, 5 band, 6 comment, 7 notes
wt_len:    .byte 4, 8, 7, 4, 4, 7, 4, 8, 8, 4, 10, 7, 5, 3, 3
wt_lo:     .byte <at_call, <at_qd, <at_ton, <at_band, <at_mode, <wt_sub, <at_freq, <at_rsts, <at_rstr, <at_name, <at_grid, <at_cmt, <wt_note, <wt_eor, <wt_eoh
wt_hi:     .byte >at_call, >at_qd, >at_ton, >at_band, >at_mode, >wt_sub, >at_freq, >at_rsts, >at_rstr, >at_name, >at_grid, >at_cmt, >wt_note, >wt_eor, >wt_eoh
ih_kind:   .byte 0, 1, 2, 5, 0, 3, 0, 0, 0, 4, 0, 6, 7
ih_off:    .byte REC_CALL, REC_DATE, REC_TIME, REC_BAND, REC_MODE, 0, REC_FREQ, REC_RSTS, REC_RSTR, REC_NAME, REC_GRID, REC_NOTES, REC_NOTES
ih_max:    .byte 10, 4, 2, 4, 4, 4, 10, 3, 3, 12, 6, NOTES_LEN, NOTES_LEN
mfsk_txt:  .byte $4d, $46, $53, $4b          // "MFSK" (ASCII)
dh_col:    .byte >dh0, >dh1, >dh2, >dh3      // high ..byte of each fingerprint column
bak_ext:   .byte $2e, $42, $41, $4b          // ".BAK" (ASCII)
           .byte $2e, $41, $44, $49          // ".ADI"
reu_pat:   .byte $55, $aa, $3c, $c3
hdr_magic: .byte $48, $4c, $47, $34          // "HLG4": the last character is the log format number

// New-record template (PETSCII/ASCII uppercase)
.encoding "petscii_upper"
rec_default:
        .fill 10, $20                         // call
        .fill 4, 0                            // date
        .fill 2, 0                            // time
        .text "59 "                           // RST sent
        .text "59 "                           // RST rcvd
        .text "20M "                          // band
        .text "SSB "                          // mode
        .fill 12, $20                         // name
        .fill 6, $20                          // grid
        .fill NOTES_LEN, $20                  // notes
        .fill 10, $20                         // frequency
        .fill RECORD_SIZE-REC_FREQ-10, 0      // reserved

// UI strings (screen codes, uppercase set)
// Band list for the BAND selector. Each entry is exactly PICK_LEN (4) characters,
// space padded, and is stored in the record as-is. Edit freely, but keep 4 chars
// per entry. (1.25M does not fit in 4 characters.)
band_list:
        .text "160M"
        .text "80M "
        .text "60M "
        .text "40M "
        .text "30M "
        .text "20M "
        .text "17M "
        .text "15M "
        .text "12M "
        .text "10M "
        .text "6M  "
        .text "2M  "
        .text "70CM"
        .text "33CM"
        .text "23CM"
band_end:

// Mode list for the MODE selector (same rules: exactly 4 characters per entry).
// These are ADIF mode names; USB/LSB and PSK31-style submodes are not stored.
mode_list:
        .text "SSB "
        .text "CW  "
        .text "FM  "
        .text "AM  "
        .text "RTTY"
        .text "FT8 "
        .text "FT4 "
        .text "PSK "
        .text "JT65"
        .text "JT9 "
        .text "MFSK"
        .text "SSTV"
mode_end:

// ADIF text is plain ASCII (note the underscores in the tag names)
.encoding "ascii"
adif_hdr:
        .text "HAMLOG64 ADIF EXPORT"
        .byte 13, 10
        .text "<ADIF_VER:5>3.1.4"
        .byte 13, 10
        .text "<PROGRAMID:8>HAMLOG64"
        .byte 13, 10
        .text "<EOH>"
        .byte 13, 10, 13, 10, 0
adif_eor:
        .text "<EOR>"
        .byte 13, 10, 0
at_call: .text "CALL"
        .byte 0
at_qd:  .text "QSO_DATE"
        .byte 0
at_ton: .text "TIME_ON"
        .byte 0
at_band: .text "BAND"
        .byte 0
at_freq: .text "FREQ"
        .byte 0
at_mode: .text "MODE"
        .byte 0
at_rsts: .text "RST_SENT"
        .byte 0
at_rstr: .text "RST_RCVD"
        .byte 0
at_name: .text "NAME"
        .byte 0
at_grid: .text "GRIDSQUARE"
        .byte 0
at_cmt: .text "COMMENT"
        .byte 0
wt_sub: .text "SUBMODE"
        .byte 0
wt_note: .text "NOTES"
        .byte 0
wt_eor: .text "EOR"
        .byte 0
wt_eoh: .text "EOH"
        .byte 0

.encoding "screencode_upper"
txt_title:  .text "HAMLOG64"
            .byte 0
txt_call:   .text "CALL"
            .byte 0
txt_rsts:   .text "RST SENT"
            .byte 0
txt_rstr:   .text "RST RCVD"
            .byte 0
txt_band:   .text "BAND"
            .byte 0
txt_mode:   .text "MODE"
            .byte 0
txt_name:   .text "NAME"
            .byte 0
txt_grid:   .text "GRID"
            .byte 0
txt_notes:  .text "NOTES"
            .byte 0
txt_freq:   .text "FREQ"
            .byte 0
txt_mhz:    .text "MHZ"
            .byte 0
txt_recent: .text "RECENT QSOS"
            .byte 0
txt_qsos:   .text "QSOS:"
            .byte 0
txt_help:   .text "F1 SAVE F2 LOGBOOK F3 SETTINGS F7 EXIT"
            .byte 0
msg_ready:  .text "READY"
            .byte 0
msg_saved:  .text "QSO SAVED"
            .byte 0
msg_nocall: .text "ENTER A CALLSIGN FIRST"
            .byte 0
msg_noreu:  .text "NO REU FOUND - ENABLE IT IN ULTIMATE"
            .byte 0
th_names:   .text "C64  WHITEGREENAMBER"
txt_lvtitle: .text "QSO LOG"
            .byte 0
txt_page:   .text "PAGE "
            .byte 0
txt_lvhelp: .text "E=EDIT D=DEL F=FIND SPC=PAGE F7=BACK"
            .byte 0
txt_nolog:  .text "NO QSOS LOGGED YET"
            .byte 0
msg_edit1:  .text "EDIT QSO #"
            .byte 0
msg_edit2:  .text "F1 SAVE  F7 CANCEL"
            .byte 0
msg_del1:   .text "DELETE "
            .byte 0
msg_del2:   .text "? Y = YES"
            .byte 0
msg_deleted: .text "QSO DELETED"
            .byte 0
// Shown in Settings. Change this one line when you bump the version (20 characters max
// fits the row; the text is upper case, as everything on this screen is).
txt_version: .text "HAMLOG64 VERSION V1.22"
            .byte 0
txt_mntitle: .text "MENU"
            .byte 0
txt_mn1:    .text "1  SET DATE/CLOCK"
            .byte 0
txt_mn2:    .text "2  BACKUP/RESTORE FILES"
            .byte 0
txt_mn3:    .text "3  COLOR THEME:"
            .byte 0
txt_mnhelp: .text "1-3 = CHOOSE   F7 = BACK"
            .byte 0
txt_fmtitle: .text "FILE MENU"
            .byte 0
txt_fm1:    .text "1  BACKUP LOG TO ULTIMATE FILE"
            .byte 0
txt_fm2:    .text "2  RESTORE LOG FROM ULTIMATE FILE"
            .byte 0
txt_fm3:    .text "3  EXPORT ADIF FILE"
            .byte 0
txt_fm4:    .text "4  IMPORT ADIF FILE"
            .byte 0
txt_fm5:    .text "5  CHOOSE ULTIMATE FOLDER"
            .byte 0
txt_fldprompt: .text "NEW FOLDER: "
            .byte 0
txt_fldlabel: .text "FOLDER:"
            .byte 0
txt_fldnone: .text "(NONE)"
            .byte 0
msg_fldsaved: .text "FOLDER SAVED"
            .byte 0
msg_nofolder: .text "CHOOSE A FOLDER FIRST (OPTION 5)"
            .byte 0
txt_fmhelp: .text "1-5 = CHOOSE   F7 = BACK"
            .byte 0
txt_bkprompt: .text "BACKUP FILE: "
            .byte 0
txt_rsprompt: .text "RESTORE FILE: "
            .byte 0
msg_bkok:   .text "BACKUP SAVED: "
            .byte 0
msg_rsok:   .text "LOG RESTORED: "
            .byte 0
msg_notbk:  .text "NOT A HAMLOG BACKUP FILE"
            .byte 0
msg_short:  .text "BACKUP FILE IS TOO SHORT"
            .byte 0
msg_confirm: .text "REPLACE CURRENT LOG? Y = YES"
            .byte 0
msg_nouci:  .text "NEEDS ULTIMATE COMMAND INTERFACE"
            .byte 0
msg_timeout: .text "ULTIMATE DID NOT ANSWER"
            .byte 0
msg_qsos:   .text " QSOS"
            .byte 0
msg_uerr:   .text "ULTIMATE REPORTED AN ERROR"
            .byte 0
txt_fdprompt: .text "FIND DATE: "
            .byte 0
msg_fdbad:  .text "ENTER YYYY, YYYYMM OR YYYYMMDD"
            .byte 0
msg_fdnone: .text "PRESS F FIRST"
            .byte 0
msg_fdmiss: .text "NOT FOUND"
            .byte 0
msg_fdend:  .text "NO MORE MATCHES"
            .byte 0
msg_fdsrch: .text "SEARCHING..."
            .byte 0
msg_found:  .text "FOUND #"
            .byte 0
msg_fn2:    .text "  N=NEXT"
            .byte 0
msg_cancel: .text "CANCELLED"
            .byte 0
txt_sctitle: .text "SET DATE AND TIME"
            .byte 0
txt_scdate: .text "DATE (YYYY-MM-DD)"
            .byte 0
txt_sctime: .text "TIME, UTC (HH:MM)"
            .byte 0
txt_sci1:   .text "TYPE THE TIME OF THE NEXT MINUTE,"
            .byte 0
txt_sci2:   .text "THEN PRESS RETURN WHEN YOUR"
            .byte 0
txt_sci3:   .text "REFERENCE CLOCK SHOWS :00."
            .byte 0
txt_sci4:   .text "THE CLOCK STARTS AT THAT MOMENT."
            .byte 0
txt_sci5:   .text "CRSR KEYS MOVE, DIGITS OVERWRITE."
            .byte 0
txt_schelp: .text "RETURN=SET  U=ULTIMATE RTC  F7=CANCEL"
            .byte 0
msg_badtime: .text "INVALID DATE OR TIME"
            .byte 0
msg_clockset: .text "CLOCK SET"
            .byte 0
msg_nortc:  .text "NO ULTIMATE CLOCK AVAILABLE"
            .byte 0
txt_exprompt: .text "EXPORT FILE: "
            .byte 0
msg_noqso:  .text "NO QSOS TO EXPORT"
            .byte 0
msg_exp1:   .text "EXPORTING "
            .byte 0
msg_exp2:   .text " OF "
            .byte 0
msg_exok:   .text "EXPORTED "
            .byte 0
msg_exq:    .text " QSOS: "
            .byte 0
txt_improm: .text "IMPORT FILE: "
            .byte 0
msg_imp1:   .text "IMPORTING "
            .byte 0
msg_imp2:   .text " SKIPPED "
            .byte 0
msg_imok:   .text "IMPORTED "
            .byte 0
msg_noimp:  .text "NO QSOS FOUND IN FILE"
            .byte 0
msg_rtc:    .text "CLOCK SET FROM ULTIMATE RTC"
            .byte 0

// Title Data
petscii_title:
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32,194, 32, 32,194, 32,213,192,192,201, 32,213,195,195,201, 32,221, 32, 32, 32,213,195,195,201, 96,213,195,195, 96, 96, 96, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32,194, 32, 32,194, 32,221, 32, 32,221, 32,194,106,116,194, 32,221, 32, 32, 32,221, 96, 32,221, 96,194, 32, 32, 32, 96, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32,235,195,195,243, 32,235,195,195,243, 32,194,106,116,194, 32,221, 32, 32, 32,221, 96, 32,221, 96,194, 32,195,201, 96, 96, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32,194, 32, 32,194, 32,221, 32, 32,221, 32,194, 96, 96,194, 32,221, 32, 32, 32,221, 96, 32,221, 96,194, 32, 32,221, 32, 96, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32,194, 32, 32,194, 32,221, 32, 32,221, 32,194, 32, 32,194, 32,202,192,192, 96,202,195,195,203, 96,202,195,195,203, 96, 96, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 96, 96,213,196,196,201, 32,194, 32, 96,194, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 96, 96,194, 32, 32, 32, 32,194, 32, 96,194, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 96, 96,235,195,195,201, 32,237,195,195,219, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 96, 96,194, 32, 96,194, 32, 32, 32, 96,194, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 96, 96,202,195,195,203, 32, 32, 32, 96,194, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 96, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32,  2, 25, 58, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 96, 96, 96, 96, 96, 96, 96, 96, 96, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 22, 96,177,174,178,177, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32,139,131,178,142,137,139, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32
.byte  32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 16, 18,  5, 19, 19, 32,  1, 14, 25, 32, 11,  5, 25, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32

// Title Color
petscii_colors:
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14
.byte  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14


// Variables
wt_cnt:     .word 0             // jiffies left to wait on the title screen
rec_idx:    .word 0
reu_buf:    .word 0
qso_count:  .word 0
cur_field:  .byte 0
cur_pos:    .byte 0
log_i:      .byte 0
tmp_f:      .byte 0
tr_end:     .byte 0
tmp_mask:   .byte 0
r_t0:       .byte 0
r_t1:       .byte 0
r_t2:       .byte 0
t_hh:       .byte 0
t_mm:       .byte 0
t_ss:       .byte 0
dec_val:    .word 0
dec_tmp:    .byte 0
dec_buf:    .fill 5, 0
uci_buf:    .fill 24, 0
uci_to:     .word 0
set_ss:     .byte 0
theme:      .byte 0
hl_col:     .byte 0
lv_sel:     .byte 0             // highlighted record on the logbook page (0 = first)
lv_cnt:     .byte 0             // records shown on this page
lv_resume:  .byte 0             // 1 = reopen the logbook where it was (after an edit)
edit_idx:   .word 0             // record being edited (0 = not editing)
sel_n:      .word 0
dl_k:       .word 0
dl_t:       .word 0
fd_buf:     .fill 8, 0          // the date being searched for: 4, 6 or 8 ASCII digits
fd_len:     .byte 0             // 0 = no search yet
fd_n:       .byte 0             // 1 = this scan is an "N" (next match)
fd_from:    .word 0             // record the scan starts at
fd_last:    .word 0             // record of the last match
gt_n:       .word 0
gt_d:       .word 0
form_save:  .fill RECORD_SIZE, 0   // the entry form, set aside while a record is edited
pk_dir:     .byte 0
pk_idx:     .byte 0
pk_cnt:     .byte 0
pk_chr:     .byte 0
uci_tmo:    .byte 2             // UCI timeout, units of ~1 s
uci_to2:    .byte 0
uci_clen:   .byte 0
uci_qok:    .byte 0             // 1 = an empty status reply counts as success (READ_DATA)
uci_idleok: .byte 0             // 1 = returning straight to idle also counts as done (WRITE_DATA)
fn_ext:     .byte 0             // default file name extension: 0 = .BAK, 4 = .ADI
df_end:     .byte 0
op_y:       .byte 0
out_len:    .word 0
ex_n:       .word 0             // record being exported
xf_n:       .byte 0             // ADIF field being written
xf_kind:    .byte 0
xf_off:     .byte 0
xf_max:     .byte 0
xf_cnt:     .byte 0
xf_len:     .byte 0
xf_ty:      .byte 0
xf_tag:     .word 0
fld_tmp:    .fill 32, 0
in_left:    .word 0             // ..bytes still unread in the current chunk (zp_in points at the next)
vl:         .word 0             // length of the field value being read
sn_n:       .word 0
tag_n:      .byte 0
tag_buf:    .fill 16, 0
cur_f:      .byte 0
val_n:      .byte 0
val_buf:    .fill 32, 0
ip_dg:      .byte 0
ip_mt:      .word 0
ia_k:       .byte 0
ia_off:     .byte 0
ia_max:     .byte 0
ia_s:       .byte 0
ia_c:       .byte 0
ia_t:       .byte 0
ia_need:    .byte 0
ia_tmp:     .fill 4, 0
sub_buf:    .fill 4, 0
sub_n:      .byte 0
got_cmt:    .byte 0
imp_ok:     .word 0             // QSOs added
imp_skip:   .word 0             // QSOs skipped (duplicates or no callsign)
imp_err:    .byte 0
imp_stop:   .byte 0
imp_tick:   .byte 0
dh_n:       .word 0             // entries in the duplicate table
dh_base:    .word 0             // record number of entry 0
fpn:        .fill 4, 0          // fingerprint of the QSO being imported
dc_p:       .byte 0
dc_y:       .byte 0
dp_i:       .word 0
kb:         .fill 20, 0         // duplicate key of the QSO being imported
kb2:        .fill 20, 0         // key of a stored QSO being compared with it
imp_buf:    .fill RECORD_SIZE, 0
uci_cmd:    .fill 32, 0
uci_dn:     .byte 0
uci_dat:    .fill UCI_DATMAX, 0
st_scr:     .fill ST_MAX+2, 0
st_keep:    .fill ST_MAX+2, 0
fn_buf:     .fill 32, 0
fn_len:     .byte 0
fn_col:     .byte 0
fn_max:     .byte FN_MAX
fn_lim:     .byte 0
fld_len:    .byte 0             // remembered Ultimate folder: length ...
fld_buf:    .fill 32, 0         // ... and text (must stay right after fld_len)
bk_fld:     .fill 32, 0
af_i:       .byte 0
af_pos:     .byte 0
af_start:   .byte 0
af_end:     .byte 0
bl_n:       .word 0
bl_0:       .byte 0
bl_1:       .byte 0
bl_2:       .byte 0
bk_date:    .fill 4, 0
bk_theme:   .byte 0
lv_k:       .byte 0
lv_r:       .byte 0
lv_j:       .byte 0
lv_col:     .byte 0
lv_top:     .word 0
lv_page:    .word 0
lv_pages:   .word 0
lv_seq:     .word 0
rb:         .word 0
cp_t:       .word 0
clk_n:      .byte 0
clk_pos:    .byte 0             // cursor in clk_buf (0-11) on the clock screen
clk_buf:    .fill 12, 0
c_hh:       .byte 0
c_mm:       .byte 0
c_t:        .byte 0
b_t:        .byte 0
last_hh:    .byte 0
old_date:   .fill 4, 0
// current date, BCD CC YY MM DD (placeholder until set; restored from REU header)
cur_date:   .byte $20, $26, $01, $01
// days per month, BCD, index = month 1-12 (Feb adjusted for leap years in dim_get)
dim_tab:    .byte $00, $31, $28, $31, $30, $31, $30, $31, $31, $30, $31, $30, $31

rec_buf:    .fill RECORD_SIZE, 0
view_buf:   .fill RECORD_SIZE, 0
hdr_buf:    .fill RECORD_SIZE, 0

// ADIF output buffer: page aligned so "256 ..bytes waiting" is a single compare of the high ..byte
.align 256
out_buf:    .fill 512, 0
in_buf:     .fill IN_CHUNK, 0           // import reads land here (also page aligned: out_buf is 2 pages)


// The importer's duplicate table lives at dh0..$8FFF: the program must not reach it.
.if (* > dh0) {
    .error "program is too large: it overlaps the import duplicate table at dh0"
}
