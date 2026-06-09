//spi_master.v 
//Generic SPI Master Module, Mode 0,0 (CPOL=0, CPHA=0)
// Clocks out N_BITS on MOSI while capturing N_BITS on MISO
// Doesn't interpret data
//
//sclk frequency = clk / (2 * CLK_DIV)
//Ex: 50MHz clk, CLK_DIV=25 -> 1MHz sclk

module spi_master #(
    parameter CLK_DIV = 25,
    parameter N_BITS = 16
) (
    input wire clk, 
    input wire rst, 
    input wire start, 
    input wire [N_BITS-1:0] tx_data, 
    input wire miso, 

    output reg sclk, 
    output wire mosi, 
    output reg cs_n, 
    output reg [N_BITS-1:0] rx_data,
    output reg done
);

    // state machine
    localparam IDLE = 2'd0; 
    localparam TRANSFER = 2'd1; 
    localparam DONE = 2'd2; 

    reg [1:0] state; 
    reg [$clog2(N_BITS)-1:0] bit_cnt;  //bits remaing
    reg [N_BITS-1:0] shift_reg;        // tx shift register, MSB first
    reg [7:0] clk_cnt;                 // clock divider counter

    assign mosi = shift_reg[N_BITS-1];

always @(posedge clk) begin
  if (rst) begin
    //reset everything to safe 
    state    <= IDLE;
    cs_n     <= 1'b1;
    sclk     <= 1'b0; 
    done     <= 1'b0; 
    clk_cnt  <= 8'd0;
    bit_cnt  <= 0;
    shift_reg <= 0;
  end else begin 
    done <= 1'b0; // done only pulses high

    case (state)

        IDLE: begin
          cs_n <= 1'b1; 
          sclk <= 1'b0;
          if (start) begin
            //load tx data and transaction
            shift_reg <= tx_data;
            bit_cnt   <= N_BITS - 1;
            clk_cnt   <= 8'd0;
            cs_n      <= 1'b0; //select the slave
            state     <= TRANSFER;
          end
        end

        TRANSFER: begin
            clk_cnt <= clk_cnt + 1;

            if (clk_cnt == CLK_DIV - 1) begin
              clk_cnt <= 8'd0;
              sclk    <= ~sclk; //toggle sclk

              if (sclk == 1'b0) begin
                //rising edge, sample MISO
                rx_data <= {rx_data[N_BITS-2:0], miso};
              end else begin
                //falling edge, shift out next bit
                shift_reg <= {shift_reg[N_BITS-2:0], 1'b0};
                if (bit_cnt == 0)
                    state <= DONE;
                else
                    bit_cnt <= bit_cnt - 1;
                end
                end
            end
        
        DONE: begin
          // deselect slave
          cs_n <= 1'b1; 
          sclk <= 1'b0; 
          done <= 1'b1; 
          state <= IDLE; 
        end

    endcase
  end
end

endmodule

