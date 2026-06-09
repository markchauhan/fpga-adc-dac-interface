// dac_controller.v 
// Drives spi_master to write one sample to a MCP4921 12-bit DAC
// Builds the 16-bit SPI command and sends the 12-bit DAC value

module dac_controller (
    input wire clk, 
    input wire rst, 
    input wire start, 
    input wire [11:0] dac_data, // 12-bit DAC value

    //spi_master communication
    output reg   spi_start,
    output reg [15:0] spi_tx,
    input wire   spi_done,

    //status 
    output reg done
);

    localparam IDLE = 1'd0;
    localparam WAIT = 1'd1;

    reg state;

    always @(posedge clk) begin 
        if (rst) begin 
            state <= IDLE; 
            spi_start <= 1'b0; 
            spi_tx <= 16'd0;
            done <= 1'b0;
        end else begin 
            // default low, only pulse for one cycle
            spi_start <= 1'b0; 
            done <= 1'b0;

            case (state)
                IDLE: begin 
                    if (start) begin
                        // build MCP4921 command: config bits + DAC value
                        spi_tx <= {4'b0011, dac_data}; // config: unbuffered, gain=1, active mode
                        spi_start <= 1'b1; 
                        state <= WAIT;
                    end
                end

                WAIT: begin 
                    if (spi_done) begin
                        done <= 1'b1; 
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

endmodule
