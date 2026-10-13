# pong-chip -- Verilog Pong for the ForgeFPGA SLG47910V on a Vicharak Shrike Lite
#
# Targets
#   make            lint + all simulation + all python checks
#   make sim        every testbench and trace comparison
#   make lint       verilator --lint-only over src/
#   make phys       python physics / timing / bandwidth checks
#   make frames     render simulation frames to PGM images
#   make fpga       synthesis + place & route -> real ForgeFPGA bitstream
#   make asic       Tiny Tapeout / SKY130 wrapper elaboration check
#   make clean
#
# The FPGA flow lives in fpga/ and needs the Renesas Go Configure Software
# Hub (see docs/ARCHITECTURE.md and fpga/Makefile).

SHELL      := /bin/sh
TOP        := pong_top
SRC        := $(wildcard src/*.v)
OUT        := out
PY         := python3
IVFLAGS    := -g2005 -Wall -Wno-timescale -o

# Tool discovery: use the locally built/generated tools when they are here
# (this container has no root and no system iverilog), otherwise whatever
# is on PATH.
LOCAL_TOOLS := $(CURDIR)/../.tools
GCSW        ?= $(CURDIR)/../.tools/goconfig/usr/local/go-configure-sw-hub/bin/external
ifneq ($(wildcard $(LOCAL_TOOLS)/iverilog/bin/iverilog),)
IV          ?= $(LOCAL_TOOLS)/iverilog/bin/iverilog
VV          ?= $(LOCAL_TOOLS)/iverilog/bin/vvp
else
IV          ?= iverilog
VV          ?= vvp
endif
# VERILATOR_ROOT is only exported when the local build is used: a system
# verilator (e.g. Debian's) is a wrapper script that derives verilator_bin
# from VERILATOR_ROOT, so exporting the local path while running the system
# one makes it exec a file that is not there.
ifneq ($(wildcard $(GCSW)/verilator/bin/verilator_bin),)
VERILATOR     ?= $(GCSW)/verilator/bin/verilator_bin
export VERILATOR_ROOT ?= $(GCSW)/verilator
else
VERILATOR     ?= verilator
endif

# iverilog and the placer both write scratch files; containers usually have
# a small /tmp, so keep them here.
export TMPDIR ?= $(CURDIR)/tmp

.PHONY: all sim lint phys frames fpga asic clean help

all: lint sim phys

# ── simulation ───────────────────────────────────────────────────────────────
$(OUT):
	@mkdir -p $(OUT)

# iverilog and eda-placer need a writable scratch directory; it is not in
# the repository (a fresh clone has no tmp/), so create it on demand.
$(TMPDIR):
	@mkdir -p $(TMPDIR)

sim: $(OUT) sim-i2c sim-tick sim-core sim-pong sim-font | $(TMPDIR)
	@echo "== all simulations passed =="

sim-i2c: $(OUT) | $(TMPDIR)
	@echo "-- tb_i2c_master (UM10204 fast-mode timing)"
	@$(IV) $(IVFLAGS) $(OUT)/tb_i2c.vvp src/i2c_master.v sim/tb_i2c_master.v
	@$(VV) $(OUT)/tb_i2c.vvp | grep -E "measured|PASSED|FAIL|NACK|ACK"

sim-tick: $(OUT) | $(TMPDIR)
	@echo "-- tb_tick (one-cycle tick every 2**16 clocks)"
	@$(IV) $(IVFLAGS) $(OUT)/tb_tick.vvp src/tick_gen.v sim/tb_tick.v
	@$(VV) $(OUT)/tb_tick.vvp | grep -E "tick period|FAIL"

sim-core: $(OUT) | $(TMPDIR)
	@echo "-- tb_core + compare_trace (RTL vs golden model, 2000 ticks)"
	@$(IV) $(IVFLAGS) $(OUT)/tb_core.vvp src/pong_core.v sim/tb_core.v
	@$(VV) $(OUT)/tb_core.vvp > $(OUT)/tb_core.log
	@$(PY) scripts/physics.py --trace $(OUT)/model_trace.txt
	@$(PY) scripts/compare_trace.py

sim-pong: $(OUT) | $(TMPDIR)
	@echo "-- tb_pong (full design + SSD1306 model, 60 frames of I2C)"
	@$(IV) $(IVFLAGS) $(OUT)/tb_pong.vvp $(SRC) sim/ssd1306_model.v sim/tb_pong.v
	@cd $(CURDIR) && $(VV) $(OUT)/tb_pong.vvp | grep -E "frames|FAIL|PASS"
	@$(PY) scripts/frame_check.py $(OUT)/frames.hex --all --quiet

sim-font: $(OUT) | $(TMPDIR)
	@echo "-- tb_font (font ROM against scripts/font_gen.py)"
	@$(IV) $(IVFLAGS) $(OUT)/tb_font.vvp src/pong_font.v sim/tb_font.v
	@$(VV) $(OUT)/tb_font.vvp | grep -E "written|FAIL|PASS"
	@$(PY) scripts/font_gen.py --check $(OUT)/font_dump.txt

# ── lint ─────────────────────────────────────────────────────────────────────
lint: $(OUT)
	@echo "-- verilator lint"
	@$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
		-Wno-VARHIDDEN -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-WIDTHEXPAND \
		-Wno-PINCONNECTEMPTY --top-module $(TOP) $(SRC) && echo "lint: clean"

# ── python checks ────────────────────────────────────────────────────────────
phys:
	@$(PY) scripts/physics.py --check
	@$(PY) scripts/i2c_timing.py --check

frames: $(OUT)
	@$(PY) scripts/frame_check.py $(OUT)/frames.hex --all --quiet
	@$(PY) scripts/frame_dump.py $(OUT)/frames.hex --last --pgm $(OUT)/last.pgm
	@$(PY) scripts/frame_dump.py $(OUT)/frames.hex --text --index 59

# ── hardware ─────────────────────────────────────────────────────────────────
fpga:
	@$(MAKE) -C fpga all          # update (pin map) + build (bitstream)

asic:
	@$(MAKE) -C asic check IV="$(IV)" VERILATOR="$(VERILATOR)"

clean:
	@rm -rf $(OUT)/*.vvp $(OUT)/*.vcd $(OUT)/*.log
	@$(MAKE) -C fpga clean >/dev/null 2>&1 || true

help:
	@sed -n '2,18p' Makefile
