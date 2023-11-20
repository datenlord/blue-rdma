include ../Makefile.base

TCLDIR ?= xdc
CLK ?= rdma_clock
OOC ?= 1
VLOGDIR ?= verilog
OUTPUTDIR ?= output
LOGFILE ?= run.log
RUNTOPHASE ?= place # synth place route all
PARTNAME = xcvu13p-fhgb2104-2-i
# TARGETFILE ?= ../src/QueuePair.bsv
# TOPMODULE ?= mkQP
TARGETFILE ?= ../src/TransportLayer.bsv
TOPMODULE ?= mkTransportLayer

export TOP = $(TOPMODULE)
export RTL = $(VLOGDIR)
export XDC = $(TCLDIR)
export IPS = $(SRCDIR)/ip/$(PARTNAME)
export CLOCKS = $(CLK)
export OUTPUT = $(OUTPUTDIR)
export OOCSYNTH = $(OOC)
export RUNTO = $(RUNTOPHASE)
export PART = $(PARTNAME)

compile:
	mkdir -p $(BUILDDIR)
	bsc -elab -sim -verbose $(BLUESIMFLAGS) $(DEBUGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -g $(TOPMODULE) $(TARGETFILE)

verilog: compile
	mkdir -p $(VLOGDIR)
	bsc $(VERILOGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(TRANSFLAGS) -g $(TOPMODULE) $(TARGETFILE)
	bluetcl listVlogFiles.tcl -bdir $(BUILDDIR) -vdir $(BUILDDIR) $(TOPMODULE) $(TOPMODULE) | grep -i '\.v' | xargs -I {} cp {} $(VLOGDIR)

vivado: verilog
	vivado -mode tcl -nolog -nojournal -source ./non_project_build.tcl 2>&1 | tee $(LOGFILE)

clean:
	rm -rf $(BUILDDIR) $(OUTPUTDIR) $(VLOGDIR) .Xil *.jou *.log

.PHONY: verilog vivado clean
.DEFAULT_GOAL := verilog
