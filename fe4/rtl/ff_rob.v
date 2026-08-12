// =============================================================================
// ff_rob - ROB storage + per-entry state machines, result write-back,
//          wake-up, sequence counters, oldest-un-issued pointer, BKPR
//
// RTL revision : 4FE-safe-v61
// Experiment   : E061-R64-IQ32-predecoded-bkpr-thresholds
// Based on     : 4FE-safe-v28 / E029-R32
// Changes      : replace acnt add/compare with fixed BKPR thresholds
//
// Per-entry state: alloc -> (rdy | wtg) -> issued -> resv.
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
  output wire [D-1:0]        live_o,
  output wire [D-1:0]        out_oh_o,
  output wire [D*128-1:0]    rob_data_f,
  output wire [D*2-1:0]      rob_lat_f,
  output wire [D*AW-1:0]     rob_tgt_f,
  output wire [D-1:0]        rob_isdep_o,
  output wire [SW-1:0]       alloc_seq_o,
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
  reg [D-1:0]  live_q;                  // allocated and not yet retired

  reg [SW-1:0] alloc_seq_q;
  reg [D-1:0]  out_oh_q;                // physical one-hot retirement head
  reg [SW-1:0] old_u_q;                 // oldest un-issued sequence number
  reg [D-1:0]  old_u_oh_q;              // physical one-hot form of old_u_q
  reg [SW-1:0] adv_q;                   // next bounded catch-up, precomputed
  reg [D-1:0]  scan_oh_q;               // old_u_oh_q pre-rotated by adv_q
  reg [2:0]    pop_cnt_q;               // prior-cycle retirement credit
  reg [SW-1:0] occ_q;                   // occupancy plus pop_cnt_q credit
  reg [SW-1:0] win_q;                   // alloc_seq_q - old_u_q

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

  // Clear exactly the fixed head positions consumed this cycle.  Egress uses
  // live_q to distinguish the current allocation epoch from a stale retained
  // result, eliminating alloc_seq-out_seq from its completion check.
  wire [D-1:0] out_h1 = {out_oh_q[D-2:0], out_oh_q[D-1]};
  wire [D-1:0] out_h2 = {out_oh_q[D-3:0], out_oh_q[D-1:D-2]};
  wire [D-1:0] out_h3 = {out_oh_q[D-4:0], out_oh_q[D-1:D-3]};
  wire [D-1:0] out_h4 = {out_oh_q[D-5:0], out_oh_q[D-1:D-4]};
  wire [D-1:0] pop_oh = ({D{pop_therm[0]}} & out_oh_q)
                        | ({D{pop_therm[1]}} & out_h1)
                        | ({D{pop_therm[2]}} & out_h2)
                        | ({D{pop_therm[3]}} & out_h3);

  // Pre-wake from slot2 remains for latency classes 1..3. Latency class 0 has
  // no slot2 residence, so it wakes from the registered slot1/actual-return
  // tag. resv is written on that same edge; with WAKE_BYPASS=0 the dependent
  // reaches I1 only after the retained result is available.
  reg [D-1:0] wake_now;
  integer e;
  always @* begin
    for (e = 0; e < D; e = e + 1)
      wake_now[e] = wtg_q[e]
                    & (res_pred_r[rob_tgt[e]] | res_now_r[rob_tgt[e]]);
  end

  // -------------------------------------------------------------------------
  // oldest-un-issued pointer: bounded catch-up, clamped at alloc frontier.
  // At most four entries issue per cycle, so an eight-entry catch-up window
  // drains a released head faster than new issued state can accumulate. This
  // replaces the timing-dominant 64-entry global scan with eight parallel
  // indexed reads and a small priority encoder.
  // -------------------------------------------------------------------------
  reg [SW-1:0] adv_n;
  // Consume only committed issue state here. Including the incoming picked
  // bitmap saves at most one old_u catch-up cycle, but couples the registered
  // picker-coordinate decode back through the eight-entry window and priority
  // encoder. The bounded window still advances by up to eight per cycle, twice
  // the maximum issue rate, so this one-cycle lag cannot accumulate.
  wire [SW-1:0] old_u_n = old_u_q + adv_q;
  reg [D-1:0] old_u_oh_n;
  always @* begin
    case (adv_q[3:0])
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

  // scan_oh_q is registered beside adv_q and already points at the position
  // that old_u reaches on this edge.  The state scan therefore has no adv_q ->
  // 64-bit rotation dependency.  Prefix ANDs are written as a three-level
  // parallel network; run_oh directly represents lengths 0..8 and is then
  // encoded to the small advance register.
  wire [D-1:0] iss_eff = iss_q & live_q;
  wire [7:0] issued_win;
  genvar gw;
  generate
    for (gw = 0; gw < 8; gw = gw + 1) begin : g_issue_window
      wire [D-1:0] win_mask;
      if (gw == 0)
        assign win_mask = scan_oh_q;
      else
        assign win_mask = {scan_oh_q[D-gw-1:0],
                           scan_oh_q[D-1:D-gw]};
      assign issued_win[gw] = |(iss_eff & win_mask);
    end
  endgenerate
  wire [7:0] pref1 = issued_win & {issued_win[6:0], 1'b1};
  wire [7:0] pref2 = pref1 & {pref1[5:0], 2'b11};
  wire [7:0] pref4 = pref2 & {pref2[3:0], 4'b1111};
  wire [8:0] run_oh = {pref4[7],
                       pref4[6] & ~issued_win[7],
                       pref4[5] & ~issued_win[6],
                       pref4[4] & ~issued_win[5],
                       pref4[3] & ~issued_win[4],
                       pref4[2] & ~issued_win[3],
                       pref4[1] & ~issued_win[2],
                       pref4[0] & ~issued_win[1],
                       ~issued_win[0]};
  always @* begin
    adv_n = {SW{1'b0}};
    if (run_oh[1]) adv_n = {{(SW-1){1'b0}}, 1'b1};
    if (run_oh[2]) adv_n = {{(SW-2){1'b0}}, 2'd2};
    if (run_oh[3]) adv_n = {{(SW-2){1'b0}}, 2'd3};
    if (run_oh[4]) adv_n = {{(SW-3){1'b0}}, 3'd4};
    if (run_oh[5]) adv_n = {{(SW-3){1'b0}}, 3'd5};
    if (run_oh[6]) adv_n = {{(SW-3){1'b0}}, 3'd6};
    if (run_oh[7]) adv_n = {{(SW-3){1'b0}}, 3'd7};
    if (run_oh[8]) adv_n = {{(SW-4){1'b0}}, 4'd8};
  end

  reg [D-1:0] scan_oh_n;
  always @* begin
    case (adv_n[3:0])
      4'd0: scan_oh_n = old_u_oh_n;
      4'd1: scan_oh_n = {old_u_oh_n[D-2:0], old_u_oh_n[D-1]};
      4'd2: scan_oh_n = {old_u_oh_n[D-3:0], old_u_oh_n[D-1:D-2]};
      4'd3: scan_oh_n = {old_u_oh_n[D-4:0], old_u_oh_n[D-1:D-3]};
      4'd4: scan_oh_n = {old_u_oh_n[D-5:0], old_u_oh_n[D-1:D-4]};
      4'd5: scan_oh_n = {old_u_oh_n[D-6:0], old_u_oh_n[D-1:D-5]};
      4'd6: scan_oh_n = {old_u_oh_n[D-7:0], old_u_oh_n[D-1:D-6]};
      4'd7: scan_oh_n = {old_u_oh_n[D-8:0], old_u_oh_n[D-1:D-7]};
      4'd8: scan_oh_n = {old_u_oh_n[D-9:0], old_u_oh_n[D-1:D-8]};
      default: scan_oh_n = old_u_oh_n;
    endcase
  end

  // -------------------------------------------------------------------------
  // BKPR (registered output)
  // -------------------------------------------------------------------------
  // Delay retirement credit by one register before it reaches the occupancy
  // accumulator.  occ_q therefore equals physical occupancy + pop_cnt_q;
  // subtracting that registered credit here reconstructs the exact E058
  // occupancy decision while cutting resv -> pop encoder -> occ_q at a flop.
  // Preserve occ/win names because the testbench samples their causes.
  wire [SW-1:0] occ_base = occ_q - {{(SW-3){1'b0}}, pop_cnt_q};
  wire [SW-1:0] occ = occ_base + {{(SW-3){1'b0}}, acnt};
  wire [SW-1:0] win = win_q + {{(SW-3){1'b0}}, acnt};
  reg occ_over, win_over;
  always @* begin
    // acnt is only 0..4. Comparing the registered bases against five fixed
    // constants in parallel keeps in_vld_q/acnt out of the seven-bit carry
    // chain. occ/win above remain for testbench cause accounting.
    case (acnt)
      3'd0: begin occ_over = (occ_base > OCC_TH);
                   win_over = (win_q > WIN_TH);       end
      3'd1: begin occ_over = (occ_base > OCC_TH-{{(SW-1){1'b0}},1'b1});
                   win_over = (win_q > WIN_TH-{{(SW-1){1'b0}},1'b1});  end
      3'd2: begin occ_over = (occ_base > OCC_TH-{{(SW-2){1'b0}},2'd2});
                   win_over = (win_q > WIN_TH-{{(SW-2){1'b0}},2'd2});  end
      3'd3: begin occ_over = (occ_base > OCC_TH-{{(SW-2){1'b0}},2'd3});
                   win_over = (win_q > WIN_TH-{{(SW-2){1'b0}},2'd3});  end
      default: begin occ_over = (occ_base > OCC_TH-{{(SW-3){1'b0}},3'd4});
                     win_over = (win_q > WIN_TH-{{(SW-3){1'b0}},3'd4}); end
    endcase
  end
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) bkpr_r <= 1'b0;
    else        bkpr_r <= occ_over || win_over || iq_over;
  end

  // E005 updates the critical vector every cycle through its D input. This
  // preserves the original precedence without putting k_tgt on per-bit clock
  // gate enables. Retirement no longer needs retained binary sequence state:
  // out_oh_q advances on every pop, so an entry cannot pop twice.
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

  // Direct thermometer-to-rotation select avoids encode -> binary mux ->
  // decode on the head update path.
  wire [4:0] pop_count_oh = {pop_therm[3],
                             pop_therm[2] & ~pop_therm[3],
                             pop_therm[1] & ~pop_therm[2],
                             pop_therm[0] & ~pop_therm[1],
                             ~pop_therm[0]};
  wire [D-1:0] out_oh_n = ({D{pop_count_oh[0]}} & out_oh_q)
                          | ({D{pop_count_oh[1]}} & out_h1)
                          | ({D{pop_count_oh[2]}} & out_h2)
                          | ({D{pop_count_oh[3]}} & out_h3)
                          | ({D{pop_count_oh[4]}} & out_h4);

  // -------------------------------------------------------------------------
  // state update
  // -------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdy_q       <= {D{1'b0}};
      wtg_q       <= {D{1'b0}};
      iss_q       <= {D{1'b0}};
      resv_q      <= {D{1'b0}};
      live_q      <= {D{1'b0}};
      alloc_seq_q <= {SW{1'b0}};
      out_oh_q    <= {{(D-1){1'b0}}, 1'b1};
      old_u_q     <= {SW{1'b0}};
      old_u_oh_q  <= {{(D-1){1'b0}}, 1'b1};
      adv_q       <= {SW{1'b0}};
      scan_oh_q   <= {{(D-1){1'b0}}, 1'b1};
      pop_cnt_q   <= 3'd0;
      occ_q       <= {SW{1'b0}};
      win_q       <= {SW{1'b0}};
    end else begin
      for (e = 0; e < D; e = e + 1) begin
        if (alloc_oh[e]) begin
          rdy_q[e]  <= slot_rdy[e[1:0]];
          wtg_q[e]  <= slot_wtg[e[1:0]];
          iss_q[e]  <= 1'b0;
          resv_q[e] <= 1'b0;
          live_q[e] <= 1'b1;
        end else begin
          if (picked[e]) begin
            rdy_q[e] <= 1'b0;
            iss_q[e] <= 1'b1;
          end else if (wake_now[e]) begin
            rdy_q[e] <= 1'b1;
          end
          if (wake_now[e])  wtg_q[e]  <= 1'b0;
          if (res_now_r[e]) resv_q[e] <= 1'b1;
          if (pop_oh[e])    live_q[e] <= 1'b0;
        end
      end
      alloc_seq_q <= alloc_seq_q + {{(SW-3){1'b0}}, acnt};
      out_oh_q    <= out_oh_n;
      old_u_q     <= old_u_n;
      old_u_oh_q  <= old_u_oh_n;
      adv_q       <= adv_n;
      scan_oh_q   <= scan_oh_n;
      pop_cnt_q   <= pop_cnt;
      occ_q       <= occ;
      win_q       <= win_q + {{(SW-3){1'b0}}, acnt} - adv_q;
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
  // The IQ consumes this as a dependency-ready event. Including actual return
  // supplies the latency-0 case after removing its same-cycle issue bypass.
  assign res_pred_o  = res_pred_r | res_now_r;
  assign res_known_o = resv_q | res_now_r | res_pred_r;
  assign wake_now_o  = wake_now;
  assign rdy_o       = rdy_q;
  assign crit_o      = crit_q;
  assign resv_o      = resv_q;
  assign live_o      = live_q;
  assign out_oh_o    = out_oh_q;
  assign alloc_seq_o = alloc_seq_q;
  assign old_u_o     = old_u_q;

endmodule
