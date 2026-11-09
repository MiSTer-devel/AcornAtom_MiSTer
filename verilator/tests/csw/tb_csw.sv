// Unit test for rtl/csw_in.sv: feeds +in=<file> a byte at a time (honouring
// in_wait, with stalls when +stall is given, a byte every clock with +fast
// as the simulator's bus does), keeps the UEF it writes in a RAM
// as the tape deck does, and writes that to +out=<file>.
module tb_csw;
localparam AW = 17;
reg clk = 0;
always #5 clk = ~clk;
reg start = 0, in_wr = 0, in_end = 0;
reg [7:0] in_data;
wire in_wait, out_wr, busy, err;
wire [24:0] out_addr;
wire [7:0] out_data;
reg  [7:0] mem [0:(1 << AW) - 1];
always @(posedge clk) if (out_wr && out_addr < (1 << AW)) mem[out_addr[AW-1:0]] <= out_data;
csw_in dut(.clk(clk), .start(start), .in_wr(in_wr), .in_data(in_data), .in_end(in_end),
	.in_wait(in_wait), .out_wr(out_wr), .out_addr(out_addr), .out_data(out_data),
	.busy(busy), .err(err));
reg [24:0] n = 0;
always @(posedge clk) if (out_wr) n <= out_addr + 1;
integer fi, fo, ch, i, stall, fast;
string fin, fout;
initial begin
	if (!$value$plusargs("in=%s", fin) || !$value$plusargs("out=%s", fout)) $fatal(1, "+in= +out=");
	stall = $test$plusargs("stall");
	fast = $test$plusargs("fast");
	fi = $fopen(fin, "rb");
	@(posedge clk); start <= 1; @(posedge clk); start <= 0;
	ch = $fgetc(fi);
	while (ch >= 0) begin
		@(posedge clk);
		if (!in_wait && (!stall || ($random & 3) == 0)) begin
			in_wr <= 1; in_data <= ch[7:0]; ch = $fgetc(fi);
			if (!fast) begin
				@(posedge clk); in_wr <= 0;
				repeat (stall ? ($random & 7) : 2) @(posedge clk);
			end
		end
		else in_wr <= 0;
	end
	@(posedge clk); in_wr <= 0; in_end <= 1;
	while (busy) @(posedge clk);
	repeat (4) @(posedge clk);
	fo = $fopen(fout, "wb");
	for (i = 0; i < n && i < (1 << AW); i++) $fwrite(fo, "%c", mem[i]);
	$fclose(fo);
	$display("err=%0d bytes=%0d", err, n);
	$finish;
end
endmodule
