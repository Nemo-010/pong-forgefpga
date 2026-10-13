#!/usr/bin/env python3
"""
gen_io_spec.py  —  Generate io_spec_in.txt and .ffpga io-spec-tool XML
                    for the SLG47910V (ForgeFPGA) from a PCF-style
                    constraints file.

CONSTRAINTS FILE FORMAT  (*.pcf)
──────────────────────────────────────────────────────────────────────
Lines starting with '#' are comments.  Each assignment is:

    set_io <signal_name>  <assignment>  [# optional comment]

Where <assignment> is one of:

  CLK            External clock input (EFLX_CLK West side, Input=0)

  PIN_N          Package pin N — GPIO output value (GPIO_OUT)
  PIN_N_OE       Package pin N — GPIO output enable (GPIO_OE)
  PIN_N_IN       Package pin N — GPIO input value  (GPIO_IN)
  (N / N_OE / N_IN without the PIN_ prefix also accepted)

  Named internal functions (not user-accessible GPIOs):
    OSC_EN            Oscillator Enable
    OSC_READY         Oscillator Ready (input)
    INT_FPGA_RESET    Internal reset trigger
    INT_FPGA_SLEEP    Internal sleep trigger
    nRST              nRST pin input (PIN 11)
    nSLEEP            nSLEEP pin input (PIN 10)
    FPGA_CORE_READY   Core-ready indicator (input)
    FUNC_MODE         Functional-mode indicator (input)
    REF_LOGIC_AS_CLK0  LaC0 reference output
    REF_LOGIC_AS_CLK1  LaC1 reference output
    LOGIC_AS_CLK0_EN   LaC0 enable output
    LOGIC_AS_CLK1_EN   LaC1 enable output
    PLL_REF_CLK_SEL    PLL ref-clk source select
    PLL_BYPASS         PLL bypass enable
    PLL_EN             PLL enable
    PLL_LOCK           PLL lock indicator (input)
    PLL_CLK            PLL clock (input)
    OSC_CLK            Oscillator clock (input)

EXAMPLE .pcf
────────────
    set_io clk     CLK          # external clock
    set_io LED     PIN_7        # GPIO16_OUT [PIN 7]
    set_io LED_en  PIN_7_OE     # GPIO16_OE  [PIN 7]
    set_io clk_en  OSC_EN       # oscillator enable

USAGE
─────
    python3 gen_io_spec.py --pcf  path/to/constraints.pcf \\
                           --out-iospec  path/to/io_spec_in.txt \\
                           --out-xml     path/to/io_spec_tool.xml

    # Inline into a .ffpga (replaces <io-spec-tool> section):
    python3 gen_io_spec.py --pcf  constraints.pcf --ffpga  in.ffpga  --out-ffpga  out.ffpga

OUTPUT FILES
────────────
  io_spec_in.txt   — passed to eda-placer via gen_fpga_data.py / Makefile
  io_spec_tool.xml — paste into .ffpga <io-spec-tool> section, OR use --ffpga
"""

import argparse, re, sys
from pathlib import Path

# ── SLG47910V (Rev BB / package 26) pin database ────────────────────────────
#
# Each entry: <assignment_key> → (chip_x, chip_y, port_type, port_idx)
#   port_type  : 'Output' | 'Input'
#   port_idx   : 0 or 1
#


_ASSIGN_DB: dict[str, tuple[int, int, str, int]] = {
    # ── GPIO output values  (pin_type = Output0) ───────────────────────────
    'PIN_1':   (31, 25, 'Output', 0),   # GPIO10_OUT
    'PIN_2':   (31, 24, 'Output', 0),   # GPIO11_OUT
    'PIN_3':   (31, 23, 'Output', 0),   # GPIO12_OUT
    'PIN_4':   (31, 22, 'Output', 0),   # GPIO13_OUT
    'PIN_5':   (31,  9, 'Output', 0),   # GPIO14_OUT
    'PIN_6':   (31,  8, 'Output', 0),   # GPIO15_OUT
    'PIN_7':   (31,  6, 'Output', 0),   # GPIO16_OUT
    'PIN_8':   (31,  5, 'Output', 0),   # GPIO17_OUT
    'PIN_9':   (31,  4, 'Output', 0),   # GPIO18_OUT
    'PIN_13':  ( 0,  6, 'Output', 0),   # GPIO0_OUT
    'PIN_14':  ( 0,  7, 'Output', 0),   # GPIO1_OUT
    'PIN_15':  ( 0,  8, 'Output', 0),   # GPIO2_OUT
    'PIN_16':  ( 0,  9, 'Output', 0),   # GPIO3_OUT
    'PIN_17':  ( 0, 10, 'Output', 0),   # GPIO4_OUT
    'PIN_18':  ( 0, 22, 'Output', 0),   # GPIO5_OUT
    'PIN_19':  ( 0, 23, 'Output', 0),   # GPIO6_OUT
    'PIN_20':  ( 0, 24, 'Output', 0),   # GPIO7_OUT
    'PIN_23':  (31, 27, 'Output', 0),   # GPIO8_OUT
    'PIN_24':  (31, 26, 'Output', 0),   # GPIO9_OUT
    # ── GPIO output-enable  (pin_type = Output1) ──────────────────────────
    'PIN_1_OE':  (31, 25, 'Output', 1),
    'PIN_2_OE':  (31, 24, 'Output', 1),
    'PIN_3_OE':  (31, 23, 'Output', 1),
    'PIN_4_OE':  (31, 22, 'Output', 1),
    'PIN_5_OE':  (31,  9, 'Output', 1),
    'PIN_6_OE':  (31,  8, 'Output', 1),
    'PIN_7_OE':  (31,  6, 'Output', 1),
    'PIN_8_OE':  (31,  5, 'Output', 1),
    'PIN_9_OE':  (31,  4, 'Output', 1),
    'PIN_13_OE': ( 0,  6, 'Output', 1),
    'PIN_14_OE': ( 0,  7, 'Output', 1),
    'PIN_15_OE': ( 0,  8, 'Output', 1),
    'PIN_16_OE': ( 0,  9, 'Output', 1),
    'PIN_17_OE': ( 0, 10, 'Output', 1),
    'PIN_18_OE': ( 0, 22, 'Output', 1),
    'PIN_19_OE': ( 0, 23, 'Output', 1),
    'PIN_20_OE': ( 0, 24, 'Output', 1),
    'PIN_23_OE': (31, 27, 'Output', 1),
    'PIN_24_OE': (31, 26, 'Output', 1),
    # ── GPIO input values   (pin_type = Input0) ───────────────────────────
    'PIN_1_IN':  (31, 25, 'Input', 0),
    'PIN_2_IN':  (31, 24, 'Input', 0),
    'PIN_3_IN':  (31, 23, 'Input', 0),
    'PIN_4_IN':  (31, 22, 'Input', 0),
    'PIN_5_IN':  (31,  9, 'Input', 0),
    'PIN_6_IN':  (31,  8, 'Input', 0),
    'PIN_7_IN':  (31,  6, 'Input', 0),
    'PIN_8_IN':  (31,  5, 'Input', 0),
    'PIN_9_IN':  (31,  4, 'Input', 0),
    'PIN_13_IN': ( 0,  6, 'Input', 0),
    'PIN_14_IN': ( 0,  7, 'Input', 0),
    'PIN_15_IN': ( 0,  8, 'Input', 0),
    'PIN_16_IN': ( 0,  9, 'Input', 0),
    'PIN_17_IN': ( 0, 10, 'Input', 0),
    'PIN_18_IN': ( 0, 22, 'Input', 0),
    'PIN_19_IN': ( 0, 23, 'Input', 0),
    'PIN_20_IN': ( 0, 24, 'Input', 0),
    'PIN_23_IN': (31, 27, 'Input', 0),
    'PIN_24_IN': (31, 26, 'Input', 0),
    # ── Named internal functions ───────────────────────────────────────────
    'OSC_EN':            ( 0, 25, 'Output', 0),
    'OSC_READY':         ( 0, 25, 'Input',  0),
    'OSC_CLK':           ( 0, 25, 'Input',  0),  # alias — OSC_CLK comes via CLK tile
    'INT_FPGA_RESET':    (31, 10, 'Output', 0),
    'INT_FPGA_SLEEP':    ( 0, 18, 'Output', 1),
    'nRST':              (31, 10, 'Input',  0),
    'nSLEEP':            (31, 10, 'Input',  1),
    'FPGA_CORE_READY':   (31, 11, 'Input',  0),
    'FUNC_MODE':         (31, 11, 'Input',  1),
    'REF_LOGIC_AS_CLK0': (31, 11, 'Output', 0),
    'REF_LOGIC_AS_CLK1': (31, 11, 'Output', 1),
    'LOGIC_AS_CLK0_EN':  (31, 12, 'Output', 0),
    'LOGIC_AS_CLK1_EN':  (31, 12, 'Output', 1),
    'PLL_REF_CLK_SEL':   ( 0, 11, 'Output', 0),
    'PLL_BYPASS':        ( 0, 11, 'Output', 1),
    'PLL_EN':            ( 0, 18, 'Output', 0),
    'PLL_LOCK':          ( 0, 12, 'Input',  1),
    'PLL_CLK':           ( 0, 12, 'Input',  0),  # not in IOSPEC but matches pattern
}

# Canonical ordered IOB list (chip_x, chip_y) — all IOBs must appear in
# io_spec_in.txt even if unassigned.  Order verified against GUI output.
_CANONICAL_IOBS: list[tuple[int, int]] = [
    # West edge (chip_x=0, chip_y=0..31)
    (0,0),(0,1),(0,2),(0,3),(0,4),(0,5),(0,6),(0,7),(0,8),(0,9),(0,10),
    (0,11),(0,12),(0,13),(0,14),(0,15),(0,16),(0,17),(0,18),(0,19),(0,20),
    (0,21),(0,22),(0,23),(0,24),(0,25),(0,26),(0,27),(0,28),(0,29),(0,30),(0,31),
    # Corner / edge tiles (chip_x=1..30, only chip_y=0,1,30,31)
    (1,0),(1,1),(1,30),(1,31),
    (2,0),(2,1),(2,30),(2,31),
    (3,0),(3,1),(3,30),(3,31),
    (4,0),(4,1),(4,30),(4,31),
    (5,0),(5,1),(5,30),(5,31),
    (6,0),(6,1),(6,30),(6,31),
    (7,0),(7,1),(7,30),(7,31),
    (8,0),(8,1),(8,30),(8,31),
    (9,0),(9,1),(9,30),(9,31),
    (10,0),(10,1),(10,30),(10,31),
    (11,0),(11,1),(11,30),(11,31),
    (12,0),(12,1),(12,30),(12,31),
    (13,0),(13,1),(13,30),(13,31),
    (14,0),(14,1),(14,30),(14,31),
    (15,0),(15,1),(15,30),(15,31),
    (16,0),(16,1),(16,30),(16,31),
    (17,0),(17,1),(17,30),(17,31),
    (18,0),(18,1),(18,30),(18,31),
    (19,0),(19,1),(19,30),(19,31),
    (20,0),(20,1),(20,30),(20,31),
    (21,0),(21,1),(21,30),(21,31),
    (22,0),(22,1),(22,30),(22,31),
    (23,0),(23,1),(23,30),(23,31),
    (24,0),(24,31),
    (25,0),(25,1),(25,30),(25,31),
    (26,0),(26,1),(26,30),(26,31),
    (27,0),(27,1),(27,30),(27,31),
    (28,0),(28,1),(28,30),(28,31),
    (29,0),(29,1),(29,30),(29,31),
    (30,0),(30,1),(30,30),(30,31),
    # East edge (chip_x=31)
    (31,0),(31,1),(31,2),(31,3),(31,4),(31,5),(31,6),
    # chip_y=7 does not exist on this device
    (31,8),(31,9),(31,10),(31,11),(31,12),
    # chip_y=13..18 do not exist on this device
    (31,19),(31,20),(31,21),(31,22),(31,23),(31,24),(31,25),
    (31,26),(31,27),(31,28),(31,29),(31,30),(31,31),
]

# Per-IOB available ports — derived from IOSPEC.txt (all-assigned maximum export)
# (chip_x, chip_y) → sorted list of ('Output'|'Input', idx)
_IOB_PORTS: dict[tuple[int,int], list[tuple[str,int]]] = {
    (0,0):   [('Output',0),('Output',1),('Input',0),('Input',1)],
    (0,1):   [('Output',0),('Output',1),('Input',0),('Input',1)],
    (0,2):   [('Output',0),('Output',1)],
    (0,3):   [('Output',0),('Output',1)],
    (0,4):   [('Output',0),('Output',1)],
    (0,5):   [('Output',0),('Output',1)],
    (0,6):   [('Output',0),('Output',1),('Input',0)],
    (0,7):   [('Output',0),('Output',1),('Input',0)],
    (0,8):   [('Output',0),('Output',1),('Input',0)],
    (0,9):   [('Output',0),('Output',1),('Input',0)],
    (0,10):  [('Output',0),('Output',1),('Input',0)],
    (0,11):  [('Output',0),('Output',1)],
    (0,12):  [('Output',0),('Output',1),('Input',1)],
    (0,13):  [('Output',0),('Output',1)],
    (0,14):  [('Output',0),('Output',1)],
    (0,15):  [('Output',0),('Output',1)],
    (0,16):  [('Output',0),('Output',1)],
    (0,17):  [('Output',0),('Output',1)],
    (0,18):  [('Output',0),('Output',1)],
    (0,19):  [('Output',0),('Output',1)],
    (0,20):  [('Output',0),('Output',1)],
    (0,21):  [('Output',0),('Output',1)],
    (0,22):  [('Output',0),('Output',1),('Input',0)],
    (0,23):  [('Output',0),('Output',1),('Input',0)],
    (0,24):  [('Output',0),('Output',1),('Input',0)],
    (0,25):  [('Output',0),('Input',0)],
    (0,26):  [('Output',0),('Output',1)],
    (0,27):  [('Output',0),('Output',1)],
    (0,28):  [('Output',0),('Output',1)],
    (0,29):  [('Output',0),('Output',1)],
    (0,30):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (0,31):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (1,0):   [('Output',0),('Output',1),('Input',0),('Input',1)],
    (1,1):   [('Output',0),('Output',1),('Input',0),('Input',1)],
    (1,30):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (1,31):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (2,0):   [('Output',0),('Output',1)],
    (2,1):   [('Output',0),('Output',1)],
    (2,30):  [('Output',0),('Output',1)],
    (2,31):  [('Output',0),('Output',1)],
    (3,0):   [('Output',0),('Output',1)],
    (3,1):   [('Output',0),('Output',1)],
    (3,30):  [('Output',0),('Output',1)],
    (3,31):  [('Output',0),('Output',1)],
    (4,0):   [('Output',0),('Output',1)],
    (4,1):   [('Output',0),('Output',1)],
    (4,30):  [('Output',0),('Output',1)],
    (4,31):  [('Output',0),('Output',1)],
    (5,0):   [('Output',0),('Output',1)],
    (5,1):   [('Output',0),('Output',1)],
    (5,30):  [('Output',0),('Output',1)],
    (5,31):  [('Output',0),('Output',1)],
    (6,0):   [('Input',0),('Input',1)],
    (6,1):   [('Output',0),('Output',1)],
    (6,30):  [('Output',0),('Output',1)],
    (6,31):  [('Input',0),('Input',1)],
    (7,0):   [('Output',0),('Output',1),('Input',0),('Input',1)],
    (7,1):   [('Output',0),('Output',1)],
    (7,30):  [('Output',0),('Output',1)],
    (7,31):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (8,0):   [('Output',0),('Output',1),('Input',0),('Input',1)],
    (8,1):   [('Output',0),('Output',1),('Input',0),('Input',1)],
    (8,30):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (8,31):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (9,0):   [('Output',0),('Output',1)],
    (9,1):   [('Output',0),('Output',1)],
    (9,30):  [('Output',0),('Output',1)],
    (9,31):  [('Output',0),('Output',1)],
    (10,0):  [('Output',0),('Output',1)],
    (10,1):  [('Output',0),('Output',1)],
    (10,30): [('Output',0),('Output',1)],
    (10,31): [('Output',0),('Output',1)],
    (11,0):  [('Output',0),('Output',1)],
    (11,1):  [('Output',0),('Output',1)],
    (11,30): [('Output',0),('Output',1)],
    (11,31): [('Output',0),('Output',1)],
    (12,0):  [('Output',0),('Output',1)],
    (12,1):  [('Output',0),('Output',1)],
    (12,30): [('Output',0),('Output',1)],
    (12,31): [('Output',0),('Output',1)],
    (13,0):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (13,1):  [('Output',0),('Output',1)],
    (13,30): [('Output',0),('Output',1)],
    (13,31): [('Output',0),('Output',1),('Input',0),('Input',1)],
    (14,0):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (14,1):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (14,30): [('Output',0),('Output',1),('Input',0),('Input',1)],
    (14,31): [('Output',0),('Output',1),('Input',0),('Input',1)],
    (15,0):  [('Output',0),('Output',1)],
    (15,1):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (15,30): [('Output',0),('Output',1),('Input',0),('Input',1)],
    (15,31): [('Output',0),('Output',1)],
    (16,0):  [('Output',0),('Output',1)],
    (16,1):  [('Output',0),('Output',1)],
    (16,30): [('Output',0),('Output',1)],
    (16,31): [('Output',0),('Output',1)],
    (17,0):  [('Output',0),('Output',1)],
    (17,1):  [('Output',0),('Output',1)],
    (17,30): [('Output',0),('Output',1)],
    (17,31): [('Output',0),('Output',1)],
    (18,0):  [('Output',0),('Output',1)],
    (18,1):  [('Output',0),('Output',1)],
    (18,30): [('Output',0),('Output',1)],
    (18,31): [('Output',0),('Output',1)],
    (19,0):  [('Output',0),('Output',1)],
    (19,1):  [('Output',0),('Output',1)],
    (19,30): [('Output',0),('Output',1)],
    (19,31): [('Output',0),('Output',1)],
    (20,0):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (20,1):  [('Output',0),('Output',1)],
    (20,30): [('Output',0),('Output',1)],
    (20,31): [('Output',0),('Output',1),('Input',0),('Input',1)],
    (21,0):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (21,1):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (21,30): [('Output',0),('Output',1),('Input',0),('Input',1)],
    (21,31): [('Output',0),('Output',1),('Input',0),('Input',1)],
    (22,0):  [('Output',0),('Output',1)],
    (22,1):  [('Output',0),('Output',1),('Input',0),('Input',1)],
    (22,30): [('Output',0),('Output',1),('Input',0),('Input',1)],
    (22,31): [('Output',0),('Output',1)],
    (23,0):  [('Output',0),('Output',1)],
    (23,1):  [('Output',0),('Output',1)],
    (23,30): [('Output',0),('Output',1)],
    (23,31): [('Output',0),('Output',1)],
    (24,0):  [('Output',0),('Output',1)],
    (24,31): [('Output',0),('Output',1)],
    (25,0):  [('Output',0),('Output',1)],
    (25,1):  [('Output',0),('Output',1)],
    (25,30): [('Output',0),('Output',1)],
    (25,31): [('Output',0),('Output',1)],
    (26,0):  [('Output',0),('Output',1)],
    (26,1):  [('Output',0),('Output',1)],
    (26,30): [('Output',0),('Output',1)],
    (26,31): [('Output',0),('Output',1)],
    (27,0):  [('Output',0),('Output',1)],
    (27,1):  [('Output',0),('Output',1)],
    (27,30): [('Output',0),('Output',1)],
    (27,31): [('Output',0),('Output',1)],
    (28,0):  [('Output',0),('Output',1)],
    (28,1):  [('Output',0),('Output',1)],
    (28,30): [('Output',0),('Output',1)],
    (28,31): [('Output',0),('Output',1)],
    (29,0):  [('Output',0),('Output',1)],
    (29,1):  [('Output',0),('Output',1)],
    (29,30): [('Output',0),('Output',1)],
    (29,31): [('Output',0),('Output',1)],
    (30,0):  [('Output',0),('Output',1)],
    (30,1):  [('Output',0),('Output',1)],
    (30,30): [('Output',0),('Output',1)],
    (30,31): [('Output',0),('Output',1)],
    (31,0):  [('Output',0),('Output',1)],
    (31,1):  [('Output',0),('Output',1)],
    (31,2):  [('Output',0),('Output',1)],
    (31,3):  [('Output',0),('Output',1)],
    (31,4):  [('Output',0),('Output',1),('Input',0)],
    (31,5):  [('Output',0),('Output',1),('Input',0)],
    (31,6):  [('Output',0),('Output',1),('Input',0)],
    (31,8):  [('Output',0),('Output',1),('Input',0)],
    (31,9):  [('Output',0),('Output',1),('Input',0)],
    (31,10): [('Output',0),('Input',0),('Input',1)],
    (31,11): [('Output',0),('Output',1),('Input',0),('Input',1)],
    (31,12): [('Output',0),('Output',1)],
    (31,19): [('Output',0),('Output',1)],
    (31,20): [('Output',0),('Output',1)],
    (31,21): [('Output',0),('Output',1)],
    (31,22): [('Output',0),('Output',1),('Input',0)],
    (31,23): [('Output',0),('Output',1),('Input',0)],
    (31,24): [('Output',0),('Output',1),('Input',0)],
    (31,25): [('Output',0),('Output',1),('Input',0)],
    (31,26): [('Output',0),('Output',1),('Input',0)],
    (31,27): [('Output',0),('Output',1),('Input',0)],
    (31,28): [('Output',0),('Output',1)],
    (31,29): [('Output',0),('Output',1)],
    (31,30): [('Output',0),('Output',1)],
    (31,31): [('Output',0),('Output',1)],
}


# ── Constraint parsing ───────────────────────────────────────────────────────

def _normalise_assignment(raw: str) -> str:
    """Normalise assignment key: strip PIN_ prefix optionally, uppercase."""
    key = raw.strip().upper()
    # Accept bare numbers: "7" → "PIN_7"; "7_OE" → "PIN_7_OE"
    if re.match(r'^\d+(_OE|_IN)?$', key):
        key = 'PIN_' + key
    return key


def parse_pcf(path: Path) -> list[tuple[str, str]]:
    """
    Parse a PCF constraints file.
    Returns list of (signal_name, assignment_key) tuples.
    """
    assignments = []
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split('#')[0].strip()   # strip comments
        if not line:
            continue
        parts = line.split()
        if not parts:
            continue
        if parts[0].lower() != 'set_io':
            print(f'WARNING:{lineno}: unknown directive "{parts[0]}", skipping',
                  file=sys.stderr)
            continue
        if len(parts) < 3:
            sys.exit(f'ERROR:{lineno}: set_io needs at least 2 arguments')
        signal = parts[1]
        assignment = _normalise_assignment(parts[2])
        assignments.append((signal, assignment))
    return assignments


# ── Core generation ──────────────────────────────────────────────────────────

class IOMap:
    """Resolved signal→physical-port assignments."""

    def __init__(self):
        # clk_signals: list of (signal_name, clk_side, port_type, port_idx)
        self.clk_signals: list[tuple[str, str, str, int]] = []
        # iob_signals: (chip_x, chip_y, port_type, port_idx) → signal_name
        self.iob_signals: dict[tuple[int,int,str,int], str] = {}

    def add(self, signal: str, assignment: str):
        if assignment == 'CLK':
            self.clk_signals.append((signal, 'W', 'Input', 0))
        elif assignment in _ASSIGN_DB:
            cx, cy, ptype, pidx = _ASSIGN_DB[assignment]
            key = (cx, cy, ptype, pidx)
            if key in self.iob_signals:
                sys.exit(
                    f'ERROR: conflict — {assignment!r} already assigned to '
                    f'{self.iob_signals[key]!r}, cannot also assign {signal!r}')
            self.iob_signals[key] = signal
        else:
            sys.exit(f'ERROR: unknown assignment {assignment!r} for signal {signal!r}. '
                     f'Run with --list-pins to see valid assignments.')


def resolve(assignments: list[tuple[str, str]]) -> IOMap:
    iomap = IOMap()
    for signal, assignment in assignments:
        iomap.add(signal, assignment)
    return iomap


# ── io_spec_in.txt generation ────────────────────────────────────────────────

def gen_iospec_txt(iomap: IOMap) -> str:
    lines: list[str] = []

    # Clock entries (West side Input=0 for external clock)
    for signal, side, ptype, pidx in iomap.clk_signals:
        lines.append(f'EFLX_CLK chip_tile_x=0, chip_tile_y=0, clk_side={side}')
        if ptype == 'Input':
            lines.append(f'    Input={pidx}, pin={signal}')
        else:
            lines.append(f'   Output={pidx}, pin={signal}, output_delay=-1')

    # All IOBs in canonical order
    for cx, cy in _CANONICAL_IOBS:
        lines.append(f'EFLX_IOB chip_tile_x=0, chip_tile_y=0, chip_x={cx}, chip_y={cy}')
        # Sub-entries for assigned ports (in canonical port order)
        for ptype, pidx in _IOB_PORTS.get((cx, cy), []):
            key = (cx, cy, ptype, pidx)
            if key in iomap.iob_signals:
                sig = iomap.iob_signals[key]
                if ptype == 'Output':
                    lines.append(f'   Output={pidx}, pin={sig}, output_delay=-1')
                else:
                    lines.append(f'    Input={pidx}, pin={sig},  input_delay=-1')

    return '\n'.join(lines) + '\n'


# ── .ffpga io-spec-tool XML generation ──────────────────────────────────────

def _ffpga_record_id(entry_type: str, **kw) -> str:
    if entry_type == 'CLK':
        side = kw['side']
        ptype = kw['ptype']
        pidx  = kw['pidx']
        direction = 'in' if ptype == 'Input' else 'out'
        return f'CLK_t[0:0]_{side}_{direction}{pidx}'
    else:  # IOB
        cx, cy = kw['cx'], kw['cy']
        ptype  = kw['ptype']
        pidx   = kw['pidx']
        direction = 'in' if ptype == 'Input' else 'out'
        return f'IOB_t[0:0]_xy[{cx}:{cy}]_{direction}{pidx}'


def gen_ffpga_xml(iomap: IOMap, indent: str = '        ') -> str:
    """Return the <io-spec-tool> XML block."""
    records: list[str] = []

    rec_indent = indent + '        '   # 8 more spaces for each <record>
    for signal, side, ptype, pidx in iomap.clk_signals:
        rid = _ffpga_record_id('CLK', side=side, ptype=ptype, pidx=pidx)
        records.append(
            f'{rec_indent}<record id="{rid}">\n'
            f'{rec_indent}    <port-name>{signal}</port-name>\n'
            f'{rec_indent}</record>')

    for cx, cy in _CANONICAL_IOBS:
        for ptype, pidx in _IOB_PORTS.get((cx, cy), []):
            key = (cx, cy, ptype, pidx)
            if key in iomap.iob_signals:
                sig = iomap.iob_signals[key]
                rid = _ffpga_record_id('IOB', cx=cx, cy=cy, ptype=ptype, pidx=pidx)
                records.append(
                    f'{rec_indent}<record id="{rid}">\n'
                    f'{rec_indent}    <port-name>{sig}</port-name>\n'
                    f'{rec_indent}</record>')

    inner = '\n'.join(records)
    return (f'{indent}<io-spec-tool>\n'
            f'{indent}    <records filter="126" filter1="16">\n'
            f'{inner}\n'
            f'{indent}    </records>\n'
            f'{indent}</io-spec-tool>')


# ── .ffpga patching ──────────────────────────────────────────────────────────

def patch_ffpga(xml_content: str, iomap: IOMap) -> str:
    import re
    new_block = gen_ffpga_xml(iomap, indent='        ')
    patched = re.sub(
        r'[ \t]*<io-spec-tool>.*?</io-spec-tool>',
        new_block,
        xml_content,
        flags=re.DOTALL)
    if patched == xml_content:
        sys.exit('ERROR: could not find <io-spec-tool> section in .ffpga file')
    return patched


# ── CLI ──────────────────────────────────────────────────────────────────────

def list_pins():
    print('Valid assignments for set_io:')
    print()
    print('  CLK          — External clock input (West CLK side, Input 0)')
    print()
    print('  GPIO pins (package pin number):')
    gpio_pins = sorted(
        [(k, v) for k, v in _ASSIGN_DB.items()
         if k.startswith('PIN_') and not k.endswith('_OE') and not k.endswith('_IN')],
        key=lambda kv: int(kv[0].split('_')[1]))
    for k, (cx, cy, _, _) in gpio_pins:
        oe_k = k + '_OE'
        in_k = k + '_IN'
        have_oe = oe_k in _ASSIGN_DB
        have_in = in_k in _ASSIGN_DB
        suffixes = [k]
        if have_oe: suffixes.append(oe_k)
        if have_in: suffixes.append(in_k)
        print(f'  {", ".join(suffixes):<30}  coord=({cx},{cy})')
    print()
    print('  Named functions:')
    for k, (cx, cy, ptype, pidx) in sorted(_ASSIGN_DB.items()):
        if not k.startswith('PIN_'):
            print(f'  {k:<25}  coord=({cx},{cy}) {ptype}{pidx}')


def main():
    ap = argparse.ArgumentParser(
        description='Generate io_spec_in.txt and .ffpga XML from PCF constraints')
    ap.add_argument('--pcf',         type=Path,
                    help='Input PCF constraints file')
    ap.add_argument('--out-iospec',  type=Path,
                    help='Output io_spec_in.txt path')
    ap.add_argument('--out-xml',     type=Path,
                    help='Output io-spec-tool XML fragment path')
    ap.add_argument('--ffpga',       type=Path,
                    help='Existing .ffpga file to patch')
    ap.add_argument('--out-ffpga',   type=Path,
                    help='Patched .ffpga output path')
    ap.add_argument('--list-pins',   action='store_true',
                    help='Print the full pin/function lookup table and exit')
    args = ap.parse_args()

    if args.list_pins:
        list_pins()
        return

    if not args.pcf:
        ap.error('--pcf is required (unless using --list-pins)')

    assignments = parse_pcf(args.pcf)
    iomap = resolve(assignments)

    if args.out_iospec:
        args.out_iospec.parent.mkdir(parents=True, exist_ok=True)
        txt = gen_iospec_txt(iomap)
        args.out_iospec.write_text(txt)
        print(f'Written: {args.out_iospec}')

    if args.out_xml:
        args.out_xml.parent.mkdir(parents=True, exist_ok=True)
        xml = gen_ffpga_xml(iomap)
        args.out_xml.write_text(xml + '\n')
        print(f'Written: {args.out_xml}')

    if args.ffpga:
        src = args.ffpga if args.out_ffpga else None
        if not src:
            ap.error('--out-ffpga is required when --ffpga is given')
        patched = patch_ffpga(args.ffpga.read_text(), iomap)
        args.out_ffpga.parent.mkdir(parents=True, exist_ok=True)
        args.out_ffpga.write_text(patched)
        print(f'Written: {args.out_ffpga}')

    if not any([args.out_iospec, args.out_xml, args.ffpga]):
        # Default: print both to stdout for inspection
        print('=== io_spec_in.txt ===')
        print(gen_iospec_txt(iomap))
        print('=== io-spec-tool XML ===')
        print(gen_ffpga_xml(iomap))


if __name__ == '__main__':
    main()
