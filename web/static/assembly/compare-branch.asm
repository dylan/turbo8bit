; Compare and Branch
; CPX compares X with a value by subtracting
; It sets flags but doesn't change X
    ORG $C000       ; Free RAM BASIC never uses: SYS 49152 runs it
    
    LDX #$05        ; Start with X = 5

LOOP:
    INX             ; Increment X
    CPX #$10        ; Compare X with 16
    BNE LOOP        ; Branch back if X != 16
    
    ; X is now $10 (16)
    RTS