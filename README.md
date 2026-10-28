# RISC_V_fpga

Tang Primer 25K (Gowin GW5A-LV25MG121) 上で動作する RISC-V 互換 32ビット CPU を
ゼロから設計・実装するプロジェクトです。

## 目標

RV32IM 命令セットを段階的に実装し、シングルサイクルCPU から始めて、
最終的にパイプライン化された CPU + SoC を構築します。
現在は 3 段パイプラインに CSR・例外・割り込みを加えたところまで到達しており、次は SDRAM に取り組みます。

## 現在の完成状況

- RV32I の基本演算、即値演算、分岐、ジャンプ、ロード/ストアを実装済み
- RV32M の乗算・除算命令を実装済み (多サイクル: 乗算3サイクル / 除算34サイクル)
- Scratch RAM と UART TX/RX の MMIO を接続済み
- 3段パイプライン化（フェッチ / デコード+レジスタ読み出し / 実行+書き戻し）
- EX から ID へのフォワーディングでデータハザードを解決
- 命令ROM・データRAM を BSRAM に配置 (ロード時1サイクルストール)
- マシンモードの CSR (Zicsr)・例外・割り込み (タイマ / ソフトウェア / UART受信) を実装
  ([詳細](#csr例外割り込み))
- `sim/` の全テストベンチ (23本) がパスする状態
- Tang Primer 25K で合成・配置配線が通り、50 MHz 制約を満たす
  (CSR・例外・割り込みの追加前の値。追加後は未計測)
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

> **注意: 本CPUは C拡張 (圧縮命令) を実装していません。**
> C をビルドするときは必ず `-march=rv32im -mabi=ilp32` を指定してください
> (CSR を使うコードは `-march=rv32im_zicsr`)。

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
| 9 | CSR / 例外 / 割り込み | ✅ |
| 10+ | SDRAM | 🔧 作業中 |

## ISA

- **ベース**: RV32I + M / Zicsr / Zifencei (RV32IM_Zicsr_Zifencei)、マシンモードのみ
- **レジスタ**: 32本 × 32ビット (x0 = 常に0)
- **命令長**: 固定 32ビット (C拡張の圧縮命令は未対応)
- **実装済み命令**: 57
  - RV32I 40命令: LUI, AUIPC, JAL, JALR, 分岐6, ロード5, ストア3,
    即値演算9, レジスタ間演算10, FENCE, ECALL, EBREAK
  - M拡張 8命令: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU
  - Zicsr 6命令: CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI
  - 特権命令: MRET, WFI / Zifencei: FENCE.I
- FENCE / FENCE.I / WFI は何もしない命令として実行します (キャッシュが無く、
  命令ROMは書き換えられないため。WFI を NOP とすることは仕様上許されています)
- 上記以外のエンコーディングはすべて不正命令例外になります

## CSR・例外・割り込み

マシンモード (M-mode) だけの最小構成です。トラップは EX ステージで取り、
EX にある命令を取り消して (レジスタ・メモリ・CSR・MMIO への書き込みはすべて
抑止) `mepc` にその PC を入れ、後続 2 命令を分岐成立時と同じく破棄します。

### CSR

| CSR | 内容 |
|:--|:--|
| `mstatus` | MIE (bit3), MPIE (bit7)。MPP (bit12:11) は常に 11 |
| `misa` | `0x40001100` (RV32IM)。書き込みは無視 |
| `mie` / `mip` | MSIE/MSIP (bit3), MTIE/MTIP (bit7), MEIE/MEIP (bit11)。`mip` は読み出し専用で割り込み線の状態を映す |
| `mtvec` | BASE + MODE (0: direct, 1: vectored。vectored では割り込み N を BASE+4N へ) |
| `mscratch` / `mepc` / `mcause` / `mtval` | トラップ用 |
| `mcycle` / `minstret` (+`h`) | 64ビットカウンタ (書き込み可) |
| `cycle` / `time` / `instret` (+`h`) | 読み出し専用。`time` はタイマの `mtime` |
| `mvendorid` / `marchid` / `mimpid` | すべて 0 |
| `mhartid` | ハート番号 (`rv_core` の `HART_ID` パラメータ。現在は 0 のみ) |

未実装の CSR へのアクセスと、読み出し専用 CSR への書き込みは不正命令例外です。

### 例外 (`mcause`)

| コード | 例外 | `mtval` |
|:--|:--|:--|
| 0 | 命令アドレス非整列 (分岐・ジャンプ先が 4 の倍数でない) | 飛び先アドレス |
| 1 | 命令アクセスフォールト (命令ROM 0x0000_0000-0x0000_7FFF の外をフェッチ) | PC |
| 2 | 不正命令 | 命令そのもの |
| 3 | EBREAK | 0 |
| 4 / 6 | ロード / ストアのアドレス非整列 | アクセスアドレス |
| 11 | ECALL | 0 |

ロード・ストアのアクセスフォールト (未実装アドレスへのアクセス) は実装していません。

### 割り込み (`mcause` bit31 = 1)

| コード | 割り込み | 要因 / 解除方法 |
|:--|:--|:--|
| 11 | マシン外部 | UART に受信データがある間。UART RX データの読み出しで解除 |
| 3 | マシンソフトウェア | `msip` = 1 の間。`msip` に 0 を書いて解除 |
| 7 | マシンタイマ | `mtime >= mtimecmp` の間。`mtimecmp` を先へ進めて解除 |

優先順位は外部 > ソフトウェア > タイマ (仕様どおり)。割り込みは命令が EX に入った
最初のサイクルでだけ受け付け、ロードの読み出しや乗除算が始まった命令は完了させて
から次の命令で受け付けます (UART RX データの読み出しのような副作用を失わないため)。

### タイマ (MMIO, ワードアクセスのみ)

ハートごとに 32 バイトのブロックを持ち、ハート h のブロックは `0x8000_0100 + 0x20*h` です
(最大 8 ハート)。ハート 0 のブロックは従来のタイマと同じアドレスなので、既存のプログラムは
そのまま動きます。

| オフセット | レジスタ |
|:--|:--|
| `+0x00` | `msip` (bit0)。そのハートのソフトウェア割り込み |
| `+0x08` / `+0x0C` | `mtimecmp` 下位 / 上位。そのハートのタイマ割り込み |
| `+0x10` / `+0x14` | `mtime` 下位 / 上位。全ハート共通のカウンタで、どのブロックからも読み書きできる |

どのハートもすべてのブロックに書き込めるので、他のハートの `msip` を 1 にすれば
そのハートに割り込みをかけられます (コア間割り込み)。`csr.h` の `send_ipi()` /
`timer_set_cmp_of()` が使えます (`timer_set_cmp()` は自分のハートの `mtimecmp` を設定します)。

`mtime` は `cpu_top` の `TIMER_DIV` クロック (既定 50) ごとに 1 進むので、
50 MHz ではマイクロ秒カウンタになります。`mtimecmp` のリセット値は全ビット 1 です。

### C から使う

`examples/csr.h` に CSR アクセス用マクロ (`read_csr` / `write_csr` / `set_csr` /
`clear_csr`)、定数、タイマ操作関数があります。トラップハンドラは GCC の
`__attribute__((interrupt("machine")))` を付けた普通の C 関数で書けます
(使用レジスタの退避と `mret` をコンパイラが生成します)。使用例は
`examples/trap_demo.c` を参照してください。

```c
void __attribute__((interrupt("machine"))) trap_handler(void) { ... }
write_csr(mtvec, (unsigned int)trap_handler);
set_csr(mie, MIE_MTIE);
set_csr(mstatus, MSTATUS_MIE);
```

> リセット直後の `mtvec` は 0 なので、ハンドラを設定する前にトラップが起きると
> リセットベクタ (0番地) に戻ってプログラムが最初からやり直しになります。

## コアと SoC の構成

マルチコア化の準備として、CPU を「ハート」と「SoC」に分けています。

- `rv_core.v` : ハート 1 個分 (3段パイプライン・乗除算器・CSR)。メモリや周辺は持たず、
  命令フェッチポートとデータバスだけで外とつながる
- `cpu_top.v` : SoC。ハート・命令ROM・データRAM・UART・タイマを持ち、アドレスをデコードする。
  ポートは従来の `cpu_top` と同じ

### データバス

ハートは EX ステージから 1 度に 1 つの要求を出し、完了するまで
`dbus_addr` / `dbus_wdata` / `dbus_we` / `dbus_funct3` を保持します。

| 信号 | 向き | 意味 |
|:--|:--|:--|
| `dbus_req` | ハート→SoC | ロード/ストアが受け付け待ち |
| `dbus_gnt` | SoC→ハート | 次のクロックで要求を受け付ける。ストアはこれで完了 |
| `dbus_rvalid` / `dbus_rdata` | SoC→ハート | 受け付けたロードのデータ (サイズ・符号拡張済み) |

今の SoC はマスタが 1 つで全スレーブが固定 1 サイクルなので、`dbus_gnt` = 1、
`dbus_rvalid` は受け付けの 1 サイクル後です (ストア 1 サイクル / ロード 2 サイクルで従来と同じ)。
`cpu_top` の `BUS_STRESS` パラメータ (シミュレーション専用) を 1 にすると、`dbus_gnt` と
`dbus_rvalid` が擬似乱数で待たされます。`sim/tb_bus_stress.v` はこの状態で `trap_test.hex` を
実行し、ハートが待ちサイクルに依存しないことを確認します。

## ディレクトリ構成

```
RISC_V_fpga/
├── src/                      # Verilog ソース
│   ├── riscv_defines.vh      # 共通定義 (唯一の定義元。sim からは -I src で参照)
│   ├── fpga_top.v            # FPGA トップ (CPU + board_io + LED表示)
│   ├── cpu_top.v             # CPU (SoC): ハート + 命令ROM・データRAM・UART・タイマ
│   ├── rv_core.v             # ハート本体 (3段パイプライン + CSR)。メモリとはバスで接続
│   ├── instruction_memory.v  # 命令ROM 32KB (BSRAM, $readmemh で初期化)
│   ├── instruction_decoder.v # デコーダ
│   ├── control_unit.v        # PC選択・ALU入力A選択
│   ├── imm_gen.v             # 即値生成
│   ├── register_file.v       # レジスタファイル
│   ├── alu.v                 # ALU
│   ├── multiplier.v          # 多サイクル乗算器 (3サイクル)
│   ├── divider.v             # 多サイクル除算器 (34サイクル)
│   ├── csr_file.v            # CSR・トラップ状態・カウンタ
│   ├── timer.v               # マシンタイマ / ソフトウェア割り込み (mtime, mtimecmp, msip)
│   ├── data_memory.v         # データRAM 32KB (BSRAM)
│   ├── uart_tx.v / uart_rx.v # UART (115200bps)
│   ├── board_io.v            # LED / ボタンの MMIO
│   ├── blinky.v              # LED点滅テスト (Phase 1)
│   └── uart_*.s / uart_*.hex # 手書きアセンブリのテストプログラム
├── sim/                      # テストベンチ (23本, tb_*.v)
│   └── trap_test.S / .hex    # tb_trap.v 用の CSR・例外・割り込み自己検査プログラム
├── examples/                 # C / アセンブリのサンプルとビルド済み hex
│   ├── uart.h                # UART MMIO ヘルパ
│   ├── csr.h                 # CSR アクセス・トラップ定数・タイマ操作
│   ├── loop55.c / loop55.S   # 1+2+...+10 = 55 を LED で確認
│   ├── button_led.c          # ボタンで LED を切り替え
│   ├── uart_echo_c.c         # UART エコー
│   ├── printf_demo.c         # 10進/16進表示、.bss/.rodata、UART RX の総合デモ
│   └── trap_demo.c           # 例外・タイマ割り込み・UART受信割り込みのデモ
├── tools/
│   ├── crt0.S                # スタートアップ (.data コピー, .bss クリア)
│   ├── link.ld               # リンカスクリプト (ROM 32KB / RAM 32KB)
│   ├── bin2hex.py            # 生バイナリ -> $readmemh 用 hex
│   ├── assemble_uart_*.py    # src/uart_*.hex を生成する手動アセンブラ
│   ├── install_riscv_toolchain.ps1 # ツールチェーン検出・導入案内
│   ├── program.ps1           # 実機書き込み (SRAM / SPIフラッシュ)
│   └── uart_monitor.ps1      # UART 受信・対話モニタ
├── constraints/              # FPGA制約ファイル
│   ├── tang_primer_25k.cst   # ピン制約
│   └── timing.sdc            # タイミング制約
├── gowin_project/            # Gowin EDA プロジェクト
├── build.tcl                 # 合成・配置配線スクリプト (gw_sh 用)
├── othello_ai_c/             # オセロAI (PC向けC実装。CPUとは未統合)
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

テストベンチは hex を `examples/` や `src/` からの相対パスで読むので、
**リポジトリのルートで**実行してください。

```bash
# ALU 単体テスト
iverilog -I src -o sim/tb_alu.out sim/tb_alu.v src/alu.v
vvp sim/tb_alu.out

# CPU を含むテストは src/*.v をまとめて渡すのが簡単
iverilog -I src -o sim/tb_printf_demo.out sim/tb_printf_demo.v src/*.v
vvp sim/tb_printf_demo.out
```

全テストベンチを一括実行する場合:

```powershell
# PowerShell
Get-ChildItem sim\tb_*.v | ForEach-Object {
    $out = "sim\$($_.BaseName).out"
    iverilog -I src -o $out $_.FullName (Get-ChildItem src\*.v).FullName
    vvp -n $out
}
```

```bash
# bash
for tb in sim/tb_*.v; do
    out=sim/$(basename "$tb" .v).out
    iverilog -I src -o "$out" "$tb" src/*.v && vvp -n "$out"
done
```

C プログラムをビルドして CPU で動かす手順は
「RISC-V ツールチェーン導入手順」の「5. ビルドして使う」を参照してください。

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
#      例: C:\Users\yourname\Documents\RISC_V_fpga
Set-Location -Path "C:\path\to\RISC_V_fpga"

# 2) スクリプトを実行
powershell -ExecutionPolicy Bypass -File ".\tools\install_riscv_toolchain.ps1"
```

このスクリプトは 2 つの接頭辞 (`riscv-none-elf-` / `riscv64-unknown-elf-`) の両方を
PATH と xPack の既定インストール先から探し、見つからなければ `xpm` での導入を案内します。
PATH への追加コマンドもそのまま貼り付けられる形で表示します。

> もし PowerShell で `Set-Location` の引数が連結してエラーになる場合は、**各コマンドを別行で実行**してください。  
> さらに、`C:\path\to\RISC_V_fpga` の部分は **実際のリポジトリの保存場所** に置き換えてください。  
> そのうえで `-File` のパスエラーが出る場合は、**絶対パス**で実行してください。  
> 例: `powershell -ExecutionPolicy Bypass -File "C:\Users\yourname\Documents\RISC_V_fpga\tools\install_riscv_toolchain.ps1"`
>
> インストール後は **PowerShell を一度閉じて再度開く** か、`where.exe riscv-none-elf-gcc` で確認してください。

### 5. ビルドして使う

サンプルは 5 本あります。

- `examples/loop55.S`: 1 から 10 までの加算結果 55 を LED で確認するサンプル (`loop55.c` は参考用)
- `examples/button_led.c`: `user_btn` で `led[1]` を切り替える MMIO サンプル
- `examples/uart_echo_c.c`: 起動メッセージのあと UART 受信文字をエコーするサンプル
- `examples/printf_demo.c`: 10進/16進表示、`.bss` / `.rodata`、UART RX まで確認する総合デモ
- `examples/trap_demo.c`: ECALL と不正命令の例外、500ms ごとのタイマ割り込み (LED[1] 点滅)、
  UART 受信割り込みのデモ

> **`-march=rv32im -mabi=ilp32` は必須です。** 省略すると gcc の既定 multilib
> (`rv32imac`) が選ばれ、本CPUが未実装の圧縮命令 (C拡張, 16ビット命令) を
> 含むバイナリが生成されます。デコーダはそれを未定義オペコードとして読み飛ばす
> だけなので、CPU はエラーも出さずに暴走します。
>
> `objcopy` に `-j` は付けないでください。`.data` の初期値は ROM 側 (LMA) に
> 置かれており、`-j .text -j .rodata` で絞ると初期値つきグローバル変数が
> hex から丸ごと落ちます。

```powershell
# loop55 (アセンブリ版が正。C 版は -O2 でループが消え x1 = 55 にならない)
riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles -Ttext=0 \
  examples/loop55.S -o examples/loop55.elf
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

# printf_demo (同じく uart.h を使う)
riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 -nostdlib -nostartfiles -I examples -T tools/link.ld \
  tools/crt0.S examples/printf_demo.c -o examples/printf_demo.elf
riscv64-unknown-elf-objcopy -O binary examples/printf_demo.elf examples/printf_demo.bin
python tools/bin2hex.py examples/printf_demo.bin > examples/printf_demo.hex

# trap_demo (CSR 命令を使うので -march に _zicsr が必要)
riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -O2 -nostdlib -nostartfiles -I examples -T tools/link.ld \
  tools/crt0.S examples/trap_demo.c -o examples/trap_demo.elf
riscv64-unknown-elf-objcopy -O binary examples/trap_demo.elf examples/trap_demo.bin
python tools/bin2hex.py examples/trap_demo.bin > examples/trap_demo.hex
```

> `crt0.S` が `.data` の ROM→RAM コピーと `.bss` のゼロクリアを行うので、
> 初期値つきグローバル変数も通常どおり使えます。`link.ld` には ROM 32 KB /
> RAM 32 KB を超えたらリンクエラーになる `ASSERT` を入れてあります。

生成した `*.hex` はそのまま CPU の初期化ファイルとして使えます。
たとえば `fpga_top` の `INIT_FILE` を `examples/loop55.hex` または `examples/button_led.hex` に変更してください。

### 6. FPGA 実機の起動手順

1. 動かしたいサンプルを hex に変換します (上記「5. ビルドして使う」)。
  - 起動確認だけなら `examples/loop55.hex`
  - ボタン/LED の MMIO 確認なら `examples/button_led.hex`
  - UART まで一通り動かすなら `examples/printf_demo.hex`
  - 割り込みまで試すなら `examples/trap_demo.hex`
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
  - `trap_demo` : 例外の報告のあと、`led[1]` が 500ms ごとに反転して `tick N` を出力。
    送った文字は `rx 'X'` として返る

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

### 7. 追加で便利な確認コマンド

```powershell
riscv64-unknown-elf-objdump -d examples/loop55.elf
```

## ツール

- **Gowin EDA** - 論理合成・配置配線
- **Icarus Verilog** - シミュレーション
- **GTKWave** - 波形表示
