# ADC/DAC Interface on FPGA: Design Notes

## What it is

A Verilog design that reads a 12-bit sample from an MCP3204 ADC and writes it to an MCP4921 DAC over two separate SPI buses. The SPI master is written from scratch, with no IP cores. The ADC controller's `done` pulse starts the DAC write, so one `start` pulse runs the whole read-then-write sequence.

It has been verified in simulation only. It has not been run on hardware.

## How it works

### spi_master

A generic SPI master for mode 0,0 with two parameters: `CLK_DIV` and `N_BITS`. It does not interpret the data.

- Three states: `IDLE`, `TRANSFER`, `DONE`.
- On `start` it loads `tx_data` into a shift register and pulls CS low. MOSI is the top bit of the shift register, so the first bit is on the line before the first SCLK edge.
- In `TRANSFER` a counter toggles SCLK every `CLK_DIV` clock cycles, which gives an SCLK frequency of `clk / (2 * CLK_DIV)`. On each rising edge it shifts MISO into `rx_data`. On each falling edge it shifts the next bit onto MOSI.
- After `N_BITS` falling edges it raises CS and pulses `done` for one clock cycle.

### adc_controller

A two-state machine (`IDLE`, `WAIT`). On `start` it loads the 24-bit command

```
{5'b00000, 1'b1, 1'b1, 1'b0, channel, 14'b0}
```

and pulses `spi_start`. The fields are five leading zeros, the start bit, SGL/DIFF = 1 for single-ended, D2 = 0, the two channel bits as D1 and D0, and 14 padding bits. When the SPI master reports `spi_done`, the controller stores `spi_rx[11:0]` in `adc_data` and pulses `done`.

The five leading zeros are there for alignment. The MCP3204 starts its reply a fixed number of clocks after the start bit: four config bits, one sample clock, one null bit, then 12 data bits. With the start bit at clock 6, the null bit is sampled at clock 12 and the data bits at clocks 13 to 24, so the result is the low 12 bits of the received word with no shifting needed.

### dac_controller

The same two-state structure. On `start` it loads `{4'b0011, dac_data}` and pulses `spi_start`. The four config bits select DAC A, unbuffered reference input, 1x gain, and output active. It pulses `done` when the transfer finishes.

### top

Instantiates two SPI masters, one with `N_BITS = 24` for the ADC and one with the default 16 for the DAC, plus the two controllers. `adc_controller.done` drives `dac_controller.start`, and `adc_data` drives `dac_data`. The ADC channel is tied to `2'b00`. The DAC master's MISO input is tied to 0 and its `rx_data` is left unconnected.

## The ADC frame bug

The first version used a 16-bit frame for the ADC, the same width as the DAC:

```
{5'b00001, 1'b1, channel, 8'b0}
```

This was wrong in two ways.

**Not enough clocks.** The start bit was at clock 5. The config bits took clocks 6 to 9, the sample period clock 10, the null bit clock 11, and data started at clock 12. A 16-clock frame ended there. By the time CS went high the ADC had driven 6 of its 12 data bits, and the master had sampled 5 of them. The other bits of the received word were high-Z.

**Channel bits misaligned.** The command had no D2 bit, so everything after SGL/DIFF was one position early. `channel[1]` landed in D2, which the MCP3204 ignores. `channel[0]` landed in D1, and D0 was always 0. Requests for channels 0, 1, 2, 3 were decoded by the ADC as channels 0, 2, 0, 2.

### Why the first testbench missed it

The first ADC model did not look at MOSI. On CS falling it shifted out four zeros and then 12 data bits, one per SCLK falling edge, which fits in 16 clocks. That matched the design but not the chip, so the test passed. It also tested only channel 0, which is the one channel the misaligned command decoded correctly.

### What exposed it

The ADC model was rewritten to follow the datasheet serial protocol:

- MOSI is sampled on SCLK rising edges. The model waits for the first 1 (the start bit), so leading zeros are allowed.
- It then clocks in four config bits: SGL/DIFF, D2, D1, D0. Only D1 and D0 select the channel.
- One more rising edge is the sample period.
- On the next falling edge it drives the null bit, then B11 down to B0 on the following falling edges.
- MISO is high-Z until the null bit and after CS rises.
- Each channel returns a different value (`0xABC`, `0x123`, `0xF81`, `0x65E`), so reading the wrong channel shows up as wrong data.

The testbench was also made self-checking across all four channels. Because `top.v` ties the channel to 0, the testbench forces `dut.adc_ctrl.channel` to each value in turn.

Running the new testbench against the 16-bit design:

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
Channel 2:
    ADC frame: 16 clocks, SGL/DIFF=1 D2=1 D1=0 D0=0, 6 of 12 data bits sent
    DAC frame: 16 clocks, word 0x3zZ5
    FAIL  ADC decoded channel = 0x0, expected 0x2
    FAIL  DAC data = 0xzZ5, expected 0xf81
    ok    DAC config bits = 0x3
  FAIL: channel 2 (2 check(s) failed)
Channel 3:
    ADC frame: 16 clocks, SGL/DIFF=1 D2=1 D1=1 D0=0, 6 of 12 data bits sent
    DAC frame: 16 clocks, word 0x3zZf
    FAIL  ADC decoded channel = 0x2, expected 0x3
    FAIL  DAC data = 0xzZf, expected 0x65e
    ok    DAC config bits = 0x3
  FAIL: channel 3 (2 check(s) failed)

Summary: 0/4 channels passed, 5 checks passed, 7 failed
FAIL
```

### The fix

Five edits in two files:

- `adc_controller.v`: `spi_tx` and `spi_rx` widened from 16 to 24 bits, the reset value changed to match, and the command changed to `{5'b00000, 1'b1, 1'b1, 1'b0, channel, 14'b0}`.
- `top.v`: the ADC wires widened to 24 bits and the ADC SPI master instantiated with `N_BITS = 24`.

`spi_master.v` did not change, because the frame length was already a parameter. The DAC path did not change.

Running the same testbench against the current code:

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
Channel 2:
    ADC frame: 24 clocks, SGL/DIFF=1 D2=0 D1=1 D0=0, 12 of 12 data bits sent
    DAC frame: 16 clocks, word 0x3f81
    ok    ADC decoded channel = 0x2
    ok    DAC data = 0xf81
    ok    DAC config bits = 0x3
  PASS: channel 2
Channel 3:
    ADC frame: 24 clocks, SGL/DIFF=1 D2=0 D1=1 D0=1, 12 of 12 data bits sent
    DAC frame: 16 clocks, word 0x365e
    ok    ADC decoded channel = 0x3
    ok    DAC data = 0x65e
    ok    DAC config bits = 0x3
  PASS: channel 3

Summary: 4/4 channels passed, 12 checks passed, 0 failed
PASS
```

## Testbench

`tb/tb_top.v` drives `top` with a 50 MHz clock, which gives a 1 MHz SCLK at the default `CLK_DIV` of 25.

- **ADC model:** described above.
- **DAC model:** shifts in MOSI on each SCLK rising edge while CS is low, and latches the word and the bit count when CS rises.
- **Checks per channel:** the ADC model decoded single-ended mode and the requested channel; the 12 data bits the DAC received equal the value the ADC model returned for that channel; the DAC config bits are `0011`.
- **Timeout:** each conversion fails if `done` does not arrive within 20,000 clock cycles.

The testbench also prints the number of clocks in each frame and how many data bits the ADC model drove, which is what made the 16-bit fault easy to read from the log.

## Design decisions

- **`N_BITS` and `CLK_DIV` are parameters of `spi_master`.** One module serves both the 24-bit ADC frame and the 16-bit DAC frame. Both are compile-time parameters.
- **Two SPI master instances.** The ADC and DAC each have their own SCLK, MOSI, and CS, so neither transfer depends on the other bus.
- **Controllers are separate from the SPI master.** Everything specific to a chip (the command layout, which received bits to keep) is in the controller. The SPI master only shifts bits.
- **The ADC model keys off the start bit, not a clock count.** It responds the way the chip would to whatever the design sends, so a wrong frame produces wrong data in simulation.

## Limitations

- Simulation only. The design has not been synthesized or run on an FPGA or against real parts.
- LDAC on the MCP4921 is assumed tied low. `top.v` has no LDAC output, so the DAC output only updates on CS rising if LDAC is held low on the board.
- `top.v` reads channel 0 only. The other channels are tested by forcing the controller's `channel` input from the testbench.
- SCLK is `clk / (2 * CLK_DIV)`. `top.v` does not override `CLK_DIV`, so both buses run at the default of 25. The divider counter is 8 bits, which limits `CLK_DIV` to 256.
- The models check protocol, not timing. Setup and hold times, CS timing, and maximum SCLK frequency are not checked, and the DAC model has no analog output.
- One conversion per `start` pulse. There is no continuous sampling mode.
