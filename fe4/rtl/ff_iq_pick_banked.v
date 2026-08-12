// =============================================================================
// ff_iq_pick_banked - E045 two-stage 4x8 banked IQ picker
//
// Base       : E042-R64-IQ32
// Experiment : E045
//
// I0a searches four interleaved eight-entry banks independently and registers
// the first two normal/critical candidates for every latency class. I0b only
// arbitrates those registered records. Keeping two candidates per bank hides
// the one-cycle stale-record window after a pick without feeding the global
// arbitration result back into the local search in the same cycle.
// =============================================================================
module ff_iq_pick_banked #(
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

  localparam TGT_L = 0;
  localparam ROB_L = RAW;
  localparam QIX_L = 2*RAW;
  localparam AGE_L = 2*RAW+QAW;
  localparam IQOH_L = AGE_L+RAW;
  localparam BANKOH_L = IQOH_L+QD;
  localparam LOCALOH_L = BANKOH_L+8;
  localparam RW    = LOCALOH_L+9;

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

  reg [NFE-1:0] pk_v_int;
  reg [QAW-1:0] pk_qix_q [0:NFE-1];
  reg [QD-1:0]  pk_iq_oh_q [0:NFE-1];
  wire [QD-1:0] picked_iq_w;
  wire [RD-1:0] picked_rob_w;
  wire [QD-1:0] ready_avail = iq_v & ~picked_iq_w
                                & (iq_rdy | (WAKE_BYPASS ? iq_wake
                                                         : {QD{1'b0}}));

  // Candidate records carry a registered circular age. All records entering
  // the global tournament share the same rbase sample, so only small unsigned
  // comparisons remain in I0b.
  wire [RW-1:0] bank_n1_d [0:NFE-1][0:3];
  wire [RW-1:0] bank_n2_d [0:NFE-1][0:3];
  wire [RW-1:0] bank_c1_d [0:NFE-1][0:3];
  wire [RW-1:0] bank_c2_d [0:NFE-1][0:3];
  reg  [RW-1:0] bank_n1_q [0:NFE-1][0:3];
  reg  [RW-1:0] bank_n2_q [0:NFE-1][0:3];
  reg  [RW-1:0] bank_c1_q [0:NFE-1][0:3];
  reg  [RW-1:0] bank_c2_q [0:NFE-1][0:3];

  genvar gf, gb, ge, gx;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_local_class
      for (gb = 0; gb < 4; gb = gb + 1) begin : g_local_bank
        wire [7:0] cand, ccand, cand2, ccand2;
        wire [7:0] oldest1, oldest2, coldest1, coldest2;
        wire [8*RW-1:0] n0, n20, c0, c20;
        wire [4*RW-1:0] n1, n21, c1, c21;
        wire [2*RW-1:0] n2, n22, c2, c22;

        for (ge = 0; ge < 8; ge = ge + 1) begin : g_local_leaf
          localparam integer QS = 4*ge+gb;
          wire [7:0] nblock1, nblock2, cblock1, cblock2;
          assign cand[ge]  = ready_avail[QS]
                              && (iq_lat[QS] == gf[1:0]);
          assign ccand[ge] = cand[ge] && iq_crit[QS];
          for (gx = 0; gx < 8; gx = gx + 1) begin : g_local_block
            localparam integer XS = 4*gx+gb;
            assign nblock1[gx] = cand[gx]
                                  && iq_older_f[XS*QD+QS];
            assign cblock1[gx] = ccand[gx]
                                  && iq_older_f[XS*QD+QS];
            assign nblock2[gx] = cand2[gx]
                                  && iq_older_f[XS*QD+QS];
            assign cblock2[gx] = ccand2[gx]
                                  && iq_older_f[XS*QD+QS];
          end
          assign oldest1[ge]  = cand[ge] && !(|nblock1);
          assign coldest1[ge] = ccand[ge] && !(|cblock1);
          assign oldest2[ge]  = cand2[ge] && !(|nblock2);
          assign coldest2[ge] = ccand2[ge] && !(|cblock2);
          assign n0[ge*RW +: RW] = {RW{oldest1[ge]}}
                                    & {1'b1,
                                       (8'b1 << iq_rob[QS][2:0]),
                                       (8'b1 << iq_rob[QS][5:3]),
                                       ({{(QD-1){1'b0}}, 1'b1} << QS),
                                       iq_rob[QS]-rbase,
                                       QS[QAW-1:0], iq_rob[QS], iq_tgt[QS]};
          assign n20[ge*RW +: RW] = {RW{oldest2[ge]}}
                                     & {1'b1,
                                        (8'b1 << iq_rob[QS][2:0]),
                                        (8'b1 << iq_rob[QS][5:3]),
                                        ({{(QD-1){1'b0}}, 1'b1} << QS),
                                        iq_rob[QS]-rbase,
                                        QS[QAW-1:0], iq_rob[QS], iq_tgt[QS]};
          assign c0[ge*RW +: RW] = {RW{coldest1[ge]}}
                                    & {1'b1,
                                       (8'b1 << iq_rob[QS][2:0]),
                                       (8'b1 << iq_rob[QS][5:3]),
                                       ({{(QD-1){1'b0}}, 1'b1} << QS),
                                       iq_rob[QS]-rbase,
                                       QS[QAW-1:0], iq_rob[QS], iq_tgt[QS]};
          assign c20[ge*RW +: RW] = {RW{coldest2[ge]}}
                                     & {1'b1,
                                        (8'b1 << iq_rob[QS][2:0]),
                                        (8'b1 << iq_rob[QS][5:3]),
                                        ({{(QD-1){1'b0}}, 1'b1} << QS),
                                        iq_rob[QS]-rbase,
                                        QS[QAW-1:0], iq_rob[QS], iq_tgt[QS]};
        end
        assign cand2  = cand & ~oldest1;
        assign ccand2 = ccand & ~coldest1;
        for (ge = 0; ge < 4; ge = ge + 1) begin : g_local_t1
          assign n1[ge*RW +: RW] = n0[(2*ge)*RW +: RW]
                                     | n0[(2*ge+1)*RW +: RW];
          assign n21[ge*RW +: RW] = n20[(2*ge)*RW +: RW]
                                      | n20[(2*ge+1)*RW +: RW];
          assign c1[ge*RW +: RW] = c0[(2*ge)*RW +: RW]
                                     | c0[(2*ge+1)*RW +: RW];
          assign c21[ge*RW +: RW] = c20[(2*ge)*RW +: RW]
                                      | c20[(2*ge+1)*RW +: RW];
        end
        for (ge = 0; ge < 2; ge = ge + 1) begin : g_local_t2
          assign n2[ge*RW +: RW] = n1[(2*ge)*RW +: RW]
                                     | n1[(2*ge+1)*RW +: RW];
          assign n22[ge*RW +: RW] = n21[(2*ge)*RW +: RW]
                                      | n21[(2*ge+1)*RW +: RW];
          assign c2[ge*RW +: RW] = c1[(2*ge)*RW +: RW]
                                     | c1[(2*ge+1)*RW +: RW];
          assign c22[ge*RW +: RW] = c21[(2*ge)*RW +: RW]
                                      | c21[(2*ge+1)*RW +: RW];
        end
        assign bank_n1_d[gf][gb] = n2[0*RW +: RW] | n2[1*RW +: RW];
        assign bank_n2_d[gf][gb] = n22[0*RW +: RW] | n22[1*RW +: RW];
        assign bank_c1_d[gf][gb] = c2[0*RW +: RW] | c2[1*RW +: RW];
        assign bank_c2_d[gf][gb] = c22[0*RW +: RW] | c22[1*RW +: RW];
      end
    end
  endgenerate

  integer bf, bb;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (bf = 0; bf < NFE; bf = bf + 1)
        for (bb = 0; bb < 4; bb = bb + 1) begin
          bank_n1_q[bf][bb] <= {RW{1'b0}};
          bank_n2_q[bf][bb] <= {RW{1'b0}};
          bank_c1_q[bf][bb] <= {RW{1'b0}};
          bank_c2_q[bf][bb] <= {RW{1'b0}};
        end
    end else begin
      for (bf = 0; bf < NFE; bf = bf + 1)
        for (bb = 0; bb < 4; bb = bb + 1) begin
          bank_n1_q[bf][bb] <= bank_n1_d[bf][bb];
          bank_n2_q[bf][bb] <= bank_n2_d[bf][bb];
          bank_c1_q[bf][bb] <= bank_c1_d[bf][bb];
          bank_c2_q[bf][bb] <= bank_c2_d[bf][bb];
        end
    end
  end

  function [RW-1:0] older_rec;
    input [RW-1:0] a;
    input [RW-1:0] b;
    begin
      if (!a[RW-1]) older_rec = b;
      else if (!b[RW-1]) older_rec = a;
      else if (a[AGE_L +: RAW] <= b[AGE_L +: RAW]) older_rec = a;
      else older_rec = b;
    end
  endfunction

  wire [RW-1:0] pri_rec [0:NFE-1];
  wire [RW-1:0] sec_rec [0:NFE-1];
  wire [NFE-1:0] fnd_raw;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_global_class
      wire [4*RW-1:0] nr0, cr0;
      wire [2*RW-1:0] nr1, cr1;
      wire [8*RW-1:0] sn0, sr0;
      wire [4*RW-1:0] sr1;
      wire [2*RW-1:0] sr2;
      wire [RW-1:0] normal_best, critical_best;
      for (gb = 0; gb < 4; gb = gb + 1) begin : g_revalidate
        // A slot cannot be reused on the same edge that clears valid_q, so a
        // registered record can become stale only by matching the current
        // picked one-hot. Avoid reading live IQ state in this pipeline stage.
        wire nlive1 = bank_n1_q[gf][gb][RW-1]
                      && !(|(bank_n1_q[gf][gb][IQOH_L +: QD]
                              & picked_iq_w));
        wire nlive2 = bank_n2_q[gf][gb][RW-1]
                      && !(|(bank_n2_q[gf][gb][IQOH_L +: QD]
                              & picked_iq_w));
        wire clive1 = bank_c1_q[gf][gb][RW-1]
                      && !(|(bank_c1_q[gf][gb][IQOH_L +: QD]
                              & picked_iq_w));
        wire clive2 = bank_c2_q[gf][gb][RW-1]
                      && !(|(bank_c2_q[gf][gb][IQOH_L +: QD]
                              & picked_iq_w));
        wire [RW-1:0] nfirst = bank_n1_q[gf][gb] & {RW{nlive1}};
        wire [RW-1:0] nsecond = bank_n2_q[gf][gb] & {RW{nlive2}};
        wire [RW-1:0] cfirst = bank_c1_q[gf][gb] & {RW{clive1}};
        wire [RW-1:0] csecond = bank_c2_q[gf][gb] & {RW{clive2}};
        assign nr0[gb*RW +: RW] = nlive1 ? nfirst : nsecond;
        assign cr0[gb*RW +: RW] = clive1 ? cfirst : csecond;
        assign sn0[(2*gb)*RW +: RW] = nfirst;
        assign sn0[(2*gb+1)*RW +: RW] = nsecond;
      end
      for (ge = 0; ge < 2; ge = ge + 1) begin : g_global_t1
        assign nr1[ge*RW +: RW] = older_rec(nr0[(2*ge)*RW +: RW],
                                             nr0[(2*ge+1)*RW +: RW]);
        assign cr1[ge*RW +: RW] = older_rec(cr0[(2*ge)*RW +: RW],
                                             cr0[(2*ge+1)*RW +: RW]);
      end
      assign normal_best = older_rec(nr1[0*RW +: RW], nr1[1*RW +: RW]);
      assign critical_best = older_rec(cr1[0*RW +: RW], cr1[1*RW +: RW]);
      wire use_crit = critical_best[RW-1]
                      && (normal_best[ROB_L +: RAW] != rbase);
      assign pri_rec[gf] = use_crit ? critical_best : normal_best;
      assign fnd_raw[gf] = pri_rec[gf][RW-1];

      for (ge = 0; ge < 8; ge = ge + 1) begin : g_secondary_filter
        wire same_primary = pri_rec[gf][RW-1]
                            && (sn0[ge*RW+QIX_L +: QAW]
                                == pri_rec[gf][QIX_L +: QAW]);
        assign sr0[ge*RW +: RW] = sn0[ge*RW +: RW]
                                   & {RW{!same_primary}};
      end
      for (ge = 0; ge < 4; ge = ge + 1) begin : g_secondary_t1
        assign sr1[ge*RW +: RW] = older_rec(sr0[(2*ge)*RW +: RW],
                                             sr0[(2*ge+1)*RW +: RW]);
      end
      for (ge = 0; ge < 2; ge = ge + 1) begin : g_secondary_t2
        assign sr2[ge*RW +: RW] = older_rec(sr1[(2*ge)*RW +: RW],
                                             sr1[(2*ge+1)*RW +: RW]);
      end
      assign sec_rec[gf] = older_rec(sr2[0*RW +: RW], sr2[1*RW +: RW]);
    end
  endgenerate

  reg [RAW-1:0] pk_idx_q [0:NFE-1];
  reg [RAW-1:0] pk_tgt_q [0:NFE-1];
  reg [1:0]     pk_lat_q [0:NFE-1];
  reg [7:0]     pk_bank_oh_q [0:NFE-1];
  reg [7:0]     pk_local_oh_q [0:NFE-1];

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

  wire [NFE-1:0] sec_fnd;
  wire [QAW-1:0] sec_qix [0:NFE-1];
  wire [RAW-1:0] sec_rob [0:NFE-1];
  wire [RAW-1:0] sec_tgt [0:NFE-1];
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_secondary_export
      assign sec_fnd[gf] = (DUAL_STEAL != 0) && sec_rec[gf][RW-1];
      assign sec_qix[gf] = sec_rec[gf][QIX_L +: QAW];
      assign sec_rob[gf] = sec_rec[gf][ROB_L +: RAW];
      assign sec_tgt[gf] = sec_rec[gf][TGT_L +: RAW];
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
    for (dc = 0; dc < NFE; dc = dc + 1) begin
      don_ok[dc] = sec_v_q[dc] && iq_v[sec_qix_q[dc]]
                   && iq_rdy[sec_qix_q[dc]]
                   && (iq_rob[sec_qix_q[dc]] == sec_rob_q[dc])
                   && !(fnd[dc]
                        && (pri_rec[dc][QIX_L +: QAW] == sec_qix_q[dc]));
      for (f = 0; f < NFE; f = f + 1)
        if (pk_v_int[f] && (pk_qix_q[f] == sec_qix_q[dc]))
          don_ok[dc] = 1'b0;
    end
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
  reg [QD-1:0]  pk_iq_oh_n [0:NFE-1];
  reg [RAW-1:0] pk_idx_n [0:NFE-1];
  reg [RAW-1:0] pk_tgt_n [0:NFE-1];
  reg [1:0]     pk_lat_n [0:NFE-1];
  reg [7:0]     pk_bank_oh_n [0:NFE-1];
  reg [7:0]     pk_local_oh_n [0:NFE-1];
  always @* begin
    for (f = 0; f < NFE; f = f + 1) begin
      pk_v_n[f]   = fnd[f] | (st1_v && (st1_rr == f[1:0]))
                             | (st2_v && (st2_rr == f[1:0]));
      pk_qix_n[f] = pri_rec[f][QIX_L +: QAW];
      pk_iq_oh_n[f] = pri_rec[f][IQOH_L +: QD];
      pk_idx_n[f] = pri_rec[f][ROB_L +: RAW];
      pk_tgt_n[f] = pri_rec[f][TGT_L +: RAW];
      pk_lat_n[f] = f[1:0];
      if (st1_v && (st1_rr == f[1:0])) begin
        pk_qix_n[f] = st1_qix; pk_idx_n[f] = st1_rob;
        pk_tgt_n[f] = st1_tgt; pk_lat_n[f] = st1_dc;
        pk_iq_oh_n[f] = ({{(QD-1){1'b0}}, 1'b1} << st1_qix);
      end else if (st2_v && (st2_rr == f[1:0])) begin
        pk_qix_n[f] = st2_qix; pk_idx_n[f] = st2_rob;
        pk_tgt_n[f] = st2_tgt; pk_lat_n[f] = st2_dc;
        pk_iq_oh_n[f] = ({{(QD-1){1'b0}}, 1'b1} << st2_qix);
      end
      pk_bank_oh_n[f]  = pri_rec[f][BANKOH_L +: 8];
      pk_local_oh_n[f] = pri_rec[f][LOCALOH_L +: 8];
      if (st1_v && (st1_rr == f[1:0])) begin
        pk_bank_oh_n[f]  = (8'b1 << st1_rob[5:3]);
        pk_local_oh_n[f] = (8'b1 << st1_rob[2:0]);
      end else if (st2_v && (st2_rr == f[1:0])) begin
        pk_bank_oh_n[f]  = (8'b1 << st2_rob[5:3]);
        pk_local_oh_n[f] = (8'b1 << st2_rob[2:0]);
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pk_v_int <= {NFE{1'b0}};
    end else begin
      pk_v_int <= pk_v_n;
    end
  end
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1) begin
      pk_qix_q[f]     <= pk_qix_n[f];
      pk_iq_oh_q[f]    <= pk_iq_oh_n[f];
      pk_idx_q[f]      <= pk_idx_n[f];
      pk_tgt_q[f]      <= pk_tgt_n[f];
      pk_lat_q[f]      <= pk_lat_n[f];
      pk_bank_oh_q[f]  <= pk_bank_oh_n[f];
      pk_local_oh_q[f] <= pk_local_oh_n[f];
    end
  end

  wire [RD-1:0] pk_rob_oh [0:NFE-1];
  genvar pf_g, pb_g;
  generate
    for (pf_g = 0; pf_g < NFE; pf_g = pf_g + 1) begin : g_pick_rob_oh
      for (pb_g = 0; pb_g < RD; pb_g = pb_g + 1) begin : g_pick_rob_bit
        assign pk_rob_oh[pf_g][pb_g] = pk_bank_oh_q[pf_g][pb_g/8]
                                        & pk_local_oh_q[pf_g][pb_g%8];
      end
    end
  endgenerate
  assign picked_iq_w = (pk_iq_oh_q[0] & {QD{pk_v_int[0]}})
                       | (pk_iq_oh_q[1] & {QD{pk_v_int[1]}})
                       | (pk_iq_oh_q[2] & {QD{pk_v_int[2]}})
                       | (pk_iq_oh_q[3] & {QD{pk_v_int[3]}});
  assign picked_rob_w = (pk_rob_oh[0] & {RD{pk_v_int[0]}})
                        | (pk_rob_oh[1] & {RD{pk_v_int[1]}})
                        | (pk_rob_oh[2] & {RD{pk_v_int[2]}})
                        | (pk_rob_oh[3] & {RD{pk_v_int[3]}});

  reg [1:0] rob_src [0:RD-1];
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1)
      if (pk_v_int[f]) rob_src[pk_idx_q[f]] <= f[1:0];
  end

  assign picked_count = {2'b0, pk_v_int[0]} + {2'b0, pk_v_int[1]}
                        + {2'b0, pk_v_int[2]} + {2'b0, pk_v_int[3]};
  always @* pk_v_q = pk_v_int;
  assign picked_iq  = picked_iq_w;
  assign picked_rob = picked_rob_w;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_export
      assign pk_idx_f[gf*RAW +: RAW] = pk_idx_q[gf];
      assign pk_tgt_f[gf*RAW +: RAW] = pk_tgt_q[gf];
      assign pk_lat_f[gf*2 +: 2] = pk_lat_q[gf];
      assign pk_bank_oh_f[gf*8 +: 8] = pk_bank_oh_q[gf];
      assign pk_local_oh_f[gf*8 +: 8] = pk_local_oh_q[gf];
    end
    for (gi = 0; gi < RD; gi = gi + 1) begin : g_src
      assign rob_src_f[gi*2 +: 2] = rob_src[gi];
    end
  endgenerate

endmodule
