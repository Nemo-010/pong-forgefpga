#!/usr/bin/env python3
"""
gen_ffpga.py  —  Generate a complete .ffpga project file for the
                 SLG47910V (ForgeFPGA) without the GUI.

The generated file is compatible with the GUI's XML schema and
opens correctly in the GUI's IO Planner if a PCF file is also provided.

USAGE
─────
    python3 gen_ffpga.py \\
        --project  MyProject           \\
        --sources  src/main.v          \\
        --pcf      constraints.pcf     \\   # optional — for IO planner
        --out      MyProject.ffpga

    python3 gen_ffpga.py --help

FIELDS / DEFAULTS
─────────────────
  --project   Project name (used for metadata; default: "project")
  --sources   One or more Verilog source files (relative paths stored as-is)
  --pcf       PCF constraints file — populates <io-spec-tool> for GUI IO Planner
  --out       Output .ffpga path (default: <project>.ffpga)
  --max-cpu   MAX_CPU for PNR (default: nproc)
  --date      Override generation date (ISO: 2026-05-31; default: today)

WHAT IS .ffpga?
────────────────
The .ffpga file is the Go Configure Software Hub project format.  It is
plain XML (GPDProject schema).  The key sections are:

  <chip>          Device identity — family/type/part/package codes for SLG47910V
  <nvmData>       OTP header bytes (device-specific, constant for Rev BB)
  <fpga-data>     PNR settings + source files + IO planner assignments
  <io-spec-tool>  IO port→signal assignments (populated from --pcf)
  <projectData>   Supply/temperature specs

Device constants (SLG47910V Rev BB, package QFN-24):
  family="04"  type="06"  friendlyName="FFPGA"  partNumber="67"  package="26"
  checksum crc32="0x451C1D42" version="2"
  nvmData: OTP preamble bytes (15 words, same as OTP_HEADER in gen_bitstreams.py)
"""

import argparse, datetime, os, sys
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

# ── Import io-spec generation if gen_io_spec.py is in the same directory ────
_GEN_IO_SPEC_PATH = Path(__file__).parent / 'gen_io_spec.py'
_have_gen_io_spec = _GEN_IO_SPEC_PATH.exists()

if _have_gen_io_spec:
    import importlib.util
    _spec = importlib.util.spec_from_file_location('gen_io_spec', _GEN_IO_SPEC_PATH)
    _gen_io_spec = importlib.util.module_from_spec(_spec)  # type: ignore
    _spec.loader.exec_module(_gen_io_spec)               # type: ignore


# ── Device constants (SLG47910V Rev BB / QFN-24) ────────────────────────────

CHIP_FAMILY     = '04'
CHIP_TYPE       = '06'
CHIP_FRIENDLY   = 'FFPGA'
CHIP_PART       = '67'
CHIP_PACKAGE    = '26'
CHIP_NVM_DATA   = ('0 0 0 28 0 0 0 0 A5 A5 A5 A5 0 0 0 0 0 0 0 0 '
                   '5A 5A 5A 5A 0 0 0 0 22 22 22 22 22 22 22 22 22 22 '
                   '0 0 3 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0')
CHIP_CRC32      = '0x451C1D42'
CHIP_CRC_VER    = '2'

# Schema / tool versions (match GP6 v6.53)
GPD_VERSION     = '6.53.003'
GPD_PROJ_VER    = '40'
GPD_OLDEST_COMPAT = '32'
DATA_VER        = '8'
YOSYS_VER       = '59'
COMPILER_VER    = '23'

# Legal notice embedded in every generated project
LEGAL_NOTICE = "Generated with Vulcan's Shrike Gen. MIT Licensed. No warranties!"


# ── XML generation ───────────────────────────────────────────────────────────

def _date_str(dt: datetime.date) -> str:
    """Format: "31 May 2026 00:00:00" (as the GUI writes it)."""
    return dt.strftime('%-d %b %Y 00:00:00')


def _date_str2(dt: datetime.date) -> str:
    """Format: "31.05.2026 00:00:00" (as <lastModify> writes it)."""
    return dt.strftime('%d.%m.%Y 00:00:00')


def _source_modules(sources: list[str]) -> str:
    lines = []
    for src in sources:
        lines.append(f'                <module filename="{xml_escape(src)}"/>')
    return '\n'.join(lines)


def _io_spec_block(pcf_path: Path | None) -> str:
    if pcf_path is None or not _have_gen_io_spec:
        return '        <io-spec-tool>\n        </io-spec-tool>'
    assignments = _gen_io_spec.parse_pcf(pcf_path)
    iomap = _gen_io_spec.resolve(assignments)
    return _gen_io_spec.gen_ffpga_xml(iomap, indent='        ')


def build_ffpga(
    project:  str,
    sources:  list[str],
    pcf:      Path | None,
    max_cpu:  int,
    date:     datetime.date,
) -> str:
    date_str  = _date_str(date)
    date_str2 = _date_str2(date)
    src_xml   = _source_modules(sources)
    io_block  = _io_spec_block(pcf)

    return f'''\
<?xml version="1.0" encoding="UTF-8"?>
<GPDProject version="{GPD_PROJ_VER}" oldestCompatibleVersion="{GPD_OLDEST_COMPAT}" GPDVersion="{GPD_VERSION}" lastChange="{date_str}" projectChecksumState="0" projectChecksum="00000000">
    <Metadata>
        <LegalNotice>{xml_escape(LEGAL_NOTICE)}</LegalNotice>
    </Metadata>
    <generalProjectSettings/>
    <chip family="{CHIP_FAMILY}" type="{CHIP_TYPE}" friendlyName="{CHIP_FRIENDLY}" partNumber="{CHIP_PART}" package="{CHIP_PACKAGE}">
        <nvmData registerLenght="480">{CHIP_NVM_DATA}</nvmData>
        <checksum crc32="{CHIP_CRC32}" version="{CHIP_CRC_VER}"/>
        <virtualProperties/>
    </chip>
    <fpga-data>
        <project-data-version>{DATA_VER}</project-data-version>
        <oldestCompatibleVersion>{DATA_VER}</oldestCompatibleVersion>
        <settings>
            <generateBitstream>
                <MAX_CPU>{max_cpu}</MAX_CPU>
                <additionalArguments></additionalArguments>
                <clockConcurrentOptimization>true</clockConcurrentOptimization>
                <compilerVersion>{COMPILER_VER}</compilerVersion>
                <highDensityIOPacking>false</highDensityIOPacking>
                <highDensityPackingLogic>true</highDensityPackingLogic>
                <maximumRoutingIterations>300</maximumRoutingIterations>
                <placeAndTrialRoute>false</placeAndTrialRoute>
                <placeAndTrialRouteIterationCount>20</placeAndTrialRouteIterationCount>
                <timingAnalysisCorner>0</timingAnalysisCorner>
                <timingAnalysisLimitPaths>-1</timingAnalysisLimitPaths>
            </generateBitstream>
            <synthesize>
                <additionalArguments></additionalArguments>
                <autoname>true</autoname>
                <enableHardMultiplexerResources>false</enableHardMultiplexerResources>
                <flatten>true</flatten>
                <keep>false</keep>
                <multiplexerResourcesNumber>5</multiplexerResourcesNumber>
                <noDSP>true</noDSP>
                <noFSM>false</noFSM>
                <useABC9>true</useABC9>
                <yosysVersion>{YOSYS_VER}</yosysVersion>
            </synthesize>
        </settings>
        <modules>
            <scr>
{src_xml}
            </scr>
        </modules>
{io_block}
        <pllConfigurator>
            <pllConfiguratorDataVersion>1</pllConfiguratorDataVersion>
            <pllConfigurations>
                <pllConfiguration>
                    <pllFref>50.000000</pllFref>
                    <pllIsManualCalculationMode>0</pllIsManualCalculationMode>
                    <pllOutputChannels>
                        <pllOutputChannel>
                            <pllIsOutEnabled>1</pllIsOutEnabled>
                            <pllRequiredFout>50.000000</pllRequiredFout>
                            <pllRefDiv>1</pllRefDiv>
                            <pllFbDiv>25</pllFbDiv>
                            <pllPostDiv1>5</pllPostDiv1>
                            <pllPostDiv2>5</pllPostDiv2>
                        </pllOutputChannel>
                    </pllOutputChannels>
                    <pllProperties>
                        <pllBypass>0</pllBypass>
                        <pllClockSelection>0</pllClockSelection>
                        <pllEnableUserClockByPll>0</pllEnableUserClockByPll>
                        <pllLock>0</pllLock>
                    </pllProperties>
                </pllConfiguration>
            </pllConfigurations>
        </pllConfigurator>
    </fpga-data>
    <projectData>
        <specs>
            <lastModify lastModifyValue="{date_str2}"/>
            <vddSpecs vddMin="1.05" vddTyp="1.1" vddMax="1.15"/>
            <vdd2Specs vdd2Min="1.71" vdd2Typ="2.5" vdd2Max="3.465"/>
            <tempSpecs tempMin="-40" tempTyp="30" tempMax="85"/>
        </specs>
    </projectData>
</GPDProject>
'''


# ── CLI ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description='Generate a .ffpga project file for SLG47910V (ForgeFPGA)')
    ap.add_argument('--project', default='project',
                    help='Project name (default: project)')
    ap.add_argument('--sources', nargs='+', metavar='FILE', default=['main.v'],
                    help='Verilog source files to include (default: main.v)')
    ap.add_argument('--pcf', type=Path, default=None,
                    help='PCF constraints file for IO planner (optional)')
    ap.add_argument('--out', type=Path, default=None,
                    help='Output .ffpga path (default: <project>.ffpga)')
    ap.add_argument('--max-cpu', type=int, default=os.cpu_count() or 1,
                    help='MAX_CPU for PNR (default: nproc)')
    ap.add_argument('--date', default=None,
                    help='Generation date ISO-8601 (default: today)')
    args = ap.parse_args()

    date = datetime.date.today()
    if args.date:
        date = datetime.date.fromisoformat(args.date)

    if args.pcf and not _have_gen_io_spec:
        sys.exit(
            f'ERROR: gen_io_spec.py not found at {_GEN_IO_SPEC_PATH}.\n'
            'Place it in the same directory as gen_ffpga.py to use --pcf.')

    out_path = args.out or Path(f'{args.project}.ffpga')

    xml = build_ffpga(
        project  = args.project,
        sources  = args.sources,
        pcf      = args.pcf,
        max_cpu  = args.max_cpu,
        date     = date,
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(xml)
    print(f'Written: {out_path}  ({len(xml):,} bytes)')
    if args.pcf:
        print(f'IO assignments loaded from: {args.pcf}')
    else:
        print('(no --pcf given — <io-spec-tool> is empty; add constraints later)')


if __name__ == '__main__':
    main()
