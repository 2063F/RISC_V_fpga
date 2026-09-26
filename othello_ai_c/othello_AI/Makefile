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

clean:
	rm -f test_replay dump_features play benchmark engine_cli *.o

.PHONY: all clean
