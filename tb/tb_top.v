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

    // fake ADC: responds with 12'hABC when CS is asserted
    reg [11:0] adc_response = 12'hABC;
    reg [15:0] adc_shift;
    integer i;

    always @(negedge adc_cs_n) begin
        adc_shift = {4'b0000, adc_response};
        adc_miso = adc_shift[15];
        for (i = 14; i >= 0; i = i - 1) begin
            @(negedge adc_sclk);
            adc_miso = adc_shift[i];
        end
        @(posedge adc_cs_n);
        adc_miso = 0;
    end

    // fake DAC: captures 16-bit SPI word when CS is asserted
    reg [15:0] dac_received;
    reg [15:0] dac_shift;
    integer j;

    always @(negedge dac_cs_n) begin
        dac_shift = 16'd0;
        for (j = 15; j >= 0; j = j - 1) begin
            @(posedge dac_sclk);
            dac_shift[j] = dac_mosi;
        end
        dac_received = dac_shift;
    end

    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);

        // reset
        rst = 1; start = 0; adc_miso = 0;
        #100;
        rst = 0;
        #100;

        // trigger one conversion
        start = 1;
        #20;
        start = 0;

        // wait for done signal
        @(posedge done);
        #100;

        // check result
        $display("ADC value sent:     0x%03X", adc_response);
        $display("DAC received:       0x%04X", dac_received);
        $display("DAC data bits:      0x%03X", dac_received[11:0]);

        if (dac_received[11:0] == adc_response)
            $display("PASS: DAC data matches ADC value");
        else
            $display("FAIL: mismatch — expected 0x%03X got 0x%03X",
                     adc_response, dac_received[11:0]);

        $finish;
    end

endmodule
