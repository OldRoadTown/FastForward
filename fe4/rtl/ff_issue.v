// =============================================================================
// ff_issue - I1 issue stage (4-FE work-stealing variant)
//
// RTL revision : 4FE-safe-v72a
// Experiment   : E072A-R32-completion-spill
// Based on     : E068-R32-dynamic-bkpr-credit
// Changes      : read spilled dependency results and preserve one-hot issue tag
//
// Reads packet data / dependency data from the ROB, drives FEIN with the
// packet's true latency (dynamic because of stealing). dp_data is bypassed
// from the FEOUT bus when the target's result arrives in this very cycle
// (WAKE_BYPASS pre-wake support).  With WAKE_BYPASS=0, issue occurs only after
// the target result has been stored in the ROB, so that live bypass cone is
// compiled out without adding a pipeline cycle.
// REG_FEIN=1 inserts an output register stage (timing fallback); the tag
// pipe (issue_v/issue_idx) is always fed FEIN-cycle aligned.
// =============================================================================
module ff_issue #(
  parameter D        = 32,
  parameter AW       = 5,
  parameter SW       = 6,
  parameter NFE      = 4,
  parameter REG_FEIN = 0,
  parameter WAKE_BYPASS = 0
)(
  input  wire                    clk,
  input  wire                    rst_n,
  // picks (I0 registered)
  input  wire [NFE-1:0]          pk_v_q,
  input  wire [NFE*AW-1:0]       pk_idx_f,
  input  wire [NFE*SW-1:0]       pk_seq_f,
  input  wire [NFE*AW-1:0]       pk_tgt_f,
  input  wire [NFE*SW-1:0]       pk_tseq_f,
  input  wire [NFE*2-1:0]        pk_lat_f,
  input  wire [NFE*8-1:0]        pk_bank_oh_f,
  input  wire [NFE*8-1:0]        pk_local_oh_f,
  // ROB read view
  input  wire [D*128-1:0]        rob_data_f,
  input  wire [D-1:0]            rob_isdep,
  input  wire [3:0]              spill_v,
  input  wire [3:0]              spill_resv,
  input  wire [4*SW-1:0]         spill_seq_f,
  input  wire [4*128-1:0]        spill_data_f,
  // same-cycle result bypass
  input  wire [NFE*128-1:0]      fe_od_f,
  input  wire [NFE-1:0]          exit_v,
  input  wire [NFE*SW-1:0]       exit_idx_f,
  // FEIN
  output wire [NFE-1:0]          fwd_v,
  output wire [NFE*128-1:0]      fwd_d_f,
  output wire [NFE*2-1:0]        fwd_l_f,       // dynamic lat (stealing)
  output wire [NFE-1:0]          fwd_dpv,
  output wire [NFE*128-1:0]      fwd_dpd_f,
  // FEIN-cycle-aligned issue view for the tag tracker
  output wire [NFE-1:0]          issue_v,
  output wire [NFE*SW-1:0]       issue_idx_f,
  output wire [NFE*D-1:0]        issue_oh_f,
  output wire [NFE*2-1:0]        issue_lat_f
);

  // unpack
  wire [127:0]  rob_data [0:D-1];
  wire [127:0]  fe_od    [0:NFE-1];
  wire [AW-1:0] pk_idx   [0:NFE-1];
  wire [SW-1:0] pk_seq   [0:NFE-1];
  wire [AW-1:0] pk_tgt   [0:NFE-1];
  wire [SW-1:0] pk_tseq  [0:NFE-1];
  wire [1:0]    pk_lat   [0:NFE-1];
  wire [7:0]    pk_bank_oh [0:NFE-1];
  wire [7:0]    pk_local_oh [0:NFE-1];
  wire [SW-1:0] exit_seq [0:NFE-1];
  wire [SW-1:0] spill_seq [0:3];
  wire [127:0] spill_data [0:3];
  genvar gi;
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ur
      assign rob_data[gi] = rob_data_f[gi*128 +: 128];
    end
    for (gi = 0; gi < NFE; gi = gi + 1) begin : g_uo
      assign fe_od[gi]  = fe_od_f[gi*128 +: 128];
      assign pk_idx[gi] = pk_idx_f[gi*AW +: AW];
      assign pk_seq[gi] = pk_seq_f[gi*SW +: SW];
      assign pk_tgt[gi] = pk_tgt_f[gi*AW +: AW];
      assign pk_tseq[gi] = pk_tseq_f[gi*SW +: SW];
      assign pk_lat[gi] = pk_lat_f[gi*2 +: 2];
      assign pk_bank_oh[gi] = pk_bank_oh_f[gi*8 +: 8];
      assign pk_local_oh[gi] = pk_local_oh_f[gi*8 +: 8];
      assign exit_seq[gi] = exit_idx_f[gi*SW +: SW];
    end
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_usp
      assign spill_seq[gi] = spill_seq_f[gi*SW +: SW];
      assign spill_data[gi] = spill_data_f[gi*128 +: 128];
    end
  endgenerate

  wire         fein_v   [0:NFE-1];
  wire [127:0] fein_d   [0:NFE-1];
  wire         fein_dpv [0:NFE-1];
  wire [127:0] fein_dpd [0:NFE-1];
  wire [D-1:0] issue_sel_oh [0:NFE-1];

  genvar gf, gb, gl;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_iss
      wire [AW-1:0] ridx = pk_idx[gf];
      wire [127:0] bank_data [0:3];
      for (gb = 0; gb < 4; gb = gb + 1) begin : g_bank_read
        assign bank_data[gb] =
          (rob_data[gb*8+0] & {128{pk_local_oh[gf][0]}})
        | (rob_data[gb*8+1] & {128{pk_local_oh[gf][1]}})
        | (rob_data[gb*8+2] & {128{pk_local_oh[gf][2]}})
        | (rob_data[gb*8+3] & {128{pk_local_oh[gf][3]}})
        | (rob_data[gb*8+4] & {128{pk_local_oh[gf][4]}})
        | (rob_data[gb*8+5] & {128{pk_local_oh[gf][5]}})
        | (rob_data[gb*8+6] & {128{pk_local_oh[gf][6]}})
        | (rob_data[gb*8+7] & {128{pk_local_oh[gf][7]}});
      end
      wire [127:0] packet_data =
          (bank_data[0] & {128{pk_bank_oh[gf][0]}})
        | (bank_data[1] & {128{pk_bank_oh[gf][1]}})
        | (bank_data[2] & {128{pk_bank_oh[gf][2]}})
        | (bank_data[3] & {128{pk_bank_oh[gf][3]}});
      // The picker already registers both hierarchy coordinates. Preserve the
      // resulting physical one-hot alongside the binary logical tag so the
      // latency-zero wake path does not rebuild a 5-to-32 decoder.
      for (gb = 0; gb < D/8; gb = gb + 1) begin : g_issue_bank_oh
        for (gl = 0; gl < 8; gl = gl + 1) begin : g_issue_local_oh
          assign issue_sel_oh[gf][gb*8+gl] = pk_bank_oh[gf][gb]
                                               & pk_local_oh[gf][gl];
        end
      end
      // pk_tgt was read and registered beside pk_idx in I0.  The I1 FE-input
      // path therefore contains only the target-data read, not two cascaded
      // 32-entry muxes (packet->target followed by target->data).
      wire [AW-1:0] tgt  = pk_tgt[gf];
      wire [SW-1:0] tseq = pk_tseq[gf];
      wire spill_tgt = spill_v[tseq[1:0]]
                       && spill_resv[tseq[1:0]]
                       && (spill_seq[tseq[1:0]] == tseq);
      wire [127:0] stored_dp = spill_tgt ? spill_data[tseq[1:0]]
                                         : rob_data[tgt];
      assign fein_v[gf]   = pk_v_q[gf];
      assign fein_d[gf]   = packet_data;
      assign fein_dpv[gf] = rob_isdep[ridx];
      if (WAKE_BYPASS == 0) begin : g_stored_dp
        // Without same-cycle wake-to-pick bypass, the target result is written
        // to rob_data one edge before this packet reaches issue.  Reading the
        // retained copy is therefore exact and removes res_now/rob_src/FEOUT
        // selection from the safe-profile FE input timing path.
        assign fein_dpd[gf] = stored_dp;
      end else begin : g_live_dp
        // Full-throughput profile: a pre-woken packet may enter the FE in the
        // same cycle as its target result and must consume the live FEOUT bus.
        reg target_now;
        reg [127:0] target_now_data;
        integer rf;
        always @* begin
          target_now = 1'b0;
          target_now_data = 128'b0;
          for (rf = 0; rf < NFE; rf = rf + 1)
            if (exit_v[rf] && (exit_seq[rf] == tseq)) begin
              target_now = 1'b1;
              target_now_data = fe_od[rf];
            end
        end
        assign fein_dpd[gf] = target_now ? target_now_data : stored_dp;
      end
    end
  endgenerate

  generate
    if (REG_FEIN) begin : g_regfe
      reg [NFE-1:0] rv_q;
      reg [127:0]   rd_q   [0:NFE-1];
      reg [1:0]     rl_q   [0:NFE-1];
      reg           rdpv_q [0:NFE-1];
      reg [127:0]   rdpd_q [0:NFE-1];
      reg [SW-1:0]  rseq_q [0:NFE-1];
      reg [D-1:0]   rsel_q [0:NFE-1];
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
            rseq_q[rf] <= pk_seq[rf];
            rsel_q[rf] <= issue_sel_oh[rf];
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
        assign issue_idx_f[gf*SW +: SW] = rseq_q[gf];
        assign issue_oh_f[gf*D +: D]     = rsel_q[gf];
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
        assign issue_idx_f[gf*SW +: SW] = pk_seq[gf];
        assign issue_oh_f[gf*D +: D]     = issue_sel_oh[gf];
        assign issue_lat_f[gf*2 +: 2]   = pk_lat[gf];
      end
    end
  endgenerate

endmodule
