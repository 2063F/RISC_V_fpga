#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
オセロAI 対戦GUI（人間 vs AI）。

・盤面のクリックだけで対局できるTkinter製の画面です。
・AIの思考（探索）は C言語版のエンジン(engine_cli / engine_cli.exe)を
  裏で1プロセス起動しっぱなしにして呼び出します。探索ロジック自体は
  C側のものをそのまま使うので、CLI版(play)と全く同じ強さで対戦できます。

事前準備:
  1. このフォルダで C言語版をビルドしておく
     Windows: build.bat を実行（engine_cli.exe ができる）
     Mac/Linux: make （engine_cli ができる）
  2. Python 3 (tkinter同梱) で実行:
       python othello_gui.py
     Windowsで tkinter が無いと言われたら、Python公式インストーラから
     入れ直す際に "tcl/tk and IDLE" にチェックを入れてください。

FPGA (RISC-V CPU) 上のエンジンと対戦する場合:
  othello_fpga.hex を書き込んだボードを USB で接続し、pyserial を入れてから
       pip install pyserial
       python othello_gui.py --serial COM3
  のようにシリアルポートを指定します（詳細は ../README_FPGA.md）。
"""
import argparse
import os
import subprocess
import sys
import tkinter as tk
from tkinter import messagebox

CELL = 64
MARGIN = 24
BOARD_PX = CELL * 8

BLACK, WHITE, EMPTY = 1, -1, 0
DIRS = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]

AI_MAX_DEPTH = 30
AI_TIME_MS = 1200
ENDGAME_THRESHOLD = 16

# FPGA 版の設定。1手 0.309 秒の大会規定に、UART の送受信 (約7ms) と
# PC 側の遅延の余裕を持たせた思考時間にしている
FPGA_TIME_MS = 250
FPGA_ENDGAME_THRESHOLD = 14


def engine_binary_path():
    here = os.path.dirname(os.path.abspath(__file__))
    for name in ("engine_cli.exe", "engine_cli"):
        p = os.path.join(here, name)
        if os.path.exists(p):
            return p
    return None


class Engine:
    """C言語版エンジン(engine_cli)を1プロセス立ち上げっぱなしにして対話する。"""

    def __init__(self, path):
        self.proc = subprocess.Popen(
            [path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )

    def best_move(self, black, white, player_is_black,
                  max_depth=AI_MAX_DEPTH, time_ms=AI_TIME_MS, endgame_threshold=ENDGAME_THRESHOLD):
        cmd = "BESTMOVE {:016x} {:016x} {} {} {} {}\n".format(
            black, white, "b" if player_is_black else "w",
            max_depth, time_ms, endgame_threshold,
        )
        self.proc.stdin.write(cmd)
        self.proc.stdin.flush()
        line = self.proc.stdout.readline().strip()
        parts = line.split()
        if not parts or parts[0] != "MOVE":
            raise RuntimeError("engineからの応答が不正です: " + line)
        sq_str, score, depth, nodes = parts[1], parts[2], parts[3], parts[4]
        if sq_str == "PASS":
            return None, float(score), int(depth), int(nodes)
        col = ord(sq_str[0]) - ord('a')
        row = int(sq_str[1]) - 1
        return (row, col), float(score), int(depth), int(nodes)

    def close(self):
        try:
            self.proc.stdin.write("QUIT\n")
            self.proc.stdin.flush()
        except Exception:
            pass
        try:
            self.proc.terminate()
        except Exception:
            pass


class SerialEngine:
    """FPGA (RISC-V CPU) 上の othello_fpga と UART 経由で対話する。

    プロトコルは engine_cli と同じ BESTMOVE 形式。ボードは入力をエコーバックし、
    プロンプト等も出すので、"MOVE" / "ERROR" で始まる行が来るまで読み飛ばす。
    """

    def __init__(self, port, baud=115200):
        try:
            import serial  # pyserial
        except ImportError:
            print("pyserial が必要です: pip install pyserial")
            sys.exit(1)
        self.ser = serial.Serial(port, baud, timeout=1)
        # 起動メッセージなどの残りを捨てる
        self.ser.write(b"\r")
        self.ser.reset_input_buffer()

    def best_move(self, black, white, player_is_black,
                  max_depth=AI_MAX_DEPTH, time_ms=FPGA_TIME_MS,
                  endgame_threshold=FPGA_ENDGAME_THRESHOLD):
        cmd = "BESTMOVE {:016x} {:016x} {} {} {} {}\r".format(
            black, white, "b" if player_is_black else "w",
            max_depth, time_ms, endgame_threshold,
        )
        self.ser.reset_input_buffer()
        self.ser.write(cmd.encode("ascii"))
        # ボードはサイクルカウンタで time_ms を守るが、念のため余裕を持って待つ
        deadline_s = time_ms / 1000.0 * 3 + 10
        waited = 0.0
        while True:
            raw = self.ser.readline()
            if not raw:
                waited += self.ser.timeout
                if waited > deadline_s:
                    raise RuntimeError("FPGAからの応答がタイムアウトしました")
                continue
            line = raw.decode("ascii", errors="replace").strip()
            if line.startswith("ERROR"):
                raise RuntimeError("FPGAからの応答が不正です: " + line)
            if not line.startswith("MOVE"):
                continue  # エコーバックやプロンプト
            parts = line.split()
            sq_str, score, depth, nodes = parts[1], parts[2], parts[3], parts[4]
            if sq_str == "PASS":
                return None, float(score), int(depth), int(nodes)
            col = ord(sq_str[0]) - ord('a')
            row = int(sq_str[1]) - 1
            return (row, col), float(score), int(depth), int(nodes)

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass


def new_board():
    b = [[EMPTY] * 8 for _ in range(8)]
    b[3][3], b[4][4] = WHITE, WHITE
    b[3][4], b[4][3] = BLACK, BLACK
    return b


def flips_for_move(board, r, c, player):
    if board[r][c] != EMPTY:
        return []
    opp = -player
    result = []
    for dr, dc in DIRS:
        line = []
        rr, cc = r + dr, c + dc
        while 0 <= rr < 8 and 0 <= cc < 8 and board[rr][cc] == opp:
            line.append((rr, cc))
            rr += dr
            cc += dc
        if line and 0 <= rr < 8 and 0 <= cc < 8 and board[rr][cc] == player:
            result.extend(line)
    return result


def legal_moves(board, player):
    return [(r, c) for r in range(8) for c in range(8)
            if board[r][c] == EMPTY and flips_for_move(board, r, c, player)]


def apply_move(board, r, c, player):
    flips = flips_for_move(board, r, c, player)
    board[r][c] = player
    for rr, cc in flips:
        board[rr][cc] = player


def move_to_str(r, c):
    """(行,列)の内部座標を 'f5' のような棋譜表記(列a-h+行1-8)に変換する。
    このプロジェクトの棋譜データ(kifu*.txt / WTHOR変換データ)と同じ表記。"""
    return chr(ord('a') + c) + str(r + 1)


def to_bitboards(board):
    black = white = 0
    for r in range(8):
        for c in range(8):
            sq = r * 8 + c
            if board[r][c] == BLACK:
                black |= (1 << sq)
            elif board[r][c] == WHITE:
                white |= (1 << sq)
    return black, white


class OthelloGUI:
    def __init__(self, root, engine):
        self.root = root
        self.engine = engine
        self.board = new_board()
        self.player = BLACK  # 黒から開始
        self.human_color = BLACK
        self.game_over = False
        self.move_history = []  # 実際に打たれた手を順番に文字列("f5"等)で記録。パスは含めない

        root.title("オセロAI対戦")
        top = tk.Frame(root)
        top.pack(pady=6)
        tk.Label(top, text="あなたの色:").pack(side=tk.LEFT)
        self.color_var = tk.StringVar(value="黒")
        tk.OptionMenu(top, self.color_var, "黒", "白", command=self.on_color_change).pack(side=tk.LEFT)
        tk.Button(top, text="新しい対局", command=self.new_game).pack(side=tk.LEFT, padx=10)

        self.status = tk.Label(root, text="", font=("Meiryo", 12))
        self.status.pack(pady=4)

        self.canvas = tk.Canvas(root, width=BOARD_PX + MARGIN * 2, height=BOARD_PX + MARGIN * 2,
                                 bg="#0a5c2a")
        self.canvas.pack(padx=10, pady=10)
        self.canvas.bind("<Button-1>", self.on_click)

        # --- 棋譜表示欄 ---
        kifu_frame = tk.Frame(root)
        kifu_frame.pack(fill=tk.X, padx=10, pady=(0, 10))
        tk.Label(kifu_frame, text="棋譜:").pack(side=tk.LEFT)
        self.kifu_var = tk.StringVar(value="")
        self.kifu_entry = tk.Entry(kifu_frame, textvariable=self.kifu_var, state="readonly",
                                    font=("Consolas", 10), width=50)
        self.kifu_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=6)
        tk.Button(kifu_frame, text="棋譜をコピー", command=self.copy_kifu).pack(side=tk.LEFT)

        self.update_kifu_display()
        self.draw()
        self.root.after(200, self.maybe_ai_turn)

    def on_color_change(self, value):
        self.human_color = BLACK if value == "黒" else WHITE
        self.new_game()

    def new_game(self):
        self.board = new_board()
        self.player = BLACK
        self.game_over = False
        self.move_history = []
        self.update_kifu_display()
        self.draw()
        self.root.after(200, self.maybe_ai_turn)

    def update_kifu_display(self):
        # 先手(黒)=F, 後手(白)=S。プレイヤー(人間)の手番を基準にする。
        prefix = "F" if self.human_color == BLACK else "S"
        self.kifu_var.set(prefix + "".join(self.move_history))

    def copy_kifu(self):
        text = self.kifu_var.get()
        self.root.clipboard_clear()
        self.root.clipboard_append(text)
        self.root.update()  # クリップボードの内容を確定させるために必要
        self.status.config(text=self.status.cget("text") + "  (棋譜をコピーしました)")

    # --- 座標変換: 画面の上がrow8、下がrow1になるようにする（CLI版play.cと同じ見た目） ---
    def screen_to_board(self, row_screen, col_screen):
        return 7 - row_screen, col_screen

    def board_to_screen(self, r, c):
        return 7 - r, c

    def draw(self):
        self.canvas.delete("all")
        for rs in range(8):
            for cs in range(8):
                x0 = MARGIN + cs * CELL
                y0 = MARGIN + rs * CELL
                self.canvas.create_rectangle(x0, y0, x0 + CELL, y0 + CELL, outline="black")
        for i in range(8):
            self.canvas.create_text(MARGIN + i * CELL + CELL / 2, MARGIN / 2,
                                     text=chr(ord('a') + i), fill="white")
            self.canvas.create_text(MARGIN / 2, MARGIN + i * CELL + CELL / 2,
                                     text=str(8 - i), fill="white")

        moves = legal_moves(self.board, self.player) if not self.game_over else []
        is_human_turn = (self.player == self.human_color) and not self.game_over

        for r in range(8):
            for c in range(8):
                rs, cs = self.board_to_screen(r, c)
                x0, y0 = MARGIN + cs * CELL, MARGIN + rs * CELL
                v = self.board[r][c]
                if v != EMPTY:
                    color = "black" if v == BLACK else "white"
                    self.canvas.create_oval(x0 + 4, y0 + 4, x0 + CELL - 4, y0 + CELL - 4,
                                             fill=color, outline="gray")
                elif is_human_turn and (r, c) in moves:
                    cx, cy = x0 + CELL / 2, y0 + CELL / 2
                    self.canvas.create_oval(cx - 5, cy - 5, cx + 5, cy + 5, fill="#ffd54a", outline="")

        b_count = sum(row.count(BLACK) for row in self.board)
        w_count = sum(row.count(WHITE) for row in self.board)
        turn_str = "あなたの番です" if is_human_turn else ("AI思考中..." if not self.game_over else "")
        self.status.config(text=f"黒:{b_count}  白:{w_count}   {turn_str}")

    def on_click(self, event):
        if self.game_over or self.player != self.human_color:
            return
        cs = (event.x - MARGIN) // CELL
        rs = (event.y - MARGIN) // CELL
        if not (0 <= rs < 8 and 0 <= cs < 8):
            return
        r, c = self.screen_to_board(int(rs), int(cs))
        moves = legal_moves(self.board, self.player)
        if (r, c) not in moves:
            return
        apply_move(self.board, r, c, self.player)
        self.move_history.append(move_to_str(r, c))
        self.update_kifu_display()
        self.player = -self.player
        self.draw()
        self.root.after(150, self.maybe_ai_turn)

    def maybe_ai_turn(self):
        if self.game_over:
            return

        moves = legal_moves(self.board, self.player)
        opp_moves_exist = True

        if not moves:
            # 現手番がパス
            self.player = -self.player
            moves2 = legal_moves(self.board, self.player)
            if not moves2:
                self.finish_game()
                return
            self.draw()
            self.root.after(200, self.maybe_ai_turn)
            return

        if self.player == self.human_color:
            self.draw()
            return  # 人間の番。クリックを待つ

        # ここからAIの番
        self.status.config(text=self.status.cget("text") + "  (AI思考中...)")
        self.root.update()

        black, white = to_bitboards(self.board)
        player_is_black = (self.player == BLACK)
        try:
            mv, score, depth, nodes = self.engine.best_move(black, white, player_is_black)
        except Exception as e:
            messagebox.showerror("エラー", f"AIエンジンとの通信に失敗しました: {e}")
            return

        if mv is None:
            self.player = -self.player
        else:
            r, c = mv
            apply_move(self.board, r, c, self.player)
            self.move_history.append(move_to_str(r, c))
            self.update_kifu_display()
            self.player = -self.player

        self.draw()

        # 次も人間が手がない可能性を考慮し、再度チェックへ
        nxt_moves = legal_moves(self.board, self.player)
        opp_moves = legal_moves(self.board, -self.player)
        if not nxt_moves and not opp_moves:
            self.finish_game()
        else:
            self.root.after(150, self.maybe_ai_turn)

    def finish_game(self):
        self.game_over = True
        b_count = sum(row.count(BLACK) for row in self.board)
        w_count = sum(row.count(WHITE) for row in self.board)
        self.draw()
        if b_count > w_count:
            winner = "黒の勝ち"
        elif w_count > b_count:
            winner = "白の勝ち"
        else:
            winner = "引き分け"
        you = "黒" if self.human_color == BLACK else "白"
        result = "あなたの勝ちです！" if ((b_count > w_count) == (self.human_color == BLACK) and b_count != w_count) else \
                 ("あなたの負けです" if b_count != w_count else "引き分けです")
        messagebox.showinfo("対局終了", f"{winner} ({b_count} - {w_count})\nあなたは{you}番でした。{result}")


def main():
    parser = argparse.ArgumentParser(description="オセロAI 対戦GUI")
    parser.add_argument("--serial", metavar="PORT",
                        help="FPGA上のエンジンを使う (例: COM3, /dev/ttyUSB1)")
    parser.add_argument("--baud", type=int, default=115200)
    args = parser.parse_args()

    if args.serial:
        engine = SerialEngine(args.serial, args.baud)
    else:
        path = engine_binary_path()
        if not path:
            print("engine_cli(.exe) が見つかりません。先にビルドしてください。")
            print("  Windows: build.bat を実行")
            print("  Mac/Linux: make")
            sys.exit(1)
        engine = Engine(path)
    root = tk.Tk()
    app = OthelloGUI(root, engine)

    def on_close():
        engine.close()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)
    root.mainloop()


if __name__ == "__main__":
    main()
