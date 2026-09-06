; =============================================================================
; XKERNEL — Wayward: nucleo del exokernel XASMOS [XSPEC-0004]
; Cadena de arranque: Exord (0x7C00) -> XKERNEL (0x9000, 16-bit)
;                     -> 32-bit -> 64-bit -> EXIT -> XSH
;
; Mejoras sobre la version anterior (misma API publica, sin romper nada
; que ya dependa de este kernel):
;   1. Linea A20 habilitada (metodo rapido, puerto 0x92) antes de proteger.
;      Sin esto, cualquier acceso a memoria >1MB se envuelve en hardware
;      real. No fallaba hasta ahora porque todo el diseño vive bajo 1MB,
;      pero es una bomba de tiempo para cuando crezca (mas kernel, mas EXFS).
;   2. Verificacion de soporte CPUID y Long Mode antes de saltar a 64-bit.
;      Si el CPU no soporta long mode, se imprime un error claro y se
;      detiene limpiamente en vez de un triple fault silencioso.
;   3. Cursor de video rastreado como fila/columna directas: se eliminaron
;      las dos instrucciones DIV que se ejecutaban en cada newline/CR.
;
; Simbolos publicos sin cambios (exfs.asm / exit.asm / xsh.asm dependen
; de estos nombres exactos):
;   cursor_pos, readline_buf, exfs_cur_dir_name, exfs_cur_dir_lba,
;   exfs_io_buf, xk_init_video, xk_init_keyboard, xk_scroll, xk_putchar,
;   xk_print, xk_println, xk_readline, xk_getkey, xk_strcmp, xk_strlen,
;   xk_strncpy
; =============================================================================
[BITS 16]
org 0x9000

kernel_16_entry:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x8000

    mov si, msg_16
    call print16

    call enable_a20
    call check_long_mode_support
    jc   .no_long_mode

    lgdt [gdt32_ptr]
    mov eax, cr0
    or  eax, 1
    mov cr0, eax
    jmp 0x08:kernel_32_entry

.no_long_mode:
    mov si, msg_no_lm
    call print16
    cli
.halt16:
    hlt
    jmp .halt16

print16:
    mov ah, 0x0E
    mov bx, 0x0007
.lp:
    lodsb
    or  al, al
    jz  .ret
    int 0x10
    jmp .lp
.ret:
    ret

; -----------------------------------------------------------------------
; enable_a20 — habilita la linea A20 via el metodo rapido (puerto 0x92).
; Soportado por practicamente todo el hardware x86 desde los 90s en
; adelante, y por QEMU/VirtualBox/VMware. Si algun dia se necesita
; soporte para hardware anterior a eso, el metodo del controlador de
; teclado 8042 es el fallback clasico, pero se omite aqui a proposito
; para no añadir complejidad que ningun hardware real actual necesita.
; -----------------------------------------------------------------------
enable_a20:
    push ax
    in   al, 0x92
    test al, 2
    jnz  .done          ; ya estaba habilitada
    or   al, 2
    and  al, 0xFE       ; no tocar el bit de reset rapido (bit 0)
    out  0x92, al
.done:
    pop  ax
    ret

; -----------------------------------------------------------------------
; check_long_mode_support — CF=0 si el CPU soporta 64-bit, CF=1 si no.
; Paso 1: verificar que CPUID existe (toggle del bit ID en EFLAGS).
; Paso 2: verificar que la hoja extendida 0x80000001 esta disponible.
; Paso 3: verificar el bit 29 (LM) de EDX en esa hoja.
; -----------------------------------------------------------------------
check_long_mode_support:
    pushfd
    pop  eax
    mov  ecx, eax
    xor  eax, 1 << 21        ; intentar togglear el bit ID (21)
    push eax
    popfd
    pushfd
    pop  eax
    push ecx
    popfd
    xor  eax, ecx
    jz   .no_cpuid           ; si no cambio, no hay CPUID

    mov  eax, 0x80000000
    cpuid
    cmp  eax, 0x80000001
    jb   .no_lm              ; sin hoja extendida, sin long mode

    mov  eax, 0x80000001
    cpuid
    test edx, 1 << 29
    jz   .no_lm

    clc
    ret
.no_cpuid:
.no_lm:
    stc
    ret

msg_16      db 'XKERNEL 16-bit OK', 13, 10, 0
msg_no_lm   db 'ERROR: CPU sin soporte Long Mode (64-bit). Deteniendo.', 13, 10, 0

; -----------------------------------------------------------------------
; GDT de 32 bits (unica en todo el proyecto)
; -----------------------------------------------------------------------
align 8
gdt32_start:
    dq 0x0000000000000000
    dq 0x00CF9A000000FFFF   ; 0x08 codigo 32-bit
    dq 0x00CF92000000FFFF   ; 0x10 datos  32-bit
gdt32_end:
gdt32_ptr:
    dw gdt32_end - gdt32_start - 1
    dd gdt32_start

; -----------------------------------------------------------------------
; GDT de 64 bits (unica en todo el proyecto)
; -----------------------------------------------------------------------
align 8
gdt64_start:
    dq 0x0000000000000000
    dq 0x00209A0000000000   ; 0x08 codigo 64-bit
    dq 0x0000920000000000   ; 0x10 datos  64-bit
gdt64_end:
gdt64_ptr:
    dw gdt64_end - gdt64_start - 1
    dd gdt64_start

; -----------------------------------------------------------------------
; Pilas (una sola declaracion de cada una en todo el proyecto)
; -----------------------------------------------------------------------
align 16
times 512  db 0
stack_top_32:

align 16
times 2048 db 0
stack_top_64:

; =============================================================================
; KERNEL 32-BIT
; =============================================================================
[BITS 32]

kernel_32_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, stack_top_32

    ; Habilitar PAE
    mov eax, cr4
    or  eax, (1 << 5)
    mov cr4, eax

    ; Tablas de paginas identidad 0-2MB en 0x1000/0x2000/0x3000
    ; (zona libre por debajo del bootloader, no usada por nadie mas)
    mov edi, 0x1000
    xor eax, eax
    mov ecx, 0x3000 / 4
    rep stosd
    mov dword [0x1000], 0x2003  ; PML4[0] -> 0x2000
    mov dword [0x2000], 0x3003  ; PDPT[0] -> 0x3000
    mov dword [0x3000], 0x0083  ; PD[0]   -> 2MB huge page identidad
    mov eax, 0x1000
    mov cr3, eax

    ; Activar Long Mode en EFER (ya verificamos que el CPU lo soporta)
    mov ecx, 0xC0000080
    rdmsr
    or  eax, (1 << 8)
    wrmsr

    ; Cargar GDT64 y activar paginacion + PE
    lgdt [gdt64_ptr]
    mov eax, cr0
    or  eax, 0x80000001
    mov cr0, eax

    jmp 0x08:kernel_64_entry

; =============================================================================
; KERNEL 64-BIT
; =============================================================================
[BITS 64]

kernel_64_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov rsp, stack_top_64
    cld                       ; asegurar DF=0 para todas las rep string ops

    call xk_init_video
    call exit_main_executor

.halt:
    cli
    hlt
    jmp .halt

; =============================================================================
; VARIABLES GLOBALES DEL KERNEL
; =============================================================================
global cursor_pos
global readline_buf
global exfs_cur_dir_name
global exfs_cur_dir_lba
global exfs_io_buf

cursor_pos:         dw 0             ; espejo de compatibilidad (row*80+col)
cursor_row:         db 0
cursor_col:         db 0
readline_buf:       times 256 db 0
exfs_cur_dir_name:  db '|', 0
                     times 126 db 0
exfs_cur_dir_lba:   dq 0
exfs_io_buf:        times 512 db 0

VGA_BASE equ 0xB8000
VGA_COLS equ 80
VGA_ROWS equ 25

; xk_init_video — limpia pantalla, resetea cursor
global xk_init_video
xk_init_video:
    push rdi
    push rcx
    push rax
    mov  rdi, VGA_BASE
    mov  rcx, VGA_COLS * VGA_ROWS
    mov  ax,  0x0720
    rep  stosw
    mov  byte [cursor_row], 0
    mov  byte [cursor_col], 0
    mov  word [cursor_pos], 0
    pop  rax
    pop  rcx
    pop  rdi
    ret

global xk_init_keyboard
xk_init_keyboard:
    push rax
.flush:
    in   al, 0x64
    test al, 1
    jz   .done
    in   al, 0x60
    jmp  .flush
.done:
    pop  rax
    ret

; xk_scroll — sube el contenido VGA una linea, limpia la ultima
global xk_scroll
xk_scroll:
    push rsi
    push rdi
    push rcx
    cld
    mov  rsi, VGA_BASE + VGA_COLS * 2
    mov  rdi, VGA_BASE
    mov  rcx, VGA_COLS * (VGA_ROWS - 1)
    rep  movsw
    mov  rdi, VGA_BASE + VGA_COLS * (VGA_ROWS - 1) * 2
    mov  rcx, VGA_COLS
    mov  ax,  0x0720
    rep  stosw
    mov  byte [cursor_row], VGA_ROWS - 1
    mov  ax,  VGA_COLS
    mul  byte [cursor_row]   ; AX = row*80, sin division
    mov  word [cursor_pos], ax
    pop  rcx
    pop  rdi
    pop  rsi
    ret

; xk_putchar — AL = caracter, BL = atributo de color
; Maneja: newline (10), retorno de carro (13), backspace (8), scroll automatico
; Rastrea fila/columna directamente: sin DIV en ninguna ruta.
global xk_putchar
xk_putchar:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi

    cmp al, 10
    je  .newline
    cmp al, 13
    je  .cr
    cmp al, 8
    je  .backspace

    ; ¿pantalla llena? scroll antes de escribir
    cmp  byte [cursor_row], VGA_ROWS
    jl   .write
    call xk_scroll
.write:
    movzx rcx, byte [cursor_row]
    imul  rcx, VGA_COLS
    movzx rdx, byte [cursor_col]
    add   rcx, rdx
    shl   rcx, 1
    add   rcx, VGA_BASE
    mov   ah, bl
    mov   word [rcx], ax

    inc   byte [cursor_col]
    cmp   byte [cursor_col], VGA_COLS
    jl    .sync
    mov   byte [cursor_col], 0
    inc   byte [cursor_row]
    jmp   .sync

.newline:
    mov  byte [cursor_col], 0
    inc  byte [cursor_row]
    jmp  .sync

.cr:
    mov  byte [cursor_col], 0
    jmp  .sync

.backspace:
    cmp  byte [cursor_col], 0
    je   .done
    dec  byte [cursor_col]
    movzx rcx, byte [cursor_row]
    imul  rcx, VGA_COLS
    movzx rax, byte [cursor_col]
    add   rcx, rax
    shl   rcx, 1
    add   rcx, VGA_BASE
    mov   word [rcx], 0x0720
    jmp   .done

.sync:
    cmp  byte [cursor_row], VGA_ROWS
    jl   .mirror
    call xk_scroll
    jmp  .done
.mirror:
    ; cursor_pos como espejo de compatibilidad (row*80+col), sin DIV
    movzx rax, byte [cursor_row]
    imul  rax, VGA_COLS
    movzx rcx, byte [cursor_col]
    add   rax, rcx
    mov   word [cursor_pos], ax

.done:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; xk_print — RSI = string null-terminated, BL = atributo
global xk_print
xk_print:
    push rax
    push rsi
.lp:
    lodsb
    test al, al
    jz   .done
    call xk_putchar
    jmp  .lp
.done:
    pop rsi
    pop rax
    ret

; xk_println — xk_print + newline
global xk_println
xk_println:
    call xk_print
    push rax
    push rbx
    mov  al, 10
    mov  bl, 0x07
    call xk_putchar
    pop  rbx
    pop  rax
    ret

; xk_readline — lee linea real del teclado PS/2 (scancode set 1)
; Entrada: RDI = buffer destino, RCX = max caracteres
; Salida:  RAX = longitud leida; buffer null-terminado
scancode_map:
    db 0,0,'1','2','3','4','5','6','7','8','9','0','-','=',8,9
    db 'q','w','e','r','t','y','u','i','o','p','[',']',13,0
    db 'a','s','d','f','g','h','j','k','l',59,39,96,0,92
    db 'z','x','c','v','b','n','m',44,46,47,0,0,0,32
    times (256 - ($ - scancode_map)) db 0

global xk_readline
xk_readline:
    push rbx
    push rdx
    push rdi
    push rcx

    xor  rdx, rdx            ; longitud actual

.rd:
    in   al, 0x64
    test al, 1
    jz   .rd
    in   al, 0x60

    cmp  al, 0x80             ; key-up, ignorar
    jge  .rd

    push rbx
    lea  rbx, [rel scancode_map]
    movzx rax, al
    mov  al, [rbx + rax]
    pop  rbx

    test al, al
    jz   .rd

    cmp  al, 13
    je   .enter
    cmp  al, 8
    je   .bs

    cmp  rdx, rcx
    jge  .rd
    mov  [rdi], al
    inc  rdi
    inc  rdx
    mov  bl, 0x0F
    call xk_putchar
    jmp  .rd

.bs:
    test rdx, rdx
    jz   .rd
    dec  rdi
    dec  rdx
    push rax
    mov  al, 8
    mov  bl, 0x07
    call xk_putchar
    mov  al, ' '
    call xk_putchar
    mov  al, 8
    call xk_putchar
    pop  rax
    jmp  .rd

.enter:
    mov  byte [rdi], 0
    mov  rax, rdx
    push rax
    mov  al, 10
    mov  bl, 0x07
    call xk_putchar
    pop  rax

    pop  rcx
    pop  rdi
    pop  rdx
    pop  rbx
    ret

; xk_getkey — lectura cruda de una tecla (para editores/apps interactivas)
; Salida: AL = ascii traducido (0 si no mapeado), AH = scancode crudo
global xk_getkey
xk_getkey:
    push rbx
    push rdx
.rd:
    in   al, 0x64
    test al, 1
    jz   .rd
    in   al, 0x60
    cmp  al, 0x80
    jge  .rd
    mov  dl, al
    lea  rbx, [rel scancode_map]
    movzx rax, al
    mov  al, [rbx + rax]
    mov  ah, dl
    pop  rdx
    pop  rbx
    ret

; =============================================================================
; UTILIDADES DE STRING (una sola definicion de cada una)
; =============================================================================

global xk_strcmp
xk_strcmp:
    push rsi
    push rdi
    push rbx
.lp:
    mov  al, [rsi]
    mov  bl, [rdi]
    cmp  al, bl
    jne  .neq
    test al, al
    jz   .eq
    inc  rsi
    inc  rdi
    jmp  .lp
.eq:
    xor  rax, rax
    pop  rbx
    pop  rdi
    pop  rsi
    ret
.neq:
    mov  rax, 1
    pop  rbx
    pop  rdi
    pop  rsi
    ret

global xk_strlen
xk_strlen:
    push rsi
    xor  rax, rax
.lp:
    cmp  byte [rsi], 0
    je   .done
    inc  rsi
    inc  rax
    jmp  .lp
.done:
    pop  rsi
    ret

global xk_strncpy
xk_strncpy:
    test rcx, rcx
    jz   .done
.lp:
    mov  al, [rsi]
    mov  [rdi], al
    inc  rsi
    inc  rdi
    test al, al
    jz   .done
    dec  rcx
    jnz  .lp
.done:
    ret

; =============================================================================
; MODULOS DEL SISTEMA
; =============================================================================
%include "src/drivers/exfs.asm"
%include "src/init/exit.asm"
%include "src/apps/xsh/xsh.asm"
