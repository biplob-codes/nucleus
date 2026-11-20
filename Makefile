BIN    := container
SRCS   := $(wildcard *.c)
HDRS   := $(wildcard *.h)
ROOTFS := /home/biplobcodes/projects/alpine-rootfs
CFLAGS := -std=gnu11 -D_GNU_SOURCE -g \
          -Wall -Wextra -Wpedantic -Wshadow -Werror \
          -fsanitize=address,undefined

.PHONY: build run check check-i clean-nat format

build: $(BIN)

$(BIN): $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) $(SRCS) -o $(BIN)

# start a container shell (interactive)
run: $(BIN)
	sudo ./$(BIN) -h nucleus -fs $(ROOTFS)

# automatic leak test: starts a container, exits it, prints the report
check: $(BIN)
	echo exit | sudo env LEAK_ROOTFS=$(ROOTFS) ./leakcheck.sh -- ./$(BIN) -h nucleus -fs $(ROOTFS)

# same, but you get the shell and type `exit` yourself
check-i: $(BIN)
	sudo env LEAK_ROOTFS=$(ROOTFS) ./leakcheck.sh -- ./$(BIN) -h nucleus -fs $(ROOTFS)

# delete NAT rules your old runs leaked (run once before your first check)
clean-nat:
	while sudo iptables -t nat -D POSTROUTING -s 12.200.1.1/24 -o enp2s0 -j MASQUERADE 2>/dev/null; do :; done; true

format:
	clang-format -i $(SRCS) $(HDRS)