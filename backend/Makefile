include ../Makefile.base

XDCDIR ?= xdc
CLK ?= rdma_clock
VLOGDIR ?= verilog
OUTPUTDIR ?= output
ONLYSYNTH ?= 1
TARGETFILE ?= ../src/QP.bsv
TOPMODULE ?= mkTransportLayerRDMA

export TOP = $(TOPMODULE)
export RTL = $(VLOGDIR)
export XDC = $(XDCDIR)
export CLOCKS = $(CLK)
export OUTPUT = $(OUTPUTDIR)
export SYNTHONLY = $(ONLYSYNTH)

compile:
	mkdir -p $(BUILDDIR)
	bsc -elab -sim -verbose $(BLUESIMFLAGS) $(DEBUGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -g $(TOPMODULE) $(TARGETFILE)

verilog: compile
	mkdir -p $(VLOGDIR)
	bsc $(VERILOGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(TRANSFLAGS) -g $(TOPMODULE) $(TARGETFILE)
	bluetcl listVlogFiles.tcl -bdir $(BUILDDIR) -vdir $(BUILDDIR) $(TOPMODULE) $(TOPMODULE) | grep -i '\.v' | xargs -I {} cp {} $(VLOGDIR)

vivado: verilog
	vivado -mode batch -source non_project_build.tcl 2>&1 | tee ./run.log

clean:
	rm -rf $(BUILDDIR) $(OUTPUTDIR) $(VLOGDIR) .Xil *.jou *.log

.PHONY: verilog vivado clean
.DEFAULT_GOAL := verilog
