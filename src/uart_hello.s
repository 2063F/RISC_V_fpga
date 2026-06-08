# =============================================================================
# uart_hello.s - RISC-V RV32I UART Hello World
# =============================================================================
# 動作:
#   "Hello, RISC-V!\n" を115200bps UARTで繰り返し送信する
# MMIO Map:
#   0x80000010 : UART TX data register  (byte write → 1バイト送信)
#   0x80000014 : UART TX status register (bit0 = busy: 1=送信中)
# =============================================================================

.section .text
.global _start

_start:
    # MMIO base addresses
    li   x10, 0x80000010    # x10 = UART TX register address
    li   x11, 0x80000014    # x11 = UART status register address

send_string:
    # --- 'H' = 0x48 ---
    li   x5, 0x48
    call send_byte
    # --- 'e' = 0x65 ---
    li   x5, 0x65
    call send_byte
    # --- 'l' = 0x6C ---
    li   x5, 0x6C
    call send_byte
    # --- 'l' = 0x6C ---
    li   x5, 0x6C
    call send_byte
    # --- 'o' = 0x6F ---
    li   x5, 0x6F
    call send_byte
    # --- ',' = 0x2C ---
    li   x5, 0x2C
    call send_byte
    # --- ' ' = 0x20 ---
    li   x5, 0x20
    call send_byte
    # --- 'R' = 0x52 ---
    li   x5, 0x52
    call send_byte
    # --- 'I' = 0x49 ---
    li   x5, 0x49
    call send_byte
    # --- 'S' = 0x53 ---
    li   x5, 0x53
    call send_byte
    # --- 'C' = 0x43 ---
    li   x5, 0x43
    call send_byte
    # --- '-' = 0x2D ---
    li   x5, 0x2D
    call send_byte
    # --- 'V' = 0x56 ---
    li   x5, 0x56
    call send_byte
    # --- '!' = 0x21 ---
    li   x5, 0x21
    call send_byte
    # --- '\r' = 0x0D ---
    li   x5, 0x0D
    call send_byte
    # --- '\n' = 0x0A ---
    li   x5, 0x0A
    call send_byte

    j    send_string    # 無限ループ

# =============================================================================
# send_byte: x5 = 送信バイト
#   x10, x11 を使う（保存なし）
#   ra = リターンアドレス
# =============================================================================
send_byte:
wait_ready:
    lw   x6, 0(x11)     # x6 = busy status
    andi x6, x6, 1      # bit0 のみ
    bne  x6, x0, wait_ready   # busy なら待つ
    sw   x5, 0(x10)     # 送信
    ret
