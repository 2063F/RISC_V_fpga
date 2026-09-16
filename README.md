# RISK_V_fpga

Tang Primer 25K (Gowin GW5A-LV25MG121) 上で動作する RISC-V 互換 32ビット CPU を
ゼロから設計・実装するプロジェクトです。

## 目標

RV32I 命令セットを段階的に実装し、シングルサイクルCPU から始めて、
最終的にパイプライン化された CPU + SoC を構築します。

## 現在の完成状況

- RV32I の基本演算、即値演算、分岐、ジャンプ、ロード/ストアを実装済み
- RV32M の乗算・除算命令を実装済み
- Scratch RAM と UART TX の MMIO を接続済み
- 2段パイプライン化（フェッチ + 実行/書き戻し）を導入済み
- `tb_cpu_top.v`, `tb_branch.v`, `tb_memory_full.v`, `tb_uart_cpu.v` で動作確認済み

## 開発ロードマップ

| Phase | 内容 | 状態 |
|:------|:-----|:-----|
| 1 | 開発環境セットアップ & LED点滅 | ✅ |
| 2 | 基本コンポーネント (ALU, レジスタ, デコーダ) | ✅ |
| 3 | シングルサイクルCPU (計算命令のみ) | ✅ |
| 4 | メモリ命令 (Load/Store) 追加 | ✅ |
| 5 | 分岐・ジャンプ追加 (チューリング完全) | ✅ |
| 6 | UART デバッグ環境 | ✅ |
| 7+ | M拡張 / パイプライン化 / SDRAM | 🔧 作業中 |

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

### C 言語プログラムを実行する方法

このリポジトリでは、RISC-V 向けのツールチェーンが見つからないため、まずは以下のように
「C ソースを RV32I 用の機械語へ変換する流れ」を README 側で整理しています。

```bash
# 1. C ソースをコンパイル
#    (実際には riscv64-unknown-elf-gcc などのツールチェーンが必要)

# 2. ELF を生バイナリへ変換
#    objcopy -O binary a.out program.bin

# 3. 32-bit words に整形して hex 化
#    python tools/elf2hex.py program.bin > src/program.hex

# 4. CPU の初期化ファイルとして利用
#    例: fpga_top.v で program.hex を読み込む
```

### 波形表示

```bash
gtkwave <filename>.vcd
```

## RISC-V ツールチェーン導入手順 (Windows)

既に Gowin EDA、Icarus Verilog、GTKWave は導入済みである前提で、
C 言語プログラムを実行するために必要な追加ツールは RISC-V クロスコンパイラです。

### 1. 追加で必要なもの

- `riscv64-unknown-elf-gcc`
- `riscv64-unknown-elf-objcopy`
- `riscv64-unknown-elf-objdump`

### 2. 導入方法

1. 公式または信頼できる配布元から Windows 用の prebuilt toolchain を入手
2. 任意のフォルダ (例: `C:\riscv`) に展開
3. `C:\riscv\bin` を PATH に追加

### 3. 動作確認

PowerShell で次を実行します。

```powershell
riscv64-unknown-elf-gcc --version
riscv64-unknown-elf-objcopy --version
riscv64-unknown-elf-objdump --version
```

3 つとも表示されれば導入成功です。

### 4. 自動インストールスクリプト

このリポジトリには、Windows 向けの支援スクリプトがあります。

```powershell
# 1) リポジトリのルートへ移動
#    ※ ここは実際の保存先に置き換えてください
#      例: C:\Users\yourname\Documents\RISK_V_fpga
Set-Location -Path "C:\path\to\RISK_V_fpga"

# 2) スクリプトを実行
powershell -ExecutionPolicy Bypass -File ".\tools\install_riscv_toolchain.ps1"
```

このスクリプトは `winget` を使って導入を試み、必要に応じて PATH の設定案内も出します。

> もし PowerShell で `Set-Location` の引数が連結してエラーになる場合は、**各コマンドを別行で実行**してください。  
> さらに、`C:\path\to\RISK_V_fpga` の部分は **実際のリポジトリの保存場所** に置き換えてください。  
> そのうえで `-File` のパスエラーが出る場合は、**絶対パス**で実行してください。  
> 例: `powershell -ExecutionPolicy Bypass -File "C:\Users\yourname\Documents\RISK_V_fpga\tools\install_riscv_toolchain.ps1"`
>
> インストール後は **PowerShell を一度閉じて再度開く** か、`where.exe riscv64-unknown-elf-gcc` で確認してください。

### 5. ビルドして使う

サンプルは 2 本あります。

- `examples/loop55.c`: 1 から 10 までの加算結果 55 を LED で確認するサンプル
- `examples/button_led.c`: `user_btn` で `led[1]` を切り替える MMIO サンプル

```powershell
# loop55
riscv64-unknown-elf-gcc -O2 -nostdlib -nostartfiles -T tools/link.ld \
  tools/crt0.S examples/loop55.c -o examples/loop55.elf
riscv64-unknown-elf-objcopy -O binary examples/loop55.elf examples/loop55.bin
python tools/elf2hex.py examples/loop55.bin > examples/loop55.hex

# button_led
riscv64-unknown-elf-gcc -O2 -nostdlib -nostartfiles -T tools/link.ld \
  tools/crt0.S examples/button_led.c -o examples/button_led.elf
riscv64-unknown-elf-objcopy -O binary examples/button_led.elf examples/button_led.bin
python tools/elf2hex.py examples/button_led.bin > examples/button_led.hex
```

生成した `*.hex` はそのまま CPU の初期化ファイルとして使えます。
たとえば `fpga_top` の `INIT_FILE` を `examples/loop55.hex` または `examples/button_led.hex` に変更してください。

### 6. FPGA 実機の起動手順

1. まずサンプルを hex に変換します。
  - 起動確認だけなら `examples/loop55.hex`
  - ボタン/LED の MMIO 確認なら `examples/button_led.hex`
2. `src/fpga_top.v` の `INIT_FILE` を使いたい hex に合わせます。
  - 既定値は `examples/loop55.hex` です。
3. Gowin EDA で `build.tcl` を実行して合成・配置配線します。
4. Tang Primer 25K に書き込みます。
5. リセット後、`loop55` なら `led[1]` が 55 完了で ON、`button_led` なら `user_btn` を押すたびに `led[1]` が切り替わります。

### 7. 追加で便利な確認コマンド

```powershell
riscv64-unknown-elf-objdump -d examples/loop55.elf
```

## ツール

- **Gowin EDA** - 論理合成・配置配線
- **Icarus Verilog** - シミュレーション
- **GTKWave** - 波形表示
