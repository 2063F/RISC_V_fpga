@echo off
REM Windows用ビルドスクリプト（makeが無くても動きます）
REM 事前に MinGW-w64 などで gcc をインストールし、コマンドプロンプトで
REM   gcc --version
REM が通ることを確認してから、このファイルをダブルクリックするか
REM コマンドプロンプトで build.bat と入力して実行してください。

gcc -O2 -Wall -Wextra -std=c11 -o test_replay.exe test_replay.c othello.c
if errorlevel 1 goto :error

gcc -O2 -Wall -Wextra -std=c11 -o dump_features.exe dump_features.c othello.c evaluate.c
if errorlevel 1 goto :error

gcc -O2 -Wall -Wextra -std=c11 -o play.exe play.c othello.c evaluate.c search.c
if errorlevel 1 goto :error

gcc -O2 -Wall -Wextra -std=c11 -o benchmark.exe benchmark.c othello.c evaluate.c search.c
if errorlevel 1 goto :error

gcc -O2 -Wall -Wextra -std=c11 -o engine_cli.exe engine_cli.c othello.c evaluate.c search.c
if errorlevel 1 goto :error

gcc -O2 -Wall -Wextra -std=c11 -mwindows -o othello.exe othello_win32.c othello.c evaluate.c search.c
if errorlevel 1 goto :error

echo.
echo ビルド完了: test_replay.exe / dump_features.exe / play.exe / benchmark.exe / engine_cli.exe / othello.exe
echo.
echo [おすすめ] othello.exe をダブルクリックするだけで対戦できます（Pythonのインストール不要）
echo [文字だけで対戦] play.exe をダブルクリック、またはコマンドプロンプトで play.exe
echo [盤面つきGUI(Python版)で対戦] python othello_gui.py  （このフォルダに engine_cli.exe が必要）
pause
goto :eof

:error
echo.
echo ビルドに失敗しました。gccがインストールされているか確認してください。
pause
