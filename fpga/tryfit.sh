#!/bin/bash
# tryfit.sh -- run synthesis with a custom option string and then the Renesas
# placer, printing only the resource report.  Used while shrinking the design.
#
#   ./tryfit.sh "-abc9 -nocarry"
set -u
GCSW=${GCSW:-/workspace/.tools/goconfig}
EXT=$GCSW/usr/local/go-configure-sw-hub/bin/external
YOSYS=$EXT/yosys/v59/yosys
PLACER=${PLACER:-$EXT/eda-placer/v23/eda-placer}
HERE=$(cd "$(dirname "$0")" && pwd)
BUILD=$HERE/ffpga/build
OPTS=${1:-"-abc9"}
LABEL=${2:-try}

export TMPDIR=${TMPDIR:-/workspace/tmp}
RUNDIR=$(mktemp -d "$TMPDIR/eflx_try_XXXX")
mkdir -p "$RUNDIR/config" "$RUNDIR/out"
cp "$HERE/ffpga/build/io_spec_in.txt" "$RUNDIR/config/io_spec_in.txt"
printf '1K\n\nM\n' > "$RUNDIR/config/floorplanspec.fp"

SRC=""
for f in "$HERE"/ffpga/src/*.v; do SRC="$SRC \"$(basename "$f")\""; done

cat > "$RUNDIR/synth.ys" <<EOF
read_verilog -sv$SRC
hierarchy -check
flatten -noscopeinfo
synth_xilinx -nobram -noiopad -nodsp $OPTS
clean
autoname
write_verilog "$RUNDIR/post.v"
write_edif "$RUNDIR/netlist.edif"
stat
EOF

( cd "$HERE/ffpga/src" && $YOSYS -e '(.*)is implicitly declared\.' -Q -s "$RUNDIR/synth.ys" ) \
    > "$RUNDIR/synth.log" 2>&1
if [ ! -f "$RUNDIR/netlist.edif" ]; then
    echo "$LABEL: SYNTH FAILED"; tail -20 "$RUNDIR/synth.log"; exit 1
fi
python3 /tmp/stats.py "$RUNDIR/synth.log" | sed "s/^/$LABEL  /"

BLOB=$(python3 "$HERE/shrike_gen/gen_fpga_data.py" \
        --netlist "$RUNDIR/netlist.edif" \
        --fp "$RUNDIR/config/floorplanspec.fp" \
        --io "$RUNDIR/config/io_spec_in.txt")
export EFLX_COMPILER_INSTALL=${EFLX_COMPILER_INSTALL:-$EXT/eda-placer/v23}
( cd "$RUNDIR/out" && $PLACER FPGA_DATA "$BLOB" 0 ) > "$RUNDIR/pnr.log" 2>&1
grep -E "There are [0-9]+ instances|Resource usages|Type=L:|Type=M:|Resource over-use|MinPlacer failed|Usage of LUTs|Usage of Logic|dual-LUT|FATAL" \
    "$RUNDIR/pnr.log" | sed "s/^/$LABEL  /"
echo "$LABEL  rundir=$RUNDIR"
