; ===========================================================================
;                              NOVA STRIKE
; ===========================================================================
; Fly through an endless alien cave, blasting waves of enemies, in the style
; of the side-scrolling arcade shooters of 1987. Written in 6502 assembly
; for the Commodore 64; everything is in this one file.
;
; HOW TO PLAY
;   Joystick in port 2 (on this page: arrow keys, and Space for fire).
;   Fly in any direction. Tap fire to shoot. Hold fire to charge the BEAM
;   gauge, then let go to fire a beam that cuts through every enemy in its
;   path (only the cave and the guardian stop it). Don't touch the cave
;   walls, the enemies or their bullets.
;   Destroy the guardian at the end of each stage.
;
; WHAT TO LOOK FOR
;   - The cave is never stored: each new column is invented as it scrolls
;     in, by nudging the height of the roof and floor at random.
;   - Smooth scrolling with $D016 and an unrolled loop that moves 21 rows
;     of characters every 8 frames (the same engine as Jumpin' Jo).
;   - Collisions with the cave come from reading screen memory under the
;     ship, allowing for the fine scroll.
;   - Enemy waves are rows in a table: when, what, how many, where.
;   - Sprite stretching: the beam is stretched across, and the guardian
;     both ways, with $D01D and $D017.
;
; MEMORY MAP
;   $0400-$07FF  screen
;   $0810-       the program
;   $2800-$2A7F  sprite shapes (pointers 160-169)
;   $3800-$39FF  letters and digits, copied from the character ROM
;   $3A00-$3A2F  the cave's characters (codes 64-69)
;   $C000-$C0FF  tables
;
; THINGS TO TRY
;   - More ships: change START_SHIPS.
;   - A roomier or tighter cave: change MIN_GAP.
;   - Design your own attack waves in WAVES.
;   - Make the beam charge faster: change BEAM_READY.
; ===========================================================================

; ---------------------------------------------------------------------------
; Settings
; ---------------------------------------------------------------------------
START_SHIPS  = 3
SHIP_SPEED   = 2
SHOT_SPEED   = 6
BEAM_SPEED   = 8
BEAM_READY   = 32           ; frames of holding fire before the beam is ready
MAX_CHARGE   = 64
MIN_GAP      = 9            ; rows of open space the cave always leaves
BOSS_HP      = 40

; ---------------------------------------------------------------------------
; The C64
; ---------------------------------------------------------------------------
VIC         = $D000
SID         = $D400
SCREEN      = $0400
COLORS      = $D800
CHARSET     = $3800
SPRITE_PTRS = $07F8
JOYSTICK    = $DC00

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
BLUE        = 6
YELLOW      = 7
ORANGE      = 8
BROWN       = 9
LIGHT_RED   = 10
DARK_GREY   = 11
GREY        = 12
LIGHT_GREEN = 13
LIGHT_BLUE  = 14
LIGHT_GREY  = 15
MULTI       = 8

; ---------------------------------------------------------------------------
; The cave
; ---------------------------------------------------------------------------
FIELD_TOP   = 4             ; the cave fills screen rows 4-24
FIELD_ROWS  = 21
C_STAR1     = 64
C_STAR2     = 65
C_ROCK      = 66            ; codes from here up are solid rock
C_CEILING   = 67
C_FLOOR     = 68
C_GAUGE     = 69            ; a solid block, for the beam gauge

; ---------------------------------------------------------------------------
; Sprites
; ---------------------------------------------------------------------------
S_SHIP      = 0
S_SHOT      = 1             ; 1 and 2; slot 1 also carries the beam
S_ENEMY     = 3             ; 3-6
MAX_ENEMIES = 4
S_BULLET    = 7
BIT_BEAM    = 2             ; the same sprites as bits of $D015/$D01D/$D017
BIT_BOSS    = 8
BIT_BULLET  = 128
SPRITE_DATA = $2800
P_SHIP      = SPRITE_DATA/64 ; 160
P_SHOT      = P_SHIP+1
P_BEAM      = P_SHIP+2
P_SAUCER    = P_SHIP+3      ; enemy shapes, in type order
P_BOOM      = P_SHIP+6      ; two frames
P_BOSS      = P_SHIP+8
P_BULLET    = P_SHIP+9
T_SAUCER    = 0             ; enemy types
T_ORB       = 1
T_DART      = 2
T_BOSS      = 3

; ---------------------------------------------------------------------------
; Zero page
; ---------------------------------------------------------------------------
frame_count = $02
joy         = $03
fire_armed  = $04
fire_held   = $05           ; fire was down last frame
ptr         = $06           ; $06-$07
cptr        = $08           ; $08-$09
tmp         = $0A
tmp2        = $0B
tmp3        = $0C
counter     = $0D
src         = $0E           ; $0E-$0F
seed_spare  = $10           ; (unused)
ship_xlo    = $11           ; the ship's sprite X (9 bits) and Y
ship_xhi    = $12
ship_y      = $13
charge      = $14
xscroll     = $15
xscroll_next = $16
shift_due   = $17
column_due  = $18
top_h       = $19           ; rows of roof in the newest column
bot_h       = $1A           ; rows of floor
ships       = $1B
score       = $1C           ; $1C-$1E BCD
hiscore     = $1F           ; $1F-$21
dead        = $22           ; frames of the ship exploding, 0 = flying
safe        = $23           ; frames of flashing invulnerability
stage       = $24
wave_ptr    = $25           ; $25-$26: the next row of WAVES
wave_wait   = $27           ; frames until the next enemy
wave_left   = $28           ; enemies left in this wave
wave_type   = $29
wave_y      = $2A
wave_gap    = $2B
boss_on     = $2C
spr_on      = $2D
music_on    = $2E
mus_note    = $2F
sfx_start   = $30           ; sound effects, one byte per voice
sfx_time    = $33
sfx_wave    = $36
sfx_ad      = $39
sfx_sr      = $3C
sfx_flo     = $3F
sfx_fhi     = $42
sfx_dlo     = $45
sfx_dhi     = $48
mus_wait    = $4B           ; music: two voices
mus_pos     = $4D
sid_off     = $4F
mptr2       = $50           ; $50-$51
bullet_dy   = $52
bonus_timer = $53
enemy       = $54           ; the enemy being moved
fire_rate   = $55           ; chance an enemy fires each frame, out of 256
wave_pause  = $56
t_x         = $57           ; $57-$58: a sprite X to look under
box_ax      = $59           ; two boxes for OVERLAP, in 2-pixel steps across
box_aw      = $5A
box_ay      = $5B
box_ah      = $5C
box_bx      = $5D
box_bw      = $5E
box_by      = $5F
box_bh      = $60
seed        = $61           ; $61-$62: the random number generator
top_d016    = $63           ; what IRQ_TOP puts in $D016, before the scroll
spr_wide    = $64           ; what UPDATE_SPRITES puts in $D01D and $D017, so
spr_tall    = $65           ; a sprite changes size with its shape, not before

ROW_LO      = $C000
ROW_HI      = $C020
SPR_XLO     = $C040
SPR_XHI     = $C048
SPR_Y       = $C050
SPR_PTR     = $C058
E_ON        = $C060         ; enemies: 0 none, 1 flying, 2 exploding
E_TYPE      = $C064
E_XLO       = $C068
E_XHI       = $C06C
E_Y         = $C070
E_BASE      = $C074         ; centre line of an orb's wave
E_T         = $C078         ; a timer for each enemy
E_HP        = $C07C
SHOT_ON     = $C080         ; 0 none, 1 shot, 2 beam
SHOT_XLO    = $C082
SHOT_XHI    = $C084
SHOT_Y      = $C086
BULLET_ON   = $C088
BULLET_XLO  = $C089
BULLET_XHI  = $C08A
BULLET_Y    = $C08B

; ===========================================================================
; START
; ===========================================================================
        ORG $0810           ; SYS 2064

start:
        SEI
        CLD
        LDA #$7F
        STA $DC0D
        LDA $DC0D
        LDA #$FF
        STA JOYSTICK
        JSR make_row_table
        JSR copy_font
        JSR init_sound
        LDA #BLACK
        STA VIC+$20
        STA VIC+$21
        LDA #$1E            ; screen $0400, characters $3800
        STA VIC+$18
        LDA #%01111001      ; multicolour: the ship and enemies
        STA VIC+$1C
        LDA #DARK_GREY
        STA VIC+$25
        LDA #WHITE
        STA VIC+$26
        LDA #LIGHT_GREY     ; stars and highlights
        STA VIC+$22
        LDA #BROWN          ; rock
        STA VIC+$23
        LDA #0
        STA VIC+$17
        STA VIC+$1D
        STA VIC+$1B
        STA VIC+$15
        STA spr_on
        STA score
        STA score+1
        STA score+2
        STA hiscore
        STA hiscore+1
        STA hiscore+2
        STA xscroll
        LDA #%00011000      ; IRQ_TOP can run before the title screen sets it
        STA top_d016
        LDA #<irq_bottom
        STA $0314
        LDA #>irq_bottom
        STA $0315
        LDA #251
        STA VIC+$12
        LDA VIC+$11
        AND #$7F
        STA VIC+$11
        LDA #1
        STA VIC+$1A
        STA VIC+$19
        LDA VIC+$12
        ORA #1
        STA seed
        STA seed+1
        CLI

main_loop:
        JSR title_screen
        JSR play_game
        JMP main_loop

; ===========================================================================
; THE RASTER SPLIT (as in Jumpin' Jo)
; IRQ_TOP, at line 67, scrolls everything below the status lines; IRQ_BOTTOM,
; at line 251, keeps the status lines at the top of the next frame still.
; ===========================================================================
irq_top:
        CLD                 ; the 6502 keeps decimal mode for an interrupt
        LDA #1
        STA VIC+$19
        LDA xscroll
        ORA top_d016        ; multicolour; 38 columns while playing
        STA VIC+$16
        LDA #<irq_bottom
        STA $0314
        LDA #>irq_bottom
        STA $0315
        LDA #251
        STA VIC+$12
        JMP $EA81

irq_bottom:
        CLD                 ; SFX_UPDATE's ADC must add in binary
        LDA #1
        STA VIC+$19
        LDA #%00011000      ; multicolour, 40 columns, no scroll
        STA VIC+$16
        INC frame_count
        JSR music_update
        JSR sfx_update
        LDA #<irq_top
        STA $0314
        LDA #>irq_top
        STA $0315
        LDA #67
        STA VIC+$12
        JMP $EA81

wait_frame:
        LDA frame_count
wf_wait:
        CMP frame_count
        BEQ wf_wait
        RTS

wait_frames:
        STA counter
wfs_loop:
        JSR wait_frame
        JSR update_sprites
        DEC counter
        BNE wfs_loop
        RTS

read_joystick:
        LDA JOYSTICK
        EOR #$FF
        AND #%00011111
        STA joy
        RTS

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
        CMP #1
        LDA #0
        STA fire_armed
        RTS

update_sprites:
        LDA #0
        STA tmp
        LDX #7
us_loop:
        TXA
        ASL
        TAY
        LDA SPR_XLO,X
        STA VIC,Y
        LDA SPR_Y,X
        STA VIC+1,Y
        LDA SPR_XHI,X
        LSR
        ROL tmp
        LDA SPR_PTR,X
        STA SPRITE_PTRS,X
        DEX
        BPL us_loop
        LDA tmp
        STA VIC+$10
        LDA spr_on
        STA VIC+$15
        LDA spr_wide
        STA VIC+$1D
        LDA spr_tall
        STA VIC+$17
        RTS

; A pseudo-random number in A: a 16-bit linear feedback shift register,
; stepped 8 times so that every bit is new. The cave uses a lot of random
; numbers, and this one only repeats after 65535 steps. X and Y are kept.
random:
        TYA
        PHA
        LDY #8
        LDA seed
rnd_bit:
        ASL
        ROL seed+1
        BCC rnd_next
        EOR #$2D
rnd_next:
        DEY
        BNE rnd_bit
        STA seed
        PLA
        TAY
        LDA seed
        RTS

; ===========================================================================
; THE TITLE SCREEN
; ===========================================================================
title_screen:
        JSR clear_screen
        LDA #START_SHIPS    ; what a new game starts with
        STA ships
        LDA #%00011000      ; 40 columns: nothing scrolls here
        STA top_d016
        LDA #0
        STA stage
        STA fire_armed
        STA xscroll
        STA spr_on
        STA spr_wide
        STA spr_tall
        LDA #<title_text
        LDX #>title_text
        JSR print_list
        JSR show_status
        LDX #3              ; the ship and the three enemies, as a key
ts_key:
        LDA title_key_y,X
        STA SPR_Y+S_ENEMY,X
        LDA #24+12*8
        STA SPR_XLO+S_ENEMY,X
        LDA #0
        STA SPR_XHI+S_ENEMY,X
        LDA title_key_shape,X
        STA SPR_PTR+S_ENEMY,X
        LDA title_key_color,X
        STA VIC+$27+S_ENEMY,X
        DEX
        BPL ts_key
        LDA #%01111000
        STA spr_on
        JSR start_music
ts_loop:
        JSR wait_frame
        JSR update_sprites
        JSR fire_pressed
        BCC ts_loop
        LDA frame_count
        EOR seed
        ORA #1
        STA seed
        RTS

; ===========================================================================
; THE GAME
; ===========================================================================
play_game:
        LDA #0
        STA score
        STA score+1
        STA score+2
        STA stage
        LDA #START_SHIPS
        STA ships
pg_stage:
        JSR start_stage
pg_life:
        JSR new_ship

; One pass per frame: the scroll first (it starts in the bottom border and is
; done before the beam reaches the cave), then everything else.
pg_loop:
        JSR wait_frame
        JSR apply_scroll
        JSR update_sprites
        JSR read_joystick
        JSR scroll_cave
        JSR new_column
        JSR move_ship
        JSR fire_control
        JSR move_shots
        JSR spawn_enemies
        JSR move_enemies
        JSR move_bullet
        JSR hit_checks
        JSR show_gauge
        LDA dead
        BEQ pg_alive
        DEC dead
        BNE pg_loop
        DEC ships
        BEQ pg_over
        JSR show_status
        JMP pg_life
pg_alive:
        LDA boss_on
        CMP #2              ; the guardian is destroyed: the stage is cleared
        BNE pg_loop
        LDA #0
        STA spr_on
        LDA #SFX_STAGE
        LDX #2
        JSR sfx_play
        LDA #<clear_text
        LDX #>clear_text
        JSR print
        LDA #$00            ; 5000 points
        LDX #$50
        JSR add_score
        LDA #150
        JSR wait_frames
        INC stage
        JMP pg_stage
pg_over:
        LDA #0
        STA spr_on
        STA music_on
        JSR silence_music
        JSR update_hiscore
        JSR show_status     ; no ships left, and perhaps a new high score
        LDA #<over_text
        LDX #>over_text
        JSR print
        LDA #150
        JMP wait_frames

; A new stage: a fresh, flat stretch of cave and the first wave.
start_stage:
        LDA #0
        STA spr_on
        STA VIC+$15         ; now, not next frame: the title's sprites would
        JSR clear_screen    ; stay up while the cave is drawn
        LDX #0              ; colour RAM: the rock's third colour, rows 4-24
        LDA #RED+MULTI
cs_colors:
        STA COLORS+160,X
        STA COLORS+416,X
        STA COLORS+672,X
        STA COLORS+744,X
        INX
        BNE cs_colors
        LDA #2
        STA top_h
        STA bot_h
        LDA #0
        STA counter
ss_col:
        LDY counter
        JSR draw_column
        INC counter
        LDA counter
        CMP #40
        BNE ss_col
        LDA #<waves
        STA wave_ptr
        LDA #>waves
        STA wave_ptr+1
        LDA #120
        STA wave_wait
        LDA stage           ; enemies fire more often each stage
        ASL
        CLC
        ADC #3
        STA fire_rate
        LDA #0
        STA wave_left
        STA boss_on
        STA shift_due
        STA column_due
        STA xscroll
        STA xscroll_next
        LDX #MAX_ENEMIES-1  ; no enemies left over from the last stage or game
ss_enemies:
        STA E_ON,X
        DEX
        BPL ss_enemies
        LDA #%00010000      ; multicolour, 38 columns to hide the scrolling edges
        STA top_d016
        JSR show_status
        JMP start_music

; A new ship at the left, safe for a couple of seconds.
new_ship:
        LDA #24+16
        STA ship_xlo
        LDA #0
        STA ship_xhi
        STA dead
        STA charge
        STA fire_held
        STA BULLET_ON
        STA SHOT_ON
        STA SHOT_ON+1
        LDA spr_wide        ; no beam, but a guardian stays stretched
        AND #255-BIT_BEAM
        STA spr_wide
        LDA #50+13*8
        STA ship_y
        LDA #100
        STA safe
        LDA #P_SHIP
        STA SPR_PTR+S_SHIP
        LDA #LIGHT_BLUE
        STA VIC+$27+S_SHIP
        LDA spr_on          ; no shots or bullet; the enemies stay in view
        AND #%01111000
        ORA #1
        STA spr_on
        JMP ms_place        ; now, or its sprite shows where it last was

; ===========================================================================
; THE CAVE
; ===========================================================================
; At the very start of a frame, in the border: set the fine scroll IRQ_TOP
; will use at line 67, then move the characters if the scroll has wrapped.
; The move takes until about line 70, past IRQ_TOP, so the fine scroll has
; to be ready first; the cave itself starts at line 83.
apply_scroll:
        LDA xscroll_next
        STA xscroll
        LDA shift_due
        BEQ as_done
        JSR shift_screen
        LDA #0
        STA shift_due
        LDA #1
        STA column_due
as_done:
        RTS

; The cave scrolls one pixel every frame.
scroll_cave:
        LDA xscroll
        SEC
        SBC #1
        BCS sc_set
        LDA #7
        LDX #1
        STX shift_due
sc_set:
        STA xscroll_next
        RTS

; Move rows 4-24 one character to the left, an unrolled loop (see Jumpin' Jo).
shift_screen:
        LDX #0
ss_loop:
        LDA SCREEN+4*40+1,X
        STA SCREEN+4*40,X
        LDA SCREEN+5*40+1,X
        STA SCREEN+5*40,X
        LDA SCREEN+6*40+1,X
        STA SCREEN+6*40,X
        LDA SCREEN+7*40+1,X
        STA SCREEN+7*40,X
        LDA SCREEN+8*40+1,X
        STA SCREEN+8*40,X
        LDA SCREEN+9*40+1,X
        STA SCREEN+9*40,X
        LDA SCREEN+10*40+1,X
        STA SCREEN+10*40,X
        LDA SCREEN+11*40+1,X
        STA SCREEN+11*40,X
        LDA SCREEN+12*40+1,X
        STA SCREEN+12*40,X
        LDA SCREEN+13*40+1,X
        STA SCREEN+13*40,X
        LDA SCREEN+14*40+1,X
        STA SCREEN+14*40,X
        LDA SCREEN+15*40+1,X
        STA SCREEN+15*40,X
        LDA SCREEN+16*40+1,X
        STA SCREEN+16*40,X
        LDA SCREEN+17*40+1,X
        STA SCREEN+17*40,X
        LDA SCREEN+18*40+1,X
        STA SCREEN+18*40,X
        LDA SCREEN+19*40+1,X
        STA SCREEN+19*40,X
        LDA SCREEN+20*40+1,X
        STA SCREEN+20*40,X
        LDA SCREEN+21*40+1,X
        STA SCREEN+21*40,X
        LDA SCREEN+22*40+1,X
        STA SCREEN+22*40,X
        LDA SCREEN+23*40+1,X
        STA SCREEN+23*40,X
        LDA SCREEN+24*40+1,X
        STA SCREEN+24*40,X
        INX
        CPX #39
        BEQ ss_done         ; a branch reaches only 127 bytes back, and this
        JMP ss_loop         ; loop is longer, so it returns to the top with JMP
ss_done:
        RTS

; A new column has scrolled into view: let the roof and floor wander a
; little, keeping MIN_GAP rows open, and draw it on the right.
new_column:
        LDA column_due
        BEQ nc_done
        LDA #0
        STA column_due
        LDA boss_on         ; the guardian's arena: the cave opens out
        BEQ nc_wander
        LDA top_h
        CMP #3
        BCC nc_arena_floor
        DEC top_h
nc_arena_floor:
        LDA bot_h
        CMP #3
        BCC nc_draw
        DEC bot_h
        JMP nc_draw
nc_wander:
        JSR random
        AND #3
        BEQ nc_roof_down
        CMP #1
        BNE nc_floor
        LDA top_h           ; roof up a row
        CMP #2
        BCC nc_floor
        DEC top_h
        JMP nc_floor
nc_roof_down:
        JSR room_to_grow
        BCC nc_floor
        INC top_h
nc_floor:
        JSR random
        AND #3
        BEQ nc_floor_up
        CMP #1
        BNE nc_draw
        LDA bot_h           ; floor down a row
        CMP #2
        BCC nc_draw
        DEC bot_h
        JMP nc_draw
nc_floor_up:
        JSR room_to_grow
        BCC nc_draw
        INC bot_h
nc_draw:
        LDY #39
        JMP draw_column
nc_done:
        RTS

; Carry set if the roof or floor may grow a row and still leave MIN_GAP.
room_to_grow:
        LDA #FIELD_ROWS
        SEC
        SBC top_h
        SEC
        SBC bot_h           ; rows open now
        CMP #MIN_GAP+1
        RTS

; Draw the cave's column Y from top_h and bot_h, with the odd star.
draw_column:
        STY tmp3
        LDX #0
dc_row:
        LDA ROW_LO+FIELD_TOP,X
        STA ptr
        LDA ROW_HI+FIELD_TOP,X
        STA ptr+1
        TXA
        CLC
        ADC #1
        CMP top_h
        BCC dc_rock         ; inside the roof
        BEQ dc_ceiling      ; the roof's lowest row
        TXA
        CLC
        ADC bot_h
        CMP #FIELD_ROWS
        BEQ dc_floor        ; the floor's top row
        BCS dc_rock         ; inside the floor
        JSR random          ; open space: one cell in 16 has a star
        AND #15
        BNE dc_space
        LDA seed+1          ; which star: not from SEED, whose low bits are
        AND #1              ; the zeros just tested
        CLC
        ADC #C_STAR1
        JMP dc_put
dc_space:
        LDA #32
        JMP dc_put
dc_ceiling:
        LDA #C_CEILING
        JMP dc_put
dc_floor:
        LDA #C_FLOOR
        JMP dc_put
dc_rock:
        LDA #C_ROCK
dc_put:
        LDY tmp3
        STA (ptr),Y
        INX
        CPX #FIELD_ROWS
        BNE dc_row
        RTS

; ===========================================================================
; STATUS
; ===========================================================================
show_status:
        LDA #<status_text
        LDX #>status_text
        JSR print_list
        LDX #hiscore+2
        LDY #19
        LDA #3
        JSR print_bcd
        LDA ships
        CMP #10
        BCC ss_ships
        LDA #9
ss_ships:
        ORA #$30
        STA SCREEN+36
        LDA stage
        CLC
        ADC #1
        CMP #10
        BCC ss_stage
        LDA #9
ss_stage:
        ORA #$30
        STA SCREEN+40+36
        ; fall through to show the score

show_score:
        LDX #score+2
        LDY #6
        LDA #3
        ; fall through

print_bcd:                  ; A bytes of BCD from zero page X down, at column Y
        STA tmp
pb_byte:
        LDA $00,X
        LSR
        LSR
        LSR
        LSR
        ORA #$30
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

; The beam gauge: one block for every 4 frames of charge.
show_gauge:
        LDA charge
        LSR
        LSR
        STA tmp
        LDX #0
sg_cell:
        LDA #'-'
        CPX tmp
        BCS sg_put
        LDA #C_GAUGE
sg_put:
        STA SCREEN+40+5,X
        INX
        CPX #16
        BNE sg_cell
        RTS

add_score:                  ; score += A (tens, units) + X (thousands, hundreds), BCD
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
        JMP show_score

update_hiscore:
        LDA score+2
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

; ===========================================================================
; THE SHIP
; ===========================================================================
move_ship:
        LDA dead
        BEQ ms_fly
        CMP #60             ; exploding for a while, then gone
        BCC ms_gone
        LSR
        LSR
        AND #1
        CLC
        ADC #P_BOOM
        STA SPR_PTR+S_SHIP
        LDA #YELLOW
        STA VIC+$27+S_SHIP
        RTS
ms_gone:
        LDA spr_on
        AND #%11111110
        STA spr_on
        RTS
ms_fly:
        LDA spr_on          ; visible, but flashing while it is safe
        ORA #1
        STA spr_on
        LDA safe
        BEQ ms_move
        DEC safe
        LDA frame_count
        AND #4
        BEQ ms_move
        LDA spr_on
        AND #%11111110
        STA spr_on
ms_move:
        LDA joy
        AND #JOY_UP
        BEQ ms_down
        LDA ship_y
        CMP #82+SHIP_SPEED  ; no higher than row 4, the roof's top row: rock
        BCC ms_down         ; is always there, so there is no way over the cave
        SEC
        SBC #SHIP_SPEED
        STA ship_y
ms_down:
        LDA joy
        AND #JOY_DOWN
        BEQ ms_left
        LDA ship_y
        CMP #239-SHIP_SPEED ; no lower than the bottom of the screen
        BCS ms_left
        ADC #SHIP_SPEED
        STA ship_y
ms_left:
        LDA joy
        AND #JOY_LEFT
        BEQ ms_right
        LDA ship_xhi
        BNE ms_go_left
        LDA ship_xlo
        CMP #24+SHIP_SPEED
        BCC ms_right
ms_go_left:
        LDA ship_xlo
        SEC
        SBC #SHIP_SPEED
        STA ship_xlo
        BCS ms_right
        DEC ship_xhi
ms_right:
        LDA joy
        AND #JOY_RIGHT
        BEQ ms_place
        LDA ship_xlo        ; no further right than X 255, so ship_xhi stays 0
        CMP #256-SHIP_SPEED
        BCS ms_place
        ADC #SHIP_SPEED
        STA ship_xlo
ms_place:
        LDA ship_xlo
        STA SPR_XLO+S_SHIP
        LDA ship_xhi
        STA SPR_XHI+S_SHIP
        LDA ship_y
        STA SPR_Y+S_SHIP
        RTS

; Tap fire to shoot. Hold it to charge the beam; let go to fire it.
fire_control:
        LDA dead
        BNE fc_done
        LDA joy
        AND #JOY_FIRE
        BEQ fc_released
        LDA fire_held
        BNE fc_charging
        LDA #1
        STA fire_held
        JSR fire_shot       ; the press itself fires a shot
fc_charging:
        LDA charge
        CMP #MAX_CHARGE
        BCS fc_done
        INC charge
        LDA charge
        CMP #BEAM_READY
        BNE fc_done
        LDA #SFX_READY      ; a ping: the beam is ready
        LDX #2
        JMP sfx_play
fc_released:
        LDA fire_held
        BEQ fc_done
        LDA #0
        STA fire_held
        LDA charge
        CMP #BEAM_READY
        BCC fc_reset
        JSR fire_beam
fc_reset:
        LDA #0
        STA charge
fc_done:
        RTS

fire_shot:
        LDX #1              ; a free shot?
fs_find:
        LDA SHOT_ON,X
        BEQ fs_go
        DEX
        BPL fs_find
        RTS
fs_go:
        LDA #1
        STA SHOT_ON,X
        LDA #P_SHOT
        STA SPR_PTR+S_SHOT,X
        LDA #20             ; from the ship's nose
        JSR shot_from_ship
        LDA ship_y
        CLC
        ADC #5
        STA SHOT_Y,X
        LDA #SFX_SHOT
        LDX #2
        JMP sfx_play

fire_beam:
        LDX #0              ; the beam always uses the first shot slot
        LDA #2
        STA SHOT_ON
        LDA #P_BEAM
        STA SPR_PTR+S_SHOT
        LDA spr_wide        ; stretched to twice its width
        ORA #BIT_BEAM
        STA spr_wide
        LDA #12
        JSR shot_from_ship
        LDA ship_y
        CLC
        ADC #3
        STA SHOT_Y
        LDA #12             ; fired into a wall? MOVE_SHOTS will look 36 and
        JSR shot_in_rock    ; 44 pixels in from here, so look from the ship's
        BCS fb_wall         ; nose up to there
        LDA #20
        JSR shot_in_rock
        BCS fb_wall
        LDA #28
        JSR shot_in_rock
        BCC fb_sound
fb_wall:
        JSR shot_gone
fb_sound:
        LDA #SFX_BEAM
        LDX #2
        JMP sfx_play

; Shot X starts A pixels right of the ship.
shot_from_ship:
        CLC
        ADC ship_xlo
        STA SHOT_XLO,X
        LDA ship_xhi
        ADC #0
        STA SHOT_XHI,X
        RTS

; Shots fly right until they leave the screen or hit the cave.
move_shots:
        LDX #1
msh_shot:
        LDA SHOT_ON,X
        BEQ msh_next
        CMP #2
        BEQ msh_beam
        LDA #SHOT_SPEED
        BNE msh_move
msh_beam:
        LDA #BEAM_SPEED
msh_move:
        CLC
        ADC SHOT_XLO,X
        STA SHOT_XLO,X
        LDA SHOT_XHI,X
        ADC #0
        STA SHOT_XHI,X
        BEQ msh_on_screen
        LDA SHOT_XLO,X
        CMP #344-256
        BCS msh_off
msh_on_screen:
        LDA #8              ; into the cave wall? A shot looks at its tip, 8
        LDY SHOT_ON,X       ; pixels in. The beam gains 9 pixels a frame on
        CPY #2              ; the cave, enough to step over a thin wall, so
        BNE msh_look        ; it looks at its tip, 36 in, and 8 behind that
        LDA #28
        JSR shot_in_rock
        BCS msh_off
        LDA #36
msh_look:
        JSR shot_in_rock
        BCS msh_off
        LDA SHOT_XLO,X
        STA SPR_XLO+S_SHOT,X
        LDA SHOT_XHI,X
        STA SPR_XHI+S_SHOT,X
        LDA SHOT_Y,X
        STA SPR_Y+S_SHOT,X
        LDA spr_on
        ORA shot_bits,X
        STA spr_on
        JMP msh_next
msh_off:
        JSR shot_gone
msh_next:
        DEX
        BPL msh_shot
        RTS

shot_gone:                  ; shot X disappears
        LDA #0
        STA SHOT_ON,X
        LDA shot_bits,X
        EOR #$FF
        AND spr_on
        STA spr_on
        CPX #0
        BNE sg_done
        LDA spr_wide        ; slot 0 may have been the stretched beam
        AND #255-BIT_BEAM
        STA spr_wide
sg_done:
        RTS

; Is shot X in the cave wall, A pixels in from its left? Carry set if so.
; The beam looks along its middle two rows, where it is longest, or it
; could slide along a floor. X is kept.
shot_in_rock:
        CLC
        ADC SHOT_XLO,X
        STA t_x
        LDA SHOT_XHI,X
        ADC #0
        STA t_x+1
        STX counter
        LDA SHOT_Y,X
        LDY SHOT_ON,X
        CPY #2
        BNE sir_look
        CLC
        ADC #2
sir_look:
        JSR cave_at
        LDX counter
        CMP #C_ROCK
        RTS

; The character under sprite X position t_x and Y position A, allowing
; for the fine scroll: screen column = (X - 24 - xscroll) / 8.
cave_at:
        SEC
        SBC #50
        BCC ca_space
        LSR
        LSR
        LSR
        CMP #25
        BCS ca_space
        TAY
        LDA ROW_LO,Y
        STA ptr
        LDA ROW_HI,Y
        STA ptr+1
        LDA t_x
        SEC
        SBC #24
        STA tmp
        LDA t_x+1
        SBC #0
        STA tmp2
        LDA tmp
        SEC
        SBC xscroll
        STA tmp
        LDA tmp2
        SBC #0
        BMI ca_space        ; off the left of the screen
        LSR
        LDA tmp
        ROR
        LSR
        LSR
        CMP #40
        BCS ca_space
        TAY
        LDA (ptr),Y
        RTS
ca_space:
        LDA #32
        RTS

; ===========================================================================
; ENEMIES
; ===========================================================================
; Waves come from the WAVES table: a row is read when the last wave has
; all been sent, and its enemies follow each other WAVE_GAP frames apart.
spawn_enemies:
        LDA boss_on
        BNE se_done         ; nothing else comes while the guardian is here
        DEC wave_wait
        BNE se_done
        LDA wave_left
        BNE se_spawn
        LDY #0              ; the next row: type, count, Y, gap, pause after
        LDA (wave_ptr),Y
        CMP #$FF
        BEQ se_boss
        STA wave_type
        INY
        LDA (wave_ptr),Y
        STA wave_left
        INY
        LDA (wave_ptr),Y
        STA wave_y
        INY
        LDA (wave_ptr),Y
        STA wave_gap
        INY
        LDA (wave_ptr),Y
        STA wave_pause
        LDA wave_ptr
        CLC
        ADC #5
        STA wave_ptr
        BCC se_spawn
        INC wave_ptr+1
se_spawn:
        JSR spawn_one
        BCS se_retry
        DEC wave_left
        LDA wave_gap
        LDX wave_left
        BNE se_wait
        LDA wave_pause
se_wait:
        STA wave_wait
se_done:
        RTS
se_retry:
        LDA #8              ; no room on screen: try again shortly
        STA wave_wait
        RTS
se_boss:
        LDA E_ON            ; the guardian needs the first slot
        BNE se_retry
        JMP spawn_boss

; Send one enemy of the wave's type. Carry set if there was no free slot.
spawn_one:
        LDX #MAX_ENEMIES-1
so_find:
        LDA E_ON,X
        BEQ so_found
        DEX
        BPL so_find
        SEC
        RTS
so_found:
        LDA wave_type
        STA E_TYPE,X
        TAY
        LDA type_hp,Y
        STA E_HP,X
        LDA type_shape,Y
        STA SPR_PTR+S_ENEMY,X
        LDA type_color,Y
        STA VIC+$27+S_ENEMY,X
        JSR open_space      ; where: in the open part of the cave at the right
        LDY wave_type
        CPY #T_ORB          ; an orb weaves 24 pixels either side of this:
        BNE so_place        ; keep the top of that inside the cave
        CMP #50+8*FIELD_TOP+24
        BCS so_place
        LDA #50+8*FIELD_TOP+24
so_place:
        STA E_Y,X
        STA E_BASE,X
        LDA #<344           ; just off the right of the screen
        STA E_XLO,X
        LDA #>344
        STA E_XHI,X
        LDA #0
        STA E_T,X
        LDA #1
        STA E_ON,X
        CLC
        RTS

; A sprite Y in the open space of the newest column, for wave_y:
; 0 the middle, 1 near the roof, 2 near the floor, 3 anywhere.
; X is kept.
open_space:
        LDA top_h           ; the top of the space: 50 + 8 x (FIELD_TOP + top_h)
        CLC
        ADC #FIELD_TOP
        ASL
        ASL
        ASL
        CLC
        ADC #50+4
        STA tmp
        LDA #FIELD_TOP+FIELD_ROWS   ; the bottom, less an enemy's height
        SEC
        SBC bot_h
        ASL
        ASL
        ASL
        CLC
        ADC #50-12
        STA tmp2
        LDA wave_y
        BEQ os_middle
        CMP #1
        BEQ os_top
        CMP #2
        BEQ os_bottom
        JSR random          ; anywhere: a random step into the space...
        AND #63
        CLC
        ADC tmp
        CMP tmp2
        BCC os_done         ; ...if it fits
os_middle:
        LDA tmp
        CLC
        ADC tmp2
        ROR                 ; (top + bottom) / 2, with the carry as bit 8
        RTS
os_top:
        LDA tmp
        RTS
os_bottom:
        LDA tmp2
os_done:
        RTS

; The guardian: one sprite stretched both ways, in the first enemy slot,
; once that is free.
spawn_boss:
        LDX #0
        LDA #1
        STA boss_on
        STA E_ON
        LDA #T_BOSS
        STA E_TYPE
        LDA #BOSS_HP
        STA E_HP
        LDA #P_BOSS
        STA SPR_PTR+S_ENEMY
        LDA #LIGHT_GREEN
        STA VIC+$27+S_ENEMY
        LDA #<344
        STA E_XLO
        LDA #>344
        STA E_XHI
        LDA #145            ; its centre line: bobbing 48 pixels either way,
        STA E_Y             ; it fills the arena without leaving the cave
        STA E_BASE
        LDA #0
        STA E_T
        LDA spr_wide
        ORA #BIT_BOSS
        STA spr_wide
        LDA spr_tall
        ORA #BIT_BOSS
        STA spr_tall
        LDA #SFX_BOSS
        LDX #2
        JMP sfx_play

move_enemies:
        LDX #MAX_ENEMIES-1
me_enemy:
        STX enemy
        LDA E_ON,X
        BNE me_active
        JMP me_hide
me_active:
        CMP #2
        BNE me_flying
        DEC E_T,X           ; exploding: two shapes, then gone
        BEQ me_gone
        LDA E_T,X
        LSR
        LSR
        AND #1
        CLC
        ADC #P_BOOM
        STA SPR_PTR+S_ENEMY,X
        JMP me_show
me_gone:
        LDA #0
        STA E_ON,X
        LDA E_TYPE,X
        CMP #T_BOSS
        BNE me_hide_jump
        LDA #2              ; the guardian is no more
        STA boss_on
        LDA spr_wide
        AND #255-BIT_BOSS
        STA spr_wide
        LDA spr_tall
        AND #255-BIT_BOSS
        STA spr_tall
me_hide_jump:
        JMP me_hide
me_flying:
        INC E_T,X
        LDA E_TYPE,X
        CMP #T_ORB
        BEQ me_orb
        CMP #T_DART
        BEQ me_dart
        CMP #T_BOSS
        BEQ me_boss
        LDA #2              ; a saucer flies straight
        JSR enemy_left
        JMP me_fire
me_orb:
        LDA #1              ; an orb weaves up and down
        JSR enemy_left
        LDA E_T,X
        AND #31
        TAY
        LDA E_BASE,X
        CLC
        ADC wave_shape,Y
        STA E_Y,X
        JMP me_fire
me_dart:
        LDA #2              ; a dart homes in on the ship's height
        JSR enemy_left
        LDA E_Y,X
        CMP ship_y
        BEQ me_fire
        BCS me_dart_up
        INC E_Y,X
        JMP me_fire
me_dart_up:
        DEC E_Y,X
        JMP me_fire
me_boss:
        LDA E_XHI,X         ; the guardian comes in, then bobs up and down
        BNE me_boss_in
        LDA E_XLO,X
        CMP #240
        BCC me_boss_bob
me_boss_in:
        LDA #1
        JSR enemy_left
me_boss_bob:
        LDA E_T,X
        LSR
        AND #31
        TAY
        LDA wave_shape,Y
        ASL
        CLC
        ADC E_BASE,X
        STA E_Y,X
        LDA E_T,X           ; and fires every 32 frames
        AND #31
        BNE me_show
        JSR enemy_fires
        JMP me_show
me_fire:
        LDA E_ON,X          ; gone off the left edge?
        BEQ me_hide
        JSR random          ; now and then, fire at the ship
        CMP fire_rate
        BCS me_show
        JSR enemy_fires
me_show:
        LDX enemy
        LDA E_XLO,X
        STA SPR_XLO+S_ENEMY,X
        LDA E_XHI,X
        STA SPR_XHI+S_ENEMY,X
        LDA E_Y,X
        STA SPR_Y+S_ENEMY,X
        LDA spr_on
        ORA enemy_bits,X
        STA spr_on
        JMP me_next
me_hide:
        LDX enemy
        LDA enemy_bits,X
        EOR #$FF
        AND spr_on
        STA spr_on
me_next:
        LDX enemy
        DEX
        BMI me_done
        JMP me_enemy
me_done:
        RTS

; Move enemy X left A pixels; past the left edge it is gone.
enemy_left:
        STA tmp
        LDA E_XLO,X
        SEC
        SBC tmp
        STA E_XLO,X
        LDA E_XHI,X
        SBC #0
        STA E_XHI,X
        BPL el_done
        LDA #0
        STA E_ON,X
el_done:
        RTS

; Enemy X fires a bullet towards the ship, if one is not already flying.
enemy_fires:
        LDA BULLET_ON
        BNE ef_done
        LDA dead
        BNE ef_done
        LDA #1
        STA BULLET_ON
        LDA E_XLO,X
        STA BULLET_XLO
        LDA E_XHI,X
        STA BULLET_XHI
        LDA E_Y,X
        CLC
        ADC #4
        STA BULLET_Y
        LDY #0              ; aim: up, level or down
        LDA ship_y
        SEC
        SBC BULLET_Y
        BCC ef_up
        CMP #12
        BCC ef_aim
        LDY #1
        JMP ef_aim
ef_up:
        CMP #256-12
        BCS ef_aim
        LDY #$FF
ef_aim:
        STY bullet_dy
        LDA #P_BULLET
        STA SPR_PTR+S_BULLET
        LDA #SFX_ZAP
        STX tmp3
        LDX #2
        JSR sfx_play
        LDX tmp3
ef_done:
        RTS

; The enemy bullet flies left, 3 pixels a frame, up or down a little.
move_bullet:
        LDA BULLET_ON
        BEQ mbu_off
        LDA BULLET_XLO
        SEC
        SBC #3
        STA BULLET_XLO
        LDA BULLET_XHI
        SBC #0
        STA BULLET_XHI
        BMI mbu_gone
        LDA BULLET_Y
        CLC
        ADC bullet_dy
        STA BULLET_Y
        CMP #50+8*FIELD_TOP ; gone as it rises out of the cave, before it
        BCC mbu_gone        ; can reach the status lines
        CMP #245
        BCS mbu_gone
        LDA BULLET_XLO
        STA SPR_XLO+S_BULLET
        LDA BULLET_XHI
        STA SPR_XHI+S_BULLET
        LDA BULLET_Y
        STA SPR_Y+S_BULLET
        LDA spr_on
        ORA #BIT_BULLET
        STA spr_on
        RTS
mbu_gone:
        LDA #0
        STA BULLET_ON
mbu_off:
        LDA spr_on
        AND #255-BIT_BULLET
        STA spr_on
        RTS

; ===========================================================================
; COLLISIONS
; Boxes are compared in 2-pixel steps across (see Alien Armada's HALF_X),
; so every position fits in a byte.
; ===========================================================================
hit_checks:
        JSR shots_hit
        LDA dead
        ORA safe
        BNE hc_done         ; the ship cannot be hurt just now
        JSR ship_box_a      ; the ship against the cave: 4 points around it
        LDX #3
hc_point:
        LDA ship_point_x,X
        CLC
        ADC ship_xlo
        STA t_x
        LDA ship_xhi
        ADC #0
        STA t_x+1
        LDA ship_point_y,X
        CLC
        ADC ship_y
        STX counter
        JSR cave_at
        LDX counter
        CMP #C_ROCK
        BCS hc_crash
        DEX
        BPL hc_point
        LDA BULLET_ON       ; against the enemy bullet
        BEQ hc_enemies
        LDA BULLET_XHI
        LSR
        LDA BULLET_XLO
        ROR
        STA box_bx
        LDA #2
        STA box_bw
        LDA BULLET_Y
        STA box_by
        LDA #4
        STA box_bh
        JSR overlap
        BCC hc_enemies
        LDA #0              ; the bullet is spent on the ship
        STA BULLET_ON
        JMP hc_crash
hc_enemies:
        LDX #MAX_ENEMIES-1  ; against the enemies themselves
hc_enemy:
        LDA E_ON,X
        CMP #1
        BNE hc_next
        JSR enemy_box_b
        JSR overlap
        BCC hc_next
        LDA E_TYPE,X
        CMP #T_BOSS
        BEQ hc_crash
        JSR enemy_dies
        JMP hc_crash
hc_next:
        DEX
        BPL hc_enemy
hc_done:
        RTS
hc_crash:
        LDA #90             ; boom
        STA dead
        LDA #0
        STA charge
        LDA #SFX_CRASH
        LDX #2
        JMP sfx_play

; Shots and the beam against the enemies.
shots_hit:
        LDX #1
sh_shot:
        LDA SHOT_ON,X
        BEQ sh_next
        STX tmp3
        LDA SHOT_XHI,X      ; the shot's box
        LSR
        LDA SHOT_XLO,X
        ROR
        STA box_ax
        LDA SHOT_Y,X
        STA box_ay
        LDA #4              ; a shot: 8 x 2 pixels
        STA box_aw
        LDA #2
        STA box_ah
        LDA SHOT_ON,X
        CMP #2
        BNE sh_enemies
        LDA #24             ; the beam: 48 x 6
        STA box_aw
        LDA #6
        STA box_ah
sh_enemies:
        LDX #MAX_ENEMIES-1
sh_enemy:
        LDA E_ON,X
        CMP #1
        BNE sh_enemy_next
        JSR enemy_box_b
        JSR overlap
        BCC sh_enemy_next
        LDY tmp3            ; a hit: the beam does 4 damage and carries on
        LDA SHOT_ON,Y
        CMP #2
        BEQ sh_beam_hit
        TXA
        PHA
        LDX tmp3
        JSR shot_gone
        PLA
        TAX
        LDA #1
        JSR enemy_hurt
        LDX tmp3
        JMP sh_next
sh_beam_hit:
        LDA E_TYPE,X        ; the guardian stops the beam, for 8 damage
        CMP #T_BOSS
        BNE sh_beam_through
        TXA
        PHA
        LDX tmp3
        JSR shot_gone
        PLA
        TAX
        LDA #8
        JSR enemy_hurt
        LDX tmp3
        JMP sh_next
sh_beam_through:
        LDA #4
        JSR enemy_hurt
sh_enemy_next:
        DEX
        BPL sh_enemy
        LDX tmp3
sh_next:
        DEX
        BMI sh_done
        JMP sh_shot
sh_done:
        RTS

; Take A hit points from enemy X; at none it explodes.
enemy_hurt:
        STA tmp
        LDA E_HP,X
        SEC
        SBC tmp
        STA E_HP,X
        BEQ enemy_dies
        BCC enemy_dies
        LDA #SFX_CLANG
        STX tmp2
        LDX #2
        JSR sfx_play
        LDX tmp2
        RTS

enemy_dies:
        LDA #2
        STA E_ON,X
        LDA #24
        STA E_T,X
        LDA #YELLOW
        STA VIC+$27+S_ENEMY,X
        LDY E_TYPE,X        ; points for this kind of enemy
        LDA type_points_lo,Y
        STX tmp2
        PHA
        LDA type_points_hi,Y
        TAX
        PLA
        JSR add_score
        LDX tmp2
        LDA E_TYPE,X
        CMP #T_BOSS
        BNE ed_small
        LDA #80             ; the guardian takes longer to blow up
        STA E_T,X
        LDA #SFX_BIGBOOM
        BNE ed_sound
ed_small:
        LDA #SFX_BOOM
ed_sound:
        STX tmp2
        LDX #2
        JSR sfx_play
        LDX tmp2
        RTS

; Box A = the ship (in 2-pixel steps across).
ship_box_a:
        LDA ship_xhi
        LSR
        LDA ship_xlo
        ROR
        CLC
        ADC #2
        STA box_ax
        LDA #9
        STA box_aw
        LDA ship_y
        CLC
        ADC #2
        STA box_ay
        LDA #8
        STA box_ah
        RTS

; Box B = enemy X: the guardian is stretched to 48 x 42.
enemy_box_b:
        LDA E_XHI,X
        LSR
        LDA E_XLO,X
        ROR
        STA box_bx
        LDA E_Y,X
        STA box_by
        LDA E_TYPE,X
        CMP #T_BOSS
        BEQ eb_boss
        LDA #12
        STA box_bw
        LDA #8
        STA box_bh
        RTS
eb_boss:
        LDA #24
        STA box_bw
        LDA #40
        STA box_bh
        RTS

; Do boxes A and B overlap? Carry set if so.
overlap:
        LDA box_bx
        CLC
        ADC box_bw
        CMP box_ax
        BCC ov_no
        BEQ ov_no
        LDA box_ax
        CLC
        ADC box_aw
        CMP box_bx
        BCC ov_no
        BEQ ov_no
        LDA box_by
        CLC
        ADC box_bh
        CMP box_ay
        BCC ov_no
        BEQ ov_no
        LDA box_ay
        CLC
        ADC box_ah
        CMP box_by
        BCC ov_no
        BEQ ov_no
        SEC
        RTS
ov_no:
        CLC
        RTS

; ===========================================================================
; SCREEN HELPERS
; ===========================================================================
clear_screen:
        LDX #0
cs_loop:
        LDA #32
        STA SCREEN,X
        STA SCREEN+$100,X
        STA SCREEN+$200,X
        STA SCREEN+$2E8,X
        LDA #WHITE          ; below 8: hires, for text
        STA COLORS,X
        STA COLORS+$100,X
        STA COLORS+$200,X
        STA COLORS+$2E8,X
        INX
        BNE cs_loop
        RTS

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

copy_font:                  ; letters and digits from the character ROM
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

print_list:
        STA src
        STX src+1
pl_next:
        LDY #0
        LDA (src),Y
        CMP #$FF
        BEQ pl_done
        JSR print_here
        JMP pl_next
pl_done:
        RTS

print:                      ; row, column, colour, text, zero
        STA src
        STX src+1
print_here:
        LDY #0
        LDA (src),Y
        TAX
        INY
        LDA (src),Y
        CLC
        ADC ROW_LO,X
        STA ptr
        STA cptr
        LDA ROW_HI,X
        ADC #0
        STA ptr+1
        CLC
        ADC #>(COLORS-SCREEN)
        STA cptr+1
        INY
        LDA (src),Y
        STA tmp
        LDA src
        CLC
        ADC #3
        STA src
        BCC ph_text
        INC src+1
ph_text:
        LDY #0
ph_loop:
        LDA (src),Y
        BEQ ph_end
        AND #$3F
        STA (ptr),Y
        LDA tmp
        STA (cptr),Y
        INY
        BNE ph_loop
ph_end:
        INY
        TYA
        CLC
        ADC src
        STA src
        BCC ph_done
        INC src+1
ph_done:
        RTS

; ===========================================================================
; MUSIC AND SOUND (the same drivers as Jumpin' Jo)
; ===========================================================================
init_sound:
        LDA #0
        LDX #$18
is_clear:
        STA SID,X
        DEX
        BPL is_clear
        LDX #2
is_voices:
        STA sfx_start,X
        STA sfx_time,X
        DEX
        BPL is_voices
        STA music_on
        LDA #15
        STA SID+$18
        LDA #CYAN           ; the shots' and bullet's colours
        STA VIC+$28
        STA VIC+$29
        LDA #WHITE
        STA VIC+$2E
        RTS

start_music:
        LDA #0
        STA music_on
        STA mus_pos
        STA mus_pos+1
        LDA #1
        STA mus_wait
        STA mus_wait+1
        LDA #$08            ; the tune: a pulse that fades a little
        STA SID+5
        LDA #$6A
        STA SID+6
        LDA #$04
        STA SID+3           ; a thin pulse
        LDA #$09            ; the bass: a plucked sawtooth
        STA SID+12
        LDA #$00
        STA SID+13
        LDA #1
        STA music_on
        RTS

silence_music:
        LDA #0
        STA SID+4
        STA SID+11
        RTS

music_update:
        LDA music_on
        BEQ mu_done
        LDX #1
mu_voice:
        DEC mus_wait,X
        BNE mu_next
        JSR next_note
mu_next:
        DEX
        BPL mu_voice
mu_done:
        RTS

next_note:
        LDA mus_list_lo,X
        STA mptr2
        LDA mus_list_hi,X
        STA mptr2+1
        LDY mus_pos,X
        LDA (mptr2),Y
        CMP #$FF
        BNE nn_note
        LDY #0
        LDA (mptr2),Y
nn_note:
        STA mus_note
        INY
        LDA (mptr2),Y
        STA mus_wait,X
        INY
        TYA
        STA mus_pos,X
        LDY voice_regs,X
        STY sid_off
        LDA mus_wave,X
        STA SID+4,Y
        LDA mus_note
        BEQ nn_done
        TAY
        LDA note_lo-1,Y
        PHA
        LDA note_hi-1,Y
        LDY sid_off
        STA SID+1,Y
        PLA
        STA SID,Y
        LDA mus_wave,X
        ORA #1
        STA SID+4,Y
nn_done:
        RTS

sfx_play:                   ; effect A on voice X
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
        STA sfx_start,X
        RTS

sfx_update:                 ; voice 3 only: the music has the others
        LDX #2
        LDY voice_regs,X
        LDA sfx_start,X
        BEQ su_running
        LDA #0
        STA sfx_start,X
        STA SID+4,Y
        LDA sfx_ad,X
        STA SID+5,Y
        LDA sfx_sr,X
        STA SID+6,Y
        LDA #8
        STA SID+3,Y
        LDA sfx_wave,X
        ORA #1
        STA SID+4,Y
        JMP su_freq
su_running:
        LDA sfx_time,X
        BEQ su_done
        DEC sfx_time,X
        BNE su_slide
        LDA sfx_wave,X
        STA SID+4,Y
        RTS
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
su_done:
        RTS

; ===========================================================================
; DATA
; ===========================================================================
voice_regs:     BYTE 0, 7, 14
shot_bits:      BYTE %00000010, %00000100
enemy_bits:     BYTE %00001000, %00010000, %00100000, %01000000
; Where the ship tests the cave, X and Y from its top left: its tail, its
; nose, the top of its fin and its underside
ship_point_x:   BYTE 4, 22, 8, 8
ship_point_y:   BYTE 6, 6, 2, 9
; Each kind of enemy: saucer, orb, dart, guardian
type_hp:        BYTE 1, 2, 1, BOSS_HP
type_shape:     BYTE P_SAUCER, P_SAUCER+1, P_SAUCER+2, P_BOSS
type_color:     BYTE GREEN, PURPLE, LIGHT_RED, LIGHT_GREEN
type_points_lo: BYTE $00, $50, $00, $00   ; BCD: 100, 150, 200, 5000
type_points_hi: BYTE $01, $01, $02, $50
; An orb's weave: 32 steps of a sine wave, 24 pixels up and down
wave_shape:     BYTE 0, 5, 9, 14, 17, 20, 22, 24, 24, 24, 22, 20, 17, 14, 9, 5
                BYTE 0, -5, -9, -14, -17, -20, -22, -24, -24, -24, -22, -20, -17, -14, -9, -5

title_key_y:    BYTE 50+8*8, 50+11*8, 50+14*8, 50+17*8
title_key_shape: BYTE P_SHIP, P_SAUCER, P_SAUCER+1, P_SAUCER+2
title_key_color: BYTE LIGHT_BLUE, GREEN, PURPLE, LIGHT_RED

status_text:
        BYTE 0, 0, WHITE
        ASCIIZ "SCORE 000000    HI 000000     SHIPS 3"
        BYTE 1, 0, WHITE
        ASCIIZ "BEAM"
        BYTE 1, 5, CYAN
        ASCIIZ "--------"
        BYTE 1, 13, YELLOW
        ASCIIZ "--------"
        BYTE 1, 30, WHITE
        ASCIIZ "STAGE 1"
        BYTE $FF
over_text:
        BYTE 13, 15, WHITE
        ASCIIZ "GAME OVER"
clear_text:
        BYTE 13, 13, YELLOW
        ASCIIZ "STAGE CLEARED"
; Text colours stay below 8: in multicolour mode, 8 and up make a cell multicolour.
title_text:
        BYTE 4, 10, YELLOW
        ASCIIZ "N O V A   S T R I K E"
        BYTE 8, 16, CYAN
        ASCIIZ "YOUR SHIP"
        BYTE 11, 16, GREEN
        ASCIIZ "SAUCER  100"
        BYTE 14, 16, PURPLE
        ASCIIZ "ORB     150"
        BYTE 17, 16, RED
        ASCIIZ "DART    200"
        BYTE 19, 2, WHITE
        ASCIIZ "TAP FIRE TO SHOOT, HOLD IT TO CHARGE"
        BYTE 20, 4, WHITE
        ASCIIZ "THE BEAM, THEN LET GO TO FIRE IT"
        BYTE 22, 11, WHITE
        ASCIIZ "PRESS FIRE TO PLAY"
        BYTE 24, 11, PURPLE
        ASCIIZ "JOYSTICK IN PORT 2"
        BYTE $FF

; ---------------------------------------------------------------------------
; WAVES: one row per attack wave, then $FF for the guardian.
;   enemy type, how many, where (0 middle, 1 high, 2 low, 3 anywhere),
;   frames between them, frames to wait after the last one
; ---------------------------------------------------------------------------
waves:
        BYTE T_SAUCER, 5, 0, 16, 60
        BYTE T_SAUCER, 5, 1, 16, 40
        BYTE T_SAUCER, 5, 2, 16, 80
        BYTE T_ORB,    6, 0, 20, 80
        BYTE T_DART,   4, 3, 30, 60
        BYTE T_SAUCER, 6, 3, 12, 40
        BYTE T_ORB,    8, 0, 16, 60
        BYTE T_DART,   6, 3, 24, 60
        BYTE T_ORB,    6, 1, 16, 20
        BYTE T_ORB,    6, 2, 16, 90
        BYTE T_SAUCER, 8, 3, 10, 120
        BYTE $FF

; ---------------------------------------------------------------------------
; Sound effects for voice 3: waveform, attack/decay, sustain/release,
; frequency low, high, change per frame low, high, length in frames.
; ---------------------------------------------------------------------------
SFX_SHOT    = 0
SFX_BEAM    = 8
SFX_READY   = 16
SFX_BOOM    = 24
SFX_BIGBOOM = 32
SFX_CRASH   = 40
SFX_CLANG   = 48
SFX_ZAP     = 56
SFX_BOSS    = 64
SFX_STAGE   = 72
sfx_table:
        BYTE 64,  $06, $00, $00, $30, $00, $FC, 6    ; shot: a quick zap down
        BYTE 32,  $0A, $00, $00, $40, $80, $FE, 24   ; beam: a long tearing sweep
        BYTE 16,  $06, $00, $00, $60, $00, $00, 4    ; the beam is ready
        BYTE 128, $08, $00, $00, $20, $00, $FF, 16   ; an enemy explodes
        BYTE 128, $0B, $00, $00, $18, $C0, $FF, 80   ; the guardian explodes
        BYTE 128, $0A, $00, $00, $10, $D0, $FF, 60   ; the ship explodes
        BYTE 64,  $04, $00, $00, $50, $00, $00, 3    ; a hit that does not kill
        BYTE 16,  $05, $00, $00, $24, $00, $FE, 6    ; an enemy fires
        BYTE 32,  $00, $F8, $00, $06, $40, $00, 50   ; the guardian arrives
        BYTE 64,  $00, $F8, $00, $10, $00, $01, 40   ; stage cleared

; ---------------------------------------------------------------------------
; The tune, in A minor. Notes are semitones from C2 = 1.
; ---------------------------------------------------------------------------
E2 = 5
F2 = 6
G2 = 8
A2 = 10
E3 = 17
F3 = 18
G3 = 20
A3 = 22
E4 = 29
GS4 = 33
A4 = 34
B4 = 36
C5 = 37
D5 = 39
E5 = 41
mus_list_lo:    BYTE <melody, <bass
mus_list_hi:    BYTE >melody, >bass
mus_wave:       BYTE 64, 32         ; pulse tune, sawtooth bass

melody:
        BYTE A4,16, C5,16, E5,16, D5,8, C5,8
        BYTE C5,16, A4,16, GS4,16, E4,16
        BYTE A4,16, C5,16, E5,16, D5,16
        BYTE C5,8, B4,8, A4,16, GS4,16, A4,16
        BYTE $FF
bass:
        BYTE A2,8, A2,8, A3,8, A2,8, G2,8, G2,8, G3,8, G2,8
        BYTE F2,8, F2,8, F3,8, F2,8, E2,8, E2,8, E3,8, E2,8
        BYTE $FF

note_lo:
        BYTE $5A,$9C,$E2,$2D,$7B,$CF,$27,$85,$E8,$51,$C1,$37
        BYTE $B4,$38,$C4,$59,$F7,$9D,$4E,$0A,$D0,$A2,$81,$6D
        BYTE $67,$70,$89,$B2,$ED,$3B,$9C,$13,$A0,$45,$02,$DA
        BYTE $CE,$E0,$11,$64,$DA,$76,$39,$26,$40,$89,$04,$B4
note_hi:
        BYTE $04,$04,$04,$05,$05,$05,$06,$06,$06,$07,$07,$08
        BYTE $08,$09,$09,$0A,$0A,$0B,$0C,$0D,$0D,$0E,$0F,$10
        BYTE $11,$12,$13,$14,$15,$17,$18,$1A,$1B,$1D,$1F,$20
        BYTE $22,$24,$27,$29,$2B,$2E,$31,$34,$37,$3A,$3E,$41

; ===========================================================================
; GRAPHICS
; Multicolour pairs of bits. In a sprite: 00 clear, 01 and 11 the colours
; every sprite shares ($D025 and $D026), 10 the sprite's own colour. In a
; character: 00 the background, 01 and 10 the shared colours in $D022 and
; $D023, 11 the cell's colour RAM. The shots are single-colour sprites.
; ===========================================================================

        ORG SPRITE_DATA+0*64   ; 160: the ship
        BYTE %00000000,%00000000,%00000000
        BYTE %00001111,%00000000,%00000000
        BYTE %00001010,%11000000,%00000000
        BYTE %00001010,%10101100,%00000000
        BYTE %11011010,%10101010,%11110000
        BYTE %01011010,%10101010,%10101111
        BYTE %11011010,%10101010,%10101011
        BYTE %01011010,%10101010,%10010100
        BYTE %11011010,%10101001,%01000000
        BYTE %00001010,%01010000,%00000000
        BYTE %00000101,%00000000,%00000000

        ORG SPRITE_DATA+1*64   ; 161: a shot
        BYTE %11111111,%00000000,%00000000
        BYTE %11111111,%00000000,%00000000

        ORG SPRITE_DATA+2*64   ; 162: the charged beam (stretched across)
        BYTE %00001111,%11111111,%00000000
        BYTE %00111111,%11111111,%10000000
        BYTE %11111111,%11111111,%11100000
        BYTE %11111111,%11111111,%11100000
        BYTE %00111111,%11111111,%10000000
        BYTE %00001111,%11111111,%00000000

        ORG SPRITE_DATA+3*64   ; 163: a saucer
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%10101010,%00000000
        BYTE %00001010,%10101010,%10100000
        BYTE %00101011,%10101110,%10111000
        BYTE %01010101,%01010101,%01010101
        BYTE %00010101,%01010101,%01010100
        BYTE %00000100,%00010000,%01000000

        ORG SPRITE_DATA+4*64   ; 164: an orb
        BYTE %00000000,%00000000,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00001010,%11111010,%10100000
        BYTE %00101011,%11101010,%10101000
        BYTE %00101010,%10101010,%10011000
        BYTE %00101010,%10101010,%01011000
        BYTE %00001010,%10101001,%01100000
        BYTE %00000010,%10101010,%10000000

        ORG SPRITE_DATA+5*64   ; 165: a dart
        BYTE %00000000,%00000000,%00000000
        BYTE %00101010,%00000000,%00000000
        BYTE %00001010,%10101010,%00000000
        BYTE %00001111,%10101010,%10101010
        BYTE %00000101,%01010101,%01010101
        BYTE %00000101,%01010101,%00000000
        BYTE %00010101,%00000000,%00000000

        ORG SPRITE_DATA+6*64   ; 166: an explosion
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00110000,%00000000
        BYTE %00001100,%00100000,%11000000
        BYTE %00000010,%10111010,%00000000
        BYTE %00111011,%11111111,%10110000
        BYTE %00000010,%10111010,%00000000
        BYTE %00001100,%00100000,%11000000
        BYTE %00000000,%00110000,%00000000

        ORG SPRITE_DATA+7*64   ; 167: an explosion, later
        BYTE %00001100,%00000000,%11000000
        BYTE %00000000,%10001000,%00000000
        BYTE %11000010,%00010010,%00001100
        BYTE %00001000,%01000100,%10000000
        BYTE %00100001,%00000001,%00100000
        BYTE %00001000,%01000100,%10000000
        BYTE %11000010,%00010010,%00001100
        BYTE %00000000,%10001000,%00000000
        BYTE %00001100,%00000000,%11000000

        ORG SPRITE_DATA+8*64   ; 168: the boss (stretched both ways)
        BYTE %00000000,%01010101,%00000000
        BYTE %00000101,%10101010,%01010000
        BYTE %00011010,%10101010,%10100100
        BYTE %01101011,%11101011,%11101001
        BYTE %01101111,%11101011,%11111001
        BYTE %01101011,%11101011,%11101001
        BYTE %01101010,%10101010,%10101001
        BYTE %01011010,%10010110,%10100101
        BYTE %00011010,%01111101,%10100100
        BYTE %00011010,%01111101,%10100100
        BYTE %01011010,%10010110,%10100101
        BYTE %01101010,%10101010,%10101001
        BYTE %01100010,%10000010,%10001001
        BYTE %01100010,%10000010,%10001001
        BYTE %01101010,%10101010,%10101001
        BYTE %00011010,%10101010,%10100100
        BYTE %00000101,%10101010,%01010000
        BYTE %00000001,%00010100,%01000000
        BYTE %00000100,%00010100,%00010000
        BYTE %00010000,%00010100,%00000100
        BYTE %00000000,%00010100,%00000000

        ORG SPRITE_DATA+9*64   ; 169: an enemy bullet
        BYTE %01100000,%00000000,%00000000
        BYTE %11110000,%00000000,%00000000
        BYTE %11110000,%00000000,%00000000
        BYTE %01100000,%00000000,%00000000

        ORG CHARSET+64*8
        BYTE %00000000,%00000000,%00000000,%00010000,%00000000,%00000000,%00000000,%00000000 ; star1
        BYTE %00000000,%00000000,%00000000,%00000000,%00000000,%00000100,%00000000,%00000000 ; star2
        BYTE %10101110,%10101010,%11101010,%10101011,%10101010,%10111010,%10101010,%11101010 ; rock
        BYTE %10101110,%10101010,%11101010,%10101011,%10101010,%11101011,%00101000,%00110000 ; ceiling
        BYTE %00001100,%00101000,%01101001,%10101010,%10111010,%10101010,%10101011,%11101010 ; floor
        BYTE %11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111 ; gauge
