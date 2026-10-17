; KERNAL CHROUT - Print a Character
; $FFD2 is the C64 ROM routine to print
; the character in the A register
    ORG $C000       ; Free RAM BASIC never uses: SYS 49152 runs it
    
    LDA #$48        ; 'H' in PETSCII
    JSR $FFD2       ; Call CHROUT
    
    LDA #$49        ; 'I'
    JSR $FFD2
    
    LDA #$21        ; '!'
    JSR $FFD2
    
    LDA #$0D        ; Carriage return
    JSR $FFD2
    
    RTS