// top.v
// Wires together spi_masater, adc_controller, and dac_controller
// Reads from MCP3204 ADC and writes to MCP4921 DAC

module top (
    input wire clk, 
    input wire rst, 
    input wire start,  //begin a conversion cycle

    // ADC SPI pins
    output wire adc_sclk, 
    output wire adc_mosi, 
    input  wire adc_miso,
    output wire adc_cs_n,

    // DAC SPI pins
    output wire dac_sclk,
    output wire dac_mosi,
    output wire dac_cs_n,
    
    output wire done
);

    // wires between adc_controller and spi_master
    wire adc_spi_start;
    wire [15:0] adc_spi_tx;
    wire adc_spi_done;
    wire [15:0] adc_spi_rx;

    //wires between dac_controller and spi_master
    wire dac_spi_start;
    wire [15:0] dac_spi_tx;
    wire dac_spi_done;

    // result from ADC to DAC
    wire [11:0] adc_result;
    wire adc_done; 

    // ADC SPI master instance
    spi_master adc_spi (
        .clk(clk),
        .rst(rst),
        .start(adc_spi_start),
        .tx_data(adc_spi_tx),
        .miso(adc_miso),
        .sclk(adc_sclk),
        .mosi(adc_mosi),
        .cs_n(adc_cs_n),
        .rx_data(adc_spi_rx),
        .done(adc_spi_done)
    );

    // DAC SPI master instance
    spi_master dac_spi (
        .clk(clk),
        .rst(rst),
        .start(dac_spi_start),
        .tx_data(dac_spi_tx),
        .miso(1'b0), // DAC doesn't send data back
        .sclk(dac_sclk),
        .mosi(dac_mosi),
        .cs_n(dac_cs_n),
        .rx_data(), // not used for DAC
        .done(dac_spi_done)
    );

    // ADC controller instance
    adc_controller adc_ctrl (
        .clk(clk),
        .rst(rst),
        .start(start),
        .channel(2'b00), // read from channel 0
        .spi_start(adc_spi_start),
        .spi_tx(adc_spi_tx),
        .spi_done(adc_spi_done),
        .spi_rx(adc_spi_rx),
        .adc_data(adc_result),
        .done(adc_done)
    );

    // DAC controller instance
    dac_controller dac_ctrl (
        .clk(clk),
        .rst(rst),
        .start(adc_done), // start DAC write after ADC conversion is done
        .dac_data(adc_result), // write ADC result to DAC
        .spi_start(dac_spi_start),
        .spi_tx(dac_spi_tx),
        .spi_done(dac_spi_done),
        .done(done) // top-level done signal pulses after DAC write is done
    );


endmodule 