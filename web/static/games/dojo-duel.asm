; ===========================================================================
;                               DOJO DUEL
; ===========================================================================
; A one-on-one karate contest at sunset, in the style of the martial arts
; games of 1985-86. Written in 6502 assembly for the Commodore 64;
; everything is in this one file.
;
; HOW TO PLAY
;   Joystick in port 2 (on this page: arrow keys, and Space for fire).
;   Left and right step. Up blocks, down crouches under high attacks.
;   With fire held:  no direction - punch      towards - front kick
;                    up - high kick (2 points) down - leg sweep
;   A clean hit scores; first to 3 points wins the bout. Each win brings a
;   tougher opponent with a higher belt. If time runs out, the fighter ahead
;   wins. A missed attack leaves you open: block or duck, then hit back.
;
; WHAT TO LOOK FOR
;   - The sunset is made by a raster interrupt that re-arms itself for the
;     next text row 16 times a frame, changing the background colour each
;     time. Where the colour changes, dithered characters blend one band
;     into the next. The mountains are characters drawn in front of it.
;   - The sun is one big sprite set behind the scenery ($D01B), so the
;     mountains hide the part of it that has already set.
;   - Each fighter is two multicolour sprites, one above the other.
;   - The sprites facing left are not in the file: MIRROR_SPRITES builds
;     them at the start by reversing the pixels of the ones facing right.
;   - Moves are rows in a table (MOVES): pose, length, when it lands, how
;     far it reaches and what defends it - the code only reads the table.
;   - The opponent is a small state machine: it defends when it sees an
;     attack coming, hits back when one misses, and otherwise closes in and
;     attacks. How often and how fast all come from tables indexed by its
;     belt (BELT_ATTACK, BELT_REACT, BELT_COUNTER, BELT_SLOW).
;
; MEMORY MAP
;   $0400-$07FF  screen
;   $0810-       the program
;   $2000-$24FF  the fighters facing right (sprite pointers 128-147)
;   $2500-$29FF  the same, mirrored at the start (148-167)
;   $2A00-$2A3F  the setting sun (168)
;   $3800-$39FF  letters and digits, copied from the character ROM
;   $3A00-$3A7F  scenery characters (codes 64-79)
;   $C000-$C0FF  tables
;
; THINGS TO TRY
;   - Change the sunset: BAND_COLORS has one colour per text row, and the
;     blends between the colours follow by themselves.
;   - Draw your own lake in LAKE.
;   - Make a move reach further or land sooner in MOVES.
;   - Start against a black belt: change START_BELT to 6.
;   - Give the opponent a favourite move: CPU_ATTACKS is the list it picks from.
;   - Longer bouts: POINTS_TO_WIN (up to 9) and BOUT_TIME are in the
;     settings below.
; ===========================================================================

; ---------------------------------------------------------------------------
; Settings
; ---------------------------------------------------------------------------
START_BELT   = 0            ; 0 white ... 6 black
POINTS_TO_WIN = 3           ; up to 9 fit on the status line
BOUT_TIME    = $30          ; seconds, in BCD
WALK_SPEED   = 1
CLOSEST      = 16           ; how close the fighters can stand
CPU_RANGE    = 22           ; the opponent walks in until it is this close
SEEN_RANGE   = 40           ; and only reacts to attacks from nearer than this
LEFT_EDGE    = 12           ; the ends of the floor
RIGHT_EDGE   = 240

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

; ---------------------------------------------------------------------------
; Fighters: poses, actions and the sprites
; ---------------------------------------------------------------------------
SPRITE_DATA = $2000
SHAPES      = SPRITE_DATA/64 ; 128: each pose is a top and a bottom shape
FACE_LEFT   = 20            ; add to a shape for the mirrored copy
POSE_GUARD  = 0             ; pose numbers, in the order of the shapes
POSE_STEP   = 1
POSE_PUNCH  = 2
POSE_KICK   = 3
POSE_HIGH   = 4
POSE_SWEEP  = 5
POSE_BLOCK  = 6
POSE_CROUCH = 7
POSE_HIT    = 8
POSE_WIN    = 9

A_IDLE      = 0             ; what a fighter is doing
A_PUNCH     = 1             ; actions 1-4 are attacks, rows of MOVES
A_KICK      = 2
A_HIGH      = 3
A_SWEEP     = 4
A_BLOCK     = 5
A_CROUCH    = 6
A_HIT       = 7
A_WIN       = 8
A_STEP      = 9

HIGH        = 1             ; how an attack is defended: crouching ducks it
LOW         = 2             ; blocking does not stop it
FIGHTER_Y   = 50+22*8-42    ; the top sprite's Y: feet on row 21
P1          = 0             ; fighter numbers: you, and the opponent
P2          = 1

C_SOLID     = 64            ; scenery characters
C_SLOPE_UP  = 65            ; a mountain top is C_SOLID, + 1 where the left
C_SLOPE_DOWN = 66           ; neighbour is lower, + 2 where the right one is:
C_PEAK      = 67            ; keep these four in this order
C_FADE_IN   = 68            ; where the sky changes colour: the colour below
C_FADE_OUT  = 69            ; fades in, then the colour above fades out
C_RIPPLE    = 70
C_SLAB      = 71            ; a paving slab, and (72) the end of one
C_ROOF      = 73            ; 73-74
C_PILLAR    = 75
C_POINT     = 76
C_NOPOINT   = 77
C_GLINT     = 78            ; 78-79: the sun on the water, left and right
SKY_TOP     = 2             ; the first row of sky, and of BAND_COLORS
SHORE_ROW   = 15            ; the lake's first row: the mountains stand on it
MESSAGE_ROW = 4             ; the referee speaks across the sky
FLOOR_COLOR = GREY          ; the paving
LAKE_COLOR  = BLUE          ; ripples
S_SUN       = 7             ; the sun's sprite: a higher number than the
SUN_SHAPE   = 168           ; fighters', so it is drawn behind them too
SUN_X       = 232           ; the sun's sprite position: its middle is over
SUN_Y       = 126           ; the glint in LAKE, and the hills hide its foot

; ---------------------------------------------------------------------------
; Zero page
; ---------------------------------------------------------------------------
frame_count = $02
joy         = $03
fire_armed  = $04
ptr         = $05           ; $05-$06
cptr        = $07           ; $07-$08
tmp         = $09
tmp2        = $0A
tmp3        = $0B
counter     = $0C
src         = $0D           ; $0D-$0E
dst         = $0F           ; $0F-$10
opening     = $11           ; your attack has just missed: a chance to hit back
band        = $12           ; which colour band the interrupt does next
belt        = $13           ; the opponent's belt, 0-6
score       = $14           ; $14-$16 BCD
hiscore     = $17           ; $17-$19
time        = $1A           ; BCD seconds
second      = $1B
pause       = $1C           ; frames the referee holds the fight
outcome     = $1D           ; what the pause is for
music_on    = $1F
mus_note    = $20
mus_wait    = $21           ; $21-$22
mus_pos     = $23           ; $23-$24
sid_off     = $25
mptr2       = $26           ; $26-$27
dist        = $28           ; how far apart the fighters are
fighter     = $29           ; which fighter a routine is working on
attack_now  = $2A           ; the player started an attack this frame
seed        = $2B           ; $2B-$2C, for RANDOM
sfx_start   = $30
sfx_time    = $33
sfx_wave    = $36
sfx_ad      = $39
sfx_sr      = $3C
sfx_flo     = $3F
sfx_fhi     = $42
sfx_dlo     = $45
sfx_dhi     = $48

ROW_LO      = $C000
ROW_HI      = $C020
F_X         = $C040         ; each fighter: where on the floor, 12-240 (its sprite
                            ; X is F_X+44, which may need bit 8 in $D010)
F_ACT       = $C042         ; what it is doing
F_TIMER     = $C044         ; frames left of it
F_POSE      = $C046
F_POINTS    = $C048
F_FACE      = $C04A         ; 0 facing right, FACE_LEFT facing left
F_COLOR     = $C04C
AI_WAIT     = $C050         ; the opponent's thinking time
AI_BACK     = $C051         ; frames it has left of backing off

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
        JSR mirror_sprites
        JSR init_sound
        LDA #BLACK
        STA VIC+$20
        STA VIC+$21
        LDA #$1E            ; screen $0400, characters $3800
        STA VIC+$18
        LDA #%00001111      ; the four fighter sprites are multicolour
        STA VIC+$1C
        LDA #LIGHT_RED      ; skin
        STA VIC+$25
        LDA #BLACK          ; hair and belts
        STA VIC+$26
        LDA #%10000000      ; the sun: twice as wide and tall, and behind the
        STA VIC+$17         ; scenery, so the mountains hide the part of it
        STA VIC+$1D         ; that has set
        STA VIC+$1B
        LDA #SUN_X
        STA VIC+S_SUN*2
        LDA #SUN_Y
        STA VIC+S_SUN*2+1
        LDA #YELLOW
        STA VIC+$27+S_SUN
        LDA #SUN_SHAPE
        STA SPRITE_PTRS+S_SUN
        LDA #0
        STA band
        STA score
        STA score+1
        STA score+2
        STA hiscore
        STA hiscore+1
        STA hiscore+2
        LDA #<irq
        STA $0314
        LDA #>irq
        STA $0315
        LDY band_line       ; a line before the first band (see IRQ)
        DEY
        STY VIC+$12
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
; THE SUNSET
; One interrupt routine runs 17 times a frame. For each text row of sky it
; sets the background colour and asks to be called again for the next row;
; after the last band it waits for line 251, where it does the frame's
; work: the black status lines, the frame count and the sound.
; Each band starts on a Bad Line, where the VIC-II takes the bus from the
; CPU for 40 cycles to fetch a row of characters: an interrupt asked for on
; that line would be held up, and change the colour a line late. So it is
; asked for a line early, and waits in a tight loop for the band's line,
; changing the colour in the first few cycles, before the VIC-II takes over.
; ===========================================================================
irq:
        CLD                 ; the 6502 keeps decimal mode for an interrupt
        LDA #1
        STA VIC+$19
        LDX band
        CPX #BANDS
        BEQ irq_frame
        LDA band_colors,X
        LDY band_line,X     ; wait while the raster is above the band's line:
        DEY                 ; then Y >= $D012 sets the carry (and if it is
irq_wait:                   ; already past the line, it goes straight on)
        CPY VIC+$12
        BCS irq_wait
        STA VIC+$21
        INX
        STX band
        LDY band_line,X     ; the line before the next band, or line 251
        CPX #BANDS          ; for the frame's work, which needs no wait
        BEQ irq_next
        DEY
irq_next:
        STY VIC+$12
        JMP $EA81
irq_frame:
        LDA #BLACK          ; the status lines at the top of the next frame
        STA VIC+$21
        LDA #0
        STA band
        LDY band_line
        DEY
        STY VIC+$12
        INC frame_count
        JSR music_update
        JSR sfx_update
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
        JSR place_fighters
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

; A random number in A. A 16-bit shift register stepped 8 times, so that
; one number says nothing about the next. Keeps X and Y.
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

; ---------------------------------------------------------------------------
; MIRROR_SPRITES - build the left-facing shapes from the right-facing ones.
; In a multicolour sprite each pixel is 2 bits, so a row of 3 bytes is
; mirrored by reversing the order of the bytes and of the 4 pixels in each.
; ---------------------------------------------------------------------------
mirror_sprites:
        LDA #<SPRITE_DATA
        STA src
        LDA #>SPRITE_DATA
        STA src+1
        LDA #<(SPRITE_DATA+FACE_LEFT*64)
        STA dst
        LDA #>(SPRITE_DATA+FACE_LEFT*64)
        STA dst+1
        LDA #FACE_LEFT      ; 20 shapes
        STA counter
ms_shape:
        LDY #0              ; Y = the first byte of a row: 0, 3, 6 ... 60
ms_row:
        LDA (src),Y         ; the left byte becomes the right one
        JSR mirror_byte
        INY
        INY
        STA (dst),Y
        DEY
        LDA (src),Y         ; the middle byte stays in the middle
        JSR mirror_byte
        STA (dst),Y
        INY
        LDA (src),Y         ; the right byte becomes the left one
        JSR mirror_byte
        DEY
        DEY
        STA (dst),Y
        INY
        INY
        INY
        CPY #63
        BNE ms_row
        LDA src             ; the next shape, 64 bytes on
        CLC
        ADC #64
        STA src
        BCC ms_dst
        INC src+1
ms_dst:
        LDA dst
        CLC
        ADC #64
        STA dst
        BCC ms_next
        INC dst+1
ms_next:
        DEC counter
        BNE ms_shape
        RTS

; Reverse the four 2-bit pixels of A.
mirror_byte:
        STA tmp
        LDA #0
        STA tmp2
        LDX #4
mb_pair:
        LDA tmp             ; the lowest pixel of the source...
        AND #3
        ASL tmp2            ; ...goes in at the bottom of the result,
        ASL tmp2            ; which moves up a pixel each time
        ORA tmp2
        STA tmp2
        LSR tmp
        LSR tmp
        DEX
        BNE mb_pair
        LDA tmp2
        RTS

; ===========================================================================
; THE TITLE SCREEN
; ===========================================================================
title_screen:
        JSR draw_scene
        LDA #START_BELT
        STA belt
        LDA #BOUT_TIME
        STA time
        LDA #0
        STA fire_armed
        STA pause
        STA F_POINTS
        STA F_POINTS+1
        LDA #<title_text
        LDX #>title_text
        JSR print_list
        JSR reset_fighters
        JSR show_status
        JSR start_music
ts_loop:
        JSR wait_frame
        JSR place_fighters
        LDA frame_count     ; the two fighters size each other up
        AND #63
        CMP #32
        LDA #POSE_GUARD
        BCC ts_pose
        LDA #POSE_STEP
ts_pose:
        STA F_POSE
        STA F_POSE+1
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
        LDA #START_BELT
        STA belt
pg_bout:
        JSR draw_scene
        LDA #0
        STA F_POINTS
        STA F_POINTS+1
        LDA #BOUT_TIME
        STA time
        JSR reset_fighters
        JSR show_status
        LDA #<begin_text
        LDX #>begin_text
        JSR say
        LDA #SFX_GONG
        LDX #2
        JSR sfx_play
        LDA #80
        JSR wait_frames
        JSR clear_message

; One pass per frame: the fighters are drawn, then everyone moves.
pg_loop:
        JSR wait_frame
        JSR place_fighters
        JSR read_joystick
        LDA #0
        STA attack_now
        LDX #P1
        JSR control_player
        LDX #P2
        JSR control_cpu
        LDA #0
        STA opening         ; set again if your attack misses now
        LDX #P1
        JSR update_fighter
        LDX #P2
        JSR update_fighter
        JSR clock
        LDA pause           ; the referee has stopped the fight
        BEQ pg_loop
        DEC pause
        BNE pg_loop
        LDA outcome
        CMP #O_POINT
        BEQ pg_point
        CMP #O_TIME
        BEQ pg_time_up
        JMP pg_loop
pg_point:
        JSR clear_message
        LDA F_POINTS        ; first to POINTS_TO_WIN
        CMP #POINTS_TO_WIN
        BCS pg_won
        LDA F_POINTS+1
        CMP #POINTS_TO_WIN
        BCS pg_lost
        JSR reset_fighters  ; back to the marks, and carry on
        JMP pg_loop
pg_time_up:
        LDA F_POINTS        ; out of time: the leader wins, a draw goes again
        CMP F_POINTS+1
        BEQ pg_draw
        BCS pg_won
        JMP pg_lost
pg_draw:
        LDA #<draw_text
        LDX #>draw_text
        JSR say
        LDA #100
        JSR wait_frames
        JMP pg_bout
pg_won:
        LDX #P1
        JSR fighter_wins
        LDA #<white_wins_text
        LDX #>white_wins_text
        JSR say
        LDX time            ; time left x 100 points
        LDA #0
        JSR add_score
        LDA #150
        JSR wait_frames
        LDA belt            ; a tougher opponent next
        CMP #6
        BCS pg_next
        INC belt
pg_next:
        JMP pg_bout
pg_lost:
        LDX #P2
        JSR fighter_wins
        LDA #<red_wins_text
        LDX #>red_wins_text
        JSR say
        LDA #150
        JSR wait_frames
        LDA #<over_text
        LDX #>over_text
        JSR say
        JSR update_hiscore
        JSR show_status     ; a new high score shows at once
        LDA #100
        JMP wait_frames

O_POINT     = 1             ; why the referee stopped the fight
O_TIME      = 2

; Both fighters back on their marks, on guard.
reset_fighters:
        LDA #84
        STA F_X
        LDA #176
        STA F_X+1
        LDA #0
        STA F_FACE
        LDA #FACE_LEFT
        STA F_FACE+1
        LDA #WHITE
        STA F_COLOR
        LDA #RED
        STA F_COLOR+1
        LDX #1
rf_loop:
        LDA #A_IDLE
        STA F_ACT,X
        LDA #0
        STA F_TIMER,X
        STA F_POSE,X
        DEX
        BPL rf_loop
        LDA #30
        STA AI_WAIT
        LDA #0
        STA AI_BACK
        LDA #50
        STA second
        LDA #%10001111      ; the fighters' four sprites, and the sun
        STA VIC+$15
        RTS

fighter_wins:               ; fighter X raises his arms
        LDA #A_WIN
        STA F_ACT,X
        LDA #POSE_WIN
        STA F_POSE,X
        TXA
        EOR #1
        TAY
        LDA #A_HIT
        STA F_ACT,Y
        LDA #POSE_HIT
        STA F_POSE,Y
        LDA #SFX_WIN
        LDX #2
        JMP sfx_play

; The bout clock: a second every 50 frames, stopped while the referee talks.
clock:
        LDA pause
        BNE ck_done
        DEC second
        BNE ck_done
        LDA #50
        STA second
        SED
        LDA time
        SEC
        SBC #1
        STA time
        CLD
        JSR show_time
        LDA time
        BNE ck_done
        LDA #O_TIME
        STA outcome
        LDA #60
        STA pause
        LDA #<time_text
        LDX #>time_text
        JMP say
ck_done:
        RTS

; ===========================================================================
; THE SCENE
; ===========================================================================
draw_scene:
        LDX #0              ; clear the screen
ds_clear:
        LDA #32
        STA SCREEN,X
        STA SCREEN+$100,X
        STA SCREEN+$200,X
        STA SCREEN+$2E8,X
        LDA #WHITE
        STA COLORS,X
        STA COLORS+$100,X
        STA COLORS+$200,X
        STA COLORS+$2E8,X
        INX
        BNE ds_clear
        LDX #SKY_TOP        ; the sky, a row at a time
ds_sky:
        JSR draw_sky_row
        INX
        CPX #SHORE_ROW
        BNE ds_sky
        LDX #39             ; the mountains: a height for each column
ds_column:
        LDA mountains,X
        BEQ ds_next_column
        STA tmp             ; rows from SHORE_ROW - height down to the shore
        LDA #SHORE_ROW
        SEC
        SBC tmp
        TAY                 ; the top row
        LDA #C_SOLID        ; its top: C_SOLID, + 1 if the left neighbour is
        STA tmp2            ; lower and + 2 if the right one is, makes a
        LDA mountains-1,X   ; slope up, a slope down or a peak
        CMP tmp
        BCS ds_right
        INC tmp2
ds_right:
        LDA mountains+1,X
        CMP tmp
        BCS ds_fill
        INC tmp2
        INC tmp2
ds_fill:
        LDA ROW_LO,Y
        STA ptr
        STA cptr
        LDA ROW_HI,Y
        STA ptr+1
        CLC
        ADC #>(COLORS-SCREEN)
        STA cptr+1
        STY tmp3
        TXA
        TAY
        LDA tmp2
        STA (ptr),Y
        LDA #BLACK
        STA (cptr),Y
        LDA #C_SOLID        ; solid rock below the top
        STA tmp2
        LDY tmp3
        INY
        CPY #SHORE_ROW
        BNE ds_fill
ds_next_column:
        DEX
        BPL ds_column
        LDX #0              ; the pagoda, from a little picture
ds_pagoda:
        LDA pagoda,X
        BEQ ds_lake
        LDY pagoda+1,X      ; row
        LDA ROW_LO,Y
        STA ptr
        STA cptr
        LDA ROW_HI,Y
        STA ptr+1
        CLC
        ADC #>(COLORS-SCREEN)
        STA cptr+1
        LDY pagoda+2,X      ; column
        LDA pagoda,X        ; character
        STA (ptr),Y
        LDA #BLACK
        STA (cptr),Y
        INX
        INX
        INX
        JMP ds_pagoda
ds_lake:
        LDX #79             ; the lake, from its picture: two rows of 40
ds_lake_cell:
        LDA lake,X
        LDY #3              ; which mark is it? Anything else is calm water
ds_lake_mark:
        CMP lake_marks,Y
        BEQ ds_lake_draw
        DEY
        BNE ds_lake_mark
ds_lake_draw:
        LDA lake_chars,Y
        STA SCREEN+SHORE_ROW*40,X
        LDA lake_inks,Y
        STA COLORS+SHORE_ROW*40,X
        DEX
        BPL ds_lake_cell
ds_floor:
        LDX #0              ; the paved courtyard, rows 17-24
ds_slab:
        TXA                 ; a slab ends every 8 columns...
        AND #7
        CMP #7              ; (carry is set only at the end of a slab)
        LDA #C_SLAB
        ADC #0              ; ADC #0 adds the carry: C_SLAB or C_SLAB+1
        STA SCREEN+17*40,X
        STA SCREEN+19*40,X
        STA SCREEN+21*40,X
        STA SCREEN+23*40,X
        TXA                 ; ...and 4 columns later on the rows between
        CLC
        ADC #4
        AND #7
        CMP #7
        LDA #C_SLAB
        ADC #0
        STA SCREEN+18*40,X
        STA SCREEN+20*40,X
        STA SCREEN+22*40,X
        STA SCREEN+24*40,X
        LDA #FLOOR_COLOR
        STA COLORS+17*40,X
        STA COLORS+18*40,X
        STA COLORS+19*40,X
        STA COLORS+20*40,X
        STA COLORS+21*40,X
        STA COLORS+22*40,X
        STA COLORS+23*40,X
        STA COLORS+24*40,X
        INX
        CPX #40
        BNE ds_slab
        RTS

; Fill sky row X with plain sky, or, where its colour meets a different one,
; with a dither that blends them: across the bottom of the upper band the
; colour below fades in, and across the top of the lower band the colour
; above fades out. (A band one row deep fades into the band below.) Keeps X.
draw_sky_row:
        LDA #32             ; the character...
        STA tmp2
        LDA #WHITE          ; ...and the colour of its pixels
        STA tmp3
        CPX #SKY_TOP        ; (the first row has no sky above it)
        BEQ dsr_below
        LDA band_colors-SKY_TOP-1,X
        CMP band_colors-SKY_TOP,X
        BEQ dsr_below
        STA tmp3            ; a new colour starts on this row
        LDA #C_FADE_OUT
        STA tmp2
dsr_below:
        CPX #SHORE_ROW-1    ; (the lake below has its own picture)
        BEQ dsr_fill
        LDA band_colors-SKY_TOP+1,X
        CMP band_colors-SKY_TOP,X
        BEQ dsr_fill
        STA tmp3            ; a new colour starts on the row below
        LDA #C_FADE_IN
        STA tmp2
dsr_fill:
        LDA ROW_LO,X
        STA ptr
        STA cptr
        LDA ROW_HI,X
        STA ptr+1
        CLC
        ADC #>(COLORS-SCREEN)
        STA cptr+1
        LDY #39
dsr_cell:
        LDA tmp2
        STA (ptr),Y
        LDA tmp3
        STA (cptr),Y
        DEY
        BPL dsr_cell
        RTS

; ===========================================================================
; STATUS AND MESSAGES
; ===========================================================================
show_status:
        LDA #<status_text
        LDX #>status_text
        JSR print_list
        LDY belt            ; the opponent's belt, in its colour
        LDA belt_colors,Y
        STA tmp
        TYA
        ASL
        ASL
        ASL
        ASL                 ; 16 bytes a name
        TAX
        LDY #0
ss_belt:
        LDA belt_names,X
        AND #$3F
        STA SCREEN+40+28,Y
        LDA tmp
        STA COLORS+40+28,Y
        INX
        INY
        CPY #12
        BNE ss_belt
        LDX #hiscore+2
        LDY #40+17
        LDA #3
        JSR print_bcd
        JSR show_points
        JSR show_time
show_score:
        LDX #score+2
        LDY #40+6
        LDA #3
        ; fall through

print_bcd:                  ; A bytes of BCD from zero page X down, at SCREEN + Y
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

show_time:
        LDX #time
        LDY #21
        LDA #1
        JMP print_bcd

; Each fighter's points as filled or empty circles: white's after WHITE,
; red's in light red, ending just before RED.
show_points:
        LDX #POINTS_TO_WIN-1
sp_loop:
        LDA #C_NOPOINT
        CPX F_POINTS
        BCS sp_white
        LDA #C_POINT
sp_white:
        STA SCREEN+6,X
        LDA #C_NOPOINT
        CPX F_POINTS+1
        BCS sp_red
        LDA #C_POINT
sp_red:
        STA SCREEN+33-POINTS_TO_WIN,X
        LDA #LIGHT_RED
        STA COLORS+33-POINTS_TO_WIN,X
        DEX
        BPL sp_loop
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

; The referee's words, across a row of the sky.
say:
        PHA
        TXA
        PHA
        JSR clear_message
        PLA
        TAX
        PLA
        JMP print
clear_message:
        LDX #MESSAGE_ROW
        JMP draw_sky_row

; ===========================================================================
; THE FIGHTERS
; ===========================================================================
; Is fighter X busy with something that cannot be interrupted?
; Carry set if so.
busy:
        LDA F_ACT,X
        BEQ by_free         ; idle
        CMP #A_SWEEP+1      ; attacks are actions 1-4
        BCC by_busy
        CMP #A_HIT
        BCC by_free         ; blocking or crouching
        CMP #A_STEP
        BEQ by_free
by_busy:
        SEC
        RTS
by_free:
        CLC
        RTS

; Start attack A for fighter X.
start_attack:
        STA F_ACT,X
        JSR move_row        ; Y = the attack's row in MOVES
        LDA moves+1,Y       ; how long it lasts
        CPX #P2
        BNE sa_timer
        LDY belt            ; the opponent winds up for longer at a lower belt:
        CLC                 ; the extra frames come before the attack lands
        ADC belt_slow,Y
sa_timer:
        STA F_TIMER,X
        TXA
        PHA
        LDA #SFX_WHOOSH
        LDX #2
        JSR sfx_play
        PLA
        TAX
        RTS

; Y = 6 x (action - 1): the row of MOVES for fighter X's attack.
move_row:
        LDA F_ACT,X
        SEC
        SBC #1
        STA tmp
        ASL
        ADC tmp             ; x 3
        ASL                 ; x 6
        TAY
        RTS

; You: the joystick decides.
control_player:
        LDA pause
        BNE cp_done
        JSR busy
        BCS cp_done
        LDA joy
        AND #JOY_FIRE
        BEQ cp_no_fire
        LDA fire_armed      ; an attack needs a fresh press of fire
        BEQ cp_done
        LDA #0
        STA fire_armed
        LDA joy             ; LSR moves out up, down, left, right in turn
        LDY #A_HIGH
        LSR                 ; up: high kick
        BCS cp_attack
        LDY #A_SWEEP
        LSR                 ; down: sweep
        BCS cp_attack
        LDY #A_PUNCH
        LSR                 ; left (away): punch
        BCS cp_attack
        LDY #A_KICK
        LSR                 ; right (towards): front kick
        BCS cp_attack
        LDY #A_PUNCH        ; no direction: punch
cp_attack:
        TYA
        STA attack_now      ; the opponent may see it coming
        JMP start_attack
cp_no_fire:
        LDA #1
        STA fire_armed
        LDA joy
        LDY #A_BLOCK
        LSR
        BCS cp_hold
        LDY #A_CROUCH
        LSR
        BCS cp_hold
        LSR
        BCS cp_back
        LSR
        BCS cp_forward
        LDA #A_IDLE
        STA F_ACT,X
cp_done:
        RTS
cp_hold:
        TYA
        STA F_ACT,X
        RTS
cp_back:
        LDA F_X
        CMP #LEFT_EDGE+WALK_SPEED
        BCC cp_still
        SEC
        SBC #WALK_SPEED
        STA F_X
        JMP cp_stepping
cp_forward:
        LDA F_X+1
        SEC
        SBC F_X
        CMP #CLOSEST+WALK_SPEED
        BCC cp_still
        LDA F_X
        CLC
        ADC #WALK_SPEED
        STA F_X
cp_stepping:
        LDA #A_STEP
        STA F_ACT,X
        RTS
cp_still:
        LDA #A_IDLE
        STA F_ACT,X
        RTS

; The opponent: sees your attacks coming, hits back when you miss, closes
; in and attacks. How quick and how wary it is comes from its belt.
control_cpu:
        LDA pause
        BNE cc_done
        JSR busy
        BCS cc_done
        LDA F_X+1
        SEC
        SBC F_X
        STA dist
        LDA attack_now      ; you have just attacked: does it see it coming?
        BNE cc_seen
        LDA opening         ; your attack has just missed: hit back?
        BEQ cc_no_chance
        LDA dist            ; only if its front kick, the longest, can reach
        CMP moves+6+3
        BCS cc_no_chance
        JSR random
        LDY belt
        CMP belt_counter,Y
        BCS cc_no_chance
        LDA #A_PUNCH        ; a quick punch if it reaches, or else the kick
        LDY dist
        CPY moves+3         ; (the punch's reach)
        BCC cc_strike
        LDA #A_KICK
cc_strike:
        JMP start_attack
cc_seen:
        LDA dist
        CMP #SEEN_RANGE
        BCS cc_no_chance
        JSR random
        LDY belt
        CMP belt_react,Y
        BCS cc_no_chance
        LDA attack_now
        LDY #A_CROUCH       ; duck punches and high kicks...
        CMP #A_PUNCH
        BEQ cc_defend
        CMP #A_HIGH
        BEQ cc_defend
        LDY #A_BLOCK        ; ...block front kicks...
        CMP #A_KICK
        BEQ cc_defend
        LDA dist            ; ...and beat a slow sweep with a quick punch,
        CMP moves+3         ; if a punch can reach
        BCS cc_no_chance
        LDA #A_PUNCH
        JMP start_attack
cc_defend:
        TYA
        STA F_ACT,X
cc_done:
        RTS
cc_no_chance:
        LDA F_ACT,X         ; defending: for as long as your attack lasts
        CMP #A_BLOCK
        BEQ cc_hold
        CMP #A_CROUCH
        BNE cc_think
cc_hold:
        LDA F_ACT
        BEQ cc_idle
        CMP #A_SWEEP+1
        BCC cc_done
        BCS cc_idle
cc_think:
        LDA AI_BACK         ; backing off, a step a frame
        BEQ cc_wait
        DEC AI_BACK
        LDA F_X+1
        CMP #RIGHT_EDGE
        BCS cc_idle
        CLC
        ADC #WALK_SPEED
        STA F_X+1
        JMP cc_step
cc_wait:
        LDA AI_WAIT
        BEQ cc_decide
        DEC AI_WAIT
cc_idle:
        LDA #A_IDLE
        STA F_ACT,X
        RTS
cc_decide:
        LDA dist
        CMP #CPU_RANGE      ; too far away: walk in
        BCC cc_close
        LDA F_X+1
        SEC
        SBC #WALK_SPEED
        STA F_X+1
cc_step:
        LDA #A_STEP
        STA F_ACT,X
        RTS
cc_close:
        JSR random          ; near enough: attack, now and then
        LDY belt
        CMP belt_attack,Y
        BCS cc_crowded
        JSR random          ; which attack?
        AND #7
        TAY
        LDA cpu_attacks,Y
        STA tmp3
        LDA F_ACT           ; are you blocking or ducking? It may notice
        LDY #A_SWEEP        ; a sweep gets under a block...
        CMP #A_BLOCK
        BEQ cc_notice
        LDY #A_KICK         ; ...and a front kick catches you ducking
        CMP #A_CROUCH
        BNE cc_throw
cc_notice:
        JSR random
        STY tmp2
        LDY belt
        CMP belt_react,Y
        BCS cc_throw
        LDA tmp2
        STA tmp3
cc_throw:
        LDA tmp3
        JSR start_attack
        LDY belt            ; and a pause before the next thought
        LDA belt_wait,Y
        STA AI_WAIT
        RTS
cc_crowded:
        LDA dist            ; standing very close: now and then back off
        CMP #CLOSEST+4
        BCS cc_idle
        JSR random
        CMP #8
        BCS cc_idle
        AND #7
        ADC #12
        STA AI_BACK         ; for 12-19 frames
        JMP cc_idle
; Move fighter X's action on a frame and pick its pose.
update_fighter:
        LDA F_ACT,X
        BEQ uf_guard
        CMP #A_SWEEP+1
        BCC uf_attack
        TAY
        LDA action_pose,Y   ; still poses: block, crouch, hit, win
        CPY #A_STEP
        BNE uf_set
        LDA pause           ; stepping: alternate two poses, but stand still
        BNE uf_guard        ; while the referee holds the fight
        LDA frame_count
        AND #8
        BEQ uf_guard
        LDA #POSE_STEP
        JMP uf_set
uf_guard:
        LDA #POSE_GUARD
uf_set:
        STA F_POSE,X
        LDA F_ACT,X
        CMP #A_HIT          ; a hit fighter recovers in time
        BNE uf_done
        LDA pause
        BNE uf_done
        DEC F_TIMER,X
        BNE uf_done
        LDA #A_IDLE
        STA F_ACT,X
uf_done:
        RTS
uf_attack:
        JSR move_row
        LDA moves,Y         ; the attack's pose
        STA F_POSE,X
        LDA F_TIMER,X       ; the moment it lands
        CMP moves+2,Y
        BNE uf_count
        STY tmp3
        JSR resolve_attack
uf_count:
        DEC F_TIMER,X
        BNE uf_done
        LDA #A_IDLE
        STA F_ACT,X
        RTS

; Fighter X's attack lands, if the other is in reach. MOVES row is tmp3.
resolve_attack:
        STX fighter
        LDA pause
        BNE ra_done         ; the referee is already talking
        LDA F_X+1
        SEC
        SBC F_X
        LDY tmp3
        CMP moves+3,Y       ; out of reach?
        BCS ra_missed
        TXA
        EOR #1
        TAX                 ; X = the defender now
        LDA F_ACT,X
        CMP #A_HIT          ; already down?
        BEQ ra_done
        CMP #A_WIN
        BEQ ra_done
        CMP #A_CROUCH
        BNE ra_not_ducking
        LDA moves+4,Y       ; ducking: high attacks go over the top
        AND #HIGH
        BNE ra_missed
        JMP ra_hit
ra_not_ducking:
        CMP #A_BLOCK
        BNE ra_hit
        LDA moves+4,Y       ; blocking stops all but a sweep
        AND #LOW
        BNE ra_hit
        LDA #SFX_BLOCK
        LDX #2
        JSR sfx_play
ra_missed:
        LDX fighter         ; you missed: the opponent may hit back
        BNE ra_done
        INC opening
ra_done:
        LDX fighter
        RTS
ra_hit:
        LDA #A_HIT
        STA F_ACT,X
        LDA #40
        STA F_TIMER,X
        LDX fighter         ; points to the attacker
        LDA F_POINTS,X
        CLC
        ADC moves+5,Y
        STA F_POINTS,X
        CPX #P1
        BNE ra_announce
        LDA moves+5,Y       ; you scored: 500, or 1000 for a 2-point move
        CMP #2
        LDA #$00
        LDX #$05
        BCC ra_points
        LDX #$10
ra_points:
        JSR add_score
        LDX fighter
ra_announce:
        JSR show_points
        LDA #SFX_HIT
        LDX #2
        JSR sfx_play
        LDA #O_POINT
        STA outcome
        LDA #70
        STA pause
        LDA fighter
        BNE ra_red
        LDA #<white_point_text
        LDX #>white_point_text
        JSR say
        LDX fighter
        RTS
ra_red:
        LDA #<red_point_text
        LDX #>red_point_text
        JSR say
        LDX fighter
        RTS

; Put both fighters on screen: two sprites each, one above the other.
place_fighters:
        LDA #0
        STA tmp2            ; bit 8 of each sprite's X, for $D010
        LDX #1
pf_fighter:
        TXA
        ASL
        TAY                 ; Y = the fighter's top sprite: 0 or 2
        LDA F_POSE,X        ; the shapes: 2 per pose, plus the facing
        ASL
        CLC
        ADC F_FACE,X
        ADC #SHAPES
        STA SPRITE_PTRS,Y
        CLC
        ADC #1
        STA SPRITE_PTRS+1,Y
        LDA F_COLOR,X
        STA VIC+$27,Y
        STA VIC+$28,Y
        TYA
        ASL
        TAY                 ; Y = the top sprite's position registers
        LDA F_X,X           ; screen X = position + 44: the arena is centred
        CLC
        ADC #44
        STA VIC,Y
        STA VIC+2,Y
        BCC pf_low
        LDA tmp2            ; past 255: set bit 8 for both sprites
        ORA fighter_msb,X
        STA tmp2
pf_low:
        LDA #FIGHTER_Y
        STA VIC+1,Y
        LDA #FIGHTER_Y+21
        STA VIC+3,Y
        DEX
        BPL pf_fighter
        LDA tmp2
        STA VIC+$10
        RTS

; ===========================================================================
; HELPERS
; ===========================================================================
make_row_table:             ; the address of each screen row
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
        AND #%11111011      ; the ROM appears at $D000 while bit 2 is off
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

print_list:                 ; print messages until a row of $FF
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
        AND #$3F            ; PETSCII letters to screen codes
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
; MUSIC
; Voices 1 and 2 each read pairs of bytes from their own list: a note
; (0 = rest) and how many frames it lasts. $FF goes back to the start.
; ===========================================================================
start_music:
        LDA #0
        STA music_on
        STA mus_pos
        STA mus_pos+1
        LDA #1
        STA mus_wait
        STA mus_wait+1
        LDA #$0A            ; the tune: plucked, like a koto
        STA SID+5
        LDA #$00
        STA SID+6
        LDA #$06
        STA SID+3           ; a thin pulse
        LDA #$0B            ; the bass: a soft triangle that dies away
        STA SID+12
        LDA #$00
        STA SID+13
        LDA #1
        STA music_on
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

; Voice X (0 = tune, 1 = bass) starts its next note.
next_note:
        LDA mus_list_lo,X
        STA mptr2
        LDA mus_list_hi,X
        STA mptr2+1
        LDY mus_pos,X
        LDA (mptr2),Y
        CMP #$FF
        BNE nn_note
        LDY #0              ; the end: round again
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
        STA SID+4,Y         ; gate off: the last note fades
        LDA mus_note
        BEQ nn_done         ; a rest
        TAY
        LDA note_lo-1,Y     ; the note table starts at note 1
        PHA
        LDA note_hi-1,Y
        LDY sid_off
        STA SID+1,Y
        PLA
        STA SID,Y
        LDA mus_wave,X
        ORA #1
        STA SID+4,Y         ; gate on: the new note starts
nn_done:
        RTS

; ===========================================================================
; SOUND EFFECTS on voice 3 (see Alien Armada for how the driver works)
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
        RTS

sfx_play:                   ; effect A (an offset into SFX_TABLE) on voice X
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

sfx_update:
        LDX #2              ; only voice 3: the music has the others
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
fighter_msb:    BYTE %00000011, %00001100   ; each fighter's two sprites in $D010

; ---------------------------------------------------------------------------
; THE MOVES. One row of six bytes for each attack:
;   the pose; how many frames it lasts; the frame it lands on, counting
;   down; how close the other fighter must be; how it is defended; points.
; Crouching ducks a HIGH attack and blocking stops all but a LOW one.
; ---------------------------------------------------------------------------
moves:
        BYTE POSE_PUNCH, 14, 9,  22, HIGH, 1    ; punch: quick, short
        BYTE POSE_KICK,  18, 11, 26, 0,    1    ; front kick: the longest reach
        BYTE POSE_HIGH,  22, 12, 24, HIGH, 2    ; high kick: slow, 2 points
        BYTE POSE_SWEEP, 22, 12, 24, LOW,  1    ; leg sweep: gets under a block

; The pose for each action (attacks take theirs from MOVES)
action_pose:
        BYTE POSE_GUARD, POSE_PUNCH, POSE_KICK, POSE_HIGH, POSE_SWEEP
        BYTE POSE_BLOCK, POSE_CROUCH, POSE_HIT, POSE_WIN, POSE_STEP

; What the opponent likes to throw
cpu_attacks:
        BYTE A_PUNCH, A_KICK, A_KICK, A_HIGH, A_SWEEP, A_PUNCH, A_KICK, A_SWEEP

; ---------------------------------------------------------------------------
; THE BELTS. The opponent gets a higher belt each time you win.
; ---------------------------------------------------------------------------
belt_names:
        TEXT "  WHITE BELT    "
        TEXT " YELLOW BELT    "
        TEXT " ORANGE BELT    "
        TEXT "  GREEN BELT    "
        TEXT "   BLUE BELT    "
        TEXT "  BROWN BELT    "
        TEXT "  BLACK BELT    "
belt_colors:    BYTE WHITE, YELLOW, ORANGE, GREEN, LIGHT_BLUE, BROWN, DARK_GREY
; Chance in 256 each frame that it attacks when it is near
belt_attack:    BYTE 6, 8, 10, 12, 16, 20, 26
; Frames it waits after an attack before it thinks again
belt_wait:      BYTE 40, 34, 28, 24, 20, 16, 12
; Chance in 256 that it sees your attack coming and defends, or sees how
; you are defending and picks the attack that beats it
belt_react:     BYTE 40, 64, 88, 112, 136, 164, 200
; Chance in 256 that it hits back when your attack misses
belt_counter:   BYTE 32, 56, 80, 104, 128, 160, 200
; Extra frames it takes to wind up an attack
belt_slow:      BYTE 10, 8, 7, 6, 4, 2, 0

; ---------------------------------------------------------------------------
; THE SCENE
; ---------------------------------------------------------------------------
; The sunset: the background colour for each text row from row 2 down,
; and the raster line the interrupt changes it on. Where one row's colour
; differs from the next, DRAW_SKY_ROW blends them. Rows 15 and 16 are the
; lake, which mirrors the sky, and the last band is the courtyard; after
; it, line 251 is where the frame's work is done.
BANDS = 16
band_colors:
        BYTE BLUE, BLUE, PURPLE, PURPLE, PURPLE, PURPLE
        BYTE LIGHT_RED, LIGHT_RED, LIGHT_RED, LIGHT_RED, LIGHT_RED
        BYTE LIGHT_RED, LIGHT_RED
        BYTE LIGHT_RED, PURPLE      ; the lake
        BYTE DARK_GREY              ; the courtyard
band_line:
        BYTE 67, 75, 83, 91, 99, 107, 115, 123
        BYTE 131, 139, 147, 155, 163, 171, 179, 187
        BYTE 251

; The height of the mountains in each column, from the shore up, with a
; spare at each end so a column can look at its neighbours.
        BYTE 1
mountains:
        BYTE 1, 2, 3, 4, 5, 6, 5, 4, 3, 2
        BYTE 3, 4, 5, 6, 7, 6, 5, 4, 3, 2
        BYTE 1, 1, 2, 3, 4, 3, 2, 2, 2, 2
        BYTE 2, 2, 3, 4, 5, 4, 3, 2, 1, 1
        BYTE 1

; A pagoda on the first peak: character, row, column ... 0
pagoda:
        BYTE C_ROOF, 6, 5,   C_ROOF+1, 6, 6
        BYTE C_PILLAR, 7, 5, C_PILLAR, 7, 6
        BYTE C_ROOF, 8, 4,   C_SOLID, 8, 5,  C_SOLID, 8, 6,  C_ROOF+1, 8, 7
        BYTE C_PILLAR, 9, 5, C_PILLAR, 9, 6
        BYTE 0

; THE LAKE, a row of text for each row of water: - is a ripple, and ( and )
; are the two halves of the sun's reflection, under SUN_X.
lake:
        TEXT " -    -    -     -   -  -   ()   -   -  "
        TEXT "   -     -    -   -    -    () -    -   "
lake_marks:     BYTE ' ', '-', '(', ')'
lake_chars:     BYTE 32, C_RIPPLE, C_GLINT, C_GLINT+1
lake_inks:      BYTE LAKE_COLOR, LAKE_COLOR, YELLOW, YELLOW

; ---------------------------------------------------------------------------
; TEXT: row, column, colour, then the words
; ---------------------------------------------------------------------------
title_text:
        BYTE 2, 12, YELLOW
        ASCIIZ "D O J O   D U E L"
        BYTE 4, 6, WHITE
        ASCIIZ "FIRE: PUNCH   FIRE+TOWARDS: KICK"
        BYTE 5, 6, WHITE
        ASCIIZ "FIRE+UP: HIGH  FIRE+DOWN: SWEEP"
        BYTE 6, 10, WHITE
        ASCIIZ "UP: BLOCK   DOWN: DUCK"
        BYTE 7, 10, YELLOW
        ASCIIZ "PRESS FIRE TO BOW IN"
        BYTE $FF
status_text:
        BYTE 0, 0, WHITE
        ASCIIZ "WHITE"
        BYTE 0, 16, GREY
        ASCIIZ "TIME"
        BYTE 0, 21, YELLOW
        ASCIIZ "  "
        BYTE 0, 34, LIGHT_RED
        ASCIIZ "RED"
        BYTE 1, 0, GREY
        ASCIIZ "SCORE"
        BYTE 1, 13, GREY
        ASCIIZ "HI"
        BYTE $FF
begin_text:
        BYTE MESSAGE_ROW, 16, WHITE
        ASCIIZ "HAJIME!"
white_point_text:
        BYTE MESSAGE_ROW, 13, WHITE
        ASCIIZ "POINT TO WHITE"
red_point_text:
        BYTE MESSAGE_ROW, 14, WHITE
        ASCIIZ "POINT TO RED"
white_wins_text:
        BYTE MESSAGE_ROW, 10, WHITE
        ASCIIZ "WHITE WINS THE BOUT"
red_wins_text:
        BYTE MESSAGE_ROW, 11, WHITE
        ASCIIZ "RED WINS THE BOUT"
draw_text:
        BYTE MESSAGE_ROW, 10, WHITE
        ASCIIZ "A DRAW - FIGHT AGAIN"
time_text:
        BYTE MESSAGE_ROW, 17, WHITE
        ASCIIZ "TIME!"
over_text:
        BYTE MESSAGE_ROW, 15, WHITE
        ASCIIZ "GAME OVER"

; ---------------------------------------------------------------------------
; Sound effects for voice 3: waveform, attack/decay, sustain/release,
; frequency low, high, change per frame low, high, length in frames.
; ---------------------------------------------------------------------------
SFX_WHOOSH  = 0
SFX_HIT     = 8
SFX_BLOCK   = 16
SFX_GONG    = 24
SFX_WIN     = 32
sfx_table:
        BYTE 128, $00, $90, $00, $18, $00, $06, 6    ; whoosh: rising noise
        BYTE 128, $09, $00, $00, $0C, $80, $FF, 12   ; hit: a falling thump
        BYTE 64,  $04, $00, $00, $10, $00, $FF, 5    ; block: a wooden tock
        BYTE 64,  $0A, $0A, $00, $09, $FF, $FF, 50   ; gong: a deep, slow bong
        BYTE 32,  $00, $F8, $00, $10, $40, $00, 50   ; win: a rising call

; ---------------------------------------------------------------------------
; The tune, on the five notes of a pentatonic scale: A C D E G.
; Notes are numbered in semitones from C2 = 1.
; ---------------------------------------------------------------------------
E2 = 5
G2 = 8
A2 = 10
D3 = 15
E3 = 17
D4 = 27
E4 = 29
G4 = 32
A4 = 34
C5 = 37
D5 = 39
E5 = 41
mus_list_lo:    BYTE <melody, <bass
mus_list_hi:    BYTE >melody, >bass
mus_wave:       BYTE 64, 16         ; pulse for the tune, triangle for the bass

melody:
        BYTE A4,16, C5,8, A4,8, G4,16, E4,16
        BYTE D4,8, E4,8, G4,8, A4,8, E4,32
        BYTE A4,16, C5,8, D5,8, E5,16, D5,8, C5,8
        BYTE A4,16, G4,8, E4,8, A4,32
        BYTE D5,16, C5,8, A4,8, G4,16, A4,16
        BYTE E4,8, G4,8, A4,8, C5,8, D5,32
        BYTE E5,16, D5,8, C5,8, A4,16, G4,8, E4,8
        BYTE D4,8, E4,8, G4,8, E4,8, A4,32
        BYTE $FF
bass:
        BYTE A2,32, E3,32, D3,32, A2,32
        BYTE A2,32, E3,32, E2,32, A2,32
        BYTE D3,32, A2,32, E2,32, G2,32
        BYTE A2,32, E3,32, E2,32, A2,32
        BYTE $FF

; The SID frequency of each note from C2 (PAL)
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
; Each pose is two multicolour sprites, 12 double-wide pixels across and
; 21 rows each: %01 skin ($D025), %10 the fighter's colour, %11 black
; ($D026). Only the shapes facing right are here; see MIRROR_SPRITES.
; ===========================================================================

        ORG SPRITE_DATA+0*64   ; 128: guard, facing right: top
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%11111100,%00000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11010101,%00000000
        BYTE %00000011,%01010111,%01000000
        BYTE %00000000,%01010101,%00000000
        BYTE %00000000,%00010100,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00001010,%10101010,%10100000
        BYTE %00001010,%10101010,%10010100
        BYTE %00001010,%10101010,%00010100
        BYTE %00011010,%10101010,%00000000
        BYTE %00010110,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000

        ORG SPRITE_DATA+1*64   ; 129: guard, facing right: bottom
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11101110,%00000000
        BYTE %00001010,%10101010,%10000000
        BYTE %00001010,%10101010,%10100000
        BYTE %00001010,%10000010,%10100000
        BYTE %00001010,%10000010,%10100000
        BYTE %00101010,%00000000,%10101000
        BYTE %00101010,%00000000,%10101000
        BYTE %00101010,%00000000,%00101010
        BYTE %00101010,%00000000,%00101010
        BYTE %00101000,%00000000,%00101010
        BYTE %00101000,%00000000,%00001010
        BYTE %00101000,%00000000,%00001010
        BYTE %00101000,%00000000,%00001010
        BYTE %00101000,%00000000,%00001010
        BYTE %00010100,%00000000,%00000101
        BYTE %00010100,%00000000,%00000101
        BYTE %01010100,%00000000,%00000101
        BYTE %01010100,%00000000,%00010101

        ORG SPRITE_DATA+2*64   ; 130: step, facing right: top
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%11111100,%00000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11010101,%00000000
        BYTE %00000011,%01010111,%01000000
        BYTE %00000000,%01010101,%00000000
        BYTE %00000000,%00010100,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00001010,%10101010,%10100000
        BYTE %00001010,%10101010,%10010100
        BYTE %00001010,%10101010,%00010100
        BYTE %00011010,%10101010,%00000000
        BYTE %00010110,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000

        ORG SPRITE_DATA+3*64   ; 131: step, facing right: bottom
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11101110,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10100010,%10000000
        BYTE %00000010,%10100010,%10100000
        BYTE %00001010,%10000000,%10100000
        BYTE %00001010,%10000000,%10100000
        BYTE %00001010,%00000000,%10101000
        BYTE %00001010,%00000000,%00101000
        BYTE %00001010,%00000000,%00101000
        BYTE %00001010,%00000000,%00101000
        BYTE %00001010,%00000000,%00101000
        BYTE %00001010,%00000000,%00101000
        BYTE %00000101,%00000000,%00010100
        BYTE %00000101,%00000000,%00010100
        BYTE %00010101,%00000000,%00010101
        BYTE %00010101,%00000000,%00010101

        ORG SPRITE_DATA+4*64   ; 132: punch, facing right: top
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%11111100,%00000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11010101,%00000000
        BYTE %00000011,%01010111,%01000000
        BYTE %00000000,%01010101,%00000000
        BYTE %00000000,%00010100,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00001010,%10101010,%10101010
        BYTE %00001010,%10101010,%10100101
        BYTE %00001010,%10101010,%00000101
        BYTE %00011010,%10101010,%00000000
        BYTE %00010110,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000

        ORG SPRITE_DATA+5*64   ; 133: punch, facing right: bottom
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11101110,%00000000
        BYTE %00001010,%10101010,%10000000
        BYTE %00001010,%10101010,%10100000
        BYTE %00001010,%10000010,%10100000
        BYTE %00001010,%10000010,%10100000
        BYTE %00101010,%00000000,%10101000
        BYTE %00101010,%00000000,%10101000
        BYTE %00101010,%00000000,%00101010
        BYTE %00101010,%00000000,%00101010
        BYTE %00101000,%00000000,%00101010
        BYTE %00101000,%00000000,%00001010
        BYTE %00101000,%00000000,%00001010
        BYTE %00101000,%00000000,%00001010
        BYTE %00101000,%00000000,%00001010
        BYTE %00010100,%00000000,%00000101
        BYTE %00010100,%00000000,%00000101
        BYTE %01010100,%00000000,%00000101
        BYTE %01010100,%00000000,%00010101

        ORG SPRITE_DATA+6*64   ; 134: kick, facing right: top
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%11111100,%00000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11010101,%00000000
        BYTE %00000011,%01010111,%01000000
        BYTE %00000000,%01010101,%00000000
        BYTE %00000000,%00010100,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00001010,%10101010,%10000000
        BYTE %00011010,%10101010,%10000000
        BYTE %00010110,%10101010,%01000000
        BYTE %00001010,%10101001,%01000000
        BYTE %00001010,%10101000,%00000000
        BYTE %00001010,%10101000,%00000000
        BYTE %00001010,%10101000,%00000000
        BYTE %00001010,%10101000,%00000000

        ORG SPRITE_DATA+7*64   ; 135: kick, facing right: bottom
        BYTE %00001010,%10101000,%00000000
        BYTE %00001010,%10101000,%00000000
        BYTE %00001111,%11111100,%00000000
        BYTE %00001111,%10111010,%10101010
        BYTE %00001010,%10101010,%10101010
        BYTE %00001010,%10101010,%10100101
        BYTE %00001010,%10000000,%00000101
        BYTE %00001010,%10000000,%00000000
        BYTE %00001010,%10000000,%00000000
        BYTE %00001010,%10000000,%00000000
        BYTE %00001010,%10000000,%00000000
        BYTE %00001010,%10000000,%00000000
        BYTE %00001010,%00000000,%00000000
        BYTE %00001010,%00000000,%00000000
        BYTE %00001010,%00000000,%00000000
        BYTE %00001010,%00000000,%00000000
        BYTE %00001010,%00000000,%00000000
        BYTE %00000101,%00000000,%00000000
        BYTE %00000101,%00000000,%00000000
        BYTE %00010101,%00000000,%00000000
        BYTE %00010101,%00000000,%00000000

        ORG SPRITE_DATA+8*64   ; 136: highkick, facing right: top
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%11111100,%00000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11010101,%00000101
        BYTE %00000011,%01010111,%10100101
        BYTE %00000000,%01010110,%10101000
        BYTE %00000000,%00011010,%10100000
        BYTE %00000010,%10101010,%10100000
        BYTE %00001010,%10101010,%10000000
        BYTE %00011010,%10101010,%00000000
        BYTE %00010110,%10101010,%00000000
        BYTE %00001010,%10101010,%00000000
        BYTE %00001010,%10101010,%00000000
        BYTE %00001010,%10101010,%00000000
        BYTE %00001010,%10101000,%00000000
        BYTE %00001010,%10101000,%00000000
        BYTE %00001010,%10101000,%00000000
        BYTE %00001010,%10101000,%00000000

        ORG SPRITE_DATA+9*64   ; 137: highkick, facing right: bottom
        BYTE %00001111,%11111100,%00000000
        BYTE %00001111,%10111000,%00000000
        BYTE %00001010,%10101000,%00000000
        BYTE %00001010,%10100000,%00000000
        BYTE %00001010,%10000000,%00000000
        BYTE %00001010,%10000000,%00000000
        BYTE %00001010,%10000000,%00000000
        BYTE %00001010,%10000000,%00000000
        BYTE %00001010,%10000000,%00000000
        BYTE %00001010,%10000000,%00000000
        BYTE %00001010,%10000000,%00000000
        BYTE %00001010,%00000000,%00000000
        BYTE %00001010,%00000000,%00000000
        BYTE %00001010,%00000000,%00000000
        BYTE %00001010,%00000000,%00000000
        BYTE %00001010,%00000000,%00000000
        BYTE %00001010,%00000000,%00000000
        BYTE %00000101,%00000000,%00000000
        BYTE %00000101,%00000000,%00000000
        BYTE %00010101,%00000000,%00000000
        BYTE %00010101,%00000000,%00000000

        ORG SPRITE_DATA+10*64   ; 138: sweep, facing right: top
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%11111100,%00000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11010101,%00000000
        BYTE %00000011,%01010111,%01000000

        ORG SPRITE_DATA+11*64   ; 139: sweep, facing right: bottom
        BYTE %00000000,%01010101,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00001010,%10101010,%10100000
        BYTE %00011010,%10101010,%10100000
        BYTE %00010110,%10101010,%10100000
        BYTE %00001010,%10101010,%10000000
        BYTE %00001010,%10101010,%10000000
        BYTE %00001010,%10101010,%10000000
        BYTE %00001111,%11111111,%11000000
        BYTE %00001111,%10111010,%10100000
        BYTE %00101010,%10101010,%10101010
        BYTE %00101010,%10101010,%10101010
        BYTE %00101010,%10000000,%00010101
        BYTE %00101010,%00000000,%00010101
        BYTE %00101010,%00000000,%00000000
        BYTE %00101010,%00000000,%00000000
        BYTE %00101000,%00000000,%00000000
        BYTE %00010100,%00000000,%00000000
        BYTE %00010100,%00000000,%00000000
        BYTE %01010100,%00000000,%00000000
        BYTE %01010100,%00000000,%00000000

        ORG SPRITE_DATA+12*64   ; 140: block, facing right: top
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%11111100,%00000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11010101,%00000000
        BYTE %00000011,%01010111,%01000000
        BYTE %00000000,%01010101,%00000000
        BYTE %00000000,%00010100,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00001010,%10101010,%10010100
        BYTE %00001010,%10101010,%10010100
        BYTE %00001010,%10101010,%10101000
        BYTE %00011010,%10101010,%10100000
        BYTE %00010110,%10101010,%10000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000

        ORG SPRITE_DATA+13*64   ; 141: block, facing right: bottom
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11101110,%00000000
        BYTE %00001010,%10101010,%10000000
        BYTE %00001010,%10101010,%10100000
        BYTE %00001010,%10000010,%10100000
        BYTE %00001010,%10000010,%10100000
        BYTE %00101010,%00000000,%10101000
        BYTE %00101010,%00000000,%10101000
        BYTE %00101010,%00000000,%00101010
        BYTE %00101010,%00000000,%00101010
        BYTE %00101000,%00000000,%00101010
        BYTE %00101000,%00000000,%00001010
        BYTE %00101000,%00000000,%00001010
        BYTE %00101000,%00000000,%00001010
        BYTE %00101000,%00000000,%00001010
        BYTE %00010100,%00000000,%00000101
        BYTE %00010100,%00000000,%00000101
        BYTE %01010100,%00000000,%00000101
        BYTE %01010100,%00000000,%00010101

        ORG SPRITE_DATA+14*64   ; 142: crouch, facing right: top
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%11111100,%00000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11010101,%00000000
        BYTE %00000011,%01010111,%01000000

        ORG SPRITE_DATA+15*64   ; 143: crouch, facing right: bottom
        BYTE %00000000,%01010101,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00001010,%10101010,%10010100
        BYTE %00001010,%10101010,%10010100
        BYTE %00011010,%10101010,%10000000
        BYTE %00010110,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00001010,%10101010,%10100000
        BYTE %00101010,%10101010,%10101000
        BYTE %00101010,%10000010,%10101000
        BYTE %00101010,%00000000,%10101000
        BYTE %00101010,%00000000,%10101000
        BYTE %00101010,%00000000,%00101000
        BYTE %00101000,%00000000,%00101000
        BYTE %00101000,%00000000,%00101000
        BYTE %00010100,%00000000,%00010100
        BYTE %00010100,%00000000,%00010100
        BYTE %01010100,%00000000,%01010100
        BYTE %01010100,%00000000,%01010100

        ORG SPRITE_DATA+16*64   ; 144: hit, facing right: top
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00001111,%11000000,%00000000
        BYTE %00111111,%11110000,%00000000
        BYTE %00111111,%01010100,%00000000
        BYTE %00001101,%01011101,%00000000
        BYTE %00000001,%01010100,%00000000
        BYTE %00000000,%01010000,%00000000
        BYTE %00001010,%10101010,%00000000
        BYTE %00011010,%10101010,%10000000
        BYTE %01011010,%10101010,%10010100
        BYTE %01000010,%10101010,%10000101
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000000,%10101010,%10000000

        ORG SPRITE_DATA+17*64   ; 145: hit, facing right: bottom
        BYTE %00000000,%10101010,%10000000
        BYTE %00000000,%10101010,%10000000
        BYTE %00000000,%10101010,%10000000
        BYTE %00000000,%11111111,%11000000
        BYTE %00000000,%11111011,%10000000
        BYTE %00000010,%10101010,%10100000
        BYTE %00000010,%10101010,%10101000
        BYTE %00000010,%10100000,%10101000
        BYTE %00000010,%10100000,%10101000
        BYTE %00001010,%10000000,%00101000
        BYTE %00001010,%10000000,%00101000
        BYTE %00001010,%00000000,%00101000
        BYTE %00001010,%00000000,%00101000
        BYTE %00001010,%00000000,%00101000
        BYTE %00101000,%00000000,%00101000
        BYTE %00101000,%00000000,%00101000
        BYTE %00101000,%00000000,%00101000
        BYTE %00010100,%00000000,%00010100
        BYTE %00010100,%00000000,%00010100
        BYTE %01010100,%00000000,%01010100
        BYTE %01010100,%00000000,%01010100

        ORG SPRITE_DATA+18*64   ; 146: win, facing right: top
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00010000,%11111100,%00010000
        BYTE %00010011,%11111111,%00010000
        BYTE %00010111,%11010101,%01010000
        BYTE %00001011,%01010111,%10000000
        BYTE %00001010,%01010101,%10100000
        BYTE %00000010,%10010110,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000

        ORG SPRITE_DATA+19*64   ; 147: win, facing right: bottom
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000011,%11111111,%00000000
        BYTE %00000011,%11101110,%00000000
        BYTE %00001010,%10101010,%10000000
        BYTE %00001010,%10101010,%10100000
        BYTE %00001010,%10000010,%10100000
        BYTE %00001010,%10000010,%10100000
        BYTE %00001010,%10000010,%10100000
        BYTE %00001010,%10000010,%10100000
        BYTE %00001010,%00000000,%10100000
        BYTE %00001010,%00000000,%10100000
        BYTE %00001010,%00000000,%10100000
        BYTE %00001010,%00000000,%10100000
        BYTE %00001010,%00000000,%10100000
        BYTE %00001010,%00000000,%10100000
        BYTE %00001010,%00000000,%10100000
        BYTE %00000101,%00000000,%01010000
        BYTE %00000101,%00000000,%01010000
        BYTE %00010101,%00000000,%01010100
        BYTE %00010101,%00000000,%01010100

        ORG SUN_SHAPE*64        ; 168: the setting sun, one colour, stretched
        BYTE %00000000,%01111110,%00000000
        BYTE %00000001,%11111111,%10000000
        BYTE %00000111,%11111111,%11100000
        BYTE %00001111,%11111111,%11110000
        BYTE %00001111,%11111111,%11110000
        BYTE %00011111,%11111111,%11111000
        BYTE %00011111,%11111111,%11111000
        BYTE %00111111,%11111111,%11111100
        BYTE %00111111,%11111111,%11111100
        BYTE %00111111,%11111111,%11111100
        BYTE %00111111,%11111111,%11111100
        BYTE %00111111,%11111111,%11111100
        BYTE %00111111,%11111111,%11111100
        BYTE %00011111,%11111111,%11111000
        BYTE %00011111,%11111111,%11111000
        BYTE %00001111,%11111111,%11110000
        BYTE %00001111,%11111111,%11110000
        BYTE %00000111,%11111111,%11100000
        BYTE %00000001,%11111111,%10000000
        BYTE %00000000,%01111110,%00000000

        ORG CHARSET+64*8
        BYTE %11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111 ; solid
        BYTE %00000001,%00000011,%00000111,%00001111,%00011111,%00111111,%01111111,%11111111 ; slope_up
        BYTE %10000000,%11000000,%11100000,%11110000,%11111000,%11111100,%11111110,%11111111 ; slope_down
        BYTE %00011000,%00111100,%00111100,%01111110,%01111110,%11111111,%11111111,%11111111 ; peak
        BYTE %10001000,%00000000,%10101010,%00010001,%10101010,%01010101,%10101010,%01010101 ; fade_in
        BYTE %10101010,%00000000,%00100010,%00000000,%10001000,%00000000,%00000000,%00000000 ; fade_out
        BYTE %00000000,%01110000,%00000000,%00000000,%00000000,%00000000,%00001110,%00000000 ; ripple
        BYTE %11111111,%10111111,%11111111,%11111111,%11111111,%11111101,%11111111,%00000000 ; slab
        BYTE %11111110,%11111110,%11101110,%11111110,%11111110,%11111110,%10111110,%00000000 ; slab_end
        BYTE %00000000,%00000000,%00000001,%00000111,%00011111,%01111111,%11111111,%00011111 ; roof_l
        BYTE %00000000,%00000000,%10000000,%11100000,%11111000,%11111110,%11111111,%11111000 ; roof_r
        BYTE %01100110,%01100110,%01100110,%01100110,%01100110,%01100110,%01100110,%01100110 ; pillar
        BYTE %00111100,%01111110,%11111111,%11111111,%11111111,%11111111,%01111110,%00111100 ; point
        BYTE %00111100,%01000010,%10000001,%10000001,%10000001,%10000001,%01000010,%00111100 ; nopoint
        BYTE %00000000,%01111111,%00000000,%00001111,%00000000,%00111111,%00000000,%00000111 ; glint_l
        BYTE %00000000,%11111110,%00000000,%11110000,%00000000,%11111100,%00000000,%11100000 ; glint_r
