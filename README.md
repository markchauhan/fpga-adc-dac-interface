# FPGA ADC/DAC Interface

Verilog design that reads one 12-bit sample from an MCP3204 ADC and writes it to an MCP4921 DAC. Each chip has its own SPI bus. The SPI master is written from scratch, with no vendor IP cores.

The design has been verified in simulation only. It has not been run on hardware.

## What it does

One pulse on `start` runs one ADC read followed by one DAC write:

1. `adc_controller` builds a 24-bit MCP3204 command (start bit, single-ended, channel) and starts the ADC SPI master.
2. The ADC SPI master clocks out the command and shifts in the reply.
3. `adc_controller` takes the low 12 bits of the reply as the sample and pulses its `done`.
4. That pulse starts `dac_controller`, which builds a 16-bit MCP4921 command (4 config bits plus the sample) and starts the DAC SPI master.
5. When the DAC transfer finishes, the top-level `done` pulses for one clock cycle.

## Specs

| Parameter | Value |
|---|---|
| ADC | MCP3204, 12-bit, single-ended mode |
| DAC | MCP4921, 12-bit |
| SPI mode | 0,0 (SCLK idles low, MISO sampled on the rising edge, MOSI changes on the falling edge) |
| ADC frame | 24 bits |
| DAC frame | 16 bits |
| Bit order | MSB first |
| SCLK frequency | `clk / (2 * CLK_DIV)` |
| `CLK_DIV` | Parameter of `spi_master`, default 25 (1 MHz SCLK from a 50 MHz clock) |
| ADC channel | Fixed to channel 0 in `top.v` |
| DAC config bits | `0011` (unbuffered, 1x gain, output active) |
| Verification | Icarus Verilog simulation with behavioral ADC and DAC models |

## SPI frames

### MCP3204: 24 bits

Five leading zeros put the start bit at clock 6, so the 12 data bits land in the last 12 clocks of the frame.

```
clock:  1  2  3  4  5  6   7   8 |  9   10  11  12  13  14  15  16 | 17 18 19 20 21 22 23 24
MOSI:   0  0  0  0  0  S  SGL D2 |  D1  D0   x   x   x   x   x   x |  x  x  x  x  x  x  x  x
MISO:   z  z  z  z  z  z   z   z |  z   z    z   0  B11 B10 B9  B8 | B7 B6 B5 B4 B3 B2 B1 B0
```

What `adc_controller` sends on MOSI:

| Clock | `spi_tx` bit | Value | Meaning |
|---|---|---|---|
| 1-5 | 23-19 | `00000` | Leading zeros |
| 6 | 18 | `1` | Start bit |
| 7 | 17 | `1` | SGL/DIFF = single-ended |
| 8 | 16 | `0` | D2 (ignored by the MCP3204) |
| 9 | 15 | `channel[1]` | D1 |
| 10 | 14 | `channel[0]` | D0 |
| 11-24 | 13-0 | `0` | Don't care |

What comes back on MISO:

| Clock | `spi_rx` bit | Value |
|---|---|---|
| 1-11 | 23-13 | High-Z (clock 11 is the sample period) |
| 12 | 12 | Null bit, `0` |
| 13-24 | 11-0 | B11 to B0, MSB first |

`adc_controller` keeps `spi_rx[11:0]`.

### MCP4921: 16 bits

`dac_controller` sends `{4'b0011, dac_data}`:

| Clock | `spi_tx` bit | Value | Meaning |
|---|---|---|---|
| 1 | 15 | `0` | Write to DAC A |
| 2 | 14 | `0` | BUF = unbuffered VREF input |
| 3 | 13 | `1` | GA = 1x gain |
| 4 | 12 | `1` | SHDN = output active |
| 5-16 | 11-0 | `dac_data[11:0]` | D11 to D0, MSB first |

The DAC's data output is not used. The DAC SPI master's MISO input is tied to 0.

## The ADC frame fix

The first version sent the ADC command in a 16-bit frame: `{5'b00001, 1'b1, channel, 8'b0}`. That had two faults:

- **Too few clocks.** The MCP3204 needs a start bit, four config bits, a sample period, a null bit, and then 12 data bits. With the start bit at clock 5, only 6 of the 12 data bits were clocked out before CS went high.
- **Channel bits one position early.** The command left no D2 bit, so `channel[1]` arrived as D2 (ignored) and `channel[0]` arrived as D1. Requests for channels 0, 1, 2, 3 were decoded as channels 0, 2, 0, 2.

The original testbench did not catch this. Its ADC model ignored MOSI and returned four zeros followed by 12 data bits in 16 clocks, which is not what the chip does. The ADC model was rewritten to follow the datasheet protocol: it waits for the start bit, clocks in the four config bits, waits one sample clock, drives a null bit, then drives 12 data bits, and holds MISO high-Z otherwise. It also returns a different value for each channel.

With the new model and the 16-bit frame:

```
Channel 0:
    ADC frame: 16 clocks, SGL/DIFF=1 D2=0 D1=0 D0=0, 6 of 12 data bits sent
    DAC frame: 16 clocks, word 0x3zZ5
    ok    ADC decoded channel = 0x0
    FAIL  DAC data = 0xzZ5, expected 0xabc
    ok    DAC config bits = 0x3
  FAIL: channel 0 (1 check(s) failed)
Channel 1:
    ADC frame: 16 clocks, SGL/DIFF=1 D2=0 D1=1 D0=0, 6 of 12 data bits sent
    DAC frame: 16 clocks, word 0x3zZf
    FAIL  ADC decoded channel = 0x2, expected 0x1
    FAIL  DAC data = 0xzZf, expected 0x123
    ok    DAC config bits = 0x3
  FAIL: channel 1 (2 check(s) failed)
...
Summary: 0/4 channels passed, 5 checks passed, 7 failed
FAIL
```

With the 24-bit frame (current code):

```
Channel 0:
    ADC frame: 24 clocks, SGL/DIFF=1 D2=0 D1=0 D0=0, 12 of 12 data bits sent
    DAC frame: 16 clocks, word 0x3abc
    ok    ADC decoded channel = 0x0
    ok    DAC data = 0xabc
    ok    DAC config bits = 0x3
  PASS: channel 0
Channel 1:
    ADC frame: 24 clocks, SGL/DIFF=1 D2=0 D1=0 D0=1, 12 of 12 data bits sent
    DAC frame: 16 clocks, word 0x3123
    ok    ADC decoded channel = 0x1
    ok    DAC data = 0x123
    ok    DAC config bits = 0x3
  PASS: channel 1
...
Summary: 4/4 channels passed, 12 checks passed, 0 failed
PASS
```

The fix was to widen the ADC path to 24 bits (`spi_tx`, `spi_rx`, and `N_BITS` on the ADC SPI master) and change the command to `{5'b00000, 1'b1, 1'b1, 1'b0, channel, 14'b0}`. The DAC path was already correct and did not change.

## File structure

```
README.md
docs/
  writeup.md          design notes
src/
  spi_master.v        SPI master, mode 0,0, parameters CLK_DIV and N_BITS
  adc_controller.v    builds the MCP3204 command, extracts the 12-bit result
  dac_controller.v    builds the MCP4921 command
  top.v               two spi_master instances (24-bit ADC, 16-bit DAC) and both controllers
tb/
  tb_top.v            self-checking testbench with MCP3204 and MCP4921 models
```

## How to run

Requires Icarus Verilog (tested with version 13.0).

```
iverilog -o sim tb/tb_top.v src/top.v src/spi_master.v src/adc_controller.v src/dac_controller.v
vvp sim
```

The testbench runs one conversion on each of the four ADC channels. For each one it checks the channel the ADC model decoded, the 12 data bits the DAC model received, and the 4 DAC config bits. It prints a summary line and `PASS` or `FAIL`, and writes waveforms to `tb_top.vcd`.

## Limitations

- **Simulation only.** The design has not been synthesized or run on an FPGA or against real MCP3204 and MCP4921 parts.
- **LDAC is assumed tied low.** `top.v` has no LDAC output. The MCP4921 output only updates on the rising edge of CS if its LDAC pin is held low on the board.
- **Channel 0 only.** `top.v` ties the ADC channel to `2'b00`. `adc_controller` accepts any of the four channels, and the testbench covers all four by forcing the `channel` input.
- **SCLK is `clk / (2 * CLK_DIV)`.** `CLK_DIV` is a compile-time parameter of `spi_master`. `top.v` does not override it, so both buses use the default of 25. The divider counter is 8 bits, so `CLK_DIV` can be at most 256.
- **The models check protocol, not timing.** The testbench models check bit order and frame length. They do not check setup and hold times, CS timing, or maximum SCLK frequency, and the DAC model does not produce an analog output.
- **One conversion per `start` pulse.** There is no continuous sampling mode.
