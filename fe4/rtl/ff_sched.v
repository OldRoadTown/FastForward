// =============================================================================
// ff_sched - per-FE 4-slot result scheduler (4-FE work-stealing variant)
//
// During cycle x, slot s (1..4) holds a result exiting at cycle x+(s-1);
// an issue during cycle u with lat class c books slot c+1 -> exact
// output-collision bookkeeping even for mixed-latency (stolen) streams.
//   exit = slot1, prediction (exit next cycle) = slot2 (plus a lat-class-0
//   packet issuing this cycle). sched_v is exported for the pick stage's
//   slot-conflict checks.
// =============================================================================
module ff_sched #(
  parameter AW  = 5,
  parameter NFE = 4
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [NFE-1:0]      issue_v,
  input  wire [NFE*AW-1:0]   issue_idx_f,
  input  wire [NFE*2-1:0]    issue_lat_f,
  output wire [NFE-1:0]      exit_v,
  output wire [NFE*AW-1:0]   exit_idx_f,
  output wire [NFE-1:0]      pre_v,
  output wire [NFE*AW-1:0]   pre_idx_f,
  output wire [NFE*4-1:0]    sched_v_f      // bit f*4+(s-1) = sched_v[f][s]
);

  wire [AW-1:0] issue_idx [0:NFE-1];
  wire [1:0]    issue_lat [0:NFE-1];
  genvar gi;
  generate
    for (gi = 0; gi < NFE; gi = gi + 1) begin : g_ui
      assign issue_idx[gi] = issue_idx_f[gi*AW +: AW];
      assign issue_lat[gi] = issue_lat_f[gi*2 +: 2];
    end
  endgenerate

  reg [4:1]    sched_v   [0:NFE-1];
  reg [AW-1:0] sched_idx [0:NFE-1][1:4];

  integer sf, sk;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (sf = 0; sf < NFE; sf = sf + 1) sched_v[sf] <= 4'b0;
    end else begin
      for (sf = 0; sf < NFE; sf = sf + 1) begin
        for (sk = 1; sk <= 3; sk = sk + 1)
          sched_v[sf][sk] <= sched_v[sf][sk+1];
        sched_v[sf][4] <= 1'b0;
        if (issue_v[sf])
          sched_v[sf][{1'b0, issue_lat[sf]} + 3'd1] <= 1'b1;
      end
    end
  end
  always @(posedge clk) begin
    for (sf = 0; sf < NFE; sf = sf + 1) begin
      for (sk = 1; sk <= 3; sk = sk + 1)
        sched_idx[sf][sk] <= sched_idx[sf][sk+1];
      if (issue_v[sf])
        sched_idx[sf][{1'b0, issue_lat[sf]} + 3'd1] <= issue_idx[sf];
    end
  end

  genvar gf;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_exit
      assign exit_v[gf]              = sched_v[gf][1];
      assign exit_idx_f[gf*AW +: AW] = sched_idx[gf][1];
      // lat-class-0 issue this cycle also exits next cycle
      assign pre_v[gf]               = sched_v[gf][2]
                                     | (issue_v[gf] & (issue_lat[gf] == 2'd0));
      assign pre_idx_f[gf*AW +: AW]  = sched_v[gf][2] ? sched_idx[gf][2]
                                                      : issue_idx[gf];
      assign sched_v_f[gf*4 +: 4]    = sched_v[gf];
    end
  endgenerate

endmodule
