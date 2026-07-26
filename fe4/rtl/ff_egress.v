// =============================================================================
// ff_egress - in-order output stage
//
// Pops up to 4 contiguous completed entries starting at out_seq, output lane
// = seq[1:0] (spec rotating-lane rule -> (D/4):1 mux per lane). A result
// arriving in this very cycle pops in the same cycle (FEOUT-bus bypass).
// PKTOUT is a registered output (spec).
// =============================================================================
module ff_egress #(
  parameter D   = 64,
  parameter AW  = 6,
  parameter SW  = 7,
  parameter NFE = 4
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [SW-1:0]       out_seq,
  input  wire [D-1:0]        resv_q,
  input  wire [D-1:0]        outp_q,
  input  wire [D-1:0]        res_now,
  input  wire [D*128-1:0]    rob_data_f,
  input  wire [D*2-1:0]      rob_src_f,     // FE each entry was issued to
  input  wire [NFE*128-1:0]  fe_od_f,
  output reg  [2:0]          pop_cnt,
  output reg  [D-1:0]        pop_oh,
  output reg  [3:0]          lane_v,        // registered PKTOUT valids
  output reg  [511:0]        lane_d_f       // registered PKTOUT data, 4 x 128
);

  // unpack
  wire [127:0] rob_data [0:D-1];
  wire [1:0]   rob_src  [0:D-1];
  wire [127:0] fe_od    [0:NFE-1];
  genvar gi;
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ur
      assign rob_data[gi] = rob_data_f[gi*128 +: 128];
      assign rob_src[gi]  = rob_src_f[gi*2 +: 2];
    end
    for (gi = 0; gi < NFE; gi = gi + 1) begin : g_uo
      assign fe_od[gi] = fe_od_f[gi*128 +: 128];
    end
  endgenerate

  // contiguous-completion check (pop bypass: same-cycle results count)
  wire [D-1:0] cmpl = resv_q | res_now;

  wire [AW-1:0] oidx0 = out_seq[AW-1:0];
  wire [AW-1:0] oidx1 = out_seq[AW-1:0] + 6'd1;
  wire [AW-1:0] oidx2 = out_seq[AW-1:0] + 6'd2;
  wire [AW-1:0] oidx3 = out_seq[AW-1:0] + 6'd3;
  wire can0 = cmpl[oidx0] & ~outp_q[oidx0];
  wire can1 = cmpl[oidx1] & ~outp_q[oidx1];
  wire can2 = cmpl[oidx2] & ~outp_q[oidx2];
  wire can3 = cmpl[oidx3] & ~outp_q[oidx3];

  always @* begin
    pop_cnt = 3'd0;
    if (can0) begin
      pop_cnt = 3'd1;
      if (can1) begin
        pop_cnt = 3'd2;
        if (can2) begin
          pop_cnt = 3'd3;
          if (can3) pop_cnt = 3'd4;
        end
      end
    end
  end

  always @* begin
    pop_oh = {D{1'b0}};
    if (pop_cnt > 3'd0) pop_oh[oidx0] = 1'b1;
    if (pop_cnt > 3'd1) pop_oh[oidx1] = 1'b1;
    if (pop_cnt > 3'd2) pop_oh[oidx2] = 1'b1;
    if (pop_cnt > 3'd3) pop_oh[oidx3] = 1'b1;
  end

  // lane mapping + data mux with same-cycle result bypass
  reg [3:0]    out_act;
  reg [127:0]  out_dat [0:3];
  integer l;
  reg [1:0]     kl;
  reg [AW-1:0]  osrc, osi;
  always @* begin
    for (l = 0; l < 4; l = l + 1) begin
      kl         = l[1:0] - out_seq[1:0];
      out_act[l] = ({1'b0, kl} < pop_cnt);
      osrc       = out_seq[AW-1:0] + {4'b0, kl};
      osi        = {osrc[AW-1:2], l[1:0]};   // osrc[1:0]==l by construction
      out_dat[l] = res_now[osi] ? fe_od[rob_src[osi]] : rob_data[osi];
    end
  end

  // registered PKTOUT
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) lane_v <= 4'b0;
    else        lane_v <= out_act;
  end
  always @(posedge clk) begin
    for (l = 0; l < 4; l = l + 1)
      if (out_act[l]) lane_d_f[l*128 +: 128] <= out_dat[l];
  end

endmodule
