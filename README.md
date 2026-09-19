# RISK_V_fpga

Tang Primer 25K (Gowin GW5A-LV25MG121) 上で動作する RISC-V 互換 32ビット CPU を
ゼロから設計・実装するプロジェクトです。

## 目標

RV32I 命令セットを段階的に実装し、シングルサイクルCPU から始めて、
最終的にパイプライン化された CPU + SoC を構築します。

## 現在の完成状況

- RV32I の基本演算、即値演算、分岐、ジャンプ、ロード/ストアを実装済み
- RV32M の乗算・除算命令を実装済み (多サイクル: 乗算3サイクル / 除算34サイクル)
- Scratch RAM と UART TX/RX の MMIO を接続済み
- 3段パイプライン化（フェッチ / デコード+レジスタ読み出し / 実行+書き戻し）
- EX から ID へのフォワーディングでデータハザードを解決
- 命令ROM・データRAM を BSRAM に配置 (ロード時1サイクルストール)
- `sim/` の全テストベンチ (21本) がパスする状態
- Tang Primer 25K で合成・配置配線が通り、50 MHz 制約を満たす
- **実機 (Tang Primer 25K) で動作確認済み**
  - `loop55` : LED[0] のハートビートと LED[1] 点灯 (x1 = 55 到達)
  - `printf_demo` : UART (COM ポート, 115200bps) にシミュレーションと同一の
    出力。`.bss` クリア、`.rodata` の LBU 読み出し、除算器を使う10進変換、
    16進変換、UART RX のエコーまで一通り動作
  - `uart_echo_c` : 起動メッセージのあとエコーループ。1文字ずつ10回、
    および20文字連続 (15ms間隔) を取りこぼしなくエコーすることを確認

### 実測値 (printf_demo.hex で合成)

| 項目 | 値 |
|:--|:--|
| 最大動作周波数 | 50.955 MHz (制約 50 MHz、スラック +0.375 ns) |
| LUT/ALU | 3357 / 23040 (14%) |
| レジスタ | 1596 / 23280 (7%) |
| BSRAM | 36 / 56 (65%) |
| DSP | 4 / 28 (15%) |

> 合成器は ROM の内容を定数として伝播させるため、使う命令が少ない
> プログラム (`loop55.hex` など) で合成すると CPU がそのプログラム専用に
> 特殊化され、リソースも周波数も実態より良く出ます。設計の素の値を見たい
> ときは `printf_demo.hex` のような命令種の多いプログラムで測ってください。

> **注意: 本CPUは RV32IM のみで、C拡張 (圧縮命令) は未実装です。**
> C をビルドするときは必ず `-march=rv32im -mabi=ilp32` を指定してください。

## 開発ロードマップ

| Phase | 内容 | 状態 |
|:------|:-----|:-----|
| 1 | 開発環境セットアップ & LED点滅 | ✅ |
| 2 | 基本コンポーネント (ALU, レジスタ, デコーダ) | ✅ |
| 3 | シングルサイクルCPU (計算命令のみ) | ✅ |
| 4 | メモリ命令 (Load/Store) 追加 | ✅ |
| 5 | 分岐・ジャンプ追加 (チューリング完全) | ✅ |
| 6 | UART デバッグ環境 | ✅ |
| 7 | M拡張 (多サイクル乗除算) | ✅ |
| 8 | 3段パイプライン化 + フォワーディング | ✅ |
| 9+ | SDRAM / 割り込み / CSR | 🔧 作業中 |

## ISA

- **ベース**: RV32I (RISC-V Base Integer Instruction Set, 32-bit)
- **レジスタ**: 32本 × 32ビット (x0 = 常に0)
- **命令長**: 固定 32ビット
- **命令数**: 40

## ディレクトリ構成

```
RISK_V_fpga/
├── src/                      # Verilog ソースファイル
│   ├── riscv_defines.vh      # 共通定義 (唯一の定義元。sim からは -I src で参照)
│   ├── multiplier.v          # 多サイクル乗算器 (Phase 7)
│   ├── divider.v             # 多サイクル除算器 (Phase 7)
│   ├── blinky.v              # LED点滅テスト (Phase 1)
│   ├── alu.v                 # ALU (Phase 2)
│   ├── register_file.v       # レジスタファイル (Phase 2)
│   ├── instruction_decoder.v # デコーダ (Phase 2)
│   └── cpu_top.v             # CPUトップ (Phase 3)
├── sim/                      # テストベンチ
│   ├── tb_alu.v
│   ├── tb_register_file.v
│   ├── tb_shift_logic.v      # シフト/論理/比較命令のCPU統合テスト
│   ├── tb_multiplier.v       # 多サイクル乗算器の単体テスト
│   ├── tb_divider.v          # 多サイクル除算器の単体テスト
│   ├── tb_hazard.v           # データハザード/フォワーディングの検証
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
#    python tools/bin2hex.py program.bin > src/program.hex

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

- `<prefix>-gcc`
- `<prefix>-objcopy`
- `<prefix>-objdump`

`<prefix>` は配布元によって異なり、**どちらでも本プロジェクトはビルドできます**。

| 配布元 | 接頭辞 |
|:--|:--|
| xPack (xpm で導入) | `riscv-none-elf-` |
| SiFive / crosstool-NG 系 | `riscv64-unknown-elf-` |

本 README のコマンド例は `riscv64-unknown-elf-` で書いていますが、
xPack を使っている場合は `riscv-none-elf-` に読み替えてください。

### 2. 導入方法

xPack 版が最も手軽です (Node.js が必要)。

```powershell
npm install --global xpm
xpm install --global @xpack-dev-tools/riscv-none-elf-gcc@latest
```

導入先 (`%APPDATA%\xPacks\@xpack-dev-tools\riscv-none-elf-gcc\<version>\.content\bin`)
を PATH に追加します。prebuilt を手で展開する場合は、その `bin` を PATH に追加してください。

> `winget` に RISC-V の bare-metal GCC パッケージは存在しません。`winget install`
> で入れようとしても失敗します。

### 3. 動作確認

PowerShell で次を実行します (接頭辞は導入したものに合わせてください)。

```powershell
riscv-none-elf-gcc --version
riscv-none-elf-objcopy --version
riscv-none-elf-objdump --version
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

このスクリプトは 2 つの接頭辞 (`riscv-none-elf-` / `riscv64-unknown-elf-`) の両方を
PATH と xPack の既定インストール先から探し、見つからなければ `xpm` での導入を案内します。
PATH への追加コマンドもそのまま貼り付けられる形で表示します。

> もし PowerShell で `Set-Location` の引数が連結してエラーになる場合は、**各コマンドを別行で実行**してください。  
> さらに、`C:\path\to\RISK_V_fpga` の部分は **実際のリポジトリの保存場所** に置き換えてください。  
> そのうえで `-File` のパスエラーが出る場合は、**絶対パス**で実行してください。  
> 例: `powershell -ExecutionPolicy Bypass -File "C:\Users\yourname\Documents\RISK_V_fpga\tools\install_riscv_toolchain.ps1"`
>
> インストール後は **PowerShell を一度閉じて再度開く** か、`where.exe riscv-none-elf-gcc` で確認してください。

### 5. ビルドして使う

サンプルは 2 本あります。

- `examples/loop55.c`: 1 から 10 までの加算結果 55 を LED で確認するサンプル
- `examples/button_led.c`: `user_btn` で `led[1]` を切り替える MMIO サンプル

> **`-march=rv32im -mabi=ilp32` は必須です。** 省略すると gcc の既定 multilib
> (`rv32imac`) が選ばれ、本CPUが未実装の圧縮命令 (C拡張, 16ビット命令) を
> 含むバイナリが生成されます。デコーダはそれを未定義オペコードとして読み飛ばす
> だけなので、CPU はエラーも出さずに暴走します。
>
> `objcopy` に `-j` は付けないでください。`.data` の初期値は ROM 側 (LMA) に
> 置かれており、`-j .text -j .rodata` で絞ると初期値つきグローバル変数が
> hex から丸ごと落ちます。

```powershell
# loop55
riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 -nostdlib -nostartfiles -T tools/link.ld \
  tools/crt0.S examples/loop55.c -o examples/loop55.elf
riscv64-unknown-elf-objcopy -O binary examples/loop55.elf examples/loop55.bin
python tools/bin2hex.py examples/loop55.bin > examples/loop55.hex

# button_led
riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 -nostdlib -nostartfiles -T tools/link.ld \
  tools/crt0.S examples/button_led.c -o examples/button_led.elf
riscv64-unknown-elf-objcopy -O binary examples/button_led.elf examples/button_led.bin
python tools/bin2hex.py examples/button_led.bin > examples/button_led.hex

# uart_echo_c (UART エコー。uart.h を拾うため examples/ を include パスに追加)
riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 -nostdlib -nostartfiles -I examples -T tools/link.ld \
  tools/crt0.S examples/uart_echo_c.c -o examples/uart_echo_c.elf
riscv64-unknown-elf-objcopy -O binary examples/uart_echo_c.elf examples/uart_echo_c.bin
python tools/bin2hex.py examples/uart_echo_c.bin > examples/uart_echo_c.hex
```

> `crt0.S` が `.data` の ROM→RAM コピーと `.bss` のゼロクリアを行うので、
> 初期値つきグローバル変数も通常どおり使えます。`link.ld` には ROM 32 KB /
> RAM 64 KB を超えたらリンクエラーになる `ASSERT` を入れてあります。

生成した `*.hex` はそのまま CPU の初期化ファイルとして使えます。
たとえば `fpga_top` の `INIT_FILE` を `examples/loop55.hex` または `examples/button_led.hex` に変更してください。

### 6. FPGA 実機の起動手順

1. 動かしたいサンプルを hex に変換します (上記「5. ビルドして使う」)。
  - 起動確認だけなら `examples/loop55.hex`
  - ボタン/LED の MMIO 確認なら `examples/button_led.hex`
  - UART まで一通り動かすなら `examples/printf_demo.hex`
2. `src/fpga_top.v` の `INIT_FILE` を使いたい hex に合わせます。
  - 既定値は `examples/loop55.hex` です。
  - `build.tcl` はここから hex のパスを読むので、変更箇所はこの1か所だけです。
3. 合成・配置配線します。

```powershell
& "C:\Gowin\<version>\IDE\bin\gw_sh.exe" build.tcl
```

4. Tang Primer 25K Dock の **USB-C** を PC に接続します (給電専用ポートではなく
   BL616 デバッガ側)。接続されると JTAG とシリアルポートが現れます。
5. 書き込みます。

```powershell
# 検出だけ確認する
powershell -ExecutionPolicy Bypass -File tools/program.ps1 -ScanOnly

# SRAM に書き込む (数秒。電源を切ると消える。まずはこちら)
powershell -ExecutionPolicy Bypass -File tools/program.ps1

# 外部SPIフラッシュに書き込む (電源を切っても残る)
powershell -ExecutionPolicy Bypass -File tools/program.ps1 -Flash
```

6. UART を使うサンプルなら、受信を確認します。

```powershell
# 8秒間受信する (ポートは1つだけなら自動検出)
powershell -ExecutionPolicy Bypass -File tools/uart_monitor.ps1

# 受信しつつ4秒後に 'Z' を送ってエコーを確認する
powershell -ExecutionPolicy Bypass -File tools/uart_monitor.ps1 -Seconds 10 -Send 'Z' -SendAfter 4

# 対話モード: 打った文字がそのままボードへ行く (Esc または Ctrl+] で終了)
powershell -ExecutionPolicy Bypass -File tools/uart_monitor.ps1 -Interactive

# 受信バイトを16進でも表示する (文字化けの切り分け用)
powershell -ExecutionPolicy Bypass -File tools/uart_monitor.ps1 -Interactive -ShowHex
```

> 起動メッセージは書き込み直後に流れてしまいます。取り逃したらリセット (S1) を
> 押しながら受信してください。

7. リセット (S1) 後の期待動作:
  - `loop55` : `led[0]` が約1.5Hzで点滅 (クロック生存)、`led[1]` が点灯
    (CPU が x1 = 55 を計算完了)
  - `button_led` : `user_btn` (S2) を押すたびに `led[1]` が反転
  - `printf_demo` / `uart_echo_c` : 115200bps のシリアル端末に出力

> `tools/program.ps1` はビットストリームより新しい `src/*.v` があると警告します。
> 合成し直さずに古いビットストリームを焼く事故を防ぐためです。
>
> SRAM への書き込みは verify 無し (`--run 2`) を使っています。GW5A-25A で
> `--run 4` (SRAM Program and Verify) を試すと、書き込み自体は通るのに読み戻しで
> `Error: Verify failed of at 0` になります。この系列は SRAM のリードバックが
> 既定で無効なためで、verify の失敗は書き込み失敗を意味しません (実機で `--run 2`
> なら正常に動作することを確認済み)。
>
> `programmer_cli.exe` は Python を同梱しており `PYTHONIOENCODING` を継承します。
> `utf-8:surrogateescape` などが設定された環境では同梱 Python が起動時に落ちる
> (`Fatal Python error: Py_Initialize`) ため、スクリプトは子プロセスの間だけ
> Python 系の環境変数を外して呼び出します。手で `programmer_cli` を叩いて同じ
> エラーが出たときは、これらの変数を外してください。

### 8. 追加で便利な確認コマンド

```powershell
riscv64-unknown-elf-objdump -d examples/loop55.elf
```

## ツール

- **Gowin EDA** - 論理合成・配置配線
- **Icarus Verilog** - シミュレーション
- **GTKWave** - 波形表示
