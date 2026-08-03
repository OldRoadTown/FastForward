// =============================================================================
// fast_forward top (4-FE work-stealing variant, integrated) -- Verilog-2001
//
// RTL revision : 4FE-safe-v20
// Experiment   : E021-N1
// Based on     : 4FE-safe-v15 / E016-N1
// Changes      : use fixed-order one-hot bank selection in the safe picker
//
// Score-driven design: score = (1/T)^4 * (1/Power) * (1/Area), Tclk >= 0.4ns
//
// Fixed integration contract: ff exposes only PKTIN, PKTOUT, and BKPR.  FEIN
// and FEOUT stay internal; the top instantiates four forwarding engines.
//
// Top level flattens/unflattens ports and instantiates the stages:
//   ff_ingress  S0/S1: PKTIN registers, compaction, dependency resolve, alloc
//               (+ critical-target marking info)
//   ff_rob      ROB storage/state (+critical flags), wake-up, counters,
//               oldest pointer, BKPR
//   ff_pick     I0: per-class dual pick (parity PEs) + critical-first
//               priority + work stealing (<=2/cycle) + rob_src record
//   ff_issue    I1: ROB data/dp read, dynamic-lat FEIN drive (REG_FEIN)
//   ff_sched    per-FE 4-slot result scheduler (exact output-slot booking)
//   FE x4        integrated forwarding engines
//   ff_egress   in-order rotating-lane output, PKTOUT registers
//
// Architecture summary (details in docs/design_spec.md):
//   4 FEs, primary latency-class binding + work stealing with exact
//   output-slot bookkeeping, 64-entry unified-storage ROB, out-of-order
//   issue / in-order output, pre-wake (dependent enters the FE in the same
//   cycle its target result appears on FEOUT), critical-first pick,
//   retained results + dual BKPR windows.
// =============================================================================
module ff #(
  parameter REG_FEIN    = 0,
  parameter WAKE_BYPASS = 0,
  parameter DUAL_STEAL  = 0
)(
  input  wire         clk,
  input  wire         rst_n,

  // ------------------------- PKTIN --------------------------------
  input  wire         lane0_pkt_in_vld,
  input  wire [127:0] lane0_pkt_in_data,
  input  wire [4:0]   lane0_pkt_in_ctrl,
  input  wire         lane1_pkt_in_vld,
  input  wire [127:0] lane1_pkt_in_data,
  input  wire [4:0]   lane1_pkt_in_ctrl,
  input  wire         lane2_pkt_in_vld,
  input  wire [127:0] lane2_pkt_in_data,
  input  wire [4:0]   lane2_pkt_in_ctrl,
  input  wire         lane3_pkt_in_vld,
  input  wire [127:0] lane3_pkt_in_data,
  input  wire [4:0]   lane3_pkt_in_ctrl,

  // ------------------------- PKTOUT -------------------------------
  output wire         lane0_pkt_out_vld,
  output wire [127:0] lane0_pkt_out_data,
  output wire         lane1_pkt_out_vld,
  output wire [127:0] lane1_pkt_out_data,
  output wire         lane2_pkt_out_vld,
  output wire [127:0] lane2_pkt_out_data,
  output wire         lane3_pkt_out_vld,
  output wire [127:0] lane3_pkt_out_data,

  // ------------------------- BKPR ---------------------------------
  output wire         pkt_in_bkpr
);

  localparam D   = 64;
  localparam AW  = 6;
  localparam SW  = 7;
  localparam NFE = 4;

  // -------------------------------------------------------------------------
  // flatten external buses
  // -------------------------------------------------------------------------
  wire [3:0]   in_vld = {lane3_pkt_in_vld, lane2_pkt_in_vld,
                         lane1_pkt_in_vld, lane0_pkt_in_vld};
  wire [511:0] in_data_f = {lane3_pkt_in_data, lane2_pkt_in_data,
                            lane1_pkt_in_data, lane0_pkt_in_data};
  wire [19:0]  in_ctrl_f = {lane3_pkt_in_ctrl, lane2_pkt_in_ctrl,
                            lane1_pkt_in_ctrl, lane0_pkt_in_ctrl};

  wire         fwded0_pkt_data_vld;
  wire [127:0] fwded0_pkt_data;
  wire         fwded1_pkt_data_vld;
  wire [127:0] fwded1_pkt_data;
  wire         fwded2_pkt_data_vld;
  wire [127:0] fwded2_pkt_data;
  wire         fwded3_pkt_data_vld;
  wire [127:0] fwded3_pkt_data;

  wire [NFE-1:0]     fe_ov  = {fwded3_pkt_data_vld, fwded2_pkt_data_vld,
                               fwded1_pkt_data_vld, fwded0_pkt_data_vld};
  wire [NFE*128-1:0] fe_od_f = {fwded3_pkt_data, fwded2_pkt_data,
                                fwded1_pkt_data, fwded0_pkt_data};

  // -------------------------------------------------------------------------
  // inter-stage wires
  // -------------------------------------------------------------------------
  wire [2:0]          acnt;
  wire [511:0]        slot_dat_f;
  wire [7:0]          slot_lat_f;
  wire [4*AW-1:0]     slot_tgt_f;
  wire [3:0]          slot_rdy, slot_wtg, slot_isdep;
  wire [D-1:0]        alloc_oh;
  wire [3:0]          kw_vld;
  wire [4*AW-1:0]     k_tgt_f;

  wire [D-1:0]        res_now, res_pred, res_known, wake_now;
  wire [D-1:0]        rdy_q, crit_q, resv_q, outp_q, rob_isdep;
  wire [D*128-1:0]    rob_data_f;
  wire [D*2-1:0]      rob_lat_f;
  wire [D*AW-1:0]     rob_tgt_f;
  wire [SW-1:0]       alloc_seq, out_seq, old_u;

  wire [D-1:0]        picked;
  wire [NFE-1:0]      pk_v_q;
  wire [NFE*AW-1:0]   pk_idx_f;
  wire [NFE*AW-1:0]   pk_tgt_f;
  wire [NFE*2-1:0]    pk_lat_f;
  wire [NFE*8-1:0]    pk_bank_oh_f;
  wire [NFE*8-1:0]    pk_local_oh_f;
  wire [D*2-1:0]      rob_src_f;

  wire [NFE-1:0]      issue_v;
  wire [NFE*AW-1:0]   issue_idx_f;
  wire [NFE*2-1:0]    issue_lat_f;
  wire [NFE-1:0]      exit_v, pre_v;
  wire [NFE*AW-1:0]   exit_idx_f, pre_idx_f;
  wire [NFE*4-1:0]    sched_v_f;

  wire [NFE-1:0]      fwd_v, fwd_dpv;
  wire [NFE*128-1:0]  fwd_d_f, fwd_dpd_f;
  wire [NFE*2-1:0]    fwd_l_f;

  wire [2:0]          pop_cnt;
  wire [D-1:0]        pop_oh;
  wire [3:0]          lane_v;
  wire [511:0]        lane_d_f;

  // -------------------------------------------------------------------------
  // stage instances
  // -------------------------------------------------------------------------
  ff_ingress #(.D(D), .AW(AW), .SW(SW)) u_ingress (
    .clk(clk), .rst_n(rst_n),
    .in_vld(in_vld), .in_data_f(in_data_f), .in_ctrl_f(in_ctrl_f),
    .alloc_seq(alloc_seq), .res_known(res_known),
    .acnt_o(acnt),
    .slot_dat_f(slot_dat_f), .slot_lat_f(slot_lat_f), .slot_tgt_f(slot_tgt_f),
    .slot_rdy_o(slot_rdy), .slot_wtg_o(slot_wtg), .slot_isdep_o(slot_isdep),
    .alloc_oh_o(alloc_oh),
    .kw_vld_o(kw_vld), .k_tgt_f(k_tgt_f)
  );

  ff_rob #(.D(D), .AW(AW), .SW(SW), .NFE(NFE)) u_rob (
    .clk(clk), .rst_n(rst_n),
    .acnt(acnt), .alloc_oh(alloc_oh),
    .slot_dat_f(slot_dat_f), .slot_lat_f(slot_lat_f), .slot_tgt_f(slot_tgt_f),
    .slot_rdy(slot_rdy), .slot_wtg(slot_wtg), .slot_isdep(slot_isdep),
    .kw_vld(kw_vld), .k_tgt_f(k_tgt_f),
    .exit_v(exit_v), .exit_idx_f(exit_idx_f),
    .pre_v(pre_v), .pre_idx_f(pre_idx_f),
    .fe_od_f(fe_od_f),
    .picked(picked), .rob_src_f(rob_src_f),
    .pop_oh(pop_oh), .pop_cnt(pop_cnt),
    .res_now_o(res_now), .res_pred_o(res_pred), .res_known_o(res_known),
    .wake_now_o(wake_now), .rdy_o(rdy_q), .crit_o(crit_q),
    .resv_o(resv_q), .outp_o(outp_q),
    .rob_data_f(rob_data_f), .rob_lat_f(rob_lat_f), .rob_tgt_f(rob_tgt_f),
    .rob_isdep_o(rob_isdep),
    .alloc_seq_o(alloc_seq), .out_seq_o(out_seq), .old_u_o(old_u),
    .bkpr_r(pkt_in_bkpr)
  );

  ff_pick #(.D(D), .AW(AW), .NFE(NFE),
            .WAKE_BYPASS(WAKE_BYPASS), .REG_FEIN(REG_FEIN),
            .DUAL_STEAL(DUAL_STEAL)) u_pick (
    .clk(clk), .rst_n(rst_n),
    .rdy_q(rdy_q), .wake_now(wake_now), .crit_q(crit_q),
    .rob_lat_f(rob_lat_f), .rob_tgt_f(rob_tgt_f),
    .rbase(old_u[AW-1:0]), .sched_v_f(sched_v_f),
    .picked(picked), .pk_v_q(pk_v_q),
    .pk_idx_f(pk_idx_f), .pk_tgt_f(pk_tgt_f),
    .pk_lat_f(pk_lat_f), .pk_bank_oh_f(pk_bank_oh_f),
    .pk_local_oh_f(pk_local_oh_f), .rob_src_f(rob_src_f)
  );

  ff_issue #(.D(D), .AW(AW), .NFE(NFE), .REG_FEIN(REG_FEIN),
             .WAKE_BYPASS(WAKE_BYPASS)) u_issue (
    .clk(clk), .rst_n(rst_n),
    .pk_v_q(pk_v_q), .pk_idx_f(pk_idx_f), .pk_tgt_f(pk_tgt_f),
    .pk_lat_f(pk_lat_f), .pk_bank_oh_f(pk_bank_oh_f),
    .pk_local_oh_f(pk_local_oh_f),
    .rob_data_f(rob_data_f), .rob_src_f(rob_src_f),
    .rob_isdep(rob_isdep),
    .res_now(res_now), .fe_od_f(fe_od_f),
    .fwd_v(fwd_v), .fwd_d_f(fwd_d_f), .fwd_l_f(fwd_l_f),
    .fwd_dpv(fwd_dpv), .fwd_dpd_f(fwd_dpd_f),
    .issue_v(issue_v), .issue_idx_f(issue_idx_f), .issue_lat_f(issue_lat_f)
  );

  ff_sched #(.AW(AW), .NFE(NFE)) u_sched (
    .clk(clk), .rst_n(rst_n),
    .issue_v(issue_v), .issue_idx_f(issue_idx_f), .issue_lat_f(issue_lat_f),
    .exit_v(exit_v), .exit_idx_f(exit_idx_f),
    .pre_v(pre_v), .pre_idx_f(pre_idx_f),
    .sched_v_f(sched_v_f)
  );

  // -------------------------------------------------------------------------
  // integrated forwarding engines
  // -------------------------------------------------------------------------
  FE u_fe0 (
    .clk(clk), .rst_n(rst_n),
    .fwd_pkt_data_vld(fwd_v[0]),
    .fwd_pkt_data(fwd_d_f[0*128 +: 128]),
    .fwd_pkt_lat(fwd_l_f[0*2 +: 2]),
    .fwd_pkt_dp_vld(fwd_dpv[0]),
    .fwd_pkt_dp_data(fwd_dpd_f[0*128 +: 128]),
    .fwded_pkt_data_vld(fwded0_pkt_data_vld),
    .fwded_pkt_data(fwded0_pkt_data)
  );

  FE u_fe1 (
    .clk(clk), .rst_n(rst_n),
    .fwd_pkt_data_vld(fwd_v[1]),
    .fwd_pkt_data(fwd_d_f[1*128 +: 128]),
    .fwd_pkt_lat(fwd_l_f[1*2 +: 2]),
    .fwd_pkt_dp_vld(fwd_dpv[1]),
    .fwd_pkt_dp_data(fwd_dpd_f[1*128 +: 128]),
    .fwded_pkt_data_vld(fwded1_pkt_data_vld),
    .fwded_pkt_data(fwded1_pkt_data)
  );

  FE u_fe2 (
    .clk(clk), .rst_n(rst_n),
    .fwd_pkt_data_vld(fwd_v[2]),
    .fwd_pkt_data(fwd_d_f[2*128 +: 128]),
    .fwd_pkt_lat(fwd_l_f[2*2 +: 2]),
    .fwd_pkt_dp_vld(fwd_dpv[2]),
    .fwd_pkt_dp_data(fwd_dpd_f[2*128 +: 128]),
    .fwded_pkt_data_vld(fwded2_pkt_data_vld),
    .fwded_pkt_data(fwded2_pkt_data)
  );

  FE u_fe3 (
    .clk(clk), .rst_n(rst_n),
    .fwd_pkt_data_vld(fwd_v[3]),
    .fwd_pkt_data(fwd_d_f[3*128 +: 128]),
    .fwd_pkt_lat(fwd_l_f[3*2 +: 2]),
    .fwd_pkt_dp_vld(fwd_dpv[3]),
    .fwd_pkt_dp_data(fwd_dpd_f[3*128 +: 128]),
    .fwded_pkt_data_vld(fwded3_pkt_data_vld),
    .fwded_pkt_data(fwded3_pkt_data)
  );

  ff_egress #(.D(D), .AW(AW), .SW(SW), .NFE(NFE)) u_egress (
    .clk(clk), .rst_n(rst_n),
    .out_seq(out_seq),
    .resv_q(resv_q), .outp_q(outp_q), .res_now(res_now),
    .rob_data_f(rob_data_f), .rob_src_f(rob_src_f), .fe_od_f(fe_od_f),
    .pop_cnt(pop_cnt), .pop_oh(pop_oh),
    .lane_v(lane_v), .lane_d_f(lane_d_f)
  );

  // -------------------------------------------------------------------------
  // unflatten external outputs
  // -------------------------------------------------------------------------
  assign lane0_pkt_out_vld  = lane_v[0];
  assign lane1_pkt_out_vld  = lane_v[1];
  assign lane2_pkt_out_vld  = lane_v[2];
  assign lane3_pkt_out_vld  = lane_v[3];
  assign lane0_pkt_out_data = lane_d_f[0*128 +: 128];
  assign lane1_pkt_out_data = lane_d_f[1*128 +: 128];
  assign lane2_pkt_out_data = lane_d_f[2*128 +: 128];
  assign lane3_pkt_out_data = lane_d_f[3*128 +: 128];

`ifndef SYNTHESIS
  // internal consistency: FE result valids must match the booked schedule
  integer f;
  always @(posedge clk) begin
    if (rst_n) begin
      for (f = 0; f < NFE; f = f + 1) begin
        if (exit_v[f] !== fe_ov[f])
          $display("[ff] ERROR: FE%0d result valid mismatch @%0t", f, $time);
      end
    end
  end
`endif

endmodule
