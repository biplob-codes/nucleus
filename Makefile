BIN    := container
SRCS   := $(wildcard *.c)
HDRS   := $(wildcard *.h)
CFLAGS := -std=gnu11 -D_GNU_SOURCE -g \
          -Wall -Wextra -Wpedantic -Wshadow -Werror \
          -fsanitize=address,undefined

.PHONY: run format

run:
	$(CC) $(CFLAGS) $(SRCS) -o $(BIN)
	sudo ./$(BIN) -h nucleus

format:
	clang-format -i $(SRCS) $(HDRS)