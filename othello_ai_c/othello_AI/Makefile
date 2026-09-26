CC = gcc
CFLAGS = -O2 -Wall -Wextra -std=c11

all: test_replay dump_features play benchmark engine_cli

test_replay: test_replay.c othello.c othello.h
	$(CC) $(CFLAGS) -o test_replay test_replay.c othello.c

dump_features: dump_features.c othello.c othello.h evaluate.c evaluate.h eval_weights.h
	$(CC) $(CFLAGS) -o dump_features dump_features.c othello.c evaluate.c

play: play.c othello.c evaluate.c search.c othello.h evaluate.h search.h eval_weights.h
	$(CC) $(CFLAGS) -o play play.c othello.c evaluate.c search.c

benchmark: benchmark.c othello.c evaluate.c search.c othello.h evaluate.h search.h eval_weights.h
	$(CC) $(CFLAGS) -o benchmark benchmark.c othello.c evaluate.c search.c

engine_cli: engine_cli.c othello.c evaluate.c search.c othello.h evaluate.h search.h eval_weights.h
	$(CC) $(CFLAGS) -o engine_cli engine_cli.c othello.c evaluate.c search.c

# ---- FPGA (RISC-V RV32IM ソフトCPU) 版 --------------------------------------
# make fpga で othello_fpga.hex を生成する。接頭辞は導入したツールチェーンに合わせる
# (例: make fpga RISCV_PREFIX=riscv-none-elf-)
RISCV_PREFIX ?= riscv64-unknown-elf-
REPO_ROOT = ../..
FPGA_SRCS = othello_fpga.c othello.c evaluate.c search.c
FPGA_HDRS = othello.h evaluate.h search.h eval_weights.h $(REPO_ROOT)/examples/uart.h
# -fno-schedule-insns*: 命令スケジューリングは本CPU(インオーダー3段)では効果が無く、
# レジスタ退避が増えて逆に約25%遅くなるので切る
FPGA_CFLAGS = -march=rv32im -mabi=ilp32 -O2 -fno-schedule-insns -fno-schedule-insns2 \
              -Wall -Wextra -std=c11 \
              -ffreestanding -nostdlib -nostartfiles -DOTHELLO_BAREMETAL \
              -I $(REPO_ROOT)/examples -T $(REPO_ROOT)/tools/link.ld

fpga: othello_fpga.hex

othello_fpga.elf: $(FPGA_SRCS) $(FPGA_HDRS) $(REPO_ROOT)/tools/crt0.S $(REPO_ROOT)/tools/link.ld
	$(RISCV_PREFIX)gcc $(FPGA_CFLAGS) $(REPO_ROOT)/tools/crt0.S $(FPGA_SRCS) -lgcc -o $@
	$(RISCV_PREFIX)size $@

othello_fpga.hex: othello_fpga.elf
	$(RISCV_PREFIX)objcopy -O binary $< othello_fpga.bin
	python3 $(REPO_ROOT)/tools/bin2hex.py othello_fpga.bin $@

# FPGA 版と同じソースを PC 上で動かす (標準入出力を UART 代わりに使う)
othello_fpga_host: $(FPGA_SRCS) othello.h evaluate.h search.h eval_weights.h
	$(CC) $(CFLAGS) -DOTHELLO_BAREMETAL -DOTHELLO_HOST_TEST -o $@ $(FPGA_SRCS)

clean:
	rm -f test_replay dump_features play benchmark engine_cli othello_fpga_host *.o
	rm -f othello_fpga.elf othello_fpga.bin

.PHONY: all clean fpga
