// A simple system-on-a-chip (SoC) for the MiST
// (c) 2015 Till Harbaum
									  
module soc ( 
   input [1:0] 	CLOCK_27,
	
	// SDRAM interface
	inout [15:0]  	SDRAM_DQ, 		// SDRAM Data bus 16 Bits
	output [12:0] 	SDRAM_A, 		// SDRAM Address bus 13 Bits
	output        	SDRAM_DQML, 	// SDRAM Low-byte Data Mask
	output        	SDRAM_DQMH, 	// SDRAM High-byte Data Mask
	output        	SDRAM_nWE, 		// SDRAM Write Enable
	output       	SDRAM_nCAS, 	// SDRAM Column Address Strobe
	output        	SDRAM_nRAS, 	// SDRAM Row Address Strobe
	output        	SDRAM_nCS, 		// SDRAM Chip Select
	output [1:0]  	SDRAM_BA, 		// SDRAM Bank Address
	output 			SDRAM_CLK, 		// SDRAM Clock
	output        	SDRAM_CKE, 		// SDRAM Clock Enable
  
   // SPI interface to arm io controller
   output      	SPI_DO,
	input       	SPI_DI,
   input       	SPI_SCK,
   input 			SPI_SS2,
   input 			SPI_SS3,
   input 			SPI_SS4,
	input       	CONF_DATA0, 

	// VGA interface
   output 			VGA_HS,
   output 	 		VGA_VS,
   output [5:0] 	VGA_R,
   output [5:0] 	VGA_G,
   output [5:0] 	VGA_B
);

wire pixel_clock;

wire [7:0] joystick_0;
wire [7:0] joystick_1;

// the configuration string is returned to the io controller to allow
// it to control the menu on the OSD 
parameter CONF_STR = {
        "Z80_SOC;;",
        "O1,Scanlines,On,Off;",
        "T2,Reset"
};

parameter CONF_STR_LEN = 9+20+8;

// the status register is controlled by the on screen display (OSD)
wire [7:0] status;

// include user_io module for arm controller communication
user_io #(.STRLEN(CONF_STR_LEN)) user_io ( 
		.conf_str   ( CONF_STR   ),

		.SPI_CLK    ( SPI_SCK    ),
      .SPI_SS_IO  ( CONF_DATA0 ),
      .SPI_MISO   ( SPI_DO     ),
      .SPI_MOSI   ( SPI_DI     ),

		.status     ( status     ),
		 
		// ps2 interface
		.ps2_clk        ( ps2_clock      ),
		.ps2_kbd_clk    ( ps2_kbd_clk    ),
		.ps2_kbd_data   ( ps2_kbd_data   ),
		.ps2_mouse_clk  ( ps2_mouse_clk  ),
		.ps2_mouse_data ( ps2_mouse_data ),
		 
		.joystick_0 ( joystick_0 ),
      .joystick_1 ( joystick_1 )
);

// the MiST emulates a PS2 keyboard and mouse
wire ps2_kbd_clk, ps2_kbd_data;
wire ps2_mouse_clk, ps2_mouse_data;

// a very simple keyboard implementation which only decodes
// a few keys (SPACE, S, ...)
wire kbd_sel = !cpu_iorq_n && cpu_m1_n && ({ cpu_addr[7:1], 1'b0} == 8'h20 );
wire [7:0] keys;
keyboard keyboard (
	.reset    ( cpu_reset    ),
	.clk      ( cpu_clock    ),

	.ps2_clk  ( ps2_kbd_clk  ),
	.ps2_data ( ps2_kbd_data ),
	
	.keys     ( keys         )
);

// a very simple mouse implementation. It accumulates mouse movement 
// internally until the cpu reads the values which in turn clears the
// hardware counters
wire [7:0] mouse_dout = 
	(cpu_addr[1:0]==2'd0)?mouse_x:
	(cpu_addr[1:0]==2'd1)?mouse_y:
	{6'b000000, mouse_b};
wire [7:0] mouse_x;
wire [7:0] mouse_y;
wire [1:0] mouse_b;
wire mouse_sel = !cpu_iorq_n && cpu_m1_n && ({ cpu_addr[7:2], 2'b00} == 8'h30 );
mouse mouse (
	.reset    ( cpu_reset      ),
	.clk      ( cpu_clock      ),

	.ps2_clk  ( ps2_mouse_clk  ),
	.ps2_data ( ps2_mouse_data ),
	
	.x        ( mouse_x        ),
	.clr_x    ( mouse_sel && !cpu_rd_n && (cpu_addr[1:0] == 2'd0)),
	.y        ( mouse_y        ),
	.clr_y    ( mouse_sel && !cpu_rd_n && (cpu_addr[1:0] == 2'd1)),
	.b        ( mouse_b        )
);

	
// include the on screen display
osd #(0,0,4) osd (
   .pclk       ( pixel_clock  ),

   // spi for OSD
   .sdi        ( SPI_DI       ),
   .sck        ( SPI_SCK      ),
   .ss         ( SPI_SS3      ),

   .red_in     ( video_r      ),
   .green_in   ( video_g      ),
   .blue_in    ( video_b      ),
   .hs_in      ( video_hs     ),
   .vs_in      ( video_vs     ),

   .red_out    ( VGA_R        ),
   .green_out  ( VGA_G        ),
   .blue_out   ( VGA_B        ),
   .hs_out     ( VGA_HS       ),
   .vs_out     ( VGA_VS       )
);
                          
wire [5:0] video_r, video_g, video_b;
wire video_hs, video_vs;
		  
// include VGA controller
vga vga (
   .reset    ( cpu_reset        ),
	.pclk     ( pixel_clock      ),
	 
	.cpu_clk  ( cpu_clock        ),
	.cpu_wr   ( !cpu_wr_n && !cpu_mreq_n && !cpu_addr[15] ),
	.cpu_addr ( cpu_addr[13:0]   ),
	.cpu_data ( cpu_dout         ),

	.scanlines ( !status[1]      ),
	
	// video output as fed into the on screen display engine
	.hs    	( video_hs          ),
	.vs    	( video_vs          ),
	.r     	( video_r           ),
	.g     	( video_g           ),
	.b     	( video_b           )
);

// The CPU is kept in reset for further 256 cycles after the PLL is generating stable clocks
// to make sure things like the SDRAM have some time to initialize
// status 0 is arm controller power up reset, status 2 is reset entry in OSD
reg [7:0] cpu_reset_cnt = 8'h00;
wire cpu_reset = (cpu_reset_cnt != 255);
always @(posedge cpu_clock) begin
	if(!pll_locked || status[0] || status[2] || dio_download)
		cpu_reset_cnt <= 8'd0;
	else 
		if(cpu_reset_cnt != 255)
			cpu_reset_cnt <= cpu_reset_cnt + 8'd1;
end
			
// SDRAM control signals
wire ram_clock;
assign SDRAM_CKE = 1'b1;

// during ROM download data_io writes the ram. Otherwise the CPU
wire [7:0] sdram_din = dio_download?dio_data:cpu_dout;
wire [24:0] sdram_addr = dio_download?dio_addr:{ 9'd0, cpu_addr[15:0] };
wire sdram_wr = dio_download?dio_write:(!cpu_wr_n && !cpu_mreq_n && cpu_addr[15]);
wire sdram_oe = dio_download?1'b1:(!cpu_rd_n && !cpu_mreq_n);

sdram sdram (
	// interface to the MT48LC16M16 chip
   .sd_data        ( SDRAM_DQ                  ),
   .sd_addr        ( SDRAM_A                   ),
   .sd_dqm         ( {SDRAM_DQMH, SDRAM_DQML}  ),
   .sd_cs          ( SDRAM_nCS                 ),
   .sd_ba          ( SDRAM_BA                  ),
   .sd_we          ( SDRAM_nWE                 ),
   .sd_ras         ( SDRAM_nRAS                ),
   .sd_cas         ( SDRAM_nCAS                ),

   // system interface
   .clk            ( ram_clock                 ),
   .clkref         ( cpu_clock                 ),
   .init           ( !pll_locked               ),

   // cpu interface
   .din            ( sdram_din                 ),
   .addr           ( sdram_addr                ),
   .we             ( sdram_wr                  ),
   .oe         	 ( sdram_oe                  ),
   .dout           ( ram_data_out              )
);
	
// CPU control signals
wire [15:0] cpu_addr;
wire [7:0] cpu_din;
wire [7:0] cpu_dout;
wire cpu_rd_n;
wire cpu_wr_n;
wire cpu_mreq_n;
wire cpu_m1_n;
wire cpu_iorq_n;

// include Z80 CPU
T80s T80s (
	.RESET_n  ( !cpu_reset    ),
	.CLK_n    ( cpu_clock     ),
	.WAIT_n   ( 1'b1          ),
	.INT_n    ( 1'b1          ),
	.NMI_n    ( 1'b1          ),
	.BUSRQ_n  ( 1'b1          ),
	.MREQ_n   ( cpu_mreq_n    ),
	.M1_n     ( cpu_m1_n      ),
	.IORQ_n   ( cpu_iorq_n    ),
	.RD_n     ( cpu_rd_n      ), 
	.WR_n     ( cpu_wr_n      ),
	.A        ( cpu_addr      ),
	.DI       ( cpu_din       ),
	.DO       ( cpu_dout      )
);

// de-multiplex the IO data sources
wire [7:0] io_dout = 
	kbd_sel?keys:
	mouse_sel?mouse_dout:
	8'h00;

// map 32k SDRAN into upper half od the address space (A15=1)
// and ROM (now also placed in SDRAM) into the lower half (A15=0)
wire [7:0] ram_data_out;
assign cpu_din = (!cpu_iorq_n)?io_dout:ram_data_out;

wire dio_download;
wire [24:0] dio_addr;
wire [7:0] dio_data;
wire dio_write;

// include ROM download helper
data_io data_io (
	// io controller spi interface
   .sck	( SPI_SCK ),
   .ss	( SPI_SS2 ),
   .sdi	( SPI_DI  ),

	.downloading ( dio_download ),  // signal indicating an active rom download
	         
   // external ram interface
   .clk   ( cpu_clock ),
   .wr    ( dio_write ),
   .addr  ( dio_addr  ),
   .data  ( dio_data  )
);


// derive 4Mhz cpu clock and 15kHz ps2 clock from 32Mhz sdram clock
wire ps2_clock = clk_div[13];
wire cpu_clock = clk_div[2];
reg [13:0] clk_div;
always @(posedge ram_clock)
        clk_div <= clk_div + 14'd1;

// PLL to generate 32Mhz ram clock and 25Mhz video clock from MiSTs 27Mhz on board clock
wire pll_locked;
pll pll (
	 .inclk0 ( CLOCK_27[0]   ),
	 .locked ( pll_locked    ),        // PLL is running stable
	 .c0     ( pixel_clock   ),        // 25.175 MHz
	 .c1     ( ram_clock     ),        // 32 MHz
	 .c2     ( SDRAM_CLK     )         // 32 MHz slightly phase shiftet
);

endmodule
