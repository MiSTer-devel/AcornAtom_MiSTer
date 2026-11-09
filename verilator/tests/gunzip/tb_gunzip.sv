// Unit test for rtl/gunzip.sv: feeds +in=<file> a byte at a time (honouring
// in_wait, with stalls when +stall is given), keeps the output in a RAM as the
// tape deck does, and writes it to +out=<file>.
module tb_gunzip;
localparam AW = 17;
reg clk = 0;
always #5 clk = ~clk;
reg start = 0, in_wr = 0, in_end = 0;
reg [7:0] in_data;
wire in_wait, out_wr, busy, gz, err;
wire [24:0] out_addr;
wire [7:0] out_data;
wire [AW-1:0] rd_addr;
reg  [7:0] rd_data;
reg  [7:0] mem [0:(1 << AW) - 1];
always @(posedge clk) begin
	if (out_wr && out_addr < (1 << AW)) mem[out_addr[AW-1:0]] <= out_data;
	rd_data <= mem[rd_addr];
end
gunzip #(.AW(AW)) dut(.clk(clk), .start(start), .in_wr(in_wr), .in_data(in_data), .in_end(in_end),
	.in_wait(in_wait), .out_wr(out_wr), .out_addr(out_addr), .out_data(out_data),
	.rd_addr(rd_addr), .rd_data(rd_data), .busy(busy), .gz(gz), .err(err));
reg [24:0] n = 0;
always @(posedge clk) if (out_wr) n <= out_addr + 1;
integer fi, fo, ch, i, stall, cycles;
string fin, fout;
initial begin
	if (!$value$plusargs("in=%s", fin) || !$value$plusargs("out=%s", fout)) $fatal(1, "+in= +out=");
	stall = $test$plusargs("stall");
	fi = $fopen(fin, "rb");
	@(posedge clk); start <= 1; @(posedge clk); start <= 0;
	cycles = 0;
	ch = $fgetc(fi);
	while (ch >= 0) begin
		@(posedge clk);
		if (!in_wait && (!stall || ($random & 3) == 0)) begin
			in_wr <= 1; in_data <= ch[7:0]; ch = $fgetc(fi);
			@(posedge clk); in_wr <= 0;
			// the HPS takes a while between bytes
			repeat (stall ? ($random & 7) : 2) @(posedge clk);
		end
	end
	@(posedge clk); in_end <= 1;
	while (busy) begin @(posedge clk); cycles++; end
	repeat (4) @(posedge clk);
	fo = $fopen(fout, "wb");
	for (i = 0; i < n && i < (1 << AW); i++) $fwrite(fo, "%c", mem[i]);
	$fclose(fo);
	$display("gz=%0d err=%0d bytes=%0d st=%0d bc=%0d fn=%0d", gz, err, n, dut.st, dut.bc, dut.f_n);
	$finish;
end
endmodule
