// =============================================================================
// ff_sched - per-FE 4-slot result scheduler (4-FE work-stealing variant)
//
// RTL revision : 4FE-safe-v72a
// Experiment   : E072A-R32-completion-spill
// Based on     : E068-R32-dynamic-bkpr-credit
// Changes      : track full tags/physical ownership and one-hot fast prediction
//
// During cycle x, slot s (1..4) holds a result exiting at cycle x+(s-1);
// an issue during cycle u with lat class c books slot c+1 -> exact
// output-collision bookkeeping even for mixed-latency (stolen) streams.
//   exit = slot1, prediction (exit next cycle) = slot2 plus a latency-zero
//   packet issued this cycle. sched_v is exported for the pick stage's
//   slot-conflict checks.
// =============================================================================
module ff_sched #(
  parameter AW  = 6,
  parameter PW  = 5,
  parameter D   = 32,
  parameter NFE = 4
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [NFE-1:0]      issue_v,
  input  wire [NFE*AW-1:0]   issue_idx_f,
  input  wire [NFE*D-1:0]    issue_oh_f,
  input  wire [NFE*2-1:0]    issue_lat_f,
  input  wire [D-1:0]        alloc_oh,
  output wire [NFE-1:0]      exit_v,
  output wire [NFE-1:0]      exit_phys,
  output wire [NFE*AW-1:0]   exit_idx_f,
  output wire [NFE-1:0]      pre_v,
  output wire [NFE-1:0]      pre_phys,
  output wire [NFE*AW-1:0]   pre_idx_f,
  output wire [D-1:0]        pre_fast_oh,
  output wire [NFE*4-1:0]    sched_v_f      // bit f*4+(s-1) = sched_v[f][s]
);

  wire [AW-1:0] issue_idx [0:NFE-1];
  wire [D-1:0]  issue_oh  [0:NFE-1];
  wire [1:0]    issue_lat [0:NFE-1];
  genvar gi;
  generate
    for (gi = 0; gi < NFE; gi = gi + 1) begin : g_ui
      assign issue_idx[gi] = issue_idx_f[gi*AW +: AW];
      assign issue_oh[gi]  = issue_oh_f[gi*D +: D];
      assign issue_lat[gi] = issue_lat_f[gi*2 +: 2];
    end
  endgenerate

  reg [4:1]    sched_v   [0:NFE-1];
  reg [4:1]    sched_phys[0:NFE-1];
  reg [AW-1:0] sched_idx [0:NFE-1][1:4];

  integer sf, sk;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (sf = 0; sf < NFE; sf = sf + 1) begin
        sched_v[sf]    <= 4'b0;
        sched_phys[sf] <= 4'b0;
      end
    end else begin
      for (sf = 0; sf < NFE; sf = sf + 1) begin
        for (sk = 1; sk <= 3; sk = sk + 1) begin
          sched_v[sf][sk] <= sched_v[sf][sk+1];
          sched_phys[sf][sk] <= sched_phys[sf][sk+1]
                                & ~alloc_oh[sched_idx[sf][sk+1][PW-1:0]];
        end
        sched_v[sf][4] <= 1'b0;
        sched_phys[sf][4] <= 1'b0;
        if (issue_v[sf]) begin
          sched_v[sf][{1'b0, issue_lat[sf]} + 3'd1] <= 1'b1;
          sched_phys[sf][{1'b0, issue_lat[sf]} + 3'd1]
              <= ~alloc_oh[issue_idx[sf][PW-1:0]];
        end
      end
    end
  end

  // Direct latency-zero prediction uses the one-hot selector already
  // registered by ff_pick.  This is the only combinational prediction source;
  // longer latencies use the registered slot2 tag below.
  reg [D-1:0] pre_fast_oh_r;
  integer pf;
  always @* begin
    pre_fast_oh_r = {D{1'b0}};
    for (pf = 0; pf < NFE; pf = pf + 1)
      if (!sched_v[pf][2] && issue_v[pf] && (issue_lat[pf] == 2'd0))
        pre_fast_oh_r = pre_fast_oh_r | issue_oh[pf];
  end
  assign pre_fast_oh = pre_fast_oh_r;
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
      // sched_phys is cleared when an allocation passes the tag between slots.
      // A replacement on the same edge as exit is handled by the ROB spill
      // create path, whose allocation write has priority over physical resv.
      // Avoiding a second live alloc_oh qualification keeps alloc_seq out of
      // the completion and wake cones.
      assign exit_phys[gf]           = sched_phys[gf][1];
      assign exit_idx_f[gf*AW +: AW] = sched_idx[gf][1];
      assign pre_v[gf]               = sched_v[gf][2];
      assign pre_phys[gf]            = sched_phys[gf][2];
      assign pre_idx_f[gf*AW +: AW]  = sched_idx[gf][2];
      assign sched_v_f[gf*4 +: 4]    = sched_v[gf];
    end
  endgenerate

endmodule
