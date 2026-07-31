// =============================================================================
// fast_forward top -- module name: dut
//
// Score uses unified-suite execution time T:
// Score = 1/(T^2*sqrt(Area*Power)); equivalent Cost = T^4*Area*Power.
//
// Key architecture decisions (see docs/design_spec.md):
//   * 8 Forwarding Engines, latency-class bound:
//       FE index f = {latclass[1:0], parity} = 2*L + p
//       - FE f only ever receives packets whose latency field == L(f)=f/2.
//         => a same-latency stream NEVER collides at the FE output port,
//            no busy/slot tracking logic needed at all.
//       - parity p = ROB entry index bit0. Each ROB entry's result can come
//         from exactly one FE per latency value => tiny result write mux.
//   * 32-entry ROB (unified storage: input data overwritten by forwarded
//     result after issue -> single 128b register per packet).
//   * Out-of-order issue (dependents wait, independents fly past),
//     in-order output via ROB, output lane = seq[1:0] (spec rotating lanes).
//   * Dependency turnaround = result cycle + 1 (wake-up bypass on the FEOUT
//     tag-pipe exit, dependent issues the very next cycle carrying the
//     forwarded result of its target as dp_data).
//   * Backpressure windows guarantee a target's forwarded result is retained
//     in the ROB until every possible dependent (dep window = 7) has issued,
//     even if the target packet was already output.
//
// PKTIN registered before use; PKTOUT/BKPR registered outputs (spec).
// FEIN driven combinationally from pick registers (FEIN/FEOUT unconstrained);
// set REG_FEIN=1 to add an output register stage on FEIN if FE input timing
// closure requires it (costs +1 cycle latency, tag pipes auto-adjust).
// =============================================================================
module dut #(
  parameter bit REG_FEIN    = 1'b0,  // register FEIN outputs (adds 1 cycle)
  parameter bit WAKE_BYPASS = 1'b1   // pick a waking dependent in the same
                                     // cycle its target result returns
)(
  input  logic         clk,
  input  logic         rst_n,

  // ------------------------- PKTIN --------------------------------
  input  logic         lane0_pkt_in_vld,
  input  logic [127:0] lane0_pkt_in_data,
  input  logic [4:0]   lane0_pkt_in_ctrl,
  input  logic         lane1_pkt_in_vld,
  input  logic [127:0] lane1_pkt_in_data,
  input  logic [4:0]   lane1_pkt_in_ctrl,
  input  logic         lane2_pkt_in_vld,
  input  logic [127:0] lane2_pkt_in_data,
  input  logic [4:0]   lane2_pkt_in_ctrl,
  input  logic         lane3_pkt_in_vld,
  input  logic [127:0] lane3_pkt_in_data,
  input  logic [4:0]   lane3_pkt_in_ctrl,

  // ------------------------- PKTOUT -------------------------------
  output logic         lane0_pkt_out_vld,
  output logic [127:0] lane0_pkt_out_data,
  output logic         lane1_pkt_out_vld,
  output logic [127:0] lane1_pkt_out_data,
  output logic         lane2_pkt_out_vld,
  output logic [127:0] lane2_pkt_out_data,
  output logic         lane3_pkt_out_vld,
  output logic [127:0] lane3_pkt_out_data,

  // ------------------------- BKPR ---------------------------------
  output logic         pkt_in_bkpr,

  // ------------------------- FEIN (8 engines) ---------------------
  output logic         fwd0_pkt_data_vld,
  output logic [127:0] fwd0_pkt_data,
  output logic [1:0]   fwd0_pkt_lat,
  output logic         fwd0_pkt_dp_vld,
  output logic [127:0] fwd0_pkt_dp_data,
  output logic         fwd1_pkt_data_vld,
  output logic [127:0] fwd1_pkt_data,
  output logic [1:0]   fwd1_pkt_lat,
  output logic         fwd1_pkt_dp_vld,
  output logic [127:0] fwd1_pkt_dp_data,
  output logic         fwd2_pkt_data_vld,
  output logic [127:0] fwd2_pkt_data,
  output logic [1:0]   fwd2_pkt_lat,
  output logic         fwd2_pkt_dp_vld,
  output logic [127:0] fwd2_pkt_dp_data,
  output logic         fwd3_pkt_data_vld,
  output logic [127:0] fwd3_pkt_data,
  output logic [1:0]   fwd3_pkt_lat,
  output logic         fwd3_pkt_dp_vld,
  output logic [127:0] fwd3_pkt_dp_data,
  output logic         fwd4_pkt_data_vld,
  output logic [127:0] fwd4_pkt_data,
  output logic [1:0]   fwd4_pkt_lat,
  output logic         fwd4_pkt_dp_vld,
  output logic [127:0] fwd4_pkt_dp_data,
  output logic         fwd5_pkt_data_vld,
  output logic [127:0] fwd5_pkt_data,
  output logic [1:0]   fwd5_pkt_lat,
  output logic         fwd5_pkt_dp_vld,
  output logic [127:0] fwd5_pkt_dp_data,
  output logic         fwd6_pkt_data_vld,
  output logic [127:0] fwd6_pkt_data,
  output logic [1:0]   fwd6_pkt_lat,
  output logic         fwd6_pkt_dp_vld,
  output logic [127:0] fwd6_pkt_dp_data,
  output logic         fwd7_pkt_data_vld,
  output logic [127:0] fwd7_pkt_data,
  output logic [1:0]   fwd7_pkt_lat,
  output logic         fwd7_pkt_dp_vld,
  output logic [127:0] fwd7_pkt_dp_data,

  // ------------------------- FEOUT (8 engines) --------------------
  input  logic         fwded0_pkt_data_vld,
  input  logic [127:0] fwded0_pkt_data,
  input  logic         fwded1_pkt_data_vld,
  input  logic [127:0] fwded1_pkt_data,
  input  logic         fwded2_pkt_data_vld,
  input  logic [127:0] fwded2_pkt_data,
  input  logic         fwded3_pkt_data_vld,
  input  logic [127:0] fwded3_pkt_data,
  input  logic         fwded4_pkt_data_vld,
  input  logic [127:0] fwded4_pkt_data,
  input  logic         fwded5_pkt_data_vld,
  input  logic [127:0] fwded5_pkt_data,
  input  logic         fwded6_pkt_data_vld,
  input  logic [127:0] fwded6_pkt_data,
  input  logic         fwded7_pkt_data_vld,
  input  logic [127:0] fwded7_pkt_data
);

  // -------------------------------------------------------------------------
  // localparams
  // -------------------------------------------------------------------------
  localparam int unsigned D   = 64;      // ROB depth (throughput x lifetime)
  localparam int unsigned AW  = $clog2(D);   // ROB index width
  localparam int unsigned SW  = AW + 1;      // sequence counter width
  localparam int unsigned NFE = 8;

  // BKPR thresholds (see design_spec.md hazard-window derivation):
  //  * occupancy   : alloc may run at most 31 ahead of out_seq (entry reuse).
  //                  BKPR is a registered output and PKTIN must be registered
  //                  before use, so between the combinational decision and the
  //                  cycle the throttle takes effect there are TWO cycles of
  //                  unaccounted in-flight input (up to 8 packets)
  //                  => assert when > 31-8 = 23.
  //  * issue window: an entry being re-allocated (seq n overwrites n-32)
  //                  kills the retained forwarded result needed by dependents
  //                  up to seq n-32+7. All of them must have ISSUED before the
  //                  overwrite => alloc may run at most (32-7)=25 ahead of the
  //                  oldest un-issued packet; with 8 in-flight + pointer lag
  //                  margin => assert when > 16.
  localparam logic [SW-1:0] OCC_TH = SW'(D - 9);   // (D-1) - 8 in-flight
  localparam logic [SW-1:0] WIN_TH = SW'(D - 19);  // (D-7) - 8 - pointer lag

  localparam int unsigned PLW = 133;     // {ctrl[4:0], data[127:0]}

  // -------------------------------------------------------------------------
  // helper functions
  // -------------------------------------------------------------------------
  function automatic logic [D-1:0] rotrD(input logic [D-1:0]  v,
                                         input logic [AW-1:0] s);
    logic [2*D-1:0] t;
    t = {v, v} >> s;
    return t[D-1:0];
  endfunction

  // priority encode from bit0: {found, position[AW-1:0]}
  function automatic logic [AW:0] peD(input logic [D-1:0] v);
    logic [AW:0] r;
    r = '0;
    for (int i = D-1; i >= 0; i--) begin
      if (v[i]) r = {1'b1, AW'(i)};
    end
    return r;
  endfunction

  // -------------------------------------------------------------------------
  // input packing + S0 input registers (PKTIN must be registered before use)
  // -------------------------------------------------------------------------
  logic [3:0]   in_vld;
  logic [127:0] in_data [4];
  logic [4:0]   in_ctrl [4];

  assign in_vld     = {lane3_pkt_in_vld, lane2_pkt_in_vld,
                       lane1_pkt_in_vld, lane0_pkt_in_vld};
  assign in_data[0] = lane0_pkt_in_data;
  assign in_data[1] = lane1_pkt_in_data;
  assign in_data[2] = lane2_pkt_in_data;
  assign in_data[3] = lane3_pkt_in_data;
  assign in_ctrl[0] = lane0_pkt_in_ctrl;
  assign in_ctrl[1] = lane1_pkt_in_ctrl;
  assign in_ctrl[2] = lane2_pkt_in_ctrl;
  assign in_ctrl[3] = lane3_pkt_in_ctrl;

  logic [3:0]   in_vld_q;
  logic [127:0] in_data_q [4];
  logic [4:0]   in_ctrl_q [4];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) in_vld_q <= '0;
    else        in_vld_q <= in_vld;
  end

  // datapath regs: enable-gated (clock-gating friendly), no reset
  always_ff @(posedge clk) begin
    for (int i = 0; i < 4; i++) begin
      if (in_vld[i]) begin
        in_data_q[i] <= in_data[i];
        in_ctrl_q[i] <= in_ctrl[i];
      end
    end
  end

  // -------------------------------------------------------------------------
  // ROB state
  // -------------------------------------------------------------------------
  logic [127:0]  rob_data  [D];   // input data, overwritten by fwded result
  logic [1:0]    rob_lat   [D];
  logic [AW-1:0] rob_tgt   [D];   // dependency target entry index
  logic          rob_isdep [D];

  logic [D-1:0]  rdy_q;           // ready to issue, not yet picked
  logic [D-1:0]  wtg_q;           // waiting for dependency result
  logic [D-1:0]  iss_q;           // picked/issued
  logic [D-1:0]  resv_q;          // forwarded result present
  logic [D-1:0]  outp_q;          // output done (result retained for dp reads)

  logic [SW-1:0] alloc_seq_q;     // next sequence number to allocate
  logic [SW-1:0] out_seq_q;       // next sequence number to output
  logic [SW-1:0] old_u_q;         // oldest un-issued sequence number

  // forward declarations
  logic [D-1:0]  res_now;         // a forwarded result is written this cycle
  logic [D-1:0]  picked;
  logic [D-1:0]  pop_oh;
  logic [2:0]    pop_cnt;

  // -------------------------------------------------------------------------
  // S1: allocation - compact valid lanes, assign sequence numbers,
  //     resolve initial dependency state
  // -------------------------------------------------------------------------
  logic [PLW-1:0] pl [4];
  logic [PLW-1:0] comp [4];       // compacted (packet-order) payloads
  logic [2:0]     acnt;

  assign pl[0] = {in_ctrl_q[0], in_data_q[0]};
  assign pl[1] = {in_ctrl_q[1], in_data_q[1]};
  assign pl[2] = {in_ctrl_q[2], in_data_q[2]};
  assign pl[3] = {in_ctrl_q[3], in_data_q[3]};

  always_comb begin
    comp[0] = pl[0]; comp[1] = pl[1]; comp[2] = pl[2]; comp[3] = pl[3];
    acnt    = 3'd0;
    unique case (in_vld_q)
      4'b0000: begin acnt = 3'd0; end
      4'b0001: begin acnt = 3'd1; comp[0] = pl[0]; end
      4'b0010: begin acnt = 3'd1; comp[0] = pl[1]; end
      4'b0100: begin acnt = 3'd1; comp[0] = pl[2]; end
      4'b1000: begin acnt = 3'd1; comp[0] = pl[3]; end
      4'b0011: begin acnt = 3'd2; comp[0] = pl[0]; comp[1] = pl[1]; end
      4'b0101: begin acnt = 3'd2; comp[0] = pl[0]; comp[1] = pl[2]; end
      4'b1001: begin acnt = 3'd2; comp[0] = pl[0]; comp[1] = pl[3]; end
      4'b0110: begin acnt = 3'd2; comp[0] = pl[1]; comp[1] = pl[2]; end
      4'b1010: begin acnt = 3'd2; comp[0] = pl[1]; comp[1] = pl[3]; end
      4'b1100: begin acnt = 3'd2; comp[0] = pl[2]; comp[1] = pl[3]; end
      4'b0111: begin acnt = 3'd3; comp[0] = pl[0]; comp[1] = pl[1]; comp[2] = pl[2]; end
      4'b1011: begin acnt = 3'd3; comp[0] = pl[0]; comp[1] = pl[1]; comp[2] = pl[3]; end
      4'b1101: begin acnt = 3'd3; comp[0] = pl[0]; comp[1] = pl[2]; comp[2] = pl[3]; end
      4'b1110: begin acnt = 3'd3; comp[0] = pl[1]; comp[1] = pl[2]; comp[2] = pl[3]; end
      4'b1111: begin acnt = 3'd4; comp[0] = pl[0]; comp[1] = pl[1]; comp[2] = pl[2]; comp[3] = pl[3]; end
    endcase
  end

  // per-packet (k = position in this cycle's packet order) attributes
  logic [1:0]    k_lat  [4];
  logic [2:0]    k_dep  [4];
  logic [AW-1:0] k_tgt  [4];
  logic          k_rdy  [4];
  logic          k_wtg  [4];
  logic          k_isdep[4];

  always_comb begin
    for (int k = 0; k < 4; k++) begin
      logic [SW-1:0] seq_k, tgt_k;
      logic          incyc, tgt_done;
      k_lat[k]   = comp[k][129:128];
      k_dep[k]   = comp[k][132:130];
      k_isdep[k] = (k_dep[k] != 3'd0);
      seq_k      = alloc_seq_q + SW'(k);
      tgt_k      = seq_k - SW'(k_dep[k]);
      k_tgt[k]   = tgt_k[AW-1:0];
      // target arriving in the same cycle (earlier lane) can't be done yet
      incyc      = k_isdep[k] && (k_dep[k] <= 3'(k));
      // retained-result lookup, incl. result arriving this very cycle
      tgt_done   = resv_q[tgt_k[AW-1:0]] | res_now[tgt_k[AW-1:0]]
                   | res_pred[tgt_k[AW-1:0]];
      k_rdy[k]   = !k_isdep[k] || (!incyc && tgt_done);
      k_wtg[k]   = ~k_rdy[k];
    end
  end

  // rotate packet-order slots so ROB entry e is only ever written from
  // fixed source slot e[1:0] (single-source input mux per entry)
  logic [PLW-1:0] slot_pl  [4];
  logic [1:0]     slot_lat [4];
  logic [AW-1:0]  slot_tgt [4];
  logic           slot_rdy [4];
  logic           slot_wtg [4];
  logic           slot_isdep [4];

  always_comb begin
    for (int j = 0; j < 4; j++) begin
      logic [1:0] k;
      k             = 2'(j) - alloc_seq_q[1:0];
      slot_pl[j]    = comp[k];
      slot_lat[j]   = k_lat[k];
      slot_tgt[j]   = k_tgt[k];
      slot_rdy[j]   = k_rdy[k];
      slot_wtg[j]   = k_wtg[k];
      slot_isdep[j] = k_isdep[k];
    end
  end

  logic [D-1:0] alloc_oh;
  always_comb begin
    alloc_oh = '0;
    for (int k = 0; k < 4; k++) begin
      logic [SW-1:0] seq_k;
      seq_k = alloc_seq_q + SW'(k);
      if (3'(k) < acnt) alloc_oh[seq_k[AW-1:0]] = 1'b1;
    end
  end

  // -------------------------------------------------------------------------
  // FEOUT: result buses, tag pipes, result write, wake-up
  // -------------------------------------------------------------------------
  logic [NFE-1:0] fe_ov;
  logic [127:0]   fe_od [NFE];

  assign fe_ov   = {fwded7_pkt_data_vld, fwded6_pkt_data_vld,
                    fwded5_pkt_data_vld, fwded4_pkt_data_vld,
                    fwded3_pkt_data_vld, fwded2_pkt_data_vld,
                    fwded1_pkt_data_vld, fwded0_pkt_data_vld};
  assign fe_od[0] = fwded0_pkt_data;
  assign fe_od[1] = fwded1_pkt_data;
  assign fe_od[2] = fwded2_pkt_data;
  assign fe_od[3] = fwded3_pkt_data;
  assign fe_od[4] = fwded4_pkt_data;
  assign fe_od[5] = fwded5_pkt_data;
  assign fe_od[6] = fwded6_pkt_data;
  assign fe_od[7] = fwded7_pkt_data;

  // issue signals (FEIN cycle aligned)
  logic [NFE-1:0] issue_v;
  logic [AW-1:0]  issue_idx [NFE];

  logic [NFE-1:0] exit_v;
  logic [AW-1:0]  exit_idx [NFE];
  logic [NFE-1:0] pre_v;
  logic [AW-1:0]  pre_idx [NFE];

  // per-FE tag delay line: FEIN valid at cycle t, latclass L -> FEOUT
  // valid at t + (L+1). Latency binding makes the pipe a fixed delay line.
  generate
    for (genvar f = 0; f < NFE; f++) begin : g_tag
      localparam int unsigned LC = f / 2;
      localparam int unsigned TD = LC + 1;
      logic [TD-1:0] tv;
      logic [AW-1:0] tq [TD];
      if (TD == 1) begin : g_t1
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) tv <= '0;
          else        tv <= TD'(issue_v[f]);
        end
      end else begin : g_tn
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) tv <= '0;
          else        tv <= {tv[TD-2:0], issue_v[f]};
        end
      end
      always_ff @(posedge clk) begin
        tq[0] <= issue_idx[f];
        for (int s = 1; s < TD; s++) tq[s] <= tq[s-1];
      end
      assign exit_v[f]   = tv[TD-1];
      assign exit_idx[f] = tq[TD-1];
      // one-cycle-early exit prediction (deterministic pipeline)
      if (TD == 1) begin : g_p1
        assign pre_v[f]   = issue_v[f];
        assign pre_idx[f] = issue_idx[f];
      end else begin : g_pn
        assign pre_v[f]   = tv[TD-2];
        assign pre_idx[f] = tq[TD-2];
      end
    end
  endgenerate

  always_comb begin
    res_now = '0;
    for (int f = 0; f < NFE; f++) begin
      if (exit_v[f]) res_now[exit_idx[f]] = 1'b1;
    end
  end

  // predicted result arrival (next cycle) - used for early wake-up so a
  // dependent can enter the FE in the SAME cycle its target result shows
  // up on FEOUT (dp_data taken from the FEOUT bus combinationally)
  logic [D-1:0] res_pred;
  always_comb begin
    res_pred = '0;
    for (int f = 0; f < NFE; f++) begin
      if (pre_v[f]) res_pred[pre_idx[f]] = 1'b1;
    end
  end

  // wake-up: target result arrives next cycle (pre-wake)
  logic [D-1:0] wake_now;
  always_comb begin
    for (int e = 0; e < D; e++) begin
      wake_now[e] = wtg_q[e] & res_pred[rob_tgt[e]];
    end
  end

  // -------------------------------------------------------------------------
  // I0: pick stage - per (latclass, parity) port select oldest ready entry.
  //     The 8 candidate sets partition the ROB => no inter-port arbitration.
  // -------------------------------------------------------------------------
  logic [D-1:0] rdy_eff;
  assign rdy_eff = rdy_q | (WAKE_BYPASS ? wake_now : '0);

  logic [AW-1:0] rbase;
  assign rbase = old_u_q[AW-1:0];

  logic [NFE-1:0] fnd;
  logic [AW-1:0]  sel_idx [NFE];

  generate
    for (genvar f = 0; f < NFE; f++) begin : g_pick
      localparam int unsigned LC = f / 2;
      localparam int unsigned PR = f % 2;
      logic [D-1:0] cand, rot;
      logic [AW:0]  pe;
      always_comb begin
        for (int e = 0; e < D; e++) begin
          cand[e] = rdy_eff[e] & (rob_lat[e] == 2'(LC)) & ((e % 2) == PR);
        end
      end
      assign rot        = rotrD(cand, rbase);
      assign pe         = peD(rot);
      assign fnd[f]     = pe[AW];
      assign sel_idx[f] = pe[AW-1:0] + rbase;
    end
  endgenerate

  always_comb begin
    picked = '0;
    for (int f = 0; f < NFE; f++) begin
      if (fnd[f]) picked[sel_idx[f]] = 1'b1;
    end
  end

  // pick registers (I0 -> I1)
  logic [NFE-1:0] pk_v_q;
  logic [AW-2:0]  pk_idxh_q [NFE];  // idx[AW-1:1]; idx[0] == port parity

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pk_v_q <= '0;
    else        pk_v_q <= fnd;
  end
  always_ff @(posedge clk) begin
    for (int f = 0; f < NFE; f++) begin
      if (fnd[f]) pk_idxh_q[f] <= sel_idx[f][AW-1:1];
    end
  end

  // -------------------------------------------------------------------------
  // I1: issue stage - read ROB data / dependency data, drive FEIN
  // -------------------------------------------------------------------------
  logic         fein_v   [NFE];
  logic [127:0] fein_d   [NFE];
  logic         fein_dpv [NFE];
  logic [127:0] fein_dpd [NFE];

  generate
    for (genvar f = 0; f < NFE; f++) begin : g_iss
      localparam int unsigned PR = f % 2;
      logic [AW-1:0] ridx;
      logic [AW-1:0] tgt;
      assign ridx        = {pk_idxh_q[f], 1'(PR)};  // (D/2):1 muxes (parity fixed)
      assign tgt         = rob_tgt[ridx];
      assign fein_v[f]   = pk_v_q[f];
      assign fein_d[f]   = rob_data[ridx];
      assign fein_dpv[f] = rob_isdep[ridx];
      assign fein_dpd[f] = res_now[tgt] ? fe_od[{rob_lat[tgt], tgt[0]}]
                                        : rob_data[tgt];
    end
  endgenerate

  // optional FEIN output register stage
  generate
    if (REG_FEIN) begin : g_regfe
      logic [127:0] fo_d   [NFE];
      logic         fo_dpv [NFE];
      logic [127:0] fo_dpd [NFE];
      logic [NFE-1:0] fo_v_q;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) fo_v_q <= '0;
        else for (int f = 0; f < NFE; f++) fo_v_q[f] <= fein_v[f];
      end
      always_ff @(posedge clk) begin
        for (int f = 0; f < NFE; f++) begin
          if (fein_v[f]) begin
            fo_d[f]   <= fein_d[f];
            fo_dpv[f] <= fein_dpv[f];
            fo_dpd[f] <= fein_dpd[f];
          end
        end
      end
      // with REG_FEIN the tag pipe is fed from the registered stage
      logic [AW-1:0] fo_idx [NFE];
      always_ff @(posedge clk) begin
        for (int f = 0; f < NFE; f++) begin
          if (fein_v[f]) fo_idx[f] <= {pk_idxh_q[f], 1'(f % 2)};
        end
      end
      assign issue_v = fo_v_q;
      always_comb for (int f = 0; f < NFE; f++) issue_idx[f] = fo_idx[f];
      // FE port hookup
      assign {fwd7_pkt_data_vld, fwd6_pkt_data_vld, fwd5_pkt_data_vld,
              fwd4_pkt_data_vld, fwd3_pkt_data_vld, fwd2_pkt_data_vld,
              fwd1_pkt_data_vld, fwd0_pkt_data_vld} = fo_v_q;
      assign fwd0_pkt_data = fo_d[0]; assign fwd0_pkt_dp_vld = fo_dpv[0]; assign fwd0_pkt_dp_data = fo_dpd[0];
      assign fwd1_pkt_data = fo_d[1]; assign fwd1_pkt_dp_vld = fo_dpv[1]; assign fwd1_pkt_dp_data = fo_dpd[1];
      assign fwd2_pkt_data = fo_d[2]; assign fwd2_pkt_dp_vld = fo_dpv[2]; assign fwd2_pkt_dp_data = fo_dpd[2];
      assign fwd3_pkt_data = fo_d[3]; assign fwd3_pkt_dp_vld = fo_dpv[3]; assign fwd3_pkt_dp_data = fo_dpd[3];
      assign fwd4_pkt_data = fo_d[4]; assign fwd4_pkt_dp_vld = fo_dpv[4]; assign fwd4_pkt_dp_data = fo_dpd[4];
      assign fwd5_pkt_data = fo_d[5]; assign fwd5_pkt_dp_vld = fo_dpv[5]; assign fwd5_pkt_dp_data = fo_dpd[5];
      assign fwd6_pkt_data = fo_d[6]; assign fwd6_pkt_dp_vld = fo_dpv[6]; assign fwd6_pkt_dp_data = fo_dpd[6];
      assign fwd7_pkt_data = fo_d[7]; assign fwd7_pkt_dp_vld = fo_dpv[7]; assign fwd7_pkt_dp_data = fo_dpd[7];
    end else begin : g_combfe
      assign issue_v = pk_v_q;
      always_comb begin
        for (int f = 0; f < NFE; f++) begin
          issue_idx[f] = {pk_idxh_q[f], 1'(f % 2)};
        end
      end
      assign {fwd7_pkt_data_vld, fwd6_pkt_data_vld, fwd5_pkt_data_vld,
              fwd4_pkt_data_vld, fwd3_pkt_data_vld, fwd2_pkt_data_vld,
              fwd1_pkt_data_vld, fwd0_pkt_data_vld} = pk_v_q;
      assign fwd0_pkt_data = fein_d[0]; assign fwd0_pkt_dp_vld = fein_dpv[0]; assign fwd0_pkt_dp_data = fein_dpd[0];
      assign fwd1_pkt_data = fein_d[1]; assign fwd1_pkt_dp_vld = fein_dpv[1]; assign fwd1_pkt_dp_data = fein_dpd[1];
      assign fwd2_pkt_data = fein_d[2]; assign fwd2_pkt_dp_vld = fein_dpv[2]; assign fwd2_pkt_dp_data = fein_dpd[2];
      assign fwd3_pkt_data = fein_d[3]; assign fwd3_pkt_dp_vld = fein_dpv[3]; assign fwd3_pkt_dp_data = fein_dpd[3];
      assign fwd4_pkt_data = fein_d[4]; assign fwd4_pkt_dp_vld = fein_dpv[4]; assign fwd4_pkt_dp_data = fein_dpd[4];
      assign fwd5_pkt_data = fein_d[5]; assign fwd5_pkt_dp_vld = fein_dpv[5]; assign fwd5_pkt_dp_data = fein_dpd[5];
      assign fwd6_pkt_data = fein_d[6]; assign fwd6_pkt_dp_vld = fein_dpv[6]; assign fwd6_pkt_dp_data = fein_dpd[6];
      assign fwd7_pkt_data = fein_d[7]; assign fwd7_pkt_dp_vld = fein_dpv[7]; assign fwd7_pkt_dp_data = fein_dpd[7];
    end
  endgenerate

  // latency field per FE port is a constant (latency-class binding)
  assign fwd0_pkt_lat = 2'd0;
  assign fwd1_pkt_lat = 2'd0;
  assign fwd2_pkt_lat = 2'd1;
  assign fwd3_pkt_lat = 2'd1;
  assign fwd4_pkt_lat = 2'd2;
  assign fwd5_pkt_lat = 2'd2;
  assign fwd6_pkt_lat = 2'd3;
  assign fwd7_pkt_lat = 2'd3;

  // -------------------------------------------------------------------------
  // Output stage: in-order pop of up to 4 contiguous completed entries,
  //               lane = seq[1:0] (spec rotating-lane rule)
  // -------------------------------------------------------------------------
  logic can0, can1, can2, can3;
  logic [AW-1:0] oidx0, oidx1, oidx2, oidx3;

  assign oidx0 = out_seq_q[AW-1:0];
  assign oidx1 = out_seq_q[AW-1:0] + AW'(1);
  assign oidx2 = out_seq_q[AW-1:0] + AW'(2);
  assign oidx3 = out_seq_q[AW-1:0] + AW'(3);
  // pop bypass: a result arriving THIS cycle can be popped this cycle
  logic [D-1:0] cmpl;
  assign cmpl  = resv_q | res_now;
  assign can0  = cmpl[oidx0] & ~outp_q[oidx0];
  assign can1  = cmpl[oidx1] & ~outp_q[oidx1];
  assign can2  = cmpl[oidx2] & ~outp_q[oidx2];
  assign can3  = cmpl[oidx3] & ~outp_q[oidx3];

  always_comb begin
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

  always_comb begin
    pop_oh = '0;
    if (pop_cnt > 3'd0) pop_oh[oidx0] = 1'b1;
    if (pop_cnt > 3'd1) pop_oh[oidx1] = 1'b1;
    if (pop_cnt > 3'd2) pop_oh[oidx2] = 1'b1;
    if (pop_cnt > 3'd3) pop_oh[oidx3] = 1'b1;
  end

  logic [3:0]    out_act;
  logic [127:0]  out_dat [4];

  always_comb begin
    for (int l = 0; l < 4; l++) begin
      logic [1:0]    kl;
      logic [AW-1:0] src;
      logic [AW-1:0] si;
      kl         = 2'(l) - out_seq_q[1:0];
      out_act[l] = ({1'b0, kl} < pop_cnt[2:0]);
      src        = out_seq_q[AW-1:0] + AW'(kl);
      // src[1:0]==l by construction -> (D/4):1 mux per lane
      si         = {src[AW-1:2], 2'(l)};
      out_dat[l] = res_now[si] ? fe_od[{rob_lat[si], si[0]}]
                               : rob_data[si];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lane0_pkt_out_vld <= 1'b0;
      lane1_pkt_out_vld <= 1'b0;
      lane2_pkt_out_vld <= 1'b0;
      lane3_pkt_out_vld <= 1'b0;
    end else begin
      lane0_pkt_out_vld <= out_act[0];
      lane1_pkt_out_vld <= out_act[1];
      lane2_pkt_out_vld <= out_act[2];
      lane3_pkt_out_vld <= out_act[3];
    end
  end
  always_ff @(posedge clk) begin
    if (out_act[0]) lane0_pkt_out_data <= out_dat[0];
    if (out_act[1]) lane1_pkt_out_data <= out_dat[1];
    if (out_act[2]) lane2_pkt_out_data <= out_dat[2];
    if (out_act[3]) lane3_pkt_out_data <= out_dat[3];
  end

  // -------------------------------------------------------------------------
  // oldest-un-issued pointer (bounded advance, clamped at alloc frontier)
  // -------------------------------------------------------------------------
  logic [D-1:0]  niss_rot;
  logic [AW:0]   ffz;
  logic [SW-1:0] adv_raw, adv;
  logic [SW-1:0] dist_f;

  always_comb begin
    // full-speed catch-up: first not-issued entry in age order
    niss_rot = rotrD(~iss_q, old_u_q[AW-1:0]);
    ffz      = peD(niss_rot);
    adv_raw  = ffz[AW] ? {1'b0, ffz[AW-1:0]} : SW'(D);
    dist_f   = alloc_seq_q - old_u_q;
    adv      = (adv_raw > dist_f) ? dist_f : adv_raw;
  end

  // -------------------------------------------------------------------------
  // BKPR (registered output)
  // -------------------------------------------------------------------------
  logic [SW-1:0] alloc_nxt, occ, win;
  assign alloc_nxt = alloc_seq_q + SW'(acnt);
  assign occ       = alloc_nxt - out_seq_q;
  assign win       = alloc_nxt - old_u_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pkt_in_bkpr <= 1'b0;
    else        pkt_in_bkpr <= (occ > OCC_TH) || (win > WIN_TH);
  end

  // -------------------------------------------------------------------------
  // ROB state update
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdy_q       <= '0;
      wtg_q       <= '0;
      iss_q       <= '0;
      resv_q      <= '0;
      outp_q      <= '0;
      alloc_seq_q <= '0;
      out_seq_q   <= '0;
      old_u_q     <= '0;
    end else begin
      for (int e = 0; e < D; e++) begin
        if (alloc_oh[e]) begin
          rdy_q[e]  <= slot_rdy[e % 4];
          wtg_q[e]  <= slot_wtg[e % 4];
          iss_q[e]  <= 1'b0;
          resv_q[e] <= 1'b0;
          outp_q[e] <= 1'b0;
        end else begin
          if (picked[e]) begin
            rdy_q[e] <= 1'b0;
            iss_q[e] <= 1'b1;
          end else if (wake_now[e]) begin
            rdy_q[e] <= 1'b1;
          end
          if (wake_now[e]) wtg_q[e]  <= 1'b0;
          if (res_now[e])  resv_q[e] <= 1'b1;
          if (pop_oh[e])   outp_q[e] <= 1'b1;
        end
      end
      alloc_seq_q <= alloc_seq_q + SW'(acnt);
      out_seq_q   <= out_seq_q + SW'(pop_cnt);
      old_u_q     <= old_u_q + adv;
    end
  end

  // ROB datapath regs (no reset, enable-gated)
  always_ff @(posedge clk) begin
    for (int e = 0; e < D; e++) begin
      if (alloc_oh[e]) begin
        rob_data[e]  <= slot_pl[e % 4][127:0];
        rob_lat[e]   <= slot_lat[e % 4];
        rob_tgt[e]   <= slot_tgt[e % 4];
        rob_isdep[e] <= slot_isdep[e % 4];
      end else if (res_now[e]) begin
        // overwrite original data with forwarded result
        // (single result source per entry: FE {lat, entry parity})
        rob_data[e] <= fe_od[{rob_lat[e], 1'(e % 2)}];
      end
    end
  end

`ifndef SYNTHESIS
  // internal consistency: FE result valids must match tag-pipe schedule
  always_ff @(posedge clk) begin
    if (rst_n) begin
      for (int f = 0; f < NFE; f++) begin
        if (exit_v[f] !== fe_ov[f]) begin
          $error("[dut] FE%0d result valid mismatch: expect %b got %b @%0t",
                 f, exit_v[f], fe_ov[f], $time);
        end
      end
    end
  end
`endif

endmodule
