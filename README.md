# FPGA ADC/DAC Interface

SPI-based ADC-to-DAC pipeline implemented in Verilog from scratch. Reads a 12-bit sample from a MCP3204 ADC and writes it to a MCP4921 DAC over two independent SPI buses. No IP cores used.

## Specs

| Parameter | Value |
|---|---|
| ADC | MCP3204 (12-bit, SPI, single-ended) |
| DAC | MCP4921 (12-bit, SPI) |
| SPI Mode | Mode 0,0 (CPOL=0, CPHA=0) |
| SPI Clock | Configurable via CLK_DIV parameter |
| Word Width | 16-bit SPI frames |
| ADC Result | 12-bit extracted from SPI response |
| DAC Input | MCP4921 config bits + 12-bit data |
| Simulation | Bit-accurate behavioral ADC and DAC models |

## What It Does

1. ADC controller builds the MCP3204 SPI command (start bit + single-ended + channel select)
2. SPI master clocks out the command and
