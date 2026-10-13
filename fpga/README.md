# fpga -- the ForgeFPGA build

This directory is [shrike-gen](https://github.com/vicharak-in/shrike-gen)
(Vicharak, MIT), vendored so that the build is reproducible, plus three
deliberate changes.  Those three are measurements, not preferences; each
one has the numbers behind it in the comment where it is made and in
[docs/TIMING.md](../docs/TIMING.md).

| change | why |
| --- | --- |
| `ABC_PASS ?= -nocarry` | with carry chains the design does not fit (111.4% of the logic blocks); without them it fits at 90.0% |
| `PLACER_VER ?= v22c` | the v23 placer's MinPlacer aborts on the 1K tile; the v22 placer works but its directory ships no `sdf_dly/`, so v22c is the v22 binary in a copy of the v23 support directory |
| `TMPDIR ?= $(CURDIR)/../tmp` | `eda-placer` writes large scratch logs and `/tmp` is a small tmpfs in most containers |

## Prerequisites

The Renesas **Go Configure Software Hub** provides `yosys` (v59),
`eda-placer` and `verilator`.  It is a public Debian package, no account:

```sh
curl -fSL -o /tmp/gcsh.deb \
  https://renesasweb-greenpak.s3.us-west-2.amazonaws.com/v6.55/go-configure-sw-hub-v6.55.001-debian-13-amd64.deb
mkdir -p /opt/gcsh && dpkg-deb -x /tmp/gcsh.deb /opt/gcsh
export GCSW=/opt/gcsh/usr/local/go-configure-sw-hub/bin/external
```

Then create the support directory the placer needs:

```sh
cd "$GCSW/eda-placer"
cp -a v23 v22c && cp v22/eda-placer v22c/eda-placer
```

`Pong.ffpga` is committed on purpose: the shrike-gen Makefile uses the
presence of a `*.ffpga` file to tell "project directory" from "workspace
directory", and without it `make -C fpga all` quietly does nothing.

`GCSW` defaults to `../../.tools/goconfig/usr/local/go-configure-sw-hub/bin/external`
in this repository's Makefile, which is where the container this was
written in keeps it.

## Build

```sh
make update     # regenerate io_spec_in.txt and Pong.ffpga from io_map.pcf
make build      # lint -> synthesis -> place & route -> collect
```

Outputs land in `ffpga/build/`:

```
bitstream/FPGA_bitstream_MCU.bin          46408 bytes   <- for the RP2040
bitstream/FPGA_bitstream_OTP.bin          45116 bytes
bitstream/FPGA_bitstream_FLASH_MEM.bin    45096 bytes
PNR_STDOUT.log        resource usage and the placement result
PNR_TIMING.log        the achievable-frequency report
post_synth_report.txt cell counts
```

## Loading it onto the board

The Vicharak documentation is explicit about which file matters
(`getting_started.md`, "Flashing the bitstream"):

> For any custom project the bitstream file that you need to copy will be
> named as "FPGA_bitstream_MCU.bin" ... If you copy any other file present
> in the bitstream folder the fpga wont be programmed.

So the file to use is `ffpga/build/bitstream/FPGA_bitstream_MCU.bin`; the
`_OTP` and `_FLASH_MEM` images in the same directory are for other
configuration paths and are not what the RP2040 loads.  Copy it to the
board's filesystem and let the RP2040 push it into the FPGA with the
`shrike` module the board's MicroPython firmware provides, e.g.

```
mpremote cp ffpga/build/bitstream/FPGA_bitstream_MCU.bin :FPGA_bitstream_MCU.bin
mpremote exec 'import shrike; shrike.flash("FPGA_bitstream_MCU.bin")'
```

This has **not** been run against hardware here - there was no Shrike Lite
in this container - so treat it as the documented procedure, not a tested
one.  The headline timing caveat below applies to whatever it loads.

## Trying synthesis options

`./tryfit.sh "<abc options>" <label>` synthesises with a custom option
string and runs the placer just far enough to print its resource report.
That is how the fit table in docs/TIMING.md was produced, e.g.

```sh
./tryfit.sh "-abc9" abc9
./tryfit.sh "-nocarry" nocarry
```

It needs `EFLX_COMPILER_INSTALL` set or the placer segfaults looking for
`sdf_dly/T40ULP/*.combined_clk.csv`.

## Honest limitations

* Place-and-route is proprietary and this is the only way to get a
  bitstream for the SLG47910; there is no open bitstream path.
* `make build` succeeds, but the vendor's static timing analysis says the
  worst path needs 36.6 ns against an 18.5-23 ns clock period.  See
  [docs/TIMING.md](../docs/TIMING.md) before trusting a device.
* No bitstream in this repository has been loaded onto hardware.  The
  file sizes, the header magic and the flow's own success messages are
  what is verified here.
