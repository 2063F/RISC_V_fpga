# オセロAI を RISC-V CPU (Tang Primer 25K) で動かす

`othello_AI/` の C 言語版オセロAI を、本リポジトリの RV32IM ソフトCPU 上で
動くようにしたものです。PC 版と同じソース (`othello.c` / `evaluate.c` /
`search.c`) を `OTHELLO_BAREMETAL` を定義してビルドします。

## PC 版との違い

| 項目 | PC 版 | FPGA 版 (`OTHELLO_BAREMETAL`) |
|:--|:--|:--|
| 評価値 | `double` | `int32_t` 固定小数点 (1024 = 石1個)。FPU が無いため |
| 置換表 | 2^20 エントリ (`calloc`) | 2^10 エントリ (静的確保, 16 KB) |
| 思考時間 | `clock()` で計測 | CPU のサイクルカウンタ (MMIO `0x8000_0020`) で計測 |
| 置換表のハッシュ | Zobrist | 乗算による混合 (RV32 で速い) |
| 入出力 | 標準入出力 | UART 115200bps 8N1 |

評価関数の重み (`eval_weights.h`) はそのまま使い、起動後の初回評価時に
固定小数点へ変換します。PC 版と最善手が一致することを確認済みです
(ランダムな 60 局面・深さ5 で全一致、評価値の差は 0.05 未満。
終盤 80 局面 (残り1〜14マス) の完全読みの石差も全一致)。

メモリ使用量: ROM 約 26 KB / 32 KB、RAM 約 19 KB / 64 KB (+スタック)。

> サイクルカウンタは `src/cpu_top.v` に追加した読み出し専用の MMIO です
> (50 MHz で加算、約86秒で一周)。この版の hex を使うときは、このカウンタを含む
> ビットストリームで合成し直してください。

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
riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -O2 -fno-schedule-insns -fno-schedule-insns2 `
  -std=c11 -ffreestanding -nostdlib -nostartfiles `
  -DOTHELLO_BAREMETAL -I ..\..\examples -T ..\..\tools\link.ld `
  ..\..\tools\crt0.S othello_fpga.c othello.c evaluate.c search.c -lgcc -o othello_fpga.elf
riscv-none-elf-objcopy -O binary othello_fpga.elf othello_fpga.bin
python ..\..\tools\bin2hex.py othello_fpga.bin othello_fpga.hex
```

> `-lgcc` は必須です (64bit ビットボードの乗算等で libgcc の関数を使うため)。
> `-fno-schedule-insns -fno-schedule-insns2` は速度のために付けています。
> 命令スケジューリングは本CPU (インオーダー3段) では効かず、レジスタ退避が
> 増えて約25%遅くなります。

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
(UART 端末の都合で表示は英語です)

対局中は **キーを1つ押すだけ** で着手します (Enter 不要)。
`0`〜`9`, `a`〜`z`, `A`〜`Z`, `;`, `:` の64文字が、順に
1a, 2a, …, 8a, 1b, …, 7h, 8h のマスに対応します (数字=行、英字=列)。
`!` で対局を中断します。対応表はメニューで `keys` と打つと表示されます。

```
   a b c d e f g h
 8 7 f n v D L T :
 7 6 e m u C K S ;
 6 5 d l t B J R Z
 5 4 c k s A I Q Y
 4 3 b j r z H P X
 3 2 a i q y G O W
 2 1 9 h p x F N V
 1 0 8 g o w E M U
```

AI の着手も `c5[k]` のようにマスとキーの両方で表示します。

### GUI で対戦

`othello_gui.py` をシリアル接続で使えます (pyserial が必要)。

```powershell
pip install pyserial
python othello_ai_c\othello_AI\othello_gui.py --serial COM3
```

GUI は PC 版 `engine_cli` と同じ `BESTMOVE` コマンドをボードへ送ります。
FPGA 版は 1 手あたり 250ms・残り 14 マスから完全読みを試みる設定です
(`othello_gui.py` の `FPGA_TIME_MS` / `FPGA_ENDGAME_THRESHOLD`)。

## 持ち時間 (1手 0.309 秒の大会規定向け)

`BESTMOVE` の `time_ms` で1手の思考時間を指定します。ボードはコマンドを
受信し終えた時点からサイクルカウンタで時間を測り、`time_ms` で探索を打ち切ります。
打ち切りから応答の1文字目までの遅れは約3ms以内です (シミュレーションで確認)。

PC から見た1手の時間には、さらに次が加わります。

| 項目 | 時間 |
|:--|:--|
| コマンド送信 (約55文字 @115200bps) | 約5ms |
| 応答送信 (約25文字) | 約2ms |
| USB シリアルの遅延 (PC・OS 依存) | 数ms〜16ms 程度 |

0.309 秒の規定には **`time_ms` = 250** を推奨します (GUI と端末対戦の既定値)。
対戦サーバ側の計測方法に合わせて調整してください。

終盤は、まず持ち時間の1/6で通常の探索をして手を確保し、残り時間で完全読みを
試みます。読み切れなければ通常探索の手を返すので、持ち時間は必ず守られます。

## 強さ・速度

50 MHz で `time_ms` = 250 のとき (シミュレーションでの実測):

- 中盤: 深さ 5〜6 (たまに7)
- 終盤: 残り 10 マス以下は確実に読み切り (8マスで約50ms、10マスで約70〜130ms)。
  12 マスは読み切れることがあり、14 マスは通常探索になる

初版からの高速化 (中盤の同じ局面を深さ4で探索: 1,026ms → 60ms、約17倍):

| 変更 | 内容 |
|:--|:--|
| 合法手生成・反転 | 方向ごとに定数シフトへ展開 (RV32 の64bit可変シフトを回避)、反転は隣が相手石の方向だけ計算 |
| 評価関数 | 確定石を辺ごとに8bitで計算、空きマス隣接を1回だけ計算、合法手を探索側と共有 |
| 探索 | 残り深さ1で葉の評価の二重計算を削除しβカット、残り深さ2の並べ替えを相手の着手数に |
| 終盤 | 評価関数を使わない専用ソルバ (相手の着手数が少ない順、残り5マス以下は空きマスを直接試す) |
| その他 | popcount/ctz の自前実装、乗算ハッシュ、命令スケジューリング無効化 |
| 時間管理 | 途中で打ち切った反復でも、読み終えたルートの手の最善を採用 |

## シミュレーションでの確認

```bash
make -C othello_ai_c/othello_AI fpga
iverilog -I src -o sim/tb_othello_fpga.out sim/tb_othello_fpga.v \
  src/cpu_top.v src/alu.v src/register_file.v src/instruction_decoder.v src/control_unit.v \
  src/imm_gen.v src/instruction_memory.v src/data_memory.v src/multiplier.v src/divider.v \
  src/uart_tx.v src/uart_rx.v
vvp sim/tb_othello_fpga.out
```

CPU 上で `BESTMOVE` を4局面実行し、PC 上で同じソースを動かした結果と一致するか、
250ms 指定で時間内に応答するかを確認します (十数分かかります)。

速度を測ったりプロファイルを取ったりするときは、Verilator 版が数百倍速くて便利です。

```bash
make -C sim/verilator
printf 'BESTMOVE 0000000810000000 0000001008000000 b 60 250 14\n' | sim/verilator/obj/uart_sim
```

使い方は `sim/verilator/Makefile` の先頭を参照してください。

PC 上で FPGA 版の動作だけ確かめたい場合は、標準入出力を UART 代わりにした
ホスト版も作れます。

```bash
make othello_fpga_host && ./othello_fpga_host
```
