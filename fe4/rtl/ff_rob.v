// =============================================================================
// ff_rob - ROB storage + per-entry state machines, result write-back,
//          wake-up, sequence counters, oldest-un-issued pointer, BKPR
//
// RTL revision : 4FE-safe-v42
// Experiment   : E042-R64-IQ32
// Based on     : 4FE-safe-v28 / E029-R32
// Changes      : 64-entry storage/retirement ROB; IQ occupancy drives issue BKPR
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
  input  wire                iq_over,
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

  function [3:0] pe8;
    input [7:0] v;
    integer i;
    begin
      pe8 = 4'b0;
      for (i = 7; i >= 0; i = i - 1)
        if (v[i]) pe8 = {1'b1, i[2:0]};
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
  reg [D-1:0]  old_u_oh_q;              // physical one-hot form of old_u_q

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
  // oldest-un-issued pointer: bounded catch-up, clamped at alloc frontier.
  // At most four entries issue per cycle, so an eight-entry catch-up window
  // drains a released head faster than new issued state can accumulate. This
  // replaces the timing-dominant 64-entry global scan with eight parallel
  // indexed reads and a small priority encoder.
  // -------------------------------------------------------------------------
  reg [SW-1:0] adv;
  reg [SW-1:0] adv_raw, dist_f;
  wire [D-1:0] iss_eff = iss_q | picked;
  wire [7:0] issued_win;
  genvar gw;
  generate
    for (gw = 0; gw < 8; gw = gw + 1) begin : g_issue_window
      wire [D-1:0] win_mask;
      if (gw == 0)
        assign win_mask = old_u_oh_q;
      else
        assign win_mask = {old_u_oh_q[D-gw-1:0],
                           old_u_oh_q[D-1:D-gw]};
      assign issued_win[gw] = |(iss_eff & win_mask);
    end
  endgenerate
  wire [3:0] first_gap = pe8(~issued_win);
  always @* begin
    // picked is now the registered issue/commit bitmap.  Include it in the
    // look-ahead so delaying the ROB state write until issue does not add an
    // extra cycle to oldest-unissued pointer advancement.
    adv_raw = first_gap[3]
              ? {{(SW-3){1'b0}}, first_gap[2:0]}
              : {{(SW-4){1'b0}}, 4'd8};
    dist_f     = alloc_seq_q - old_u_q;
    adv = (adv_raw > dist_f) ? dist_f : adv_raw;
  end
  wire [SW-1:0] old_u_n = old_u_q + adv;
  reg [D-1:0] old_u_oh_n;
  always @* begin
    case (adv[3:0])
      4'd0: old_u_oh_n = old_u_oh_q;
      4'd1: old_u_oh_n = {old_u_oh_q[D-2:0], old_u_oh_q[D-1]};
      4'd2: old_u_oh_n = {old_u_oh_q[D-3:0], old_u_oh_q[D-1:D-2]};
      4'd3: old_u_oh_n = {old_u_oh_q[D-4:0], old_u_oh_q[D-1:D-3]};
      4'd4: old_u_oh_n = {old_u_oh_q[D-5:0], old_u_oh_q[D-1:D-4]};
      4'd5: old_u_oh_n = {old_u_oh_q[D-6:0], old_u_oh_q[D-1:D-5]};
      4'd6: old_u_oh_n = {old_u_oh_q[D-7:0], old_u_oh_q[D-1:D-6]};
      4'd7: old_u_oh_n = {old_u_oh_q[D-8:0], old_u_oh_q[D-1:D-7]};
      4'd8: old_u_oh_n = {old_u_oh_q[D-9:0], old_u_oh_q[D-1:D-8]};
      default: old_u_oh_n = old_u_oh_q;
    endcase
  end

  // -------------------------------------------------------------------------
  // BKPR (registered output)
  // -------------------------------------------------------------------------
  wire [SW-1:0] alloc_nxt = alloc_seq_q
                            + {{(SW-3){1'b0}}, acnt};
  wire [SW-1:0] occ       = alloc_nxt - out_seq_q;
  wire [SW-1:0] win       = alloc_nxt - old_u_q;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) bkpr_r <= 1'b0;
    else        bkpr_r <= (occ > OCC_TH) || (win > WIN_TH) || iq_over;
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
      old_u_oh_q  <= {{(D-1){1'b0}}, 1'b1};
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
      old_u_oh_q  <= old_u_oh_n;
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

endmodule
