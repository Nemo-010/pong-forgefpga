# shrike-gen

#### CLI Makefile based project scaffolding, build and flashing for **Renesas SLG47910V** (ForgeFPGA) and the [Vicharak](https://x.com/Vicharak_In) [Shrike Lite](https://store.vicharak.in/?product=shrike&post_type=product&name=shrike&v=55add3d845bf) board.

Write Verilog or VHDL, edit pin constraints, type `make` and get bitstreams. No GUI required.

`shrike-gen` replaces the Go Configure Software Hub GUI with a fully scriptable, terminal-driven workflow. The generated `.ffpga` files and all three bitstream formats (`MCU`, `OTP`, `FLASH_MEM`) are byte-compatible with the GUI. You can still open a project in the GUI, but you don't have to.

**Status:** Alpha - Simple projects supported 
**License:** MIT

---

## What's New

**Experimental VHDL support:** VHDL projects are now supported via [OSS-CAD-Suite](https://github.com/YosysHQ/oss-cad-suite-build) (GHDL + Yosys). Create a VHDL project with `make vhdlproject ProjectName`. The VHDL flow uses `ghdl -a` for linting and `yosys -m ghdl` for synthesis; everything else (PnR, bitstream generation, flash) is identical to the Verilog flow. See [VHDL projects](#vhdl-projects) for setup and troubleshooting.

**Flashing:** `make flash` copies a bitstream onto the RP2040/RP2350 and calls `shrike.flash()`. Supports per-project, cross-project, and arbitrary file targets. `mpremote` is auto-installed the first time after `make init` or `make flash`. Credit: @dpks2003

**Multi-module support:** All `.v` files in `ffpga/src/` are picked up automatically. Add new source files and run `make update`; the `.ffpga` and `read_verilog` list both stay in sync with no manual edits.

**Explicit top module:** `make top` passes `-top $(TOP)` (from `shrike.mk`) to Yosys. `make top <ModuleName>` overrides with any name. Useful when auto-detection doesnt work when no module is annotated with (* top *). Fix suggested by: @multigcs

**Verilator optional:** The bundled `verilator_bin` requires `GLIBC_2.38` and will not run on Debian 12 or older distributions. Lint can now be skipped by passing `VERILATOR=` on the command line, or a working verilator path can be specified. Width related lint warnings (`WIDTHEXPAND`/`WIDTHTRUNC`) are suppressed by default for less noisy builds. Contributed by: @multigcs

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Repository layout](#repository-layout)
- [Quick start](#quick-start)
- [Writing your design](#writing-your-design)
- [VHDL projects](#vhdl-projects)
- [Build targets](#build-targets)
- [Flashing](#flashing)
- [Python scripts reference](#python-scripts-reference)
- [Advanced options](#advanced-options)
- [How it works](#how-it-works)
- [Notable Projects, Usage, Forks or Alternatives](#notable-projects-usage-forks-or-alternatives)
- [Contributors](#contributors)
- [Credits](#credits)
- [TODO](#todo)

---

## Prerequisites

| Tool | Purpose | Where it comes from |
|---|---|---|
| **Go Configure Software Hub** | Provides `yosys`, `verilator`, `eda-placer` | Install from Renesas |
| **Python 3.8+** | Runs all generator scripts | `python3` on `$PATH` |
| **GNU Make** | Drives the build | `make` on `$PATH` |
| **bash** | Shell | `bash` on `$PATH` |

All three binary tools (`yosys v59`, `verilator`, `eda-placer v23`) ship inside the Go Configure Software Hub installation at `/opt/go-configure-sw-hub/bin/external/`. No separate tool installation is needed.

> **Verilator compatibility note:** The bundled `verilator_bin` requires `GLIBC_2.38` and will not run on Debian 12 or other distributions that ship an older glibc. If you hit a `version 'GLIBC_2.38' not found` error, see [Skipping or replacing Verilator](#skipping-or-replacing-verilator) below.

### Additional prerequisite for VHDL projects

| Tool | Purpose | Where it comes from |
|---|---|---|
| **OSS-CAD-Suite** | Provides `ghdl`, `yosys` with GHDL plugin | Install from [YosysHQ/oss-cad-suite-build](https://github.com/YosysHQ/oss-cad-suite-build) |

OSS-CAD-Suite must be installed at `/opt/oss-cad-suite/`. VHDL projects do not require Go Configure Software Hub's yosys or verilator, only `eda-placer` is still used for place & route.

---

## Repository layout

```
Makefile                    <- role-aware: workspace and project targets in one file
shrike_gen/
    shrike-gen.py           <- project scaffolding CLI
    gen_ffpga.py            <- .ffpga XML generator (GP6 v6.53 compatible)
    gen_io_spec.py          <- PCF to io_spec_in.txt + .ffpga IO-spec XML
    gen_fpga_data.py        <- FPGA_DATA base64 blob encoder for eda-placer
    gen_bitstreams.py       <- AXI log to MCU / OTP / FLASH_MEM .bin files
    templates/
        io_map.pcf          <- default pin constraint template
        main.v              <- default top-level Verilog template
        main.vhd            <- default top-level VHDL template
```

---

## Quick start

### 1. Clone the repo

```bash
git clone https://github.com/trholding/shrike-gen.git
cd shrike-gen
```

### 2. (Optional) create the `./shrike-gen` symlink and install mpremote for flashing

```bash
make init
```

This lets you run `./shrike-gen ProjectName` directly. Without it, `make project` is the only entry point you need.

### 3. Create a project

**Verilog project:**

```bash
# These are equivalent:
make project Blink
make project NAME=Blink

# Or, if you ran make init:
./shrike-gen Blink
```

**VHDL project:**

```bash
make vhdlproject Blink
make vhdlproject NAME=Blink

# Or, if you ran make init:
./shrike-gen --type vhdl Blink
```

The project directory is created in the current workspace:

```
Blink/
├── Makefile              <- copied from workspace root; handles project builds
├── shrike.mk             <- PROJECT=Blink  TOP=Blink  PROJECT_TYPE=verilog|vhdl (included by Makefile)
├── Blink.ffpga           <- GUI-compatible project file (regenerated by make update)
├── io_map.pcf            <- pin constraints (edit this)
└── ffpga/
    ├── src/
    │   └── main.v        <- top-level Verilog (edit this) or main.vhd for VHDL
    └── build/
        ├── floorplanspec.fp    <- fixed device descriptor (do not edit)
        └── io_spec_in.txt      <- generated from io_map.pcf (do not edit)
```

> `shrike.mk` stores three identifiers: `PROJECT` (directory / file name), `TOP` (top-level module or entity name), and `PROJECT_TYPE` (`verilog` or `vhdl`). `PROJECT` and `TOP` are the same by default but can differ; see [Advanced options](#advanced-options).

### 4. Build

```bash
cd Blink
make
```

Bitstreams land in `ffpga/build/bitstream/`:

```
FPGA_bitstream_MCU.bin
FPGA_bitstream_OTP.bin
FPGA_bitstream_FLASH_MEM.bin
```

---

## Writing your design

### Verilog sources: `ffpga/src/`

All `.v` files in `ffpga/src/` are picked up automatically. Add as many source files as you need; `make update` keeps the `.ffpga` project file in sync and `make` passes all of them to Yosys:

```
ffpga/src/main.v
ffpga/src/uart.v       <- picked up automatically
ffpga/src/counter.v    <- picked up automatically
```

### Pin constraints: `io_map.pcf`

The constraint file uses nextpnr-style `set_io` syntax:

```
set_io <signal_name>  <assignment>   # optional comment
```

| Assignment | Meaning |
|---|---|
| `CLK` | External clock input |
| `PIN_N` | GPIO output value on package pin N |
| `PIN_N_OE` | GPIO output enable on package pin N |
| `PIN_N_IN` | GPIO input value from package pin N |
| `OSC_EN` | Oscillator enable |
| `PLL_EN`, `PLL_LOCK`, `PLL_CLK`, … | PLL controls (see full list below) |

Note: The mapping and naming conventions are subject to change.

**Example:**

```
set_io clk     CLK         # external clock input
set_io LED     PIN_7       # GPIO output value, pin 7
set_io LED_en  PIN_7_OE    # GPIO output enable, pin 7 (drive HIGH to enable)
set_io clk_en  OSC_EN      # oscillator enable
```

Available GPIO ranges: `PIN_1` to `PIN_9` (east edge), `PIN_13` to `PIN_20` (west edge), `PIN_23` to `PIN_24` (east edge).

For the complete pin reference:

```bash
python3 shrike_gen/gen_io_spec.py --list-pins
```

---

## VHDL projects

VHDL support is **experimental** and uses [OSS-CAD-Suite](https://github.com/YosysHQ/oss-cad-suite-build) (GHDL + Yosys with the GHDL plugin) in place of the Go Configure Software Hub's Yosys and Verilator.

### Setup

Install OSS-CAD-Suite to `/opt/oss-cad-suite/`. Then create a VHDL project:

```bash
make vhdlproject MyDesign
cd MyDesign
```

Edit `ffpga/src/main.vhd` and `io_map.pcf`, then:

```bash
make
```

All `.vhd` files in `ffpga/src/` are picked up automatically, same as `.v` files in Verilog projects.

### VHDL synthesis attributes

ForgeFPGA requires synthesis attributes on port signals. In VHDL these are declared inside the entity using `attribute` syntax (equivalent to Verilog's `(* iopad_external_pin *)`):

```vhdl
entity MyDesign is
  port (
    clk    : in  std_logic;
    LED    : out std_logic;
    LED_en : out std_logic;
    clk_en : out std_logic
  );

  attribute clkbuf_inhibit     : string;
  attribute iopad_external_pin : string;
  attribute clkbuf_inhibit     of clk    : signal is "true";
  attribute iopad_external_pin of clk    : signal is "true";
  attribute iopad_external_pin of LED    : signal is "true";
  attribute iopad_external_pin of LED_en : signal is "true";
  attribute iopad_external_pin of clk_en : signal is "true";
end entity MyDesign;
```

The generated `main.vhd` template already has this set up correctly for the standard Shrike Lite signals.
>Note: Please correct me, if my assumptions are wrong...

### Troubleshooting: `libghdl` not found

If synthesis fails with:

```
ERROR: Can't load module `./ghdl': libghdl-6_0_0_dev.so: cannot open shared object file: No such file or directory
```

The GHDL yosys plugin was compiled against a library name that differs from what OSS-CAD-Suite ships. Fix it with a symlink:

```bash
sudo ln -sf /opt/oss-cad-suite/lib/libghdl-6_0_0.so \
            /opt/oss-cad-suite/lib/libghdl-6_0_0_dev.so
```

This is a one-time fix; the symlink persists across builds.

---

## Build targets

### Workspace targets (run from the repo root)

| Target | Description |
|---|---|
| `make init` | Create `./shrike-gen` symlink (optional convenience) |
| `make project NAME=X` | Create a new Verilog project skeleton named X |
| `make project X` | Same (positional form) |
| `make vhdlproject NAME=X` | Create a new VHDL project skeleton named X |
| `make vhdlproject X` | Same (positional form) |
| `make list` | List existing projects in this workspace |
| `make mpremote-install` | Install `mpremote` flash tool into `~/.local` |
| `make help` | Show workspace help |

### Project targets (run from inside a project directory)

| Target | Description |
|---|---|
| `make` | `update` then full build |
| `make top` | Same, with `-top $(TOP)` passed to Yosys / GHDL (uses `TOP` from `shrike.mk`) |
| `make top <ModuleName>` | Same, with `-top <ModuleName>` passed to Yosys / entity name to GHDL |
| `make update` | Regenerate `.ffpga` and `io_spec_in.txt`; re-scan `src/` for new/renamed files |
| `make build` | `lint` -> `synth` -> `pnr` -> `collect` (skip update) |
| `make lint` | Verilator lint (Verilog) or `ghdl -a` analysis (VHDL) |
| `make synth` | Yosys synthesis (Verilog) or GHDL+Yosys synthesis (VHDL) |
| `make flash` | Copy bitstream to MCU and call `shrike.flash()` |
| `make clean` | Remove all build outputs; keeps source and constraints |
| `make help` | Show project help with detected sources, type, and current settings |

#### When to use `make top`

By default Yosys auto-detects the top module if a module is annotated with `(* top *)`. For VHDL, the top entity is always specified explicitly via `make top`. If synthesis fails or produces unexpected results, be explicit:

```bash
make top                  # uses TOP from shrike.mk (set at project creation)
make top blink_top        # override with any module/entity name for this build
```

The three modes map directly to the Yosys `synth_xilinx` flag (Verilog) or GHDL `-e` elaboration argument (VHDL):

| Command | Verilog (Yosys flag) | VHDL (GHDL flag) |
|---|---|---|
| `make` | *(none, auto-detect)* | `-e $(TOP)` |
| `make top` | `-top $(TOP)` | `-e $(TOP)` |
| `make top MyEntity` | `-top MyEntity` | `-e MyEntity` |

---

## Flashing

`make flash` copies a bitstream onto the RP2040/RP2350 MCU and calls `shrike.flash()` to program the FPGA. The **Shrike MicroPython UF2 must already be on the MCU** before flashing.

```bash
make flash                           # current project, MCU bitstream
make flash FROM=Blink2               # flash a sibling project's bitstream
make flash VARIANT=FLASH_MEM         # choose a bitstream variant (MCU/OTP/FLASH_MEM)
make flash PORT=/dev/ttyACM0         # target a specific board when several are attached
make flash BITSTREAM=/path/to/x.bin  # flash an arbitrary file
```

Resolution order: `BITSTREAM=` wins over `FROM=` wins over the current project.

> **⚠️ OTP is irreversible.** `make flash VARIANT=OTP` refuses to run unless you also pass `I_KNOW_OTP_IS_FOREVER=1`. Test on an MCU or FLASH_MEM target first and verify your output against GUI-generated bitstreams before committing to OTP.

### `mpremote` installation

`make flash` auto-installs `mpremote` on first use if it isn't already on your system. To provision it explicitly:

```bash
make mpremote-install
```

Or from workspace 

```
make init
```

| Variable | Effect |
|---|---|
| `MPREMOTE=/path/to/mpremote` | Use a specific binary (e.g. from a venv) |
| `PYTHON=/path/to/python3` | Use a specific interpreter for install |
| `AUTO_INSTALL=0` | Never auto-install; error and point at `make mpremote-install` instead |

On PEP 668 systems (Ubuntu 24.04, Debian 12+) the install uses `--break-system-packages --user`, which writes only to `~/.local` and leaves system packages untouched. `python3-pip` must be present; install it once with your package manager if missing.

---

## Python scripts reference

These scripts are invoked by the Makefile but can also be run directly. All live in `shrike_gen/`.

---

### `shrike-gen.py`: Project scaffolding

Creates a complete, ready-to-build project directory from scratch.

```bash
python3 shrike_gen/shrike-gen.py <ProjectName> [options]
./shrike-gen <ProjectName> [options]     # after: make init
```

| Option | Default | Description |
|---|---|---|
| `--top NAME` | same as ProjectName | Top-level module or entity name (written to `shrike.mk` as `TOP`) |
| `--type TYPE` | `verilog` | HDL type: `verilog` or `vhdl` |
| `--dir PATH` | current directory | Parent directory for the new project |
| `--force` | *(none)* | Overwrite an existing project directory |

---

### `gen_ffpga.py`: `.ffpga` project file generator

Produces a GUI-compatible `.ffpga` XML file for the SLG47910V. Called automatically by `make update`.

```bash
python3 shrike_gen/gen_ffpga.py \
    --project  MyProject \
    --sources  main.v uart.v counter.v \
    --pcf      io_map.pcf \
    --out      MyProject.ffpga
```

| Option | Default | Description |
|---|---|---|
| `--project NAME` | `"project"` | Project name used in XML metadata |
| `--sources FILE…` | *(none)* | Source filenames stored in `<modules><scr>` (`.v` or `.vhd`) |
| `--pcf FILE` | *(none)* | PCF file; populates `<io-spec-tool>` for the GUI IO Planner |
| `--out FILE` | `<project>.ffpga` | Output path |
| `--max-cpu N` | `nproc` | `MAX_CPU` for the PnR step |
| `--date ISO` | today | Override the generation date |

The `.ffpga` XML has four key sections: `<chip>` (device identity and constants), `<nvmData>` (OTP preamble bytes), `<fpga-data>` (PnR settings and source file list), and `<io-spec-tool>` (IO port assignments for the GUI IO Planner).

---

### `gen_io_spec.py`: PCF to IO spec converter

Parses the `.pcf` constraints file and produces the two IO spec outputs consumed downstream. Called automatically by `make update`.

```bash
python3 shrike_gen/gen_io_spec.py \
    --pcf        io_map.pcf \
    --out-iospec ffpga/build/io_spec_in.txt \
    --out-xml    io_spec_tool.xml
```

| Option | Description |
|---|---|
| `--pcf FILE` | Input PCF constraints file |
| `--out-iospec FILE` | Output `io_spec_in.txt` consumed by `eda-placer` |
| `--out-xml FILE` | Output `<io-spec-tool>` XML fragment (paste into an existing `.ffpga`) |
| `--ffpga FILE` | Read an existing `.ffpga` and replace its `<io-spec-tool>` section inline |
| `--out-ffpga FILE` | Write the updated `.ffpga` (used together with `--ffpga`) |
| `--list-pins` | Print the full pin database for the SLG47910V and exit |

---

### `gen_fpga_data.py`: `FPGA_DATA` blob encoder

Constructs the base64-encoded argument blob passed to `eda-placer`. Called automatically by the PnR step; you normally won't need to run this directly.

```bash
python3 shrike_gen/gen_fpga_data.py \
    --netlist  ffpga/build/netlist.edif \
    --fp       ffpga/build/floorplanspec.fp \
    --io       ffpga/build/io_spec_in.txt \
    --max-cpu  4
```

| Option | Default | Description |
|---|---|---|
| `--netlist FILE` | required | Path to `netlist.edif` (output of Yosys) |
| `--fp FILE` | required | Path to `floorplanspec.fp` |
| `--io FILE` | required | Path to `io_spec_in.txt` |
| `--max-cpu N` | `nproc` | Passed as `-MAX_CPU` to `eda-placer` |
| `--token N` | `0` | GUI IPC port (headless builds always use `0`) |
| `--print-cmd` | *(none)* | Print the full `eda-placer` invocation instead of just the blob |

Prints the blob to stdout.

---

### `gen_bitstreams.py`: Bitstream generator

Reads the AXI log output from `eda-placer` and produces all three bitstream variants. Called automatically by `make collect`; you normally won't need to run this directly.

```bash
python3 shrike_gen/gen_bitstreams.py \
    --axi     ffpga/build/EFLX_bitstream_AXI.log \
    --outdir  ffpga/build/bitstream/ \
    --project MyProject \
    --netlist ffpga/build/netlist.edif
```

| Option | Default | Description |
|---|---|---|
| `--axi FILE` | required | `EFLX_bitstream_AXI.log` produced by `eda-placer` |
| `--outdir DIR` | required | Output directory for bitstream files |
| `--project NAME` | *(none)* | Used in output filenames and embedded metadata headers |
| `--netlist FILE` | *(none)* | Embedded as a metadata reference in bitstream headers |

Produces `.bin` and `.txt` files for `MCU`, `OTP`, and `FLASH_MEM` variants. All formats verified byte-perfect against GUI-generated output.

---

## Advanced options

### Skipping or replacing Verilator

By default the Makefile uses the `verilator_bin` bundled with Go Configure Software Hub. That binary requires `GLIBC_2.38`, which is not available on Debian 12 or distributions shipping an older glibc. If you hit:

```
verilator_bin: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
```

**Skip lint entirely** by passing an empty `VERILATOR` on the command line:

```bash
make VERILATOR=
```

This works for any make target `make build VERILATOR=`, `make synth VERILATOR=`, etc. Lint is skipped and the rest of the build (Yosys synthesis, PnR) runs normally.

**Use a different Verilator** by pointing at any compatible binary:

```bash
make lint VERILATOR=/usr/bin/verilator_bin
make build VERILATOR=/usr/bin/verilator_bin
```

A system installed Verilator should work fine as a drop-in replacement.

> Note: `make lint` on its own always requires a working Verilator. Only the full build pipeline (`make`, `make build`, `make synth`) can skip lint via `VERILATOR=`.

---

### Lint warning suppressions

The linter now runs with `-Wno-WIDTHEXPAND` and `-Wno-WIDTHTRUNC`, which suppresses warnings about implicit bit-width changes in assignments. These are silenced because the many common Verilog coding patterns can trigger them frequently without indicating real bugs.

---

### Custom top-level module name

```bash
make project Blink --top blink_top
# or
python3 shrike_gen/shrike-gen.py Blink --top blink_top
```

`shrike.mk` will contain `PROJECT=Blink` and `TOP=blink_top`. Use `make top` to pass the correct `-top` flag to Yosys at synthesis time.

### Custom parent directory

```bash
python3 shrike_gen/shrike-gen.py Blink --dir ~/fpga/projects
```

### Overwrite an existing project

```bash
make project Blink --force
# or
python3 shrike_gen/shrike-gen.py Blink --force
```

### Opening the project in the GUI

The generated `.ffpga` is a valid Go Configure Software Hub project file. Open it normally, then open `main.v` from within the GUI. The IO Planner will reflect your `io_map.pcf` assignments. Both workflows remain available: GUI for visual inspection, `make` for fast iteration.

---

## How it works

The full build pipeline:

```
io_map.pcf
    |
    v
gen_io_spec.py ──────────────────────────> io_spec_in.txt
    |                                           |
    v                                           |
gen_ffpga.py --> ProjectName.ffpga              |
                                                |
ffpga/src/*.v  (Verilog)                        |
ffpga/src/*.vhd (VHDL)                          |
    |                                           |
    v                                           |
Verilator lint  (Verilog)                       |
ghdl -a         (VHDL)                          |
    |                                           |
    v                                           |
Yosys synth_xilinx        (Verilog)             |
Yosys -m ghdl synth_xilinx (VHDL)  --> netlist.edif
                              |                 |
                              v                 v
                         gen_fpga_data.py --> FPGA_DATA blob
                                                |
                                                v
                                           eda-placer --> EFLX_bitstream_AXI.log
                                                                |
                                                                v
                                                         gen_bitstreams.py
                                                                |
                                               +----------------+----------------+
                                               v                v                v
                                     MCU.bin          OTP.bin          FLASH_MEM.bin
```

Each generator implements part of the Go Configure Software Hub's internal format:

- **`gen_ffpga.py`** produces the `.ffpga` XML schema (GPDProject v6.53) with correct device constants for the SLG47910V Rev BB (family `04`, type `06`, QFN-24 package, CRC32 `0x451C1D42`).
- **`gen_io_spec.py`** maps PCF signal names to the chip's internal `(chip_x, chip_y, port_type, port_idx)` coordinates and outputs the `io_spec_in.txt` format `eda-placer` expects.
- **`gen_fpga_data.py`** encodes the PnR argument list as `uint32_BE(uncompressed_size) + zlib(inner)` then base64-encodes the result, matching the exact argument blob format expected by `eda-placer`.
- **`gen_bitstreams.py`** reads 1024x11 hex words from the AXI log, byte-swaps each word, and prepends the correct device-specific header for each of the three output formats.

---

## Notable Projects, Usage, Forks or Alternatives

#### Notable Projects
- **[shrike](https://github.com/vicharak-in/shrike)**: Low cost microcontroller + FPGA board for makers , hobbyist and student for endless possibility, by [@vicharak-in](https://github.com/vicharak-in)

- **[LogicCard-VHDL](https://github.com/annoyedmilk/LogicCard-VHDL)**: VHDL examples for ForgeFPGA / LogicCard, by [@annoyedmilk](https://github.com/annoyedmilk)

#### Notable Alternatives

- **[shrike-starter](https://github.com/visejak/shrike-starter)**: Get a design running on the Vicharak Shrike Lite board super quickly and without the vendor GUI by [@visejak](https://github.com/visejak)

> Special thanks to [@visejak](https://github.com/visejak) for [shrike-starter](https://github.com/visejak/shrike-starter) ([announcement](https://x.com/visejak/status/2063979878161027450?s=20)), he is a great guy! Please follow him on X, also here, and watch out for his work on **supporting SLG47910V in nextpnr**! 

#### Notable Usage
- **[riocore](https://github.com/multigcs/riocore)**: Realtime-IO for motion control, by [@multigcs](https://github.com/multigcs)

---

## Contributors

| | |
|---|---|
| [@trholding](https://github.com/trholding) | Vulcan Ignis, original author |
| [@dpks2003](https://github.com/dpks2003) | Deepak Sharda, flash support and default shell bug fixes |
| [@multigcs](https://github.com/multigcs) | Oliver Dippel, set top module fix, skip lint + lint warning suppressions |

**Thanks to [Vicharak](https://x.com/Vicharak_In)** for making FPGAs accessible, and for the board. Check out [Vicharak.in](https://vicharak.in)!

---

## Credits

| | |
|---|---|
| [@annoyedmilk](https://github.com/annoyedmilk) | Marco, VHDL synthesis approach from [LogicCard-VHDL](https://github.com/annoyedmilk/LogicCard-VHDL) served as reference |

---

## TODO

- **Full example support**: fix remaining bugs, get all official Shrike examples building
- **shrike-genify**: adopt existing GUI projects into the shrike-gen build workflow
- **Expanded PCF**: cover the full ~400 IO Planner mapping options; add board `.vcf` and GUI `.gcf` variants
- **Clean up code**: clean up Makefile and code

---

## Disclaimer

**Alpha software.** Expect bugs.

Always verify generated bitstreams before programming hardware, especially for OTP targets where programming is **irreversible**. Compare outputs against GUI-generated files where possible and test on non-OTP targets first.

Use at your own risk. Neither the author nor contributors accept responsibility for damaged or incorrectly programmed devices.

---

## License

MIT, see [LICENSE](LICENSE) for details.
