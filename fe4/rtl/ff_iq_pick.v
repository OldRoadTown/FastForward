// =============================================================================
// ff_iq_pick - balanced-tree picker for the decoupled issue queue
//
// Experiment : E053
// Base       : 4FE-safe-v28 / E029-R32
//
// The timing-sensitive search is bounded by QD=32 even though storage ROB is
// 64 entries. The IQ age matrix produces an oldest one-hot mask; a five-level
// OR tree carries the ROB tag and target without a post-pick descriptor read.
// =============================================================================
module ff_iq_pick #(
  parameter QD          = 32,
  parameter QAW         = 5,
  parameter RD          = 64,
  parameter RAW         = 6,
  parameter NFE         = 4,
  parameter WAKE_BYPASS = 0,
  parameter DUAL_STEAL  = 0,
  parameter REG_FEIN    = 0
)(
  input  wire                    clk,
  input  wire                    rst_n,
  input  wire [QD-1:0]           iq_v,
  input  wire [QD-1:0]           iq_rdy,
  input  wire [QD-1:0]           iq_crit,
  input  wire [QD-1:0]           iq_wake,
  input  wire [QD*RAW-1:0]       iq_rob_f,
  input  wire [QD*2-1:0]         iq_lat_f,
  input  wire [QD*RAW-1:0]       iq_tgt_f,
  input  wire [QD*QD-1:0]        iq_older_f,
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

  // Candidate record, LSB first: target, ROB tag, IQ slot, valid.
  localparam TGT_L = 0;
  localparam ROB_L = RAW;
  localparam QIX_L = 2*RAW;
  localparam RW    = 1+2*RAW+QAW;

  wire [RAW-1:0] iq_rob [0:QD-1];
  wire [1:0]     iq_lat [0:QD-1];
  wire [RAW-1:0] iq_tgt [0:QD-1];
  wire [3:0]     sched_v [0:NFE-1];
  genvar gi;
  generate
    for (gi = 0; gi < QD; gi = gi + 1) begin : g_unpack_iq
      assign iq_rob[gi] = iq_rob_f[gi*RAW +: RAW];
      assign iq_lat[gi] = iq_lat_f[gi*2 +: 2];
      assign iq_tgt[gi] = iq_tgt_f[gi*RAW +: RAW];
    end
    for (gi = 0; gi < NFE; gi = gi + 1) begin : g_unpack_sched
      assign sched_v[gi] = sched_v_f[gi*4 +: 4];
    end
  endgenerate

  reg [QD-1:0] picked_iq_q;
  wire [QD-1:0] ready_avail = iq_v & ~picked_iq_q
                                & (iq_rdy | (WAKE_BYPASS ? iq_wake
                                                         : {QD{1'b0}}));
  assign picked_count = {2'b0, pk_v_q[0]} + {2'b0, pk_v_q[1]}
                        + {2'b0, pk_v_q[2]} + {2'b0, pk_v_q[3]};

  // Per-class age-matrix selectors. The IQ records allocation order once;
  // selection only asks whether any live class candidate is marked older than
  // a leaf, then OR-reduces the resulting one-hot descriptor in five levels.
  // Critical may jump unless the normal oldest packet is the window head.
  wire [RW-1:0] pri_rec [0:NFE-1];
  wire [QD-1:0] class_cand [0:NFE-1];
  wire [QD-1:0] pri_oh [0:NFE-1];
  wire [NFE-1:0] fnd_raw;
  genvar gf, ge, gx;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_class
      wire [QD-1:0] normal_oldest, critical_oldest;
      wire [QD*RW-1:0] n0, c0;
      wire [(QD/2)*RW-1:0] n1, c1;
      wire [(QD/4)*RW-1:0] n2, c2;
      wire [(QD/8)*RW-1:0] n3, c3;
      wire [(QD/16)*RW-1:0] n4, c4;
      wire [RW-1:0] n5, c5;
      for (ge = 0; ge < QD; ge = ge + 1) begin : g_leaf
        wire [QD-1:0] normal_block, critical_block;
        assign class_cand[gf][ge] = ready_avail[ge]
                                      && (iq_lat[ge] == gf[1:0]);
        for (gx = 0; gx < QD; gx = gx + 1) begin : g_block
          assign normal_block[gx] = class_cand[gf][gx]
                                    && iq_older_f[gx*QD+ge];
          assign critical_block[gx] = class_cand[gf][gx] && iq_crit[gx]
                                      && iq_older_f[gx*QD+ge];
        end
        assign normal_oldest[ge] = class_cand[gf][ge]
                                   && !(|normal_block);
        assign critical_oldest[ge] = class_cand[gf][ge] && iq_crit[ge]
                                     && !(|critical_block);
        assign n0[ge*RW +: RW] = {RW{normal_oldest[ge]}}
                                  & {1'b1, ge[QAW-1:0],
                                     iq_rob[ge], iq_tgt[ge]};
        assign c0[ge*RW +: RW] = {RW{critical_oldest[ge]}}
                                  & {1'b1, ge[QAW-1:0],
                                     iq_rob[ge], iq_tgt[ge]};
      end
      for (ge = 0; ge < QD/2; ge = ge + 1) begin : g_t1
        assign n1[ge*RW +: RW] = n0[(2*ge)*RW +: RW]
                                | n0[(2*ge+1)*RW +: RW];
        assign c1[ge*RW +: RW] = c0[(2*ge)*RW +: RW]
                                | c0[(2*ge+1)*RW +: RW];
      end
      for (ge = 0; ge < QD/4; ge = ge + 1) begin : g_t2
        assign n2[ge*RW +: RW] = n1[(2*ge)*RW +: RW]
                                | n1[(2*ge+1)*RW +: RW];
        assign c2[ge*RW +: RW] = c1[(2*ge)*RW +: RW]
                                | c1[(2*ge+1)*RW +: RW];
      end
      for (ge = 0; ge < QD/8; ge = ge + 1) begin : g_t3
        assign n3[ge*RW +: RW] = n2[(2*ge)*RW +: RW]
                                | n2[(2*ge+1)*RW +: RW];
        assign c3[ge*RW +: RW] = c2[(2*ge)*RW +: RW]
                                | c2[(2*ge+1)*RW +: RW];
      end
      for (ge = 0; ge < QD/16; ge = ge + 1) begin : g_t4
        assign n4[ge*RW +: RW] = n3[(2*ge)*RW +: RW]
                                | n3[(2*ge+1)*RW +: RW];
        assign c4[ge*RW +: RW] = c3[(2*ge)*RW +: RW]
                                | c3[(2*ge+1)*RW +: RW];
      end
      assign n5 = n4[0*RW +: RW] | n4[1*RW +: RW];
      assign c5 = c4[0*RW +: RW] | c4[1*RW +: RW];
      wire use_crit = c5[RW-1]
                      && (n5[ROB_L +: RAW] != rbase);
      assign pri_oh[gf] = use_crit ? critical_oldest : normal_oldest;
      assign pri_rec[gf] = use_crit ? c5 : n5;
      assign fnd_raw[gf] = pri_rec[gf][RW-1];
    end
  endgenerate

  reg [NFE-1:0] pk_v_int;
  reg [RAW-1:0] pk_idx_q [0:NFE-1];
  reg [RAW-1:0] pk_tgt_q [0:NFE-1];
  reg [1:0]     pk_lat_q [0:NFE-1];

  reg [NFE-1:0] own_cfl;
  integer oc;
  always @* begin
    for (oc = 0; oc < NFE; oc = oc + 1) begin
      own_cfl[oc] = 1'b0;
      if (oc <= 1)
        if (sched_v[oc][oc+2]) own_cfl[oc] = 1'b1;
      if (oc < 3)
        if (pk_v_int[oc] && (pk_lat_q[oc] == oc[1:0] + 2'd1))
          own_cfl[oc] = 1'b1;
    end
  end
  wire [NFE-1:0] fnd = (REG_FEIN == 0) ? (fnd_raw & ~own_cfl) : fnd_raw;

  // Optional dual/full second-candidate path. It is generate-pruned from the
  // timing-safe build, while retaining the V28 throughput A/B configurations.
  wire [NFE-1:0] sec_fnd;
  wire [QAW-1:0] sec_qix [0:NFE-1];
  wire [RAW-1:0] sec_rob [0:NFE-1];
  wire [RAW-1:0] sec_tgt [0:NFE-1];
  genvar sx;
  generate
    if (DUAL_STEAL != 0) begin : g_secondary
      for (gf = 0; gf < NFE; gf = gf + 1) begin : g_sc
        wire [QD-1:0] secondary_cand, secondary_oldest;
        wire [QD*RW-1:0] s0;
        wire [(QD/2)*RW-1:0] s1;
        wire [(QD/4)*RW-1:0] s2;
        wire [(QD/8)*RW-1:0] s3;
        wire [(QD/16)*RW-1:0] s4;
        wire [RW-1:0] s5;
        for (ge = 0; ge < QD; ge = ge + 1) begin : g_sl
          wire [QD-1:0] secondary_block;
          assign secondary_cand[ge] = class_cand[gf][ge] & ~pri_oh[gf][ge];
          for (sx = 0; sx < QD; sx = sx + 1) begin : g_sb
            assign secondary_block[sx] = secondary_cand[sx]
                                         && iq_older_f[sx*QD+ge];
          end
          assign secondary_oldest[ge] = secondary_cand[ge]
                                         && !(|secondary_block);
          assign s0[ge*RW +: RW] = {RW{secondary_oldest[ge]}}
                                    & {1'b1, ge[QAW-1:0],
                                       iq_rob[ge], iq_tgt[ge]};
        end
        for (ge = 0; ge < QD/2; ge = ge + 1) begin : g_s1
          assign s1[ge*RW +: RW] = s0[(2*ge)*RW +: RW]
                                  | s0[(2*ge+1)*RW +: RW];
        end
        for (ge = 0; ge < QD/4; ge = ge + 1) begin : g_s2
          assign s2[ge*RW +: RW] = s1[(2*ge)*RW +: RW]
                                  | s1[(2*ge+1)*RW +: RW];
        end
        for (ge = 0; ge < QD/8; ge = ge + 1) begin : g_s3
          assign s3[ge*RW +: RW] = s2[(2*ge)*RW +: RW]
                                  | s2[(2*ge+1)*RW +: RW];
        end
        for (ge = 0; ge < QD/16; ge = ge + 1) begin : g_s4
          assign s4[ge*RW +: RW] = s3[(2*ge)*RW +: RW]
                                  | s3[(2*ge+1)*RW +: RW];
        end
        assign s5 = s4[0*RW +: RW] | s4[1*RW +: RW];
        assign sec_fnd[gf] = s5[RW-1];
        assign sec_qix[gf] = s5[QIX_L +: QAW];
        assign sec_rob[gf] = s5[ROB_L +: RAW];
        assign sec_tgt[gf] = s5[TGT_L +: RAW];
      end
    end else begin : g_no_secondary
      for (gf = 0; gf < NFE; gf = gf + 1) begin : g_ns
        assign sec_fnd[gf] = 1'b0;
        assign sec_qix[gf] = {QAW{1'b0}};
        assign sec_rob[gf] = {RAW{1'b0}};
        assign sec_tgt[gf] = {RAW{1'b0}};
      end
    end
  endgenerate

  reg [NFE-1:0] sec_v_q;
  reg [QAW-1:0] sec_qix_q [0:NFE-1];
  reg [RAW-1:0] sec_rob_q [0:NFE-1];
  reg [RAW-1:0] sec_tgt_q [0:NFE-1];
  integer f;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) sec_v_q <= {NFE{1'b0}};
    else        sec_v_q <= sec_fnd;
  end
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1) begin
      sec_qix_q[f] <= sec_qix[f];
      sec_rob_q[f] <= sec_rob[f];
      sec_tgt_q[f] <= sec_tgt[f];
    end
  end

  reg [NFE-1:0] don_ok;
  integer dc;
  always @* begin
    for (dc = 0; dc < NFE; dc = dc + 1)
      don_ok[dc] = sec_v_q[dc] && iq_v[sec_qix_q[dc]]
                   && iq_rdy[sec_qix_q[dc]]
                   && (iq_rob[sec_qix_q[dc]] == sec_rob_q[dc])
                   && !picked_iq_q[sec_qix_q[dc]]
                   && !(fnd[dc]
                        && (pri_rec[dc][QIX_L +: QAW] == sec_qix_q[dc]));
  end

  function stcfl;
    input [3:0] svr;
    input       pkv;
    input [1:0] pkl;
    input [1:0] cc;
    begin
      stcfl = 1'b0;
      if (cc <= 2'd1) begin
        if (cc == 2'd0) stcfl = svr[2];
        else            stcfl = svr[3];
      end
      if (cc != 2'd3)
        if (pkv && (pkl == cc + 2'd1)) stcfl = 1'b1;
    end
  endfunction

  reg st1_v, st2_v, st1_dv, st2_dv, st1_rv, st2_rv;
  reg [1:0] st1_dc, st2_dc, st1_rr, st2_rr;
  reg [QAW-1:0] st1_qix, st2_qix;
  reg [RAW-1:0] st1_rob, st2_rob, st1_tgt, st2_tgt;
  reg [RAW-1:0] d_age, c_age;
  integer rr;
  always @* begin
    st1_dv = 1'b0; st1_dc = 2'd0; st1_qix = {QAW{1'b0}};
    st1_rob = {RAW{1'b0}}; st1_tgt = {RAW{1'b0}};
    d_age = {RAW{1'b1}};
    for (dc = NFE-1; dc >= 0; dc = dc - 1) begin
      c_age = sec_rob_q[dc] - rbase;
      if (don_ok[dc] && (!st1_dv || (c_age < d_age))) begin
        st1_dv = 1'b1; st1_dc = dc[1:0]; st1_qix = sec_qix_q[dc];
        st1_rob = sec_rob_q[dc]; st1_tgt = sec_tgt_q[dc]; d_age = c_age;
      end
    end
    st1_rv = 1'b0; st1_rr = 2'd0;
    for (rr = NFE-1; rr >= 0; rr = rr - 1)
      if (!fnd[rr] && !stcfl(sched_v[rr], pk_v_int[rr],
                             pk_lat_q[rr], st1_dc)) begin
        st1_rv = 1'b1; st1_rr = rr[1:0];
      end
    st1_v = st1_dv & st1_rv & (REG_FEIN == 0) & (DUAL_STEAL != 0);

    st2_dv = 1'b0; st2_dc = 2'd0; st2_qix = {QAW{1'b0}};
    st2_rob = {RAW{1'b0}}; st2_tgt = {RAW{1'b0}};
    for (dc = 0; dc < NFE; dc = dc + 1)
      if (don_ok[dc] && (!st1_v || (dc[1:0] != st1_dc))) begin
        st2_dv = 1'b1; st2_dc = dc[1:0]; st2_qix = sec_qix_q[dc];
        st2_rob = sec_rob_q[dc]; st2_tgt = sec_tgt_q[dc];
      end
    st2_rv = 1'b0; st2_rr = 2'd0;
    for (rr = 0; rr < NFE; rr = rr + 1)
      if (!fnd[rr] && (!st1_v || (rr[1:0] != st1_rr))
          && !stcfl(sched_v[rr], pk_v_int[rr],
                    pk_lat_q[rr], st2_dc)) begin
        st2_rv = 1'b1; st2_rr = rr[1:0];
      end
    st2_v = st2_dv & st2_rv & st1_v & (DUAL_STEAL != 0);
  end

  reg [NFE-1:0] pk_v_n;
  reg [QAW-1:0] pk_qix_n [0:NFE-1];
  reg [RAW-1:0] pk_idx_n [0:NFE-1];
  reg [RAW-1:0] pk_tgt_n [0:NFE-1];
  reg [1:0]     pk_lat_n [0:NFE-1];
  reg [QD-1:0] picked_iq_n;
  always @* begin
    picked_iq_n = {QD{1'b0}};
    // Keep the registered IQ one-hot commit boundary: decoding pk_qix_q
    // after the edge would feed directly back into next-cycle ready_avail.
    for (f = 0; f < NFE; f = f + 1)
      picked_iq_n = picked_iq_n | (pri_oh[f] & {QD{fnd[f]}});
    for (f = 0; f < NFE; f = f + 1) begin
      pk_v_n[f]   = fnd[f] | (st1_v && (st1_rr == f[1:0]))
                             | (st2_v && (st2_rr == f[1:0]));
      pk_qix_n[f] = pri_rec[f][QIX_L +: QAW];
      pk_idx_n[f] = pri_rec[f][ROB_L +: RAW];
      pk_tgt_n[f] = pri_rec[f][TGT_L +: RAW];
      pk_lat_n[f] = f[1:0];
      if (st1_v && (st1_rr == f[1:0])) begin
        pk_qix_n[f] = st1_qix; pk_idx_n[f] = st1_rob;
        pk_tgt_n[f] = st1_tgt; pk_lat_n[f] = st1_dc;
      end else if (st2_v && (st2_rr == f[1:0])) begin
        pk_qix_n[f] = st2_qix; pk_idx_n[f] = st2_rob;
        pk_tgt_n[f] = st2_tgt; pk_lat_n[f] = st2_dc;
      end
      if ((st1_v && (st1_rr == f[1:0]))
          || (st2_v && (st2_rr == f[1:0])))
        picked_iq_n[pk_qix_n[f]] = 1'b1;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pk_v_int    <= {NFE{1'b0}};
      picked_iq_q <= {QD{1'b0}};
    end else begin
      pk_v_int    <= pk_v_n;
      picked_iq_q <= picked_iq_n;
    end
  end
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1) begin
      pk_idx_q[f]      <= pk_idx_n[f];
      pk_tgt_q[f]      <= pk_tgt_n[f];
      pk_lat_q[f]      <= pk_lat_n[f];
    end
  end

  reg [1:0] rob_src [0:RD-1];
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1)
      if (pk_v_int[f]) rob_src[pk_idx_q[f]] <= f[1:0];
  end

  always @* pk_v_q = pk_v_int;
  assign picked_iq = picked_iq_q;
  // Only the compact binary ROB coordinate crosses the picker edge.
  // Reconstruct the ROB commit masks and issue-read 8x8 coordinates after
  // that edge while retaining the IQ one-hot register to break feedback.
  wire [RD-1:0] pk_rob_oh [0:NFE-1];
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_export
      assign pk_idx_f[gf*RAW +: RAW] = pk_idx_q[gf];
      assign pk_tgt_f[gf*RAW +: RAW] = pk_tgt_q[gf];
      assign pk_lat_f[gf*2 +: 2] = pk_lat_q[gf];
      assign pk_bank_oh_f[gf*8 +: 8] = 8'b1 << pk_idx_q[gf][5:3];
      assign pk_local_oh_f[gf*8 +: 8] = 8'b1 << pk_idx_q[gf][2:0];
      for (gi = 0; gi < RD; gi = gi + 1) begin : g_rob_commit
        assign pk_rob_oh[gf][gi] = pk_v_int[gf]
                                      && (pk_idx_q[gf] == gi[RAW-1:0]);
      end
    end
    for (gi = 0; gi < RD; gi = gi + 1) begin : g_src
      assign rob_src_f[gi*2 +: 2] = rob_src[gi];
    end
  endgenerate
  assign picked_rob = pk_rob_oh[0] | pk_rob_oh[1]
                      | pk_rob_oh[2] | pk_rob_oh[3];

endmodule
