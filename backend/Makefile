include ../Makefile.base

TCLDIR ?= xdc
CLK ?= rdma_clock
OOC ?= 1
VLOGDIR ?= ../src/third_party/verilog
OUTPUTDIR ?= output
LOGFILE ?= run.log
RUNTOPHASE ?= all # synth place route all
PARTNAME = xcvu13p-fhgb2104-2-i
# PARTNAME = xcvu23p-vsva1365-2L-e

# TARGETFILE ?= ../src/SendQ.bsv
# TOPMODULE ?= mkSQ
# TARGETFILE ?= ../src/QueuePair.bsv
# TOPMODULE ?= mkQP
# TARGETFILE ?= ../test/TestTop.bsv
# TOPMODULE ?= mkTestInjectStreamToCmacControllerWrapper
TARGETFILE ?= ../src/third_party/Top.bsv
TOPMODULE ?= mkBsvTop

BACKENDDIR ?= .
MAX_NET_PATH_NUM ?= 10000
VERILOG_TOPMODULE ?= top

STUB_TOP_MODULE = mkStubTop
STUB_TOP_FILE = ../src/stubs.bsv

IMPORT_VERILOG_DIR := +:../src/third_party/blue-crc/lib/primitives
IMPORT_VERILOG_DIR := $(shell echo "$(IMPORT_VERILOG_DIR)" | tr -d ' ')

export TOP = $(TOPMODULE)
export DIR_RTL = $(VLOGDIR)
export DIR_XDC = $(TCLDIR)
export DIR_OOC_SCRIPTS = $(BACKENDDIR)/ooc_tcl_and_xdc
export DIR_IPS = $(BACKENDDIR)/ips
export DIR_IP_GENERATED = $(BUILDDIR)/ips
export DIR_BSV_GENERATED = $(BACKENDDIR)/verilog
export VERILOG_TOPMODULE
export TARGET_CLOCKS = $(CLK)
export DIR_OUTPUT = $(OUTPUTDIR)
export OOCSYNTH = $(OOC)
export RUNTO = $(RUNTOPHASE)
export PART = $(PARTNAME)
export MAX_NET_PATH_NUM

export DIR_BSV_GENERATED_STUB = $(BACKENDDIR)/verilog/stub

gen_udp_crc_tab:
	mkdir -p $(DIR_BSV_GENERATED)
	
	python3 $(BLUE_CRC_DIR)/scripts/gen_crc_tab.py \
			$(BLUE_UDP_CRC_TABLE_GEN_INFO_DIR)/crc_ieee_32_512.json \
			$(DIR_BSV_GENERATED)
compile:
	mkdir -p $(BUILDDIR)
	bsc -elab -verilog -verbose $(BLUESIMFLAGS) $(DEBUGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -g $(TOPMODULE) $(TARGETFILE)

verilog: gen_udp_crc_tab compile 
	mkdir -p $(DIR_BSV_GENERATED)
	bsc $(VERILOGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(TRANSFLAGS) -g $(TOPMODULE) $(TARGETFILE)
	bluetcl listVlogFiles.tcl -p $(IMPORT_VERILOG_DIR) -bdir $(BUILDDIR) -vdir $(BUILDDIR) $(TOPMODULE) $(TOPMODULE) | grep -i '\.v' | xargs -I {} cp {} $(DIR_BSV_GENERATED)

compile_stub:
	mkdir -p $(BUILDDIR)
	bsc -elab -sim -verbose $(BLUESIMFLAGS) $(DEBUGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -g $(STUB_TOP_MODULE) $(STUB_TOP_FILE)

verilog_stub: compile_stub
	mkdir -p $(BUILDDIR)
	mkdir -p $(DIR_BSV_GENERATED_STUB)
	bsc $(VERILOGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(TRANSFLAGS) -g $(STUB_TOP_MODULE) $(STUB_TOP_FILE)
	bluetcl listVlogFiles.tcl -bdir $(BUILDDIR) -vdir $(BUILDDIR) $(STUB_TOP_MODULE) $(STUB_TOP_MODULE) | grep -i '\.v' | xargs -I {} cp {} $(DIR_BSV_GENERATED_STUB)

vivado: verilog
	vivado -mode tcl -nolog -nojournal -source ./build_top.tcl 2>&1 | tee $(LOGFILE)

vivado_ooc:
	vivado -mode tcl -nolog -nojournal -source ./build_top.tcl 2>&1 | tee $(LOGFILE)

vivado_multi_placement:
	vivado -mode tcl -nolog -nojournal -source ./build_top.tcl -tclargs synth 2>&1 | tee $(LOGFILE)
	vivado -mode tcl -nolog -nojournal -source ./build_top.tcl -tclargs prw ExtraNetDelay_high 2>&1 | tee $(LOGFILE)
	vivado -mode tcl -nolog -nojournal -source ./build_top.tcl -tclargs prw WLDrivenBlockPlacement 2>&1 | tee $(LOGFILE)

clean:
	rm -rf $(BUILDDIR) $(OUTPUTDIR) $(DIR_BSV_GENERATED) $(DIR_BSV_GENERATED_STUB) .Xil *.jou *.log

.PHONY: verilog vivado clean
.DEFAULT_GOAL := verilog
