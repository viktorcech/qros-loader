;=============================================================================
; QROS LOADER V2, W1K 2026 (AI) - turbo tape loader pre Atari XE/XL
;
; Nacita QROS pasku (132-bajtove bloky, SIO ramce cez POKEY seriovy vstup),
; za behu parsuje Atari binarny format (XEX) a spusti program.
; Pocas nahravania ukazuje nazov programu z hlavicky a percenta.
;
; Loader pracuje v RAM pod OS ROM: na starte skopiruje OS ROM do RAM
; ($C000-$CFFF, $E000-$FFFF), sam bezi v kopii FP ROM ($D800-$DFFF) a pred
; startom programu ju z ROM obnovi. Program bezi s vypnutou ROM (QROS OS):
; do kopie OS stub zapise upravy QROS OS (qrosos.inc), takze
; programy ako DETURBO maju kazetovy handler C: v QROS rezime. Program moze
; zabrat $0000-$BFFF okrem stranky zasobnika, BASIC je vypnuty.
;
; Prekladac: MADS (mads.exe), pozri build.py
;   mads qrosload.asm -d:BOOT=1 ... -o:qrosload.bin   ; surovy blob pre boot
;   mads qrosload.asm -d:BOOT=0 ... -o:qrosload.xex   ; spustitelny XEX
;
; QROS system & SW: Ing. Matus Zubor
; QROS HW ozivenie (2025): Aleister
; Loader: W1K 2026 (AI)
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
SKSTAT  = $D20F                 ; stav seriovej linky a klavesnice (citanie)

; ---- ostatny HW ------------------------------------------------------------
DMACTL  = $D400                 ; riadenie DMA
DLISTL  = $D402                 ; adresa display listu
DLISTH  = $D403
CHBASE  = $D409                 ; sada znakov
COLPM0  = $D012                 ; COLPM0-3, COLPF0-3, COLBK: 9 registrov za sebou
COLBK   = $D01A                 ; okraj (indikacia chyby)
PRIOR   = $D01B
PACTL   = $D302                 ; motor kazety: $34 = zapnuty, $3C = vypnuty
PORTB   = $D301                 ; bit 0 = ROM OS, bit 1 = BASIC (1 = vypnute)
NMIEN   = $D40E
VCOUNT  = $D40B                 ; riadok obrazu / 2 (meni sa kazdych 128 us)

; ---- OS premenne -----------------------------------------------------------
CASINI  = $0002                 ; init vektor bootovacieho obrazu
RAMLO   = $0004                 ; OS: adresa zavadzaca (load+6) pri boote
DOSVEC  = $000A
POKMSK  = $0010                 ; tienovy register IRQEN
DFLAGS  = $0240                 ; boot hlavicka: priznaky, pocet zaznamov, load
DBSECT  = $0241
BOOTAD  = $0242
SDMCTL  = $022F                 ; tiene, ktore OS VBI kopiruje do hardveru:
SDLSTL  = $0230                 ; display list
SDLSTH  = $0231
GPRIOR  = $026F
PCOLR0  = $02C0                 ; PCOLR0-3, COLOR0-4 (9 bajtov za sebou)
COLOR1  = $02C5
COLOR2  = $02C6
RUNAD   = $02E0                 ; adresa spustenia programu
INITAD  = $02E2                 ; adresa inicializacie segmentu
CHBAS   = $02F4

; ---- nulta stranka (volne bajty $CB-$D1 na XL/XE) --------------------------
; Zapisy programu do nultej stranky idu do tiena ZPSHAD, takze tieto bajty
; segment neprepise; skutocna nulta stranka dostane tien pred INIT a RUN.
DPAGE   = $CD                   ; stranka ciela segmentu
SEGCNT  = $CE                   ; -(zostavajuca dlzka segmentu), ide hore k 0
DSTY    = $D0                   ; nizky bajt ciela medzi behmi kopirovania
SUM     = $D1                   ; kontrolny sucet prijimaneho bloku
QSRC    = $CB                   ; stub: zdroj behu qrosos (2 B)
QDST    = $CD                   ; stub: ciel behu (2 B)

; ---- RAM pod OS ROM (loader v kopii FP ROM $D800-$DFFF) --------------------
LOADER_LO = $D8                 ; stranky loadera: chranene pred zapisom
LOADER_HI = $E0                 ; (prva stranka za nimi)
VARS    = $D800                 ; premenne a riadok obrazovky (mimo blobu)
BUFADR  = VARS_END              ; 132-bajtovy blok hned za premennymi
CDATA_ADR = BUFADR+132          ; konstantne data (texty, tabulky) za blokom
ZPSHAD  = $D900                 ; tien nultej stranky (cela stranka)
MAIN_ADR = $DA00                ; hlavny kod loadera, po stranky do $DFFF
TRAMP_ADR = $0100                ; trampolina na dne stranky zasobnika

;---- premenne (v RAM pod ROM, nie su v blobe) ------------------------------
exp_lo     = VARS+0             ; ocakavany index dalsieho bloku
tmo        = VARS+1             ; kolko zmien VCOUNT este cakat na bajt
vtick      = VARS+2             ; posledna videna hodnota VCOUNT
retries    = VARS+3
zvars      = VARS+4             ; --- nulovane pri starte ---
bufpos     = zvars+0            ; pozicia v datovej casti bloku
bufcnt     = zvars+1            ; pocet platnych bajtov v bloku
exp_hi     = zvars+2
collide    = zvars+3            ; program sa pokusil prepisat loader
name_shown = zvars+4
pct        = zvars+5
acc        = zvars+6            ; akumulator percent (2 B)
baudidx    = zvars+8            ; index skusanej rychlosti v baudtab (0..3)
baudtab    = zvars+9            ; styri skusane POKEY delice (AUDF3; AUDF4 = 0)
cdig       = zvars+13           ; desiatkove pocitadlo nacitanych blokov (4 B)
totblk     = zvars+17           ; pocet blokov pasky z konca blobu (2 B)
dl_last    = zvars+19           ; naposledy zapisany display list (2 B)
dm_last    = zvars+21           ; a DMACTL - ANTIC berie zapis hned, aj uprostred
bootimg    = zvars+22           ; snimky, preto len pri zmene tienov
gapcur     = zvars+23           ; bootimg != 0: nahrava sa bootovaci obraz
gapnext    = zvars+24           ; gapcur/gapnext: tento/dalsi blok zacal po medzere
zvars_end  = zvars+25
scrline    = zvars_end          ; textovy riadok (40 B)
VARS_END   = scrline+40

; ---- parametre z prikazoveho riadku (-d:) ----------------------------------
; BOOT    = 1 -> bootovaci blob pre pasku, 0 -> samostatny XEX
; LOADADR = adresa nahrania blobu (po starte patri programu): paska $0700
;           (OS boot), XEX $4000 - zavadzace (SIO2SD, SIDE, DOS) ziju v
;           $0700-$3FFF a subor nahrany cez ne ich nesmie prepisat
; DIVISOR = POKEY delic:  baud = takt / (2 * (DIVISOR + 7))
;           127 -> 6617 baud PAL (rezim "6600"),  86 -> 9535 baud PAL

POKEY_AUDF_6600 = 127           ; delic pre rezim 6600 (6617 baud PAL)
POKEY_AUDF_9600 = 86            ; delic pre rezim 9600 (9535 baud PAL)

; Casove limity sa meraju zmenami VCOUNT (128 us), nie cyklami CPU, takze
; platia aj na akceleratore. Uprostred bloku idu bajty tesne za sebou; ticho
; dlhsie nez TMO_SHORT je medzera medzi blokmi (IRG) - na nej sa prijem
; znova zarovna na zaciatok bloku.
TMO_SHORT = 40                  ; 5,1 ms = ~3,4 bajtu pri 6600 baud
TMO_LONG  = 176                 ; x 256 zmien = 5,8 s pre prvy bajt bloku

NAMECOL = 0                     ; stlpec nazvu programu na 1. riadku
PCTCOL  = 36                    ; stlpec percent
CNTCOL  = PCTCOL-5              ; text "BLOK" pred pocitadlom (bez total_blk)

; Chybove farby pozadia
ERR_SYNC  = $34                 ; cervena  - data nie su v binarnom (DOS) formate
ERR_BLOCK = $24                 ; oranzova - blok sa neda precitat / chyba
ERR_NORUN = $B4                 ; zelena   - chyba RUN adresa ($02E0)
ERR_COLL  = $84                 ; modra    - program prepisuje loader

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
    dta [[blob_end - LOADADR + 127] / 128]  ; pocet 128-bajtovych zaznamov
    dta a(LOADADR)                          ; adresa nahrania
    dta a(boot_rts)                         ; init vektor -> CASINI

;=============================================================================
; Stub (LOADADR + 6): skopiruje OS ROM do RAM, presunie loader pod ROM a
; pripravi trampolinu. Bezi raz, potom jeho pamat patri programu.
;=============================================================================
entry:
    sei
    cld
    ldx #$FF
    txs
    inx                         ; X = 0
    stx NMIEN                   ; ziadne DLI/VBI
    stx DMACTL                  ; obraz von pocas kopirovania

    lda PORTB                   ; bez BASICu; bit 0: ROM zapnuta / vypnuta
    ora #$03
    sta cr_on+1
    and #$FE
    sta cr_off+1

    lda #$C0                    ; OS ROM -> RAM: $C000-$CFFF a $E000-$FFFF
    ldx #$D0                    ; ($D800-$DFFF obnovi trampolina pred startom)
    jsr copy_rom
    lda #$E0
    ldx #0
    jsr copy_rom

; QROS OS: upravy kopie OS (qrosos.inc) - behy
; [adresa, dlzka, bajty...], koniec dlzka 0. ROM je vypnuta.
    lda #<qrosos
    sta QSRC
    lda #>qrosos
    sta QSRC+1
qr_next:
    ldy #2
    lda (QSRC),y                ; dlzka behu (1..255); 0 = koniec
    beq qr_done
    tax                         ; X = dlzka (qr_adv X nemeni)
    dey
    lda (QSRC),y                ; adresa (aj nulta stranka)
    sta QDST+1
    dey
    lda (QSRC),y
    sta QDST
    lda #3                      ; QSRC += 3 (hlavicka behu)
    jsr qr_adv
    ldy #0
qr_copy:
    lda (QSRC),y
    sta (QDST),y
    iny
    dex
    bne qr_copy
    tya                         ; Y = dlzka behu: QSRC += dlzka
    jsr qr_adv
    jmp qr_next
qr_adv:
    clc
    adc QSRC
    sta QSRC
    bcc qa_ret
    inc QSRC+1
qa_ret:
    rts
qr_done:
    jsr QROSOS_INIT             ; inicializacia QROS handlera (CIN v kopii OS)

    ldx #0
    ldy #>[MAIN_LEN+255]        ; hlavny kod na MAIN, po celych strankach
mv_loop:
mv_src:
    lda main_load,x
mv_dst:
    sta MAIN_ADR,x
    inx
    bne mv_loop
    inc mv_src+2
    inc mv_dst+2
    dey
    bne mv_loop

zs_loop:                        ; tien nultej stranky = jej sucasny stav
    lda $00,x
    sta ZPSHAD,x
    inx
    bne zs_loop

    ldx #tramp_len-1            ; trampolina do stranky $01
tr_copy:
    lda tramp_load,x
    sta TRAMP_ADR,x
    dex
    bpl tr_copy

    ldx #cdata_len-1            ; konstantne data pod ROM
cd_copy:
    lda cdata_load,x
    sta CDATA_ADR,x
    dex
    bpl cd_copy

    jmp main.start

; copy_rom - stranky A az X-1 (X = 0: po $FFFF) z OS ROM do RAM pod nou.
; Pod ROM sa zapisuje len pri vypnutej ROM, preto sa PORTB prepina po bajte.
; Konci s vypnutou ROM.  Nici: A, X, Y
copy_rom:
    sta cr_src+2
    sta cr_dst+2
    stx cr_end+1
    ldx #0
cr_off:
    ldy #0                      ; SMC: PORTB bez ROM (v Y pocas celej kopie)
cr_loop:
cr_on:
    lda #0                      ; SMC: PORTB s ROM
    sta PORTB
cr_src:
    lda $FF00,x
    sty PORTB
cr_dst:
    sta $FF00,x
    inx
    bne cr_loop
    inc cr_src+2
    inc cr_dst+2
    lda cr_dst+2
cr_end:
    cmp #0                      ; SMC: koncova stranka
    bne cr_loop
boot_rts:
    rts

;=============================================================================
; Trampolina (stranka $01): kod, ktory bezi mimo loadera.
;=============================================================================
tramp_load:
    .local tramp, TRAMP_ADR

; init - INIT segmentu bezi ako pod DOS (VBI aj IRQ, bez serioveho prijmu),
; ale uz s vypnutou ROM: vidi QROS OS v RAM. INIT smie prepnut PORTB (banky
; 130XE, ROM $FF): banka ostava (dalsi segment ide do nej), ROM ide von,
; inak by sa loader pod nou stratil.
init:
    jsr irq_on
    jsr call_init
    sei
    lda PORTB
    and #$FE
    sta PORTB
    lda #0
    sta NMIEN
    rts
call_init:
    jmp (INITAD)

; boot_go - bootovaci obraz (RUNAD ukazuje sem): ako OS po nahrani z kazety
boot_go:
    jsr call_boot               ; zavadzac na load+6, vracia sa cez rts
    jsr call_casini
    jmp (DOSVEC)
call_boot:
    jmp (RAMLO)
call_casini:
    jmp (CASINI)

; run - obnovi FP ROM $D800-$DFFF (prepise loader), zapne prerusenia cez
; vektory kopie OS a spusti program s vypnutou ROM; banku z posledneho INIT
; necha.
run:
    lda PORTB                   ; PORTB programu, ROM von (tramp.init)
    ora #$01
    sta fr_on+1
    eor #$01
    sta fr_off+1
    ldx #0
fr_off:
    ldy #0                      ; SMC: PORTB bez ROM (v Y, takto ostane)
fr_loop:
fr_on:
    lda #0                      ; SMC: PORTB s ROM
    sta PORTB
fr_src:
    lda $D800,x
    sty PORTB
fr_dst:
    sta $D800,x
    inx
    bne fr_loop
    inc fr_src+2
    inc fr_dst+2
    lda fr_dst+2
    cmp #LOADER_HI
    bne fr_loop
    jsr irq_on
    jmp (RUNAD)

irq_on:                         ; obvykle IRQ (BREAK + klavesnica) a VBI
    lda #$C0
    sta POKMSK
    sta IRQEN
    lda #$40
    sta NMIEN
    cli
    rts

    .endl
tramp_len = * - tramp_load
    ert tramp_len > 112         ; zasobniku ostava aspon 144 B (kopia cez bpl: < 128)

;=============================================================================
; Konstantne data pod ROM (stub ich skopiruje na CDATA): texty a tabulky chyb
;=============================================================================
cdata_load:
    .local cdata, CDATA_ADR
label_txt   dta d'QROS LOADER V2, W1K 2026 (AI)'
label_end
cnt_txt     dta d'BLOK'
cnt_end
err_col     dta ERR_SYNC, ERR_BLOCK, ERR_NORUN, ERR_COLL
err_msg     dta main.msg_sync-main.msgs, main.msg_block-main.msgs
            dta main.msg_norun-main.msgs, main.msg_coll-main.msgs
    .endl
cdata_len = * - cdata_load
    ert cdata_len > 128
    ert CDATA_ADR + cdata_len > ZPSHAD              ; data sa zmestia pred tien

;=============================================================================
; Hlavny kod loadera - bezi na MAIN pod OS ROM
;=============================================================================
main_load:
    .local main, MAIN_ADR

;=============================================================================
; Chyby - pred vstupom (start sa vola cez jmp), v dosahu kratkych vetvi
; parsera (vstupy su tesne pred start). Kazdy ldx preskoci dalsie cez
; bit abs ($2C).
;=============================================================================
; halt - X = cislo chyby: text za "CHYBA - " a farba okraja
halt:                           ; I=1 vzdy (entry, tramp.init konci sei)
    txa
    pha
    jsr motor_off
    jsr scr_on                  ; nas riadok na obrazovke, NMI von
    jsr clr_line                ; konci s A = 0
    tax                         ; X = stlpec 0
    tay                         ; Y = text "CHYBA - " (msg_pre = msgs)
    jsr hl_copy
    pla
    tay
    lda cdata.err_col,y
    pha
    lda cdata.err_msg,y
    tay
    jsr hl_copy
    pla
halt_loop:
    sta COLBK
    jmp halt_loop

hl_copy:                        ; text od msgs+Y po $FF na stlpec X
    lda msgs,y
    bmi hl_ret
    sta scrline,x
    inx
    iny
    bne hl_copy
hl_ret:
    rts

no_run:
    ldx #2
    dta $2C
e_sync:
    ldx #0
    dta $2C
e_block:
    ldx #1
    dta $2C
e_coll:
    ldx #3
    jmp halt

start:
    lda #0
    ldx #zvars_end - zvars      ; vynulovanie stavu
clr_vars:
    sta zvars-1,x
    dex
    bne clr_vars
    sta INITAD+1                ; vysoky bajt 0 = INIT/RUN nenastaveny
    sta RUNAD+1

; Skusane delice: zadany, o 4 mensi, druha bezna QROS rychlost, o 4 mensia.
; Zaznam z emulatora ma presnu rychlost delica a jeho dekoder vzorkuje bity
; neskoro - precita ho az prijimac o ~3 % rychlejsi. Realna paska ide hned
; prvym. Delice su 8-bitove (AUDF4 = 0), z baudiv sa cita len nizky bajt.
    lda baudiv
    sta baudtab
    ldx #POKEY_AUDF_6600
    cmp #POKEY_AUDF_9600
    beq bi_alt
    ldx #POKEY_AUDF_9600
bi_alt:
    stx baudtab+2
    sec
    sbc #4
    sta baudtab+1
    txa                         ; C=1: delice > 4, sbc nepozicia
    sbc #4
    sta baudtab+3

    lda #2                      ; datove bloky zacinaju indexom 2
    sta exp_lo
    lda total_blk               ; parametre z konca blobu - blob program prepise
    sta totblk
    lda total_blk+1
    sta totblk+1

    jsr motor_off               ; motor stal uz po boote OS - cakame na klavesu
    jsr screen_init
    jsr wait_key
    jsr ser_init                ; POKEY prijem + motor

;=============================================================================
; Parser Atari binarneho formatu (streamovany priamo z pasky)
;=============================================================================
    jsr getbyte                 ; FF FF = binarny format, inak bootovaci obraz
    jcs e_sync
    cmp #$FF
    jne boot_img
    jsr getbyte
    jcs e_sync
    cmp #$FF
    jne e_sync

seg_loop:
    jsr getbyte                 ; zaciatocna adresa segmentu
    jcs load_done               ; korektny koniec medzi segmentmi
    sta DSTY
    jsr getbyte
    jcs e_sync
    sta DPAGE

    and DSTY                    ; $FFFF = dalsia (volitelna) FF FF hlavicka
    cmp #$FF
    beq seg_loop

    jsr getbyte                 ; koncova adresa segmentu (docasne v SEGCNT)
    jcs far_sync                ; (e_sync uz mimo dosahu, far_sync hned za nami)
    sta SEGCNT
    jsr getbyte
    jcs far_sync
    sta SEGCNT+1

    lda DSTY                    ; SEGCNT = start - end - 1 = -dlzka
    sbc SEGCNT                  ; C=0 z getbyte odcita tu jednotku
    sta SEGCNT
    lda DPAGE
    sbc SEGCNT+1
    sta SEGCNT+1
    bcc seg_ok                  ; start > end -> poskodeny subor
far_sync:
    jmp e_sync                  ; aj pre dalsie vetvy mimo dosahu e_sync
cl_eof:                         ; koniec pasky uprostred segmentu je chyba; pri
    lda bootimg                 ; boot obraze moze byt posledny zaznam kratsi,
    jeq far_sync                ; nez hovori hlavicka - OS bootu to nevadi
    jmp load_done
cl_more:                        ; blok minuty -> dalsi (bufcnt 1..128); mimo
    jsr next_block              ; slucky behov, aby jej koniec dosiahol cl_run
    bcs cl_eof                  ; koniec pasky uprostred segmentu
    lda #0
    sta bufpos
    lda bufcnt                  ; Z=0
    bne cl_avail
seg_ok:


;-----------------------------------------------------------------------------
; Kopirovanie segmentu po behoch: beh = zvysok bloku, zvysok segmentu alebo
; zvysok stranky ciela, co je najkratsie - beh nikdy neprekroci stranku, takze
; obe strany idu cez abs,x s X hore k nule (operandy su posunute o koniec
; behu - 256). Zahodeny beh (chranena stranka, hardver) sa zapisuje spat do
; zdroja: prepis tym istym bajtom nic nespravi.
; Vstup: DPAGE:DSTY = ciel, SEGCNT = -dlzka (aj z boot_img).
;-----------------------------------------------------------------------------
copy_seg:
cl_run:
    lda bufcnt                  ; A = zvysok bloku (bufpos <= bufcnt)
    sec
    sbc bufpos
    beq cl_more                 ; blok minuty: dalsi blok (cl_more je pred nami)
cl_avail:                       ; A = zvysok bloku (1..128)
    ldx SEGCNT+1                ; zvysok segmentu >= 256 -> cely zvysok bloku
    inx
    bne cl_blk
    tax
    clc
    adc SEGCNT                  ; C=1: zvysok bloku >= zvysok segmentu (-SEGCNT)
    txa
    bcc cl_blk
    lda #0                      ; beh = -SEGCNT (C=1 z adc)
    sbc SEGCNT
cl_blk:                         ; A = min(blok, segment), 1..128
    tax
    jsr cl_chk                  ; Y = stranka zapisu (0 = zahodit); A nemeni
    bcc cl_pg
    sta collide                 ; A = beh != 0: do chranenej stranky ide bajt
cl_pg:
    txa
    clc
    adc DSTY                    ; koniec behu v stranke ciela
    bcc cl_fit                  ; < 256
    beq cl_fit                  ; = 256: presne po koniec stranky (C=1)
    lda #0                      ; cez koniec stranky: beh = 256 - DSTY
    sbc DSTY                    ; (C=1; DSTY != 0, takze potom C=0)
    tax
    lda #0                      ; koniec behu = 256
    sec
cl_fit:                         ; X = beh, A = koniec behu = novy DSTY, C = (koniec = 256)
    sta cl_st+1
    sta DSTY
    bne cl_hi                   ; Z z poslednej ALU operacie (adc / lda #0)
    inc DPAGE                   ; dalsi beh zacina v dalsej stranke
cl_hi:
    tya                         ; stranka zapisu - 1 + C (inc, sta, bne C nemenia)
    adc #$FF
    sta cl_st+2
    txa
    clc
    adc SEGCNT                  ; SEGCNT += beh
    sta SEGCNT
    bcc cl_lim
    inc SEGCNT+1
    clc
cl_lim:                         ; C=0
    txa
    adc bufpos                  ; koniec behu = nova pozicia v bufri (<= 128)
    sta bufpos
    adc #<[BUFADR+3-256]        ; C=0; lda base,x s X = -beh..-1; bez prenosu
    sta cl_ld+1                 ; (ert nizsie), vysoky bajt operandu je pevny
    tya
    bne cl_go
    lda cl_ld+1                 ; zahodeny beh: ciel = zdroj
    sta cl_st+1
    lda #>[BUFADR+3-256]
    sta cl_st+2
cl_go:
    txa
    eor #$FF                    ; X = -beh, ide hore k nule
    tax
    inx

; 15 cyklov na bajt (citanie krizi stranku: operand je o stranku nizsie).
cl_ld:
    lda a:BUFADR+3-256,x        ; SMC nizky bajt: + koniec behu
cl_st:
    sta a:$0000,x               ; SMC: ciel + koniec behu - 256, alebo zdroj
    inx
    bne cl_ld
    ert >cl_ld <> >*            ; slucka v jednej stranke

    lda SEGCNT
    ora SEGCNT+1
    bne cl_run                  ; segment pokracuje v dalsom bloku

;-----------------------------------------------------------------------------
; Segment nacitany - ak sa zmenil INITAD, zavolame ho (rovnako ako DOS)
;-----------------------------------------------------------------------------
    lda INITAD+1                ; segment nastavil INIT? (0 = nie)
    jeq seg_loop

do_init:
    jsr zp_put                  ; INIT vidi nultu stranku programu
    jsr tramp.init
    jsr zp_get                  ; co v nej INIT zmenil, ostava v tieni
    lda #0
    sta INITAD+1
    jsr scr_sync                ; obraz podla tienov (INIT ich mohol zmenit)
    jsr ser_init                ; INIT mohol zmenit POKEY aj motor
    jmp seg_loop

;-----------------------------------------------------------------------------
; Bootovaci obraz (ako OS boot z kazety): hlavicka = priznaky,
; pocet 128-bajtovych zaznamov, load, init. Cely obraz aj s hlavickou ide na
; load - jej bajty su este v bufri, bufpos sa vrati na 0. Spusta ho
; tramp.boot_go cez RAMLO (load+6) a CASINI (v tieni nultej stranky).
;-----------------------------------------------------------------------------
bi_sync:
    jmp e_sync                  ; chyby hlavicky (e_sync mimo dosahu vetvi)
boot_img:
    sta DFLAGS
    jsr getbyte                 ; pocet zaznamov -> SEGCNT = -(zaznamy * 128)
    bcs bi_sync
    sta DBSECT
    beq bi_sync                 ; 0 zaznamov nie je obraz
    sta bootimg
    lsr                         ; cele stranky, C = +128 B
    eor #$FF                    ; A = -stranky - 1 (eor C nemeni)
    tax
    lda #0
    ror                         ; A = $80 pri neparnom pocte, inak 0
    bne bi_cnt
    inx                         ; parny pocet: -stranky, 0 B navyse
bi_cnt:
    sta SEGCNT
    stx SEGCNT+1
    jsr getbyte                 ; load
    bcs bi_sync
    sta DSTY
    sta BOOTAD
    jsr getbyte
    bcs bi_sync
    sta DPAGE
    sta BOOTAD+1
    jsr getbyte                 ; init -> CASINI
    bcs bi_sync
    sta ZPSHAD+CASINI
    jsr getbyte
    bcs bi_sync
    sta ZPSHAD+CASINI+1
    lda DSTY                    ; RAMLO = load + 6; C=0 z getbyte (bcs nevykonane)
    adc #6
    sta ZPSHAD+RAMLO
    lda DPAGE
    adc #0
    sta ZPSHAD+RAMLO+1
    lda #<tramp.boot_go
    sta RUNAD
    lda #>tramp.boot_go
    sta RUNAD+1
    lda #0                      ; hlavicka je sucast obrazu
    sta bufpos
    jmp copy_seg

; cl_chk - stranka zapisu behu podla DPAGE: $00 -> tien ZPSHAD, $01 a stranky
; loadera -> chranene (zahodit, kolizia), $D0-$D7 hardver (zahodit), vsetko
; ostatne priamo (aj kopia OS pod ROM).
; Vystup: Y = stranka zapisu, 0 = zahodit; C=1 chranena.  Nici: Y (A nie)
cl_chk:
    ldy DPAGE
    beq ck_zp
    cpy #1
    beq ck_drop                 ; stranka zasobnika; C=1 z cpy
    cpy #$D0
    bcc ck_free                 ; RAM pod $D000
    cpy #LOADER_HI
    bcs ck_free                 ; kopia OS za loaderom
    cpy #LOADER_LO              ; C=1 loader ($D8-$DF), C=0 hardver ($D0-$D7)
ck_drop:
    ldy #0
    rts
ck_zp:
    ldy #>ZPSHAD
ck_free:
    clc
    rts

; zp_put / zp_get - tien nultej stranky do nej / z nej.  Nici: A, X
zp_put:
    ldx #0
zpp_loop:
    lda ZPSHAD,x
    sta $00,x
    inx
    bne zpp_loop
    rts

zp_get:
    ldx #0
zpg_loop:
    lda $00,x
    sta ZPSHAD,x
    inx
    bne zpg_loop
    rts

;=============================================================================
; Koniec nahravania - motor stop, nulta stranka a PORTB programu, spustenie
;=============================================================================
load_done:
    jsr motor_off
    lda collide
    jne e_coll
    lda RUNAD+1                 ; RUN musi byt nastaveny (0 = nie)
    jeq no_run
    lda #0                      ; obraz von: nas riadok a display list zmiznu
    sta SDMCTL                  ; s obnovou FP ROM, program si obraz zapne sam
    jsr scr_sync
    jsr zp_put
    jmp tramp.run

;=============================================================================
; getbyte - dalsi datovy bajt XEX prudu (hlavicky segmentov)
; Vystup: A = bajt, C=0.  C=1 = koniec suboru (EOF blok).
; Nici: X, Y
;=============================================================================
getbyte:
    ldx bufpos
    cpx bufcnt
    bcc gb_have

    jsr next_block
    bcs gb_ret
    ldx #0

gb_have:                        ; C=0: z bcc aj z nevykonaneho bcs
    lda BUFADR+3,x
    inx
    stx bufpos
gb_ret:
    rts

;=============================================================================
; next_block - nacita dalsi POUZITELNY datovy blok do buffra
; Vystup: C=0 blok pripraveny (bufcnt = 1..128 platnych bajtov)
;         C=1 nacitany koncovy blok
;=============================================================================
next_block:
    lda #16                     ; pocet povolenych opakovani
    sta retries

nb_next:
    jsr read_block
    bcs nb_bad                  ; timeout alebo zly kontrolny sucet

    lda BUFADR+2                ; typ bloku
    cmp #$FC
    beq nb_data
    cmp #$FA
    beq nb_data
    cmp #$FD
    beq nb_header
    cmp #$FF
    beq nb_next                 ; nastavovaci blok len preskocime
    cmp #$FE
    bne nb_skip
    rts                         ; koniec suboru, C=1 z cmp

; Blok sa necita: ak zacal po medzere (ciste), je zla rychlost - skusime
; dalsiu z tabulky. Ak sme don vbehli uprostred, len sa zarovname na dalsiu
; medzeru. Blok s dobrym suctom, ale zlym typom alebo poradim, preskocime.
; Pocet pokusov je obmedzeny, aby sa loader nikdy nezacyklil.
nb_bad:                         ; Z = (gapcur = 0) z read_block (lda pred rts)
    beq nb_skip
    jsr next_baud
nb_skip:
    dec retries
    bne nb_next
    jmp e_block

nb_header:
    jsr show_name               ; hlavicka - vypiseme nazov programu
    jmp nb_next

; --- kontrola poradia a dlzky bloku (A = typ) -------------------------------
nb_data:
    ldx BUFADR+1                ; nizky bajt indexu
    cpx exp_lo
    bne nb_skip
    ldx BUFADR
    cpx exp_hi
    bne nb_skip

    ldx #128                    ; uplny blok
    cmp #$FC
    beq nb_ok
    ldx BUFADR+130              ; neuplny blok - pocet platnych v poslednom bajte
    beq nb_skip
    cpx #129
    bcs nb_skip

nb_ok:
    stx bufcnt
    inc exp_lo
    bne nb_prog
    inc exp_hi
nb_prog:
    jsr bump_progress
    jsr scr_sync                ; tiene -> hardver, ako OS VBI
    clc
    rts

;=============================================================================
; read_block - nacita 132 bajtov a overi SIO kontrolny sucet
; Sucet sa pocita uz pocas prijmu, takze v medzere medzi blokmi ostava viac
; casu na spracovanie. Kazde zlyhanie konci za medzerou (IRG), takze dalsi
; pokus zacina presne na zaciatku bloku.
; Vystup: C=0 v poriadku; C=1 timeout alebo zly sucet, A (a Z) = gapcur:
;         blok zacal po medzere (ticho >= TMO_SHORT pred prvym bajtom, alebo
;         medzera najdena v predoslom pokuse), inak sme vbehli do stredu.
;=============================================================================
read_block:
    lda gapnext                 ; medzeru nasiel uz predosly pokus?
    sta gapcur
    lda #0
    sta gapnext
    ldx #TMO_LONG               ; prvy bajt: TMO_LONG x 33 ms
rb_first:
    lda #0                      ; 256 tickov
    jsr sbyte
    bcc rb_start
    dex
    bne rb_first
    inx                         ; po 5,8 s ticha: dalsi bajt je po medzere
    stx gapnext
    txa                         ; A = 1, Z = 0; C = 1 z sbyte
    rts

rb_start:                       ; A = prvy bajt; X = TMO_LONG len ak prisiel hned
    pha
    cpx #TMO_LONG
    bne rb_gap
    lda tmo                     ; cakali sme 256-tmo tickov; 0 = bajt hned
    beq rb_sync
    cmp #257-TMO_SHORT          ; tmo <= 256-TMO_SHORT: cakanie >= TMO_SHORT
    bcs rb_sync
rb_gap:
    lda #1
    sta gapcur
rb_sync:
    lda #0                      ; sucet prvych 131 bajtov
    sta SUM
    ldx #256-132                ; index ide hore k nule
    pla                         ; prvy bajt
    clc
    bcc rb_store                ; C=0 pre sucet

rb_have:                        ; C=0 od adc #0 (cakanie ho nemeni)
    lda SERIN
    ldy #0                      ; vynulovanie a znovuzapnutie zapisovaca IRQ
    sty IRQEN
    ldy #$20
    sty IRQEN
rb_store:
    sta BUFADR+132-256,x
    inx
    beq rb_check                ; A = 132. bajt = kontrolny sucet
    adc SUM                     ; sucet s prenosom; C=0 (adc #0 neprenasa)
    adc #0
    sta SUM
    lda #TMO_SHORT              ; dalsi bajt musi prist hned (sbyte inline)
    sta tmo
rb_wait:
    lda IRQST                   ; bit 5 v nule = prijaty bajt
    and #$20
    beq rb_have
    lda VCOUNT                  ; eor nemeni C (sucet ho potrebuje 0)
    eor vtick
    beq rb_wait
    eor vtick
    sta vtick
    dec tmo
    bne rb_wait
    beq rb_dgap                 ; Z=1: medzera uprostred bloku

rb_check:
    cmp SUM
    bne rb_drain
    clc
    rts

rb_drain:                       ; zly sucet: zvysok bloku zahodime po medzeru
    ldx #0                      ; najviac 256 bajtov
rb_dloop:
    lda #TMO_SHORT
    jsr sbyte
    bcs rb_dgap
    dex
    bne rb_dloop
    beq rb_fail                 ; Z=1: 256 bajtov bez medzery (prud bez pauz)
rb_dgap:
    inc gapnext                 ; medzera najdena: dalsi bajt je po nej
rb_fail:
    lda gapcur
    sec
    rts

;=============================================================================
; sbyte - prijme jeden bajt z POKEY seriovej linky
; Vstup: A = najviac kolko zmien VCOUNT cakat (0 = 256, 33 ms)
; Vystup: A = bajt, C=0.  C=1 = timeout.
; X zachova (read_block v nom drzi poziciu v bloku), nici Y.
;=============================================================================
sbyte:
    sta tmo
sb_wait:
    lda IRQST                   ; bit 5 v nule = prijaty bajt
    and #$20
    beq sb_have
    lda VCOUNT
    cmp vtick
    beq sb_wait
    sta vtick
    dec tmo
    bne sb_wait
    sec
    rts

sb_have:
    lda SERIN
    ldy #0                      ; vynulovanie a znovuzapnutie zapisovaca IRQ
    sty IRQEN
    ldy #$20
    sty IRQEN
    clc
    rts

;=============================================================================
; next_baud - dalsi delic z tabulky (dookola) a pokracuje do ser_init.
; Hlavicka sa na paske posiela dvakrat a pred nou su medzery, takze sa loader
; zosynchronizuje este pred prvym datovym blokom.
; ser_init - POKEY asynchronny prijem rychlostou baudidx, motor zapnut
; Nici: A, X
;=============================================================================
next_baud:
    lda baudidx
    clc
    adc #1
    and #3                      ; 4 polozky
    sta baudidx

ser_init:
    lda #$28                    ; kanaly 3+4 spojene, kanal 3 na 1.79 MHz
    sta AUDCTL
    lda #$A0                    ; ciste tony, hlasitost 0
    sta AUDC3
    sta AUDC4
    ldx baudidx                 ; 0..3
    lda baudtab,x
    sta AUDF3
    lda #0
    sta AUDF4                   ; delic je 8-bitovy
    sta SKCTL                   ; init mod resetuje prijimac (zapis $13 pri
                                ; SKCTL=$13 by nic nespravil), ako OS sio.s
    sta SKRES
    sta IRQEN                   ; IRQEN len tu (druhy zapis by zahodil
    lda #$13                    ; prave prijimany bajt)
    sta SKCTL                   ; asynchronny prijem odznova
    lda #$20
    sta IRQEN
    lda #$34                    ; motor kazety zapnut
    sta PACTL
    rts

; motor_off - motor stop, POKEY ticho.  Nici: A
motor_off:
    lda #$3C
    sta PACTL
    lda #0
    sta AUDC3
    sta AUDC4
    rts

;=============================================================================
; Vypis na obrazovku
;=============================================================================

; screen_init - postavi vlastny display list s jednym textovym riadkom.
; Riadok lezi v chranenej pamati loadera, takze vypis nikdy neprepise
; nahravany program (a program zase neprepise vypis).
screen_init:
    jsr clr_line
    ldy #cdata.label_end-cdata.label_txt-1 ; oznacenie loadera, kym nepride nazov
si_label:
    lda cdata.label_txt,y
    sta scrline+NAMECOL,y
    dey
    bpl si_label
    jmp scr_on

; wait_key - caka na stlacenie klavesy (SKSTAT bit 2 = 0): najprv na pustenie
; (klavesa z bootu), potom na stlacenie. Potom sa ukaze pocitadlo.
wait_key:
    lda SKSTAT
    and #$04
    beq wait_key
wk_down:
    lda SKSTAT
    and #$04
    bne wk_down
    lda totblk                  ; pocet blokov pasky zname: percenta,
    ora totblk+1                ; inak text a pocitadlo blokov
    bne wk_pct
    ldy #cdata.cnt_end-cdata.cnt_txt-1
wk_cnt:
    lda cdata.cnt_txt,y
    sta scrline+CNTCOL,y
    dey
    bpl wk_cnt
    jmp show_count              ; hned ukazeme vychodzi stav
wk_pct:
    jmp show_pct

    ert CNTCOL < NAMECOL + 25 + 1               ; za nazvom aspon medzera
    ert cdata.label_end - cdata.label_txt > CNTCOL - NAMECOL  ; oznacenie po pocitadlo

; scr_on - nas riadok do OS tienov a na obrazovku, NMI vypnute. Program,
; ktory si tiene prepise (nahravaci obrazok), dostane svoj obraz pri dalsom
; scr_sync - ako pod OS VBI.  Nici: A, X
scr_on:
    lda #0
    sta NMIEN
    lda #<dlist
    sta SDLSTL
    lda #>dlist
    sta SDLSTH
    lda #$E0                    ; znakova sada OS (kopia pod ROM)
    sta CHBAS
    lda #$0E                    ; jas textu
    sta COLOR1
    lda #$94                    ; pozadie textu
    sta COLOR2
    lda #$22                    ; DMA: normalna sirka + display list
    sta SDMCTL
; scr_sync - tiene -> hardver, to co robi OS VBI; raz za blok. Farby, PRIOR
; a CHBASE vzdy (rovnaka hodnota nic nespravi), display list a DMACTL len
; pri zmene - ANTIC ich berie hned a obraz by uprostred snimky skocil.
; Nici: A, X
scr_sync:
    ldx #8                      ; PCOLR0-3, COLOR0-4 -> COLPM0-3, COLPF0-3, COLBK
sy_col:
    lda PCOLR0,x
    sta COLPM0,x
    dex
    bpl sy_col
    lda GPRIOR
    sta PRIOR
    lda CHBAS
    sta CHBASE
    lda SDLSTL
    cmp dl_last
    bne sy_dl
    lda SDLSTH
    cmp dl_last+1
    beq sy_dm
sy_dl:
    lda SDLSTL
    sta dl_last
    sta DLISTL
    lda SDLSTH
    sta dl_last+1
    sta DLISTH
sy_dm:
    lda SDMCTL
    cmp dm_last
    beq sy_ret
    sta dm_last
    sta DMACTL
sy_ret:
    rts

; clr_line - riadok vyplni medzerami.  Vystup: A = 0 (halt na to spolieha)
clr_line:
    ldy #39
    lda #0
cl_clr:
    sta scrline,y
    dey
    bpl cl_clr
    rts

; show_name - az 25 znakov nazvu z hlavickoveho bloku (offset $08).
; Nazov konci na $9B alebo $00 (pasky z inych generatorov), inak 25 znakov.
show_name:
    lda name_shown
    bne sn_ret

    ldx #0                      ; X != 0: nazov ma aj iny znak nez medzeru
    ldy #0
sn_scan:
    lda BUFADR+8,y
    beq sn_scanned
    cmp #$9B
    beq sn_scanned
    cmp #$20
    beq sn_space
    inx
sn_space:
    iny
    cpy #25
    bne sn_scan
sn_scanned:
    txa                         ; prazdny nazov neprepisuje znacku
    beq sn_ret

    inc name_shown
    ldy #0
sn_copy:
    lda BUFADR+8,y
    beq sn_fill
    cmp #$9B
    beq sn_fill
    and #$7F                    ; ATASCII -> obrazovy kod
    cmp #$60
    bcs sn_put                  ; $60-$7F: rovnaky kod
    sbc #$1F                    ; C=0: -$20; $20-$5F -> $00-$3F, C=1
    bcs sn_put
    adc #$60                    ; C=0: $00-$1F (+$E0) -> $40-$5F
sn_put:
    sta scrline+NAMECOL,y
    iny
    cpy #25
    bne sn_copy
sn_fill:                        ; za nazvom medzery az po pocitadlo (zmaze
    lda #0                      ; zvysok oznacenia loadera)
sn_fl:
    sta scrline+NAMECOL,y
    iny
    cpy #CNTCOL-NAMECOL
    bne sn_fl
sn_ret:
    rts

; bump_progress - o jeden blok dalej
; Percenta len ak generator dopisal total_blk (pocet blokov celej pasky),
; inak pocitadlo blokov - percenta za segment by pri viacerych segmentoch
; skakali na 100 % a odznova.
bump_progress:
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

    lda totblk                  ; nula = pocet blokov pasky nepozname
    ora totblk+1
    beq show_count

    lda acc                     ; acc += 100
    clc
    adc #100
    bcc bp_div
    inc acc+1
bp_div:
    sec
bp_loop:                        ; kym acc >= totblk, uber ho a pripocitaj 1
    sta acc                     ; A = nizky bajt acc
    sbc totblk
    tax
    lda acc+1
    sbc totblk+1
    bcc show_pct                ; acc < totblk
    sta acc+1
    txa
    inc pct                     ; C=1 ostava; pct <= 100, nikdy 0
    bne bp_loop

; show_pct - vypise pct ako tri cislice a znak percenta od stlpca PCTCOL
show_pct:
    lda pct
    ldx #$10-1                  ; stovky ako obrazovy kod cislice
    sec
sp_h:
    inx
    sbc #100
    bcs sp_h
    adc #100                    ; vrati zvysok, C=1 (A + 256)
    ldy #$10-1                  ; desiatky
sp_t:
    iny
    sbc #10
    bcs sp_t
    adc #$10+10                 ; jednotky ako obrazovy kod (C=0)
    sta scrline+PCTCOL+2

    cpx #$10                    ; nulove stovky -> medzera
    bne sp_put
    ldx #0
    cpy #$10                    ; a pod 10 aj nulove desiatky
    bne sp_put
    ldy #0
sp_put:
    stx scrline+PCTCOL
    sty scrline+PCTCOL+1
    lda #$05                    ; obrazovy kod znaku percenta
    sta scrline+PCTCOL+3
    rts

; show_count - vypise pocitadlo blokov ako styri cislice
show_count:
    ldx #0
sc_lead:                        ; uvodne nuly -> medzery (posledna cislica vzdy)
    lda cdig,x
    bne sc_put
    sta scrline+PCTCOL,x
    inx
    cpx #3
    bne sc_lead
sc_dig:
    lda cdig,x
sc_put:
    ora #$10
    sta scrline+PCTCOL,x
    inx
    cpx #4
    bne sc_dig
    rts

; --- chybove texty (obrazove kody, ukoncene $FF) ----------------------------
msgs
msg_pre     dta d'CHYBA - ', $FF
msg_sync    dta d'NEZNAMY FORMAT', $FF
msg_block   dta d'NECITATELNY BLOK', $FF
msg_norun   dta d'CHYBA RUN ADRESA', $FF
msg_coll    dta d'PREPISUJE LOADER', $FF
msg_end
    ert msg_pre <> msgs
    ert msg_end - msgs > 256
    ert [msg_sync - msg_pre - 1] + [msg_end - msg_coll - 1] > 40

; --- vlastny display list: 24 prazdnych riadkov + jeden textovy riadok -------
dlist
    dta $70,$70,$70
    dta $42, a(scrline)
    dta $41, a(dlist)

    ert [dlist & $FC00] <> [[dlist + 8] & $FC00]        ; DL cez 1K hranicu
    ert [scrline & $F000] <> [[scrline + 39] & $F000]   ; riadok cez 4K hranicu

    .endl
MAIN_LEN = * - main_load
    ert MAIN_ADR + [[MAIN_LEN + 255] & $FF00] > [LOADER_HI * 256]  ; kod po strankach do $DFFF
    ert >[BUFADR + 3] <> >[BUFADR + 130]             ; data bloku v jednej stranke
    ert <[BUFADR + 3] > 127                          ; cl_ld: nizky bajt + 128 bez prenosu
    ert BUFADR + 132 > ZPSHAD                        ; buffer pred tienom
    ert VARS_END > BUFADR                            ; premenne pred bufferom
    ert >VARS <> LOADER_LO

; QROS OS data (ostavaju v blobe, stub ich pouzije pred nahravanim)
qrosos:
    icl 'qrosos.inc'

; Dopisatelne parametre na konci blobu (generator ich meni podla pasky):
;   baudiv    na offsete dlzka-4  - POKEY delic prenosovej rychlosti
;   total_blk na offsete dlzka-2  - pocet datovych blokov (nula = bez percent)
; POZOR: label sa nesmie volat DIVISOR - MADS je case-insensitive a prepisal
; by hodnotu z -d:DIVISOR (adresa labelu namiesto delica).
baudiv     dta a(DIVISOR)
total_blk  dta a(0)
blob_end:

;=============================================================================
; XEX zostavenie: adresa spustenia
;=============================================================================
    .if BOOT = 0
    org RUNAD
    dta a(entry)
    .endif
