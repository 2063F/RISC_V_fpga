"""
uart_echo.py  -  手動アセンブラ (RISC-V RV32I)
受信したシリアルデータをそのまま送信する（エコーバック）プログラムを生成する。
"""

import struct

def lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37

def addi(rd, rs1, imm12):
    imm12 = imm12 & 0xFFF
    return (imm12 << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13

def lw(rd, rs1, offset):
    offset = offset & 0xFFF
    return (offset << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0x03

def sw(rs1, rs2, offset):
    offset = offset & 0xFFF
    imm11_5 = (offset >> 5) & 0x7F
    imm4_0  = offset & 0x1F
    return (imm11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (0b010 << 12) | (imm4_0 << 7) | 0x23

def andi_inst(rd, rs1, imm12):
    imm12 = imm12 & 0xFFF
    return (imm12 << 20) | (rs1 << 15) | (0b111 << 12) | (rd << 7) | 0x13

def beq(rs1, rs2, offset):
    """BEQ rs1, rs2, offset (PC-relative, in bytes)"""
    offset = offset & 0x1FFF
    imm12   = (offset >> 12) & 1
    imm11   = (offset >> 11) & 1
    imm10_5 = (offset >> 5)  & 0x3F
    imm4_1  = (offset >> 1)  & 0xF
    return (imm12 << 31) | (imm10_5 << 25) | (rs2 << 20) | (rs1 << 15) | \
           (0b000 << 12) | (imm4_1 << 8) | (imm11 << 7) | 0x63

def bne(rs1, rs2, offset):
    """BNE rs1, rs2, offset (PC-relative, in bytes)"""
    offset = offset & 0x1FFF
    imm12   = (offset >> 12) & 1
    imm11   = (offset >> 11) & 1
    imm10_5 = (offset >> 5)  & 0x3F
    imm4_1  = (offset >> 1)  & 0xF
    return (imm12 << 31) | (imm10_5 << 25) | (rs2 << 20) | (rs1 << 15) | \
           (0b001 << 12) | (imm4_1 << 8) | (imm11 << 7) | 0x63

def jal(rd, offset):
    offset = offset & 0x1FFFFF
    imm20    = (offset >> 20) & 1
    imm10_1  = (offset >> 1)  & 0x3FF
    imm11    = (offset >> 11) & 1
    imm19_12 = (offset >> 12) & 0xFF
    return (imm20 << 31) | (imm19_12 << 12) | (imm11 << 20) | (imm10_1 << 21) | \
           (rd << 7) | 0x6F

def li_macro(rd, imm):
    imm = imm & 0xFFFFFFFF
    imm_s = imm if imm < 0x80000000 else imm - 0x100000000
    lo12 = imm_s & 0xFFF
    if lo12 >= 0x800:
        lo12 -= 0x1000
    hi20 = (imm_s - lo12) >> 12

    insts = []
    if hi20 != 0:
        insts.append(lui(rd, hi20 & 0xFFFFF))
        if lo12 != 0:
            insts.append(addi(rd, rd, lo12 & 0xFFF))
    else:
        insts.append(addi(rd, 0, lo12 & 0xFFF))
    return insts

UART_TX_ADDR      = 0x80000010
UART_STAT_ADDR    = 0x80000014
UART_RX_ADDR      = 0x80000018
UART_RX_STAT_ADDR = 0x8000001C

x0, x5, x6, x10, x11, x12, x13 = 0, 5, 6, 10, 11, 12, 13

instructions = []

def emit(inst):
    instructions.append(inst & 0xFFFFFFFF)

def current_pc():
    return len(instructions) * 4

# Initialize addresses
for inst in li_macro(x10, UART_TX_ADDR):      emit(inst)
for inst in li_macro(x11, UART_STAT_ADDR):    emit(inst)
for inst in li_macro(x12, UART_RX_ADDR):      emit(inst)
for inst in li_macro(x13, UART_RX_STAT_ADDR): emit(inst)

# loop start
loop_pc = current_pc()

# wait_rx:
wait_rx_pc = current_pc()
emit(lw(x6, x13, 0))               # lw x6, 0(x13)  (read rx status)
emit(andi_inst(x6, x6, 1))         # andi x6, x6, 1
bne_rx_pc = current_pc()
emit(beq(x6, x0, (wait_rx_pc - bne_rx_pc) & 0x1FFF)) # beq x6, x0, wait_rx

# read rx data
emit(lw(x5, x12, 0))               # lw x5, 0(x12)  (read received byte)

# wait_tx:
wait_tx_pc = current_pc()
emit(lw(x6, x11, 0))               # lw x6, 0(x11)  (read tx status busy)
emit(andi_inst(x6, x6, 1))         # andi x6, x6, 1
bne_tx_pc = current_pc()
emit(bne(x6, x0, (wait_tx_pc - bne_tx_pc) & 0x1FFF)) # bne x6, x0, wait_tx

# send tx data
emit(sw(x10, x5, 0))               # sw x5, 0(x10)  (write to tx data)

# j loop
j_loop_pc = current_pc()
emit(jal(x0, (loop_pc - j_loop_pc) & 0x1FFFFF))

print(f"Total instructions: {len(instructions)}")
with open("src/uart_echo.hex", "w") as f:
    for inst in instructions:
        f.write(f"{inst:08x}\n")

print("src/uart_echo.hex written OK")
