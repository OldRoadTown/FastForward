// =============================================================================
// ff_rob - ROB storage + per-entry state machines, result write-back,
//          wake-up, sequence counters, oldest-un-issued pointer, BKPR
//
// RTL revision : 4FE-safe-v39
// Experiment   : E039-R32-rbase-shadow
// Based on     : 4FE-safe-v20 / E021-N1
// Changes      : retain E029's 4x8 ROB and isolate picker rbase fanout with
//                an equivalent same-cycle physical-index register
//
// Per-entry state: alloc -> (rdy | wtg) -> issued -> resv -> outp.
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
  input  wire [D-1:0]        pop_oh,
  input  wire [2:0]          pop_cnt,
  // state exports
  output wire [D-1:0]        res_now_o,
  output wire [D-1:0]        res_pred_o,
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
  output wire [AW-1:0]       old_u_idx_o,
  output reg                 bkpr_r         // registered BKPR
);

  // BKPR thresholds (2 cycles / up to 8 packets of unaccounted in-flight
  // input between the combinational decision and the throttle taking effect):
  //  * occupancy   : entry reuse (seq n overwrites n-32):  (D-1)-8      = 23
  //  * issue window: retained-result overwrite hazard; preserve E021's
  //                  19-entry safety reserve: D-19                    = 13
  localparam [SW-1:0] OCC_TH = 23;
  localparam [SW-1:0] WIN_TH = 13;

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
  reg [D-1:0]  outp_q;                  // popped to PKTOUT

  reg [SW-1:0] alloc_seq_q;
  reg [SW-1:0] out_seq_q;
  reg [SW-1:0] old_u_q;                 // oldest un-issued sequence number
  // Same-cycle shadow of old_u_q's physical index. It has identical state
  // semantics, but gives the high-fanout picker a dedicated register Q.
  reg [AW-1:0] old_u_idx_q;

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

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) bkpr_r <= 1'b0;
    else        bkpr_r <= (occ > OCC_TH) || (win > WIN_TH);
  end

  // E005 updates these control vectors every cycle through their D inputs.
  // This preserves the original precedence (critical set beats alloc clear;
  // alloc clear beats pop set) without placing k_tgt/pop_oh on per-bit clock
  // gate enables.
  reg [D-1:0] crit_set_oh;
  integer ck;
  always @* begin
    crit_set_oh = {D{1'b0}};
    for (ck = 0; ck < 4; ck = ck + 1)
      if (kw_vld[ck]) crit_set_oh[k_tgt[ck]] = 1'b1;
  end
  wire [D-1:0] crit_n = (crit_q & ~alloc_oh) | crit_set_oh;
  wire [D-1:0] outp_n = (outp_q | pop_oh) & ~alloc_oh;

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
      old_u_q     <= {SW{1'b0}};
      old_u_idx_q <= {AW{1'b0}};
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
      old_u_idx_q <= old_u_n[AW-1:0];
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
  assign outp_o      = outp_q;
  assign alloc_seq_o = alloc_seq_q;
  assign out_seq_o   = out_seq_q;
  assign old_u_o     = old_u_q;
  assign old_u_idx_o = old_u_idx_q;

endmodule
