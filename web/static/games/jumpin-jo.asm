; ===========================================================================
;                              JUMPIN' JO
; ===========================================================================
; Run, jump, stomp bugs and bash blocks across a smoothly scrolling world, in
; the style of the great platform games of 1985-87. Written in 6502 assembly
; for the Commodore 64; everything is in this one file.
;
; HOW TO PLAY
;   Joystick in port 2 (on this page: arrow keys, and Space for fire).
;   Left and right run. Up or fire jumps - hold it to jump higher.
;   Land on a bug to squash it; walk into one and you lose a life.
;   Jump up into a ? block for a gem, or into bricks to break them.
;   100 gems give you an extra life. Reach the flag to finish the level.
;
; WHAT TO LOOK FOR
;   - Smooth scrolling: bits 0-2 of $D016 slide the screen 0-7 pixels, and
;     every 8 pixels the whole picture is copied one character to the left
;     (SHIFT_SCREEN, an unrolled loop that races the beam in the border).
;   - A raster split: two interrupts a frame. The status line at the top
;     stays still on black; the level below it scrolls, in multicolour.
;   - The level is a map of 16 x 16 tiles in RAM, built from the text in
;     LEVELS; each tile is four multicolour characters.
;   - Fixed-point physics: speeds and heights in 1/256ths of a pixel make
;     the jumps rise and fall smoothly (see MOVE_JO).
;   - A two-voice music player in the interrupt, with sound effects on the
;     third voice.
;
; MEMORY MAP
;   $0400-$07FF  screen
;   $0810-       the program
;   $2800-$2B3F  sprite shapes (pointers 160-172)
;   $3800-$39FF  letters and digits, copied from the character ROM
;   $3A00-$3B3F  tiles: 10 tiles x 4 multicolour characters (codes 64-103)
;   $4000-$44FF  the level map: 10 rows of 128 tiles
;   $C000-$C0FF  tables
;
; THINGS TO TRY
;   - Build your own level: edit the text in LEVELS.
;   - Jump higher: make JUMP_SPEED more negative, e.g. $FA00 (-6.0).
;   - Lower gravity: make GRAVITY smaller.
;   - Write your own tune: change the notes in MELODY and BASS.
; ===========================================================================

; ---------------------------------------------------------------------------
; Settings
; ---------------------------------------------------------------------------
START_LIVES  = 3
RUN_SPEED    = 2            ; pixels per frame (keep it even)
JUMP_SPEED   = $FB00        ; -5.0 pixels per frame, in 8.8 fixed point
GRAVITY      = $0040        ; +0.25 pixels per frame, every frame
FAST_FALL    = $00C0        ; extra gravity when jump is let go early
MAX_FALL     = $06          ; whole pixels per frame
BOUNCE_SPEED = $FC80        ; after stomping a bug
NUM_LEVELS   = 2

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
MULTI       = 8             ; add to a colour in colour RAM: multicolour cell

; ---------------------------------------------------------------------------
; The level
; ---------------------------------------------------------------------------
LEVEL_MAP   = $4000         ; 10 rows of 128 tiles, one byte each
MAP_W       = 128
MAP_H       = 10
FIELD_ROW   = 5             ; screen row of the top of the level
FIELD_Y     = 90            ; ...and its sprite Y (50 + 8 x 5)
FIELD_END   = 250           ; sprite Y of the bottom of the screen
MAX_CAM     = 216           ; the last character column the camera reaches

TILE_SKY    = 0             ; each tile is 4 characters, from 64 + 4 x tile:
TILE_GRASS  = 1             ;   top left, top right, bottom left, bottom right
TILE_GROUND = 2
TILE_BRICK  = 3
TILE_BONUS  = 4
TILE_USED   = 5
TILE_GEM    = 6
TILE_HARD   = 7
TILE_POLE   = 8
TILE_FLAG   = 9
TILE_CHARS  = 64

; ---------------------------------------------------------------------------
; Sprites
; ---------------------------------------------------------------------------
S_JO        = 0
S_BUG       = 1             ; bugs use sprites 1-4
MAX_BUGS    = 4
S_GEM       = 5             ; a gem popping out of a block
SPRITE_DATA = $2800         ; sprite shapes: shape number = address / 64
P_STAND     = SPRITE_DATA/64 ; 160, facing right; add 4 for facing left
P_RUN1      = P_STAND+1
P_RUN2      = P_STAND+2
P_JUMP      = P_STAND+3
P_HURT      = P_STAND+8
P_BUG1      = P_STAND+9
P_BUG2      = P_STAND+10
P_SQUASHED  = P_STAND+11
P_GEM       = P_STAND+12

; ---------------------------------------------------------------------------
; Zero page
; ---------------------------------------------------------------------------
frame_count = $02
joy         = $03
fire_armed  = $04
jump_armed  = $05           ; jump was let go since the last jump
ptr         = $06           ; $06-$07
cptr        = $08           ; $08-$09
mptr        = $0A           ; $0A-$0B: a row of the level map
tmp         = $0C
tmp2        = $0D
tmp3        = $0E
counter     = $0F
t_x         = $10           ; $10-$11: world X to look at in the map
px          = $12           ; $12-$13: Jo's world X (left edge of the sprite)
py          = $14           ; Jo's sprite Y...
py_frac     = $15           ; ...and 1/256ths of a pixel
vy_lo       = $16           ; Jo's vertical speed, 8.8 fixed point
vy_hi       = $17
on_ground   = $18
facing      = $19           ; 0 right, 4 left (added to the shape)
anim        = $1A
jo_state    = $1B           ; 0 playing, 1 hurt, 2 reached the flag
state_timer = $1C
cam_char    = $1D           ; leftmost character column on screen
xscroll     = $1E           ; fine scroll the interrupt puts in $D016
xscroll_next = $1F          ; fine scroll for the next frame
shift_due   = $20           ; the screen must move a character left
column_due  = $21           ; a new column must be drawn on the right
cam_x       = $22           ; $22-$23: world X of the screen's left edge
score       = $24           ; $24-$26, BCD
gems        = $27           ; BCD
lives       = $28
level       = $29
checkpoint  = $2A           ; tile column to restart from
top_d016    = $2B           ; what the upper interrupt sets
top_d021    = $2C
src         = $2D           ; $2D-$2E
music_on    = $2F
sfx_start   = $30           ; sound effects: one byte per voice
sfx_time    = $33
sfx_wave    = $36
sfx_ad      = $39
sfx_sr      = $3C
sfx_flo     = $3F
sfx_fhi     = $42
sfx_dlo     = $45
sfx_dhi     = $48
mus_wait    = $4B           ; music: frames to the next note, two voices
mus_pos     = $4D           ; position in each voice's list
mus_note    = $4F
sid_off     = $50
mptr2       = $51           ; $51-$52
spawn_count = $53
flag_col    = $54           ; tile column of the goal
gem_timer   = $55           ; the popping gem
gem_y       = $56
gem_x       = $57           ; $57-$58: world X
hiscore     = $59           ; $59-$5B
level_ptr   = $5C           ; $5C-$5D: the current level's text
bug_index   = $5E
squashed    = $5F           ; bugs landed on this frame

; Tables in free RAM
ROW_LO      = $C000         ; screen row addresses
ROW_HI      = $C020
SPR_XLO     = $C040         ; sprite positions, copied to the VIC-II each frame
SPR_XHI     = $C048
SPR_Y       = $C050
SPR_PTR     = $C058
SPR_ON      = $C060         ; one byte: which sprites are visible
BUG_ON      = $C068         ; the bugs: 1 = walking, 2 = squashed
BUG_XLO     = $C070         ; world X
BUG_XHI     = $C078
BUG_Y       = $C080
BUG_DIR     = $C088         ; 1 right, $FF left
BUG_TIMER   = $C090
SPAWN_COL   = $C0A0         ; where bugs wait to appear: up to 32
SPAWN_ROW   = $C0C0
SPAWN_USED  = $C0E0

; ===========================================================================
; START
; ===========================================================================
        ORG $0810           ; SYS 2064

start:
        SEI
        CLD
        LDA #$7F
        STA $DC0D           ; no CIA timer interrupts
        LDA $DC0D
        LDA #$FF
        STA JOYSTICK        ; no keyboard row selected: $DC00 is the joystick
        JSR make_row_table
        JSR copy_font
        JSR init_sound
        LDA #BLACK
        STA VIC+$20
        STA VIC+$21
        LDA #$1E            ; screen at $0400, characters at $3800
        STA VIC+$18
        LDA #%00111111      ; sprites 0-5 are multicolour
        STA VIC+$1C
        LDA #LIGHT_RED      ; skin
        STA VIC+$25
        LDA #BLACK          ; outlines
        STA VIC+$26
        LDA #0
        STA VIC+$17
        STA VIC+$1D
        STA VIC+$1B         ; sprites in front of the scenery
        STA SPR_ON
        STA hiscore
        STA hiscore+1
        STA hiscore+2
        STA score
        STA score+1
        STA score+2
        STA xscroll
        LDA #%00011000      ; multicolour, 40 columns
        STA top_d016
        LDA #BLACK
        STA top_d021

        LDA #<irq_bottom    ; two raster interrupts take turns
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
        CLI

main_loop:
        JSR title_screen
        JSR play_game
        JMP main_loop

; ===========================================================================
; THE RASTER SPLIT
; IRQ_TOP runs at line 67, where the level begins: from here down the
; screen is sky coloured and scrolled. IRQ_BOTTOM runs at line 251, below
; the level: the status line at the top of the next frame is black and
; still. Each one points the interrupt vector at the other.
; ===========================================================================
irq_top:
        CLD                 ; the 6502 keeps decimal mode for an interrupt
        LDA #1
        STA VIC+$19
        LDA xscroll
        ORA top_d016
        STA VIC+$16
        LDA top_d021
        STA VIC+$21
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
        LDA #BLACK
        STA VIC+$21
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

; Copy the sprite tables to the VIC-II, gathering bit 8 of each X into $D010.
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
        LDA SPR_ON
        STA VIC+$15
        RTS

; ===========================================================================
; THE TITLE SCREEN
; ===========================================================================
title_screen:
        JSR clear_screen
        LDA #START_LIVES    ; what a new game starts with
        STA lives
        LDA #0
        STA fire_armed
        STA xscroll
        STA SPR_ON
        STA gems            ; the status line shows a new game's start
        STA level
        LDA #%00011000      ; 40 columns on a black background
        STA top_d016
        LDA #BLACK
        STA top_d021
        LDA #<title_text
        LDX #>title_text
        JSR print_list
        JSR show_status
        LDX #hiscore+2      ; the high score on row 1
        LDY #40+21
        LDA #3
        JSR print_bcd
        LDA #24+19*8        ; Jo and a bug, as sprites
        STA SPR_XLO+S_JO
        LDA #50+6*8
        STA SPR_Y+S_JO
        LDA #24+3*8
        STA SPR_XLO+S_BUG
        LDA #50+14*8-12
        STA SPR_Y+S_BUG
        LDA #P_BUG1
        STA SPR_PTR+S_BUG
        LDA #0
        STA SPR_XHI+S_JO
        STA SPR_XHI+S_BUG
        LDA #%00000011
        STA SPR_ON
        JSR start_music
ts_loop:
        JSR wait_frame
        JSR update_sprites
        LDA frame_count     ; Jo runs on the spot, the bug waddles
        LSR
        LSR
        LSR
        AND #1
        CLC
        ADC #P_RUN1
        STA SPR_PTR+S_JO
        LDA frame_count
        LSR
        LSR
        LSR
        LSR
        AND #1
        CLC
        ADC #P_BUG1
        STA SPR_PTR+S_BUG
        JSR fire_pressed
        BCC ts_loop
        RTS

; ===========================================================================
; THE GAME
; ===========================================================================
play_game:
        LDA #0
        STA score
        STA score+1
        STA score+2
        STA gems
        STA level
        LDA #START_LIVES
        STA lives
pg_level:
        JSR start_level
        LDA #0
        STA checkpoint
pg_life:
        JSR restart

; One pass per frame. The screen is scrolled first, starting in the border
; and done before the beam reaches the level; then everything moves and
; the camera follows Jo.
pg_loop:
        JSR wait_frame
        JSR apply_scroll
        JSR update_sprites
        JSR read_joystick
        JSR move_jo
        JSR move_bugs
        JSR hit_bugs
        JSR move_gem
        JSR follow_camera
        JSR new_column
        JSR place_sprites
        LDA jo_state
        BEQ pg_loop
        DEC state_timer     ; hurt, or at the flag: wait, then carry on
        BNE pg_loop
        LDA jo_state
        CMP #2
        BEQ pg_next_level
        DEC lives
        BEQ pg_over
        JMP pg_life
pg_next_level:
        INC level
        LDA level
        CMP #NUM_LEVELS
        BCC pg_level
        LDA #0              ; after the last level, start again
        STA level
        JMP pg_level
pg_over:
        LDA #0
        STA SPR_ON
        STA music_on
        JSR silence_music
        JSR clear_field
        JSR show_status     ; LIVES 0
        LDA #<over_text
        LDX #>over_text
        JSR print
        JSR update_hiscore
        LDA #150
        JMP wait_frames

; Build the level's map from its text, and show its name.
start_level:
        LDA #0
        STA SPR_ON
        STA music_on
        STA xscroll         ; the last level ended scrolled
        JSR update_sprites  ; hide them now: decoding the map takes frames
        JSR silence_music
        JSR clear_screen
        JSR show_status
        LDA #%00011000
        STA top_d016
        LDA #BLACK
        STA top_d021
        LDA level
        ASL
        TAX
        LDA level_list,X
        STA src
        LDA level_list+1,X
        STA src+1
        LDY #0              ; the header: five colours...
sl_colors:
        LDA (src),Y
        STA level_colors,Y
        INY
        CPY #5
        BNE sl_colors
        LDA src
        CLC
        ADC #5
        STA src
        BCC sl_name
        INC src+1
sl_name:
        LDY #0              ; ...then the name, for the "get ready" screen
sl_name_copy:
        LDA (src),Y
        STA ready_name+3,Y
        BEQ sl_name_done
        INY
        BNE sl_name_copy
sl_name_done:
        STY tmp             ; centred: column (40 - its length) / 2
        LDA #40
        SEC
        SBC tmp
        LSR
        STA ready_name+1
        INY
        TYA
        CLC
        ADC src
        STA src
        BCC sl_map
        INC src+1
sl_map:
        JSR decode_map      ; (before PRINT, which also uses src)
        LDA level
        CLC
        ADC #'1'
        STA ready_text+9
        LDA #<ready_text
        LDX #>ready_text
        JSR print
        LDA #<ready_name
        LDX #>ready_name
        JSR print
        LDA #100
        JSR wait_frames
        RTS

; The map text comes in 4 strips of 32 columns, each 10 rows deep. Each
; character becomes a tile; E marks where a bug waits and P where Jo starts.
decode_map:
        LDA #0
        STA check_col       ; no checkpoint, and no flag, until the text has one
        STA spawn_count
        STA counter         ; strip
        LDA #255
        STA flag_col
dm_strip:
        LDA #0
        STA tmp3            ; row
dm_row:
        LDX tmp3
        LDA map_row_lo,X
        STA mptr
        LDA map_row_hi,X
        STA mptr+1
        LDA counter         ; this strip's first column: 32 x strip
        ASL
        ASL
        ASL
        ASL
        ASL
        STA tmp2
        CLC
        ADC mptr
        STA mptr
        LDY #0
dm_col:
        LDA (src),Y
        JSR decode_tile
        STA (mptr),Y
        INY
        CPY #32
        BNE dm_col
        LDA src
        CLC
        ADC #32
        STA src
        BCC dm_next_row
        INC src+1
dm_next_row:
        INC tmp3
        LDA tmp3
        CMP #MAP_H
        BNE dm_row
        INC counter
        LDA counter
        CMP #4
        BNE dm_strip
        ; ground under ground is earth, not grass: one pass from the top
        LDX #1
dm_grass_row:
        LDA map_row_lo,X
        STA mptr
        LDA map_row_hi,X
        STA mptr+1
        LDA map_row_lo-1,X
        STA ptr
        LDA map_row_hi-1,X
        STA ptr+1
        LDY #MAP_W-1
dm_grass:
        LDA (mptr),Y
        CMP #TILE_GRASS
        BNE dm_grass_next
        LDA (ptr),Y         ; the tile above
        CMP #TILE_GRASS
        BEQ dm_earth
        CMP #TILE_GROUND
        BNE dm_grass_next
dm_earth:
        LDA #TILE_GROUND
        STA (mptr),Y
dm_grass_next:
        DEY
        BPL dm_grass
        INX
        CPX #MAP_H
        BNE dm_grass_row
        RTS

; A = a character of the map text; returns its tile. tmp2 + Y is the
; column and tmp3 the row.
decode_tile:
        LDX #0
dt_find:
        CMP tile_letters,X
        BEQ dt_found
        INX
        CPX #10
        BNE dt_find
        LDA #TILE_SKY       ; anything else is sky
        RTS
dt_found:
        CPX #7              ; E: a bug waits here
        BEQ dt_bug
        CPX #8              ; P: Jo starts here
        BEQ dt_jo
        CPX #9              ; C: the checkpoint
        BEQ dt_check
        LDA tile_codes,X
        CMP #TILE_FLAG
        BNE dt_done
        TYA
        CLC
        ADC tmp2
        STA flag_col
        LDA #TILE_FLAG
dt_done:
        RTS
dt_bug:
        LDX spawn_count
        CPX #32
        BCS dt_sky
        TYA
        CLC
        ADC tmp2
        STA SPAWN_COL,X
        LDA tmp3
        STA SPAWN_ROW,X
        INC spawn_count
dt_sky:
        LDA #TILE_SKY
        RTS
dt_jo:
        TYA
        CLC
        ADC tmp2
        STA start_col
        LDA tmp3
        STA start_row
        LDA #TILE_SKY
        RTS
dt_check:
        TYA
        CLC
        ADC tmp2
        STA check_col
        LDA tmp3
        STA check_row
        LDA #TILE_SKY
        RTS

; Start (or restart) at the checkpoint: camera, screen, Jo and the bugs.
restart:
        LDA #0
        STA SPR_ON
        STA jo_state
        STA vy_lo
        STA vy_hi
        STA on_ground
        STA facing
        STA shift_due
        STA column_due
        STA gem_timer
        STA xscroll
        STA xscroll_next
        LDX #MAX_BUGS-1
rs_bugs:
        STA BUG_ON,X
        DEX
        BPL rs_bugs
        LDX #31
rs_spawns:
        STA SPAWN_USED,X
        DEX
        BPL rs_spawns
        JSR update_sprites  ; no bugs left over while the level is redrawn
        LDA start_row       ; the start, or the checkpoint: its tile row...
        LDX checkpoint
        BEQ rs_row
        LDA check_row
rs_row:
        STA tmp2
        LDA start_col       ; ...and column
        CPX #0
        BEQ rs_column
        LDA check_col
rs_column:
        STA tmp             ; Jo's tile column
        ASL                 ; camera: 4 characters to the left of Jo,
        SEC                 ; but not before the start of the map
        SBC #4
        BCS rs_cam
        LDA #0
rs_cam:
        CMP #MAX_CAM
        BCC rs_cam_ok
        LDA #MAX_CAM
rs_cam_ok:
        STA cam_char
        ASL                 ; cam_x = cam_char x 8
        STA cam_x
        LDA #0
        ROL
        STA cam_x+1
        ASL cam_x
        ROL cam_x+1
        ASL cam_x
        ROL cam_x+1
        LDA tmp             ; Jo: X = column x 16, his feet at the bottom of the row
        STA px
        LDA #0
        STA px+1
        LDX #4
rs_jo_x:
        ASL px
        ROL px+1
        DEX
        BNE rs_jo_x
        LDA tmp2            ; Y = FIELD_Y + 16 x (row + 1) - 21
        ASL
        ASL
        ASL
        ASL
        CLC
        ADC #FIELD_Y+16-21
        STA py
        LDA #0
        STA py_frac
        JSR color_field
        JSR show_status
        JSR draw_screen
        LDA level_colors+1  ; the level's multicolours
        STA VIC+$22
        LDA level_colors+2
        STA VIC+$23
        LDA level_colors+3  ; a gem popping out of a block takes the colour
        AND #7              ; of the gems in the map (less MULTI)
        STA VIC+$27+S_GEM
        LDA level_colors
        STA top_d021
        LDA #%00010000      ; multicolour, 38 columns for scrolling
        STA top_d016
        LDA #1
        STA SPR_ON
        JSR place_sprites
        JMP start_music

; ===========================================================================
; SCROLLING
; The camera only moves right, RUN_SPEED pixels a frame. Each time it does,
; xscroll counts down by as much (6, 4, 2, 0 for a speed of 2); below 0 it
; wraps round by adding 8, and the whole level on screen is moved one
; character left, with a new column drawn on the right.
; ===========================================================================
; At the very start of a frame, in the border: set the fine scroll IRQ_TOP
; will put in $D016 at line 67, then move the characters if the camera
; crossed a character boundary. The move ends close to line 67, so the fine
; scroll has to be ready first; the level itself starts at line 91.
apply_scroll:
        LDA xscroll_next
        STA xscroll
        LDA shift_due
        BEQ as_done
        JSR shift_screen
        INC cam_char
        LDA #0
        STA shift_due
        LDA #1
        STA column_due
as_done:
        RTS

; Move rows 5-24 one character to the left. The loop body copies the same
; column of all 20 rows, which saves the loop's own instructions 20 times
; over: about 7300 cycles, done before the beam reaches row 5.
shift_screen:
        LDX #0
ss_loop:
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
        BNE ss_loop
        RTS

; Keep Jo in the left half of the screen: once past the middle, the camera
; moves with him (until the end of the level).
follow_camera:
        LDA jo_state
        BNE fc_done
        LDA px              ; Jo's distance from the left edge of the screen
        SEC
        SBC cam_x
        STA tmp
        LDA px+1
        SBC cam_x+1
        BNE fc_move
        LDA tmp
        CMP #136
        BCC fc_done
fc_move:
        LDA cam_char
        CMP #MAX_CAM
        BCS fc_done
        LDA cam_x
        CLC
        ADC #RUN_SPEED
        STA cam_x
        BCC fc_fine
        INC cam_x+1
fc_fine:
        LDA xscroll
        SEC
        SBC #RUN_SPEED
        BCS fc_set
        ADC #8              ; below 0: wrap round, and move the characters
        LDX #1
        STX shift_due
fc_set:
        STA xscroll_next
fc_done:
        RTS

; Draw the column that has just appeared on the right, and wake any bug
; waiting there.
new_column:
        LDA column_due
        BEQ nc_done
        LDA #0
        STA column_due
        LDA cam_char
        CLC
        ADC #39
        PHA
        LDY #39
        JSR draw_column
        PLA
        LSR
        JMP wake_bugs
nc_done:
        RTS

; Draw the whole screen from the map.
draw_screen:
        LDA #0
        STA counter
ds_col:
        LDA cam_char
        CLC
        ADC counter
        LDY counter
        JSR draw_column
        LDA cam_char
        CLC
        ADC counter
        LSR
        JSR wake_bugs
        INC counter
        LDA counter
        CMP #40
        BNE ds_col
        RTS

; Draw world character column A of the map into screen column Y. Each tile
; is 2 characters wide, so the column is the left or right half of a tile.
draw_column:
        STY tmp             ; screen column
        LSR                 ; tile column, with the half in the carry
        STA tmp2
        LDA #TILE_CHARS
        ADC #0              ; the left or right character
        STA tmp3
        LDX #0              ; tile row
dc_row:
        LDA map_row_lo,X
        STA mptr
        LDA map_row_hi,X
        STA mptr+1
        LDY tmp2
        LDA (mptr),Y        ; the tile
        ASL
        ASL                 ; x 4 characters per tile
        CLC
        ADC tmp3
        STA counter_save
        LDA field_lo,X      ; the screen row of this row of tiles
        STA ptr
        LDA field_hi,X
        STA ptr+1
        LDY tmp
        LDA counter_save
        STA (ptr),Y         ; top half of the tile
        TYA
        CLC
        ADC #40
        TAY
        LDA counter_save
        CLC
        ADC #2              ; the bottom half is 2 characters on
        STA (ptr),Y
        INX
        CPX #MAP_H
        BNE dc_row
        RTS

; Redraw the tile in tile column A, if it is on screen: both its character
; columns. DRAW_COLUMN uses tmp, tmp2 and tmp3, so each column number waits
; on the stack.
redraw_tile:
        ASL                 ; its left character column
        PHA
        JSR rt_draw
        PLA
        CLC
        ADC #1              ; and its right one
rt_draw:                    ; draw character column A, if it is on screen
        PHA
        SEC
        SBC cam_char
        BCC rt_off          ; off the left edge
        CMP #40
        BCS rt_off          ; off the right edge
        TAY
        PLA
        JMP draw_column
rt_off:
        PLA
        RTS

; Colour memory: the status line hires white, then the level's colours.
color_field:
        LDX #79
cf_status:
        LDA #WHITE
        STA COLORS,X
        DEX
        BPL cf_status
        LDA level_colors+3  ; upper rows
        LDX #0
cf_upper:
        STA COLORS+80,X
        STA COLORS+80+256,X
        STA COLORS+80+512,X
        INX
        BNE cf_upper
        LDA level_colors+4  ; the bottom two rows of tiles
        LDX #160
cf_lower:
        STA COLORS+839,X
        DEX
        BNE cf_lower
        RTS

; ===========================================================================
; THE MAP
; ===========================================================================
; The tile at world X t_x and sprite Y A. Above the map is sky; beyond its
; ends is a wall.
tile_at:
        LDX t_x+1
        CPX #MAP_W/16       ; 2048 pixels or more (or below 0)
        BCS ta_wall
        SEC
        SBC #FIELD_Y
        BCC ta_sky
        CMP #MAP_H*16
        BCS ta_sky
        LSR
        LSR
        LSR
        LSR                 ; 16 pixels to a tile
        TAX
        LDA map_row_lo,X
        STA mptr
        LDA map_row_hi,X
        STA mptr+1
        LDA t_x+1           ; tile column = X / 16
        ASL
        ASL
        ASL
        ASL
        STA tmp
        LDA t_x
        LSR
        LSR
        LSR
        LSR
        ORA tmp
        TAY
        LDA (mptr),Y
        RTS
ta_sky:
        LDA #TILE_SKY
        RTS
ta_wall:
        LDA #TILE_HARD
        RTS

; The tile at Jo's X + X and Y + A. Carry set if it is solid.
probe:
        CLC
        ADC py
        PHA
        TXA
        CLC
        ADC px
        STA t_x
        LDA px+1
        ADC #0
        STA t_x+1
        PLA
        JSR tile_at
is_solid:                   ; carry set if tile A is solid (A is kept)
        TAX
        LDA solid,X
        CMP #1
        TXA
        RTS

; ===========================================================================
; JO
; ===========================================================================
move_jo:
        LDA jo_state
        BEQ mj_play
        CMP #1
        BNE mj_done
        JMP hurt_fall
mj_done:
        RTS
mj_play:
        LDA #0
        STA counter         ; set to 1 if Jo runs this frame
        LDA joy
        AND #JOY_LEFT
        BEQ mj_right
        LDA #4
        STA facing          ; facing left: the shapes 4 further on
        LDA px              ; not off the left edge of the screen
        SEC
        SBC cam_x
        TAX
        LDA px+1
        SBC cam_x+1
        BNE mj_left_free
        CPX #RUN_SPEED
        BCC mj_vertical
mj_left_free:
        LDX #6-RUN_SPEED    ; is the way clear? look where Jo's left edge will be
        JSR side_clear
        BCS mj_vertical
        LDA px
        SEC
        SBC #RUN_SPEED
        STA px
        BCS mj_ran
        DEC px+1
        JMP mj_ran
mj_right:
        LDA joy
        AND #JOY_RIGHT
        BEQ mj_vertical
        LDA #0
        STA facing
        LDX #17+RUN_SPEED   ; Jo's right edge, one step on
        JSR side_clear
        BCS mj_vertical
        LDA px
        CLC
        ADC #RUN_SPEED
        STA px
        BCC mj_ran
        INC px+1
mj_ran:
        INC counter

mj_vertical:
        LDA joy
        AND #JOY_UP+JOY_FIRE
        BNE mj_held
        LDA #1
        STA jump_armed      ; let go: the next press may jump
mj_held:
        LDA on_ground
        BEQ mj_air
        LDA joy             ; on the ground: jump?
        AND #JOY_UP+JOY_FIRE
        BEQ mj_floor
        LDA jump_armed
        BEQ mj_floor
        LDA #0
        STA jump_armed
        STA on_ground
        LDA #<JUMP_SPEED
        STA vy_lo
        LDA #>JUMP_SPEED
        STA vy_hi
        LDA #SFX_JUMP
        LDX #2
        JSR sfx_play
        JMP mj_air
mj_floor:
        LDX #7              ; still something under Jo's feet?
        LDA #21
        JSR probe
        BCS mj_on_floor
        LDX #16
        LDA #21
        JSR probe
        BCS mj_on_floor
        LDA #0              ; ran off a ledge
        STA on_ground
        STA vy_lo
        STA vy_hi
        JMP mj_air
mj_on_floor:
        JMP mj_shape

mj_air:
        LDA vy_lo           ; gravity pulls: speed += GRAVITY
        CLC
        ADC #<GRAVITY
        STA vy_lo
        LDA vy_hi
        ADC #>GRAVITY
        STA vy_hi
        BPL mj_cap
        LDA joy             ; rising with jump let go: fall back sooner
        AND #JOY_UP+JOY_FIRE
        BNE mj_move_y
        LDA vy_lo
        CLC
        ADC #<FAST_FALL
        STA vy_lo
        LDA vy_hi
        ADC #>FAST_FALL
        STA vy_hi
        JMP mj_move_y
mj_cap:
        CMP #MAX_FALL       ; falling no faster than MAX_FALL
        BCC mj_move_y
        LDA #MAX_FALL
        STA vy_hi
        LDA #0
        STA vy_lo
mj_move_y:
        LDA py_frac         ; position += speed, both 8.8 fixed point
        CLC
        ADC vy_lo
        STA py_frac
        LDA py
        ADC vy_hi
        STA py
        LDA vy_hi
        BMI mj_rising
        LDX #7              ; falling: has Jo landed on something?
        LDA #21
        JSR probe
        BCS mj_land
        LDX #16
        LDA #21
        JSR probe
        BCS mj_land
        LDA py
        CMP #FIELD_END-16
        BCC mj_shape
        JMP jo_hurt         ; down a hole
mj_land:
        LDA py              ; stand on top of that tile: its top is
        CLC                 ; FIELD_Y + 16 x row
        ADC #21-FIELD_Y
        AND #%11110000
        CLC
        ADC #FIELD_Y-21
        STA py
        LDA #0
        STA py_frac
        STA vy_lo
        STA vy_hi
        LDA #1
        STA on_ground
        JMP mj_shape
mj_rising:
        LDX #12             ; head first into something? the middle first
        LDA #1
        JSR probe
        BCS mj_bump
        LDX #7
        LDA #1
        JSR probe
        BCS mj_bump
        LDX #16
        LDA #1
        JSR probe
        BCC mj_shape
mj_bump:
        STA tmp3            ; the tile that was hit
        LDA t_x+1           ; its column
        ASL
        ASL
        ASL
        ASL
        STA tmp
        LDA t_x
        LSR
        LSR
        LSR
        LSR
        ORA tmp
        STA hit_col
        LDA py
        CLC
        ADC #1-FIELD_Y
        LSR
        LSR
        LSR
        LSR
        STA hit_row
        LDA #0              ; Jo stops just under the tile and starts to fall
        STA vy_lo
        STA vy_hi
        STA py_frac
        LDA hit_row
        ASL
        ASL
        ASL
        ASL
        CLC
        ADC #FIELD_Y+15
        STA py
        LDA tmp3
        JSR hit_block

mj_shape:
        LDA on_ground       ; choose Jo's shape: jumping, running or standing
        BNE mj_ground_shape
        LDA #P_JUMP
        JMP mj_set_shape
mj_ground_shape:
        LDA counter
        BEQ mj_standing
        LDA frame_count
        LSR
        LSR
        AND #1
        CLC
        ADC #P_RUN1
        JMP mj_set_shape
mj_standing:
        LDA #P_STAND
mj_set_shape:
        CLC
        ADC facing
        STA SPR_PTR+S_JO
        JSR take_gems
        LDA px+1            ; past the checkpoint?
        ASL
        ASL
        ASL
        ASL
        STA tmp
        LDA px
        LSR
        LSR
        LSR
        LSR
        ORA tmp
        STA tmp             ; Jo's tile column
        LDA check_col
        BEQ mj_flag
        CMP tmp
        BCS mj_flag
        STA checkpoint
mj_flag:
        LDA tmp             ; at the flag?
        CMP flag_col
        BCC mj_end
        LDA #2
        STA jo_state
        LDA #150
        STA state_timer
        LDA #0
        STA music_on
        JSR silence_music
        LDA #$00
        LDX #$10
        JSR add_score       ; 1000 points for the flag
        LDA #SFX_FLAG
        LDX #2
        JSR sfx_play
mj_end:
        RTS

; Is the column of pixels X across from Jo clear from his head to his
; feet? Carry set if something solid is in the way.
side_clear:
        STX tmp3
        LDA #3
        JSR probe
        BCS sc_done
        LDX tmp3
        LDA #12
        JSR probe
        BCS sc_done
        LDX tmp3
        LDA #19
        JSR probe
sc_done:
        RTS

; Jo hit tile A from below, at hit_col / hit_row.
hit_block:
        CMP #TILE_BONUS
        BEQ hb_bonus
        CMP #TILE_BRICK
        BEQ hb_brick
        LDA #SFX_BUMP
        LDX #2
        JMP sfx_play
hb_brick:
        LDA #TILE_SKY       ; bricks break
        JSR set_hit_tile
        LDA #$50
        LDX #0
        JSR add_score
        LDA #SFX_BRICK
        LDX #2
        JMP sfx_play
hb_bonus:
        LDA #TILE_USED      ; a ? block gives a gem, once
        JSR set_hit_tile
        LDA hit_col         ; the gem pops out of the top
        STA gem_x
        LDA #0
        STA gem_x+1
        LDX #4
hb_gem_x:
        ASL gem_x
        ROL gem_x+1
        DEX
        BNE hb_gem_x
        LDA hit_row
        ASL
        ASL
        ASL
        ASL
        CLC
        ADC #FIELD_Y-16
        STA gem_y
        LDA #16
        STA gem_timer
        JMP got_gem

; Change the map at hit_col / hit_row to tile A, and on screen.
set_hit_tile:
        LDX hit_row
        PHA
        LDA map_row_lo,X
        STA mptr
        LDA map_row_hi,X
        STA mptr+1
        PLA
        LDY hit_col
        STA (mptr),Y
        LDA hit_col
        JMP redraw_tile

; Gems in the map are collected by touching them.
take_gems:
        LDX #12
        LDA #6
        JSR probe
        CMP #TILE_GEM
        BEQ tg_take
        LDX #12
        LDA #16
        JSR probe
        CMP #TILE_GEM
        BNE tg_done
tg_take:
        LDA #TILE_SKY       ; probe left mptr and Y at the gem's cell
        STA (mptr),Y
        TYA
        JSR redraw_tile
        JMP got_gem
tg_done:
        RTS

; One more gem: every 100 is an extra life.
got_gem:
        SED
        LDA gems
        CLC
        ADC #1
        STA gems
        CLD
        BCC gg_score        ; the carry says $99 became $00 (Z can't: in decimal
        INC lives           ; mode the 6502 sets Z from the binary sum, $9A)
        LDA #SFX_ONE_UP
        LDX #2
        JSR sfx_play
        JMP gg_points
gg_score:
        LDA #SFX_GEM
        LDX #2
        JSR sfx_play
gg_points:
        LDA #$50
        LDX #0
        JMP add_score

; The gem from a ? block floats up and vanishes.
move_gem:
        LDA gem_timer
        BEQ mg_done
        DEC gem_timer
        DEC gem_y
mg_done:
        RTS

; Ouch: Jo jumps up off the screen, and a life is lost.
jo_hurt:
        LDA #1
        STA jo_state
        LDA #120
        STA state_timer
        LDA #$FC
        STA vy_hi
        LDA #0
        STA vy_lo
        STA music_on
        JSR silence_music
        LDA #P_HURT
        STA SPR_PTR+S_JO
        LDA #SFX_HURT
        LDX #2
        JMP sfx_play

hurt_fall:
        LDA py
        CMP #FIELD_END
        BCS hf_done         ; gone: just wait for the timer
        LDA vy_lo
        CLC
        ADC #<GRAVITY
        STA vy_lo
        LDA vy_hi
        ADC #>GRAVITY
        STA vy_hi
        LDA py_frac
        CLC
        ADC vy_lo
        STA py_frac
        LDA py
        ADC vy_hi
        BIT vy_hi           ; rising, or still on the screen: that's where he is
        BMI hf_store
        BCC hf_store
        LDA #255            ; falling past the bottom: stay there, not at the top
hf_store:
        STA py
hf_done:
        RTS

; ===========================================================================
; BUGS
; ===========================================================================
; Tile column A has come into view: wake any bug waiting in it.
wake_bugs:
        STA tmp3
        LDX spawn_count
wb_spawn:
        DEX
        BMI wb_done
        LDA SPAWN_USED,X
        BNE wb_spawn
        LDA SPAWN_COL,X
        CMP tmp3
        BNE wb_spawn
        LDY #MAX_BUGS-1     ; a free bug sprite?
wb_slot:
        LDA BUG_ON,Y
        BEQ wb_wake
        DEY
        BPL wb_slot
        RTS
wb_wake:
        LDA #1
        STA SPAWN_USED,X
        STA BUG_ON,Y
        LDA #$FF
        STA BUG_DIR,Y       ; walking left, towards Jo
        LDA SPAWN_ROW,X     ; standing on the bottom of its tile
        ASL
        ASL
        ASL
        ASL
        CLC
        ADC #FIELD_Y-5
        STA BUG_Y,Y
        LDA SPAWN_COL,X     ; X = column x 16
        STA tmp
        LDA #0
        STA tmp2
        ASL tmp
        ROL tmp2
        ASL tmp
        ROL tmp2
        ASL tmp
        ROL tmp2
        ASL tmp
        ROL tmp2
        LDA tmp
        STA BUG_XLO,Y
        LDA tmp2
        STA BUG_XHI,Y
        JMP wb_spawn
wb_done:
        RTS

; Bugs walk slowly, turn at walls and fall off edges.
move_bugs:
        LDX #MAX_BUGS-1
mb_bug:
        STX bug_index
        LDA BUG_ON,X
        BNE mb_awake
        JMP mb_next
mb_awake:
        CMP #2
        BNE mb_walking
        DEC BUG_TIMER,X     ; squashed: show it flat for a moment
        BEQ mb_gone
        JMP mb_next
mb_gone:
        LDA #0
        STA BUG_ON,X
        JMP mb_next
mb_walking:
        LDA frame_count     ; a step every other frame
        AND #1
        BNE mb_fall
        LDA BUG_DIR,X       ; look at the next pixel ahead, at knee height
        BMI mb_look_left
        LDA #22
        JMP mb_look
mb_look_left:
        LDA #1
mb_look:
        JSR bug_x_plus
        LDX bug_index
        LDA BUG_Y,X
        CLC
        ADC #14
        JSR tile_at
        JSR is_solid
        LDX bug_index
        BCC mb_step
        LDA BUG_DIR,X       ; a wall: turn round
        EOR #$FE
        STA BUG_DIR,X
        JMP mb_fall
mb_step:
        LDA BUG_DIR,X       ; X += direction, with the sign carried into the high byte
        CLC
        ADC BUG_XLO,X
        STA BUG_XLO,X
        LDA BUG_DIR,X
        BMI mb_step_left
        LDA BUG_XHI,X
        ADC #0
        STA BUG_XHI,X
        JMP mb_fall
mb_step_left:
        LDA BUG_XHI,X
        ADC #$FF
        STA BUG_XHI,X
mb_fall:
        LDA #12             ; ground under its middle?
        JSR bug_x_plus
        LDX bug_index
        LDA BUG_Y,X
        CLC
        ADC #21
        JSR tile_at
        JSR is_solid
        LDX bug_index
        BCS mb_landed
        LDA BUG_Y,X         ; falling
        CLC
        ADC #2
        STA BUG_Y,X
        CMP #FIELD_END-16
        BCC mb_next
        LDA #0              ; fallen out of the world
        STA BUG_ON,X
        JMP mb_next
mb_landed:
        LDA BUG_Y,X
        CLC
        ADC #21-FIELD_Y
        AND #%11110000
        CLC
        ADC #FIELD_Y-21
        STA BUG_Y,X
mb_next:
        LDX bug_index
        DEX
        BMI mb_done
        JMP mb_bug
mb_done:
        RTS

; t_x = bug X's world X + A
bug_x_plus:
        CLC
        ADC BUG_XLO,X
        STA t_x
        LDA BUG_XHI,X
        ADC #0
        STA t_x+1
        RTS

; Does Jo touch a bug? Landing on top squashes it; anything else hurts. Every
; bug is checked against Jo's speed before any bounce, so landing on two at
; once squashes both.
hit_bugs:
        LDA jo_state
        BEQ hbg_check
        RTS
hbg_check:
        LDA #0
        STA squashed
        LDX #MAX_BUGS-1
hbg_bug:
        LDA BUG_ON,X
        CMP #1
        BNE hbg_next
        LDA px              ; across: within 16 pixels of each other?
        SEC
        SBC BUG_XLO,X
        STA tmp
        LDA px+1
        SBC BUG_XHI,X
        STA tmp2
        LDA tmp
        CLC
        ADC #16
        STA tmp
        LDA tmp2
        ADC #0
        BNE hbg_next
        LDA tmp
        CMP #32
        BCS hbg_next
        LDA BUG_Y,X         ; down: Jo's feet at or below the bug's top...
        CLC
        ADC #8
        STA tmp
        LDA py
        CLC
        ADC #20
        CMP tmp
        BCC hbg_next
        SEC
        SBC tmp
        STA tmp2            ; how far his feet are into the bug
        LDA BUG_Y,X         ; ...and his head no lower than its feet?
        CLC
        ADC #20
        STA tmp3
        LDA py
        CLC
        ADC #2
        CMP tmp3
        BEQ hbg_touch
        BCS hbg_next
hbg_touch:
        LDA vy_hi           ; falling onto it from above?
        BMI hbg_hurt
        LDA tmp2
        CMP #8
        BCS hbg_hurt
        LDA #2              ; squashed!
        STA BUG_ON,X
        LDA #30
        STA BUG_TIMER,X
        INC squashed
hbg_next:
        DEX
        BMI hbg_done
        JMP hbg_bug
hbg_done:
        LDA squashed        ; one bounce, however many bugs were squashed
        BEQ hbg_none
        LDA #<BOUNCE_SPEED
        STA vy_lo
        LDA #>BOUNCE_SPEED
        STA vy_hi
        LDA #0
        STA on_ground
        LDA #SFX_STOMP
        LDX #2
        JSR sfx_play
hbg_score:
        LDA #$00            ; 100 points a bug
        LDX #$01
        JSR add_score
        DEC squashed
        BNE hbg_score
hbg_none:
        RTS
hbg_hurt:
        JMP jo_hurt

; Turn world positions into sprite positions for the next frame.
place_sprites:
        LDA #1              ; Jo is always there
        STA SPR_ON
        LDA px
        SEC
        SBC cam_x
        STA tmp
        LDA px+1
        SBC cam_x+1
        STA tmp2
        LDA tmp
        CLC
        ADC #24
        STA SPR_XLO+S_JO
        LDA tmp2
        ADC #0
        STA SPR_XHI+S_JO
        LDA py
        STA SPR_Y+S_JO
        LDX #MAX_BUGS-1
ps_bug:
        LDA BUG_ON,X
        BEQ ps_bug_next
        LDA BUG_XLO,X       ; screen X = world X - camera + 24
        SEC
        SBC cam_x
        STA tmp
        LDA BUG_XHI,X
        SBC cam_x+1
        STA tmp2
        LDA tmp
        CLC
        ADC #24
        STA SPR_XLO+S_BUG,X
        LDA tmp2
        ADC #0
        STA SPR_XHI+S_BUG,X
        BMI ps_bug_gone     ; off the left of the screen: gone for good
        CMP #2
        BCS ps_bug_next     ; 512 or more: far to the right, $D010 can't show it
        LDA BUG_Y,X
        STA SPR_Y+S_BUG,X
        LDA BUG_ON,X        ; its shape
        CMP #2
        BEQ ps_squashed
        LDA frame_count
        LSR
        LSR
        LSR
        AND #1
        CLC
        ADC #P_BUG1
        JMP ps_bug_shape
ps_squashed:
        LDA #P_SQUASHED
ps_bug_shape:
        STA SPR_PTR+S_BUG,X
        LDA SPR_ON
        ORA bug_bits,X
        STA SPR_ON
        JMP ps_bug_next
ps_bug_gone:
        LDA #0
        STA BUG_ON,X
ps_bug_next:
        DEX
        BPL ps_bug
        LDA gem_timer       ; the popping gem
        BEQ ps_done
        LDA gem_x
        SEC
        SBC cam_x
        STA tmp
        LDA gem_x+1
        SBC cam_x+1
        STA tmp2
        LDA tmp
        CLC
        ADC #24
        STA SPR_XLO+S_GEM
        LDA tmp2
        ADC #0
        STA SPR_XHI+S_GEM
        LDA gem_y
        STA SPR_Y+S_GEM
        LDA #P_GEM
        STA SPR_PTR+S_GEM
        LDA SPR_ON
        ORA #%00100000
        STA SPR_ON
ps_done:
        RTS

; ===========================================================================
; SCORE AND STATUS
; ===========================================================================
add_score:                  ; score += A (tens, units) and X (thousands, hundreds), BCD
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
show_status:                ; SCORE 000000  GEMS 00  LIVES 3  LEVEL 1
        LDA #<status_text
        LDX #>status_text
        JSR print
        LDX #score+2
        LDY #6
        LDA #3
        JSR print_bcd
        LDX #gems
        LDY #19
        LDA #1
        JSR print_bcd
        LDA lives
        CMP #10
        BCC ss_lives
        LDA #9              ; (only room for one digit)
ss_lives:
        ORA #$30
        STA SCREEN+29
        LDA level
        CLC
        ADC #'1'
        STA SCREEN+38
        RTS

print_bcd:                  ; A bytes of BCD from zero page X down, at column Y of row 0 (40 + column: row 1)
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
        LDA #WHITE          ; below 8, so the text is not multicolour
        STA COLORS,X
        STA COLORS+$100,X
        STA COLORS+$200,X
        STA COLORS+$2E8,X
        INX
        BNE cs_loop
        RTS

; Clear the level's part of the screen (rows 2-24) to black, for a message.
clear_field:
        LDA #%00011000      ; no scroll, 40 columns
        STA top_d016
        LDA #BLACK
        STA top_d021
        LDA #0
        STA xscroll
        LDX #0
cfl_loop:
        LDA #32
        STA SCREEN+80,X
        STA SCREEN+80+256,X
        STA SCREEN+80+512,X
        STA SCREEN+80+664,X
        LDA #WHITE
        STA COLORS+80,X
        STA COLORS+80+256,X
        STA COLORS+80+512,X
        STA COLORS+80+664,X
        INX
        BNE cfl_loop
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
        LDA #$09            ; the tune: a pulse wave that fades a little
        STA SID+5
        LDA #$5A
        STA SID+6
        LDA #$08
        STA SID+3           ; pulse width 50%
        LDA #$0A            ; the bass: a triangle that plucks
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
        LDA #PURPLE         ; and the sprites' own colours
        STA VIC+$27
        LDA #BROWN
        STA VIC+$28
        STA VIC+$29
        STA VIC+$2A
        STA VIC+$2B
        RTS

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
bug_bits:       BYTE %00000010, %00000100, %00001000, %00010000
start_col:      BYTE 0              ; where Jo starts: column and row
start_row:      BYTE 0
check_col:      BYTE 0              ; the checkpoint
check_row:      BYTE 0
hit_col:        BYTE 0
hit_row:        BYTE 0
counter_save:   BYTE 0
level_colors:   BYTE 0, 0, 0, 0, 0  ; sky, $D022, $D023, upper colour RAM, lower

; Which tiles Jo and the bugs cannot pass through
solid:          BYTE 0, 1, 1, 1, 1, 1, 0, 1, 0, 0
; The letters of the level text, and the tiles they become
tile_letters:   BYTE '#', 'B', '?', '*', 'H', 'I', 'F', 'E', 'P', 'C'
tile_codes:     BYTE TILE_GRASS, TILE_BRICK, TILE_BONUS, TILE_GEM, TILE_HARD
                BYTE TILE_POLE, TILE_FLAG

; The level map's rows, and the screen rows each row of tiles starts on
map_row_lo:     BYTE <LEVEL_MAP, <(LEVEL_MAP+128), <(LEVEL_MAP+256), <(LEVEL_MAP+384)
                BYTE <(LEVEL_MAP+512), <(LEVEL_MAP+640), <(LEVEL_MAP+768)
                BYTE <(LEVEL_MAP+896), <(LEVEL_MAP+1024), <(LEVEL_MAP+1152)
map_row_hi:     BYTE >LEVEL_MAP, >(LEVEL_MAP+128), >(LEVEL_MAP+256), >(LEVEL_MAP+384)
                BYTE >(LEVEL_MAP+512), >(LEVEL_MAP+640), >(LEVEL_MAP+768)
                BYTE >(LEVEL_MAP+896), >(LEVEL_MAP+1024), >(LEVEL_MAP+1152)
field_lo:       BYTE <(SCREEN+5*40), <(SCREEN+7*40), <(SCREEN+9*40), <(SCREEN+11*40)
                BYTE <(SCREEN+13*40), <(SCREEN+15*40), <(SCREEN+17*40)
                BYTE <(SCREEN+19*40), <(SCREEN+21*40), <(SCREEN+23*40)
field_hi:       BYTE >(SCREEN+5*40), >(SCREEN+7*40), >(SCREEN+9*40), >(SCREEN+11*40)
                BYTE >(SCREEN+13*40), >(SCREEN+15*40), >(SCREEN+17*40)
                BYTE >(SCREEN+19*40), >(SCREEN+21*40), >(SCREEN+23*40)

status_text:
        BYTE 0, 0, WHITE
        ASCIIZ "SCORE 000000  GEMS 00  LIVES 3  LEVEL 1"
over_text:
        BYTE 12, 15, WHITE
        ASCIIZ "GAME OVER"
ready_text:
        BYTE 10, 16, WHITE
        ASCIIZ "LEVEL 1"
ready_name:
        BYTE 12, 0, YELLOW  ; (START_LEVEL centres the name it copies here)
        TEXT "                         "
        BYTE 0
; Text colours stay below 8: in multicolour mode, 8 and up make a cell multicolour.
title_text:
        BYTE 3, 11, YELLOW
        ASCIIZ "J U M P I N '   J O"
        BYTE 9, 10, WHITE
        ASCIIZ "LEFT AND RIGHT TO RUN"
        BYTE 11, 11, WHITE
        ASCIIZ "UP OR FIRE TO JUMP"
        BYTE 14, 7, GREEN
        ASCIIZ "JUMP ON THE BUGS TO SQUASH"
        BYTE 16, 9, YELLOW
        ASCIIZ "BUMP ? BLOCKS FOR GEMS"
        BYTE 18, 7, CYAN
        ASCIIZ "100 GEMS FOR AN EXTRA LIFE"
        BYTE 21, 11, WHITE
        ASCIIZ "PRESS FIRE TO PLAY"
        BYTE 23, 11, PURPLE
        ASCIIZ "JOYSTICK IN PORT 2"
        BYTE 1, 12, WHITE
        ASCIIZ "HI-SCORE"
        BYTE $FF

; ---------------------------------------------------------------------------
; Sound effects for voice 3: waveform, attack/decay, sustain/release,
; frequency low, high, change per frame low, high, length in frames.
; ---------------------------------------------------------------------------
SFX_JUMP    = 0
SFX_GEM     = 8
SFX_STOMP   = 16
SFX_BRICK   = 24
SFX_BUMP    = 32
SFX_HURT    = 40
SFX_FLAG    = 48
SFX_ONE_UP  = 56
sfx_table:
        BYTE 64,  $00, $F0, $00, $0C, $80, $01, 10   ; jump: boing upwards
        BYTE 16,  $08, $00, $00, $50, $00, $08, 6    ; gem: a bright ping
        BYTE 128, $06, $00, $00, $08, $C0, $FF, 6    ; stomp: squelch
        BYTE 128, $08, $00, $00, $18, $00, $FF, 10   ; brick: crumble
        BYTE 16,  $04, $00, $00, $06, $00, $00, 3    ; bump: a dull knock
        BYTE 32,  $00, $F8, $00, $20, $00, $FF, 30   ; hurt: a falling wail
        BYTE 64,  $00, $F8, $00, $10, $00, $01, 40   ; the flag: a rising fanfare
        BYTE 16,  $00, $F8, $00, $30, $00, $04, 16   ; extra life

; ---------------------------------------------------------------------------
; The tune. Notes are numbered in semitones from C2 = 1.
; ---------------------------------------------------------------------------
F2 = 6
G2 = 8
B2 = 12
C3 = 13
D3 = 15
G3 = 20
C4 = 25
D4 = 27
E4 = 29
F4 = 30
G4 = 32
A4 = 34
B4 = 36
C5 = 37
mus_list_lo:    BYTE <melody, <bass
mus_list_hi:    BYTE >melody, >bass
mus_wave:       BYTE 64, 16         ; pulse for the tune, triangle for the bass

melody:
        BYTE C4,8, E4,8, G4,8, E4,8, F4,8, A4,8, G4,16
        BYTE E4,8, C4,8, D4,8, E4,8, D4,16, 0,16
        BYTE C4,8, E4,8, G4,8, E4,8, F4,8, A4,8, C5,16
        BYTE B4,8, A4,8, G4,8, F4,8, E4,16, 0,16
        BYTE A4,8, A4,8, G4,8, F4,8, G4,8, G4,8, F4,8, E4,8
        BYTE F4,8, F4,8, E4,8, D4,8, E4,16, C4,16
        BYTE D4,8, E4,8, F4,8, G4,8, A4,8, B4,8, C5,16
        BYTE G4,16, E4,16, C4,16, 0,16
        BYTE $FF
bass:
        BYTE C3,16, G3,16, F2,16, C3,16
        BYTE C3,16, G3,16, G2,16, D3,16
        BYTE C3,16, G3,16, F2,16, C3,16
        BYTE G2,16, D3,16, C3,16, G3,16
        BYTE F2,16, C3,16, C3,16, G3,16
        BYTE F2,16, G2,16, C3,16, G3,16
        BYTE G2,16, D3,16, G2,16, B2,16
        BYTE C3,16, G2,16, C3,32
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
; LEVELS
; Each level: five colours - the sky, $D022, $D023, and the colour RAM of
; the upper rows and of the bottom two rows of tiles (+ MULTI) - and a
; name of up to 25 letters, then the map: 4 strips of 32 columns, each 10
; rows from the top.
;   #  ground     B  brick     ?  ? block    H  hard block   *  gem
;   E  a bug      P  Jo starts C  checkpoint I  flag pole    F  the flag
; ===========================================================================
level_list:
        WORD level_1, level_2

level_1:
        BYTE CYAN, BLACK, ORANGE, YELLOW+MULTI, GREEN+MULTI
        ASCIIZ "SUNNY HILLS"
        TEXT "                                "
        TEXT "                                "
        TEXT "                                "
        TEXT "                                "
        TEXT "        ?B?B?                   "
        TEXT "                        *  *    "
        TEXT "                       HHHHHH   "
        TEXT "  P                E   H    H E "
        TEXT "################################"
        TEXT "################################"

        TEXT "                                "
        TEXT "                                "
        TEXT "                                "
        TEXT "                                "
        TEXT "      ?        ?B?              "
        TEXT "                        *  *    "
        TEXT "                       BBBBBB   "
        TEXT "    E             E           E "
        TEXT "##########   #######   #########"
        TEXT "##########   #######   #########"

        TEXT "                                "
        TEXT "                                "
        TEXT "                                "
        TEXT "                                "
        TEXT "              *  *  *       ?   "
        TEXT "            *         *         "
        TEXT "          HH            HH      "
        TEXT " C      HHHH   E     E  HHHH  E "
        TEXT "################################"
        TEXT "################################"

        TEXT "                                "
        TEXT "                                "
        TEXT "                                "
        TEXT "                         F      "
        TEXT " ?B?B?                   I      "
        TEXT "                         I      "
        TEXT "                         I      "
        TEXT "  E           E   E HHH  I      "
        TEXT "########   #####################"
        TEXT "########   #####################"

level_2:
        BYTE BLACK, BLUE, DARK_GREY, CYAN+MULTI, GREEN+MULTI
        ASCIIZ "MOONLIT CAVES"
        TEXT "HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH"
        TEXT "                                "
        TEXT "                                "
        TEXT "                                "
        TEXT "         ?B?B?B?B?B?B?          "
        TEXT "                                "
        TEXT "           *    *    *          "
        TEXT "  P         E      E     E    E "
        TEXT "################################"
        TEXT "################################"

        TEXT "HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH"
        TEXT "                                "
        TEXT "                                "
        TEXT "                                "
        TEXT "      *  *  *       ?    ?      "
        TEXT "                                "
        TEXT "     HHHHHHHHH                  "
        TEXT "           E       BBBBBB    E  "
        TEXT "####    ######   ###    ########"
        TEXT "####    ######   ###    ########"

        TEXT "HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH"
        TEXT "          H        H            "
        TEXT "                                "
        TEXT "                                "
        TEXT "     *   *        ?B?    *      "
        TEXT "                                "
        TEXT "     HH     HHHHH        HH     "
        TEXT " C       E   E        E     E   "
        TEXT "################################"
        TEXT "################################"

        TEXT "HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH"
        TEXT "                                "
        TEXT "                                "
        TEXT "                         F      "
        TEXT " ?B?B?      *  *  *      I      "
        TEXT "                         I      "
        TEXT "                         I      "
        TEXT "   E          E     HHH  I      "
        TEXT "########   #####################"
        TEXT "########   #####################"

; ===========================================================================
; GRAPHICS
; Multicolour: each pair of bits is one double-width pixel. 00 is the
; background; 01, 10 and 11 are the three other colours.
; ===========================================================================

        ORG SPRITE_DATA+0*64   ; 160: standing, facing right
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%10101010,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10101000
        BYTE %00000001,%01010101,%01000000
        BYTE %00000001,%01010111,%01010000
        BYTE %00000001,%01010111,%01010000
        BYTE %00000000,%01010101,%01000000
        BYTE %00000000,%00010101,%00000000
        BYTE %00000000,%10101010,%10000000
        BYTE %00000010,%10101010,%10100000
        BYTE %00000110,%10101010,%10100100
        BYTE %00000110,%10101010,%10100100
        BYTE %00000010,%10101010,%10100000
        BYTE %00000010,%10101010,%10100000
        BYTE %00000000,%01010001,%01000000
        BYTE %00000000,%01010001,%01000000
        BYTE %00000000,%01010001,%01000000
        BYTE %00000011,%11110011,%11110000
        BYTE %00000011,%11110011,%11110000

        ORG SPRITE_DATA+1*64   ; 161: running
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%10101010,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10101000
        BYTE %00000001,%01010101,%01000000
        BYTE %00000001,%01010111,%01010000
        BYTE %00000001,%01010111,%01010000
        BYTE %00000000,%01010101,%01000000
        BYTE %00000000,%00010101,%00000000
        BYTE %00000000,%10101010,%10000000
        BYTE %00000110,%10101010,%10100000
        BYTE %00000110,%10101010,%10100101
        BYTE %00000010,%10101010,%10100000
        BYTE %00000010,%10101010,%10100000
        BYTE %00000001,%01000000,%01010000
        BYTE %00000101,%00000000,%00010100
        BYTE %00010100,%00000000,%00000101
        BYTE %00111100,%00000000,%00001111
        BYTE %11111100,%00000000,%00001111

        ORG SPRITE_DATA+2*64   ; 162: running
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%10101010,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000010,%10101010,%10101000
        BYTE %00000001,%01010101,%01000000
        BYTE %00000001,%01010111,%01010000
        BYTE %00000001,%01010111,%01010000
        BYTE %00000000,%01010101,%01000000
        BYTE %00000000,%00010101,%00000000
        BYTE %00000000,%10101010,%10000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000110,%10101010,%10010000
        BYTE %00000010,%10101010,%10010000
        BYTE %00000010,%10101010,%10100000
        BYTE %00000000,%00010101,%00000000
        BYTE %00000000,%00010101,%00000000
        BYTE %00000000,%00010100,%01000000
        BYTE %00000000,%00010100,%01000000
        BYTE %00000000,%00111111,%11000000
        BYTE %00000000,%00111111,%11000000

        ORG SPRITE_DATA+3*64   ; 163: jumping
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%10101010,%00000100
        BYTE %00000010,%10101010,%10000100
        BYTE %00000010,%10101010,%10101001
        BYTE %00000001,%01010101,%01001000
        BYTE %00000001,%01010111,%01011000
        BYTE %00000001,%01010111,%01011000
        BYTE %00000000,%01010101,%01100000
        BYTE %00000000,%00010101,%10000000
        BYTE %00000000,%10101010,%10000000
        BYTE %00000110,%10101010,%10000000
        BYTE %00010010,%10101010,%10100000
        BYTE %00000010,%10101010,%10100000
        BYTE %00000010,%10101010,%10100000
        BYTE %00000001,%01000000,%01010000
        BYTE %00000101,%00000000,%00010101
        BYTE %00111111,%00000000,%00001111
        BYTE %00111111,%00000000,%00000000

        ORG SPRITE_DATA+4*64   ; 164: standing, facing left
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%10101010,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00101010,%10101010,%10000000
        BYTE %00000001,%01010101,%01000000
        BYTE %00000101,%11010101,%01000000
        BYTE %00000101,%11010101,%01000000
        BYTE %00000001,%01010101,%00000000
        BYTE %00000000,%01010100,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00001010,%10101010,%10000000
        BYTE %00011010,%10101010,%10010000
        BYTE %00011010,%10101010,%10010000
        BYTE %00001010,%10101010,%10000000
        BYTE %00001010,%10101010,%10000000
        BYTE %00000001,%01000101,%00000000
        BYTE %00000001,%01000101,%00000000
        BYTE %00000001,%01000101,%00000000
        BYTE %00001111,%11001111,%11000000
        BYTE %00001111,%11001111,%11000000

        ORG SPRITE_DATA+5*64   ; 165: running, facing left
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%10101010,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00101010,%10101010,%10000000
        BYTE %00000001,%01010101,%01000000
        BYTE %00000101,%11010101,%01000000
        BYTE %00000101,%11010101,%01000000
        BYTE %00000001,%01010101,%00000000
        BYTE %00000000,%01010100,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00001010,%10101010,%10010000
        BYTE %01011010,%10101010,%10010000
        BYTE %00001010,%10101010,%10000000
        BYTE %00001010,%10101010,%10000000
        BYTE %00000101,%00000001,%01000000
        BYTE %00010100,%00000000,%01010000
        BYTE %01010000,%00000000,%00010100
        BYTE %11110000,%00000000,%00111100
        BYTE %11110000,%00000000,%00111111

        ORG SPRITE_DATA+6*64   ; 166: running, facing left
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%10101010,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00101010,%10101010,%10000000
        BYTE %00000001,%01010101,%01000000
        BYTE %00000101,%11010101,%01000000
        BYTE %00000101,%11010101,%01000000
        BYTE %00000001,%01010101,%00000000
        BYTE %00000000,%01010100,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000110,%10101010,%10010000
        BYTE %00000110,%10101010,%10000000
        BYTE %00001010,%10101010,%10000000
        BYTE %00000000,%01010100,%00000000
        BYTE %00000000,%01010100,%00000000
        BYTE %00000001,%00010100,%00000000
        BYTE %00000001,%00010100,%00000000
        BYTE %00000011,%11111100,%00000000
        BYTE %00000011,%11111100,%00000000

        ORG SPRITE_DATA+7*64   ; 167: jumping, facing left
        BYTE %00000000,%00000000,%00000000
        BYTE %00010000,%10101010,%00000000
        BYTE %00010010,%10101010,%10000000
        BYTE %01101010,%10101010,%10000000
        BYTE %00100001,%01010101,%01000000
        BYTE %00100101,%11010101,%01000000
        BYTE %00100101,%11010101,%01000000
        BYTE %00001001,%01010101,%00000000
        BYTE %00000010,%01010100,%00000000
        BYTE %00000010,%10101010,%00000000
        BYTE %00000010,%10101010,%10010000
        BYTE %00001010,%10101010,%10000100
        BYTE %00001010,%10101010,%10000000
        BYTE %00001010,%10101010,%10000000
        BYTE %00000101,%00000001,%01000000
        BYTE %01010100,%00000000,%01010000
        BYTE %11110000,%00000000,%11111100
        BYTE %00000000,%00000000,%11111100

        ORG SPRITE_DATA+8*64   ; 168: hurt
        BYTE %00000000,%00000000,%00000000
        BYTE %00000100,%10101010,%00010000
        BYTE %00000110,%10101010,%10010000
        BYTE %00000110,%10101010,%10010000
        BYTE %00000101,%01010101,%01010000
        BYTE %00000001,%11010111,%01000000
        BYTE %00000001,%01010101,%01000000
        BYTE %00000001,%01111101,%00000000
        BYTE %00000000,%01010101,%00000000
        BYTE %00000010,%10101010,%10000000
        BYTE %00001010,%10101010,%10100000
        BYTE %00001010,%10101010,%10100000
        BYTE %00000010,%10101010,%10000000
        BYTE %00000001,%01000001,%01000000
        BYTE %00000001,%01000001,%01000000
        BYTE %00001111,%11000011,%11110000

        ORG SPRITE_DATA+9*64   ; 169: a bug, walking
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%10101010,%00000000
        BYTE %00001010,%10101010,%10100000
        BYTE %00101010,%10101010,%10101000
        BYTE %00101001,%01101001,%01101000
        BYTE %10100111,%01101001,%11011010
        BYTE %10100111,%01101001,%11011010
        BYTE %10101010,%10101010,%10101010
        BYTE %10101010,%01010101,%10101010
        BYTE %00101010,%10101010,%10101000
        BYTE %00000101,%01010101,%01010000
        BYTE %00001100,%00111100,%00110000
        BYTE %00111100,%00111100,%00111100
        BYTE %00110000,%00000000,%00001100

        ORG SPRITE_DATA+10*64   ; 170: a bug, walking
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%10101010,%00000000
        BYTE %00001010,%10101010,%10100000
        BYTE %00101010,%10101010,%10101000
        BYTE %00101001,%01101001,%01101000
        BYTE %10100111,%01101001,%11011010
        BYTE %10100111,%01101001,%11011010
        BYTE %10101010,%10101010,%10101010
        BYTE %10101010,%01010101,%10101010
        BYTE %00101010,%10101010,%10101000
        BYTE %00000101,%01010101,%01010000
        BYTE %00000011,%00111100,%11000000
        BYTE %00000011,%11000011,%11000000
        BYTE %00000000,%11000011,%00000000

        ORG SPRITE_DATA+11*64   ; 171: a squashed bug
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
        BYTE %00001010,%10101010,%10100000
        BYTE %00101010,%10101010,%10101000
        BYTE %10100111,%10101010,%11011010
        BYTE %10101010,%10101010,%10101010
        BYTE %00111100,%11110011,%11001111

        ORG SPRITE_DATA+12*64   ; 172: a gem popping out of a block, in the level's gem colour
        BYTE %00000000,%00000000,%00000000
        BYTE %00000000,%00000000,%00000000
        BYTE %00001111,%11110000,%00000000
        BYTE %00111010,%10101100,%00000000
        BYTE %11101010,%10101011,%00000000
        BYTE %11101010,%10101011,%00000000
        BYTE %11101010,%10101011,%00000000
        BYTE %11101010,%10101011,%00000000
        BYTE %00111010,%10101100,%00000000
        BYTE %00111010,%10101100,%00000000
        BYTE %00001110,%10110000,%00000000
        BYTE %00001110,%10110000,%00000000
        BYTE %00000011,%11000000,%00000000

        ORG CHARSET+(TILE_CHARS+4)*8 ; tile 0, the sky, is four empty characters
        BYTE %11111111,%11111111,%10111011,%10101010,%10100110,%10101010,%10101010,%10011010 ; grass: top left
        BYTE %11111111,%11111111,%11101110,%10101010,%10101010,%10100110,%10101010,%10101010 ; top right
        BYTE %10101010,%10101010,%10100110,%10101010,%10101010,%10011010,%10101010,%10101010 ; bottom left
        BYTE %10011010,%10101010,%10101010,%10101010,%10011010,%10101010,%10101010,%01101010 ; bottom right
        BYTE %10101010,%10101001,%10101010,%10011010,%10101010,%10101010,%10101010,%10100110 ; ground: top left
        BYTE %10101010,%10101010,%10100110,%10101010,%10101010,%01101010,%10101010,%10101010 ; top right
        BYTE %10101010,%10101010,%10011010,%10101010,%10101010,%10101010,%10100110,%10101010 ; bottom left
        BYTE %10101010,%10100110,%10101010,%10101010,%01101010,%10101010,%10100110,%10101010 ; bottom right
        BYTE %01010101,%11111101,%10101001,%10101001,%10101001,%10101001,%10101001,%01010101 ; brick: top left
        BYTE %01010101,%11111111,%10101010,%10101010,%10101010,%10101010,%10101010,%01010101 ; top right
        BYTE %11111111,%10101010,%10101010,%10101010,%10101010,%10101010,%10101010,%01010101 ; bottom left
        BYTE %11111101,%10101001,%10101001,%10101001,%10101001,%10101001,%10101001,%01010101 ; bottom right
        BYTE %01010101,%01111111,%01111011,%01111101,%01110111,%01111111,%01111111,%01111101 ; bonus: top left
        BYTE %01010101,%11111110,%11101110,%01111110,%11011110,%11011110,%01111110,%11111110 ; top right
        BYTE %01111101,%01111111,%01111101,%01111111,%01111011,%01111111,%01101010,%01010101 ; bottom left
        BYTE %11111110,%11111110,%11111110,%11111110,%11101110,%11111110,%10101010,%01010101 ; bottom right
        BYTE %01010101,%01101010,%01101110,%01101010,%01101010,%01101010,%01101010,%01101010 ; used: top left
        BYTE %01010101,%10101001,%10111001,%10101001,%10101001,%10101001,%10101001,%10101001 ; top right
        BYTE %01101010,%01101010,%01101010,%01101010,%01101010,%01101110,%01101010,%01010101 ; bottom left
        BYTE %10101001,%10101001,%10101001,%10101001,%10101001,%10111001,%10101001,%01010101 ; bottom right
        BYTE %00000000,%00000000,%00000101,%00011111,%01111111,%01111111,%01111010,%01111111 ; gem: top left
        BYTE %00000000,%00000000,%01010000,%11110100,%11111101,%11111001,%10101001,%11111001 ; top right
        BYTE %00011111,%00011111,%00000111,%00000111,%00000001,%00000000,%00000000,%00000000 ; bottom left
        BYTE %11110100,%11100100,%11010000,%10010000,%01000000,%00000000,%00000000,%00000000 ; bottom right
        BYTE %11111111,%11101010,%11101010,%11101011,%11101010,%11101010,%11101010,%11101010 ; hard: top left
        BYTE %11111110,%10101001,%10101001,%10101001,%10101001,%10101001,%10101001,%10101001 ; top right
        BYTE %11101010,%11101010,%11101010,%11101010,%11101010,%11101010,%11101010,%10010101 ; bottom left
        BYTE %10101001,%10101001,%10101001,%10101001,%10011001,%10101001,%10101001,%01010101 ; bottom right
        BYTE %00000001,%00000011,%00000011,%00000011,%00000011,%00000011,%00000011,%00000011 ; pole: top left
        BYTE %01000000,%01000000,%01000000,%01000000,%01000000,%01000000,%01000000,%01000000 ; top right
        BYTE %00000011,%00000011,%00000011,%00000011,%00000011,%00000011,%00000011,%00000011 ; bottom left
        BYTE %01000000,%01000000,%01000000,%01000000,%01000000,%01000000,%01000000,%01000000 ; bottom right
        BYTE %00000011,%00001111,%00000011,%00000011,%00000011,%00000011,%00000011,%00000011 ; flag: top left
        BYTE %11000000,%11110000,%11000000,%01101010,%01101010,%01101010,%01101010,%01101000 ; top right
        BYTE %00000011,%00000011,%00000011,%00000011,%00000011,%00000011,%00000011,%00000011 ; bottom left
        BYTE %01100000,%01000000,%01000000,%01000000,%01000000,%01000000,%01000000,%01000000 ; bottom right
