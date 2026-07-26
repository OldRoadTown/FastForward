VERILATOR ?= verilator
TOP        = tb_top
SRCS       = $(wildcard rtl/*.v) verif/fe_model.sv verif/tb_top.sv
VFLAGS     = --binary --timing -j 4 --top-module $(TOP) \
             -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-TIMESCALEMOD

BIN = obj_dir/V$(TOP)

.PHONY: build heavy mid quick all clean

build: $(BIN)

$(BIN): $(SRCS)
	$(VERILATOR) $(VFLAGS) $(SRCS)

heavy: $(BIN)
	$(BIN) +NPKT=20000 +LOADPCT=100 +SEED=7

mid: $(BIN)
	$(BIN) +NPKT=20000 +LOADPCT=50 +SEED=11

quick: $(BIN)
	$(BIN) +NPKT=500 +LOADPCT=100 +SEED=3
	$(BIN) +NPKT=500 +LOADPCT=50  +SEED=4
	$(BIN) +NPKT=500 +LOADPCT=20  +SEED=5

all: quick mid heavy

clean:
	rm -rf obj_dir
