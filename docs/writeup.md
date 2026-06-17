# ADC/DAC Interface on FPGA

## What It Is

SPI master state machine built from scratch in Verilog, no IP cores. Reads 12-bit samples from a MCP3204 ADC and writes the result to a MCP4921 DAC over two independent SPI buses. The ADC done signal chains directly into the DAC write, so the full pipeline runs back to back without any software intervention.

## The Hard Part

MCP3204 timing requires MISO to be pre-loaded before the first rising edge of SCLK. Miss that and you lose the first bit and everything shifts by one position.

Found this the hard way: simulation was returning 0x55e instead of 0xabc. That is exactly 0xabc >> 1. Once I saw the pattern it was obvious: the master was sampling one clock cycle late. Fixed it by driving MISO on CS assertion, before the first rising edge, then shifting the remaining 15 bits on each falling edge.

Mode 0,0 also had to be exactly right in the state machine: sample MISO on rising edge, shift MOSI on falling edge. Getting that backwards produces subtly wrong data that is hard to catch without a bit-accurate testbench.

## Design Decisions

CLK_DIV is a parameter so the SPI clock rate is configurable without recompiling, useful when targeting different ADC/DAC parts with different max SCLK specs.

The testbench models both the ADC and DAC at the bit level. It does not just check the final output value, it verifies the full 16-bit SPI frame including the MCP4921 config bits. This caught the timing bug early.

Two independent SPI master instances mirror how you would wire a real photonic control board, where ADC and DAC sit on separate chip selects with independent timing.

## Why It Matters

This is the exact hardware boundary layer that sits underneath any optical feedback loop. Integrating COTS ADCs and DACs requires reading datasheets and matching timing to spec, not just writing code. The MCP3204 and MCP4921 are representative SPI peripherals and the same state machine approach applies to higher-speed parts used in real quantum control systems.
