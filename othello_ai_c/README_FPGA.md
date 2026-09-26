# オセロAI を RISC-V CPU (Tang Primer 25K) で動かす

`othello_AI/` の C 言語版オセロAI を、本リポジトリの RV32IM ソフトCPU 上で
動くようにしたものです。PC 版と同じソース (`othello.c` / `evaluate.c` /
`search.c`) を `OTHELLO_BAREMETAL` を定義してビルドします。

## PC 版との違い

| 項目 | PC 版 | FPGA 版 (`OTHELLO_BAREMETAL`) |
|:--|:--|:--|
| 評価値 | `double` | `int32_t` 固定小数点 (1024 = 石1個)。FPU が無いため |
| 置換表 | 2^20 エントリ (`calloc`) | 2^10 エントリ (静的確保, 16 KB) |
| 思考時間 | `clock()` で計測 | タイマーが無いので探索ノード数で近似 (`OTHELLO_NODES_PER_MS`) |
| 入出力 | 標準入出力 | UART 115200bps 8N1 |

評価関数の重み (`eval_weights.h`) はそのまま使い、起動後の初回評価時に
固定小数点へ変換します。PC 版と最善手が一致することを確認済みです
(ランダムな 60 局面・深さ5 で全一致、評価値の差は 0.05 未満)。

メモリ使用量: ROM 約 19 KB / 32 KB、RAM 約 20 KB / 64 KB (+スタック)。

## ビルド

RISC-V ツールチェーンの導入はリポジトリ直下の README を参照してください。

```bash
cd othello_ai_c/othello_AI
make fpga                                  # riscv64-unknown-elf- の場合
make fpga RISCV_PREFIX=riscv-none-elf-     # xPack の場合
```

make が無い Windows では PowerShell で次を実行します (接頭辞は適宜読み替え)。

```powershell
cd othello_ai_c\othello_AI
riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -O2 -std=c11 -ffreestanding -nostdlib -nostartfiles `
  -DOTHELLO_BAREMETAL -I ..\..\examples -T ..\..\tools\link.ld `
  ..\..\tools\crt0.S othello_fpga.c othello.c evaluate.c search.c -lgcc -o othello_fpga.elf
riscv-none-elf-objcopy -O binary othello_fpga.elf othello_fpga.bin
python ..\..\tools\bin2hex.py othello_fpga.bin othello_fpga.hex
```

> `-lgcc` は必須です (64bit ビットボードのシフト等で libgcc の関数を使うため)。

ビルド済みの `othello_fpga.hex` もリポジトリに含めています。

## FPGA への書き込み

1. `src/fpga_top.v` の `INIT_FILE` を変更します。

   ```verilog
   parameter INIT_FILE = "othello_ai_c/othello_AI/othello_fpga.hex"
   ```

2. 合成・書き込み (リポジトリ直下で実行)。

   ```powershell
   & "C:\Gowin\<version>\IDE\bin\gw_sh.exe" build.tcl
   powershell -ExecutionPolicy Bypass -File tools/program.ps1
   ```

## 遊び方

### 端末で対戦

```powershell
powershell -ExecutionPolicy Bypass -File tools/uart_monitor.ps1 -Interactive
```

接続後に Enter を押すとメニューが出ます (出ない場合はリセット S1)。

```
=== Othello AI on RISC-V (RV32IM) ===
  b    : play as Black (first move)
  w    : play as White
  BESTMOVE <black_hex16> <white_hex16> <b|w> <depth> <time_ms> <endgame>
  help : show this menu
> b
```

`b` で先手 (黒 X)、`w` で後手 (白 O)。`*` が着手可能なマスです。
`f5` のように入力して Enter。`q` で対局を中断します。
(UART 端末の都合で表示は英語です)

### GUI で対戦

`othello_gui.py` をシリアル接続で使えます (pyserial が必要)。

```powershell
pip install pyserial
python othello_ai_c\othello_AI\othello_gui.py --serial COM3
```

GUI は PC 版 `engine_cli` と同じ `BESTMOVE` コマンドをボードへ送ります。
FPGA 版は 1 手あたり約 3 秒・残り 8 マスから完全読みの設定です
(`othello_gui.py` の `FPGA_TIME_MS` / `FPGA_ENDGAME_THRESHOLD`)。

## 強さ・速度

シミュレーションでの実測では、50 MHz 動作で 1 ノードあたり約 2〜5 万サイクル
(約 1,000〜2,500 ノード/秒) です。PC 版より桁違いに遅いため、思考時間 3 秒でも
中盤の読みは深さ 4 前後になります。完全読みは残り 8 マスで 2 千ノード前後、
残り 10 マスだと 1〜3 万ノード (十数秒) かかります。

思考時間はノード数から換算しているため目安です (`search.c` の
`OTHELLO_NODES_PER_MS`、既定値 1)。

## シミュレーションでの確認

```bash
make -C othello_ai_c/othello_AI fpga
iverilog -I src -o sim/tb_othello_fpga.out sim/tb_othello_fpga.v \
  src/cpu_top.v src/alu.v src/register_file.v src/instruction_decoder.v src/control_unit.v \
  src/imm_gen.v src/instruction_memory.v src/data_memory.v src/multiplier.v src/divider.v \
  src/uart_tx.v src/uart_rx.v
vvp sim/tb_othello_fpga.out
```

CPU 上で `BESTMOVE` を2局面実行し、PC 上で同じソースを動かした結果と一致するか
確認します (数分〜十数分かかります)。

PC 上で FPGA 版の動作だけ確かめたい場合は、標準入出力を UART 代わりにした
ホスト版も作れます。

```bash
make othello_fpga_host && ./othello_fpga_host
```
