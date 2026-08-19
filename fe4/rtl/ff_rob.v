// =============================================================================
// ff_rob - ROB storage + per-entry state machines, result write-back,
//          wake-up, sequence counters, oldest-un-issued pointer, BKPR
//
// RTL revision : 4FE-safe-v70b
// Experiment   : E070B-R32-advance6-credit
// Based on     : 4FE-safe-v20 / E021-N1
// Changes      : credit up to six guaranteed old-u advances in BKPR
//
// Per-entry state: alloc -> (rdy | wtg) -> issued -> resv.
// The forwarded result overwrites the entry's input data (single 128b reg
// per packet) and is RETAINED after output until the entry is re-allocated,
// so late dependents (window = 7) can still read it; the BKPR issue window
// guarantees no needed result is ever overwritten.
// =============================================================================
module ff_rob #(
  parameter D   = 32,
  parameter AW  = 5,
  parameter SW  = 6,
  parameter NFE = 4
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
  input  wire [2:0]          pop_cnt,
  input  wire [3:0]          pop_therm,
  // state exports
  output wire [D-1:0]        res_now_o,
  output wire [D-1:0]        res_pred_o,
  output wire [D-1:0]        res_known_o,   // resv | res_now | res_pred
  output wire [D-1:0]        wake_now_o,
  output wire [D-1:0]        rdy_o,
  output wire [D-1:0]        crit_o,
  output wire [D-1:0]        resv_o,
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
  //  * occupancy   : entry reuse (seq n overwrites n-32):  (D-1)-8      = 23
  //  * issue window: a packet may depend on any of the preceding 7 entries.
  //    Before allocating sequence n, every entry through n-D+7 must therefore
  //    have issued.  With old_u denoting the first unissued sequence, this is
  //    equivalent to alloc_nxt-old_u <= D-7.  Reserve 8 additional packets
  //    for the documented two-cycle BKPR response, giving D-7-8 = 17.
  localparam [SW-1:0] OCC_TH = 23;
  localparam [SW-1:0] WIN_TH = 17;

  function [3:0] pe8;
    input [7:0] v;
    integer i;
    begin
      pe8 = 4'b0;
      for (i = 7; i >= 0; i = i - 1)
        if (v[i]) pe8 = {1'b1, i[2:0]};
    end
  endfunction

  // Oldest set entry relative to base, returned as {valid, physical index}.
  // The two-level 4x8 search preserves exact wraparound order without a
  // 32-bit barrel rotate followed by a flat priority encoder.
  function [AW:0] peH;
    input [D-1:0]  v;
    input [AW-1:0] base;
    integer b;
    reg [15:0] bank_pe_f;
    reg [3:0]  bank_v;
    reg [7:0]  base_bits, post_mask;
    reg [3:0]  post_pe, pre_pe, local_pe;
    reg [1:0]  base_bank, other_bank;
    reg        other_valid;
    begin
      bank_pe_f = 16'b0;
      bank_v    = 4'b0;
      for (b = 0; b < 4; b = b + 1) begin
        bank_pe_f[b*4 +: 4] = pe8(v[b*8 +: 8]);
        bank_v[b] = bank_pe_f[b*4+3];
      end

      base_bank = base[4:3];
      base_bits = v[base_bank*8 +: 8];
      post_mask = 8'hff << base[2:0];
      post_pe   = pe8(base_bits & post_mask);
      pre_pe    = pe8(base_bits & ~post_mask);

      bank_v[base_bank] = 1'b0;
      other_bank  = 2'b0;
      other_valid = 1'b0;
      case (base_bank)
        2'd0: begin
          if      (bank_v[1]) begin other_valid = 1'b1; other_bank = 2'd1; end
          else if (bank_v[2]) begin other_valid = 1'b1; other_bank = 2'd2; end
          else if (bank_v[3]) begin other_valid = 1'b1; other_bank = 2'd3; end
        end
        2'd1: begin
          if      (bank_v[2]) begin other_valid = 1'b1; other_bank = 2'd2; end
          else if (bank_v[3]) begin other_valid = 1'b1; other_bank = 2'd3; end
          else if (bank_v[0]) begin other_valid = 1'b1; other_bank = 2'd0; end
        end
        2'd2: begin
          if      (bank_v[3]) begin other_valid = 1'b1; other_bank = 2'd3; end
          else if (bank_v[0]) begin other_valid = 1'b1; other_bank = 2'd0; end
          else if (bank_v[1]) begin other_valid = 1'b1; other_bank = 2'd1; end
        end
        default: begin
          if      (bank_v[0]) begin other_valid = 1'b1; other_bank = 2'd0; end
          else if (bank_v[1]) begin other_valid = 1'b1; other_bank = 2'd1; end
          else if (bank_v[2]) begin other_valid = 1'b1; other_bank = 2'd2; end
        end
      endcase
      local_pe   = bank_pe_f[other_bank*4 +: 4];

      if (post_pe[3])
        peH = {1'b1, base_bank, post_pe[2:0]};
      else if (other_valid)
        peH = {1'b1, other_bank, local_pe[2:0]};
      else if (pre_pe[3])
        peH = {1'b1, base_bank, pre_pe[2:0]};
      else
        peH = {(AW+1){1'b0}};
    end
  endfunction

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

  reg [SW-1:0] alloc_seq_q;
  reg [SW-1:0] out_seq_q;
  reg [SW-1:0] old_u_q;                 // oldest un-issued sequence number

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

  // pre-wake: target result arrives next cycle -> dependent can enter the FE
  // in the same cycle the result shows up on FEOUT (dp taken from the bus)
  reg [D-1:0] wake_now;
  integer e;
  always @* begin
    for (e = 0; e < D; e = e + 1)
      wake_now[e] = wtg_q[e] & res_pred_r[rob_tgt[e]];
  end

  // -------------------------------------------------------------------------
  // oldest-un-issued pointer: full-speed catch-up, clamped at alloc frontier
  // -------------------------------------------------------------------------
  reg [AW:0]   first_niss;
  reg [AW-1:0] first_dist;
  reg [SW-1:0] dist_f;
  reg [SW-1:0] first_seq;
  reg          take_first;
  wire [D-1:0] iss_eff = iss_q | picked;
  always @* begin
    // picked is now the registered issue/commit bitmap.  Include it in the
    // look-ahead so delaying the ROB state write until issue does not add an
    // extra cycle to oldest-unissued pointer advancement.
    first_niss = peH(~iss_eff, old_u_q[AW-1:0]);
    first_dist = first_niss[AW-1:0] - old_u_q[AW-1:0];
    dist_f     = alloc_seq_q - old_u_q;
    // Reconstruct the 6-bit sequence number directly from the selected
    // physical index.  Crossing physical slot 31 toggles the sequence epoch.
    // The active window is kept below D entries by BKPR, so the reconstruction
    // is unambiguous and equals old_u_q + {1'b0, first_dist}.
    first_seq  = {
      old_u_q[SW-1]
        ^ (first_niss[AW-1:0] < old_u_q[AW-1:0]),
      first_niss[AW-1:0]
    };
    take_first = first_niss[AW] && ({1'b0, first_dist} <= dist_f);
  end
  // If the first not-issued physical entry lies beyond the allocation
  // frontier (or none exists), catch up exactly to alloc_seq_q.  This is
  // equivalent to min(adv_raw, dist_f) followed by old_u_q + adv, but removes
  // that mux/compare/add chain from the old_u_q register input.
  wire [SW-1:0] old_u_n = take_first ? first_seq : alloc_seq_q;

  // -------------------------------------------------------------------------
  // BKPR (registered output)
  // -------------------------------------------------------------------------
  wire [SW-1:0] alloc_nxt = alloc_seq_q
                            + {{(SW-3){1'b0}}, acnt};
  wire [SW-1:0] occ       = alloc_nxt - out_seq_q;
  wire [SW-1:0] win       = alloc_nxt - old_u_q;

  // Credit only progress that is guaranteed to occur at this edge. Retirement
  // is already available as a four-bit thermometer. For the issue window,
  // inspect at most six consecutive entries at old_u; this is a conservative
  // lower bound on old_u_n-old_u_q and avoids placing the full peH/old_u_n cone
  // on bkpr_r. dist_f prevents stale iss bits beyond the allocation frontier
  // from being counted after physical-index wraparound.
  wire [AW-1:0] cred_i0 = old_u_q[AW-1:0];
  wire [AW-1:0] cred_i1 = old_u_q[AW-1:0] + {{(AW-1){1'b0}}, 1'b1};
  wire [AW-1:0] cred_i2 = old_u_q[AW-1:0] + {{(AW-2){1'b0}}, 2'd2};
  wire [AW-1:0] cred_i3 = old_u_q[AW-1:0] + {{(AW-2){1'b0}}, 2'd3};
  wire [AW-1:0] cred_i4 = old_u_q[AW-1:0] + {{(AW-3){1'b0}}, 3'd4};
  wire [AW-1:0] cred_i5 = old_u_q[AW-1:0] + {{(AW-3){1'b0}}, 3'd5};
  wire dist_ge1 = |dist_f;
  wire dist_ge2 = |dist_f[SW-1:1];
  wire dist_ge3 = (|dist_f[SW-1:2]) | (&dist_f[1:0]);
  wire dist_ge4 = |dist_f[SW-1:2];
  wire dist_ge5 = (|dist_f[SW-1:3]) | (dist_f[2] & (|dist_f[1:0]));
  wire dist_ge6 = (|dist_f[SW-1:3]) | (dist_f[2] & dist_f[1]);
  wire [5:0] adv_therm;
  assign adv_therm[0] = dist_ge1 & iss_eff[cred_i0];
  assign adv_therm[1] = adv_therm[0] & dist_ge2 & iss_eff[cred_i1];
  assign adv_therm[2] = adv_therm[1] & dist_ge3 & iss_eff[cred_i2];
  assign adv_therm[3] = adv_therm[2] & dist_ge4 & iss_eff[cred_i3];
  assign adv_therm[4] = adv_therm[3] & dist_ge5 & iss_eff[cred_i4];
  assign adv_therm[5] = adv_therm[4] & dist_ge6 & iss_eff[cred_i5];

  // Convert each thermometer to a one-hot count, then select fixed
  // threshold comparisons in parallel. The effective raw thresholds rise by
  // actual same-edge progress, while the post-progress safety limits remain
  // OCC_TH=23 and WIN_TH=17.
  wire [4:0] pop_count_oh = { pop_therm[3],
                              pop_therm[2] & ~pop_therm[3],
                              pop_therm[1] & ~pop_therm[2],
                              pop_therm[0] & ~pop_therm[1],
                             ~pop_therm[0] };
  wire [6:0] adv_count_oh = { adv_therm[5],
                              adv_therm[4] & ~adv_therm[5],
                              adv_therm[3] & ~adv_therm[4],
                              adv_therm[2] & ~adv_therm[3],
                              adv_therm[1] & ~adv_therm[2],
                              adv_therm[0] & ~adv_therm[1],
                             ~adv_therm[0] };

  wire occ_gt23 = occ[5] | (occ[4] & occ[3]);
  wire occ_gt24 = occ[5] | (occ[4] & occ[3] & (|occ[2:0]));
  wire occ_gt25 = occ[5] | (occ[4] & occ[3] & (occ[2] | occ[1]));
  wire occ_gt26 = occ[5] | (occ[4] & occ[3]
                            & (occ[2] | (occ[1] & occ[0])));
  wire occ_gt27 = occ[5] | (&occ[4:2]);
  wire occ_over = (pop_count_oh[0] & occ_gt23)
                | (pop_count_oh[1] & occ_gt24)
                | (pop_count_oh[2] & occ_gt25)
                | (pop_count_oh[3] & occ_gt26)
                | (pop_count_oh[4] & occ_gt27);

  wire win_gt17 = win[5] | (win[4] & (|win[3:1]));
  wire win_gt18 = win[5] | (win[4]
                            & (win[3] | win[2] | (win[1] & win[0])));
  wire win_gt19 = win[5] | (win[4] & (win[3] | win[2]));
  wire win_gt20 = win[5] | (win[4]
                            & (win[3] | (win[2] & (win[1] | win[0]))));
  wire win_gt21 = win[5] | (win[4]
                            & (win[3] | (win[2] & win[1])));
  wire win_gt22 = win[5] | (win[4]
                            & (win[3] | (&win[2:0])));
  wire win_gt23 = win[5] | (win[4] & win[3]);
  wire win_over = (adv_count_oh[0] & win_gt17)
                | (adv_count_oh[1] & win_gt18)
                | (adv_count_oh[2] & win_gt19)
                | (adv_count_oh[3] & win_gt20)
                | (adv_count_oh[4] & win_gt21)
                | (adv_count_oh[5] & win_gt22)
                | (adv_count_oh[6] & win_gt23);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) bkpr_r <= 1'b0;
    else        bkpr_r <= occ_over || win_over;
  end

`ifndef SYNTHESIS
  // At the allocation edge, registered picks consume their ROB operands
  // before any same-edge entry reuse.  The newest allocation is therefore
  // reuse_span_n-1 beyond old_u_n and must remain no more than D-8 positions
  // beyond it; otherwise a legal distance-seven dependent could still need
  // the entry being overwritten.
  wire [SW-1:0] reuse_span_n = alloc_nxt - old_u_n;
  wire [SW-1:0] old_u_adv_n  = old_u_n - old_u_q;
  wire [2:0] adv_credit_n = {2'b0, adv_therm[0]}
                          + {2'b0, adv_therm[1]}
                          + {2'b0, adv_therm[2]}
                          + {2'b0, adv_therm[3]}
                          + {2'b0, adv_therm[4]}
                          + {2'b0, adv_therm[5]};
  wire [2:0] pop_credit_n = {2'b0, pop_therm[0]}
                          + {2'b0, pop_therm[1]}
                          + {2'b0, pop_therm[2]}
                          + {2'b0, pop_therm[3]};
  always @(posedge clk) begin
    if (rst_n && (reuse_span_n > (D-7)))
      $error("[ff_rob] unsafe ROB reuse span %0d @%0t", reuse_span_n, $time);
    if (rst_n && ({{(SW-3){1'b0}}, adv_credit_n} > old_u_adv_n))
      $error("[ff_rob] issue credit exceeds old-u advance @%0t", $time);
    if (rst_n && (pop_credit_n != pop_cnt))
      $error("[ff_rob] retirement credit/count mismatch @%0t", $time);
  end
`endif

  // E005 updates the critical vector every cycle through its D input so the
  // target-marking cone cannot become a per-bit clock-gate enable path.
  reg [D-1:0] crit_set_oh;
  integer ck;
  always @* begin
    crit_set_oh = {D{1'b0}};
    for (ck = 0; ck < 4; ck = ck + 1)
      if (kw_vld[ck]) crit_set_oh[k_tgt[ck]] = 1'b1;
  end
  wire [D-1:0] crit_n = (crit_q & ~alloc_oh) | crit_set_oh;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) crit_q <= {D{1'b0}};
    else        crit_q <= crit_n;
  end

`ifndef SYNTHESIS
  // out_seq_q is the first not-yet-retired sequence and advances by pop_cnt
  // on every retirement edge.  It therefore prevents a physical entry from
  // being retired twice without a separate per-entry popped bitmap.  Catch a
  // stale retained result being mistaken for a live entry after wraparound.
  wire [SW-1:0] retire_avail = alloc_seq_q - out_seq_q;
  always @(posedge clk) begin
    if (rst_n && ({{(SW-3){1'b0}}, pop_cnt} > retire_avail))
      $error("[ff_rob] retirement exceeds live occupancy @%0t", $time);
  end
`endif

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
      old_u_q     <= {SW{1'b0}};
    end else begin
      for (e = 0; e < D; e = e + 1) begin
        if (alloc_oh[e]) begin
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
          if (res_now_r[e]) resv_q[e] <= 1'b1;
        end
      end
      alloc_seq_q <= alloc_seq_q + {{(SW-3){1'b0}}, acnt};
      out_seq_q   <= out_seq_q + {{(SW-3){1'b0}}, pop_cnt};
      old_u_q     <= old_u_n;
    end
  end

  // ROB datapath registers (no reset, enable-gated)
  always @(posedge clk) begin
    for (e = 0; e < D; e = e + 1) begin
      if (alloc_oh[e]) begin
        rob_data[e]  <= slot_dat[e[1:0]];
        rob_lat[e]   <= slot_lat[e[1:0]];
        rob_tgt[e]   <= slot_tgt[e[1:0]];
        rob_isdep[e] <= slot_isdep[e[1:0]];
      end else if (res_now_r[e]) begin
        rob_data[e] <= fe_od[rob_src[e]];  // unique result source per entry
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
  assign res_known_o = resv_q | res_now_r | res_pred_r;
  assign wake_now_o  = wake_now;
  assign rdy_o       = rdy_q;
  assign crit_o      = crit_q;
  assign resv_o      = resv_q;
  assign alloc_seq_o = alloc_seq_q;
  assign out_seq_o   = out_seq_q;
  assign old_u_o     = old_u_q;

endmodule
