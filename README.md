# RISK_V_fpga

Tang Primer 25K (Gowin GW5A-LV25MG121) 上で動作する RISC-V 互換 32ビット CPU を
ゼロから設計・実装するプロジェクトです。

## 目標

RV32I 命令セットを段階的に実装し、シングルサイクルCPU から始めて、
最終的にパイプライン化された CPU + SoC を構築します。

## 開発ロードマップ

| Phase | 内容 | 状態 |
|:------|:-----|:-----|
| 1 | 開発環境セットアップ & LED点滅 | 🔧 作業中 |
| 2 | 基本コンポーネント (ALU, レジスタ, デコーダ) | ⬜ |
| 3 | シングルサイクルCPU (計算命令のみ) | ⬜ |
| 4 | メモリ命令 (Load/Store) 追加 | ⬜ |
| 5 | 分岐・ジャンプ追加 (チューリング完全) | ⬜ |
| 6 | UART デバッグ環境 | ⬜ |
| 7+ | M拡張 / パイプライン化 / SDRAM | ⬜ |

## ISA

- **ベース**: RV32I (RISC-V Base Integer Instruction Set, 32-bit)
- **レジスタ**: 32本 × 32ビット (x0 = 常に0)
- **命令長**: 固定 32ビット
- **命令数**: 40

## ディレクトリ構成

```
RISK_V_fpga/
├── src/                      # Verilog ソースファイル
│   ├── riscv_defines.vh      # 共通定義
│   ├── blinky.v              # LED点滅テスト (Phase 1)
│   ├── alu.v                 # ALU (Phase 2)
│   ├── register_file.v       # レジスタファイル (Phase 2)
│   ├── instruction_decoder.v # デコーダ (Phase 2)
│   └── cpu_top.v             # CPUトップ (Phase 3)
├── sim/                      # テストベンチ
│   ├── tb_alu.v
│   ├── tb_register_file.v
│   └── tb_cpu_top.v
├── constraints/              # FPGA制約ファイル
│   ├── tang_primer_25k.cst   # ピン制約
│   └── timing.sdc            # タイミング制約
└── README.md
```

## ターゲットボード

- **FPGA**: Sipeed Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
- **LUT4**: 23,040
- **FF**: 23,040
- **B-SRAM**: 1,008 Kbits (56ブロック)
- **乗算器**: 28 (18×18)
- **クロック**: 50 MHz

## シミュレーション実行方法

### Icarus Verilog を使用する場合

```bash
# ALU テスト
iverilog -I src -o sim/tb_alu.out sim/tb_alu.v src/alu.v
vvp sim/tb_alu.out

# レジスタファイル テスト
iverilog -I src -o sim/tb_regfile.out sim/tb_register_file.v src/register_file.v
vvp sim/tb_regfile.out
```

### 波形表示

```bash
gtkwave <filename>.vcd
```

## ツール

- **Gowin EDA** - 論理合成・配置配線
- **Icarus Verilog** - シミュレーション
- **GTKWave** - 波形表示
