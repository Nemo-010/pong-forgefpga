# Fabrication: the open path, and what a prototype shuttle costs

Two separate things live in this file:

1. **The open-process path for this RTL**, which is a real, automated,
   free-of-charge-for-the-design-part route through `asic/`.
2. **A starting survey of prototyping shuttles**, with the date each entry
   was checked and an explicit "not verified" column, because prices,
   deadlines and even which domains answer change, and a stale price is
   worse than no price.

The FPGA half of this repository (which is what the user actually needs for
the Shrike Lite) is *not* open: ForgeFPGA place-and-route is proprietary and
the bitstream comes from Renesas' Go Configure Software Hub.  See
docs/ARCHITECTURE.md.  What follows is the open path for a *different*
chip, kept honest by saying so.

## The open ASIC path for this design

`asic/tt_um_pong.v` wraps the unmodified `src/` RTL for a Tiny Tapeout tile.
The wrapper is checked in CI:

```
cd asic && make check     # iverilog elaborate + verilator lint, no PDK needed
```

and the RTL is portable because of decisions made for the FPGA target, not
in spite of them:

* **no vendor primitives, no `ifdef`s, no gated clocks** - the FPGA flow
  uses `synth_xilinx` on stock Verilog, and the ASIC flow can use
  `yosys`/`OpenLane` on exactly the same files;
* **one clock domain**, from an external `clk` pin, with the design's own
  16-tick reset generator rather than an asynchronous reset;
* **no RAM, no DSP, no multipliers** - the renderer stream the panel, so
  there is nothing to infer;
* **no tristate logic in the fabric**: SCL/SDA are driven low or released,
  and the tristate happens in the pad (which is what `uio_oe` is for).

The wrapper maps the five switches onto `ui_in[4:0]`, the I2C pair onto
`uio[1:0]` (open drain), and the status LED onto `uo_out[0]`, and folds
`ena`/`rst_n` into the switch inputs and output enables.  `asic/info.yaml`
carries the pin table for the shuttle's harness.

What a tapeout still needs, which this repository cannot provide:

* the shuttle's own testbench and a `test/` directory, so the submitted
  design is verified *in that harness* (the design is verified here, but
  not with the shuttle's runner);
* the actual hardening run (OpenLane/OpenROAD with SKY130A or GF180MCU),
  which needs Docker and a PDK download - neither is available in the
  container this was written in, so `make -C asic harden` deliberately
  stops with instructions instead of pretending;
* the shuttle's timing target, which is much lower than the FPGA's 50 MHz
  and which this design would meet on a modern process, where the vendor
  flow's 35.1 ns on a 40 nm low-power FPGA fabric corresponds to a very
  different number.  No STA run for SKY130 exists here.

## Survey of cheap prototyping shuttles

Checked from this container on **2026-10-13** (the container's clock; the
date is quoted because these entries go stale).  "Reached" means an HTTP
request from here returned a page, and the quoted text is from that page.
A dash means the request failed *from this container*, which may be a
blocked domain or a DNS artifact rather than the service being gone.

| service | region | what the page said when checked | status |
| --- | --- | --- | --- |
| **Tiny Tapeout** (tinytapeout.com) | global, ships anywhere | "Our open shuttles SKY26d ... GF26c", tile-based pricing with a calculator, "Subsidized PCBs", and early-bird pricing that is "limited per shuttle, and ... only available to individuals" | reached 2026-10-13 |
| **EUROPRACTICE** (europractice-ic.com) | EU, worldwide for some processes | front page lists "MPW Schedules & Prices", "Prototyping", "Access & Registration" | reached 2026-10-13 |
| **MOSIS** (mosis.com) | US | front page: "Nanofab Prototyping, MPW Services, IC Design" | reached 2026-10-13 |
| **SkyWater Technology** (skywatertechnology.com) | US | corporate site; MPW access is through partners/agents, not direct | reached 2026-10-13 |
| **Efabless / ChipIgnite** | US | `efabless.com` redirects and `/chipignite` returns 404 | site changed; **not verified** - do not rely on the old ChipIgnite pricing |
| **CMP** (cmp.imag.fr) | FR | connection failed from this container | **not verified** |
| **IHP MPW** (ihp-microelectronics.com) | DE | `/services/mpw` returns 404 (site reachable, that path is not) | **not verified** |
| **imec IC-link** | BE | the `/en/what-we-offer/ic-link` path returned 404 | **not verified** |

A few things are true of the whole category and worth stating before
anyone plans around a table like this:

* **The two individual-friendly routes are the shared-tile ones.**  Tiny
  Tapeout exists precisely to make a tapeout cheap by putting many designs
  on one mask set on a fixed tile grid, with subsidised PCBs on the
  breakout boards; most foundry MPW programmes are aimed at companies,
  need an NDA, and quote per mm2 with an NRE.
* **"Cheap" is per tile, not per design.**  A design that needs a wide
  bus, many pads, a large memory or an analogue block is not in the same
  price class, and none of these services will take a 128x64 panel
  interface without the panel being external.
* **Regions are not the barrier, responsibilities are.**  Every one of
  these ships internationally; what differs is who signs the export
  paperwork and whether the process is on a restricted list.
* **Nobody publishes a fixed price for a custom run** the way a sheet
  metal shop does for a bracket.  The closest analogue to "SendCutSend for
  silicon" that exists today is a fixed-size shared-tile shuttle, which is
  exactly what Tiny Tapeout is.

Any decision made from this table should re-fetch the vendor's own page
first.  This file records what was seen and when, nothing more.

## Other cheap paths that are not shuttles

For the same "prototype a digital design for a few hundred dollars"
problem there are two routes that avoid a mask set entirely and are worth
naming next to the table:

* **A bigger FPGA.**  The design is 90% of a 140-block device; a cheap
  ICE40/ECP5/Gowin board removes the timing worry completely and costs
  less than a shuttle.  This is the honest recommendation for anyone who
  wants *this game* on hardware this month.
* **An MCU.**  The same game state machine is an afternoon in C on the
  RP2040 that is already on the Shrike Lite, next to the FPGA.  That is
  the right answer if the goal is the game rather than the chip.
