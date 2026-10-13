# asic -- the same RTL on an open process
#
# Two things live here:
#
#   check   elaborate and lint the Tiny Tapeout wrapper (this runs in CI and
#           needs nothing but iverilog and verilator)
#   harden  run the Tiny Tapeout / OpenLane flow, which needs Docker and a
#           checkout of https://github.com/TinyTapeout/ttsky-verilog (or the
#           matching shuttle template).  It is a separate target because it
#           cannot run inside this container (no Docker daemon, no root).
#
# The point of a Tiny Tapeout port is that the design is fabric independent:
# src/ has no vendor primitives, no gated clocks and no multi-clock
# structures, so the same files synthesise for SKY130 / GF180 through the
# standard open flow.  See docs/FAB.md for what the shuttle costs and what
# the wrapper has to satisfy.

TT_REPO  ?= https://github.com/TinyTapeout/ttsky-verilog
TT_DIR   ?= ../ttsky-verilog
IV       ?= iverilog
VERILATOR?= verilator
SRC      := ../src/*.v tt_um_pong.v

.PHONY: check elaborate lint harden clean

check: elaborate lint
	@echo "asic: wrapper elaborates and lints"

elaborate:
	@echo "-- elaborating tt_um_pong with the real RTL"
	@$(IV) -g2005 -Wall -Wno-timescale -o /dev/null -s tt_um_pong $(SRC) \
		&& echo "elaborate: ok"

lint:
	@echo "-- verilator lint (wrapper + RTL)"
	@$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
		-Wno-VARHIDDEN -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-WIDTHEXPAND \
		-Wno-PINCONNECTEMPTY --top-module tt_um_pong $(SRC) && echo "lint: clean"

# Placeholder until the shuttle template is checked out; see the README.
harden:
	@test -d $(TT_DIR) || { \
		echo "Clone the shuttle template first:"; \
		echo "  git clone $(TT_REPO) $(TT_DIR)"; exit 1; }
	@echo "Copy tt_um_pong.v and info.yaml into $(TT_DIR)/src/ then run its"
	@echo "GitHub Action (or 'make' in that repo for a local OpenLane run)."

clean:
	@rm -f *.vvp *.vcd
