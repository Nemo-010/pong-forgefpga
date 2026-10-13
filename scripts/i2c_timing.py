#!/usr/bin/env python3
"""I2C (and panel bandwidth) timing budget for the Pong design.

The RTL sets the SCL period by counting clocks, so the period in
nanoseconds is a function of the ForgeFPGA internal oscillator, which is
not exactly 50 MHz and is not trimmed: the SLG47910 datasheet Rev 1.05
sec. 3.3.4 gives 43.495 MHz to 54.110 MHz over -40..+85 C at 1.71-1.89 V
(and 45.158-52.513 MHz at 2.5 V / 25 C).  Every I2C spec number the panel
cares about therefore has to be checked over that whole range, not at one
nominal frequency.

Sources
-------
* NXP UM10204 "I2C-bus specification and user manual", rev. 6 (4 April
  2014), Table 10 "Characteristics of the SDA and SCL bus lines for
  Standard-, Fast- and Fast-mode Plus I2C-bus devices":
    Standard mode (Sm):  max 100 kbit/s, tLOW >= 4.7 us, tHIGH >= 4.0 us
    Fast mode (Fm):      max 400 kbit/s, tLOW >= 1.3 us, tHIGH >= 0.6 us
    tHD;STA >= 0.6 us, tSU;STO >= 0.6 us (Fm)
* Solomon Systech SSD1306 datasheet rev 1.1, Table 13-6 "AC
  Characteristics" for the I2C interface:
    tcycle >= 2.5 us, tHIGH >= 0.6 us, tLOW >= 1.3 us,
    tHD;STA >= 0.6 us, tSU;STO >= 0.6 us
  and Table 13-7 (SPI) / sec. 8.1.5.2 for the pull-up requirement.
* Pull-ups: a 400 kHz open-drain bus needs tR <= 300 ns (UM10204 Table 10
  Fm).  With the bus capacitance of a short ribbon and the modules' usual
  4.7 kOhm pull-ups, tR = R*C gives a few tens of ns; the modules' own
  pull-ups are what the design relies on.  See docs/PINMAP.md.

The design drives SCL low for T_LOW_CYC clocks and high for T_HIGH_CYC
clocks, plus the START/STOP setup holds.  The numbers below are the
defaults in src/i2c_master.v.  Change one and re-run: --check fails if any
minimum is violated at either end of the oscillator range.
"""

import argparse
import sys

# src/i2c_master.v defaults (clock counts)
T_LOW_CYC    = 71
T_HIGH_CYC   = 77
T_BUF_CYC    = 71
T_STA_CYC    = 35
T_STO_CYC    = 35
WATCHDOG_BIT = 11

# SLG47910 Rev 1.05 sec. 3.3.4, internal oscillator
F_MIN_HZ = 43.495e6
F_MAX_HZ = 54.110e6

# limits in nanoseconds
FM_TLOW_MIN   = 1300.0
FM_THIGH_MIN  = 600.0
FM_TCYCLE_MIN = 2500.0     # SSD1306 Table 13-6
FM_THDSTA_MIN = 600.0      # UM10204 Table 10
FM_TSUSTO_MIN = 600.0
SM_TLOW_MIN   = 4700.0
SM_THIGH_MIN  = 4000.0

# the design's own frame format
PANEL_W, PANEL_H = 128, 64
PAGES = PANEL_H // 8
COL_CMDS = 5               # addressing-mode setup, per frame
FRAME_BYTES = COL_CMDS + PANEL_W * PAGES


def ns(cycles, f_hz):
    return cycles * 1e9 / f_hz


def report(f_hz):
    tlow = ns(T_LOW_CYC, f_hz)
    thigh = ns(T_HIGH_CYC, f_hz)
    tcycle = tlow + thigh
    tsta = ns(T_STA_CYC + T_LOW_CYC, f_hz)   # SDA falls while SCL high, then SCL low
    tsto = ns(T_STO_CYC + T_HIGH_CYC, f_hz)
    f_scl = 1e9 / tcycle
    return dict(f=f_hz, tlow=tlow, thigh=thigh, tcycle=tcycle, tsta=tsta,
                tsto=tsto, f_scl=f_scl,
                tframe=FRAME_BYTES * 9 * tcycle * 1e-9,
                fps=1e9 / (FRAME_BYTES * 9 * tcycle))


def check():
    ok = True
    rows = []
    for f in (F_MIN_HZ, 50.0e6, F_MAX_HZ):
        r = report(f)
        rows.append(r)
        print(f"  {r['f']/1e6:6.3f} MHz OSC -> SCL {r['f_scl']/1e3:7.1f} kHz, "
              f"tLOW {r['tlow']:7.1f} ns, tHIGH {r['thigh']:7.1f} ns, "
              f"tcycle {r['tcycle']:7.1f} ns, "
              f"frame {r['tframe']*1e3:5.1f} ms ({r['fps']:4.1f} fps)")

    # the constraint that matters: at the *fastest* oscillator every
    # minimum is at its shortest, at the slowest one every mode is still
    # Fast-mode (the bus must not fall back below 400 kHz limits by
    # accident, but slower is legal: the panel accepts any clock up to
    # 400 kHz, so the only hard limits are the minima).
    worst = report(F_MAX_HZ)
    checks = [
        ("tLOW  >= 1300 ns (UM10204 Fm, SSD1306 tab. 13-6)",
         worst["tlow"], FM_TLOW_MIN),
        ("tHIGH >=  600 ns (UM10204 Fm, SSD1306 tab. 13-6)",
         worst["thigh"], FM_THIGH_MIN),
        ("tcycle >= 2500 ns (SSD1306 tab. 13-6)",
         worst["tcycle"], FM_TCYCLE_MIN),
        ("tHD;STA >= 600 ns (UM10204 Fm tab. 10)", worst["tsta"], FM_THDSTA_MIN),
        ("tSU;STO >= 600 ns (UM10204 Fm tab. 10)", worst["tsto"], FM_TSUSTO_MIN),
    ]
    for name, got, lim in checks:
        ok &= got >= lim
        print(f"  {'ok ' if got >= lim else 'FAIL'} {name}: {got:.1f} ns (worst case)")

    slow = report(F_MIN_HZ)
    # at the slowest oscillator the bus must still be a valid fast-mode bus
    # (>= 400 kHz would be a violation, being slower is not)
    if slow["tlow"] < SM_TLOW_MIN and slow["thigh"] < SM_THIGH_MIN:
        print(f"  note: at {F_MIN_HZ/1e6:.3f} MHz the bus is still Fast-mode "
              f"compatible ({slow['f_scl']/1e3:.1f} kHz <= 400 kHz)")
    # watchdog must outlast one byte at the slowest clock
    byte_cyc = 9 * (T_LOW_CYC + T_HIGH_CYC)
    wd = 1 << WATCHDOG_BIT
    print(f"  {'ok ' if wd > byte_cyc else 'FAIL'} watchdog {wd} clocks > one "
          f"byte {byte_cyc} clocks")
    ok &= wd > byte_cyc
    print("i2c_timing: " + ("ALL CHECKS PASSED" if ok else "FAILED"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--trace", metavar="FILE", help="write a per-frame table")
    args = ap.parse_args()
    if args.check:
        return check()
    r = report(50.0e6)
    print(f"SCL {r['f_scl']/1e3:.1f} kHz, frame {r['tframe']*1e3:.2f} ms, "
          f"{r['fps']:.1f} fps ({FRAME_BYTES} bytes/frame)")
    if args.trace:
        with open(args.trace, "w") as fh:
            fh.write("osc_mhz scl_khz tlow_ns thigh_ns tcycle_ns frame_ms fps\n")
            for f in (F_MIN_HZ, 50.0e6, F_MAX_HZ):
                x = report(f)
                fh.write(f"{x['f']/1e6:.3f} {x['f_scl']/1e3:.1f} {x['tlow']:.1f} "
                         f"{x['thigh']:.1f} {x['tcycle']:.1f} {x['tframe']*1e3:.2f} "
                         f"{x['fps']:.1f}\n")
        print(f"wrote {args.trace}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
