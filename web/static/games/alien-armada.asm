; ===========================================================================
;                              ALIEN ARMADA
; ===========================================================================
; A shoot-'em-up in the style of the arcade invader games of 1978, written in
; 6502 assembly for the Commodore 64. Everything is in this one file: the
; code, the sound effects, and the pixels of every sprite and character.
;
; HOW TO PLAY
;   Joystick in port 2 (on this page: arrow keys move, Space fires).
;   Stop the armada before it lands. The shields soak up bombs but crumble.
;   The mystery ship that crosses the top is worth 50 to 300 points.
;
; WHAT TO LOOK FOR
;   - A raster interrupt paces the whole game: 50 frames a second.
;   - The armada is made of characters. Moving it means redrawing screen
;     memory, which is why it moves a whole character (8 pixels) at a time.
;   - The base, shots, bombs and mystery ship are hardware sprites.
;   - A shot hits an alien when the screen cell under its tip holds an
;     alien character (see SPRITE_CELL).
;   - Scores are binary-coded decimal: SED makes ADC add in decimal.
;   - Sound effects are rows in a table, played by a small SID driver.
;
; MEMORY MAP
;   $0400-$07FF  screen memory, with the sprite pointers at the end
;   $0810-       the program
;   $2000-$21BF  sprite shapes (sprite pointers 128-134)
;   $3800-$39FF  letters and digits, copied from the character ROM
;   $3A00-$3ABF  the game's own characters (screen codes 64-87)
;   $C000-$C0FF  tables: sprite positions, the aliens, row addresses
;
; THINGS TO TRY
;   - More lives (up to 9): change START_LIVES.
;   - Faster bombs: change BOMB_SPEED. A faster gun: change SHOT_SPEED.
;   - Redraw the aliens: their pixels are under ALIEN CHARACTERS at the end.
;   - Recolour the screen's bands of colour in BAND_COLORS.
; ===========================================================================

; ---------------------------------------------------------------------------
; Settings: change these to change the game
; ---------------------------------------------------------------------------
START_LIVES  = 3
BASE_SPEED   = 2            ; pixels per frame
SHOT_SPEED   = 6            ; pixels per frame (keep it below 8, a character)
BOMB_SPEED   = 2            ; pixels per frame
MAX_BOMBS    = 3            ; bombs falling at once (sprites 2-4)

; ---------------------------------------------------------------------------
; The C64's chips and memory
; ---------------------------------------------------------------------------
VIC         = $D000         ; VIC-II video chip registers
SID         = $D400         ; SID sound chip registers
SCREEN      = $0400         ; 40 x 25 screen codes
COLORS      = $D800         ; the colour of each screen cell
SPRITE_PTRS = $07F8         ; the 64-byte block each sprite shows
CHARSET     = $3800         ; our character set (VIC-II bank 0)
SPRITE_DATA = $2000         ; our sprite shapes: block 128 onwards
JOYSTICK    = $DC00         ; joystick port 2, 0 bits = pressed

JOY_UP      = 1
JOY_DOWN    = 2
JOY_LEFT    = 4
JOY_RIGHT   = 8
JOY_FIRE    = 16

BLACK       = 0
WHITE       = 1
RED         = 2
CYAN        = 3
PURPLE      = 4
GREEN       = 5
YELLOW      = 7
LIGHT_RED   = 10
DARK_GREY   = 11
GREY        = 12
LIGHT_GREEN = 13
LIGHT_BLUE  = 14
LIGHT_GREY  = 15

SPACE       = 32            ; screen code of a blank cell

; ---------------------------------------------------------------------------
; Sprites: which hardware sprite plays which part, and their shapes
; ---------------------------------------------------------------------------
S_BASE      = 0
S_SHOT      = 1
S_BOMB      = 2             ; 2, 3 and 4
S_UFO       = 5
BIT_BASE    = 1             ; the same sprites as bits of $D015
BIT_SHOT    = 2
BIT_UFO     = 32

P_BASE      = 128           ; shape number = address / 64
P_SHOT      = 129
P_BOMB      = 130           ; two frames: 130, 131
P_UFO       = 132
P_BOOM      = 133           ; two frames: 133, 134

; ---------------------------------------------------------------------------
; Characters: the game's own shapes start at screen code 64
; ---------------------------------------------------------------------------
C_ALIEN_A   = 64            ; each alien is 2 cells wide, in 2 frames:
C_ALIEN_B   = 68            ;   +0 +1 first frame, +2 +3 second frame
C_ALIEN_C   = 72
C_BANG      = 76            ; 76, 77: an alien exploding
C_SHIELD    = 78            ; 78-81: a shield block, crumbling
C_CORNER_L  = 82            ; 82, 83
C_CORNER_R  = 84            ; 84, 85
C_GROUND    = 86
C_LIFE      = 87
SHIELD_FIRST = 78
SHIELD_LAST  = 85

; ---------------------------------------------------------------------------
; Where things are on the screen. Sprite Y 50 is the top text row, and
; sprite X 24 the leftmost column.
; ---------------------------------------------------------------------------
UFO_Y       = 66            ; row 2
BASE_Y      = 226           ; row 22
SHIELD_ROW  = 18            ; rows 18-20
LAND_ROW    = 21            ; aliens this low have landed
GROUND_ROW  = 23
LIVES_ROW   = 24
OVER_ROW    = 12            ; GAME OVER

; ---------------------------------------------------------------------------
; Zero page variables. This game never returns to BASIC, so it is free to
; use the zero page locations BASIC normally keeps for itself.
; ---------------------------------------------------------------------------
frame_count = $02           ; counted up by the raster interrupt
joy         = $03           ; joystick, 1 bits = pressed
fire_armed  = $04           ; fire was released, so a press counts
seed        = $05           ; random number generator state
ptr         = $06           ; general purpose pointers: $06-$07
ptr2        = $08           ; $08-$09
cptr        = $0A           ; colour memory pointer: $0A-$0B
tmp         = $0C
tmp2        = $0D
tmp3        = $0E
counter     = $0F
cell_row    = $10           ; the cell SPRITE_CELL found
cell_col    = $11
fx          = $12           ; armada: screen column of its first column
ftop        = $13           ; armada: screen row of its top row
fdir        = $14           ; armada: 1 = moving right, $FF = left
fanim       = $15           ; armada: 0 or 2, the animation frame
step_timer  = $16           ; frames until the armada's next step
alive_count = $17
minc        = $18           ; leftmost and rightmost columns with aliens
maxc        = $19
maxr        = $1A           ; lowest row with aliens
landed      = $1B
score       = $1C           ; 6 BCD digits, lowest byte first: $1C-$1E
hiscore     = $1F           ; $1F-$21
lives       = $22
wave        = $23           ; wave number for the game's sums
wave_bcd    = $24           ; and the same in decimal, for the screen
bomb_timer  = $25
ufo_timer   = $26
ufo_dir     = $27
ufo_text_timer = $28
ufo_text_col = $29
bang_timer  = $2A           ; an alien's explosion on screen
bang_ptr    = $2B           ; $2B-$2C: where it is
dying       = $2D           ; frames left of the base's explosion
march_note  = $2E
spr_on      = $2F           ; which sprites are on, copied to $D015
last_row    = $4B           ; the lowest screen row DRAW_ARMADA draws

; The sound driver keeps one byte per voice in each of these.
sfx_start   = $30           ; 1 = start this voice's effect next frame
sfx_time    = $33           ; frames left
sfx_wave    = $36           ; waveform
sfx_ad      = $39           ; attack/decay
sfx_sr      = $3C           ; sustain/release
sfx_flo     = $3F           ; frequency, low and high bytes
sfx_fhi     = $42
sfx_dlo     = $45           ; frequency change per frame
sfx_dhi     = $48

; Tables too big for the zero page live in free RAM at $C000.
SPR_XLO     = $C000         ; sprite X, low 8 bits (8 sprites)
SPR_XHI     = $C008         ; sprite X, bit 8
SPR_Y       = $C010
SPR_PTR     = $C018         ; shape
SPR_COL     = $C020         ; colour
ALIVE       = $C040         ; 40 aliens: 5 rows of 8, 1 = alive
ROW_LO      = $C080         ; address of each screen row
ROW_HI      = $C0A0

; ===========================================================================
; START
; ===========================================================================
        ORG $0810           ; SYS 2064 starts the game

start:
        SEI                 ; no interrupts while we set up
        CLD
        LDA #$7F
        STA $DC0D           ; switch off the CIA timer interrupt the KERNAL uses
        LDA $DC0D           ; and clear any that is waiting
        LDA #$FF
        STA JOYSTICK        ; select no keyboard row, so $DC00 reads only the joystick
        JSR make_row_table
        JSR copy_font
        JSR init_sid

        LDA #BLACK
        STA VIC+$20         ; border
        STA VIC+$21         ; background
        LDA #$1E            ; screen at $0400, characters at $3800
        STA VIC+$18
        LDA #0
        STA VIC+$1C         ; single-colour sprites
        STA VIC+$17         ; no stretching
        STA VIC+$1D
        STA VIC+$1B         ; sprites in front of the characters
        STA spr_on
        STA hiscore
        STA hiscore+1
        STA hiscore+2
        STA score
        STA score+1
        STA score+2
        STA fanim
        LDA #1
        STA ufo_dir
        STA wave_bcd

        ; A raster interrupt at line 251, just below the last row of text.
        LDA #<irq
        STA $0314           ; the KERNAL jumps through $0314 on every IRQ
        LDA #>irq
        STA $0315
        LDA #251
        STA VIC+$12         ; raster line to interrupt on (bits 0-7)
        LDA VIC+$11
        AND #$7F            ; and bit 8
        STA VIC+$11
        LDA #1
        STA VIC+$1A         ; enable raster interrupts
        STA VIC+$19         ; and clear one that may be waiting
        LDA VIC+$12
        ORA #1
        STA seed            ; any start that is not zero
        CLI

main_loop:
        JSR title_screen    ; returns when fire is pressed
        JSR play_game       ; returns when the game is over
        JMP main_loop

; ===========================================================================
; THE RASTER INTERRUPT
; Runs once a frame, when the VIC-II reaches line 251. It does as little as
; possible: it tells the main loop a new frame has begun, and keeps the
; sound effects moving so they play smoothly whatever the game is doing.
; ===========================================================================
irq:
        CLD                 ; the 6502 keeps decimal mode for an interrupt,
                            ; and SFX_UPDATE's ADC must add in binary
        LDA #1
        STA VIC+$19         ; acknowledge, or the interrupt would repeat at once
        INC frame_count
        JSR sfx_update
        JMP $EA81           ; the KERNAL's ending: restore Y, X and A, then RTI

; Wait for the next frame. The game runs its logic just after line 251,
; while the beam is in the border, so the screen never shows half a change.
wait_frame:
        LDA frame_count
wf_wait:
        CMP frame_count
        BEQ wf_wait
        RTS

; Wait A frames, keeping the sprites up to date. An alien's explosion runs
; its course too: the last alien of a wave is still exploding when the
; fanfare starts.
wait_frames:
        STA counter
wfs_loop:
        JSR wait_frame
        JSR update_sprites
        JSR update_bang
        DEC counter
        BNE wfs_loop
        RTS

; Read joystick 2. The hardware reads 0 for a closed switch, so flip the
; bits to make 1 mean pressed.
read_joystick:
        LDA JOYSTICK
        EOR #$FF
        AND #%00011111
        STA joy
        RTS

; Has fire just been pressed? Carry set if so. A press only counts after
; the button has been let go, so holding fire cannot skip a screen.
fire_pressed:
        JSR read_joystick
        AND #JOY_FIRE
        BNE fp_down
        LDA #1
        STA fire_armed
        CLC
        RTS
fp_down:
        LDA fire_armed
        CMP #1              ; carry set if armed
        LDA #0
        STA fire_armed
        RTS

; ---------------------------------------------------------------------------
; UPDATE_SPRITES - copy the sprite tables to the VIC-II.
; The game moves sprites by changing SPR_XLO, SPR_Y and the rest; this puts
; them on screen in one go. X positions need 9 bits, so the 9th bit of all
; eight sprites is gathered into one byte for $D010.
; ---------------------------------------------------------------------------
update_sprites:
        LDA #0
        STA tmp
        LDX #7
us_loop:
        TXA
        ASL
        TAY                 ; Y = 2 x sprite number: its position registers
        LDA SPR_XLO,X
        STA VIC+0,Y
        LDA SPR_Y,X
        STA VIC+1,Y
        LDA SPR_XHI,X
        LSR                 ; bit 8 of X into the carry...
        ROL tmp             ; ...and into the byte for $D010
        LDA SPR_PTR,X
        STA SPRITE_PTRS,X
        LDA SPR_COL,X
        STA VIC+$27,X
        DEX
        BPL us_loop
        LDA tmp
        STA VIC+$10
        LDA spr_on
        STA VIC+$15         ; which sprites are visible
        RTS

; HALF_X - the X position of sprite X divided by 2. Halving makes the 9-bit
; position fit in one byte, which is plenty for collision checks.
half_x:
        LDA SPR_XHI,X
        LSR
        LDA SPR_XLO,X
        ROR
        RTS

; ===========================================================================
; THE TITLE SCREEN
; ===========================================================================
title_screen:
        JSR clear_screen
        LDA #0
        STA spr_on
        STA fire_armed
        JSR show_status
        LDA #<title_text
        LDX #>title_text
        JSR print_list
        JSR draw_title_aliens
        ; the mystery ship, as a sprite, in the points table
        LDA #24+14*8
        STA SPR_XLO+S_UFO
        LDA #0
        STA SPR_XHI+S_UFO
        LDA #50+8*8
        STA SPR_Y+S_UFO
        LDA #P_UFO
        STA SPR_PTR+S_UFO
        LDA #LIGHT_RED
        STA SPR_COL+S_UFO
        LDA #BIT_UFO
        STA spr_on
ts_loop:
        JSR wait_frame
        JSR update_sprites
        ; the aliens march on the spot, and the prompt blinks
        LDA frame_count
        AND #31
        BNE ts_fire
        LDA fanim
        EOR #2
        STA fanim
        JSR draw_title_aliens
        LDA frame_count
        AND #32
        BEQ ts_bright
        LDA #DARK_GREY
        JMP ts_blink
ts_bright:
        LDA #WHITE
ts_blink:
        LDX #17
ts_color:
        STA COLORS+20*40+11,X
        DEX
        BPL ts_color
ts_fire:
        JSR fire_pressed
        BCC ts_loop
        ; mix the moment fire was pressed into the random numbers
        LDA frame_count
        EOR seed
        ORA #1
        STA seed
        RTS

; The three kinds of alien in the points table, in their colours.
draw_title_aliens:
        LDX #2
dta_loop:
        LDY title_alien_row,X
        LDA ROW_LO,Y
        STA ptr
        CLC
        ADC #<(COLORS-SCREEN)
        STA cptr
        LDA ROW_HI,Y
        STA ptr+1
        ADC #>(COLORS-SCREEN)
        STA cptr+1
        LDA title_alien_char,X
        CLC
        ADC fanim
        LDY #14
        STA (ptr),Y
        INY
        CLC
        ADC #1
        STA (ptr),Y
        LDA title_alien_color,X
        STA (cptr),Y
        DEY
        STA (cptr),Y
        DEX
        BPL dta_loop
        RTS

; ===========================================================================
; THE GAME
; ===========================================================================
play_game:
        LDA #0
        STA score
        STA score+1
        STA score+2
        LDA #START_LIVES
        STA lives
        LDA #1
        STA wave
        STA wave_bcd

pg_wave:
        JSR new_wave

; The main loop: one pass per frame. The sprites go to the VIC-II first,
; then the armada, which may redraw lots of characters: it starts while
; the beam is in the border and works down the screen ahead of it. Then
; everything else works out the next frame.
pg_loop:
        JSR wait_frame
        JSR update_sprites
        JSR step_armada
        JSR read_joystick
        JSR move_base
        JSR move_shot
        JSR move_bombs
        JSR drop_bomb
        JSR move_ufo
        JSR update_bang

        LDA landed
        BNE pg_over         ; the aliens have reached the ground
        LDA lives
        BEQ pg_over         ; the last base has gone
        LDA alive_count     ; the wave is over when every alien has gone,
        ORA dying           ; and the base has finished exploding
        BNE pg_loop

        ; Every alien is gone: a fanfare, then the next, lower wave.
        LDA #BIT_BASE
        STA spr_on
        LDA #SFX_CLEARED
        LDX #0
        JSR sfx_play
        LDA #75
        JSR wait_frames
        LDA wave_bcd        ; count the waves, up to 99
        CMP #$99
        BEQ pg_wave
        INC wave
        SED                 ; decimal mode: $09 + 1 = $10
        LDA wave_bcd
        CLC
        ADC #1
        STA wave_bcd
        CLD
        JMP pg_wave

pg_over:
        LDA #BIT_BASE
        AND spr_on
        STA spr_on
        LDA #SFX_BASE_BOOM
        LDX #1
        JSR sfx_play
        LDA bang_timer      ; an alien still exploding goes now: later, it
        BEQ pg_message      ; could rub out part of the message instead
        LDA #1
        STA bang_timer
        JSR update_bang
pg_message:
        LDX #39             ; the message gets a row to itself, as the
        LDA #SPACE          ; armada may be passing through that row
pg_clear:
        STA SCREEN+OVER_ROW*40,X
        DEX
        BPL pg_clear
        LDA #<over_text
        LDX #>over_text
        JSR print
        JSR update_hiscore
        JSR show_status
        LDA #200
        JMP wait_frames

; Set up a new wave: shields, ground, a full armada and the base.
new_wave:
        JSR clear_screen
        LDX #39
        LDA #1
nw_alive:
        STA ALIVE,X
        DEX
        BPL nw_alive
        LDA #40
        STA alive_count
        LDA #8
        STA fx
        ; each wave starts one row lower, down to row 9
        LDA wave
        CMP #6
        BCC nw_top
        LDA #6
nw_top:
        CLC
        ADC #3
        STA ftop
        LDA #1
        STA fdir
        LDA #0
        STA landed
        STA bang_timer
        STA dying
        STA ufo_text_timer
        STA march_note
        LDA #50
        STA step_timer      ; a moment's pause before they move
        LDA #90
        STA bomb_timer
        LDA #180
        STA ufo_timer
        JSR color_bands
        JSR draw_shields
        JSR draw_ground
        JSR show_status
        JSR show_lives
        JSR find_edges
        JSR draw_armada
        JMP place_base

; ===========================================================================
; THE ARMADA
; Forty aliens in 5 rows of 8. ALIVE holds one byte for each. On screen an
; alien is two characters, with a blank column between neighbours, and a
; blank row between the rows. The whole armada steps one character at a
; time; the fewer aliens are left, the more often it steps.
; ===========================================================================
step_armada:
        LDA dying
        BNE sa_done         ; everything waits while the base explodes
        DEC step_timer
        BNE sa_done
        LDA alive_count
        LSR
        CLC
        ADC #2
        STA step_timer      ; next step in 2 + aliens/2 frames
        JSR find_edges
        LDA fdir
        BMI sa_left
        LDX maxc            ; moving right: is the rightmost alien at the edge?
        LDA times3,X
        CLC
        ADC fx              ; screen column of its left half
        CMP #38             ; its right half is in column 39
        BCS sa_down
        INC fx
        JMP sa_draw
sa_left:
        LDX minc            ; moving left: is the leftmost alien at the edge?
        LDA times3,X
        CLC
        ADC fx
        BEQ sa_down
        DEC fx
        JMP sa_draw
sa_down:
        INC ftop            ; at an edge the armada drops a row and turns
        LDA fdir
        EOR #$FE            ; 1 becomes $FF and $FF becomes 1
        STA fdir
        LDA maxr            ; the lowest aliens are at row ftop + 2 x maxr
        ASL
        CLC
        ADC ftop
        CMP #LAND_ROW
        BCC sa_draw
        LDA #1
        STA landed
sa_draw:
        LDA bang_timer      ; an explosion still showing? rub it out now,
        BEQ sa_animate      ; as the redraw may not reach its row
        LDA #1
        STA bang_timer
        JSR update_bang
sa_animate:
        LDA fanim
        EOR #2              ; swap to the other animation frame
        STA fanim
        JSR draw_armada
        ; the march: four low notes, round and round
        LDA march_note
        CLC
        ADC #1
        AND #3
        STA march_note
        ASL
        ASL
        ASL                 ; 8 bytes per sound effect
        CLC
        ADC #SFX_MARCH
        LDX #2
        JSR sfx_play
sa_done:
        RTS

; Find the leftmost and rightmost columns that still have an alien, and
; the lowest row.
find_edges:
        LDA #7
        STA minc
        LDA #0
        STA maxc
        STA maxr
        LDX #39
fe_loop:
        LDA ALIVE,X
        BEQ fe_next
        TXA
        AND #7              ; the alien's column
        CMP minc
        BCS fe_not_left
        STA minc
fe_not_left:
        CMP maxc
        BCC fe_not_right
        STA maxc
fe_not_right:
        TXA
        LSR
        LSR
        LSR                 ; the alien's row
        CMP maxr
        BCC fe_next
        STA maxr
fe_next:
        DEX
        BPL fe_loop
        RTS

; Draw the armada: every screen row from the one above it down to its
; lowest living row is cleared, then the living aliens are drawn into their
; rows. Rows below that are already empty, and stopping there keeps the
; drawing on the screen however far down the armada gets. Down among the
; shields only the armada's own characters are rubbed out, so the aliens
; eat away a shield just where they pass through it.
draw_armada:
        LDA maxr
        ASL
        CLC
        ADC ftop
        STA last_row
        LDX ftop
        DEX
        STX tmp             ; tmp = the screen row being drawn
da_row:
        LDX tmp
        LDA ROW_LO,X
        STA ptr
        LDA ROW_HI,X
        STA ptr+1
        LDY #39
        CPX #SHIELD_ROW
        BCS da_shields
        LDA #SPACE
da_clear:
        STA (ptr),Y
        DEY
        BPL da_clear
        JMP da_aliens
da_shields:
        LDA (ptr),Y
        CMP #SHIELD_FIRST   ; aliens and explosions come before the shields
        BCS da_keep
        LDA #SPACE
        STA (ptr),Y
da_keep:
        DEY
        BPL da_shields
da_aliens:
        LDA tmp
        SEC
        SBC ftop
        BCC da_next         ; the row above the armada stays empty
        LSR                 ; A = armada row, carry set for a gap row
        BCS da_next
        JSR draw_alien_row
da_next:
        INC tmp
        LDA last_row
        CMP tmp
        BCS da_row
        RTS

; Draw armada row A into the screen row at ptr.
draw_alien_row:
        TAX
        LDA row_char,X
        CLC
        ADC fanim
        STA tmp3            ; the left half of this row's alien
        TXA
        ASL
        ASL
        ASL
        TAX                 ; X = the row's first alien in ALIVE
        LDA #0
        STA tmp2            ; 3 x column
dr_loop:
        LDA ALIVE,X
        BEQ dr_next
        LDA fx
        CLC
        ADC tmp2
        TAY
        LDA tmp3
        STA (ptr),Y
        INY
        CLC
        ADC #1
        STA (ptr),Y
dr_next:
        INX
        LDA tmp2
        CLC
        ADC #3
        STA tmp2
        CMP #24
        BCC dr_loop
        RTS

; Colour the screen in bands, like the coloured film stuck over the screen
; of an arcade machine: an alien takes the colour of the band it is in.
color_bands:
        LDX #24
cb_row:
        LDA ROW_LO,X
        STA cptr
        LDA ROW_HI,X
        CLC
        ADC #>(COLORS-SCREEN)
        STA cptr+1
        LDA band_colors,X
        LDY #39
cb_fill:
        STA (cptr),Y
        DEY
        BPL cb_fill
        DEX
        BPL cb_row
        RTS

; The shot is in an alien's cell (cell_row, cell_col): which alien is it?
; Its row is (cell_row - ftop) / 2 and its column (cell_col - fx) / 3.
hit_alien:
        LDA cell_row
        SEC
        SBC ftop
        LSR
        STA tmp             ; armada row
        LDA cell_col
        SEC
        SBC fx
        LDX #0
ha_div3:                    ; divide by 3 the simple way: count subtractions
        CMP #3
        BCC ha_found
        SBC #3
        INX
        BNE ha_div3
ha_found:
        STX tmp2            ; armada column; A = 0 or 1, the half that was hit
        STA tmp3
        LDA cell_col
        SEC
        SBC tmp3
        STA tmp3            ; screen column of the alien's left half
        LDA tmp
        ASL
        ASL
        ASL
        ORA tmp2
        TAX
        LDA ALIVE,X
        BEQ ha_done         ; already gone (only possible if the screen and ALIVE disagree)
        LDA #0
        STA ALIVE,X
        DEC alive_count
        LDX tmp
        LDA row_points,X
        LDX #0
        JSR add_score
        LDA bang_timer      ; an explosion still showing? rub it out now:
        BEQ ha_bang         ; this one takes its place
        LDA #1
        STA bang_timer
        JSR update_bang
ha_bang:
        ; an explosion where the alien was, for a few frames
        LDX cell_row
        LDA ROW_LO,X
        CLC
        ADC tmp3
        STA bang_ptr
        LDA ROW_HI,X
        ADC #0
        STA bang_ptr+1
        LDY #0
        LDA #C_BANG
        STA (bang_ptr),Y
        INY
        LDA #C_BANG+1
        STA (bang_ptr),Y
        LDA #12
        STA bang_timer
        LDA #SFX_BOOM
        LDX #1
        JMP sfx_play
ha_done:
        RTS

; Clear the explosion when its time is up.
update_bang:
        LDA bang_timer
        BEQ ub_done
        DEC bang_timer
        BNE ub_done
        LDY #0
        LDA #SPACE
        STA (bang_ptr),Y
        INY
        STA (bang_ptr),Y
ub_done:
        RTS

; ===========================================================================
; THE BASE
; ===========================================================================
place_base:
        LDA #24+160-8       ; the middle of the screen
        STA SPR_XLO+S_BASE
        LDA #0
        STA SPR_XHI+S_BASE
        LDA #BASE_Y
        STA SPR_Y+S_BASE
        LDA #P_BASE
        STA SPR_PTR+S_BASE
        LDA #GREEN
        STA SPR_COL+S_BASE
        LDA #WHITE
        STA SPR_COL+S_SHOT
        LDA #P_SHOT
        STA SPR_PTR+S_SHOT
        LDA #YELLOW
        STA SPR_COL+S_BOMB
        STA SPR_COL+S_BOMB+1
        STA SPR_COL+S_BOMB+2
        LDA #LIGHT_RED
        STA SPR_COL+S_UFO
        LDA #BIT_BASE
        STA spr_on          ; just the base: no shot, bombs or mystery ship
        RTS

; Move the base with the joystick and fire. X positions have 9 bits, so
; the sums carry into SPR_XHI. The base may go from X 24 (the left edge)
; to 329 (its 15 pixels touching the right edge).
move_base:
        LDA dying
        BEQ mb_control
        JMP base_exploding
mb_control:
        LDA joy
        AND #JOY_LEFT
        BEQ mb_right
        LDA SPR_XLO+S_BASE
        SEC
        SBC #BASE_SPEED
        STA tmp
        LDA SPR_XHI+S_BASE
        SBC #0
        BNE mb_set          ; still 256 or more: fine
        LDA tmp
        CMP #24
        BCC mb_fire         ; it would leave the screen
        LDA #0
        JMP mb_set
mb_right:
        LDA joy
        AND #JOY_RIGHT
        BEQ mb_fire
        LDA SPR_XLO+S_BASE
        CLC
        ADC #BASE_SPEED
        STA tmp
        LDA SPR_XHI+S_BASE
        ADC #0
        BEQ mb_set          ; still below 256: fine
        LDA tmp
        CMP #330-256
        BCS mb_fire         ; it would leave the screen
        LDA #1
mb_set:
        STA SPR_XHI+S_BASE
        LDA tmp
        STA SPR_XLO+S_BASE
mb_fire:
        LDA joy
        AND #JOY_FIRE
        BNE mb_held
        LDA #1              ; fire is up, so holding it from now on fires
        STA fire_armed
        RTS
mb_held:
        LDA fire_armed      ; the press that started the game is not a shot:
        BEQ mb_done         ; it has to be let go first
        LDA spr_on
        AND #BIT_SHOT
        BNE mb_done         ; one shot at a time
        LDA SPR_XLO+S_BASE  ; the shot leaves from the gun, 7 pixels in
        CLC
        ADC #7
        STA SPR_XLO+S_SHOT
        LDA SPR_XHI+S_BASE
        ADC #0
        STA SPR_XHI+S_SHOT
        LDA #BASE_Y-4
        STA SPR_Y+S_SHOT
        LDA spr_on
        ORA #BIT_SHOT
        STA spr_on
        LDA #SFX_SHOT
        LDX #0
        JSR sfx_play
mb_done:
        RTS

; Hit! Blow the base up; every shot and bomb disappears.
base_hit:
        LDA #100
        STA dying
        LDA spr_on
        AND #BIT_BASE+BIT_UFO
        STA spr_on
        LDA #SFX_BASE_BOOM
        LDX #1
        JMP sfx_play

; While the base explodes it flickers between two shapes. Then a life goes,
; and if any are left a new base appears.
base_exploding:
        DEC dying
        BEQ be_over
        LDA dying
        AND #4
        LSR
        LSR
        CLC
        ADC #P_BOOM
        STA SPR_PTR+S_BASE
        LDA #YELLOW
        STA SPR_COL+S_BASE
        RTS
be_over:
        DEC lives
        JSR show_lives
        LDA lives
        BEQ be_gone
        LDA spr_on          ; a mystery ship flies on over the new base:
        AND #BIT_UFO        ; PLACE_BASE would take it off the screen
        PHA
        JSR place_base
        PLA
        ORA spr_on
        STA spr_on
        RTS
be_gone:
        LDA spr_on
        AND #255-BIT_BASE
        STA spr_on
        RTS

; ===========================================================================
; THE SHOT
; It moves up SHOT_SPEED pixels a frame. Each frame we look at the screen
; cell under its tip: an alien character there means a hit.
; ===========================================================================
move_shot:
        LDA spr_on
        AND #BIT_SHOT
        BEQ ms_done
        LDA SPR_Y+S_SHOT
        SEC
        SBC #SHOT_SPEED
        STA SPR_Y+S_SHOT
        CMP #58             ; up to row 1: gone
        BCC ms_remove
        JSR shot_hits_ufo
        BCS ms_remove
        JSR shot_hits_bomb
        BCS ms_remove
        LDX #S_SHOT
        LDA #0              ; the tip is its top row of pixels
        JSR sprite_cell
        CMP #C_ALIEN_A
        BCC ms_shield
        CMP #C_BANG         ; screen codes 64-75 are aliens
        BCS ms_shield
        JSR hit_alien
        JMP ms_remove
ms_shield:
        JSR hit_shield
        BCC ms_done
ms_remove:
        LDA spr_on
        AND #255-BIT_SHOT
        STA spr_on
ms_done:
        RTS

; ---------------------------------------------------------------------------
; SPRITE_CELL - which screen cell is under sprite X? A says how many pixels
; below the sprite's top to look; we look 1 pixel in from its left edge.
; Returns the cell's character in A, with (ptr),Y pointing at the cell and
; its position in cell_row and cell_col. Off the screen it returns a space.
; ---------------------------------------------------------------------------
sprite_cell:
        CLC
        ADC SPR_Y,X
        SEC
        SBC #50             ; sprite Y 50 is the top of the screen
        BCC sc_outside
        LSR
        LSR
        LSR                 ; 8 pixel lines to a row of characters
        CMP #25
        BCS sc_outside
        STA cell_row
        TAY
        LDA ROW_LO,Y
        STA ptr
        LDA ROW_HI,Y
        STA ptr+1
        LDA SPR_XLO,X       ; column = (X + 1 - 24) / 8, and X has 9 bits
        SEC
        SBC #23
        STA tmp
        LDA SPR_XHI,X
        SBC #0
        LSR                 ; bit 8 into the carry...
        LDA tmp
        ROR                 ; ...and in at the top: (X - 23) / 2
        LSR
        LSR                 ; (X - 23) / 8
        CMP #40
        BCS sc_outside
        STA cell_col
        TAY
        LDA (ptr),Y
        RTS
sc_outside:
        LDA #SPACE
        RTS

; If A is a shield character, crumble it a little: (ptr),Y is its cell.
; Carry set if it was a shield.
hit_shield:
        CMP #SHIELD_FIRST
        BCC hs_no
        CMP #SHIELD_LAST+1
        BCS hs_no
        SBC #SHIELD_FIRST-1 ; the carry is clear here, so subtract one less
        TAX
        LDA shield_next,X   ; the next, more broken, character
        STA (ptr),Y
        SEC
        RTS
hs_no:
        CLC
        RTS

; Does the shot hit the mystery ship? Carry set if so.
shot_hits_ufo:
        LDA spr_on
        AND #BIT_UFO
        BEQ shu_no
        LDA SPR_Y+S_SHOT
        CMP #UFO_Y+8
        BCS shu_no          ; still below it
        LDX #S_SHOT
        JSR half_x
        STA tmp2
        LDX #S_UFO
        JSR half_x
        STA tmp3
        LDA tmp2
        SEC
        SBC tmp3            ; how far into the 16-pixel ship, in 2-pixel steps
        CMP #8
        BCS shu_no
        JSR ufo_hit
        SEC
        RTS
shu_no:
        CLC
        RTS

; Does the shot hit a bomb? Both go if it does. Carry set if so.
shot_hits_bomb:
        LDX #S_SHOT
        JSR half_x
        STA tmp2
        LDX #S_BOMB
shb_loop:
        LDA spr_on
        AND bit_mask,X
        BEQ shb_next
        JSR half_x
        SEC
        SBC tmp2
        CLC
        ADC #1
        CMP #3              ; within 2 pixels either way
        BCS shb_next
        LDA SPR_Y,X
        SEC
        SBC SPR_Y+S_SHOT
        CLC
        ADC #6
        CMP #13             ; the 7-line bomb and 6-line shot overlap
        BCS shb_next
        LDA bit_mask,X
        EOR #$FF
        AND spr_on
        STA spr_on
        SEC
        RTS
shb_next:
        INX
        CPX #S_BOMB+MAX_BOMBS
        BNE shb_loop
        CLC
        RTS

; ===========================================================================
; BOMBS
; ===========================================================================
; Every so often, the lowest alien in a random column drops a bomb.
drop_bomb:
        LDA dying
        BNE db_done
        DEC bomb_timer
        BNE db_done
        LDA wave            ; bombs come faster each wave
        CMP #11
        BCC db_wave
        LDA #11
db_wave:
        ASL
        STA tmp
        LDA #34
        SEC
        SBC tmp
        STA bomb_timer      ; every 32 frames in wave 1, down to 12
        LDX #S_BOMB         ; find a free bomb sprite
db_free:
        LDA spr_on
        AND bit_mask,X
        BEQ db_found
        INX
        CPX #S_BOMB+MAX_BOMBS
        BNE db_free
db_done:
        RTS
db_found:
        STX counter
        JSR random
        AND #7
        STA tmp2            ; a random column
        LDA #4
        STA tmp3            ; look up from the bottom row
db_row:
        LDA tmp3
        ASL
        ASL
        ASL
        ORA tmp2
        TAY
        LDA ALIVE,Y
        BNE db_drop
        DEC tmp3
        BPL db_row
        RTS                 ; an empty column: no bomb this time
db_drop:
        LDX counter
        LDA #P_BOMB         ; its shape now: next frame UPDATE_SPRITES shows
        STA SPR_PTR,X       ; the bomb before MOVE_BOMBS has run
        LDA tmp3            ; sprite Y = 50 + 8 x (ftop + 2 x row + 1)
        ASL
        SEC
        ADC ftop
        ASL
        ASL
        ASL
        CLC
        ADC #50
        STA SPR_Y,X
        LDY tmp2            ; sprite X = 24 + 8 x (fx + 3 x column) + 7
        LDA times3,Y
        CLC
        ADC fx
        LDY #0
        ASL
        ASL
        ASL                 ; x 8, which can carry into bit 8
        BCC db_low
        INY
db_low:
        CLC
        ADC #24+7
        BCC db_x
        INY
db_x:
        STA SPR_XLO,X
        TYA
        STA SPR_XHI,X
        LDA spr_on
        ORA bit_mask,X
        STA spr_on
        RTS

; Bombs fall BOMB_SPEED pixels a frame until they hit the base, a shield
; or the ground.
move_bombs:
        LDX #S_BOMB
mbo_loop:
        LDA spr_on
        AND bit_mask,X
        BEQ mbo_next
        LDA SPR_Y,X
        CLC
        ADC #BOMB_SPEED
        STA SPR_Y,X
        CMP #50+GROUND_ROW*8-7
        BCS mbo_remove      ; its point has reached the ground
        LDA frame_count     ; wriggle: a new shape every 4 frames
        AND #4
        LSR
        LSR
        CLC
        ADC #P_BOMB
        STA SPR_PTR,X
        JSR bomb_hits_base
        BCS mbo_next        ; the base is hit: every bomb has gone
        TXA
        PHA
        LDA #7              ; look under the bomb's point
        JSR sprite_cell
        JSR hit_shield
        PLA                 ; PLA and TAX leave the carry alone
        TAX
        BCS mbo_remove
mbo_next:
        INX
        CPX #S_BOMB+MAX_BOMBS
        BNE mbo_loop
        RTS
mbo_remove:
        LDA bit_mask,X
        EOR #$FF
        AND spr_on
        STA spr_on
        JMP mbo_next

; Has bomb X hit the base? Carry set if so (and X is kept).
bomb_hits_base:
        LDA dying
        BNE bhb_no
        LDA SPR_Y,X
        CMP #BASE_Y-6       ; its point has reached the top of the base...
        BCC bhb_no
        CMP #BASE_Y+8       ; ...and it is not below it
        BCS bhb_no
        JSR half_x
        STA tmp2
        STX counter
        LDX #S_BASE
        JSR half_x
        LDX counter
        STA tmp3
        LDA tmp2
        SEC
        SBC tmp3
        CLC
        ADC #1
        CMP #9              ; the 3-pixel bomb is over the 15-pixel base
        BCS bhb_no
        JSR base_hit
        LDX counter
        SEC
        RTS
bhb_no:
        CLC
        RTS

; ===========================================================================
; THE MYSTERY SHIP
; ===========================================================================
move_ufo:
        LDA ufo_text_timer  ; its points are showing: rub them out in time
        BEQ mu_ship
        DEC ufo_text_timer
        BNE mu_ship
        LDY ufo_text_col
        LDA #SPACE
        STA SCREEN+2*40,Y
        STA SCREEN+2*40+1,Y
        STA SCREEN+2*40+2,Y
mu_ship:
        LDA spr_on
        AND #BIT_UFO
        BNE mu_fly
        LDA dying           ; no ship: count down to the next one
        BNE mu_done
        LDA frame_count
        AND #3              ; only every 4th frame, so the wait can be long
        BNE mu_done
        DEC ufo_timer
        BNE mu_done
        JMP launch_ufo
mu_fly:
        LDA ufo_dir
        BMI mu_left
        INC SPR_XLO+S_UFO
        BNE mu_right_edge
        INC SPR_XHI+S_UFO
mu_right_edge:
        LDA SPR_XHI+S_UFO   ; gone past the right edge, X 344?
        BEQ mu_siren
        LDA SPR_XLO+S_UFO
        CMP #344-256
        BCS ufo_gone
        JMP mu_siren
mu_left:
        LDA SPR_XLO+S_UFO
        BNE mu_left_low
        DEC SPR_XHI+S_UFO
mu_left_low:
        DEC SPR_XLO+S_UFO
        LDA SPR_XHI+S_UFO   ; gone past the left edge, X 0?
        ORA SPR_XLO+S_UFO
        BEQ ufo_gone
mu_siren:
        LDA sfx_time        ; voice 1 free? sound the siren again
        ORA sfx_start
        BNE mu_done
        LDA #SFX_UFO
        LDX #0
        JMP sfx_play
mu_done:
        RTS
ufo_gone:
        LDA spr_on
        AND #255-BIT_UFO
        STA spr_on
        RTS

; Send a mystery ship across, from alternate sides.
launch_ufo:
        LDA #UFO_Y
        STA SPR_Y+S_UFO
        LDA #P_UFO
        STA SPR_PTR+S_UFO
        LDA ufo_dir
        EOR #$FE
        STA ufo_dir
        BMI lu_right
        LDA #0              ; from the left, out of sight under the border
        STA SPR_XLO+S_UFO
        STA SPR_XHI+S_UFO
        JMP lu_on
lu_right:
        LDA #<344           ; from the right
        STA SPR_XLO+S_UFO
        LDA #>344
        STA SPR_XHI+S_UFO
lu_on:
        LDA spr_on
        ORA #BIT_UFO
        STA spr_on
        JSR random          ; the next one in 10 to 20 seconds
        ORA #128
        STA ufo_timer
        RTS

; The shot hit the mystery ship: 50, 100, 150 or 300 points, shown where it
; was for a second.
ufo_hit:
        LDA spr_on
        AND #255-BIT_UFO
        STA spr_on
        JSR random
        AND #3
        STA tmp3            ; which prize: not tmp, which ADD_SCORE's digits use
        TAX
        LDA ufo_points_hi,X
        PHA
        LDA ufo_points_lo,X
        TAY
        PLA
        TAX
        TYA
        JSR add_score
        LDX #S_UFO          ; column = (X / 2 - 12) / 4
        JSR half_x
        SEC
        SBC #12
        BCS uh_on_screen
        LDA #0
uh_on_screen:
        LSR
        LSR
        CMP #38
        BCC uh_col
        LDA #37
uh_col:
        STA ufo_text_col
        TAY
        LDA tmp3            ; three characters of text for the points
        ASL
        ADC tmp3
        TAX
        LDA ufo_points_text,X
        AND #$3F
        STA SCREEN+2*40,Y
        LDA ufo_points_text+1,X
        AND #$3F
        STA SCREEN+2*40+1,Y
        LDA ufo_points_text+2,X
        AND #$3F
        STA SCREEN+2*40+2,Y
        LDA #LIGHT_RED
        STA COLORS+2*40,Y
        STA COLORS+2*40+1,Y
        STA COLORS+2*40+2,Y
        LDA #50
        STA ufo_text_timer
        LDA #0              ; stop the siren
        STA sfx_time
        STA SID+4
        LDA #SFX_UFO_BOOM
        LDX #1
        JMP sfx_play

; ===========================================================================
; SCORE AND STATUS
; ===========================================================================
; Add to the score: A = tens and units, X = thousands and hundreds, both in
; BCD. With the D flag set, ADC adds decimal digits: $19 + $01 = $20.
add_score:
        SED
        CLC
        ADC score
        STA score
        TXA
        ADC score+1
        STA score+1
        LDA #0
        ADC score+2
        STA score+2
        CLD
        LDA #6
        JMP show_score

; The top line: score, high score and wave.
show_status:
        LDA #<status_text
        LDX #>status_text
        JSR print
        LDX #hiscore+2
        LDY #21
        LDA #3
        JSR print_bcd
        LDX #wave_bcd
        LDY #38
        LDA #1
        JSR print_bcd
        LDA #6
show_score:
        TAY
        LDX #score+2
        LDA #3
        ; fall through to print_bcd

; Print A bytes of BCD on the top line at column Y, starting from the
; zero-page byte at X and working down: two digits per byte.
print_bcd:
        STA tmp
pb_byte:
        LDA $00,X
        LSR
        LSR
        LSR
        LSR
        ORA #$30            ; screen code of the digit
        STA SCREEN,Y
        INY
        LDA $00,X
        AND #$0F
        ORA #$30
        STA SCREEN,Y
        INY
        DEX
        DEC tmp
        BNE pb_byte
        RTS

update_hiscore:
        LDA score+2         ; compare from the top byte down
        CMP hiscore+2
        BCC uh_done
        BNE uh_new
        LDA score+1
        CMP hiscore+1
        BCC uh_done
        BNE uh_new
        LDA score
        CMP hiscore
        BCC uh_done
uh_new:
        LDA score
        STA hiscore
        LDA score+1
        STA hiscore+1
        LDA score+2
        STA hiscore+2
uh_done:
        RTS

; The bottom line: the number of lives and a small base for each spare one.
show_lives:
        LDX #39
        LDA #SPACE
sl_clear:
        STA SCREEN+LIVES_ROW*40,X
        DEX
        BPL sl_clear
        LDA lives
        ORA #$30
        STA SCREEN+LIVES_ROW*40+1
        LDA #WHITE
        STA COLORS+LIVES_ROW*40+1
        LDX lives
        DEX
        BEQ sl_done
        BMI sl_done
        CPX #12             ; no more than fit on the line
        BCC sl_icons
        LDX #12
sl_icons:
        LDY #3
sl_icon:
        LDA #C_LIFE
        STA SCREEN+LIVES_ROW*40,Y
        LDA #GREEN
        STA COLORS+LIVES_ROW*40,Y
        INY
        INY
        DEX
        BNE sl_icon
sl_done:
        RTS

; ===========================================================================
; SCREEN HELPERS
; ===========================================================================
clear_screen:
        LDX #0
cs_loop:
        LDA #SPACE
        STA SCREEN,X
        STA SCREEN+$100,X
        STA SCREEN+$200,X
        STA SCREEN+$2E8,X   ; ends at $07E7, short of the sprite pointers
        LDA #WHITE
        STA COLORS,X
        STA COLORS+$100,X
        STA COLORS+$200,X
        STA COLORS+$2E8,X
        INX
        BNE cs_loop
        RTS

draw_ground:
        LDX #39
dg_loop:
        LDA #C_GROUND
        STA SCREEN+GROUND_ROW*40,X
        LDA #GREEN
        STA COLORS+GROUND_ROW*40,X
        DEX
        BPL dg_loop
        RTS

; Four shields, each 4 characters wide and 3 high.
draw_shields:
        LDA #3
        STA tmp
ds_shield:
        LDX tmp
        LDY shield_cols,X   ; this shield's left column
        LDX #0              ; position across the shape
ds_cell:
        LDA shield_shape,X
        STA SCREEN+SHIELD_ROW*40,Y
        LDA shield_shape+4,X
        STA SCREEN+SHIELD_ROW*40+40,Y
        LDA shield_shape+8,X
        STA SCREEN+SHIELD_ROW*40+80,Y
        LDA #GREEN
        STA COLORS+SHIELD_ROW*40,Y
        STA COLORS+SHIELD_ROW*40+40,Y
        STA COLORS+SHIELD_ROW*40+80,Y
        INY
        INX
        CPX #4
        BNE ds_cell
        DEC tmp
        BPL ds_shield
        RTS

; Build the table of screen row addresses: SCREEN + 40 x row.
make_row_table:
        LDA #<SCREEN
        STA ptr
        LDA #>SCREEN
        STA ptr+1
        LDX #0
mrt_loop:
        LDA ptr
        STA ROW_LO,X
        LDA ptr+1
        STA ROW_HI,X
        LDA ptr
        CLC
        ADC #40
        STA ptr
        BCC mrt_next
        INC ptr+1
mrt_next:
        INX
        CPX #25
        BNE mrt_loop
        RTS

; Copy the letters, digits and punctuation (screen codes 0-63) from the
; character ROM. The ROM hides under the I/O chips at $D000 until bit 2 of
; $01 is cleared - and with interrupts off, as nothing can reach the
; chips meanwhile.
copy_font:
        LDA $01
        PHA
        AND #%11111011
        STA $01
        LDY #0
cf_loop:
        LDA $D000,Y
        STA CHARSET,Y
        LDA $D100,Y
        STA CHARSET+$100,Y
        INY
        BNE cf_loop
        PLA
        STA $01
        RTS

; ---------------------------------------------------------------------------
; PRINT - print a message: A = low byte and X = high byte of its address.
; A message is a row, a column and a colour, then the text and a zero.
; PRINT_LIST prints messages one after another until a row of $FF.
; ---------------------------------------------------------------------------
print_list:
        STA ptr
        STX ptr+1
pl_next:
        LDY #0
        LDA (ptr),Y
        CMP #$FF
        BEQ pl_done
        JSR print_here
        JMP pl_next
pl_done:
        RTS

print:
        STA ptr
        STX ptr+1
print_here:
        LDY #0
        LDA (ptr),Y         ; row
        TAX
        INY
        LDA (ptr),Y         ; column
        CLC
        ADC ROW_LO,X
        STA ptr2
        STA cptr
        LDA ROW_HI,X
        ADC #0
        STA ptr2+1
        CLC
        ADC #>(COLORS-SCREEN)
        STA cptr+1
        INY
        LDA (ptr),Y         ; colour
        STA tmp
        LDA ptr             ; skip the three bytes to the text
        CLC
        ADC #3
        STA ptr
        BCC ph_text
        INC ptr+1
ph_text:
        LDY #0
ph_loop:
        LDA (ptr),Y
        BEQ ph_end
        AND #$3F            ; PETSCII to screen code, for letters and digits
        STA (ptr2),Y
        LDA tmp
        STA (cptr),Y
        INY
        BNE ph_loop
ph_end:
        INY                 ; leave ptr after the zero, at the next message
        TYA
        CLC
        ADC ptr
        STA ptr
        BCC ph_done
        INC ptr+1
ph_done:
        RTS

; A pseudo-random number in A: an 8-bit linear feedback shift register,
; which runs through all 255 values except zero before repeating.
random:
        LDA seed
        ASL
        BCC rnd_done
        EOR #$1D
rnd_done:
        STA seed
        RTS

; ===========================================================================
; SOUND EFFECTS
; Each effect is a row of 8 bytes in SFX_TABLE. SFX_PLAY copies a row into
; the variables for one of the SID's three voices; SFX_UPDATE, called by
; the interrupt every frame, starts the note and slides its frequency.
; ===========================================================================
init_sid:
        LDA #0
        LDX #$18
is_clear:
        STA SID,X
        DEX
        BPL is_clear
        STA sfx_start
        STA sfx_start+1
        STA sfx_start+2
        STA sfx_time
        STA sfx_time+1
        STA sfx_time+2
        LDA #15             ; full volume
        STA SID+$18
        RTS

; Play effect A (its offset in SFX_TABLE) on voice X (0, 1 or 2).
sfx_play:
        TAY
        LDA sfx_table,Y
        STA sfx_wave,X
        LDA sfx_table+1,Y
        STA sfx_ad,X
        LDA sfx_table+2,Y
        STA sfx_sr,X
        LDA sfx_table+3,Y
        STA sfx_flo,X
        LDA sfx_table+4,Y
        STA sfx_fhi,X
        LDA sfx_table+5,Y
        STA sfx_dlo,X
        LDA sfx_table+6,Y
        STA sfx_dhi,X
        LDA sfx_table+7,Y
        STA sfx_time,X
        LDA #1
        STA sfx_start,X     ; last, so the interrupt never sees half an effect
        RTS

sfx_update:
        LDX #2
su_voice:
        LDY voice_regs,X    ; Y = offset of this voice's SID registers
        LDA sfx_start,X
        BEQ su_running
        LDA #0              ; a new effect: restart the envelope
        STA sfx_start,X
        STA SID+4,Y         ; gate off...
        LDA sfx_ad,X
        STA SID+5,Y
        LDA sfx_sr,X
        STA SID+6,Y
        LDA #8
        STA SID+3,Y         ; pulse width 50%, for the pulse waveform
        LDA sfx_wave,X
        ORA #1              ; ...and on again: attack, decay, sustain
        STA SID+4,Y
        JMP su_freq
su_running:
        LDA sfx_time,X
        BEQ su_next         ; nothing playing
        DEC sfx_time,X
        BNE su_slide
        LDA sfx_wave,X      ; time is up: gate off, so the note releases
        STA SID+4,Y
        JMP su_next
su_slide:
        LDA sfx_flo,X
        CLC
        ADC sfx_dlo,X
        STA sfx_flo,X
        LDA sfx_fhi,X
        ADC sfx_dhi,X
        STA sfx_fhi,X
su_freq:
        LDA sfx_flo,X
        STA SID,Y
        LDA sfx_fhi,X
        STA SID+1,Y
su_next:
        DEX
        BPL su_voice
        RTS

; ===========================================================================
; DATA
; ===========================================================================
voice_regs:     BYTE 0, 7, 14           ; each voice has 7 SID registers
bit_mask:       BYTE 1, 2, 4, 8, 16, 32, 64, 128
times3:         BYTE 0, 3, 6, 9, 12, 15, 18, 21

; The five rows of the armada, top to bottom
row_char:       BYTE C_ALIEN_A, C_ALIEN_B, C_ALIEN_B, C_ALIEN_C, C_ALIEN_C
row_points:     BYTE $30, $20, $20, $10, $10    ; BCD

; The colour of each screen row, top to bottom
band_colors:    BYTE WHITE, WHITE, WHITE, WHITE
                BYTE YELLOW, YELLOW
                BYTE CYAN, CYAN, CYAN, CYAN
                BYTE LIGHT_GREEN, LIGHT_GREEN, LIGHT_GREEN, LIGHT_GREEN
                BYTE LIGHT_BLUE, LIGHT_BLUE, LIGHT_BLUE, LIGHT_BLUE
                BYTE GREEN, GREEN, GREEN, GREEN, GREEN, GREEN
                BYTE WHITE

; The mystery ship's points, in BCD, and as text
ufo_points_lo:  BYTE $50, $00, $50, $00
ufo_points_hi:  BYTE $00, $01, $01, $03
ufo_points_text: TEXT " 50100150300"

; The shields: where they are, their shape, and how each piece crumbles
shield_cols:    BYTE 5, 14, 23, 32
shield_shape:   BYTE C_CORNER_L, C_SHIELD, C_SHIELD, C_CORNER_R
                BYTE C_SHIELD, C_SHIELD, C_SHIELD, C_SHIELD
                BYTE C_SHIELD, SPACE, SPACE, C_SHIELD
shield_next:    BYTE C_SHIELD+1, C_SHIELD+2, C_SHIELD+3, SPACE
                BYTE C_CORNER_L+1, SPACE, C_CORNER_R+1, SPACE

title_alien_row:   BYTE 11, 14, 17
title_alien_char:  BYTE C_ALIEN_A, C_ALIEN_B, C_ALIEN_C
title_alien_color: BYTE YELLOW, CYAN, LIGHT_GREEN

; Messages: row, column, colour, then the text
status_text:
        BYTE 0, 0, WHITE
        ASCIIZ "SCORE 000000      HI 000000      WAVE 00"
over_text:
        BYTE OVER_ROW, 15, WHITE
        ASCIIZ "GAME OVER"
title_text:
        BYTE 4, 8, WHITE
        ASCIIZ "A L I E N   A R M A D A"
        BYTE 8, 17, LIGHT_RED
        ASCIIZ "= ?? MYSTERY"
        BYTE 11, 17, YELLOW
        ASCIIZ "= 30 POINTS"
        BYTE 14, 17, CYAN
        ASCIIZ "= 20 POINTS"
        BYTE 17, 17, LIGHT_GREEN
        ASCIIZ "= 10 POINTS"
        BYTE 20, 11, WHITE
        ASCIIZ "PRESS FIRE TO PLAY"
        BYTE 22, 11, GREY
        ASCIIZ "JOYSTICK IN PORT 2"
        BYTE $FF

; ---------------------------------------------------------------------------
; Sound effects, 8 bytes each:
;   waveform (16 triangle, 32 sawtooth, 64 pulse, 128 noise),
;   attack/decay, sustain/release,
;   frequency low, high; change per frame low, high; length in frames.
; The SID's frequency number is about 17 times the pitch in Hz.
; ---------------------------------------------------------------------------
SFX_SHOT      = 0
SFX_BOOM      = 8
SFX_BASE_BOOM = 16
SFX_UFO       = 24
SFX_UFO_BOOM  = 32
SFX_CLEARED   = 40
SFX_MARCH     = 48          ; four notes, 8 bytes apart
sfx_table:
        BYTE 32,  $08, $00, $00, $50, $00, $FC, 12   ; shot: sawtooth swooping down
        BYTE 128, $08, $00, $00, $24, $80, $FE, 16   ; alien hit: a burst of noise
        BYTE 128, $0A, $00, $00, $18, $E0, $FF, 100  ; base hit: a long rumble
        BYTE 16,  $00, $F0, $00, $1C, $80, $00, 16   ; mystery ship: rising siren
        BYTE 128, $09, $00, $00, $30, $80, $FE, 24   ; mystery ship hit
        BYTE 16,  $00, $F4, $00, $10, $80, $01, 40   ; wave cleared: a whistle up
        BYTE 64,  $06, $00, $85, $06, $00, $00, 6    ; march: G
        BYTE 64,  $06, $00, $27, $06, $00, $00, 6    ;        F sharp
        BYTE 64,  $06, $00, $CE, $05, $00, $00, 6    ;        F
        BYTE 64,  $06, $00, $7B, $05, $00, $00, 6    ;        E

; ===========================================================================
; SPRITE SHAPES
; A sprite is 24 x 21 pixels: 3 bytes a line, 63 bytes, in a 64-byte block.
; The VIC-II finds block N at address N x 64, so $2000 is shape 128. Each
; shape here starts at its own ORG; the lines left out are empty.
; ===========================================================================
        ORG SPRITE_DATA     ; 128: the base
        BYTE %00000001,%00000000,0
        BYTE %00000011,%10000000,0
        BYTE %00000011,%10000000,0
        BYTE %01111111,%11111100,0
        BYTE %11111111,%11111110,0
        BYTE %11111111,%11111110,0
        BYTE %11111111,%11111110,0
        BYTE %11111111,%11111110,0

        ORG SPRITE_DATA+1*64 ; 129: the shot
        BYTE %11000000,0,0
        BYTE %11000000,0,0
        BYTE %11000000,0,0
        BYTE %11000000,0,0
        BYTE %11000000,0,0
        BYTE %11000000,0,0

        ORG SPRITE_DATA+2*64 ; 130: a bomb
        BYTE %01000000,0,0
        BYTE %10000000,0,0
        BYTE %01000000,0,0
        BYTE %00100000,0,0
        BYTE %01000000,0,0
        BYTE %10000000,0,0
        BYTE %01000000,0,0

        ORG SPRITE_DATA+3*64 ; 131: the bomb, wriggled
        BYTE %01000000,0,0
        BYTE %00100000,0,0
        BYTE %01000000,0,0
        BYTE %10000000,0,0
        BYTE %01000000,0,0
        BYTE %00100000,0,0
        BYTE %01000000,0,0

        ORG SPRITE_DATA+4*64 ; 132: the mystery ship
        BYTE %00000111,%11100000,0
        BYTE %00011111,%11111000,0
        BYTE %00111111,%11111100,0
        BYTE %01101101,%10110110,0
        BYTE %11111111,%11111111,0
        BYTE %00111001,%10011100,0
        BYTE %00010000,%00001000,0

        ORG SPRITE_DATA+5*64 ; 133: the base exploding
        BYTE %00100000,%10000100,0
        BYTE %10001010,%00100001,0
        BYTE %00010010,%10010100,0
        BYTE %01001111,%11100100,0
        BYTE %00111111,%11111000,0
        BYTE %10111111,%11111010,0
        BYTE %01111111,%11111100,0
        BYTE %11111111,%11111110,0

        ORG SPRITE_DATA+6*64 ; 134: and its second frame
        BYTE %10000100,%01000100,0
        BYTE %00100000,%10010001,0
        BYTE %10001010,%00010100,0
        BYTE %00101110,%11100100,0
        BYTE %01111111,%11110100,0
        BYTE %00111111,%11111000,0
        BYTE %10111111,%11110101,0
        BYTE %11111111,%11111110,0

; ===========================================================================
; CHARACTERS
; 8 bytes each, one per line of 8 pixels. Screen code N is at CHARSET + 8N,
; so the game's own characters, from code 64, start at CHARSET + $200.
; ===========================================================================
        ORG CHARSET+64*8

; ALIEN CHARACTERS: each alien is a left and a right half, in two frames.
; The top row's alien (30 points), first frame then second
        BYTE %00000011,%00001111,%00011001,%00011111,%00000110,%00001101,%00011000,%00001000
        BYTE %11000000,%11110000,%10011000,%11111000,%01100000,%10110000,%00011000,%00010000
        BYTE %00000011,%00001111,%00011001,%00011111,%00000110,%00001101,%00001010,%00010000
        BYTE %11000000,%11110000,%10011000,%11111000,%01100000,%10110000,%01010000,%00001000
; The middle rows' alien (20 points)
        BYTE %00110000,%00010011,%00001111,%00111010,%01111111,%11011111,%10011000,%00011000
        BYTE %00001100,%11001000,%11110000,%01011100,%11111110,%11111011,%00011001,%00011000
        BYTE %00110000,%00010011,%00001111,%00111010,%01111111,%00111111,%00101100,%01001000
        BYTE %00001100,%11001000,%11110000,%01011100,%11111110,%11111100,%00110100,%00010010
; The bottom rows' alien (10 points)
        BYTE %00000111,%00111111,%01110011,%01111111,%00001110,%00011001,%00110000,%00000000
        BYTE %11100000,%11111100,%11001110,%11111110,%01110000,%10011000,%00001100,%00000000
        BYTE %00000111,%00111111,%01110011,%01111111,%00001110,%00011011,%00001100,%00000000
        BYTE %11100000,%11111100,%11001110,%11111110,%01110000,%11011000,%00110000,%00000000
; An alien exploding
        BYTE %01000010,%00100001,%10001000,%00100000,%11000000,%00100000,%10001000,%01000010
        BYTE %01000010,%10000100,%00010001,%00000100,%00000011,%00000100,%00010001,%01000010
; Shield block: whole, then crumbling in three steps
        BYTE %11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111
        BYTE %11101111,%11111111,%10111011,%11111111,%11110111,%11011110,%11111111,%01111011
        BYTE %01101011,%11011101,%10110110,%11101011,%01011101,%10110110,%01101101,%11011010
        BYTE %01001001,%00100010,%10010100,%01000001,%00101010,%10000100,%01010010,%00001000
; Shield corners, left then right: whole, then crumbling
        BYTE %00001111,%00011111,%00111111,%01111111,%11111111,%11111111,%11111111,%11111111
        BYTE %00000101,%00011010,%00100101,%01011011,%10110110,%01101101,%11011010,%10110101
        BYTE %11110000,%11111000,%11111100,%11111110,%11111111,%11111111,%11111111,%11111111
        BYTE %10100000,%01011000,%10100100,%11011010,%01101101,%10110110,%01011011,%10101101
; The ground
        BYTE %11111111,%11111111,0,0,0,0,0,0
; A spare base, for the lives line
        BYTE %00011000,%00111100,%01111110,%11111111,%11111111,0,0,0
