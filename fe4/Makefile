VERILATOR ?= verilator
YOSYS     ?= yosys
TOP        = tb_top
SRCS       = $(wildcard rtl/*.v) verif/fe_model.sv verif/tb_top.sv
VFLAGS     = --binary --timing -j 4 --top-module $(TOP) \
             -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-TIMESCALEMOD

BIN = obj_dir/V$(TOP)
DUAL_BIN = obj_dual/V$(TOP)
FULL_BIN = obj_full/V$(TOP)

.PHONY: build heavy mid quick all dual-heavy full-heavy proxy clean

build: $(BIN)

$(BIN): $(SRCS)
	$(VERILATOR) $(VFLAGS) $(SRCS)

$(DUAL_BIN): $(SRCS)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dual \
	             -DWAKE_BYPASS_V=0 -DDUAL_STEAL_V=1 $(SRCS)

$(FULL_BIN): $(SRCS)
	$(VERILATOR) $(VFLAGS) --Mdir obj_full \
	             -DWAKE_BYPASS_V=1 -DDUAL_STEAL_V=1 $(SRCS)

heavy: $(BIN)
	$(BIN) +NPKT=20000 +LOADPCT=100 +SEED=7

mid: $(BIN)
	$(BIN) +NPKT=20000 +LOADPCT=50 +SEED=11

quick: $(BIN)
	$(BIN) +NPKT=500 +LOADPCT=100 +SEED=3
	$(BIN) +NPKT=500 +LOADPCT=50  +SEED=4
	$(BIN) +NPKT=500 +LOADPCT=20  +SEED=5

all: quick mid heavy

dual-heavy: $(DUAL_BIN)
	$(DUAL_BIN) +NPKT=20000 +LOADPCT=100 +SEED=7

full-heavy: $(FULL_BIN)
	$(FULL_BIN) +NPKT=20000 +LOADPCT=100 +SEED=7

proxy:
	$(YOSYS) -Q -s synth/proxy.ys

clean:
	rm -rf obj_dir obj_dual obj_full
