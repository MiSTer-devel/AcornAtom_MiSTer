// Behavioural stand-in for the Altera altsyncram megafunction, covering what
// sys/sd_card.sv asks of it: BIDIR_DUAL_PORT, equal widths on both ports,
// each port's address registered on its own clock, unregistered outputs.
// Simulation only; every parameter sd_card.sv sets by defparam is declared so
// the elaboration does not fail, but only the sizes are used.
module altsyncram #(
	parameter numwords_a = 2048,
	parameter widthad_a  = 11,
	parameter width_a    = 8,
	parameter numwords_b = 2048,
	parameter widthad_b  = 11,
	parameter width_b    = 8,
	parameter width_byteena_a = 1,
	parameter width_byteena_b = 1,
	parameter address_reg_b = "CLOCK1",
	parameter clock_enable_input_a  = "BYPASS",
	parameter clock_enable_input_b  = "BYPASS",
	parameter clock_enable_output_a = "BYPASS",
	parameter clock_enable_output_b = "BYPASS",
	parameter indata_reg_b = "CLOCK1",
	parameter intended_device_family = "Cyclone V",
	parameter lpm_type = "altsyncram",
	parameter operation_mode = "BIDIR_DUAL_PORT",
	parameter outdata_aclr_a = "NONE",
	parameter outdata_aclr_b = "NONE",
	parameter outdata_reg_a = "UNREGISTERED",
	parameter outdata_reg_b = "UNREGISTERED",
	parameter power_up_uninitialized = "FALSE",
	parameter read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
	parameter read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
	parameter read_during_write_mode_mixed_ports = "DONT_CARE",
	parameter wrcontrol_wraddress_reg_b = "CLOCK1",
	parameter init_file = "",
	parameter ram_block_type = "AUTO"
) (
	input                  clock0,
	input  [widthad_a-1:0] address_a,
	input  [width_a-1:0]   data_a,
	input                  wren_a,
	output [width_a-1:0]   q_a,
	input                  clock1,
	input  [widthad_b-1:0] address_b,
	input  [width_b-1:0]   data_b,
	input                  wren_b,
	output [width_b-1:0]   q_b,
	input                  aclr0,
	input                  aclr1,
	input                  addressstall_a,
	input                  addressstall_b,
	input  [width_byteena_a-1:0] byteena_a,
	input  [width_byteena_b-1:0] byteena_b,
	input                  clocken0,
	input                  clocken1,
	input                  clocken2,
	input                  clocken3,
	output [1:0]           eccstatus,
	input                  rden_a,
	input                  rden_b
);

reg [width_a-1:0]   mem [0:numwords_a-1];
reg [widthad_a-1:0] addr_a_r;
reg [widthad_b-1:0] addr_b_r;

always @(posedge clock0) begin
	if (wren_a) mem[address_a] <= data_a;
	addr_a_r <= address_a;
end

always @(posedge clock1) begin
	if (wren_b) mem[address_b] <= data_b;
	addr_b_r <= address_b;
end

assign q_a = mem[addr_a_r];
assign q_b = mem[addr_b_r];
assign eccstatus = 2'b00;

endmodule
