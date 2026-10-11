//tb_top.v
// Testbench for top.v simulates MCP3204 ADC and MCP4921 DAC using behavioral models
// Run with: iverilog -o sim tb/tb_top.v src/top.v src/spi_master.v src/adc_controller.v src/dac_controller.v
//           vvp sim

`timescale 1ns/1ps

module tb_top;

    // clock and control
    reg clk, rst, start;

    // ADC SPI pins
    wire adc_sclk, adc_mosi, adc_cs_n;
    reg  adc_miso;

    // DAC SPI pins
    wire dac_sclk, dac_mosi, dac_cs_n;

    // done signal
    wire done;

    // instantiate top module
    top dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .adc_sclk(adc_sclk),
        .adc_mosi(adc_mosi),
        .adc_miso(adc_miso),
        .adc_cs_n(adc_cs_n),
        .dac_sclk(dac_sclk),
        .dac_mosi(dac_mosi),
        .dac_cs_n(dac_cs_n),
        .done(done)
    );

    // 50MHz clock
    initial clk = 0;
    always #10 clk = ~clk; // 20ns period -> 50MHz

    // ------------------------------------------------------------------
    // fake ADC: MCP3204 behavioral model, SPI Mode 0,0
    //
    // Follows the datasheet serial protocol (8-bit-segment timing, 24 clocks):
    //   MOSI: 0 0 0 0 0 S SGL D2 | D1 D0 x x  x   x   x  x  | x  ...  x
    //   MISO: z z z z z z  z  z  | z  z  z 0 B11 B10 B9 B8  | B7 ... B0
    // The model keys off the start bit rather than a clock count, so leading
    // zeros are tolerated. MOSI is sampled on rising edges; MISO changes on
    // falling edges and is high-Z until the null bit.
    // ------------------------------------------------------------------
    localparam ADC_WAIT_START = 2'd0;  // waiting for first 1 on MOSI
    localparam ADC_CONFIG     = 2'd1;  // clocking in SGL/DIFF, D2, D1, D0
    localparam ADC_SAMPLE     = 2'd2;  // sample period, one more rising edge
    localparam ADC_OUTPUT     = 2'd3;  // null bit, then B11..B0

    reg [1:0]  adc_state;
    reg [3:0]  adc_cfg;        // {SGL/DIFF, D2, D1, D0} as clocked in
    reg [2:0]  adc_cfg_cnt;
    reg [11:0] adc_shift;
    reg [3:0]  adc_out_cnt;    // data bits driven so far
    reg        adc_null_sent;
    integer    adc_clk_cnt;    // SCLK rising edges seen in this frame

    // a different conversion result for each channel
    function [11:0] adc_value;
        input [1:0] ch;
        case (ch)
            2'd0: adc_value = 12'hABC;
            2'd1: adc_value = 12'h123;
            2'd2: adc_value = 12'hF81;
            2'd3: adc_value = 12'h65E;
        endcase
    endfunction

    // MCP3204 only decodes D1:D0 (D2 is don't care)
    wire [1:0] adc_channel = adc_cfg[1:0];
    wire       adc_sgl     = adc_cfg[3];

    always @(negedge adc_cs_n) begin
        adc_state     = ADC_WAIT_START;
        adc_cfg       = 4'bxxxx;
        adc_cfg_cnt   = 0;
        adc_out_cnt   = 0;
        adc_null_sent = 0;
        adc_clk_cnt   = 0;
        adc_miso      = 1'bz;
    end

    always @(posedge adc_cs_n)
        adc_miso = 1'bz;

    // rising edge: clock in MOSI
    always @(posedge adc_sclk) if (!adc_cs_n) begin
        adc_clk_cnt = adc_clk_cnt + 1;
        case (adc_state)
            ADC_WAIT_START: if (adc_mosi === 1'b1) adc_state = ADC_CONFIG;
            ADC_CONFIG: begin
                adc_cfg     = {adc_cfg[2:0], adc_mosi};
                adc_cfg_cnt = adc_cfg_cnt + 1;
                if (adc_cfg_cnt == 4) adc_state = ADC_SAMPLE;
            end
            ADC_SAMPLE: begin
                adc_shift = adc_value(adc_channel);
                adc_state = ADC_OUTPUT;
            end
            default: ;
        endcase
    end

    // falling edge: drive MISO
    always @(negedge adc_sclk) if (!adc_cs_n && adc_state == ADC_OUTPUT) begin
        if (!adc_null_sent) begin
            adc_miso      = 1'b0;            // null bit
            adc_null_sent = 1;
        end else if (adc_out_cnt < 12) begin
            adc_miso    = adc_shift[11];     // MSB first
            adc_shift   = {adc_shift[10:0], 1'b0};
            adc_out_cnt = adc_out_cnt + 1;
        end else begin
            adc_miso = 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // fake DAC: captures the SPI word clocked in while CS is asserted
    // ------------------------------------------------------------------
    reg [15:0] dac_received;
    reg [15:0] dac_shift;
    integer    dac_bits;       // bits clocked in during the last frame
    integer    dac_bit_cnt;

    always @(negedge dac_cs_n) begin
        dac_shift   = 16'd0;
        dac_bit_cnt = 0;
    end

    always @(posedge dac_sclk) if (!dac_cs_n) begin
        dac_shift   = {dac_shift[14:0], dac_mosi};
        dac_bit_cnt = dac_bit_cnt + 1;
    end

    always @(posedge dac_cs_n) begin
        dac_received = dac_shift;
        dac_bits     = dac_bit_cnt;
    end

    // ------------------------------------------------------------------
    // self-checking test
    // ------------------------------------------------------------------
    localparam TIMEOUT_CYCLES = 20000;

    integer checks_passed = 0;
    integer checks_failed = 0;
    integer chans_passed  = 0;
    integer chans_failed  = 0;
    integer errs;
    integer cycles;
    integer c;

    task check;
        input        ok;
        input [255:0] name;
        input [15:0] got;
        input [15:0] expected;
        begin
            if (ok) begin
                checks_passed = checks_passed + 1;
                $display("    ok    %0s = 0x%0h", name, got);
            end else begin
                checks_failed = checks_failed + 1;
                errs = errs + 1;
                $display("    FAIL  %0s = 0x%0h, expected 0x%0h", name, got, expected);
            end
        end
    endtask

    task run_channel;
        input [1:0] ch;
        begin
            errs = 0;
            $display("Channel %0d:", ch);

            // top.v ties the ADC channel to a constant, so override it here
            force dut.adc_ctrl.channel = ch;

            @(negedge clk);
            start = 1;
            @(negedge clk);
            start = 0;

            cycles = 0;
            while (done !== 1'b1 && cycles < TIMEOUT_CYCLES) begin
                @(posedge clk);
                cycles = cycles + 1;
            end

            if (done !== 1'b1) begin
                $display("    FAIL  timed out waiting for done");
                checks_failed = checks_failed + 1;
                errs = errs + 1;
            end else begin
                repeat (5) @(posedge clk);
                $display("    ADC frame: %0d clocks, SGL/DIFF=%b D2=%b D1=%b D0=%b, %0d of 12 data bits sent",
                         adc_clk_cnt, adc_cfg[3], adc_cfg[2], adc_cfg[1], adc_cfg[0], adc_out_cnt);
                $display("    DAC frame: %0d clocks, word 0x%04h", dac_bits, dac_received);

                check(adc_sgl === 1'b1 && adc_channel === ch,
                      "ADC decoded channel", {14'd0, adc_channel}, {14'd0, ch});
                check(dac_received[11:0] === adc_value(ch),
                      "DAC data", {4'd0, dac_received[11:0]}, {4'd0, adc_value(ch)});
                check(dac_received[15:12] === 4'b0011,
                      "DAC config bits", {12'd0, dac_received[15:12]}, 16'h3);
            end

            if (errs == 0) begin
                chans_passed = chans_passed + 1;
                $display("  PASS: channel %0d", ch);
            end else begin
                chans_failed = chans_failed + 1;
                $display("  FAIL: channel %0d (%0d check(s) failed)", ch, errs);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);

        // reset
        rst = 1; start = 0; adc_miso = 1'bz;
        #100;
        rst = 0;
        #100;

        for (c = 0; c < 4; c = c + 1)
            run_channel(c[1:0]);

        $display("");
        $display("Summary: %0d/4 channels passed, %0d checks passed, %0d failed",
                 chans_passed, checks_passed, checks_failed);
        if (chans_failed == 0)
            $display("PASS");
        else
            $display("FAIL");

        $finish;
    end

endmodule
