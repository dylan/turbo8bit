; ===========================================================================
;                                ROCKFALL
; ===========================================================================
; Dig through the caves, grab the gems and reach the exit before time runs
; out - in the style of the boulder-dashing cave games of 1984. Written in
; 6502 assembly for the Commodore 64; everything is in this one file.
;
; HOW TO PLAY
;   Joystick in port 2 (on this page: arrow keys, and Space for fire).
;   Move through dirt to dig it. Collect enough gems to open the exit, then
;   walk into it. Boulders and gems fall when nothing holds them up, and
;   roll off each other - don't stand under one. Push a boulder sideways
;   into an empty space. Hold fire and push a direction to grab dirt or a
;   gem next to you without stepping into it. Drop a boulder on a firefly
;   to blow it up; touching one blows YOU up.
;
; WHAT TO LOOK FOR
;   - The screen IS the map. The caves are characters in screen memory,
;     and the game reads and writes them there: no other copy is kept.
;   - Every tile that can move has bit 7 of its character code set, so the
;     cave scan finds them with a single BMI, and a jump table picks the
;     routine for each kind (see SCAN_CAVE and TILE_HANDLERS).
;   - The cave is scanned from the bottom up, so a falling boulder lands in
;     a row that has already been scanned and moves only once per turn.
;   - Animation by redefining characters: changing the 8 bytes of the gem
;     character makes every gem on screen sparkle at once.
;   - The caves are drawn as text - see the CAVES section at the end.
;
; MEMORY MAP
;   $0400-$07E7  screen: the cave, the score line and the lives
;   $0810-       the program
;   $3800-$39FF  letters and digits, copied from the character ROM
;   $3A00-$3A27  the cave's still tiles (screen codes 64-68)
;   $3C00-$3C7F  the tiles that move (screen codes 128-143)
;   $C000-$C0FF  tables
;
; THINGS TO TRY
;   - Design your own cave: edit the text of one in CAVES. Every row must
;     be 40 characters, inside a border of #.
;   - Make the game faster or slower: change TICK_FRAMES.
;   - Change how long you get: the time in each cave's header (in BCD).
; ===========================================================================

; ---------------------------------------------------------------------------
; Settings
; ---------------------------------------------------------------------------
TICK_FRAMES  = 6            ; frames per turn of the cave: lower is faster, down
                            ; to 2 (a turn's scan takes more than one frame)
START_LIVES  = 3
NUM_CAVES    = 4

; ---------------------------------------------------------------------------
; The C64's chips and memory
; ---------------------------------------------------------------------------
VIC         = $D000
SID         = $D400
SCREEN      = $0400
COLORS      = $D800
CHARSET     = $3800
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
; Tiles: the character codes the cave is made of
; ---------------------------------------------------------------------------
T_EMPTY     = 32            ; a space
T_DIRT      = 64            ; tiles below 128 never move by themselves
T_WALL      = 65            ; brick: boulders roll off it
T_STEEL     = 66            ; indestructible, even by explosions
T_EXIT      = 67            ; looks like steel until it opens, and is as hard
T_PLAYER    = 68
T_BOULDER   = 128           ; tiles from 128 up (bit 7 set) are moved by SCAN_CAVE
T_GEM       = 129
T_BOULDER_F = 130           ; a boulder that is falling
T_GEM_F     = 131           ; a gem that is falling
T_FIREFLY   = 132           ; 132-135: a firefly facing up, right, down, left
T_FIREFLY_M = 136           ; 136-139: the same, already moved this turn
T_EXPLODE   = 140           ; 140-142: an explosion, burning out
T_EXPLODE_M = 143           ; the same, set off ahead of this turn's scan

TO_FALLING  = 2             ; T_BOULDER + TO_FALLING = T_BOULDER_F

CAVE_TOP    = 2             ; the cave fills screen rows 2-23
CAVE_ROWS   = 22

; ---------------------------------------------------------------------------
; Zero page
; ---------------------------------------------------------------------------
frame_count = $02
joy         = $03
joy_latch   = $04           ; directions pressed since the last turn
fire_armed  = $05
frame_done  = $06           ; frames the main loop has handled (see WAIT_FRAME)
ptr         = $07           ; $07-$08: the screen row ABOVE the one scanned
cptr        = $09           ; $09-$0A: the same row in colour memory
tmp         = $0B
tmp2        = $0C
counter     = $0D
here        = $0E           ; offset of the current cell from ptr (40 + column)
tile        = $0F
jump        = $10           ; $10-$11: address for the jump table
scan_row    = $12
prow        = $13           ; the player's screen row and column
pcol        = $14
facing      = $15           ; 0 = right, 1 = left, for the player's shape
walk        = $16           ; walking animation step
dead        = $17           ; frames until the cave restarts, 0 = alive
tick_timer  = $18
second      = $19           ; frames until the clock ticks
cave        = $1A           ; cave number, 0 up
exit_open   = $1B
exit_row    = $1C
exit_col    = $1D
done        = $1E           ; 1 = the player reached the exit
gems_needed = $1F           ; BCD
gems_got    = $20           ; BCD
time        = $21           ; seconds left, BCD: $21-$22
score       = $23           ; $23-$25, BCD
hiscore     = $26           ; $26-$28
lives       = $29
anim        = $2A           ; animation counter
cave_ptr    = $2B           ; $2B-$2C: the cave's text
src         = $2D           ; $2D-$2E: a source for copying
gem_value   = $2F           ; BCD points for a gem
sfx_start   = $30           ; the sound driver's variables, 3 bytes each
sfx_time    = $33
sfx_wave    = $36
sfx_ad      = $39
sfx_sr      = $3C
sfx_flo     = $3F
sfx_fhi     = $42
sfx_dlo     = $45
sfx_dhi     = $48
anim_char   = $4B           ; the character ANIMATE is setting
ex_count    = $4C           ; cells left in a row of an explosion
cptr2       = $4D           ; $4D-$4E: the character SET_CHAR is setting
target      = $4F           ; offset of the cell the player or a firefly moves to
ff_dir      = $50           ; the way a firefly is trying to go
flash       = $51           ; frames of white border left
pdir        = $52           ; the way the player is moving
ROW_LO      = $C000         ; address of each screen row
ROW_HI      = $C020

; ===========================================================================
; START
; ===========================================================================
        ORG $0810           ; SYS 2064

start:
        SEI
        CLD
        LDA #$7F
        STA $DC0D           ; no CIA timer interrupts: the raster runs the show
        LDA $DC0D
        LDA #$FF
        STA JOYSTICK        ; no keyboard row selected: $DC00 is just the joystick
        JSR make_row_table
        JSR copy_font
        JSR init_sid
        LDA #BLACK
        STA VIC+$20
        STA VIC+$21
        STA VIC+$15         ; no sprites in this game
        LDA #$1E            ; screen at $0400, characters at $3800
        STA VIC+$18
        LDA #0
        STA hiscore
        STA hiscore+1
        STA hiscore+2
        STA score
        STA score+1
        STA score+2
        LDA #<irq
        STA $0314
        LDA #>irq
        STA $0315
        LDA #251
        STA VIC+$12
        LDA VIC+$11
        AND #$7F
        STA VIC+$11
        LDA #1
        STA VIC+$1A
        STA VIC+$19
        LDA frame_count     ; no frames owed yet (see WAIT_FRAME)
        STA frame_done
        CLI

main_loop:
        JSR title_screen
        JSR play_game
        JMP main_loop

; ===========================================================================
; INTERRUPT AND TIMING
; ===========================================================================
irq:
        CLD                 ; the 6502 keeps decimal mode for an interrupt,
                            ; and SFX_UPDATE's ADC must add in binary
        LDA #1
        STA VIC+$19         ; acknowledge the raster interrupt
        INC frame_count
        JSR sfx_update
        JMP $EA81           ; restore the registers and return

; Wait for the next frame. A turn of the cave can take longer than a frame,
; so the main loop keeps its own count of the frames it has handled: when it
; is behind, it carries straight on and catches up. Each pass of the main
; loop is then one frame, and the clock keeps time.
wait_frame:
        LDA frame_done
wf_wait:
        CMP frame_count
        BEQ wf_wait
        INC frame_done
        RTS

wait_frames:
        STA counter
wfs_loop:
        JSR wait_frame
        JSR animate
        DEC counter
        BNE wfs_loop
        RTS

read_joystick:
        LDA JOYSTICK
        EOR #$FF
        AND #%00011111
        STA joy
        ORA joy_latch       ; remember a quick tap until the next turn
        STA joy_latch
        RTS

fire_pressed:
        JSR read_joystick
        LDA joy
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

; ===========================================================================
; THE TITLE SCREEN
; ===========================================================================
title_screen:
        JSR clear_screen
        LDA #0
        STA fire_armed
        STA dead
        STA facing
        STA walk
        LDA #1
        STA exit_open       ; so the exit flashes in the key
        LDA #<title_text
        LDX #>title_text
        JSR print_list
        LDX #score+2        ; the last score, top left
        LDY #6
        LDA #3
        JSR print_bcd
        LDX #hiscore+2      ; the high score, top right
        LDY #34
        LDA #3
        JSR print_bcd
        LDX #4              ; the key: one of each tile
ts_key:
        LDY title_key_row,X
        LDA ROW_LO,Y
        STA ptr
        STA cptr
        LDA ROW_HI,Y
        STA ptr+1
        CLC
        ADC #>(COLORS-SCREEN)
        STA cptr+1
        LDA title_key_tile,X
        LDY #11
        STX tmp
        JSR put_tile        ; (put_tile uses X)
        LDX tmp
        DEX
        BPL ts_key
        LDA #WHITE          ; the open exit is white
        STA COLORS+15*40+11
ts_loop:
        JSR wait_frame
        JSR animate
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
        STA cave
        LDA #START_LIVES
        STA lives

pg_cave:
        JSR start_cave

; One pass per frame (WAIT_FRAME makes up for a turn that overruns one).
; Every TICK_FRAMES frames the cave takes a turn: the player moves, then
; everything else in the cave does.
pg_loop:
        JSR wait_frame
        JSR read_joystick
        JSR animate
        DEC tick_timer
        BNE pg_checks
        LDA #TICK_FRAMES
        STA tick_timer
        JSR move_player
        JSR scan_cave
        LDA #0              ; forget taps: the next turn starts afresh
        STA joy_latch
pg_checks:
        LDA done
        BNE pg_exit
        LDA dead
        BNE pg_dying
        JSR clock
        JMP pg_loop

pg_dying:                   ; the cave carries on while the dust settles
        DEC dead
        BNE pg_loop
        DEC lives
        BEQ pg_over
        JMP pg_cave         ; try this cave again

pg_exit:
        JSR time_bonus
        INC cave
        LDA cave
        CMP #NUM_CAVES
        BCC pg_next
        LDA #0              ; after the last cave, round again
        STA cave
pg_next:
        JMP pg_cave

pg_over:
        JSR show_lives      ; none left
        LDA #<over_text
        LDX #>over_text
        JSR print
        JSR update_hiscore
        LDA #150
        JMP wait_frames

; Set up the current cave from its text.
start_cave:
        JSR clear_screen
        LDA cave
        ASL
        TAX
        LDA cave_list,X
        STA src
        LDA cave_list+1,X
        STA src+1
        LDY #0              ; the header: gems needed, then the time
        LDA (src),Y
        STA gems_needed
        INY
        LDA (src),Y
        STA time
        INY
        LDA (src),Y
        STA time+1
        LDA src
        CLC
        ADC #3
        STA src
        BCC sc_name
        INC src+1
sc_name:
        LDY #0              ; copy the name after "CAVE n  "
sc_name_copy:
        LDA (src),Y
        STA name_text+11,Y
        BEQ sc_name_done
        INY
        BNE sc_name_copy
sc_name_done:
        INY                 ; skip the name and its zero: the map comes next
        TYA
        CLC
        ADC src
        STA src
        BCC sc_map
        INC src+1
sc_map:
        LDA #CAVE_TOP       ; decode the map, row by row
        STA scan_row
sc_row:
        LDX scan_row
        LDA ROW_LO,X
        STA ptr
        STA cptr
        LDA ROW_HI,X
        STA ptr+1
        CLC
        ADC #>(COLORS-SCREEN)
        STA cptr+1
        LDY #0
sc_cell:
        LDA (src),Y
        JSR map_tile        ; text character -> tile
        JSR put_tile
        INY
        CPY #40
        BNE sc_cell
        LDA src
        CLC
        ADC #40
        STA src
        BCC sc_next_row
        INC src+1
sc_next_row:
        INC scan_row
        LDA scan_row
        CMP #CAVE_TOP+CAVE_ROWS
        BNE sc_row

        LDA #0
        STA gems_got
        STA exit_open
        STA done
        STA dead
        STA joy_latch
        STA walk
        LDA #$10
        STA gem_value       ; 10 points a gem, 20 once the exit is open
        LDA #TICK_FRAMES
        STA tick_timer
        LDA #50
        STA second
        LDA cave            ; the cave's name and number on row 1
        CLC
        ADC #'1'
        STA name_text+8
        LDA #<name_text
        LDX #>name_text
        JSR print
        LDA #<status_text
        LDX #>status_text
        JSR print
        LDA #<lives_text
        LDX #>lives_text
        JSR print
        JSR show_gems
        JSR show_time
        JSR show_score
        JSR show_lives
        LDA frame_count     ; play starts now: the frames spent drawing the
        STA frame_done      ; cave are not for the main loop to catch up
        LDA #SFX_NEW_CAVE
        LDX #2
        JMP sfx_play

; Turn a character of the cave text into a tile. 'P' and 'X' also record
; where the player and the exit are. Y is the column, scan_row the row.
map_tile:
        CMP #'#'
        BEQ mt_steel
        CMP #'='
        BEQ mt_wall
        CMP #'.'
        BEQ mt_dirt
        CMP #'O'
        BEQ mt_boulder
        CMP #'*'
        BEQ mt_gem
        CMP #'F'
        BEQ mt_firefly
        CMP #'P'
        BEQ mt_player
        CMP #'X'
        BEQ mt_exit
        LDA #T_EMPTY
        RTS
mt_steel:
        LDA #T_STEEL
        RTS
mt_wall:
        LDA #T_WALL
        RTS
mt_dirt:
        LDA #T_DIRT
        RTS
mt_boulder:
        LDA #T_BOULDER
        RTS
mt_gem:
        LDA #T_GEM
        RTS
mt_firefly:
        LDA #T_FIREFLY+3    ; facing left
        RTS
mt_player:
        LDA scan_row
        STA prow
        STY pcol
        LDA #T_PLAYER
        RTS
mt_exit:
        LDA scan_row
        STA exit_row
        STY exit_col
        LDA #T_EXIT
        RTS

; The clock: one second less every 50 frames, beeping for the last ten.
clock:
        DEC second
        BNE ck_done
        LDA #50
        STA second
        SED
        LDA time
        SEC
        SBC #1
        STA time
        LDA time+1
        SBC #0
        STA time+1
        CLD
        JSR show_time
        LDA time+1
        BNE ck_done
        LDA time
        BEQ ck_out
        CMP #$10
        BCS ck_done
        LDA #SFX_BEEP       ; under ten seconds left
        LDX #2
        JMP sfx_play
ck_out:
        JMP kill_player     ; out of time
ck_done:
        RTS

; Reached the exit: what is left of the time becomes points, one a second.
time_bonus:
        LDA #SFX_EXIT
        LDX #2
        JSR sfx_play
        LDA #25
        JSR wait_frames
tb_loop:
        LDA time
        ORA time+1
        BEQ tb_done
        SED
        LDA time
        SEC
        SBC #1
        STA time
        LDA time+1
        SBC #0
        STA time+1
        CLD
        LDA #1
        LDX #0
        JSR add_score
        JSR show_time
        LDA #SFX_TICK
        LDX #0
        JSR sfx_play
        JSR wait_frame
        JSR animate
        JMP tb_loop
tb_done:
        LDA #50
        JMP wait_frames

; ===========================================================================
; ANIMATION
; Every gem on screen is the same character, so rewriting that character's
; 8 bytes makes them all sparkle together. The fireflies spin, the open
; exit flashes and the player walks the same way.
; ===========================================================================
animate:
        INC anim
        LDX #BLACK          ; the border flashes white when the exit opens
        LDA flash
        BEQ an_border
        DEC flash
        LDX #WHITE
an_border:
        STX VIC+$20
        LDA anim            ; gems: a new shape every 4 frames
        AND #3
        BNE an_fireflies
        LDA anim
        AND #%00001100      ; 4 shapes, 8 bytes each: (anim / 4 mod 4) x 8
        ASL
        CLC
        ADC #<gem_shapes
        STA src
        LDA #>gem_shapes
        ADC #0
        STA src+1
        LDA #T_GEM
        JSR set_char
        LDA #T_GEM_F
        JSR set_char
an_fireflies:
        LDA anim            ; fireflies: every 2 frames
        AND #1
        BNE an_exit
        LDA anim
        AND #%00000110      ; (anim / 2 mod 4) x 8
        ASL
        ASL
        CLC
        ADC #<firefly_shapes
        STA src
        LDA #>firefly_shapes
        ADC #0
        STA src+1
        LDA #T_FIREFLY      ; the same shape for all 8 firefly characters
        STA anim_char
an_firefly_loop:
        LDA anim_char
        JSR set_char
        INC anim_char
        LDA anim_char
        CMP #T_FIREFLY_M+4
        BNE an_firefly_loop
an_exit:
        LDA #<steel_shape   ; the exit: steel until it opens, then flashing
        STA src
        LDA #>steel_shape
        STA src+1
        LDA exit_open
        BEQ an_exit_set
        LDA anim
        AND #8
        BEQ an_exit_set
        LDA #<door_shape
        STA src
        LDA #>door_shape
        STA src+1
an_exit_set:
        LDA #T_EXIT
        JSR set_char
        LDA facing          ; the player: 3 shapes facing each way
        ASL
        ADC facing          ; x 3
        CLC
        ADC walk
        ASL
        ASL
        ASL                 ; x 8
        CLC
        ADC #<player_shapes
        STA src
        LDA #>player_shapes
        ADC #0
        STA src+1
        LDA #T_PLAYER
        JMP set_char

; Copy 8 bytes from src into the shape of character A.
set_char:
        LDX #0
        STX tmp2
        ASL                 ; A x 8, with the carries going into tmp2
        ROL tmp2
        ASL
        ROL tmp2
        ASL
        ROL tmp2
        STA cptr2
        LDA tmp2
        CLC
        ADC #>CHARSET
        STA cptr2+1
        LDY #7
scr_copy:
        LDA (src),Y
        STA (cptr2),Y
        DEY
        BPL scr_copy
        RTS

; ===========================================================================
; THE PLAYER
; ===========================================================================
; Point ptr and cptr at the screen row above row X, so that row X's cells
; are at offsets 40-79 and the rows above and below at 0-39 and 80-119.
set_row_ptr:
        DEX
        LDA ROW_LO,X
        STA ptr
        STA cptr
        LDA ROW_HI,X
        STA ptr+1
        CLC
        ADC #>(COLORS-SCREEN)
        STA cptr+1
        RTS

move_player:
        LDA dead
        ORA done
        BNE mp_done
        LDX prow
        JSR set_row_ptr
        LDA pcol
        CLC
        ADC #40
        STA here
        LDA joy             ; the direction held now, or else one tapped
        AND #%00001111      ; since the last turn
        BNE mp_which
        LDA joy_latch       ; a tap: fire comes from it too, so that a quick
        STA joy             ; tap of fire and a direction is still a grab
mp_which:
        LDX #0              ; which way? the first of up, down, left, right
mp_find:
        LSR
        BCS mp_dir
        INX
        CPX #4
        BNE mp_find
        LDA #0              ; no direction: stand still
        STA walk
mp_done:
        RTS
mp_dir:
        LDA joy_to_dir,X    ; 0 up, 1 right, 2 down, 3 left
        STA pdir
        TAX
        CPX #1
        BNE mp_not_right
        LDA #0
        STA facing
mp_not_right:
        CPX #3
        BNE mp_target
        LDA #1
        STA facing
mp_target:
        LDA here
        CLC
        ADC dir_offset,X
        STA target          ; the offset of the cell it moves into
        TAY
        LDA (ptr),Y
        CMP #T_DIRT
        BEQ mp_dig
        CMP #T_GEM
        BEQ mp_gem
        CMP #T_GEM_F
        BEQ mp_gem
        TAX
        LDA joy             ; holding fire, the player never moves - not even
        AND #JOY_FIRE       ; into the cell that the last turn's grab emptied
        BNE mp_stay
        CPX #T_EMPTY
        BEQ mp_step
        CPX #T_EXIT
        BEQ mp_exit
        CPX #T_BOULDER
        BEQ mp_push
mp_stay:
        RTS                 ; anything else is in the way
mp_dig:
        LDA #SFX_DIG
        LDX #0
        JSR sfx_play
        JMP mp_take
mp_gem:
        JSR collect_gem
mp_take:
        LDA joy             ; holding fire? grab it without moving
        AND #JOY_FIRE
        BEQ mp_step
        LDY target
        LDA #T_EMPTY
        JMP put_tile
mp_exit:
        LDA exit_open
        BEQ mp_blocked
        LDA #1
        STA done
        JMP mp_step
mp_push:
        LDX pdir            ; boulders can only be pushed sideways...
        TXA
        AND #1
        BEQ mp_blocked
        LDA target
        CLC
        ADC dir_offset,X
        TAY
        LDA (ptr),Y
        CMP #T_EMPTY        ; ...into an empty space
        BNE mp_blocked
        LDA #T_BOULDER
        JSR put_tile
        LDA #SFX_PUSH
        LDX #0
        JSR sfx_play
mp_step:
        LDY here            ; leave the old cell...
        LDA #T_EMPTY
        JSR put_tile
        LDY target          ; ...and step into the new one
        LDA #T_PLAYER
        JSR put_tile
        LDX pdir
        LDA prow
        CLC
        ADC dir_row,X
        STA prow
        LDA pcol
        CLC
        ADC dir_col,X
        STA pcol
        LDA walk            ; walking: alternate shapes 1 and 2
        EOR #3
        CMP #3
        BNE mp_walk
        LDA #1
mp_walk:
        STA walk
mp_blocked:
        RTS

collect_gem:
        SED
        LDA gems_got
        CLC
        ADC #1
        STA gems_got
        CLD
        LDA gem_value
        LDX #0
        JSR add_score
        JSR show_gems
        LDA #SFX_GEM
        LDX #1
        JSR sfx_play
        LDA gems_got
        CMP gems_needed
        BNE cg_done
        LDA #1              ; enough: open the exit
        STA exit_open
        LDA #$20
        STA gem_value       ; from now on gems are worth double
        LDX exit_row
        LDA ROW_LO,X
        STA src
        LDA ROW_HI,X
        CLC
        ADC #>(COLORS-SCREEN)
        STA src+1
        LDY exit_col
        LDA #WHITE
        STA (src),Y
        LDA #6
        STA flash           ; flash the border
        LDA #SFX_OPEN
        LDX #2
        JSR sfx_play
cg_done:
        RTS

; Blow the player up, wherever they are.
kill_player:
        LDA dead
        BNE kp_done
        LDX prow
        JSR set_row_ptr
        LDA #0              ; this is never in the middle of a scan (see
        STA here            ; EXPLODE)
        LDA pcol
        CLC
        ADC #40
        JMP explode
kp_done:
        RTS

; ===========================================================================
; THE CAVE SCAN
; Once a turn, every cell inside the cave is looked at, from the bottom row
; up and left to right. Only tiles with bit 7 set can move, so most cells
; cost one LDA and one BMI. A moving tile's routine is found in a table.
; ===========================================================================
scan_cave:
        LDA #CAVE_TOP+CAVE_ROWS-2
        STA scan_row        ; the bottom row inside the border
sc_scan_row:
        LDX scan_row
        JSR set_row_ptr
        LDY #41             ; 40 + column 1
sc_scan_cell:
        LDA (ptr),Y
        BMI sc_active
sc_scan_next:
        INY
        CPY #40+39
        BNE sc_scan_cell
        DEC scan_row
        LDA scan_row
        CMP #CAVE_TOP+1
        BCS sc_scan_row
        RTS
sc_active:
        STY here
        STA tile
        CMP #T_EXPLODE_M+1  ; not a tile we know? leave it alone
        BCS sc_scan_next
        AND #$7F            ; the tile's number in the jump table
        ASL
        TAX
        LDA tile_handlers,X
        STA jump
        LDA tile_handlers+1,X
        STA jump+1
        JSR sc_jump
        LDY here
        JMP sc_scan_next
sc_jump:
        JMP (jump)          ; JMP indirect: jump to the address stored at jump

; The routine for each moving tile, in tile order from 128.
tile_handlers:
        WORD resting, resting                   ; boulder, gem
        WORD falling, falling                   ; falling boulder, falling gem
        WORD firefly, firefly, firefly, firefly ; facing up, right, down, left
        WORD moved, moved, moved, moved         ; fireflies that moved already
        WORD burning, burning, burning          ; explosion
        WORD lit                                ; explosion, just set off

; A boulder or gem at rest: it falls if the cell below is empty, and rolls
; off anything round if there is room to one side.
resting:
        LDA here
        CLC
        ADC #40
        TAY
        LDA (ptr),Y         ; the cell below
        CMP #T_EMPTY
        BNE re_round
        LDA tile            ; empty: start falling
        CLC
        ADC #TO_FALLING
        JMP move_down
re_round:
        CMP #T_BOULDER
        BEQ re_roll
        CMP #T_GEM
        BEQ re_roll
        CMP #T_WALL
        BEQ re_roll
        RTS
re_roll:
        LDY here            ; to the left: the cell and the one below it empty?
        DEY
        LDA (ptr),Y
        CMP #T_EMPTY
        BNE re_right
        TYA
        CLC
        ADC #40
        TAY
        LDA (ptr),Y
        CMP #T_EMPTY
        BEQ roll_to
re_right:
        LDY here            ; to the right?
        INY
        LDA (ptr),Y
        CMP #T_EMPTY
        BNE re_stay
        TYA
        CLC
        ADC #40
        TAY
        LDA (ptr),Y
        CMP #T_EMPTY
        BEQ roll_to
re_stay:
        RTS
roll_to:                    ; Y = the cell diagonally below: slide into it
        STY tmp
        LDY here
        LDA #T_EMPTY
        JSR put_tile
        LDY tmp
        LDA tile
        CLC
        ADC #TO_FALLING
        JMP put_tile

; A falling boulder or gem keeps falling, crushes what it lands on, or
; comes to rest.
falling:
        LDA here
        CLC
        ADC #40
        TAY
        LDA (ptr),Y
        CMP #T_EMPTY
        BNE fa_landed
        LDA tile
        JMP move_down
fa_landed:
        CMP #T_PLAYER       ; squashed!
        BEQ fa_explode
        CMP #T_FIREFLY
        BCC fa_rest
        CMP #T_FIREFLY_M+4
        BCS fa_rest
fa_explode:
        TYA                 ; explode where it landed
        JMP explode
fa_rest:
        LDA tile
        SEC
        SBC #TO_FALLING
        LDY here
        JSR put_tile
        LDA #SFX_THUD       ; a thud for a boulder...
        LDX tile
        CPX #T_GEM_F
        BNE fa_sound
        LDA #SFX_PING       ; ...a ping for a gem
fa_sound:
        LDX #1
        JMP sfx_play

; Move the tile in A down one cell. The row below has already been
; scanned this turn, so it will not move again until the next one.
move_down:
        PHA
        LDY here
        LDA #T_EMPTY
        JSR put_tile
        LDA here
        CLC
        ADC #40
        TAY
        PLA
        JMP put_tile

; A firefly follows the wall on its left: turn left if it can, else go
; straight on, else turn right. Touching the player sets it off.
firefly:
        LDX #3              ; is the player next to it?
ff_look:
        LDA here
        CLC
        ADC dir_offset,X
        TAY
        LDA (ptr),Y
        CMP #T_PLAYER
        BNE ff_look_next
        LDA here
        JMP explode
ff_look_next:
        DEX
        BPL ff_look
        LDA tile
        SEC
        SBC #T_FIREFLY
        STA tmp2            ; the way it is facing
        CLC
        ADC #3              ; turning left is 3 turns right
        AND #3
        JSR ff_try
        BCS ff_done
        LDA tmp2            ; straight on
        JSR ff_try
        BCS ff_done
        LDA tmp2            ; turn right, without moving
        CLC
        ADC #1
        AND #3
        CLC
        ADC #T_FIREFLY
        LDY here
        JMP put_tile
ff_done:
        RTS

; Move the firefly in direction A if that cell is empty. Carry set if it
; moved. Moving up or right takes it into a cell still to be scanned this
; turn, so it is marked as moved there.
ff_try:
        STA ff_dir
        TAX
        LDA here
        CLC
        ADC dir_offset,X
        STA target
        TAY
        LDA (ptr),Y
        CMP #T_EMPTY
        BNE ff_no
        LDY here            ; A is T_EMPTY: leave the old cell
        JSR put_tile
        LDA ff_dir
        CLC
        ADC #T_FIREFLY
        LDX ff_dir
        CPX #2              ; up (0) or right (1)?
        BCS ff_put
        ADC #T_FIREFLY_M-T_FIREFLY
ff_put:
        LDY target
        JSR put_tile
        SEC
        RTS
ff_no:
        CLC
        RTS

; A firefly that already moved this turn: unmark it and leave it be.
moved:
        LDA tile
        SEC
        SBC #T_FIREFLY_M-T_FIREFLY
        LDY here
        JMP put_tile

; Explosions burn through three shapes, then leave an empty cell.
burning:
        LDA tile
        CMP #T_EXPLODE+2
        BCS bu_out
        ADC #1
        LDY here
        JMP put_tile
bu_out:
        LDA #T_EMPTY
        LDY here
        JMP put_tile

; An explosion set off this turn, in a cell the scan had still to reach:
; unmark it, so that it burns in step with the rest of the explosion.
lit:
        LDA #T_EXPLODE
        LDY here
        JMP put_tile

; Explode the 3 x 3 cells around the cell at offset A from ptr: everything
; but steel walls and the exit is blown away, including the player.
; In the middle of a scan, the cells it has still to reach this turn - the
; row above the one scanned, and the cells right of HERE - are marked, as a
; firefly moving there is: otherwise the scan would burn them a turn ahead
; of the rest. HERE is 0 when no scan is under way.
explode:
        SEC
        SBC #41             ; the top left cell
        STA tmp
        LDA #3
        STA tmp2            ; rows to go
ex_row:
        LDX #3
        LDY tmp
ex_cell:
        LDA (ptr),Y
        CMP #T_STEEL
        BEQ ex_next
        CMP #T_EXIT         ; without it the cave could not be finished
        BEQ ex_next
        CMP #T_PLAYER
        BNE ex_blow
        LDA #100            ; the player is caught in it
        STA dead
ex_blow:
        STX ex_count
        LDX #T_EXPLODE
        LDA here
        BEQ ex_put          ; no scan under way
        CPY #40
        BCC ex_ahead        ; the row above the one scanned
        CPY #80
        BCS ex_put          ; the rows below it
        CPY here
        BCC ex_put
        BEQ ex_put          ; HERE, or left of it
ex_ahead:
        LDX #T_EXPLODE_M
ex_put:
        TXA
        JSR put_tile
        LDX ex_count
ex_next:
        INY
        DEX
        BNE ex_cell
        LDA tmp
        CLC
        ADC #40
        STA tmp
        DEC tmp2
        BNE ex_row
        LDA #SFX_BOOM
        LDX #2
        JMP sfx_play

; Put tile A in the cell at offset Y from ptr, with its colour.
put_tile:
        STA (ptr),Y
        TAX
        BMI pt_moving
        CMP #T_DIRT
        BCC pt_done         ; a space: its colour does not matter
        LDA still_colors-T_DIRT,X
        STA (cptr),Y
pt_done:
        RTS
pt_moving:
        LDA moving_colors-T_BOULDER,X
        STA (cptr),Y
        RTS

; ===========================================================================
; SCORE AND STATUS
; ===========================================================================
add_score:                  ; score += A (tens and units) + X (thousands and hundreds), in BCD
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
show_score:
        LDX #score+2
        LDY #34
        LDA #3
        ; fall through to print_bcd

; Print A bytes of BCD on the top line at column Y, from the zero-page
; byte at X downwards: two digits per byte.
print_bcd:
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

show_gems:
        LDX #gems_got
        LDY #5
        LDA #1
        JSR print_bcd
        LDX #gems_needed
        LDY #8
        LDA #1
        JMP print_bcd

show_time:                  ; three digits: the last of the high byte, then the low byte
        LDA time+1
        AND #$0F
        ORA #$30
        STA SCREEN+21
        LDX #time
        LDY #22
        LDA #1
        JMP print_bcd

show_lives:
        LDA lives
        ORA #$30
        STA SCREEN+40+39
        LDA #WHITE
        STA COLORS+40+39
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
        LDA #T_EMPTY
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
        BNE cs_loop
        STX flash
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

; Copy letters and digits (screen codes 0-63) from the character ROM,
; which appears at $D000 when bit 2 of $01 is cleared.
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

; PRINT a message at A (low) / X (high): row, column, colour, text, zero.
; PRINT_LIST prints messages until a row of $FF.
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

print:
        STA src
        STX src+1
print_here:
        LDY #0
        LDA (src),Y         ; row
        TAX
        INY
        LDA (src),Y         ; column
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
        LDA (src),Y         ; colour
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
        AND #$3F            ; PETSCII to screen code
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
; SOUND EFFECTS - see Alien Armada for how this little driver works
; ===========================================================================
init_sid:
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
        LDA #15
        STA SID+$18
        RTS

sfx_play:                   ; effect A (offset in SFX_TABLE) on voice X
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
        LDX #2
su_voice:
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
        BEQ su_next
        DEC sfx_time,X
        BNE su_slide
        LDA sfx_wave,X
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
voice_regs:     BYTE 0, 7, 14
; Directions, clockwise from up: how far to the next cell, row and column
dir_offset:     BYTE -40, 1, 40, -1
dir_row:        BYTE -1, 0, 1, 0
dir_col:        BYTE 0, 1, 0, -1
joy_to_dir:     BYTE 0, 2, 3, 1     ; joystick up, down, left, right

still_colors:   BYTE ORANGE, LIGHT_RED, LIGHT_BLUE, LIGHT_BLUE, WHITE
                ;    dirt    wall       steel       exit        player
moving_colors:  BYTE LIGHT_GREY, CYAN, LIGHT_GREY, CYAN
                BYTE YELLOW, YELLOW, YELLOW, YELLOW, YELLOW, YELLOW, YELLOW, YELLOW
                BYTE WHITE, YELLOW, ORANGE, WHITE

title_key_row:  BYTE 7, 9, 11, 13, 15
title_key_tile: BYTE T_PLAYER, T_GEM, T_BOULDER, T_FIREFLY, T_EXIT

status_text:
        BYTE 0, 0, WHITE
        ASCIIZ "GEMS 00/00      TIME 000    SCORE 000000"
over_text:
        BYTE 12, 14, WHITE
        ASCIIZ " GAME OVER "    ; the spaces clear the cave either side of it
lives_text:
        BYTE 1, 33, WHITE
        ASCIIZ "LIVES"
title_text:
        BYTE 3, 12, YELLOW
        ASCIIZ "R O C K F A L L"
        BYTE 7, 14, WHITE
        ASCIIZ "THIS IS YOU"
        BYTE 9, 14, CYAN
        ASCIIZ "GRAB THE GEMS"
        BYTE 11, 14, LIGHT_GREY
        ASCIIZ "MIND THE BOULDERS"
        BYTE 13, 14, YELLOW
        ASCIIZ "AVOID THE FIREFLIES"
        BYTE 15, 14, LIGHT_BLUE
        ASCIIZ "THEN FIND THE EXIT"
        BYTE 18, 2, GREY
        ASCIIZ "FIRE + DIRECTION GRABS WITHOUT MOVING"
        BYTE 20, 11, WHITE
        ASCIIZ "PRESS FIRE TO PLAY"
        BYTE 22, 11, GREY
        ASCIIZ "JOYSTICK IN PORT 2"
        BYTE 0, 0, WHITE
        ASCIIZ "SCORE"
        BYTE 0, 25, WHITE
        ASCIIZ "HI-SCORE"
        BYTE $FF

; Row 1 of the screen while playing: "CAVE n" and the cave's name.
name_text:
        BYTE 1, 0, LIGHT_BLUE
        TEXT "CAVE 1  "
        TEXT "                             "
        BYTE 0

; ---------------------------------------------------------------------------
; Sound effects: waveform, attack/decay, sustain/release, frequency low,
; high, change per frame low, high, length in frames.
; ---------------------------------------------------------------------------
SFX_DIG   = 0
SFX_GEM   = 8
SFX_PUSH  = 16
SFX_THUD  = 24
SFX_PING  = 32
SFX_BOOM  = 40
SFX_OPEN  = 48
SFX_BEEP  = 56
SFX_TICK  = 64
SFX_NEW_CAVE = 72
SFX_EXIT  = 80
sfx_table:
        BYTE 128, $02, $00, $00, $18, $00, $00, 2    ; dig: a crunch of noise
        BYTE 16,  $09, $00, $00, $48, $00, $03, 8    ; gem: a rising ting
        BYTE 128, $03, $00, $00, $06, $00, $00, 3    ; push: a low scrape
        BYTE 128, $04, $00, $00, $0A, $80, $FF, 4    ; boulder lands: thud
        BYTE 16,  $06, $00, $00, $60, $00, $00, 3    ; gem lands: ping
        BYTE 128, $0A, $00, $00, $20, $A0, $FF, 40   ; explosion
        BYTE 64,  $00, $F6, $00, $10, $80, $02, 30   ; the exit opens
        BYTE 64,  $04, $00, $00, $38, $00, $00, 4    ; time running out
        BYTE 16,  $01, $00, $00, $50, $00, $00, 1    ; bonus tick
        BYTE 16,  $00, $F8, $00, $0C, $00, $01, 24   ; a new cave
        BYTE 32,  $00, $F8, $00, $18, $00, $04, 20   ; out through the exit

; ---------------------------------------------------------------------------
; Shapes that ANIMATE copies into the character set
; ---------------------------------------------------------------------------
gem_shapes:
        BYTE %00011000,%00111100,%01111110,%11111111,%01111110,%00111100,%00011000,%00000000
        BYTE %00011000,%00100100,%01011010,%10111101,%01011010,%00100100,%00011000,%00000000
        BYTE %00011000,%00111100,%01100110,%11000011,%01100110,%00111100,%00011000,%00000000
        BYTE %00011000,%00100100,%01000010,%10011001,%01000010,%00100100,%00011000,%00000000
firefly_shapes:
        BYTE %11111111,%10000001,%10111101,%10100101,%10100101,%10111101,%10000001,%11111111
        BYTE %00011000,%00100100,%01011010,%10100101,%10100101,%01011010,%00100100,%00011000
        BYTE %00000000,%01111110,%01000010,%01011010,%01011010,%01000010,%01111110,%00000000
        BYTE %00011000,%00100100,%01011010,%10100101,%10100101,%01011010,%00100100,%00011000
steel_shape:
        BYTE %11111111,%10000001,%10100101,%10000001,%10000001,%10100101,%10000001,%11111111
door_shape:
        BYTE %11111111,%11000011,%10111101,%10100101,%10100101,%10100101,%10111101,%11111111
player_shapes:
        ; facing right: standing, then two steps
        BYTE %00111100,%01111110,%00011000,%00111100,%01011010,%00011000,%00100100,%01100110
        BYTE %00011110,%00111111,%00001100,%00011100,%00111110,%00011000,%00110100,%01100010
        BYTE %00011110,%00111111,%00001100,%00011100,%00011110,%00011000,%00010100,%00011000
        ; facing left: the same, mirrored
        BYTE %00111100,%01111110,%00011000,%00111100,%01011010,%00011000,%00100100,%01100110
        BYTE %01111000,%11111100,%00110000,%00111000,%01111100,%00011000,%00101100,%01000110
        BYTE %01111000,%11111100,%00110000,%00111000,%01111000,%00011000,%00101000,%00011000

; ===========================================================================
; CAVES
; Each cave: the gems needed (BCD), the time in seconds (BCD), its name,
; then 22 rows of 40 characters:
;   #  steel wall     =  brick wall    .  dirt       (space) empty
;   O  boulder        *  gem           F  firefly    P  you    X  exit
; ===========================================================================
cave_list:
        WORD cave_1, cave_2, cave_3, cave_4

cave_1:
        BYTE $10
        WORD $0150
        ASCIIZ "THE FIRST DIG"
        TEXT "########################################"
        TEXT "#P....O.....*.......O.......*......O...#"
        TEXT "#.......O.......*......O......O....*...#"
        TEXT "#..*..O....=====....O....*.......O.....#"
        TEXT "#.....O..*......O.......O....*.....O...#"
        TEXT "#.*...........*....*..O.......O........#"
        TEXT "#....O...O.......=====......*....*..O..#"
        TEXT "#..O...*....O..............O......*....#"
        TEXT "#......O...*....O...*...O.....O........#"
        TEXT "#.*........O........O......*.......O...#"
        TEXT "#....O..*.....*.......O.........*......#"
        TEXT "#..O......=====...O.......*...O....*...#"
        TEXT "#.....*.......O........O.........O.....#"
        TEXT "#.O.....O.........*......O..*......O...#"
        TEXT "#....*......*...O....=====.......*.....#"
        TEXT "#..O.....O.......*.........O.....O.....#"
        TEXT "#......*....O..........*.......*....O..#"
        TEXT "#.O.........*.....O.......O..........*.#"
        TEXT "#....O..*.......O.....*.......O....X...#"
        TEXT "#..*......O..........O......*..........#"
        TEXT "#......O.....*....O.......*.......O....#"
        TEXT "########################################"

cave_2:
        BYTE $15
        WORD $0120
        ASCIIZ "BOULDER ALLEY"
        TEXT "########################################"
        TEXT "#P...O.O.O.O.....O.O.O.O.....O.O.O.O...#"
        TEXT "#....*.*.*.*.....*.*.*.*.....*.*.*.*...#"
        TEXT "#....=======.....=======.....=======...#"
        TEXT "#......................................#"
        TEXT "#.OOO........OOO.........OOO.......OOO.#"
        TEXT "#.***........***.........***.......***.#"
        TEXT "#.===........===.........===.......===.#"
        TEXT "#......................................#"
        TEXT "#...O...O...O...O...O...O...O...O...O..#"
        TEXT "#..                                  ..#"
        TEXT "#..=================  ===============..#"
        TEXT "#......*.......*..........*.......*....#"
        TEXT "#..O.....O.........O.........O......O..#"
        TEXT "#.....*.....*..........*........*......#"
        TEXT "#.O.......O......O..........O.......O..#"
        TEXT "#....*........*.......*........*.......#"
        TEXT "#..O....O.........O........O......O....#"
        TEXT "#.........*...........*.........*......#"
        TEXT "#....O.........O.........O........X....#"
        TEXT "#..*......*.........*.........*........#"
        TEXT "########################################"

cave_3:
        BYTE $12
        WORD $0150
        ASCIIZ "FIREFLY FIELDS"
        TEXT "########################################"
        TEXT "#P..*....O....O....*.....O....O....*...#"
        TEXT "#.....O....*.....O....O....*.....O.....#"
        TEXT "#...O...O.....O....O.....O....O....O...#"
        TEXT "#..=========..=========..=========.....#"
        TEXT "#..=   *   =..=   *   =..=   *   =..O..#"
        TEXT "#..=  F    =..=  F    =..=  F    =.....#"
        TEXT "#..=   *   =..=   *   =..=   *   =..*..#"
        TEXT "#..=========..=========..=========.....#"
        TEXT "#.....*.........*..........*......O....#"
        TEXT "#..O......O.........O.........O......*.#"
        TEXT "#.....*.......O........*.........O.....#"
        TEXT "#..=========....O.....=========........#"
        TEXT "#..=  *  * =..........=  *  * =...O....#"
        TEXT "#..=   F   =...*..O...=   F   =........#"
        TEXT "#..=  *  * =..........=  *  * =....*...#"
        TEXT "#..=========...O......=========........#"
        TEXT "#....*.......O......*.........O....O...#"
        TEXT "#..O......*.......O.......*...........X#"
        TEXT "#......O.......*.......O......*....*...#"
        TEXT "#..*.......O.......*.......O...........#"
        TEXT "########################################"

cave_4:
        BYTE $20
        WORD $0180
        ASCIIZ "THE VAULT"
        TEXT "########################################"
        TEXT "#P.....O......O.......O.......O.......X#"
        TEXT "#..O......*......*........*.......O....#"
        TEXT "#.....=====.......=====.......=====....#"
        TEXT "#..O..=***=...O...=***=...O...=***=..O.#"
        TEXT "#.....=***=.......=***=.......=***=....#"
        TEXT "#.....==.==.......==.==.......==.==....#"
        TEXT "#..*......O....*.......O...*.......O...#"
        TEXT "#....O.........O....O.........O........#"
        TEXT "#.     F      ..........      F      ..#"
        TEXT "#.==========......O.......==========...#"
        TEXT "#....*.....O...*......*.......*....O...#"
        TEXT "#..O....=====....O........=====....*...#"
        TEXT "#......O=***=.........O...=***=O.......#"
        TEXT "#..*....=***=....*........=***=....O...#"
        TEXT "#.......==.==...O....O....==.==........#"
        TEXT "#....O.........*.....*.........O...*...#"
        TEXT "#..*.....O...........O.....*.........O.#"
        TEXT "#......*.....O....*.......O.....O......#"
        TEXT "#..O......*.......O....*......*........#"
        TEXT "#.....O.......*.......O.......*....O...#"
        TEXT "########################################"

; ===========================================================================
; TILES
; 8 bytes each, a line of 8 pixels per byte. The still tiles start at
; screen code 64, the moving ones at 128.
; ===========================================================================
        ORG CHARSET+T_DIRT*8
        BYTE %10110101,%01011010,%11101011,%01010110,%10111101,%11010110,%01101011,%10110101 ; dirt
        BYTE %11111110,%11111110,%11111110,%00000000,%11101111,%11101111,%11101111,%00000000 ; brick wall
        BYTE %11111111,%10000001,%10100101,%10000001,%10000001,%10100101,%10000001,%11111111 ; steel wall
        BYTE %11111111,%10000001,%10100101,%10000001,%10000001,%10100101,%10000001,%11111111 ; the exit
        BYTE %00111100,%01111110,%00011000,%00111100,%01011010,%00011000,%00100100,%01100110 ; you

        ORG CHARSET+T_BOULDER*8
        BYTE %00111100,%01111010,%11111101,%11111111,%11111111,%10111111,%01011110,%00111100 ; boulder
        BYTE %00011000,%00111100,%01111110,%11111111,%01111110,%00111100,%00011000,%00000000 ; gem
        BYTE %00111100,%01111010,%11111101,%11111111,%11111111,%10111111,%01011110,%00111100 ; falling boulder
        BYTE %00011000,%00111100,%01111110,%11111111,%01111110,%00111100,%00011000,%00000000 ; falling gem
        ORG CHARSET+T_EXPLODE*8 ; (the 8 firefly shapes are set by ANIMATE)
        BYTE %01011010,%10111101,%01111110,%11111111,%11111111,%01111110,%10111101,%01011010 ; explosion
        BYTE %10010010,%01010100,%00101000,%11000110,%00101000,%01010100,%10010010,%00000000
        BYTE %10000001,%00000000,%00100100,%00000000,%00000000,%00100100,%00000000,%10000001
        BYTE %01011010,%10111101,%01111110,%11111111,%11111111,%01111110,%10111101,%01011010 ; just set off
