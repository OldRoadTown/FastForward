// =============================================================================
// ff_issue - I1 issue stage (4-FE work-stealing variant)
//
// Reads packet data / dependency data from the ROB, drives FEIN with the
// packet's true latency (dynamic because of stealing). dp_data is bypassed
// from the FEOUT bus when the
// target's result arrives in this very cycle (pre-wake support).
// REG_FEIN=1 inserts an output register stage (timing fallback); the tag
// pipe (issue_v/issue_idx) is always fed FEIN-cycle aligned.
// =============================================================================
module ff_issue #(
  parameter D        = 64,
  parameter AW       = 6,
  parameter NFE      = 4,
  parameter REG_FEIN = 0
)(
  input  wire                    clk,
  input  wire                    rst_n,
  // picks (I0 registered)
  input  wire [NFE-1:0]          pk_v_q,
  input  wire [NFE*AW-1:0]       pk_idx_f,
  input  wire [NFE*2-1:0]        pk_lat_f,
  // ROB read view
  input  wire [D*128-1:0]        rob_data_f,
  input  wire [D*2-1:0]          rob_src_f,     // FE each entry was issued to
  input  wire [D*AW-1:0]         rob_tgt_f,
  input  wire [D-1:0]            rob_isdep,
  // same-cycle result bypass
  input  wire [D-1:0]            res_now,
  input  wire [NFE*128-1:0]      fe_od_f,
  // FEIN
  output wire [NFE-1:0]          fwd_v,
  output wire [NFE*128-1:0]      fwd_d_f,
  output wire [NFE*2-1:0]        fwd_l_f,       // dynamic lat (stealing)
  output wire [NFE-1:0]          fwd_dpv,
  output wire [NFE*128-1:0]      fwd_dpd_f,
  // FEIN-cycle-aligned issue view for the tag tracker
  output wire [NFE-1:0]          issue_v,
  output wire [NFE*AW-1:0]       issue_idx_f,
  output wire [NFE*2-1:0]        issue_lat_f
);

  // unpack
  wire [127:0]  rob_data [0:D-1];
  wire [1:0]    rob_src  [0:D-1];
  wire [AW-1:0] rob_tgt  [0:D-1];
  wire [127:0]  fe_od    [0:NFE-1];
  wire [AW-1:0] pk_idx   [0:NFE-1];
  wire [1:0]    pk_lat   [0:NFE-1];
  genvar gi;
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ur
      assign rob_data[gi] = rob_data_f[gi*128 +: 128];
      assign rob_src[gi]  = rob_src_f[gi*2 +: 2];
      assign rob_tgt[gi]  = rob_tgt_f[gi*AW +: AW];
    end
    for (gi = 0; gi < NFE; gi = gi + 1) begin : g_uo
      assign fe_od[gi]  = fe_od_f[gi*128 +: 128];
      assign pk_idx[gi] = pk_idx_f[gi*AW +: AW];
      assign pk_lat[gi] = pk_lat_f[gi*2 +: 2];
    end
  endgenerate

  wire         fein_v   [0:NFE-1];
  wire [127:0] fein_d   [0:NFE-1];
  wire         fein_dpv [0:NFE-1];
  wire [127:0] fein_dpd [0:NFE-1];

  genvar gf;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_iss
      wire [AW-1:0] ridx = pk_idx[gf];
      wire [AW-1:0] tgt  = rob_tgt[ridx];
      assign fein_v[gf]   = pk_v_q[gf];
      assign fein_d[gf]   = rob_data[ridx];
      assign fein_dpv[gf] = rob_isdep[ridx];
      // dp bypass: target result may be on the FEOUT bus this very cycle
      assign fein_dpd[gf] = res_now[tgt] ? fe_od[rob_src[tgt]]
                                         : rob_data[tgt];
    end
  endgenerate

  generate
    if (REG_FEIN) begin : g_regfe
      reg [NFE-1:0] rv_q;
      reg [127:0]   rd_q   [0:NFE-1];
      reg [1:0]     rl_q   [0:NFE-1];
      reg           rdpv_q [0:NFE-1];
      reg [127:0]   rdpd_q [0:NFE-1];
      reg [AW-1:0]  ridx_q [0:NFE-1];
      integer rf;
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rv_q <= {NFE{1'b0}};
        else for (rf = 0; rf < NFE; rf = rf + 1) rv_q[rf] <= fein_v[rf];
      end
      always @(posedge clk) begin
        for (rf = 0; rf < NFE; rf = rf + 1) begin
          if (fein_v[rf]) begin
            rd_q[rf]   <= fein_d[rf];
            rl_q[rf]   <= pk_lat[rf];
            rdpv_q[rf] <= fein_dpv[rf];
            rdpd_q[rf] <= fein_dpd[rf];
            ridx_q[rf] <= pk_idx[rf];
          end
        end
      end
      for (gf = 0; gf < NFE; gf = gf + 1) begin : g_ro
        assign fwd_v[gf]                = rv_q[gf];
        assign fwd_d_f[gf*128 +: 128]   = rd_q[gf];
        assign fwd_l_f[gf*2 +: 2]       = rl_q[gf];
        assign fwd_dpv[gf]              = rdpv_q[gf];
        assign fwd_dpd_f[gf*128 +: 128] = rdpd_q[gf];
        assign issue_v[gf]              = rv_q[gf];
        assign issue_idx_f[gf*AW +: AW] = ridx_q[gf];
        assign issue_lat_f[gf*2 +: 2]   = rl_q[gf];
      end
    end else begin : g_combfe
      for (gf = 0; gf < NFE; gf = gf + 1) begin : g_co
        assign fwd_v[gf]                = fein_v[gf];
        assign fwd_d_f[gf*128 +: 128]   = fein_d[gf];
        assign fwd_l_f[gf*2 +: 2]       = pk_lat[gf];
        assign fwd_dpv[gf]              = fein_dpv[gf];
        assign fwd_dpd_f[gf*128 +: 128] = fein_dpd[gf];
        assign issue_v[gf]              = pk_v_q[gf];
        assign issue_idx_f[gf*AW +: AW] = pk_idx[gf];
        assign issue_lat_f[gf*2 +: 2]   = pk_lat[gf];
      end
    end
  endgenerate

endmodule
