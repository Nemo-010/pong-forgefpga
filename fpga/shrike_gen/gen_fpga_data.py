#!/usr/bin/env python3
"""
gen_fpga_data.py — Generate the FPGA_DATA base64 blob for eda-placer.

The Go Configure GUI calls eda-placer as:
    eda-placer FPGA_DATA <blob> <token>

Where <blob> encodes the full argument list using:
    Outer: uint32_BE(uncompressed_size) + zlib(inner)
    Inner: uint32_BE(n_args)
           uint32_BE(len[0]) ... uint32_BE(len[n-1])
           arg[0]arg[1]...arg[n-1]   (raw UTF-8, no separators/nulls)

The <token> (third argument, e.g. "21428") is a GUI IPC port; for headless
builds we pass 0 — eda-placer ignores a failed callback connection.

Usage:
    python3 gen_fpga_data.py \\
        --netlist  <path/to/netlist.edif> \\
        --fp       <path/to/floorplanspec.fp> \\
        --io       <path/to/io_spec_in.txt> \\
        [--max-cpu N]                          (default: nproc)
        [--token   N]                          (default: 0)

Prints the blob on stdout (no newline) — capture with $() in Makefile.
"""

import argparse, base64, os, struct, sys, zlib

# ── PNR flag defaults (captured from GUI strace) ─────────────────────────────
PNR_FLAGS = [
    ('-ENABLE_BITSTREAM_OUTPUT_AXI',     '1'),
    ('-ENABLE_BITSTREAM_OUTPUT_AXI_CRC', '0'),
    ('-ENABLE_HIGH_DENSITY_PACKING',     '1'),
    ('-ENABLE_HIGH_DENSITY_IO_PACKING',  '0'),
    ('-CLK_CONCURRENT_OPT',              '1'),
    ('-PLACE_AND_TRIAL_ROUTE',           os.environ.get('TRIAL_ROUTE', '0')),
    ('-PNR_TRIAL_ITER_TOTAL',            '20'),
    ('-MAX_ROUTE_ITER',                  '300'),
    ('-MAX_CPU',                         None),   # filled from --max-cpu
    # 0..5 selects one of the vendor delay libraries under eda-placer's
    # sdf_dly/T40ULP directory (tt / ss / ff x hot / cold).  Overridable so
    # the spread can be reported instead of one corner.
    ('-TIMING_ANALYSIS_CORNER',          os.environ.get('TIMING_CORNER', '0')),
]

# Print the critical path of every timing endpoint (default: top 1% only).
_CP = os.environ.get('TIMING_PRINT_CRITICAL_PATH')
if _CP:
    PNR_FLAGS.append(('-TIMING_PRINT_CRITICAL_PATH', _CP))

# Optional user SDC file (set_false_path / set_multicycle_path exceptions).
_SDC = os.environ.get('SDC_FILE')
if _SDC:
    PNR_FLAGS.append(('-sdc', os.path.abspath(_SDC)))

PNR_FLAGS += [
]


def encode_fpga_data(args: list[str]) -> str:
    encoded = [a.encode('utf-8') for a in args]
    inner   = struct.pack('>I', len(encoded))
    inner  += b''.join(struct.pack('>I', len(e)) for e in encoded)
    inner  += b''.join(encoded)
    outer   = struct.pack('>I', len(inner)) + zlib.compress(inner)
    return base64.b64encode(outer).decode('ascii')


def main():
    ap = argparse.ArgumentParser(description='Generate FPGA_DATA blob for eda-placer')
    ap.add_argument('--netlist',  required=True, help='Absolute path to netlist.edif')
    ap.add_argument('--fp',       required=True, help='Absolute path to floorplanspec.fp')
    ap.add_argument('--io',       required=True, help='Absolute path to io_spec_in.txt')
    ap.add_argument('--max-cpu',  type=int, default=os.cpu_count() or 1,
                    help='MAX_CPU value (default: nproc)')
    ap.add_argument('--token',    default='0',
                    help='GUI IPC token, 3rd argv to eda-placer (default: 0)')
    ap.add_argument('--print-cmd', action='store_true',
                    help='Print the full eda-placer command instead of just the blob')
    args = ap.parse_args()

    # Build arg list (order must match GUI exactly)
    pnr_args = []
    for flag, val in PNR_FLAGS:
        pnr_args.append(flag)
        pnr_args.append(str(args.max_cpu) if val is None else val)

    eda_args = [
        '-edif', os.path.abspath(args.netlist),
        '-fp',   os.path.abspath(args.fp),
        *pnr_args,
        '-io',   os.path.abspath(args.io),
    ]

    blob = encode_fpga_data(eda_args)

    if args.print_cmd:
        import shlex
        eda_bin = '/opt/go-configure-sw-hub/bin/external/eda-placer/v23/eda-placer'
        print(f'{eda_bin} FPGA_DATA {shlex.quote(blob)} {args.token}')
    else:
        sys.stdout.write(blob)   # no newline — safe for $() capture


if __name__ == '__main__':
    main()