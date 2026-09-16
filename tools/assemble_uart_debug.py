"""
assemble_uart_debug.py - 手動アセンブラ (RISC-V RV32I)
レジスタ x1〜x5 の値を 16 進数 (Hex) で UART へダンプするデバッグプログラムを生成する。
"""

import struct

def lui(rd, imm20): return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37
def addi(rd, rs1, imm12): return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13
def lw(rd, rs1, offset): return ((offset & 0xFFF) << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0x03
def sw(rs1, rs2, offset):
    off = offset & 0xFFF
    return (((off >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (0b010 << 12) | ((off & 0x1F) << 7) | 0x23
def andi_inst(rd, rs1, imm12): return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b111 << 12) | (rd << 7) | 0x13
def srli(rd, rs1, shamt): return ((0 << 25) | (shamt & 0x1F) << 20) | (rs1 << 15) | (0b101 << 12) | (rd << 7) | 0x13
def slli(rd, rs1, shamt): return ((0 << 25) | (shamt & 0x1F) << 20) | (rs1 << 15) | (0b001 << 12) | (rd << 7) | 0x13
def bne(rs1, rs2, offset):
    off = offset & 0x1FFF
    return (((off >> 12) & 1) << 31) | (((off >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (0b001 << 12) | (((off >> 1) & 0xF) << 8) | (((off >> 11) & 1) << 7) | 0x63
def blt(rs1, rs2, offset):
    off = offset & 0x1FFF
    return (((off >> 12) & 1) << 31) | (((off >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (0b100 << 12) | (((off >> 1) & 0xF) << 8) | (((off >> 11) & 1) << 7) | 0x63
def jal(rd, offset):
    off = offset & 0x1FFFFF
    return (((off >> 20) & 1) << 31) | (((off >> 12) & 0xFF) << 12) | (((off >> 11) & 1) << 20) | \
           (((off >> 1) & 0x3FF) << 21) | (rd << 7) | 0x6F
def jalr(rd, rs1, offset=0): return ((offset & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x67

def mul(rd, rs1, rs2):
    return (0x01 << 25) | (rs2 << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x33
def div(rd, rs1, rs2):
    return (0x01 << 25) | (rs2 << 20) | (rs1 << 15) | (4 << 12) | (rd << 7) | 0x33

def li_macro(rd, imm):
    imm = imm & 0xFFFFFFFF
    imm_s = imm if imm < 0x80000000 else imm - 0x100000000
    lo12 = imm_s & 0xFFF
    if lo12 >= 0x800:
        lo12 -= 0x1000
    hi20 = (imm_s - lo12) >> 12
    if hi20 != 0:
        insts = [lui(rd, hi20 & 0xFFFFF)]
        if lo12 != 0: insts.append(addi(rd, rd, lo12 & 0xFFF))
        return insts
    else:
        return [addi(rd, 0, lo12 & 0xFFF)]

# レジスタマップ:
# x10: UART TX データレジスタアドレス (0x80000010)
# x11: UART ステータスレジスタアドレス (0x80000014)
# x1: ra (戻りアドレス)
# x2: sp (スタック代わりに一時変数保存などで退避用)
# x8: 被乗数/被除数
# x9: 乗数/除数
# x21: 積 (mul)
# x22: 商 (div)
# x20: ループカウンタ用

UART_TX_ADDR = 0x80000010
UART_STAT_ADDR = 0x80000014

instructions = []
placeholders = {} # label_name -> list of (index, type)

def emit(inst):
    instructions.append(inst & 0xFFFFFFFF)

def current_pc():
    return len(instructions) * 4

# _start:
# MMIO アドレス初期化
for inst in li_macro(10, UART_TX_ADDR): emit(inst)
for inst in li_macro(11, UART_STAT_ADDR): emit(inst)

# テスト用の計算レジスタに初期値をセット
emit(addi(8, 0, 15))      # x8 = 15
emit(addi(9, 0, 3))       # x9 = 3

# メインループ開始位置
main_loop_pc = current_pc()

# 演算実行
emit(mul(21, 8, 9))       # x21 = x8 * x9 (積)
emit(div(22, 8, 9))       # x22 = x8 / x9 (商)

# "A=" 送信
emit(addi(5, 0, 0x41)) # 'A'
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(5, 0, 0x3D)) # '='
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(12, 8, 0)) # x12 = A
placeholders[len(instructions)] = ("print_hex", "jal")
emit(0xDEADBEEF)

# "  MUL=" 送信
emit(addi(5, 0, 0x20)) # ' '
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(5, 0, 0x4D)) # 'M'
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(5, 0, 0x55)) # 'U'
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(5, 0, 0x4C)) # 'L'
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(5, 0, 0x3D)) # '='
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(12, 21, 0)) # x12 = mul
placeholders[len(instructions)] = ("print_hex", "jal")
emit(0xDEADBEEF)

# "  DIV=" 送信
emit(addi(5, 0, 0x20)) # ' '
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(5, 0, 0x44)) # 'D'
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(5, 0, 0x49)) # 'I'
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(5, 0, 0x56)) # 'V'
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(5, 0, 0x3D)) # '='
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(12, 22, 0)) # x12 = div
placeholders[len(instructions)] = ("print_hex", "jal")
emit(0xDEADBEEF)

# '\r\n' 送信
emit(addi(5, 0, 0x0D))
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)
emit(addi(5, 0, 0x0A))
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)

# テスト値更新 (A = A + 5)
emit(addi(8, 8, 5))

# 遅延ウェイトループ (約 5,000,000 サイクル ➔ 0.1秒)
for inst in li_macro(20, 5000000): emit(inst)
wait_loop_pc = current_pc()
emit(addi(20, 20, -1))
# bne x20, x0, wait_loop
emit(bne(20, 0, (wait_loop_pc - current_pc()) & 0x1FFF))

# 無限ループ (main_loop へ戻る)
placeholders[len(instructions)] = ("main_loop", "jal_x0")
emit(0xDEADBEEF)

# ---------------------------------------------------------------------------
# 関数: print_hex
# 入力: x12 = 32ビット数値
# 破壊レジスタ: x5, x6, x7, x13, x14
# ---------------------------------------------------------------------------
print_hex_pc = current_pc()
emit(addi(2, 1, 0)) # 戻りアドレスを x2(sp) に退避 (簡易フレーム)

# カウンタ x13 = 8 (8桁分ループ)
emit(addi(13, 0, 8))

hex_loop_pc = current_pc()
# 最上位4ビットを取り出す (x12 の bit 28-31)
emit(srli(14, 12, 28)) # x14 = x12 >> 28
# x12 = x12 << 4 (次の桁のためにシフト)
emit(slli(12, 12, 4))

# x14 の値をアスキー文字に変換 (0-9 は +0x30, A-F は +0x37)
emit(addi(5, 0, 10))
# if x14 < 10 (addi(5) = 10) -> skip_hex_alpha
skip_branch_idx = len(instructions)
emit(0xDEADBEEF) # blt x14, x5, skip_hex_alpha プレースホルダ

# A-F の場合
emit(addi(5, 14, 0x37)) # 'A' = 10 + 0x37 = 0x41
placeholders[len(instructions)] = ("print_char", "jal")
emit(0xDEADBEEF)
placeholders[len(instructions)] = ("hex_loop_end", "jal_x0")
emit(0xDEADBEEF)

# 0-9 の場合
skip_hex_alpha_pc = current_pc()
emit(addi(5, 14, 0x30)) # '0' = 0x30

# 文字送信
print_char_pc = current_pc() # bltからここへ飛ばす
placeholders[len(instructions)] = ("send_byte", "jal")
emit(0xDEADBEEF)

# ループ制御
hex_loop_end_pc = current_pc()
emit(addi(13, 13, -1))
emit(bne(13, 0, (hex_loop_pc - current_pc()) & 0x1FFF))

# 復帰して ret
emit(addi(1, 2, 0)) # 戻りアドレスを x1 に復帰
emit(jalr(0, 1, 0))

# blt 命令のパッチ
instructions[skip_branch_idx] = blt(14, 5, (skip_hex_alpha_pc - (skip_branch_idx * 4)) & 0x1FFF)

# ---------------------------------------------------------------------------
# 関数: send_byte
# 入力: x5 = 送信文字
# ---------------------------------------------------------------------------
send_byte_pc = current_pc()
# wait_ready:
wait_ready_pc = current_pc()
emit(lw(6, 11, 0))              # lw x6, 0(x11)
emit(andi_inst(6, 6, 1))        # andi x6, x6, 1
emit(bne(6, 0, (wait_ready_pc - current_pc()) & 0x1FFF))
emit(sw(10, 5, 0))              # sw x5, 0(x10)
emit(jalr(0, 1, 0))             # ret

# ---------------------------------------------------------------------------
# プレースホルダ解決 (JAL / J Loop)
for idx, (label, mode) in placeholders.items():
    curr_pc = idx * 4
    if label == "send_byte":
        target = send_byte_pc
    elif label == "print_hex":
        target = print_hex_pc
    elif label == "main_loop":
        target = main_loop_pc
    elif label == "print_char":
        target = print_char_pc
    elif label == "hex_loop_end":
        target = hex_loop_end_pc
    else:
        continue
    
    offset = target - curr_pc
    if mode == "jal":
        instructions[idx] = jal(1, offset & 0x1FFFFF)
    elif mode == "jal_x0":
        instructions[idx] = jal(0, offset & 0x1FFFFF)

# 出力
with open("src/uart_debug.hex", "w") as f:
    for inst in instructions:
        f.write(f"{inst:08x}\n")

print("src/uart_debug.hex generated successfully. Total instructions:", len(instructions))
