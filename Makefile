BIN    := container
SRCS   := $(wildcard *.c)
HDRS   := $(wildcard *.h)
ROOTFS := /home/biplobcodes/projects/alpine-rootfs
CFLAGS := -std=gnu11 -D_GNU_SOURCE -g \
          -Wall -Wextra -Wpedantic -Wshadow -Werror \
          -fsanitize=address,undefined

# every leakcheck command gets the same environment
LC := sudo env LEAK_ROOTFS=$(ROOTFS) NUC_BIN=./$(BIN) SRC_DIR=. ./leakcheck.sh

.PHONY: build run check check-i test list explain status watch clean-leaks clean-nat format

build: $(BIN)

$(BIN): $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) $(SRCS) -o $(BIN)

# start a container shell (interactive) - unchanged
run: $(BIN)
	sudo ./$(BIN) -h nucleus -fs $(ROOTFS)

# quick leak test: start a container, exit it, print the leak report
check: $(BIN)
	echo exit | $(LC) check -- ./$(BIN) -h nucleus -fs $(ROOTFS)

# same, but you get the shell and type `exit` yourself
check-i: $(BIN)
	$(LC) check -- ./$(BIN) -h nucleus -fs $(ROOTFS)

# the roadmap test suite:
#   make test            everything
#   make test T=2        one phase
#   make test T=2.1a     one task
#   make test T="1 2.4"  several
test: $(BIN)
	$(LC) test $(T)

list:
	@./leakcheck.sh list

# make explain T=2.1a  -> what the test proves and what "fixed" looks like
explain:
	@./leakcheck.sh explain $(T)

# one-shot view of everything Nucleus currently owns on the host
status:
	@$(LC) status

# live view: run `make run` in one terminal and this in another
watch:
	sudo watch -n1 -c env LEAK_ROOTFS=$(ROOTFS) ./leakcheck.sh status

# remove cgroups, veths, NAT rules and processes left by crashed runs
clean-leaks:
	$(LC) clean

clean-nat: clean-leaks

format:
	clang-format -i $(SRCS) $(HDRS)