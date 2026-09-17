// =============================================================================
// ff_iq - decoupled 32-entry issue queue for a 64-entry storage ROB
//
// Experiment : E043-400ps
// Base       : E042-R64-IQ32
//
// Only scheduling descriptors live here. Packet/result data and retirement
// state remain in ff_rob. IQ slots are allocated from the free list, so their
// physical positions are independent of ROB tags. A 32x32 allocation-order
// matrix records the relative age once, keeping tag arithmetic out of pick.
// E043 adds banked allocation/pressure pipelines and per-class ready masks.
// =============================================================================
module ff_iq #(
  parameter QD  = 32,
  parameter QAW = 5,
  parameter RAW = 6
)(
  input  wire                    clk,
  input  wire                    rst_n,
  input  wire [2:0]              acnt,
  input  wire [RAW:0]            alloc_seq,
  input  wire [7:0]              slot_lat_f,
  input  wire [4*RAW-1:0]        slot_tgt_f,
  input  wire [3:0]              slot_rdy,
  input  wire [3:0]              slot_wtg,
  input  wire [3:0]              slot_isdep,
  input  wire [3:0]              kw_vld,
  input  wire [4*RAW-1:0]        k_tgt_f,
  input  wire [11:0]             k_dep_f,
  input  wire [(1<<RAW)-1:0]     res_pred,
  input  wire [(1<<RAW)-1:0]     res_known,
  input  wire [QD-1:0]           picked_iq,
  input  wire [2:0]              picked_count,
  output wire [QD-1:0]           iq_v_o,
  output wire [QD-1:0]           iq_rdy_o,
  output wire [QD-1:0]           iq_crit_o,
  output wire [QD-1:0]           iq_wake_o,
  output wire [QD*RAW-1:0]       iq_rob_f,
  output wire [QD*2-1:0]         iq_lat_f,
  output wire [QD*RAW-1:0]       iq_tgt_f,
  output wire [QD*QD-1:0]        iq_older_f,
  output wire [4*QD-1:0]         iq_class_ready_f,
  output wire [4*QD-1:0]         iq_class_critical_ready_f,
  output reg  [QAW:0]            iq_count,
  output wire [QAW:0]            iq_count_n,
  output wire                     iq_over_n
);

  wire [1:0]    slot_lat [0:3];
  wire [RAW-1:0] slot_tgt [0:3];
  wire [RAW-1:0] k_tgt [0:3];
  wire [2:0] k_dep [0:3];
  genvar gi;
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_unpack
      assign slot_lat[gi] = slot_lat_f[gi*2 +: 2];
      assign slot_tgt[gi] = slot_tgt_f[gi*RAW +: RAW];
      assign k_tgt[gi]    = k_tgt_f[gi*RAW +: RAW];
      assign k_dep[gi]    = k_dep_f[gi*3 +: 3];
    end
  endgenerate

  reg [QD-1:0] valid_q;
  reg [QD-1:0] ready_q;
  reg [QD-1:0] wait_q;
  reg [QD-1:0] crit_q;
  reg [QD-1:0] class_ready_q [0:3];
  reg [QD-1:0] class_critical_ready_q [0:3];
  reg [RAW-1:0] rob_q [0:QD-1];
  reg [1:0]     lat_q [0:QD-1];
  reg [RAW-1:0] tgt_q [0:QD-1];
  reg [QD-1:0]  older_q [0:QD-1];

  reg [QD-1:0] wake_now;
  reg [QD-1:0] known_probe_q;
  reg [RAW-1:0] probe_tgt_q [0:QD-1];
  integer e;
  always @* begin
    for (e = 0; e < QD; e = e + 1)
      wake_now[e] = valid_q[e] & wait_q[e]
                    & known_probe_q[e]
                    & (probe_tgt_q[e] == tgt_q[e]);
  end
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      known_probe_q <= {QD{1'b0}};
    end else begin
      for (e = 0; e < QD; e = e + 1) begin
        known_probe_q[e] <= res_known[tgt_q[e]];
        probe_tgt_q[e] <= tgt_q[e];
      end
    end
  end

  // One allocation batch is reserved while its metadata crosses the
  // ingress->IQ register boundary. A registered pick can be reused by the new
  // request, but slots reserved by the pending batch remain unavailable.
  reg [QD-1:0] alloc_sel_q [0:3];
  reg [2:0] pend_cnt_q;
  wire [3:0] pend_en = {pend_cnt_q > 3, pend_cnt_q > 2,
                        pend_cnt_q > 1, pend_cnt_q > 0};
  // Invalid lanes are zeroed when captured, so the free-list feedback no
  // longer depends on pend_cnt_q comparators in the following cycle.
  wire [QD-1:0] pend_hit = alloc_sel_q[0] | alloc_sel_q[1]
                            | alloc_sel_q[2] | alloc_sel_q[3];
  wire [QD-1:0] free0 = (~valid_q | picked_iq) & ~pend_hit;

  // E043 partitions the IQ free list into four eight-entry banks.  A batch
  // contains consecutive ROB sequence numbers, so it requests each bank at
  // most once.  Four independent 8-bit prefix encoders replace the 32-entry
  // four-winner Kogge-Stone network.
  wire [7:0] bank_free [0:3];
  wire [7:0] bank_pref1 [0:3];
  wire [7:0] bank_pref2 [0:3];
  wire [7:0] bank_pref4 [0:3];
  wire [7:0] bank_pick [0:3];
  wire [3:0] bank_free_count [0:3];
  reg  [7:0] bank_free_probe_q [0:3];
  reg  [2:0] bank_free_lo_q [0:3];
  reg  [2:0] bank_free_hi_q [0:3];
  genvar gb;
  generate
    for (gb = 0; gb < 4; gb = gb + 1) begin : g_free_bank
      assign bank_free[gb] = free0[gb*8 +: 8];
      assign bank_pref1[gb] = bank_free[gb] | (bank_free[gb] << 1);
      assign bank_pref2[gb] = bank_pref1[gb] | (bank_pref1[gb] << 2);
      assign bank_pref4[gb] = bank_pref2[gb] | (bank_pref2[gb] << 4);
      assign bank_pick[gb] = bank_free[gb] & ~(bank_pref4[gb] << 1);
      assign bank_free_count[gb] = {1'b0, bank_free_lo_q[gb]}
                                    + {1'b0, bank_free_hi_q[gb]};
    end
  endgenerate

  wire [QD-1:0] alloc_sel [0:3];
  wire [1:0] alloc_bank [0:3];
  genvar gs;
  generate
    for (gs = 0; gs < 4; gs = gs + 1) begin : g_bank_request
      assign alloc_bank[gs] = alloc_seq[1:0] + gs[1:0];
      assign alloc_sel[gs] =
          ({QD{alloc_bank[gs] == 2'd0}} & {24'b0, bank_pick[0]})
        | ({QD{alloc_bank[gs] == 2'd1}} & {16'b0, bank_pick[1], 8'b0})
        | ({QD{alloc_bank[gs] == 2'd2}} & {8'b0, bank_pick[2], 16'b0})
        | ({QD{alloc_bank[gs] == 2'd3}} & {bank_pick[3], 24'b0});
    end
  endgenerate

  reg [RAW-1:0] alloc_rob [0:3];
  reg [1:0]     alloc_lat [0:3];
  reg           alloc_isdep [0:3];
  reg           alloc_crit [0:3];
  reg           alloc_rdy [0:3];
  reg           alloc_wtg [0:3];
  integer a;
  reg [RAW:0] aseq;
  always @* begin
    for (a = 0; a < 4; a = a + 1) begin
      aseq          = alloc_seq + a[RAW:0];
      alloc_rob[a]  = aseq[RAW-1:0];
      alloc_lat[a]  = slot_lat[aseq[1:0]];
      alloc_isdep[a] = |k_dep[a];
      // Admit every dependent as waiting.  The registered res_known probe
      // promotes it after allocation without a live completion-to-pending
      // path through ingress readiness logic.
      alloc_rdy[a]  = ~(|k_dep[a]);
      alloc_wtg[a]  = |k_dep[a];
      alloc_crit[a] = 1'b0;
    end
  end

  // Pending request metadata. The ROB allocation still occurs at ingress;
  // only the compact IQ descriptor crosses this explicit register boundary.
  reg [RAW-1:0] pend_rob_q [0:3];
  reg [1:0]     pend_lat_q [0:3];
  reg [2:0]     pend_dep_q [0:3];
  reg           pend_isdep_q [0:3];
  reg           pend_crit_q [0:3];
  reg           pend_rdy_q [0:3];
  reg           pend_wtg_q [0:3];
  wire [RAW-1:0] pend_tgt_calc [0:3];
  genvar gt;
  generate
    for (gt = 0; gt < 4; gt = gt + 1) begin : g_pend_target
      assign pend_tgt_calc[gt] = pend_rob_q[gt]
                                  - {{(RAW-3){1'b0}}, pend_dep_q[gt]};
    end
  endgenerate

  // Generate the critical-target broadcast from registered ROB tag/distance
  // metadata.  This splits compaction from target arithmetic while q2 still
  // catches targets allocated on the same edge as q1.
  reg [3:0] kw_vld_q1, kw_vld_q2;
  reg [RAW-1:0] kw_tgt_q1 [0:3];
  reg [RAW-1:0] kw_tgt_q2 [0:3];
  integer kb;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      kw_vld_q1 <= 4'b0;
      kw_vld_q2 <= 4'b0;
    end else begin
      kw_vld_q2 <= kw_vld_q1;
      for (kb = 0; kb < 4; kb = kb + 1) begin
        kw_vld_q1[kb] <= pend_en[kb] & (|pend_dep_q[kb]);
        kw_tgt_q1[kb] <= pend_tgt_calc[kb];
        kw_tgt_q2[kb] <= kw_tgt_q1[kb];
      end
    end
  end

  // Decode the four mutually exclusive allocation ranks once.  Metadata and
  // valid/state writes then use one parallel one-hot mux instead of four
  // cascaded procedural priority conditions.
  wire [QD-1:0] alloc_hit;
  wire [3:0] alloc_lane [0:QD-1];
  wire [RAW-1:0] slot_new_rob [0:QD-1];
  wire [1:0] slot_new_lat [0:QD-1];
  wire [RAW-1:0] slot_new_tgt [0:QD-1];
  wire [QD-1:0] slot_new_rdy, slot_new_wtg, slot_new_crit;
  genvar ga;
  generate
    for (ga = 0; ga < QD; ga = ga + 1) begin : g_alloc_decode
      assign alloc_lane[ga] = {pend_en[3] & alloc_sel_q[3][ga],
                               pend_en[2] & alloc_sel_q[2][ga],
                               pend_en[1] & alloc_sel_q[1][ga],
                               pend_en[0] & alloc_sel_q[0][ga]};
      assign alloc_hit[ga] = |alloc_lane[ga];
      assign slot_new_rob[ga] = (pend_rob_q[0] & {RAW{alloc_lane[ga][0]}})
                              | (pend_rob_q[1] & {RAW{alloc_lane[ga][1]}})
                              | (pend_rob_q[2] & {RAW{alloc_lane[ga][2]}})
                              | (pend_rob_q[3] & {RAW{alloc_lane[ga][3]}});
      assign slot_new_lat[ga] = (pend_lat_q[0] & {2{alloc_lane[ga][0]}})
                              | (pend_lat_q[1] & {2{alloc_lane[ga][1]}})
                              | (pend_lat_q[2] & {2{alloc_lane[ga][2]}})
                              | (pend_lat_q[3] & {2{alloc_lane[ga][3]}});
      assign slot_new_tgt[ga] = (pend_tgt_calc[0] & {RAW{alloc_lane[ga][0]}})
                              | (pend_tgt_calc[1] & {RAW{alloc_lane[ga][1]}})
                              | (pend_tgt_calc[2] & {RAW{alloc_lane[ga][2]}})
                              | (pend_tgt_calc[3] & {RAW{alloc_lane[ga][3]}});
      assign slot_new_rdy[ga] = |(alloc_lane[ga]
                                  & {pend_rdy_q[3], pend_rdy_q[2],
                                     pend_rdy_q[1], pend_rdy_q[0]});
      assign slot_new_wtg[ga] = |(alloc_lane[ga]
                                  & {pend_wtg_q[3], pend_wtg_q[2],
                                     pend_wtg_q[1], pend_wtg_q[0]});
      assign slot_new_crit[ga] = |(alloc_lane[ga]
                                   & {pend_crit_q[3], pend_crit_q[2],
                                      pend_crit_q[1], pend_crit_q[0]});
    end
  endgenerate

  // Allocation order is total and never changes, so record it once rather
  // than recomputing six-bit circular ages in every picker level. Row i bit j
  // is one exactly when live IQ entry i was allocated before live entry j.
  wire [QD-1:0] survivor = valid_q & ~picked_iq;
  wire [QD-1:0] newer_alloc [0:3];
  assign newer_alloc[0] = (alloc_sel_q[1] & {QD{pend_en[1]}})
                        | (alloc_sel_q[2] & {QD{pend_en[2]}})
                        | (alloc_sel_q[3] & {QD{pend_en[3]}});
  assign newer_alloc[1] = (alloc_sel_q[2] & {QD{pend_en[2]}})
                        | (alloc_sel_q[3] & {QD{pend_en[3]}});
  assign newer_alloc[2] = alloc_sel_q[3] & {QD{pend_en[3]}};
  assign newer_alloc[3] = {QD{1'b0}};
  wire [QD-1:0] older_n [0:QD-1];
  generate
    for (ga = 0; ga < QD; ga = ga + 1) begin : g_older_next
      wire [QD-1:0] new_row = (newer_alloc[0]
                                  & {QD{alloc_lane[ga][0]}})
                               | (newer_alloc[1]
                                  & {QD{alloc_lane[ga][1]}})
                               | (newer_alloc[2]
                                  & {QD{alloc_lane[ga][2]}});
      assign older_n[ga] = alloc_hit[ga] ? new_row
                           : (survivor[ga] ? (older_q[ga] | alloc_hit)
                                           : older_q[ga]);
    end
  endgenerate

  // Picker exports the count beside its registered commit bitmap, avoiding a
  // 32-way popcount on the registered BKPR path.
  assign iq_count_n = iq_count + {{(QAW-2){1'b0}}, pend_cnt_q}
                               - {{(QAW-2){1'b0}}, picked_count};
  // Register bank pressure before it crosses into ROB backpressure.  Four
  // leaves three physical slots when asserted, covering the two registered
  // throttle stages plus the batch already resident in ingress.
  wire bank_pressure = (bank_free_count[0] < 4'd4)
                       || (bank_free_count[1] < 4'd4)
                       || (bank_free_count[2] < 4'd4)
                       || (bank_free_count[3] < 4'd4);

  reg [QD-1:0] crit_hit;
  reg [QD-1:0] crit_hit_q;
  integer ch, ck;
  always @* begin
    crit_hit = {QD{1'b0}};
    for (ch = 0; ch < QD; ch = ch + 1)
      for (ck = 0; ck < 4; ck = ck + 1) begin
        if (kw_vld_q1[ck] && (kw_tgt_q1[ck] == rob_q[ch]))
          crit_hit[ch] = 1'b1;
        if (kw_vld_q2[ck] && (kw_tgt_q2[ck] == rob_q[ch]))
          crit_hit[ch] = 1'b1;
      end
  end
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) crit_hit_q <= {QD{1'b0}};
    else        crit_hit_q <= crit_hit;
  end

  integer q;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= {QD{1'b0}};
      ready_q <= {QD{1'b0}};
      wait_q  <= {QD{1'b0}};
      crit_q  <= {QD{1'b0}};
      class_ready_q[0] <= {QD{1'b0}};
      class_ready_q[1] <= {QD{1'b0}};
      class_ready_q[2] <= {QD{1'b0}};
      class_ready_q[3] <= {QD{1'b0}};
      class_critical_ready_q[0] <= {QD{1'b0}};
      class_critical_ready_q[1] <= {QD{1'b0}};
      class_critical_ready_q[2] <= {QD{1'b0}};
      class_critical_ready_q[3] <= {QD{1'b0}};
      iq_count <= {(QAW+1){1'b0}};
      for (q = 0; q < 4; q = q + 1) begin
        bank_free_probe_q[q] <= 8'hff;
        bank_free_lo_q[q] <= 3'd4;
        bank_free_hi_q[q] <= 3'd4;
      end
      pend_cnt_q <= 3'd0;
      for (q = 0; q < 4; q = q + 1)
        alloc_sel_q[q] <= {QD{1'b0}};
      for (q = 0; q < QD; q = q + 1)
        older_q[q] <= {QD{1'b0}};
    end else begin
      iq_count <= iq_count_n;
      for (q = 0; q < 4; q = q + 1) begin
        bank_free_probe_q[q] <= bank_free[q];
        bank_free_lo_q[q] <= {2'b0, bank_free_probe_q[q][0]}
                              + {2'b0, bank_free_probe_q[q][1]}
                              + {2'b0, bank_free_probe_q[q][2]}
                              + {2'b0, bank_free_probe_q[q][3]};
        bank_free_hi_q[q] <= {2'b0, bank_free_probe_q[q][4]}
                              + {2'b0, bank_free_probe_q[q][5]}
                              + {2'b0, bank_free_probe_q[q][6]}
                              + {2'b0, bank_free_probe_q[q][7]};
      end
      pend_cnt_q <= acnt;
      for (q = 0; q < 4; q = q + 1) begin
        alloc_sel_q[q] <= (q[2:0] < acnt) ? alloc_sel[q] : {QD{1'b0}};
        pend_rob_q[q]  <= alloc_rob[q];
        pend_lat_q[q]  <= alloc_lat[q];
        pend_dep_q[q]  <= k_dep[q];
        pend_isdep_q[q] <= alloc_isdep[q];
        pend_crit_q[q] <= alloc_crit[q];
        pend_rdy_q[q] <= alloc_rdy[q];
        pend_wtg_q[q] <= alloc_wtg[q];
      end
      for (q = 0; q < QD; q = q + 1) begin
        older_q[q] <= older_n[q];
        if (picked_iq[q]) begin
          valid_q[q] <= 1'b0;
          ready_q[q] <= 1'b0;
          wait_q[q]  <= 1'b0;
          crit_q[q]  <= 1'b0;
          class_ready_q[0][q] <= 1'b0;
          class_ready_q[1][q] <= 1'b0;
          class_ready_q[2][q] <= 1'b0;
          class_ready_q[3][q] <= 1'b0;
          class_critical_ready_q[0][q] <= 1'b0;
          class_critical_ready_q[1][q] <= 1'b0;
          class_critical_ready_q[2][q] <= 1'b0;
          class_critical_ready_q[3][q] <= 1'b0;
        end else begin
          if (wake_now[q]) begin
            ready_q[q] <= 1'b1;
            wait_q[q]  <= 1'b0;
            case (lat_q[q])
              2'd0: class_ready_q[0][q] <= 1'b1;
              2'd1: class_ready_q[1][q] <= 1'b1;
              2'd2: class_ready_q[2][q] <= 1'b1;
              2'd3: class_ready_q[3][q] <= 1'b1;
            endcase
            if (crit_q[q] || crit_hit_q[q]) begin
              case (lat_q[q])
                2'd0: class_critical_ready_q[0][q] <= 1'b1;
                2'd1: class_critical_ready_q[1][q] <= 1'b1;
                2'd2: class_critical_ready_q[2][q] <= 1'b1;
                2'd3: class_critical_ready_q[3][q] <= 1'b1;
              endcase
            end
          end
          if (valid_q[q] && crit_hit_q[q]) begin
            crit_q[q] <= 1'b1;
            if (ready_q[q]) begin
              case (lat_q[q])
                2'd0: class_critical_ready_q[0][q] <= 1'b1;
                2'd1: class_critical_ready_q[1][q] <= 1'b1;
                2'd2: class_critical_ready_q[2][q] <= 1'b1;
                2'd3: class_critical_ready_q[3][q] <= 1'b1;
              endcase
            end
          end
        end

        // Allocation has final precedence, including same-edge pick reuse.
        if (alloc_hit[q]) begin
          valid_q[q] <= 1'b1;
          ready_q[q] <= slot_new_rdy[q];
          wait_q[q]  <= slot_new_wtg[q];
          crit_q[q]  <= slot_new_crit[q];
          class_ready_q[0][q] <= 1'b0;
          class_ready_q[1][q] <= 1'b0;
          class_ready_q[2][q] <= 1'b0;
          class_ready_q[3][q] <= 1'b0;
          class_critical_ready_q[0][q] <= 1'b0;
          class_critical_ready_q[1][q] <= 1'b0;
          class_critical_ready_q[2][q] <= 1'b0;
          class_critical_ready_q[3][q] <= 1'b0;
          case (slot_new_lat[q])
            2'd0: begin
              class_ready_q[0][q] <= slot_new_rdy[q];
              class_critical_ready_q[0][q] <= slot_new_rdy[q]
                                                       & slot_new_crit[q];
            end
            2'd1: begin
              class_ready_q[1][q] <= slot_new_rdy[q];
              class_critical_ready_q[1][q] <= slot_new_rdy[q]
                                                       & slot_new_crit[q];
            end
            2'd2: begin
              class_ready_q[2][q] <= slot_new_rdy[q];
              class_critical_ready_q[2][q] <= slot_new_rdy[q]
                                                       & slot_new_crit[q];
            end
            2'd3: begin
              class_ready_q[3][q] <= slot_new_rdy[q];
              class_critical_ready_q[3][q] <= slot_new_rdy[q]
                                                       & slot_new_crit[q];
            end
          endcase
          rob_q[q]   <= slot_new_rob[q];
          lat_q[q]   <= slot_new_lat[q];
          tgt_q[q]   <= slot_new_tgt[q];
        end
      end
    end
  end

  generate
    for (gi = 0; gi < QD; gi = gi + 1) begin : g_export
      assign iq_rob_f[gi*RAW +: RAW] = rob_q[gi];
      assign iq_lat_f[gi*2 +: 2]     = lat_q[gi];
      assign iq_tgt_f[gi*RAW +: RAW] = tgt_q[gi];
      assign iq_older_f[gi*QD +: QD] = older_q[gi];
    end
  endgenerate
  assign iq_v_o    = valid_q;
  assign iq_rdy_o  = ready_q;
  assign iq_crit_o = crit_q;
  assign iq_wake_o = wake_now;
  assign iq_class_ready_f[0*QD +: QD] = class_ready_q[0];
  assign iq_class_ready_f[1*QD +: QD] = class_ready_q[1];
  assign iq_class_ready_f[2*QD +: QD] = class_ready_q[2];
  assign iq_class_ready_f[3*QD +: QD] = class_ready_q[3];
  assign iq_class_critical_ready_f[0*QD +: QD] = class_critical_ready_q[0];
  assign iq_class_critical_ready_f[1*QD +: QD] = class_critical_ready_q[1];
  assign iq_class_critical_ready_f[2*QD +: QD] = class_critical_ready_q[2];
  assign iq_class_critical_ready_f[3*QD +: QD] = class_critical_ready_q[3];
  assign iq_over_n = bank_pressure;
  wire _unused_ready_ok = &{1'b0, slot_rdy[0], slot_wtg[0], res_pred[0]};

`ifndef SYNTHESIS
  integer af;
  always @(posedge clk) begin
    if (rst_n) begin
      for (af = 0; af < 4; af = af + 1)
        if ((af < acnt) && !(|alloc_sel[af]))
          $display("[ff_iq] ERROR: IQ overflow allocating lane %0d @%0t", af, $time);
    end
  end
`endif

endmodule
