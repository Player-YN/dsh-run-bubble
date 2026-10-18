SHELL := /bin/zsh
SWIFT ?= swiftc
NODE  ?= node
BIN   := RunBubbleOverlay

.PHONY: all build check install status snapshot clean

all: build

build:
	$(SWIFT) -O -parse-as-library -framework AppKit overlay.swift -o $(BIN)

check:
	$(NODE) --check daemon.mjs
	$(NODE) --check interop/dsh-chat.mjs
	$(SWIFT) -typecheck -parse-as-library -framework AppKit overlay.swift

install: build
	./run-bubble install --rebuild

status:
	./run-bubble status

snapshot:
	./run-bubble snapshot /tmp/dsh-run-bubble.png

clean:
	rm -f $(BIN)
