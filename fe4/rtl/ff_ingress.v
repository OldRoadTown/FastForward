// =============================================================================
// ff_ingress - unconditional PKTIN S0 + four-beat elastic queue,
//              valid-lane compaction,
//              per-packet attribute/dependency resolve, slot rotation,
//              allocation one-hot
//
// RTL revision : 4FE-safe-v74a
// Experiment   : E074A-R32-unconditional-input
// Based on     : E074-R32-ingress-admission
// Changes      : isolate raw PKTIN behind an unconditional S0 register; all
//                queue and BKPR decisions use only registered input state
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
  // Unconditional input boundary register + elastic input queue
  // -------------------------------------------------------------------------
  // Raw PKTIN appears only on the D side of these registers. In particular,
  // raw in_vld is not allowed to control queue writes, BKPR, or ROB admission.
  // The payload/control registers are intentionally reset-free but are still
  // sampled every cycle; s0_vld_q is the sole qualifier for their contents.
  reg [3:0]   s0_vld_q;
  reg [511:0] s0_data_q;
  reg [19:0]  s0_ctrl_q;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      s0_vld_q <= 4'b0;
    else
      s0_vld_q <= in_vld;
  end

  always @(posedge clk) begin
    s0_data_q <= in_data_f;
    s0_ctrl_q <= in_ctrl_f;
  end

  // q0 is the consumable head. q1/q2/q3 absorb the registered S0 beat and the
  // documented BKPR response tail when the ROB temporarily stops admitting.
  reg [2:0]   beat_count_q;
  reg [3:0]   q0_vld_q, q1_vld_q, q2_vld_q, q3_vld_q;
  reg [511:0] q0_data_q, q1_data_q, q2_data_q, q3_data_q;
  reg [19:0]  q0_ctrl_q, q1_ctrl_q, q2_ctrl_q, q3_ctrl_q;

  wire        in_push = |s0_vld_q;
  wire        head_pop = (beat_count_q != 3'd0) && admit_i;
  reg  [2:0]  beat_count_n;
  always @* begin
    beat_count_n = beat_count_q;
    case ({head_pop, in_push})
      2'b01: beat_count_n = beat_count_q + 3'd1;
      2'b10: beat_count_n = beat_count_q - 3'd1;
      default: begin end
    endcase
  end

  // Valid/control state is reset; the wide datapath remains enable-gated and
  // reset-free. Predicting the post-edge queue count avoids an empty refill
  // bubble when q0 drains while BKPR is high.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      beat_count_q <= 3'd0;
      q0_vld_q     <= 4'b0;
      q1_vld_q     <= 4'b0;
      q2_vld_q     <= 4'b0;
      q3_vld_q     <= 4'b0;
      bkpr_r       <= 1'b0;
    end else begin
      case ({head_pop, in_push})
        2'b01: begin
          case (beat_count_q)
            3'd0: q0_vld_q <= s0_vld_q;
            3'd1: q1_vld_q <= s0_vld_q;
            3'd2: q2_vld_q <= s0_vld_q;
            3'd3: q3_vld_q <= s0_vld_q;
            default: begin end
          endcase
          if (beat_count_q != 3'd4)
            beat_count_q <= beat_count_q + 3'd1;
        end
        2'b10: begin
          case (beat_count_q)
            3'd1: q0_vld_q <= 4'b0;
            3'd2: begin
              q0_vld_q <= q1_vld_q;
              q1_vld_q <= 4'b0;
            end
            3'd3: begin
              q0_vld_q <= q1_vld_q;
              q1_vld_q <= q2_vld_q;
              q2_vld_q <= 4'b0;
            end
            3'd4: begin
              q0_vld_q <= q1_vld_q;
              q1_vld_q <= q2_vld_q;
              q2_vld_q <= q3_vld_q;
              q3_vld_q <= 4'b0;
            end
            default: begin end
          endcase
          beat_count_q <= beat_count_q - 3'd1;
        end
        2'b11: begin
          case (beat_count_q)
            3'd1: q0_vld_q <= s0_vld_q;
            3'd2: begin
              q0_vld_q <= q1_vld_q;
              q1_vld_q <= s0_vld_q;
            end
            3'd3: begin
              q0_vld_q <= q1_vld_q;
              q1_vld_q <= q2_vld_q;
              q2_vld_q <= s0_vld_q;
            end
            3'd4: begin
              q0_vld_q <= q1_vld_q;
              q1_vld_q <= q2_vld_q;
              q2_vld_q <= q3_vld_q;
              q3_vld_q <= s0_vld_q;
            end
            default: begin end
          endcase
        end
        default: begin end
      endcase
      bkpr_r <= (beat_count_n >= 3'd3)
                 || ((beat_count_q != 3'd0) && !admit_i);
    end
  end

  always @(posedge clk) begin
    case ({head_pop, in_push})
      2'b01: begin
        case (beat_count_q)
          3'd0: begin q0_data_q <= s0_data_q; q0_ctrl_q <= s0_ctrl_q; end
          3'd1: begin q1_data_q <= s0_data_q; q1_ctrl_q <= s0_ctrl_q; end
          3'd2: begin q2_data_q <= s0_data_q; q2_ctrl_q <= s0_ctrl_q; end
          3'd3: begin q3_data_q <= s0_data_q; q3_ctrl_q <= s0_ctrl_q; end
          default: begin end
        endcase
      end
      2'b10: begin
        case (beat_count_q)
          3'd2: begin q0_data_q <= q1_data_q; q0_ctrl_q <= q1_ctrl_q; end
          3'd3: begin
            q0_data_q <= q1_data_q; q0_ctrl_q <= q1_ctrl_q;
            q1_data_q <= q2_data_q; q1_ctrl_q <= q2_ctrl_q;
          end
          3'd4: begin
            q0_data_q <= q1_data_q; q0_ctrl_q <= q1_ctrl_q;
            q1_data_q <= q2_data_q; q1_ctrl_q <= q2_ctrl_q;
            q2_data_q <= q3_data_q; q2_ctrl_q <= q3_ctrl_q;
          end
          default: begin end
        endcase
      end
      2'b11: begin
        case (beat_count_q)
          3'd1: begin q0_data_q <= s0_data_q; q0_ctrl_q <= s0_ctrl_q; end
          3'd2: begin
            q0_data_q <= q1_data_q; q0_ctrl_q <= q1_ctrl_q;
            q1_data_q <= s0_data_q; q1_ctrl_q <= s0_ctrl_q;
          end
          3'd3: begin
            q0_data_q <= q1_data_q; q0_ctrl_q <= q1_ctrl_q;
            q1_data_q <= q2_data_q; q1_ctrl_q <= q2_ctrl_q;
            q2_data_q <= s0_data_q; q2_ctrl_q <= s0_ctrl_q;
          end
          3'd4: begin
            q0_data_q <= q1_data_q; q0_ctrl_q <= q1_ctrl_q;
            q1_data_q <= q2_data_q; q1_ctrl_q <= q2_ctrl_q;
            q2_data_q <= q3_data_q; q2_ctrl_q <= q3_ctrl_q;
            q3_data_q <= s0_data_q; q3_ctrl_q <= s0_ctrl_q;
          end
          default: begin end
        endcase
      end
      default: begin end
    endcase
  end

  // q0_vld_q is explicitly cleared when the final queued beat is popped, so
  // the count!=0 qualifier would be redundant logic on the admission path.
  wire [3:0] in_vld_q = q0_vld_q;
  wire [127:0] in_data_q [0:3];
  wire [4:0]   in_ctrl_q [0:3];
  genvar gi;
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_q0
      assign in_data_q[gi] = q0_data_q[gi*128 +: 128];
      assign in_ctrl_q[gi] = q0_ctrl_q[gi*5 +: 5];
    end
  endgenerate

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (rst_n && in_push && !head_pop && (beat_count_q == 3'd4))
      $error("[ff_ingress] elastic input queue overflow @%0t", $time);
    if (rst_n && (beat_count_q == 3'd0) &&
        (|q0_vld_q || |q1_vld_q || |q2_vld_q || |q3_vld_q))
      $error("[ff_ingress] nonempty valid state at zero queue count @%0t", $time);
    if (rst_n && (beat_count_q != 3'd0) && !(|q0_vld_q))
      $error("[ff_ingress] empty queue head at nonzero count @%0t", $time);
    if (rst_n && (beat_count_q < 3'd2) && |q1_vld_q)
      $error("[ff_ingress] unexpected first spill valid @%0t", $time);
    if (rst_n && (beat_count_q < 3'd3) && |q2_vld_q)
      $error("[ff_ingress] unexpected second spill valid @%0t", $time);
    if (rst_n && (beat_count_q < 3'd4) && |q3_vld_q)
      $error("[ff_ingress] unexpected third spill valid @%0t", $time);
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
