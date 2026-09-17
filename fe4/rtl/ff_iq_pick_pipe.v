// =============================================================================
// ff_iq_pick_pipe - deeply pipelined 32-entry safe-profile IQ picker
//
// RTL revision : 4FE-safe-v43
// Experiment   : E043-400ps
//
// P0: age-matrix blocker reductions -> normal/critical oldest one-hot
// P1: five-level one-hot descriptor reduction
// P2: critical-vs-normal choice
// P3: FE slot check, one-hot decode, and registered commit
//
// reserve_q holds every P0 winner until its P3 disposition, so all four
// stages may accept a new batch every cycle without selecting an entry twice.
// This module implements only the timing-safe no-bypass/no-steal profile; the
// top retains ff_iq_pick for the optional dual/full A/B configurations.
// =============================================================================
module ff_iq_pick_pipe #(
  parameter QD       = 32,
  parameter QAW      = 5,
  parameter RD       = 64,
  parameter RAW      = 6,
  parameter NFE      = 4,
  parameter REG_FEIN = 0
)(
  input  wire                    clk,
  input  wire                    rst_n,
  input  wire [QD-1:0]           iq_v,
  input  wire [QD-1:0]           iq_crit,
  input  wire [QD*RAW-1:0]       iq_rob_f,
  input  wire [QD*RAW-1:0]       iq_tgt_f,
  input  wire [QD*QD-1:0]        iq_older_f,
  input  wire [4*QD-1:0]         iq_class_ready_f,
  input  wire [4*QD-1:0]         iq_class_critical_ready_f,
  input  wire [RAW-1:0]          rbase,
  input  wire [NFE*4-1:0]        sched_v_f,
  output wire [QD-1:0]           picked_iq,
  output wire [2:0]              picked_count,
  output wire [RD-1:0]           picked_rob,
  output reg  [NFE-1:0]          pk_v_q,
  output wire [NFE*RAW-1:0]      pk_idx_f,
  output wire [NFE*RAW-1:0]      pk_tgt_f,
  output wire [NFE*2-1:0]        pk_lat_f,
  output wire [NFE*8-1:0]        pk_bank_oh_f,
  output wire [NFE*8-1:0]        pk_local_oh_f,
  output wire [RD*2-1:0]         rob_src_f
);

  localparam TGT_L = 0;
  localparam ROB_L = RAW;
  localparam QIX_L = 2*RAW;
  localparam RW    = 1+2*RAW+QAW;

  wire [RAW-1:0] iq_rob [0:QD-1];
  wire [RAW-1:0] iq_tgt [0:QD-1];
  wire [QD-1:0] class_ready [0:NFE-1];
  wire [QD-1:0] class_critical_ready [0:NFE-1];
  wire [3:0] sched_v [0:NFE-1];
  genvar gi, gf, ge, gx;
  generate
    for (gi = 0; gi < QD; gi = gi + 1) begin : g_unpack_iq
      assign iq_rob[gi] = iq_rob_f[gi*RAW +: RAW];
      assign iq_tgt[gi] = iq_tgt_f[gi*RAW +: RAW];
    end
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_unpack_class
      assign class_ready[gf] = iq_class_ready_f[gf*QD +: QD];
      assign class_critical_ready[gf] =
                         iq_class_critical_ready_f[gf*QD +: QD];
      assign sched_v[gf] = sched_v_f[gf*4 +: 4];
    end
  endgenerate

  // -------------------------------------------------------------------------
  // P0: predecoded class-ready masks enter only the 32-way blocker reduction.
  // -------------------------------------------------------------------------
  reg [QD-1:0] reserve_q;
  wire [QD-1:0] p0_normal_oh [0:NFE-1];
  wire [QD-1:0] p0_critical_oh [0:NFE-1];
  wire [QD-1:0] p0_available [0:NFE-1];
  reg [QD-1:0] p0_normal_q [0:NFE-1];
  reg [QD-1:0] p0_critical_q [0:NFE-1];
  wire [QD-1:0] p0_new_union = p0_normal_oh[0] | p0_critical_oh[0]
                                | p0_normal_oh[1] | p0_critical_oh[1]
                                | p0_normal_oh[2] | p0_critical_oh[2]
                                | p0_normal_oh[3] | p0_critical_oh[3];
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_p0_class
      wire [QD-1:0] normal_block [0:QD-1];
      wire [QD-1:0] critical_block [0:QD-1];
      wire [QD-1:0] p0_critical_available;
      // reserve_q captures the newly computed winners on this same edge.
      // Feeding the previous P0 winner registers back into availability put
      // three extra OR levels ahead of every 32-way blocker tree.
      assign p0_available[gf] = class_ready[gf] & ~reserve_q;
      assign p0_critical_available = class_critical_ready[gf] & ~reserve_q;
      for (ge = 0; ge < QD; ge = ge + 1) begin : g_p0_leaf
        for (gx = 0; gx < QD; gx = gx + 1) begin : g_p0_block
          assign normal_block[ge][gx] = p0_available[gf][gx]
                                           & iq_older_f[gx*QD+ge];
          assign critical_block[ge][gx] = p0_critical_available[gx]
                                           & iq_older_f[gx*QD+ge];
        end
        assign p0_normal_oh[gf][ge] = p0_available[gf][ge]
                                       & !(|normal_block[ge]);
        assign p0_critical_oh[gf][ge] = p0_critical_available[ge]
                                         & !(|critical_block[ge]);
      end
    end
  endgenerate

  // -------------------------------------------------------------------------
  // P1: balanced descriptor reduction.  The IQ metadata is stable because
  // reserve_q prevents the selected slot from reaching commit twice.
  // -------------------------------------------------------------------------
  wire [RW-1:0] p1_normal_rec [0:NFE-1];
  wire [RW-1:0] p1_critical_rec [0:NFE-1];
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_p1_class
      wire [QD*RW-1:0] n0, c0;
      wire [(QD/2)*RW-1:0] n1, c1;
      wire [(QD/4)*RW-1:0] n2, c2;
      wire [(QD/8)*RW-1:0] n3, c3;
      wire [(QD/16)*RW-1:0] n4, c4;
      for (ge = 0; ge < QD; ge = ge + 1) begin : g_p1_leaf
        assign n0[ge*RW +: RW] = {RW{p0_normal_q[gf][ge]}}
                                   & {1'b1, ge[QAW-1:0],
                                      iq_rob[ge], iq_tgt[ge]};
        assign c0[ge*RW +: RW] = {RW{p0_critical_q[gf][ge]}}
                                   & {1'b1, ge[QAW-1:0],
                                      iq_rob[ge], iq_tgt[ge]};
      end
      for (ge = 0; ge < QD/2; ge = ge + 1) begin : g_p1_t1
        assign n1[ge*RW +: RW] = n0[(2*ge)*RW +: RW]
                                  | n0[(2*ge+1)*RW +: RW];
        assign c1[ge*RW +: RW] = c0[(2*ge)*RW +: RW]
                                  | c0[(2*ge+1)*RW +: RW];
      end
      for (ge = 0; ge < QD/4; ge = ge + 1) begin : g_p1_t2
        assign n2[ge*RW +: RW] = n1[(2*ge)*RW +: RW]
                                  | n1[(2*ge+1)*RW +: RW];
        assign c2[ge*RW +: RW] = c1[(2*ge)*RW +: RW]
                                  | c1[(2*ge+1)*RW +: RW];
      end
      for (ge = 0; ge < QD/8; ge = ge + 1) begin : g_p1_t3
        assign n3[ge*RW +: RW] = n2[(2*ge)*RW +: RW]
                                  | n2[(2*ge+1)*RW +: RW];
        assign c3[ge*RW +: RW] = c2[(2*ge)*RW +: RW]
                                  | c2[(2*ge+1)*RW +: RW];
      end
      for (ge = 0; ge < QD/16; ge = ge + 1) begin : g_p1_t4
        assign n4[ge*RW +: RW] = n3[(2*ge)*RW +: RW]
                                  | n3[(2*ge+1)*RW +: RW];
        assign c4[ge*RW +: RW] = c3[(2*ge)*RW +: RW]
                                  | c3[(2*ge+1)*RW +: RW];
      end
      assign p1_normal_rec[gf] = n4[0*RW +: RW] | n4[1*RW +: RW];
      assign p1_critical_rec[gf] = c4[0*RW +: RW] | c4[1*RW +: RW];
    end
  endgenerate

  reg [RW-1:0] p1_normal_q [0:NFE-1];
  reg [RW-1:0] p1_critical_q [0:NFE-1];
  reg [QD-1:0] p1_normal_oh_q [0:NFE-1];
  reg [QD-1:0] p1_critical_oh_q [0:NFE-1];

  // -------------------------------------------------------------------------
  // P2: critical choice is isolated from both the blocker and descriptor tree.
  // -------------------------------------------------------------------------
  wire [NFE-1:0] p2_use_critical;
  wire [RW-1:0] p2_selected_rec [0:NFE-1];
  wire [QD-1:0] p2_selected_oh [0:NFE-1];
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_p2_choice
      assign p2_use_critical[gf] = p1_critical_q[gf][RW-1]
                                    && (p1_normal_q[gf][ROB_L +: RAW]
                                        != rbase);
      assign p2_selected_rec[gf] = p2_use_critical[gf]
                                     ? p1_critical_q[gf] : p1_normal_q[gf];
      assign p2_selected_oh[gf] = p2_use_critical[gf]
                                    ? p1_critical_oh_q[gf]
                                    : p1_normal_oh_q[gf];
    end
  endgenerate

  reg [RW-1:0] p2_rec_q [0:NFE-1];
  reg [QD-1:0] p2_selected_oh_q [0:NFE-1];
  reg [QD-1:0] p2_all_oh_q [0:NFE-1];

  // -------------------------------------------------------------------------
  // P3: registered commit and ROB one-hot decode.
  // -------------------------------------------------------------------------
  reg [NFE-1:0] own_cfl;
  integer f;
  always @* begin
    for (f = 0; f < NFE; f = f + 1) begin
      own_cfl[f] = 1'b0;
      if (f <= 1)
        if (sched_v[f][f+2]) own_cfl[f] = 1'b1;
    end
  end

  wire [NFE-1:0] commit_v;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_p3_valid
      assign commit_v[gf] = p2_rec_q[gf][RW-1]
                              & ((REG_FEIN != 0) ? 1'b1 : ~own_cfl[gf]);
    end
  endgenerate

  reg [QD-1:0] picked_iq_n;
  reg [RD-1:0] picked_rob_n;
  reg [QD-1:0] commit_selected_oh;
  integer cf;
  always @* begin
    picked_iq_n = {QD{1'b0}};
    picked_rob_n = {RD{1'b0}};
    commit_selected_oh = {QD{1'b0}};
    for (cf = 0; cf < NFE; cf = cf + 1) begin
      if (commit_v[cf]) begin
        picked_iq_n = picked_iq_n | p2_selected_oh_q[cf];
        commit_selected_oh = commit_selected_oh | p2_selected_oh_q[cf];
        picked_rob_n[p2_rec_q[cf][ROB_L +: RAW]] = 1'b1;
      end
    end
  end

  wire [QD-1:0] p2_all_union = p2_all_oh_q[0] | p2_all_oh_q[1]
                                  | p2_all_oh_q[2] | p2_all_oh_q[3];
  wire [QD-1:0] release_drop = p2_all_union & ~commit_selected_oh;

  reg [NFE-1:0] pk_v_int;
  reg [RAW-1:0] pk_idx_q [0:NFE-1];
  reg [RAW-1:0] pk_tgt_q [0:NFE-1];
  reg [1:0] pk_lat_q [0:NFE-1];
  reg [7:0] pk_bank_oh_q [0:NFE-1];
  reg [7:0] pk_local_oh_q [0:NFE-1];
  reg [QD-1:0] picked_iq_q;
  reg [RD-1:0] picked_rob_q;

  integer sf;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reserve_q <= {QD{1'b0}};
      pk_v_int <= {NFE{1'b0}};
      picked_iq_q <= {QD{1'b0}};
      picked_rob_q <= {RD{1'b0}};
      for (sf = 0; sf < NFE; sf = sf + 1) begin
        p0_normal_q[sf] <= {QD{1'b0}};
        p0_critical_q[sf] <= {QD{1'b0}};
        p1_normal_q[sf] <= {RW{1'b0}};
        p1_critical_q[sf] <= {RW{1'b0}};
        p1_normal_oh_q[sf] <= {QD{1'b0}};
        p1_critical_oh_q[sf] <= {QD{1'b0}};
        p2_rec_q[sf] <= {RW{1'b0}};
        p2_selected_oh_q[sf] <= {QD{1'b0}};
        p2_all_oh_q[sf] <= {QD{1'b0}};
      end
    end else begin
      reserve_q <= (reserve_q & ~release_drop & ~picked_iq_q)
                    | p0_new_union;
      pk_v_int <= commit_v;
      picked_iq_q <= picked_iq_n;
      picked_rob_q <= picked_rob_n;
      for (sf = 0; sf < NFE; sf = sf + 1) begin
        p0_normal_q[sf] <= p0_normal_oh[sf];
        p0_critical_q[sf] <= p0_critical_oh[sf];
        p1_normal_q[sf] <= p1_normal_rec[sf];
        p1_critical_q[sf] <= p1_critical_rec[sf];
        p1_normal_oh_q[sf] <= p0_normal_q[sf];
        p1_critical_oh_q[sf] <= p0_critical_q[sf];
        p2_rec_q[sf] <= p2_selected_rec[sf];
        p2_selected_oh_q[sf] <= p2_selected_oh[sf];
        p2_all_oh_q[sf] <= p1_normal_oh_q[sf] | p1_critical_oh_q[sf];
      end
    end
  end

  always @(posedge clk) begin
    for (sf = 0; sf < NFE; sf = sf + 1) begin
      pk_idx_q[sf] <= p2_rec_q[sf][ROB_L +: RAW];
      pk_tgt_q[sf] <= p2_rec_q[sf][TGT_L +: RAW];
      pk_lat_q[sf] <= sf[1:0];
      pk_bank_oh_q[sf] <= 8'b0;
      pk_local_oh_q[sf] <= 8'b0;
      pk_bank_oh_q[sf][p2_rec_q[sf][ROB_L+3 +: 3]] <= 1'b1;
      pk_local_oh_q[sf][p2_rec_q[sf][ROB_L +: 3]] <= 1'b1;
    end
  end

  reg [1:0] rob_src [0:RD-1];
  always @(posedge clk) begin
    for (sf = 0; sf < NFE; sf = sf + 1)
      if (pk_v_int[sf]) rob_src[pk_idx_q[sf]] <= sf[1:0];
  end

  always @* pk_v_q = pk_v_int;
  assign picked_iq = picked_iq_q;
  assign picked_rob = picked_rob_q;
  assign picked_count = {2'b0, pk_v_q[0]} + {2'b0, pk_v_q[1]}
                        + {2'b0, pk_v_q[2]} + {2'b0, pk_v_q[3]};

  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_export
      assign pk_idx_f[gf*RAW +: RAW] = pk_idx_q[gf];
      assign pk_tgt_f[gf*RAW +: RAW] = pk_tgt_q[gf];
      assign pk_lat_f[gf*2 +: 2] = pk_lat_q[gf];
      assign pk_bank_oh_f[gf*8 +: 8] = pk_bank_oh_q[gf];
      assign pk_local_oh_f[gf*8 +: 8] = pk_local_oh_q[gf];
    end
    for (gi = 0; gi < RD; gi = gi + 1) begin : g_export_src
      assign rob_src_f[gi*2 +: 2] = rob_src[gi];
    end
  endgenerate

  wire _unused_ok = &{1'b0, iq_v[0], iq_crit[0]};

endmodule
