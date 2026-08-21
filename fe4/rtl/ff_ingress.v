// =============================================================================
// ff_ingress - three-beat circular-spill PKTIN queue, valid-lane compaction,
//              per-packet attribute/dependency resolve, slot rotation,
//              allocation one-hot
//
// RTL revision : 4FE-safe-v78
// Experiment   : E078-R32-head-tail-spill
// Based on     : E077-R32-circular-spill
// Changes      : use independent one-bit head/tail pointers so each wide spill
//                bank has a regular enqueue-only datapath
//
// Slot rotation: ROB entry e is only ever written from fixed source slot
// e[1:0], so each entry has a single input write source.
// =============================================================================
module ff_ingress #(
  parameter D  = 32,
  parameter AW = 5,
  parameter SW = 6
)(
  input  wire            clk,
  input  wire            rst_n,
  // raw PKTIN (unregistered - registered inside, per spec)
  input  wire [3:0]      in_vld,
  input  wire [511:0]    in_data_f,     // 4 x 128
  input  wire [19:0]     in_ctrl_f,     // 4 x 5
  // context
  input  wire [SW-1:0]   alloc_seq,
  input  wire [D-1:0]    res_known,     // resv | res_now | res_pred
  input  wire            admit_i,       // ROB can consume the current head
  // allocation outputs
  output wire [2:0]      acnt_o,
  output wire [511:0]    slot_dat_f,    // 4 x 128, slot j -> entries e[1:0]==j
  output wire [7:0]      slot_lat_f,    // 4 x 2
  output wire [4*AW-1:0] slot_tgt_f,
  output wire [3:0]      slot_rdy_o,
  output wire [3:0]      slot_wtg_o,
  output wire [3:0]      slot_isdep_o,
  output wire [D-1:0]    alloc_oh_o,
  // critical marking (a new dependent makes its target critical)
  output wire [3:0]      kw_vld_o,      // k valid && dependent
  output wire [4*AW-1:0] k_tgt_f,
  output reg             bkpr_r
);

  // -------------------------------------------------------------------------
  // unpack
  // -------------------------------------------------------------------------
  wire [127:0] in_data [0:3];
  wire [4:0]   in_ctrl [0:3];
  genvar gi;
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_up
      assign in_data[gi] = in_data_f[gi*128 +: 128];
      assign in_ctrl[gi] = in_ctrl_f[gi*5 +: 5];
    end
  endgenerate

  // -------------------------------------------------------------------------
  // Elastic input queue
  // -------------------------------------------------------------------------
  // q0 is the original S0 register. sp0/sp1 are circular spill banks used only
  // when the ROB cannot consume q0. The two spill beats exactly cover the
  // documented two-cycle / eight-packet response after BKPR is asserted.
  // Independent head/tail pointers make each spill bank an enqueue-only data
  // register. A simultaneous dequeue/enqueue reads the old head value into q0
  // before the same physical bank can be reused as the new tail.
  reg [1:0]   beat_count_q;
  reg         spill_head_q;
  reg         spill_tail_q;
  reg [3:0]   q0_vld_q, sp0_vld_q, sp1_vld_q;
  reg [511:0] q0_data_q, sp0_data_q, sp1_data_q;
  reg [19:0]  q0_ctrl_q, sp0_ctrl_q, sp1_ctrl_q;

  wire        in_push = |in_vld;
  wire        head_pop = (beat_count_q != 2'd0) && admit_i;
  wire        spill_pop = head_pop && (beat_count_q >= 2'd2);
  wire        q0_take_input = in_push &&
                              ((beat_count_q == 2'd0) ||
                               (head_pop && (beat_count_q == 2'd1)));
  wire        spill_push = in_push && !q0_take_input &&
                           (head_pop || (beat_count_q != 2'd3));
  reg  [2:0]  beat_count_n;
  always @* begin
    beat_count_n = {1'b0, beat_count_q};
    case ({head_pop, in_push})
      2'b01: beat_count_n = {1'b0, beat_count_q} + 3'd1;
      2'b10: beat_count_n = {1'b0, beat_count_q} - 3'd1;
      default: begin end
    endcase
  end

  // Valid/control state is reset; the wide datapath remains enable-gated and
  // reset-free. Predicting the post-edge queue count avoids an empty refill
  // bubble when q0 drains while BKPR is high.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      beat_count_q <= 2'd0;
      spill_head_q <= 1'b0;
      spill_tail_q <= 1'b0;
      q0_vld_q     <= 4'b0;
      sp0_vld_q    <= 4'b0;
      sp1_vld_q    <= 4'b0;
      bkpr_r       <= 1'b0;
    end else begin
      if (q0_take_input)
        q0_vld_q <= in_vld;
      else if (spill_pop)
        q0_vld_q <= spill_head_q ? sp1_vld_q : sp0_vld_q;
      else if (head_pop)
        q0_vld_q <= 4'b0;

      case ({spill_pop && !spill_head_q,
             spill_push && !spill_tail_q})
        2'b01, 2'b11: sp0_vld_q <= in_vld;
        2'b10:        sp0_vld_q <= 4'b0;
        default: begin end
      endcase
      case ({spill_pop && spill_head_q,
             spill_push && spill_tail_q})
        2'b01, 2'b11: sp1_vld_q <= in_vld;
        2'b10:        sp1_vld_q <= 4'b0;
        default: begin end
      endcase

      if (spill_pop)  spill_head_q <= ~spill_head_q;
      if (spill_push) spill_tail_q <= ~spill_tail_q;
      if (in_push && !head_pop && (beat_count_q != 2'd3))
        beat_count_q <= beat_count_q + 2'd1;
      else if (head_pop && !in_push)
        beat_count_q <= beat_count_q - 2'd1;
      bkpr_r <= (beat_count_n >= 3'd2)
                 || ((beat_count_q != 2'd0) && !admit_i);
    end
  end

  always @(posedge clk) begin
    if (q0_take_input) begin
      q0_data_q <= in_data_f;
      q0_ctrl_q <= in_ctrl_f;
    end else if (spill_pop) begin
      if (spill_head_q) begin
        q0_data_q <= sp1_data_q;
        q0_ctrl_q <= sp1_ctrl_q;
      end else begin
        q0_data_q <= sp0_data_q;
        q0_ctrl_q <= sp0_ctrl_q;
      end
    end
    if (spill_push && !spill_tail_q) begin
      sp0_data_q <= in_data_f;
      sp0_ctrl_q <= in_ctrl_f;
    end
    if (spill_push && spill_tail_q) begin
      sp1_data_q <= in_data_f;
      sp1_ctrl_q <= in_ctrl_f;
    end
  end

  wire [3:0] in_vld_q = (beat_count_q != 2'd0) ? q0_vld_q : 4'b0;
  wire [127:0] in_data_q [0:3];
  wire [4:0]   in_ctrl_q [0:3];
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_q0
      assign in_data_q[gi] = q0_data_q[gi*128 +: 128];
      assign in_ctrl_q[gi] = q0_ctrl_q[gi*5 +: 5];
    end
  endgenerate

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (rst_n && in_push && !head_pop && (beat_count_q == 2'd3))
      $error("[ff_ingress] elastic input queue overflow @%0t", $time);
    if (rst_n && (beat_count_q == 2'd0) &&
        (|q0_vld_q || |sp0_vld_q || |sp1_vld_q))
      $error("[ff_ingress] nonempty valid state at zero queue count @%0t", $time);
    if (rst_n && (beat_count_q != 2'd0) && !(|q0_vld_q))
      $error("[ff_ingress] empty queue head at nonzero count @%0t", $time);
    if (rst_n && (beat_count_q < 2'd2) &&
        (|sp0_vld_q || |sp1_vld_q))
      $error("[ff_ingress] unexpected spill valid @%0t", $time);
    if (rst_n && (beat_count_q < 2'd2) &&
        (spill_head_q != spill_tail_q))
      $error("[ff_ingress] empty spill pointer mismatch @%0t", $time);
    if (rst_n && (beat_count_q == 2'd2) &&
        ((spill_head_q == spill_tail_q) ||
         (spill_head_q ? (!(|sp1_vld_q) || |sp0_vld_q)
                       : (!(|sp0_vld_q) || |sp1_vld_q))))
      $error("[ff_ingress] invalid single-spill state @%0t", $time);
    if (rst_n && (beat_count_q == 2'd3) &&
        ((spill_head_q != spill_tail_q) ||
         !(|sp0_vld_q) || !(|sp1_vld_q)))
      $error("[ff_ingress] invalid full-spill state @%0t", $time);
  end
`endif

  // -------------------------------------------------------------------------
  // valid-lane compaction into packet order
  // -------------------------------------------------------------------------
  reg [127:0] comp_data [0:3];
  reg [4:0]   comp_ctrl [0:3];
  reg [2:0]   acnt;

  // Keep the wide packet-data mux independent of the narrow control mux.
  // This prevents control-only dependency logic from inheriting a 133-bit
  // compaction cone while preserving the exact packet-order mapping.
  always @* begin
    comp_data[0] = in_data_q[0];
    comp_data[1] = in_data_q[1];
    comp_data[2] = in_data_q[2];
    comp_data[3] = in_data_q[3];
    case (in_vld_q)
      4'b0010: comp_data[0] = in_data_q[1];
      4'b0100: comp_data[0] = in_data_q[2];
      4'b1000: comp_data[0] = in_data_q[3];
      4'b0101: comp_data[1] = in_data_q[2];
      4'b1001: comp_data[1] = in_data_q[3];
      4'b0110: begin
        comp_data[0] = in_data_q[1];
        comp_data[1] = in_data_q[2];
      end
      4'b1010: begin
        comp_data[0] = in_data_q[1];
        comp_data[1] = in_data_q[3];
      end
      4'b1100: begin
        comp_data[0] = in_data_q[2];
        comp_data[1] = in_data_q[3];
      end
      4'b1011: comp_data[2] = in_data_q[3];
      4'b1101: begin
        comp_data[1] = in_data_q[2];
        comp_data[2] = in_data_q[3];
      end
      4'b1110: begin
        comp_data[0] = in_data_q[1];
        comp_data[1] = in_data_q[2];
        comp_data[2] = in_data_q[3];
      end
      default: begin end
    endcase
  end

  always @* begin
    comp_ctrl[0] = in_ctrl_q[0];
    comp_ctrl[1] = in_ctrl_q[1];
    comp_ctrl[2] = in_ctrl_q[2];
    comp_ctrl[3] = in_ctrl_q[3];
    acnt    = 3'd0;
    case (in_vld_q)
      4'b0000: acnt = 3'd0;
      4'b0001: acnt = 3'd1;
      4'b0010: begin acnt = 3'd1; comp_ctrl[0] = in_ctrl_q[1]; end
      4'b0100: begin acnt = 3'd1; comp_ctrl[0] = in_ctrl_q[2]; end
      4'b1000: begin acnt = 3'd1; comp_ctrl[0] = in_ctrl_q[3]; end
      4'b0011: acnt = 3'd2;
      4'b0101: begin acnt = 3'd2; comp_ctrl[1] = in_ctrl_q[2]; end
      4'b1001: begin acnt = 3'd2; comp_ctrl[1] = in_ctrl_q[3]; end
      4'b0110: begin acnt = 3'd2; comp_ctrl[0] = in_ctrl_q[1];
                     comp_ctrl[1] = in_ctrl_q[2]; end
      4'b1010: begin acnt = 3'd2; comp_ctrl[0] = in_ctrl_q[1];
                     comp_ctrl[1] = in_ctrl_q[3]; end
      4'b1100: begin acnt = 3'd2; comp_ctrl[0] = in_ctrl_q[2];
                     comp_ctrl[1] = in_ctrl_q[3]; end
      4'b0111: acnt = 3'd3;
      4'b1011: begin acnt = 3'd3; comp_ctrl[2] = in_ctrl_q[3]; end
      4'b1101: begin acnt = 3'd3; comp_ctrl[1] = in_ctrl_q[2];
                     comp_ctrl[2] = in_ctrl_q[3]; end
      4'b1110: begin acnt = 3'd3; comp_ctrl[0] = in_ctrl_q[1];
                     comp_ctrl[1] = in_ctrl_q[2];
                     comp_ctrl[2] = in_ctrl_q[3]; end
      4'b1111: acnt = 3'd4;
      default: acnt = 3'd0;
    endcase
  end

  // -------------------------------------------------------------------------
  // per-packet (k = position in packet order) attributes + dependency resolve
  // -------------------------------------------------------------------------
  reg [1:0]    k_lat  [0:3];
  reg [2:0]    k_dep  [0:3];
  reg [AW-1:0] k_tgt  [0:3];
  reg          k_isdep[0:3];

  integer k;
  reg [SW-1:0] seq_k, tgt_k;
  always @* begin
    for (k = 0; k < 4; k = k + 1) begin
      k_lat[k]   = comp_ctrl[k][1:0];
      k_dep[k]   = comp_ctrl[k][4:2];
      k_isdep[k] = (k_dep[k] != 3'd0);
      seq_k      = alloc_seq + k[SW-1:0];
      tgt_k      = seq_k - {{(SW-3){1'b0}}, k_dep[k]};
      k_tgt[k]   = tgt_k[AW-1:0];
    end
  end

  // Resolve readiness directly on the four registered input lanes.  The
  // prefix rank is the packet-order position of each valid lane.  Using the
  // lane's own control avoids selecting dependency bits through comp_ctrl
  // before target arithmetic; the result is written straight to its physical
  // ROB source slot, avoiding a second ready-bit rotation mux afterwards.
  reg [1:0]    lane_rank [0:3];
  reg [2:0]    lane_dep [0:3];
  reg [SW-1:0] lane_seq, lane_tgt_seq;
  reg          lane_isdep, lane_incyc, lane_tdone;
  reg [3:0]    slot_rdy_direct, slot_wtg_direct;
  reg [1:0]    lane_slot;
  integer l;
  always @* begin
    lane_rank[0] = 2'd0;
    lane_rank[1] = {1'b0, in_vld_q[0]};
    lane_rank[2] = {1'b0, in_vld_q[0]} + {1'b0, in_vld_q[1]};
    lane_rank[3] = {1'b0, in_vld_q[0]} + {1'b0, in_vld_q[1]}
                   + {1'b0, in_vld_q[2]};
    slot_rdy_direct = 4'b0;
    slot_wtg_direct = 4'b0;
    for (l = 0; l < 4; l = l + 1) begin
      lane_dep[l]  = in_ctrl_q[l][4:2];
      lane_isdep   = (lane_dep[l] != 3'd0);
      lane_seq     = alloc_seq + {{(SW-2){1'b0}}, lane_rank[l]};
      lane_tgt_seq = lane_seq - {{(SW-3){1'b0}}, lane_dep[l]};
      lane_incyc   = lane_isdep
                     && ({1'b0, lane_dep[l]}
                         <= {2'b0, lane_rank[l]});
      lane_tdone   = res_known[lane_tgt_seq[AW-1:0]];
      lane_slot    = alloc_seq[1:0] + lane_rank[l];
      if (in_vld_q[l]) begin
        slot_rdy_direct[lane_slot] = !lane_isdep
                                      || (!lane_incyc && lane_tdone);
        slot_wtg_direct[lane_slot] = lane_isdep
                                      && (lane_incyc || !lane_tdone);
      end
    end
  end

  // -------------------------------------------------------------------------
  // rotate packet-order slots so entry e gets fixed source slot e[1:0]
  // -------------------------------------------------------------------------
  reg [127:0]   slot_dat [0:3];
  reg [1:0]     slot_lat [0:3];
  reg [AW-1:0]  slot_tgt [0:3];
  reg [3:0]     slot_rdy;
  reg [3:0]     slot_wtg;
  reg [3:0]     slot_isdep;

  integer j;
  reg [1:0] kj;
  always @* begin
    for (j = 0; j < 4; j = j + 1) begin
      kj            = j[1:0] - alloc_seq[1:0];
      slot_dat[j]   = comp_data[kj];
      slot_lat[j]   = k_lat[kj];
      slot_tgt[j]   = k_tgt[kj];
      slot_rdy[j]   = slot_rdy_direct[j];
      slot_wtg[j]   = slot_wtg_direct[j];
      slot_isdep[j] = k_isdep[kj];
    end
  end

  reg [D-1:0] alloc_oh;
  reg [SW-1:0] aseq;
  always @* begin
    alloc_oh = {D{1'b0}};
    for (k = 0; k < 4; k = k + 1) begin
      aseq = alloc_seq + k[SW-1:0];
      if (k[2:0] < acnt) alloc_oh[aseq[AW-1:0]] = 1'b1;
    end
  end

  // -------------------------------------------------------------------------
  // pack outputs
  // -------------------------------------------------------------------------
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_pk
      assign slot_dat_f[gi*128 +: 128] = slot_dat[gi];
      assign slot_lat_f[gi*2 +: 2]     = slot_lat[gi];
      assign slot_tgt_f[gi*AW +: AW]   = slot_tgt[gi];
    end
  endgenerate
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_pw
      // Mark every allocated dependency target critical.  Previously this
      // used k_wtg, which put sched/pre_idx -> res_known on the ROB crit_q
      // clock-enable path.  Over-marking an already-resolved target is safe:
      // crit_q only changes priority while that target is still ready.
      // A blocked head may mark its already-allocated predecessor critical
      // before the head itself enters the ROB. This is safe because crit only
      // affects ready-entry priority, and it keeps admit_i out of this path.
      assign kw_vld_o[gi]          = (gi[2:0] < acnt) && k_isdep[gi];
      assign k_tgt_f[gi*AW +: AW]  = k_tgt[gi];
    end
  endgenerate
  assign acnt_o       = acnt;
  assign slot_rdy_o   = slot_rdy;
  assign slot_wtg_o   = slot_wtg;
  assign slot_isdep_o = slot_isdep;
  assign alloc_oh_o   = admit_i ? alloc_oh : {D{1'b0}};

endmodule
