// Verilator C++ wrapper for Hermes GPU — with VCD waveform tracing
#include "Vtb_hermes_gpu.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>

vluint64_t main_time = 0;

double sc_time_stamp() {
  return main_time * 1.0;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  // Enable VCD trace
  Verilated::traceEverOn(true);

  Vtb_hermes_gpu* dut = new Vtb_hermes_gpu;
  VerilatedVcdC* trace = new VerilatedVcdC;
  dut->trace(trace, 99);
  trace->open("hermes_gpu.vcd");

  const vluint64_t max_time = 2000000;

  while (!Verilated::gotFinish() && main_time < max_time) {
    dut->eval();
    trace->dump(main_time);
    main_time++;
  }

  trace->close();
  bool passed = Verilated::gotFinish();
  printf("[HERMES] Simulation: %s (%llu ticks)\n",
         passed ? "PASSED" : "TIMEOUT",
         (long long)main_time);
  printf("[HERMES] Waveform: hermes_gpu.vcd\n");
  delete dut;
  delete trace;
  return passed ? 0 : 1;
}
