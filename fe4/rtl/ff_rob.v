// =============================================================================
// ff_rob - ROB storage + per-entry state machines, result write-back,
//          wake-up, sequence counters, oldest-un-issued pointer, BKPR
//
// RTL revision : 4FE-safe-v43
// Experiment   : E043-400ps
// Based on     : E042-R64-IQ32
// Changes      : registered safe-profile write-back, split sequence-distance
//                subtraction, physical allocation/oldest-unissued pointers
//
// Per-entry state: alloc -> (rdy | wtg) -> issued -> resv -> outp.
// The forwarded result overwrites the entry's input data (single 128b reg
// per packet) and is RETAINED after output until the entry is re-allocated,
// so late dependents (window = 7) can still read it; the BKPR issue window
// guarantees no needed result is ever overwritten.
// =============================================================================
module ff_rob #(
  parameter D   = 64,
  parameter AW  = 6,
  parameter SW  = 7,
  parameter NFE = 4,
  parameter WAKE_BYPASS = 0
)(
  input  wire                clk,
  input  wire                rst_n,
  // ingress / allocation
  input  wire [2:0]          acnt,
  input  wire [D-1:0]        alloc_oh,
  input  wire [511:0]        slot_dat_f,
  input  wire [7:0]          slot_lat_f,
  input  wire [4*AW-1:0]     slot_tgt_f,
  input  wire [3:0]          slot_rdy,
  input  wire [3:0]          slot_wtg,
  input  wire [3:0]          slot_isdep,
  input  wire [3:0]          kw_vld,        // newly waiting dependents
  input  wire [4*AW-1:0]     k_tgt_f,       // their targets (critical mark)
  // FE tracking / results
  input  wire [NFE-1:0]      exit_v,
  input  wire [NFE*AW-1:0]   exit_idx_f,
  input  wire [NFE-1:0]      pre_v,
  input  wire [NFE*AW-1:0]   pre_idx_f,
  input  wire [NFE*128-1:0]  fe_od_f,
  // pick / egress feedback
  input  wire [D-1:0]        picked,
  input  wire [D*2-1:0]      rob_src_f,     // FE each entry was issued to
  input  wire                iq_over,
  input  wire [D-1:0]        pop_oh,
  input  wire [2:0]          pop_cnt,
  // state exports
  output wire [D-1:0]        res_now_o,
  output wire [D-1:0]        res_pred_o,
  output wire [D-1:0]        res_stored_o,  // persistent registered results only
  output wire [D-1:0]        res_known_o,   // resv | res_now | res_pred
  output wire [D-1:0]        wake_now_o,
  output wire [D-1:0]        rdy_o,
  output wire [D-1:0]        crit_o,
  output wire [D-1:0]        resv_o,
  output wire [D-1:0]        outp_o,
  output wire [D*128-1:0]    rob_data_f,
  output wire [D*2-1:0]      rob_lat_f,
  output wire [D*AW-1:0]     rob_tgt_f,
  output wire [D-1:0]        rob_isdep_o,
  output wire [SW-1:0]       alloc_seq_o,
  output wire [SW-1:0]       out_seq_o,
  output wire [SW-1:0]       old_u_o,
  output reg                 bkpr_r         // registered BKPR
);

  // BKPR thresholds (2 cycles / up to 8 packets of unaccounted in-flight
  // input between the combinational decision and the throttle taking effect):
  //  * occupancy: storage entry reuse (seq n overwrites n-64): 55
  //  * retained-result window: keep a dependency target from being reused
  //    while an older unissued consumer still needs it: 45 (E021 invariant)
  //  * IQ occupancy: ff_iq reserves eight slots for registered-BKPR flight
  // Keep the legacy occ/win names because the regression testbench samples
  // them to classify backpressure causes.
  localparam [SW-1:0] OCC_TH = 55;
  localparam [SW-1:0] WIN_TH = 45;

  // -------------------------------------------------------------------------
  // unpack
  // -------------------------------------------------------------------------
  wire [127:0]  slot_dat [0:3];
  wire [1:0]    slot_lat [0:3];
  wire [AW-1:0] slot_tgt [0:3];
  wire [AW-1:0] k_tgt   [0:3];
  wire [1:0]    rob_src [0:D-1];
  wire [AW-1:0] exit_idx [0:NFE-1];
  wire [AW-1:0] pre_idx  [0:NFE-1];
  wire [127:0]  fe_od    [0:NFE-1];
  genvar gi;
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_us
      assign slot_dat[gi] = slot_dat_f[gi*128 +: 128];
      assign slot_lat[gi] = slot_lat_f[gi*2 +: 2];
      assign slot_tgt[gi] = slot_tgt_f[gi*AW +: AW];
    end
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_uk
      assign k_tgt[gi] = k_tgt_f[gi*AW +: AW];
    end
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ur
      assign rob_src[gi] = rob_src_f[gi*2 +: 2];
    end
    for (gi = 0; gi < NFE; gi = gi + 1) begin : g_uf
      assign exit_idx[gi] = exit_idx_f[gi*AW +: AW];
      assign pre_idx[gi]  = pre_idx_f[gi*AW +: AW];
      assign fe_od[gi]    = fe_od_f[gi*128 +: 128];
    end
  endgenerate

  // -------------------------------------------------------------------------
  // storage
  // -------------------------------------------------------------------------
  reg [127:0]  rob_data  [0:D-1];       // input data, later the fwded result
  reg [1:0]    rob_lat   [0:D-1];
  reg [AW-1:0] rob_tgt   [0:D-1];
  reg          rob_isdep [0:D-1];

  reg [D-1:0]  crit_q;                  // some dependent is waiting on this
  reg [D-1:0]  rdy_q;                   // ready, not yet picked
  reg [D-1:0]  wtg_q;                   // waiting for dependency result
  reg [D-1:0]  iss_q;                   // picked/issued
  reg [D-1:0]  resv_q;                  // result present (retained after pop)
  reg [D-1:0]  outp_q;                  // popped to PKTOUT

  reg [SW-1:0] alloc_seq_q;
  reg [SW-1:0] out_seq_q;
  reg [SW-1:0] old_u_q;                 // oldest un-issued sequence number
  reg [D-1:0]  old_u_oh_q;              // physical one-hot form of old_u_q
  reg [SW-1:0] adv_q;
  reg [2:0] pop_cnt_pipe_q;

  wire [6:0] alloc_seq_next, out_seq_next, old_u_next;
  wire [6:0] dist_now, occ, win;
  ff_prefix_add7 u_add_alloc (
    .a(alloc_seq_q), .b({4'b0, acnt}), .cin(1'b0), .y(alloc_seq_next));
  ff_prefix_add7 u_add_out (
    .a(out_seq_q), .b({4'b0, pop_cnt_pipe_q}), .cin(1'b0), .y(out_seq_next));
  ff_prefix_add7 u_add_old (
    .a(old_u_q), .b(adv_q), .cin(1'b0), .y(old_u_next));
  ff_split_sub7 u_sub_dist (
    .clk(clk), .rst_n(rst_n), .a(alloc_seq_q), .b(old_u_q), .y(dist_now));
  ff_split_sub7 u_sub_occ (
    .clk(clk), .rst_n(rst_n), .a(alloc_seq_q), .b(out_seq_q), .y(occ));
  ff_split_sub7 u_sub_win (
    .clk(clk), .rst_n(rst_n), .a(alloc_seq_q), .b(old_u_q), .y(win));

  // A physical allocation pointer makes every ROB state/data write depend on
  // only a registered one-hot and the 3-bit batch count.  It removes the
  // ingress compaction -> binary add/decode -> 64 ROB D-input path.
  reg [D-1:0] alloc_head_oh_q;
  wire [D-1:0] alloc1_oh = {alloc_head_oh_q[D-2:0], alloc_head_oh_q[D-1]};
  wire [D-1:0] alloc2_oh = {alloc_head_oh_q[D-3:0], alloc_head_oh_q[D-1:D-2]};
  wire [D-1:0] alloc3_oh = {alloc_head_oh_q[D-4:0], alloc_head_oh_q[D-1:D-3]};
  wire [D-1:0] alloc4_oh = {alloc_head_oh_q[D-5:0], alloc_head_oh_q[D-1:D-4]};
  wire [D-1:0] alloc_fast = ({D{acnt > 0}} & alloc_head_oh_q)
                            | ({D{acnt > 1}} & alloc1_oh)
                            | ({D{acnt > 2}} & alloc2_oh)
                            | ({D{acnt > 3}} & alloc3_oh);

  // -------------------------------------------------------------------------
  // result decode + wake-up
  // -------------------------------------------------------------------------
  reg [D-1:0] res_now_r, res_pred_r;
  integer f;
  always @* begin
    res_now_r  = {D{1'b0}};
    res_pred_r = {D{1'b0}};
    for (f = 0; f < NFE; f = f + 1) begin
      if (exit_v[f]) res_now_r[exit_idx[f]]  = 1'b1;
      if (pre_v[f])  res_pred_r[pre_idx[f]]  = 1'b1;
    end
  end

  // Return write-back is split at the ROB boundary.  The scheduler index is
  // decoded into a registered per-FE one-hot together with its 128-bit data;
  // the following cycle writes the selected ROB word.  This removes the
  // scheduler-index decode and FE-source selection from the large ROB D cone.
  reg [D-1:0] wb_oh_q [0:NFE-1];
  reg [127:0] wb_data_q [0:NFE-1];
  integer wf;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (wf = 0; wf < NFE; wf = wf + 1)
        wb_oh_q[wf] <= {D{1'b0}};
    end else begin
      for (wf = 0; wf < NFE; wf = wf + 1) begin
        wb_oh_q[wf] <= {D{1'b0}};
        if (exit_v[wf]) wb_oh_q[wf][exit_idx[wf]] <= 1'b1;
      end
    end
  end
  always @(posedge clk) begin
    for (wf = 0; wf < NFE; wf = wf + 1)
      if (exit_v[wf]) wb_data_q[wf] <= fe_od[wf];
  end

  wire [D-1:0] store_now = wb_oh_q[0] | wb_oh_q[1]
                           | wb_oh_q[2] | wb_oh_q[3];
  wire [127:0] store_data [0:D-1];
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_store_data
      assign store_data[gi] = (wb_data_q[0] & {128{wb_oh_q[0][gi]}})
                            | (wb_data_q[1] & {128{wb_oh_q[1][gi]}})
                            | (wb_data_q[2] & {128{wb_oh_q[2][gi]}})
                            | (wb_data_q[3] & {128{wb_oh_q[3][gi]}});
    end
  endgenerate

  // pre-wake: target result arrives next cycle -> dependent can enter the FE
  // in the same cycle the result shows up on FEOUT (dp taken from the bus)
  reg [D-1:0] wake_now;
  integer e;
  always @* begin
    for (e = 0; e < D; e = e + 1)
      wake_now[e] = wtg_q[e] & res_pred_r[rob_tgt[e]];
  end

  // -------------------------------------------------------------------------
  // oldest-un-issued pointer: four-phase bounded catch-up.  U1 constructs a
  // logarithmic first-gap one-hot; U2 encodes/clamps it; U3 advances the
  // pointers.  This avoids the linear priority chain inferred by a procedural
  // encoder.  Sixteen entries per four cycles matches peak issue bandwidth.
  // -------------------------------------------------------------------------
  wire [D-1:0] iss_eff = iss_q | picked;
  wire [15:0] issued_win;
  genvar gw;
  generate
    for (gw = 0; gw < 16; gw = gw + 1) begin : g_issue_window
      wire [D-1:0] win_mask;
      if (gw == 0)
        assign win_mask = old_u_oh_q;
      else
        assign win_mask = {old_u_oh_q[D-gw-1:0],
                           old_u_oh_q[D-1:D-gw]};
      assign issued_win[gw] = |(iss_eff & win_mask);
    end
  endgenerate

  reg [1:0] old_u_phase_q;
  reg [15:0] issued_win_q;
  reg [SW-1:0] dist_probe_q;
  reg [15:0] first_gap_oh_q;
  reg        no_gap_q;
  // Keep distance clamping out of the first-gap tree.  Folding the decoded
  // allocation distance into every gap bit lets an area-oriented mapper turn
  // bit 15 back into a long AND/OR chain.  The pure 16-bit leading-one tree is
  // shallow; U2 applies a small 4-bit clamp afterwards.
  wire [15:0] gap_bits = ~issued_win_q;
  wire [15:0] gap_pref1 = gap_bits | (gap_bits << 1);
  wire [15:0] gap_pref2 = gap_pref1 | (gap_pref1 << 2);
  wire [15:0] gap_pref4 = gap_pref2 | (gap_pref2 << 4);
  wire [15:0] gap_pref8 = gap_pref4 | (gap_pref4 << 8);
  wire [15:0] first_gap_oh = gap_bits & ~(gap_pref8 << 1);
  wire [3:0] first_gap_idx = {|(first_gap_oh_q & 16'hff00),
                              |(first_gap_oh_q & 16'hf0f0),
                              |(first_gap_oh_q & 16'hcccc),
                              |(first_gap_oh_q & 16'haaaa)};
  wire [4:0] gap_advance = no_gap_q ? 5'd16
                                    : {1'b0, first_gap_idx};
  reg [SW-1:0] adv_raw_comb;
  always @* begin
    // gap_advance is at most 16.  Only distances below 16 need a real
    // comparison, reducing the clamp to four bits on its timing path.
    if (|dist_probe_q[SW-1:4])
      adv_raw_comb = {{(SW-5){1'b0}}, gap_advance};
    else if (no_gap_q || (dist_probe_q[3:0] < first_gap_idx))
      adv_raw_comb = {{(SW-4){1'b0}}, dist_probe_q[3:0]};
    else
      adv_raw_comb = {{(SW-5){1'b0}}, gap_advance};
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      old_u_q       <= {SW{1'b0}};
      old_u_oh_q    <= {{(D-1){1'b0}}, 1'b1};
      old_u_phase_q <= 2'd0;
      issued_win_q  <= 16'b0;
      dist_probe_q  <= {SW{1'b0}};
      first_gap_oh_q <= 16'b0;
      no_gap_q      <= 1'b0;
      adv_q         <= {SW{1'b0}};
    end else begin
      case (old_u_phase_q)
        2'd0: begin
          issued_win_q <= issued_win;
          old_u_phase_q <= 2'd1;
        end
        2'd1: begin
          // dist_now is a registered 4+3 split subtraction.  Capturing it in
          // U1 aligns it with the U0 issue-window sample without crossing a
          // complete 7-bit subtractor in one clock stage.
          dist_probe_q <= dist_now;
          first_gap_oh_q <= first_gap_oh;
          no_gap_q <= &issued_win_q;
          old_u_phase_q <= 2'd2;
        end
        2'd2: begin
          adv_q <= adv_raw_comb;
          old_u_phase_q <= 2'd3;
        end
        default: begin
          old_u_q <= old_u_next;
          case (adv_q[4:0])
            5'd0:  old_u_oh_q <= old_u_oh_q;
            5'd1:  old_u_oh_q <= {old_u_oh_q[D-2:0], old_u_oh_q[D-1]};
            5'd2:  old_u_oh_q <= {old_u_oh_q[D-3:0], old_u_oh_q[D-1:D-2]};
            5'd3:  old_u_oh_q <= {old_u_oh_q[D-4:0], old_u_oh_q[D-1:D-3]};
            5'd4:  old_u_oh_q <= {old_u_oh_q[D-5:0], old_u_oh_q[D-1:D-4]};
            5'd5:  old_u_oh_q <= {old_u_oh_q[D-6:0], old_u_oh_q[D-1:D-5]};
            5'd6:  old_u_oh_q <= {old_u_oh_q[D-7:0], old_u_oh_q[D-1:D-6]};
            5'd7:  old_u_oh_q <= {old_u_oh_q[D-8:0], old_u_oh_q[D-1:D-7]};
            5'd8:  old_u_oh_q <= {old_u_oh_q[D-9:0], old_u_oh_q[D-1:D-8]};
            5'd9:  old_u_oh_q <= {old_u_oh_q[D-10:0], old_u_oh_q[D-1:D-9]};
            5'd10: old_u_oh_q <= {old_u_oh_q[D-11:0], old_u_oh_q[D-1:D-10]};
            5'd11: old_u_oh_q <= {old_u_oh_q[D-12:0], old_u_oh_q[D-1:D-11]};
            5'd12: old_u_oh_q <= {old_u_oh_q[D-13:0], old_u_oh_q[D-1:D-12]};
            5'd13: old_u_oh_q <= {old_u_oh_q[D-14:0], old_u_oh_q[D-1:D-13]};
            5'd14: old_u_oh_q <= {old_u_oh_q[D-15:0], old_u_oh_q[D-1:D-14]};
            5'd15: old_u_oh_q <= {old_u_oh_q[D-16:0], old_u_oh_q[D-1:D-15]};
            5'd16: old_u_oh_q <= {old_u_oh_q[D-17:0], old_u_oh_q[D-1:D-16]};
            default: old_u_oh_q <= old_u_oh_q;
          endcase
          old_u_phase_q <= 2'd0;
        end
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // BKPR (registered output)
  // -------------------------------------------------------------------------
  // Exclude the live ingress batch from this path and compensate by lowering
  // both thresholds by four entries.  This preserves the same safety point
  // while removing in_vld/compaction from the registered BKPR cone.
  reg [SW-1:0] occ_probe_q, win_probe_q;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      occ_probe_q <= {SW{1'b0}};
      win_probe_q <= {SW{1'b0}};
      bkpr_r <= 1'b0;
    end else begin
      occ_probe_q <= occ;
      win_probe_q <= win;
      // The registered 4+3 subtraction plus the distance probe add two
      // decision stages; reserve twelve worst-case input packets in total.
      bkpr_r <= (occ_probe_q > (OCC_TH-12))
                || (win_probe_q > (WIN_TH-12)) || iq_over;
    end
  end

  // E005 updates these control vectors every cycle through their D inputs.
  // This preserves the original precedence (critical set beats alloc clear;
  // alloc clear beats pop set) without placing k_tgt/pop_oh on per-bit clock
  // gate enables.
  reg [D-1:0] crit_set_oh;
  reg [3:0] kw_vld_q1, kw_vld_q2;
  reg [AW-1:0] kw_tgt_q1 [0:3];
  reg [AW-1:0] kw_tgt_q2 [0:3];
  integer kb;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      kw_vld_q1 <= 4'b0;
      kw_vld_q2 <= 4'b0;
    end else begin
      kw_vld_q1 <= kw_vld;
      kw_vld_q2 <= kw_vld_q1;
      for (kb = 0; kb < 4; kb = kb + 1) begin
        kw_tgt_q1[kb] <= k_tgt[kb];
        kw_tgt_q2[kb] <= kw_tgt_q1[kb];
      end
    end
  end
  integer ck;
  always @* begin
    crit_set_oh = {D{1'b0}};
    for (ck = 0; ck < 4; ck = ck + 1) begin
      if (kw_vld_q1[ck]) crit_set_oh[kw_tgt_q1[ck]] = 1'b1;
      if (kw_vld_q2[ck]) crit_set_oh[kw_tgt_q2[ck]] = 1'b1;
    end
  end
  wire [D-1:0] crit_n = (crit_q & ~alloc_fast) | crit_set_oh;
  wire [D-1:0] outp_n = (outp_q | pop_oh) & ~alloc_fast;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      crit_q <= {D{1'b0}};
      outp_q <= {D{1'b0}};
    end else begin
      crit_q <= crit_n;
      outp_q <= outp_n;
    end
  end

  // -------------------------------------------------------------------------
  // state update
  // -------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdy_q       <= {D{1'b0}};
      wtg_q       <= {D{1'b0}};
      iss_q       <= {D{1'b0}};
      resv_q      <= {D{1'b0}};
      alloc_seq_q <= {SW{1'b0}};
      out_seq_q   <= {SW{1'b0}};
      alloc_head_oh_q <= {{(D-1){1'b0}}, 1'b1};
      pop_cnt_pipe_q <= 3'b0;
    end else begin
      for (e = 0; e < D; e = e + 1) begin
        if (alloc_fast[e]) begin
          rdy_q[e]  <= slot_rdy[e[1:0]];
          wtg_q[e]  <= slot_wtg[e[1:0]];
          iss_q[e]  <= 1'b0;
          resv_q[e] <= 1'b0;
        end else begin
          if (picked[e]) begin
            rdy_q[e] <= 1'b0;
            iss_q[e] <= 1'b1;
          end else if (wake_now[e]) begin
            rdy_q[e] <= 1'b1;
          end
          if (wake_now[e])  wtg_q[e]  <= 1'b0;
          if ((WAKE_BYPASS != 0) ? res_now_r[e] : store_now[e])
            resv_q[e] <= 1'b1;
        end
      end
      alloc_seq_q <= alloc_seq_next;
      out_seq_q   <= out_seq_next;
      pop_cnt_pipe_q <= pop_cnt;
      case (acnt)
        3'd1: alloc_head_oh_q <= alloc1_oh;
        3'd2: alloc_head_oh_q <= alloc2_oh;
        3'd3: alloc_head_oh_q <= alloc3_oh;
        3'd4: alloc_head_oh_q <= alloc4_oh;
        default: alloc_head_oh_q <= alloc_head_oh_q;
      endcase
    end
  end

  // ROB datapath registers (no reset, enable-gated)
  always @(posedge clk) begin
    for (e = 0; e < D; e = e + 1) begin
      if (alloc_fast[e]) begin
        rob_data[e]  <= slot_dat[e[1:0]];
        rob_lat[e]   <= slot_lat[e[1:0]];
        rob_tgt[e]   <= slot_tgt[e[1:0]];
        rob_isdep[e] <= slot_isdep[e[1:0]];
      end else if ((WAKE_BYPASS != 0) ? res_now_r[e] : store_now[e]) begin
        if (WAKE_BYPASS != 0)
          rob_data[e] <= fe_od[rob_src[e]];
        else
          rob_data[e] <= store_data[e];
      end
    end
  end

  // -------------------------------------------------------------------------
  // exports
  // -------------------------------------------------------------------------
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ex
      assign rob_data_f[gi*128 +: 128] = rob_data[gi];
      assign rob_lat_f[gi*2 +: 2]      = rob_lat[gi];
      assign rob_tgt_f[gi*AW +: AW]    = rob_tgt[gi];
      assign rob_isdep_o[gi]           = rob_isdep[gi];
    end
  endgenerate

  assign res_now_o   = res_now_r;
  assign res_pred_o  = res_pred_r;
  assign res_stored_o = resv_q;
  assign res_known_o = resv_q | res_now_r | res_pred_r;
  assign wake_now_o  = wake_now;
  assign rdy_o       = rdy_q;
  assign crit_o      = crit_q;
  assign resv_o      = resv_q;
  assign outp_o      = outp_q;
  assign alloc_seq_o = alloc_seq_q;
  assign out_seq_o   = out_seq_q;
  assign old_u_o     = old_u_q;
  wire _unused_alloc_ok = &{1'b0, alloc_oh[0], rob_src[0][0]};

endmodule
