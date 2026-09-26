# =============================================================================
# cpu_top を Verilator でビルドし、UART を標準入出力につないで高速に動かす。
# iverilog の数百倍速いので、C プログラムの速度測定・プロファイルに使う。
#
#   make -C sim/verilator HEX=othello_ai_c/othello_AI/othello_fpga.hex
#   printf 'BESTMOVE 0000000810000000 0000001008000000 b 60 250 14\n' | \
#       sim/verilator/obj/uart_sim
#
# HEX はリポジトリ直下からの相対パス（実行もリポジトリ直下で行うこと）。
# 関数別のサイクル数を見るには:
#   riscv64-unknown-elf-nm -n --defined-only prog.elf > syms.txt
#   sim/verilator/obj/uart_sim --profile syms.txt < input.txt
# =============================================================================
REPO_ROOT := $(abspath ../..)
HEX ?= othello_ai_c/othello_AI/othello_fpga.hex
SRCS = cpu_top.v alu.v register_file.v instruction_decoder.v control_unit.v imm_gen.v \
       instruction_memory.v data_memory.v multiplier.v divider.v uart_tx.v uart_rx.v

obj/uart_sim: uart_sim.cpp $(addprefix $(REPO_ROOT)/src/,$(SRCS))
	verilator --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style \
	  -I$(REPO_ROOT)/src --top-module cpu_top -GINIT_FILE='"$(HEX)"' \
	  --Mdir obj $(addprefix $(REPO_ROOT)/src/,$(SRCS)) $(CURDIR)/uart_sim.cpp -o uart_sim

clean:
	rm -rf obj

.PHONY: clean
