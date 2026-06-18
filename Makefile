# ============================================================
# Hermes GPU — Makefile
# AI-Focused High-Compute GPU in SystemVerilog
# ============================================================

SHELL := /bin/bash

# --- Tools ---
VERILATOR ?= verilator
IVERILOG  ?= iverilog
VVP       ?= vvp

# --- Directories ---
RTL_DIR    := rtl
BUILD_DIR  := build
REPORT_DIR := reports

# --- Files ---
SVH_FILES  := $(wildcard $(RTL_DIR)/*.svh)
SV_FILES   := $(wildcard $(RTL_DIR)/*.sv)
PKG_FILES  := $(RTL_DIR)/hermes_pkg.sv
RTL_FILES  := $(filter-out $(PKG_FILES) $(RTL_DIR)/tb_%,$(SV_FILES))
TB_FILES   := $(RTL_DIR)/tb_hermes_multi_gpu.sv
ALL_SRC    := $(SVH_FILES) $(SV_FILES)

# --- Outputs ---
LINT_LOG   := $(REPORT_DIR)/lint.rpt
VLT_OBJ_DIR := $(BUILD_DIR)/obj_vlt

# --- Flags ---
IVERILOG_FLAGS  := -g2012 -sv -Wall -s v
VERILATOR_FLAGS := --lint-only --top-module hermes_multi_gpu -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-CASEINCOMPLETE -Wno-MULTITOP -sv +incdir+$(RTL_DIR)

# ============================================================
# Targets
# ============================================================

.PHONY: help
help:
	@echo "Hermes GPU Build System"
	@echo "======================="
	@echo ""
	@echo "Targets:"
	@echo "  all         Build (verilator) and lint"
	@echo "  lint        Lint RTL with Verilator  (RECOMMENDED)"
	@echo "  build-icarus Try build with Icarus     (may hang on large gen)"
	@echo "  build-vlt   Build C++ sim with Verilator"
	@echo "  wave        Run sim + view waveform (gtkwave)"
	@echo "  sim         Run Verilator simulation"
	@echo "  clean       Remove build artifacts"
	@echo "  distclean   Remove all generated files"
	@echo "  fpga-project Create Vivado project"
	@echo "  fpga-synth  Run Vivado synthesis"
	@echo "  fpga-clean  Remove synth outputs"
	@echo "  files       List all source files"
	@echo "  cloc        Count lines of code"
	@echo ""
	@echo "Files:"
	@echo "  RTL:    $(words $(RTL_FILES)) modules"
	@echo "  Headers: $(words $(SVH_FILES)) .svh files"
	@echo "  TB:     1 testbench"
	@echo "  Total:  $(words $(ALL_SRC)) source files"

.PHONY: all
all: lint

# --- Directories ---
$(BUILD_DIR) $(REPORT_DIR):
	mkdir -p $@

# ============================================================
# LINT (Verilator)
# ============================================================

.PHONY: lint
lint: | $(REPORT_DIR)
	@echo "[HERMES] Linting all RTL with Verilator..."
	@$(VERILATOR) $(VERILATOR_FLAGS) \
		$(PKG_FILES) $(RTL_FILES) 2>&1 | tee $(LINT_LOG); \
		if [ $${PIPESTATUS[0]} -eq 0 ]; then \
			echo "[HERMES] Lint: PASSED"; \
		else \
			echo "[HERMES] Lint: FAILED (see $(LINT_LOG))"; \
			exit 1; \
		fi

.PHONY: lint-strict
lint-strict: | $(REPORT_DIR)
	@echo "[HERMES] Strict lint (Wall + Werror)..."
	$(VERILATOR) --lint-only -Wall -Werror -sv \
		$(PKG_FILES) $(RTL_FILES)

# ============================================================
# BUILD (Icarus — may hang on 32x32 generate)
# ============================================================

.PHONY: build-icarus
build-icarus: | $(BUILD_DIR)
	@echo "[HERMES] Building with Icarus Verilog..."
	$(IVERILOG) $(IVERILOG_FLAGS) -I $(RTL_DIR) \
		$(PKG_FILES) $(RTL_FILES) $(TB_FILES) \
		-o $(BUILD_DIR)/simv || echo "[HERMES] Icarus build may hang on large designs; use 'make build-vlt'"

# ============================================================
# BUILD (Verilator — fast C++ simulation)
# ============================================================

.PHONY: build-vlt
build-vlt: | $(BUILD_DIR)
	@echo "[HERMES] Building C++ simulation with Verilator..."
	$(VERILATOR) -sv --timing --trace --cc --exe --build \
		--top-module tb_hermes_multi_gpu \
		-Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-CASEINCOMPLETE \
		-Wno-TIMESCALEMOD -Wno-MULTITOP -Wno-UNOPTFLAT \
		+incdir+$(RTL_DIR) \
		$(PKG_FILES) $(RTL_FILES) $(TB_FILES) $(CURDIR)/sim_main.cpp \
		--Mdir $(VLT_OBJ_DIR) \
		-o ../Vtb_hermes_multi_gpu 2>&1
	@echo "[HERMES] Verilator build: DONE"

# ============================================================
# SIMULATE
# ============================================================

.PHONY: sim
sim: build-vlt
	@echo "[HERMES] Running Hermes GPU simulation..."
	$(BUILD_DIR)/Vtb_hermes_multi_gpu

.PHONY: run
run: sim

# ============================================================
# FPGA SYNTHESIS (Vivado)
# ============================================================

VIVADO          ?= vivado
SCRIPTS_DIR     := scripts
CONSTRAINTS_DIR := constraints

.PHONY: fpga-project
fpga-project:
	@echo "[HERMES] Creating Vivado project..."
	cd $(SCRIPTS_DIR) && $(VIVADO) -mode batch -source vivado_create.tcl

.PHONY: fpga-synth
fpga-synth:
	@echo "[HERMES] Running Vivado synthesis..."
	mkdir -p synth/output
	cd $(SCRIPTS_DIR) && $(VIVADO) -mode batch -source vivado_synth.tcl

.PHONY: fpga-clean
fpga-clean:
	rm -rf synth

# ============================================================
# WAVEFORM
# ============================================================

.PHONY: wave
wave: clean-vcd build-vlt
	@echo "[HERMES] Running simulation for waveform..."
	$(BUILD_DIR)/Vtb_hermes_multi_gpu
	@if command -v gtkwave >/dev/null 2>&1; then \
		gtkwave hermes_gpu.vcd; \
	elif command -v surfviz >/dev/null 2>&1; then \
		surfviz hermes_gpu.vcd; \
	else \
		echo "[HERMES] No waveform viewer found. Install gtkwave:"; \
		echo "  sudo apt install gtkwave"; \
		echo "  Then: gtkwave hermes_gpu.vcd"; \
	fi

# ============================================================
# CLEAN
# ============================================================

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)
	@echo "[HERMES] Clean: OK"

.PHONY: clean-vcd
clean-vcd:
	rm -f hermes_gpu.vcd

.PHONY: distclean
distclean: clean clean-vcd
	rm -rf $(REPORT_DIR)
	rm -f *.vpd *.fsdb
	@echo "[HERMES] Distclean: OK"

# ============================================================
# UTILITY
# ============================================================

.PHONY: files
files:
	@echo "=== Hermes GPU Source Files ==="
	@echo ""
	@echo "--- Headers (.svh) ---"
	@for f in $(SVH_FILES); do \
		lines=$$(wc -l < $$f); \
		printf "  %-35s %3d lines\n" $$f $$lines; \
	done
	@echo ""
	@echo "--- Packages ---"
	@for f in $(PKG_FILES); do \
		lines=$$(wc -l < $$f); \
		printf "  %-35s %3d lines\n" $$f $$lines; \
	done
	@echo ""
	@echo "--- RTL Modules ---"
	@for f in $(RTL_FILES); do \
		lines=$$(wc -l < $$f); \
		printf "  %-35s %3d lines\n" $$f $$lines; \
	done
	@echo ""
	@echo "--- Testbench ---"
	@for f in $(TB_FILES); do \
		lines=$$(wc -l < $$f); \
		printf "  %-35s %3d lines\n" $$f $$lines; \
	done
	@echo ""
	@wc -l $(ALL_SRC) | tail -1

.PHONY: cloc
cloc:
	@echo "Hermes GPU — Lines of Code"
	@echo "=========================="
	@wc -l $(ALL_SRC) | sort -n

.PHONY: deps
deps:
	@echo "// Hermes GPU Module Dependencies"
	@echo "digraph hermes {"
	@echo "  rankdir=LR;"
	@echo "  node [shape=box, style=rounded];"
	@for f in $(RTL_FILES); do \
		mod=$$(grep -oP '^\s*module\s+\K\w+' $$f); \
		deps=$$(grep -oP '\b\w+_unit\b|\b\w+_core\b|\b\w+_array\b|\b\w+_scheduler\b|\b\w+_memory\b|\b\w+_controller\b|\b\w+_decoder\b|\b\w+_file\b|\b\w+_gpu\b' $$f | grep -v "^$$mod$$" | sort -u); \
		for d in $$deps; do \
			echo "  \"$$mod\" -> \"$$d\";"; \
		done; \
	done
	@echo "}"
