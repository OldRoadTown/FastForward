// =============================================================================
// ff_egress - in-order output stage
//
// RTL revision : 4FE-safe-v46
// Experiment   : E046-R64-IQ32-onehot-retire
// Based on     : 4FE-safe-v28 / E029-R32
// Changes      : registered-result retirement from a one-hot head window
//
// Pops up to 4 contiguous completed entries starting at out_seq, output lane
// = seq[1:0] (spec rotating-lane rule -> (D/4):1 mux per lane). A result
// is detected from registered result state. PKTOUT is registered.
// =============================================================================
module ff_egress #(
  parameter D   = 64,
  parameter AW  = 6,
  parameter SW  = 7,
  parameter NFE = 4
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [SW-1:0]       alloc_seq,
  input  wire [SW-1:0]       out_seq,
  input  wire [D-1:0]        out_oh,
  input  wire [D-1:0]        resv_q,
  input  wire [D*128-1:0]    rob_data_f,
  output reg  [2:0]          pop_cnt,
  output reg  [3:0]          lane_v,        // registered PKTOUT valids
  output reg  [511:0]        lane_d_f       // registered PKTOUT data, 4 x 128
);

  // unpack
  wire [127:0] rob_data [0:D-1];
  genvar gi;
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ur
      assign rob_data[gi] = rob_data_f[gi*128 +: 128];
    end
  endgenerate

  // Fixed rotations of the one-hot retirement head turn each completion read
  // into an AND plus a balanced OR tree. A result becomes eligible one cycle
  // after FEOUT, when ROB data and state have both been registered.
  wire [D-1:0] om0 = out_oh;
  wire [D-1:0] om1 = {out_oh[D-2:0], out_oh[D-1]};
  wire [D-1:0] om2 = {out_oh[D-3:0], out_oh[D-1:D-2]};
  wire [D-1:0] om3 = {out_oh[D-4:0], out_oh[D-1:D-3]};
  wire [SW-1:0] retire_avail = alloc_seq - out_seq;
  wire can0 = (retire_avail > 0) && |(resv_q & om0);
  wire can1 = (retire_avail > 1) && |(resv_q & om1);
  wire can2 = (retire_avail > 2) && |(resv_q & om2);
  wire can3 = (retire_avail > 3) && |(resv_q & om3);

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

  // Lane mapping. rob_data already contains the registered FE result when the
  // corresponding resv_q bit becomes visible, so no FEOUT bypass mux is used.
  reg [3:0]    out_act;
  reg [127:0]  out_dat [0:3];
  integer l;
  reg [1:0]     kl;
  reg [AW-1:0]  osrc, osi;
  always @* begin
    for (l = 0; l < 4; l = l + 1) begin
      kl         = l[1:0] - out_seq[1:0];
      out_act[l] = ({1'b0, kl} < pop_cnt);
      osrc       = out_seq[AW-1:0] + {{(AW-2){1'b0}}, kl};
      osi        = {osrc[AW-1:2], l[1:0]};   // osrc[1:0]==l by construction
      out_dat[l] = rob_data[osi];
    end
  end

  // registered PKTOUT
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) lane_v <= 4'b0;
    else        lane_v <= out_act;
  end
  always @(posedge clk) begin
    for (l = 0; l < 4; l = l + 1)
      // lane_v qualifies lane_d_f.  Always writing the data removes the
      // sched_idx/res_now -> out_act -> lane_d clock-gate enable path.
      lane_d_f[l*128 +: 128] <= out_dat[l];
  end

endmodule
