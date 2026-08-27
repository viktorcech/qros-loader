;=============================================================================
; QROS / EMO turbo tape loader pre Atari XE/XL
;
; Nacita QROS pasku (132-bajtove bloky, SIO ramce cez POKEY seriovy vstup),
; za behu parsuje Atari binarny format (XEX) a spusti program.
; Pocas nahravania ukazuje nazov programu z hlavicky a percenta.
;
; Prekladac: MADS (mads.exe), pozri build_loader.py
;   mads qrosload.asm -d:BOOT=1 ... -o:qrosload.bin   ; surovy blob pre boot
;   mads qrosload.asm -d:BOOT=0 ... -o:qrosload.xex   ; spustitelny XEX
;
; QROS system & SW: Ing. Matus Zubor
; QROS HW ozivenie (2025): Aleister
; Loader: W1K
;
; Hodnoty POKEY registrov overene proti zdrojakom Altirra kernelu
; (Kernel/source/Shared/sio.s, cassette.s, boot.s).
;=============================================================================

; ---- POKEY -----------------------------------------------------------------
AUDF3   = $D204                 ; delic seriovej rychlosti (nizky bajt)
AUDC3   = $D205
AUDF4   = $D206                 ; delic (vysoky bajt)
AUDC4   = $D207
AUDCTL  = $D208
SKRES   = $D20A                 ; reset stavu seriovej linky (zapis)
SERIN   = $D20D                 ; prijaty bajt
IRQEN   = $D20E                 ; povolenie IRQ (zapis)
IRQST   = $D20E                 ; stav IRQ (citanie, aktivne v nule)
SKCTL   = $D20F

; ---- ostatny HW ------------------------------------------------------------
DMACTL  = $D400                 ; riadenie DMA
DLISTL  = $D402                 ; adresa display listu
DLISTH  = $D403
CHBASE  = $D409                 ; sada znakov
COLPF1  = $D017                 ; jas textu
COLPF2  = $D018                 ; pozadie textu
COLBK   = $D01A                 ; okraj (indikacia chyby)
PACTL   = $D302                 ; motor kazety: $34 = zapnuty, $3C = vypnuty
PORTB   = $D301                 ; bit 0 = ROM OS, bit 1 = BASIC,
                                ; bity 2,3,5,6,7 = prepinanie rozsirenych bank
NMIEN   = $D40E

; ---- OS premenne -----------------------------------------------------------
POKMSK  = $0010                 ; tienovy register IRQEN
RUNAD   = $02E0                 ; adresa spustenia programu
INITAD  = $02E2                 ; adresa inicializacie segmentu

; ---- nulta stranka (volne bajty $CB-$D1 na XL/XE) --------------------------
DSTPTR  = $CB                   ; cielovy ukazovatel segmentu (2 B)
SEGLEN  = $CD                   ; zostavajuca dlzka segmentu (2 B)
SEGEND  = $CF                   ; koncova adresa segmentu (2 B)

; ---- parametre z prikazoveho riadku (-d:) ----------------------------------
; BOOT    = 1 -> bootovaci blob pre pasku, 0 -> samostatny XEX
; LOADADR = adresa kodu loadera
; BUFADR  = adresa 132-bajtoveho bloku
; DIVISOR = POKEY delic:  baud = takt / (2 * (DIVISOR + 7))
;           127 -> 6617 baud PAL (rezim "6600"),  86 -> 9535 baud PAL

POKEY_AUDF_6600 = 127           ; delic pre rezim 6600 (6617 baud PAL)
POKEY_AUDF_9600 = 86            ; delic pre rezim 9600 (9535 baud PAL)

NAMECOL = 0                     ; stlpec nazvu programu na 1. riadku
PCTCOL  = 36                    ; stlpec percent

; Chybove farby pozadia
ERR_SYNC  = $34                 ; cervena  - na paske nie je platny XEX
ERR_BLOCK = $24                 ; oranzova - blok sa neda precitat / chyba
ERR_NORUN = $B4                 ; zelena   - chyba RUN adresa ($02E0)
ERR_COLL  = $84                 ; modra    - program prepisuje loader

; Prva stranka za loaderom - koniec chranenej oblasti BUFADR .. bin_end-1
PROT_END = [[bin_end - 1] / 256] + 1

    .if BOOT = 0
    opt h+
    .else
    opt h-
    .endif

    org LOADADR

;=============================================================================
; Bootovacia hlavicka (6 bajtov).
; OS ju precita z prveho zaznamu pasky, nacita `records` x 128 bajtov na
; LOADADR, skopiruje init vektor do CASINI a skoci na LOADADR+6.
; V XEX zostaveni je neskodna - len sa nahra do pamate.
;=============================================================================
    dta $00                                 ; priznaky
    dta [[bin_end - LOADADR + 127] / 128]   ; pocet 128-bajtovych zaznamov
    dta a(LOADADR)                          ; adresa nahrania
    dta a(stub_rts)                         ; init vektor -> CASINI

;=============================================================================
; Vstupny bod (LOADADR + 6)
;=============================================================================
entry:
    sei
    cld
    ldx #$FF
    txs

    lda #0
    sta NMIEN                   ; ziadne DLI/VBI pocas prenosu

; --- POKEY: asynchronny seriovy prijem --------------------------------------
    lda #$28                    ; kanaly 3+4 spojene, kanal 3 na 1.79 MHz
    sta AUDCTL
    lda #$A0                    ; ciste tony, hlasitost 0
    sta AUDC3
    sta AUDC4
    lda baudiv                  ; prva skusana rychlost (dopisatelna)
    sta baudtab
    lda baudiv+1
    sta baudtab+1
    lda baudiv                  ; druha je ta zvysna bezna QROS rychlost
    cmp #POKEY_AUDF_9600
    bne bi_alt_9600
    lda #POKEY_AUDF_6600
    bne bi_alt_store
bi_alt_9600:
    lda #POKEY_AUDF_9600
bi_alt_store:
    sta baudtab+2
    lda #0
    sta baudtab+3
    sta baudidx

    jsr set_baud                ; delic, SKCTL, SKRES aj IRQEN naraz
                                ; (druhy zapis IRQEN by zahodil prijimany bajt)

; --- motor kazety zapnut ----------------------------------------------------
    lda #$34
    sta PACTL

; --- vynulovanie stavu ------------------------------------------------------
    lda #0
    sta bufpos
    sta bufcnt
    sta collide
    sta exp_hi
    sta name_shown
    sta pct
    sta acc
    sta acc+1
    lda #2                      ; datove bloky zacinaju indexom 2
    sta exp_lo

    lda total_blk               ; ak pozname celu pasku, percenta su globalne
    sta pgtot
    lda total_blk+1
    sta pgtot+1

    lda #<stub_rts              ; INITAD na neutralne RTS
    sta INITAD
    lda #>stub_rts
    sta INITAD+1
    lda #<no_run                ; RUNAD na hlasenie "chyba RUN"
    sta RUNAD
    lda #>no_run
    sta RUNAD+1

    jsr screen_init

;=============================================================================
; Parser Atari binarneho formatu (streamovany priamo z pasky)
;=============================================================================
    jsr getbyte                 ; povinna hlavicka FF FF
    jcs e_sync
    cmp #$FF
    jne e_sync
    jsr getbyte
    jcs e_sync
    cmp #$FF
    jne e_sync

seg_loop:
    jsr getbyte                 ; zaciatocna adresa segmentu
    jcs load_done               ; korektny koniec medzi segmentmi
    sta DSTPTR
    jsr getbyte
    jcs e_sync
    sta DSTPTR+1

    and DSTPTR                  ; $FFFF = dalsia (volitelna) FF FF hlavicka
    cmp #$FF
    beq seg_loop

    jsr getbyte                 ; koncova adresa segmentu
    jcs e_sync
    sta SEGEND
    jsr getbyte
    jcs e_sync
    sta SEGEND+1

    sec                         ; SEGLEN = end - start + 1
    lda SEGEND
    sbc DSTPTR
    sta SEGLEN
    lda SEGEND+1
    sbc DSTPTR+1
    sta SEGLEN+1
    jcc e_sync                  ; end < start -> poskodeny subor
    inc SEGLEN
    bne seg_ready
    inc SEGLEN+1
seg_ready:
    jsr setup_progress          ; percenta pocitame z dlzky segmentu

copy_loop:
    lda SEGLEN                  ; hotovo, ked SEGLEN = 0
    ora SEGLEN+1
    beq seg_done

    jsr getbyte
    jcs e_sync                  ; koniec pasky uprostred segmentu

    ldx DSTPTR+1                ; nesmieme prepisat sameho seba
    cpx #>BUFADR                ; pod chranenou oblastou -> zapis
    bcc store_ok
    cpx #PROT_END               ; nad nou -> tiez zapis
    bcc protected
store_ok:
    ldy #0
    sta (DSTPTR),y
    jmp advance
protected:
    inc collide

advance:
    inc DSTPTR
    bne dec_len
    inc DSTPTR+1
dec_len:
    lda SEGLEN
    bne dec_lo
    dec SEGLEN+1
dec_lo:
    dec SEGLEN
    jmp copy_loop

;-----------------------------------------------------------------------------
; Segment nacitany - ak sa zmenil INITAD, zavolame ho (rovnako ako DOS)
;-----------------------------------------------------------------------------
seg_done:
    lda INITAD
    cmp #<stub_rts
    bne do_init
    lda INITAD+1
    cmp #>stub_rts
    jeq seg_loop

do_init:
    jsr call_init
    lda #<stub_rts
    sta INITAD
    lda #>stub_rts
    sta INITAD+1
    jmp seg_loop

call_init:
    jmp (INITAD)
stub_rts:
    rts

;=============================================================================
; Koniec nahravania - motor stop, obnovenie prostredia, spustenie programu
;=============================================================================
load_done:
    lda #100                    ; dokoncene
    sta pct
    jsr show_progress

    lda #$3C                    ; motor vypnut
    sta PACTL
    lda #0
    sta AUDC3
    sta AUDC4

    lda collide
    jne e_coll

; Program mohol pocas nahravania prepnut PORTB (rozsirena pamat, vypnuta ROM
; OS). Prerusenia zapneme len ak je ROM OS este na mieste - inak by vektory
; na $FFFA/$FFFE ukazovali do RAM a stroj by spadol.
    lda PORTB
    and #$01
    beq ld_no_irq

    lda #$C0                    ; obvykle IRQ (BREAK + klavesnica)
    sta POKMSK
    sta IRQEN
    lda #$40                    ; VBI spat
    sta NMIEN
    cli

ld_no_irq:
    jmp (RUNAD)

no_run:
    ldx #2
    lda #ERR_NORUN
    jmp halt

e_sync:
    ldx #0
    lda #ERR_SYNC
    jmp halt

e_block:
    ldx #1
    lda #ERR_BLOCK
    jmp halt

e_coll:
    ldx #3
    lda #ERR_COLL

; halt - X = index chyboveho textu, A = farba okraja
halt:
    sta halt_col
    stx halt_idx

    lda #$3C                    ; motor vypnut
    sta PACTL
    lda #0
    sta AUDC3
    sta AUDC4

    lda scr_ok                  ; vypiseme text chyby na nas riadok
    beq halt_loop
    ldy #39
    lda #0
hl_clear:
    sta scrline,y
    dey
    bpl hl_clear

    ldx halt_idx
    lda msg_lo,x
    sta hl_load+1
    lda msg_hi,x
    sta hl_load+2
    ldy #0
hl_copy:
hl_load:
    lda a:$0000,y
    beq halt_loop
    sty hl_y
    jsr a2s                     ; texty su v ATASCII
    ldy hl_y
    sta scrline,y
    iny
    cpy #40
    bne hl_copy

halt_loop:
    lda halt_col
    sta COLBK
    jmp halt_loop

; --- chybove texty (ATASCII, ukoncene nulou) --------------------------------
msg_lo  dta <msg_sync, <msg_block, <msg_norun, <msg_coll
msg_hi  dta >msg_sync, >msg_block, >msg_norun, >msg_coll

msg_sync    dta c'CHYBA - NA PASKE NIE JE XEX', 0
msg_block   dta c'CHYBA - NECITATELNY BLOK', 0
msg_norun   dta c'CHYBA - CHYBA RUN ADRESA', 0
msg_coll    dta c'CHYBA - PROGRAM PREPISUJE LOADER', 0

;=============================================================================
; getbyte - dalsi datovy bajt XEX prudu
; Vystup: A = bajt, C=0.  C=1 = koniec suboru (EOF blok).
; Nici: X
;=============================================================================
getbyte:
    ldx bufpos
    cpx bufcnt
    bcc gb_have

    jsr next_block
    bcs gb_eof
    ldx bufpos

gb_have:
    lda BUFADR+3,x
    inc bufpos
    clc
    rts

gb_eof:
    sec
    rts

;=============================================================================
; next_block - nacita dalsi POUZITELNY datovy blok do buffra
; Vystup: C=0 blok pripraveny (bufpos=0, bufcnt=pocet platnych bajtov)
;         C=1 nacitany koncovy blok
;=============================================================================
next_block:
    lda #16                     ; pocet povolenych opakovani
    sta retries

nb_next:
    jsr read_block
    bcs nb_bad                  ; timeout alebo zly kontrolny sucet

    lda BUFADR+2
    cmp #$FE
    beq nb_eof
    cmp #$FC
    beq nb_index
    cmp #$FA
    beq nb_index
    cmp #$FD
    beq nb_header
    cmp #$FF
    beq nb_next                 ; nastavovaci blok len preskocime

; Blok sa necita alebo mu nerozumieme. Skusime druhu rychlost - takto loader
; zvladne 6600 aj 9600 pasku bez samostatneho buildu. Pocet pokusov je
; obmedzeny, aby sa nikdy nezacyklil.
nb_bad:
    jsr next_baud
    dec retries
    bne nb_next
    jmp e_block

nb_header:
    jsr show_name               ; hlavicka - vypiseme nazov programu
    jmp nb_next

; --- kontrola poradia bloku -------------------------------------------------
nb_index:
    ldx BUFADR+1                ; nizky bajt indexu
    cpx exp_lo
    bne nb_bad
    ldx BUFADR
    cpx exp_hi
    bne nb_bad

    inc exp_lo
    bne nb_len
    inc exp_hi

nb_len:
    ldx #128                    ; uplny blok
    cmp #$FC
    beq nb_store
    ldx BUFADR+130              ; neuplny blok - pocet platnych v poslednom bajte

nb_store:
    stx bufcnt
    lda #0
    sta bufpos
    jsr bump_progress
    clc
    rts

nb_eof:
    sec
    rts

;=============================================================================
; read_block - nacita 132 bajtov a overi SIO kontrolny sucet
; Vystup: C=0 v poriadku, C=1 timeout alebo zly sucet
;=============================================================================
read_block:
    ldx #0
rb_loop:
    jsr getser                  ; getser zachovava X aj Y
    bcs rb_fail
    sta BUFADR,x
    inx
    cpx #132
    bne rb_loop

    lda #0                      ; sucet s prenosom cez 131 bajtov
    ldx #0
rb_sum:
    clc
    adc BUFADR,x
    adc #0
    inx
    cpx #131
    bne rb_sum

    cmp BUFADR+131
    bne rb_fail
    clc
    rts

rb_fail:
    sec
    rts

;=============================================================================
; set_baud - nastavi POKEY delic podla baudidx a zresetuje seriovu linku
set_baud:
    lda baudidx
    asl
    tax
    lda baudtab,x
    sta AUDF3
    lda baudtab+1,x
    sta AUDF4
    lda #$13                    ; asynchronny prijem odznova
    sta SKCTL
    sta SKRES
    lda #0                      ; a znovuzapnutie zapisovaca IRQ
    sta IRQEN
    lda #$20
    sta IRQEN
    rts

; next_baud - prepne na druhu rychlost z tabulky.
; Loader tak precita pasku 6600 aj 9600 bez samostatneho buildu: prvy blok
; sa nepodari, checksum nesedi a dalsi pokus uz bezi druhou rychlostou.
; Hlavicka sa na paske posiela dvakrat, takze sa zosynchronizuje este pred
; prvym datovym blokom.
next_baud:
    lda baudidx
    eor #1
    sta baudidx
    jmp set_baud

; getser - prijme jeden bajt z POKEY seriovej linky
; Vystup: A = bajt, C=0.  C=1 = timeout.
; X aj Y su zachovane - read_block si v X drzi poziciu v bloku!
;=============================================================================
getser:
    stx save_x
    sty save_y
    lda #12                     ; vonkajsie kolo (staci na IRG 1258 ms)
    sta timeout
    ldy #0
    ldx #0

gs_wait:
    lda IRQST                   ; bit 5 v nule = prijaty bajt
    and #$20
    beq gs_have
    dex
    bne gs_wait
    dey
    bne gs_wait
    dec timeout
    bne gs_wait
    ldx save_x
    ldy save_y
    sec
    rts

gs_have:
    lda SERIN
    pha
    lda #0                      ; vynulovanie a znovuzapnutie zapisovaca IRQ
    sta IRQEN
    lda #$20
    sta IRQEN
    ldx save_x
    ldy save_y
    pla
    clc
    rts

;=============================================================================
; Vypis na obrazovku
;=============================================================================

; screen_init - postavi vlastny display list s jednym textovym riadkom.
; Riadok lezi v chranenej pamati loadera, takze vypis nikdy neprepise
; nahravany program (a program zase neprepise vypis).
screen_init:
    lda #0
    sta DMACTL                  ; DMA von, kym prestavujeme display list

    ldy #39                     ; riadok vyplnime medzerami
    lda #0
si_clr:
    sta scrline,y
    dey
    bpl si_clr

    ldy #3                      ; znacka QROS, kym nepride nazov z pasky
si_label:
    lda label_txt,y
    sta scrline,y
    dey
    bpl si_label

    lda #<dlist
    sta DLISTL
    lda #>dlist
    sta DLISTH
    lda #$E0                    ; sada znakov OS
    sta CHBASE
    lda #$0E                    ; jas textu
    sta COLPF1
    lda #$94                    ; pozadie textu
    sta COLPF2
    lda #$22                    ; DMA: normalna sirka + display list
    sta DMACTL

    lda #1
    sta scr_ok
    jsr show_progress           ; hned ukazeme vychodzi stav
    rts

label_txt   dta $31,$32,$2F,$33 ; "QROS" v obrazovych kodoch

; setup_progress - na zaciatku segmentu urci, z coho pocitame percenta.
; Ak generator dopisal celkovy pocet blokov pasky, percenta su za celu pasku.
; Inak beru dlzku prave nahravaneho segmentu (pri jednosegmentovych hrach
; je to to iste).
setup_progress:
    lda total_blk
    ora total_blk+1
    beq pg_seg
    rts

pg_seg:
    clc                         ; pgtot = (SEGLEN + 127) / 128
    lda SEGLEN
    adc #127
    sta pgtmp
    lda SEGLEN+1
    adc #0
    sta pgtmp+1
    lda pgtmp                   ; posun o 7 doprava = posun o 1 dolava a vyssi bajt
    asl
    lda pgtmp+1
    rol
    sta pgtot
    lda #0
    rol
    sta pgtot+1

    lda #0                      ; percenta pocitame odznova
    sta acc
    sta acc+1
    sta pct
    rts

; putscr - A = obrazovy kod znaku, Y = stlpec nasho riadku
putscr:
    sta scrline,y
    rts

; a2s - prevod ATASCII na obrazovy kod, A = znak
a2s:
    and #$7F
    cmp #$60
    bcs a2s_done
    cmp #$20
    bcc a2s_ctrl
    sec
    sbc #$20
a2s_done:
    rts
a2s_ctrl:
    clc
    adc #$40
    rts

; show_name - 25 znakov nazvu z hlavickoveho bloku (offset $08)
show_name:
    lda scr_ok
    beq sn_ret
    lda name_shown
    bne sn_ret

    ldy #24                     ; prazdny nazov neprepisuje znacku
sn_check:
    lda BUFADR+8,y
    cmp #$20
    bne sn_have
    dey
    bpl sn_check
    rts
sn_have:
    inc name_shown

    ldy #24
sn_loop:
    sty sn_y
    lda BUFADR+8,y
    jsr a2s
    ldy sn_y
    jsr putscr
    ldy sn_y
    dey
    bpl sn_loop
sn_ret:
    rts

; bump_progress - o jeden blok dalej
; Ak pozname celkovy pocet blokov, ukazeme percenta, inak pocitadlo blokov.
bump_progress:
    lda scr_ok
    beq bp_ret

    ldx #3                      ; desiatkove pocitadlo nacitanych blokov
bp_count:
    inc cdig,x
    lda cdig,x
    cmp #10
    bcc bp_counted
    lda #0
    sta cdig,x
    dex
    bpl bp_count
bp_counted:

    lda pgtot                   ; nula = este nevieme z coho ratat percenta
    ora pgtot+1
    bne bp_pct
    jmp show_count

bp_pct:
    clc                         ; acc = acc + 100
    lda acc
    adc #100
    sta acc
    lda acc+1
    adc #0
    sta acc+1

bp_loop:
    lda acc+1                   ; kym acc >= pgtot, uber pgtot a pripocitaj 1
    cmp pgtot+1
    bcc bp_show
    bne bp_sub
    lda acc
    cmp pgtot
    bcc bp_show
bp_sub:
    sec
    lda acc
    sbc pgtot
    sta acc
    lda acc+1
    sbc pgtot+1
    sta acc+1
    inc pct
    jmp bp_loop

bp_show:
    jsr show_pct
bp_ret:
    rts

; show_pct - vypise pct ako tri cislice a znak percenta od stlpca PCTCOL
; show_progress - percenta alebo pocitadlo, podla toho co vieme
show_progress:
    lda scr_ok
    beq sp_ret
    lda pgtot
    ora pgtot+1
    bne show_pct
    jmp show_count

show_pct:
    lda pct
    ldx #0
sp_h:
    cmp #100
    bcc sp_hd
    sbc #100
    inx
    jmp sp_h
sp_hd:
    stx dig0
    ldx #0
sp_t:
    cmp #10
    bcc sp_td
    sbc #10
    inx
    jmp sp_t
sp_td:
    stx dig1
    sta dig2

    lda dig0                    ; stovky (prazdne, ak nula)
    beq sp_h_blank
    ora #$10
    bne sp_h_put
sp_h_blank:
    lda #0
sp_h_put:
    ldy #PCTCOL
    jsr putscr

    lda dig0                    ; desiatky (prazdne, ak cele cislo pod 10)
    ora dig1
    beq sp_t_blank
    lda dig1
    ora #$10
    bne sp_t_put
sp_t_blank:
    lda #0
sp_t_put:
    ldy #PCTCOL+1
    jsr putscr

    lda dig2                    ; jednotky
    ora #$10
    ldy #PCTCOL+2
    jsr putscr

    lda #$05                    ; obrazovy kod znaku percenta
    ldy #PCTCOL+3
    jsr putscr
sp_ret:
    rts

; show_count - vypise pocitadlo blokov ako styri cislice
show_count:
    lda scr_ok
    beq sc_ret
    ldx #0
    ldy #PCTCOL
    lda #1
    sta sc_lead                 ; este sme nevypisali nenulovu cislicu
sc_loop:
    lda cdig,x
    bne sc_digit
    cpx #3                      ; posledna cislica sa vypise vzdy
    beq sc_digit
    lda sc_lead
    beq sc_digit
    lda #0                      ; uvodna nula -> medzera
    bne sc_put
    beq sc_put
sc_digit:
    lda #0
    sta sc_lead
    lda cdig,x
    ora #$10
sc_put:
    sty sc_y
    jsr putscr
    ldy sc_y
    iny
    inx
    cpx #4
    bne sc_loop
sc_ret:
    rts

;=============================================================================
; Premenne
;=============================================================================
bufpos     dta 0                ; pozicia v datovej casti bloku
bufcnt     dta 0                ; pocet platnych bajtov v bloku
exp_lo     dta 0                ; ocakavany index dalsieho bloku
exp_hi     dta 0
retries    dta 0
timeout    dta 0
collide    dta 0                ; program sa pokusil prepisat loader
save_x     dta 0
save_y     dta 0
sn_y       dta 0
scr_ok     dta 0
name_shown dta 0
halt_col   dta 0                ; farba okraja pri chybe
halt_idx   dta 0                ; index chyboveho textu
hl_y       dta 0
pgtot      dta a(0)             ; z coho ratame percenta (bloky)
pgtmp      dta a(0)
baudidx    dta 0                ; ktora rychlost z tabulky sa prave skusa
baudtab    dta a(0), a(0)       ; dva skusane POKEY delice
pct        dta 0
dig0       dta 0
dig1       dta 0
dig2       dta 0
sc_lead    dta 0
sc_y       dta 0
cdig       dta 0,0,0,0          ; desiatkove pocitadlo nacitanych blokov
acc        dta a(0)             ; akumulator percent


; --- vlastny display list: 24 prazdnych riadkov + jeden textovy riadok -------
dlist
    dta $70,$70,$70
    dta $42, a(scrline)
    dta $41, a(dlist)

scrline
    dta 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    dta 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

; Dopisatelne parametre na konci blobu (generator ich meni podla pasky):
;   baudiv    na offsete dlzka-4  - POKEY delic prenosovej rychlosti
;   total_blk na offsete dlzka-2  - pocet datovych blokov (nula = bez percent)
; POZOR: label sa nesmie volat DIVISOR - MADS je case-insensitive a prepisal
; by hodnotu z -d:DIVISOR (adresa labelu namiesto delica).
baudiv     dta a(DIVISOR)
total_blk  dta a(0)

bin_end:

;=============================================================================
; XEX zostavenie: adresa spustenia
;=============================================================================
    .if BOOT = 0
    org RUNAD
    dta a(entry)
    .endif
