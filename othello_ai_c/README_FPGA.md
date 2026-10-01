# オセロAI を RISC-V CPU (Tang Primer 25K) で動かす

`othello_AI/` の C 言語版オセロAI を、本リポジトリの RV32IM ソフトCPU 上で
動くようにしたものです。PC 版と同じソース (`othello.c` / `evaluate.c` /
`search.c`) を `OTHELLO_BAREMETAL` を定義してビルドします。

## PC 版との違い

| 項目 | PC 版 | FPGA 版 (`OTHELLO_BAREMETAL`) |
|:--|:--|:--|
| 評価値 | `double` | `int32_t` 固定小数点 (1024 = 石1個)。FPU が無いため |
| 置換表 | 2^20 エントリ (`calloc`) | 2^10 エントリ (静的確保, 16 KB) |
| 思考時間 | `clock()` で計測 | CPU のサイクルカウンタ (MMIO `0x8000_0030`) で計測 |
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

### 自作キーボード (キースイッチマトリクス) で着手する

FPGA に 8x8 のキースイッチマトリクスを直結すると、対局中の着手に使えます
(UART のキー入力と併用できます。メニュー操作と盤面表示は UART のまま)。

- 回路: `src/keypad_matrix.v` (走査・チャタリング除去)、MMIO `0x8000_0028`
- キー番号 = 行 × 8 + 列 (0〜63)。上の64文字と同じ順に 1a, 2a, …, 8h に対応
  - 行 r が列 a〜h (r=0 が a)、列 c が行 1〜8 (c=0 が 1)
  - 例: 行3・列2 (キー番号26) = `q` = d3

配線:

| 信号 | FPGA ピン (0→7) | 動作 |
|:--|:--|:--|
| 行 `kbd_row_n[0..7]` | J11, F7, J8, L9, L10, L7, K7, H1 | 1本ずつ 0.5ms Low を出力、他はハイインピーダンス |
| 列 `kbd_col_n[0..7]` | J10, F6, K8, K9, K10, L8, J7, H2 | 内蔵プルアップ。押されたキーの行が Low のとき Low |

- 各キーのスイッチは、その行の線と列の線の間につなぐだけです (抵抗不要、3.3V 系)。
- ダイオードは無くても1キーずつなら正しく動きます。同時押しを正確に取りたい場合は
  各キーにダイオードを入れ、カソードを行側にしてください。
- 1走査 4ms、同じ状態が 12ms 続いたら押下と判定します (チャタリング除去)。
  押したままでは連打になりません。
- ピンを変える場合は `constraints/tang_primer_25k.cst` を編集します。

MMIO の仕様 (`src/board_io.v`):

| アドレス | 読み出し | 書き込み |
|:--|:--|:--|
| `0x8000_0028` | bit8 = 押下イベントあり、bit5:0 = キー番号 | 任意の値でイベントを1つ消費 |

CPU が読まない間に押したキーも順に溜まります (同じキーを2回押した分は1回になります)。

### USB キーボードで着手する

Dock の **USB-A ポート** に USB キーボードを挿すと、対局中の着手に使えます
(UART・キーマトリクスと併用できます)。日本語 (JIS) 配列で、次のキーが
**A1, A2, …, A8, B1, …, H8** の順に対応します (数字 = 段、英字 = 列)。

| マス | キー |
|:--|:--|
| A1〜A8, B1〜B4 | F1 F2 F3 F4 F5 F6 F7 F8 / F9 F10 F11 F12 |
| B5〜B8, C1〜C8, D1〜D2 | 1 2 3 4 / 5 6 7 8 9 0 - ^ / ¥ BackSpace |
| D3〜D8, E1〜E6 | Q W E R T Y / U I O P @ [ |
| E7〜E8, F1〜F8, G1〜G2 | A S / D F G H J K L ; / : ] |
| G3〜G8, H1〜H6 | Z X C V B N / M , . / ＼(ろ) 右Shift |
| H7, H8 | 左Alt, 無変換 |

```
        F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12
        A1 A2 A3 A4 A5 A6 A7 A8 B1 B2  B3  B4
     1  2  3  4  5  6  7  8  9  0  -  ^  ¥  BS
     B5 B6 B7 B8 C1 C2 C3 C4 C5 C6 C7 C8 D1 D2
       Q  W  E  R  T  Y  U  I  O  P  @  [
       D3 D4 D5 D6 D7 D8 E1 E2 E3 E4 E5 E6
        A  S  D  F  G  H  J  K  L  ;  :  ]
        E7 E8 F1 F2 F3 F4 F5 F6 F7 F8 G1 G2
         Z  X  C  V  B  N  M  ,  .  /  ろ 右Shift
         G3 G4 G5 G6 G7 G8 H1 H2 H3 H4 H5 H6
   左Alt = H7   無変換 = H8
```

- キーを押した瞬間に着手します。押しっぱなしでも1回だけです。
- 割り当ての無いキー (Enter・Space・左Shift など) は無視します。
- AI の思考中に押したキーは溜まり、次の自分の手番で使われます
  (メニュー中に押したキーは対局開始時に捨てます)。
- 回路: `src/usb_keyboard.v` (キーコード → マス番号の変換)、MMIO `0x8000_002C`。
  USB の処理は nand2mario さんの [usb_hid_host](https://github.com/nand2mario/usb_hid_host)
  (Apache-2.0、`src/usb_hid_host/`) を使い、PLL で作った 12MHz で動かしています。

制限:

- **低速 (Low-speed, 1.5Mbps) の USB キーボードのみ** 対応です。一般的な
  事務用キーボードの多くは低速ですが、ゲーミングキーボードなど全速 (Full-speed)
  専用の機種は動きません。USB ハブ経由も不可です。
- 一度に認識できる同時押しは4キーまでです (着手には1キーで足ります)。
- USB 機器そのものはシミュレーションできないため、キーボードからのレポートを
  受け取った後の処理だけをテストしています。実機での動作は未確認です。

MMIO の仕様 (`src/board_io.v`):

| アドレス | 読み出し | 書き込み |
|:--|:--|:--|
| `0x8000_002C` | bit9 = キーボード接続中、bit8 = 押下イベントあり、bit5:0 = マス番号 (0 = A1 … 63 = H8) | 任意の値でイベントを1つ消費 |

### 2色ドットマトリクス LED で盤面を表示する

8x8 の赤/緑ドットマトリクス LED (Lite-On LTP-12188M-08) に盤面を表示します。
**白の石 = 赤、黒の石 = 緑** で光ります。

- 対局モードでは盤面が変わるたびに更新します。
- `BESTMOVE` では、受け取った局面をすぐ表示し、応答を送った後に AI が打った後の
  局面へ更新します。
- 回路: `src/led_matrix_bicolor.v` (ダイナミック点灯)。1行 1ms ずつ順に点灯
  (8行で 125Hz、デューティ 1/8)。行の切り替え時は 5µs 全消灯してゴーストを防ぎます。

LED の向き: LED の「行1」を上にして置いたとき、盤面の8段目が上、a列が左
(「列1」) になります。逆向きに取り付ける場合は `othello_fpga.c` の
`LED_FLIP_VERTICAL` を 0 にしてください。

配線 (データシートより、LTP-12188M は **行 = アノード共通、列 = カソード (赤・緑別々)**):

```
FPGA led_row[k]   ── 680Ω ── PNP ベース     PNP エミッタ ── 3.3V
                                           PNP コレクタ ── LED 行(k+1) アノード
FPGA led_col_r[k] ── 68Ω ── LED 列(k+1) 赤カソード
FPGA led_col_g[k] ── 68Ω ── LED 列(k+1) 緑カソード
```

| LED の端子 | LED ピン番号 | FPGA 信号 | FPGA ピン | 途中に入れるもの |
|:--|:--|:--|:--|:--|
| 行1 アノード | 22 | `led_row[0]` | B11 | PNP (コレクタ側が LED) |
| 行2 アノード | 19 | `led_row[1]` | E11 | PNP (コレクタ側が LED) |
| 行3 アノード | 16 | `led_row[2]` | F5 | PNP (コレクタ側が LED) |
| 行4 アノード | 13 | `led_row[3]` | H5 | PNP (コレクタ側が LED) |
| 行5 アノード | 3 | `led_row[4]` | B10 | PNP (コレクタ側が LED) |
| 行6 アノード | 6 | `led_row[5]` | E10 | PNP (コレクタ側が LED) |
| 行7 アノード | 9 | `led_row[6]` | G5 | PNP (コレクタ側が LED) |
| 行8 アノード | 12 | `led_row[7]` | J5 | PNP (コレクタ側が LED) |
| 列1 赤カソード | 23 | `led_col_r[0]` | D11 | 68Ω |
| 列2 赤カソード | 20 | `led_col_r[1]` | A11 | 68Ω |
| 列3 赤カソード | 17 | `led_col_r[2]` | L5 | 68Ω |
| 列4 赤カソード | 14 | `led_col_r[3]` | H8 | 68Ω |
| 列5 赤カソード | 2 | `led_col_r[4]` | D10 | 68Ω |
| 列6 赤カソード | 5 | `led_col_r[5]` | A10 | 68Ω |
| 列7 赤カソード | 8 | `led_col_r[6]` | K5 | 68Ω |
| 列8 赤カソード | 11 | `led_col_r[7]` | H7 | 68Ω |
| 列1 緑カソード | 24 | `led_col_g[0]` | G11 | 68Ω |
| 列2 緑カソード | 21 | `led_col_g[1]` | C11 | 68Ω |
| 列3 緑カソード | 18 | `led_col_g[2]` | K11 | 68Ω |
| 列4 緑カソード | 15 | `led_col_g[3]` | G7 | 68Ω |
| 列5 緑カソード | 1 | `led_col_g[4]` | G10 | 68Ω |
| 列6 緑カソード | 4 | `led_col_g[5]` | C10 | 68Ω |
| 列7 緑カソード | 7 | `led_col_g[6]` | L11 | 68Ω |
| 列8 緑カソード | 10 | `led_col_g[7]` | G8 | 68Ω |

部品の選び方 (データシートの値: 順電圧 typ 2.05V(緑) / 2.1V(赤)、max 2.6V、
1ドットの平均電流 max 25mA):

- **列の抵抗 68Ω**: 3.3V − PNP の飽和電圧 (約0.2V) − 順電圧 (約2.1V) − FPGA の
  Low 電圧 (約0.3V) ≒ 0.8V を 68Ω で割って、点灯中 約12mA (平均はデューティ1/8で
  約1.5mA)。暗ければ 47Ω (約17mA) まで下げられます。順電圧が max 寄りの個体は
  暗めになります (3.3V 電源では余裕が小さいため)。
- **行の PNP**: 1行で最大8ドット × 12〜17mA ≒ 100〜140mA 流れるので、
  コレクタ電流 500mA 級の PNP (S8550, 2SA1020, BC327 など) を使ってください
  (2SA1015 は 150mA なのでぎりぎりです)。ベース抵抗 680Ω でベース電流 約3.5mA。
  行の出力は **Low で点灯** です。
- 列の出力は **Low で点灯** で、FPGA のピンが LED 1個分の電流を吸い込みます
  (制約ファイルで列のピンは DRIVE=16 にしています)。
- ドライバ回路が違う (NPN で行を駆動する等) 場合は、`src/led_matrix_bicolor.v` の
  `ROW_ACTIVE_LOW` / `COL_ACTIVE_LOW` で極性を変えられます。
- もっと明るくしたい場合は行側を 5V にできますが、3.3V の FPGA では PNP を
  切れなくなるので、NPN などでレベル変換が必要です。
- 受け取ったデータシートは型番が LTP-12188M-**07** です。-08 もピン配置は
  同じと想定していますが、念のため手元の部品で確認してください。

MMIO の仕様 (書き込みのみ、`src/led_matrix_bicolor.v`): bit (LED行 × 8 + LED列) が1で点灯。

| アドレス | 内容 |
|:--|:--|
| `0x8000_0040` / `0x8000_0044` | 赤 (行0〜3 / 行4〜7) |
| `0x8000_0048` / `0x8000_004C` | 緑 (行0〜3 / 行4〜7) |

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

FPGA 全体 (キーマトリクス・USB キーボード・LED を含む) の統合テスト:

```bash
iverilog -I src -o sim/tb_othello_keypad.out sim/tb_othello_keypad.v src/*.v \
  src/usb_hid_host/*.v sim/models/gowin_pll_usb.v
vvp sim/tb_othello_keypad.out
```

`fpga_top` を含むシミュレーションでは、Gowin の PLL (`src/gowin/gowin_pll_usb.v`)
の代わりに `sim/models/gowin_pll_usb.v` を使ってください。

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
