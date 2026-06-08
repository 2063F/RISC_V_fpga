"""
uart_hello.py  -  手動アセンブラ (RISC-V RV32I)
"Hello, RISC-V!\r\n" をUART MMIO 0x8000_0010 へ繰り返し送信するプログラムを生成する。

レジスタ割当:
  x10 = 0x80000010  (UART TX data)
  x11 = 0x80000014  (UART TX status)
  x5  = 送信バイト
  x6  = busyステータス作業レジスタ
  x1  = ra (return address for send_byte)
"""

import struct

def lui(rd, imm20):
    """LUI rd, imm20 (upper 20 bits)"""
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
    """JAL rd, offset (PC-relative, in bytes)"""
    offset = offset & 0x1FFFFF
    imm20    = (offset >> 20) & 1
    imm10_1  = (offset >> 1)  & 0x3FF
    imm11    = (offset >> 11) & 1
    imm19_12 = (offset >> 12) & 0xFF
    return (imm20 << 31) | (imm19_12 << 12) | (imm11 << 20) | (imm10_1 << 21) | \
           (rd << 7) | 0x6F

def jalr(rd, rs1, offset=0):
    """JALR rd, rs1, offset  (= RET when rd=x0, rs1=x1, offset=0)"""
    offset = offset & 0xFFF
    return (offset << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x67

# ---------------------------------------------------------------------------
# li マクロ (load immediate 32bit)
# lui + addi  or  addi x0 only
# LUI imm は upper 20bit, ただし下位12bitが負なら+1補正
def li_macro(rd, imm):
    imm = imm & 0xFFFFFFFF
    imm_s = imm if imm < 0x80000000 else imm - 0x100000000  # sign-extend
    lo12 = imm_s & 0xFFF
    if lo12 >= 0x800:          # 12bit signed: negative → adjust upper
        lo12 -= 0x1000
    hi20 = (imm_s - lo12) >> 12

    insts = []
    if hi20 != 0:
        insts.append(lui(rd, hi20 & 0xFFFFF))
        if lo12 != 0:
            insts.append(addi(rd, rd, lo12 & 0xFFF))
    else:
        # small immediate: ADDI rd, x0, lo12
        insts.append(addi(rd, 0, lo12 & 0xFFF))
    return insts

# ---------------------------------------------------------------------------
# Program layout  (base = 0x0000_0000, word-indexed)
# We will lay instructions out as a list and resolve labels by index.
#
# Registers:
#  x1  = ra
#  x5  = t0 (byte to send)
#  x6  = t1 (busy flag work)
#  x10 = a0 = 0x80000010 (TX data addr)
#  x11 = a1 = 0x80000014 (TX status addr)

# "Hello, RISC-V!\r\n"
message = [0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x2C, 0x20,
           0x52, 0x49, 0x53, 0x43, 0x2D, 0x56, 0x21,
           0x0D, 0x0A]

# -----------------------------------------------------------------------
# Phase 1: 命令数を先に数えてラベルを決定する
# _start:         (PC = 0)
#   li x10, 0x80000010   → 2 insts (lui + addi)
#   li x11, 0x80000014   → 2 insts
# send_string:    (PC word = 4)
#   for each byte in message: li x5, byte (1 inst) + jal x1, send_byte (1 inst)
#                             = 2 insts × 16 bytes = 32 insts
#   j send_string                                   = 1 inst (jal x0, back)
# send_byte:  (PC word = 4+32+1 = 37)
# wait_ready:
#   lw x6, 0(x11)                                   = 1
#   andi x6, x6, 1                                  = 1
#   bne x6, x0, wait_ready (offset = -8 bytes)      = 1
#   sw x5, 0(x10)                                   = 1
#   jalr x0, x1, 0  (ret)                           = 1
#                                             total  = 42 insts

UART_TX_ADDR   = 0x80000010
UART_STAT_ADDR = 0x80000014

x0, x1, x5, x6, x10, x11 = 0, 1, 5, 6, 10, 11

instructions = []  # list of 32-bit words

def emit(inst):
    instructions.append(inst & 0xFFFFFFFF)

def current_pc():
    return len(instructions) * 4

# _start
for inst in li_macro(x10, UART_TX_ADDR):   emit(inst)   # 2 insts
for inst in li_macro(x11, UART_STAT_ADDR): emit(inst)   # 2 insts

# send_string label @ word 4
send_string_pc = current_pc()

for byte_val in message:
    for inst in li_macro(x5, byte_val):     emit(inst)  # 1 inst each (small imm)
    # jal x1, send_byte  -- offset resolved later, placeholder 0
    instructions.append(0xDEADBEEF)  # placeholder

j_back_idx = len(instructions)
instructions.append(0xDEADBEEF)  # j send_string placeholder

# send_byte label @ word j_back_idx+1
send_byte_pc = current_pc()

# wait_ready:
wait_ready_pc = current_pc()
emit(lw(x6, x11, 0))              # lw x6, 0(x11)
emit(andi_inst(x6, x6, 1))        # andi x6, x6, 1
# bne x6, x0, wait_ready (offset = wait_ready_pc - current_pc)
bne_pc = current_pc()
emit(bne(x6, x0, (wait_ready_pc - bne_pc) & 0x1FFF))
emit(sw(x10, x5, 0))              # sw x5, 0(x10)
emit(jalr(x0, x1, 0))             # ret

# ---------------------------------------------------------------------------
# Resolve JAL placeholders
for i, byte_val in enumerate(message):
    jal_idx = 4 + i * 2 + 1   # index in instructions[]
    jal_pc  = jal_idx * 4
    offset  = send_byte_pc - jal_pc
    instructions[jal_idx] = jal(x1, offset & 0x1FFFFF)

# j send_string
jback_pc = j_back_idx * 4
offset = (send_string_pc - jback_pc) & 0x1FFFFF
instructions[j_back_idx] = jal(x0, offset)

# ---------------------------------------------------------------------------
# Output as hex file
print(f"Total instructions: {len(instructions)}")
print("Address  Hex        Binary")
for i, inst in enumerate(instructions):
    print(f"  {i*4:04x}  {inst:08x}   {inst:032b}")

with open("src/uart_hello.hex", "w") as f:
    for inst in instructions:
        f.write(f"{inst:08x}\n")

print("\nsrc/uart_hello.hex written OK")
