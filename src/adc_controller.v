// adc_controller.v
// Drives spi_master to read one sample from a MCP3204 12-bit ADC
// Builds the 16-bit SPI command and extracts the 12-bit

module adc_controller (
    input wire   clk, 
    input wire   rst,
    input wire   start, 
    input wire [1:0] channel, // ADC channel to read (0-3)

    //spi_master communication
    output reg    spi_start, 
    output reg [15:0] spi_tx, 
    input wire    spi_done, 
    input wire [15:0] spi_rx, 

    // results
    output reg [11:0] adc_data,
    output reg    done
);

localparam IDLE = 1'd0;
localparam WAIT = 1'd1;

reg state;


always @(posedge clk) begin
  if (rst) begin
    state    <= IDLE; 
    spi_start <= 1'b0; 
    spi_tx    <= 16'd0;
    adc_data  <= 12'd0;
    done      <= 1'b0;
  end else begin 
    // defualt low, only pulse for one cycle
    spi_start <= 1'b0; 
    done     <= 1'b0;

    case (state)
        
        IDLE: begin 
            if (start) begin
              // build MC3204 command: start bit + single-ended + channel
              spi_tx <= {5'b00001, 1'b1, channel, 8'b0};
              spi_start <= 1'b1; 
              state <= WAIT;
            end
        end

        WAIT: begin 
            if (spi_done) begin
              // bottom 12 bits of rx are the ADC result
              adc_data <= spi_rx[11:0];
              done <= 1'b1; 
              state <= IDLE;
            end
        end
    endcase
  end
end
endmodule