// =============================================================================
// ff_iq - decoupled 32-entry issue queue for a 64-entry storage ROB
//
// Experiment : E062
// Base       : 4FE-safe-v28 / E029-R32
//
// Only scheduling descriptors live here. Packet/result data and retirement
// state remain in ff_rob. IQ slots are allocated from the free list, so their
// physical positions are independent of ROB tags. A 32x32 allocation-order
// matrix records the relative age once, keeping tag arithmetic out of pick.
// Wake-up compares the four registered scheduler/result tags directly against
// each six-bit target instead of decoding them into a 64-bit bitmap first.
// Unused allocation ranks are masked when the reservation is registered, so
// the free-list and age-matrix paths no longer depend on pend_cnt_q decoding.
// =============================================================================
module ff_iq #(
  parameter QD  = 32,
  parameter QAW = 5,
  parameter RAW = 6,
  parameter NFE = 4
)(
  input  wire                    clk,
  input  wire                    rst_n,
  input  wire [2:0]              acnt,
  input  wire [RAW:0]            alloc_seq,
  input  wire [7:0]              slot_lat_f,
  input  wire [4*RAW-1:0]        slot_tgt_f,
  input  wire [3:0]              slot_isdep,
  input  wire [3:0]              kw_vld,
  input  wire [4*RAW-1:0]        k_tgt_f,
  input  wire [(1<<RAW)-1:0]     res_known, // retained/stored result bitmap
  input  wire [NFE-1:0]          pre_v,
  input  wire [NFE*RAW-1:0]      pre_idx_f,
  input  wire [NFE-1:0]          exit_v,
  input  wire [NFE*RAW-1:0]      exit_idx_f,
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
  output reg  [QAW:0]            iq_count,
  output wire [QAW:0]            iq_count_n,
  output wire                     iq_over_n
);

  wire [1:0]    slot_lat [0:3];
  wire [RAW-1:0] slot_tgt [0:3];
  wire [RAW-1:0] k_tgt [0:3];
  wire [RAW-1:0] pre_idx [0:NFE-1];
  wire [RAW-1:0] exit_idx [0:NFE-1];
  genvar gi;
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_unpack
      assign slot_lat[gi] = slot_lat_f[gi*2 +: 2];
      assign slot_tgt[gi] = slot_tgt_f[gi*RAW +: RAW];
      assign k_tgt[gi]    = k_tgt_f[gi*RAW +: RAW];
    end
    for (gi = 0; gi < NFE; gi = gi + 1) begin : g_unpack_result_tags
      assign pre_idx[gi]  = pre_idx_f[gi*RAW +: RAW];
      assign exit_idx[gi] = exit_idx_f[gi*RAW +: RAW];
    end
  endgenerate

  reg [QD-1:0] valid_q;
  reg [QD-1:0] ready_q;
  reg [QD-1:0] wait_q;
  reg [QD-1:0] crit_q;
  reg [RAW-1:0] rob_q [0:QD-1];
  reg [1:0]     lat_q [0:QD-1];
  reg [RAW-1:0] tgt_q [0:QD-1];
  reg [QD-1:0]  older_q [0:QD-1];

  reg [QD-1:0] wake_now;
  reg [QD-1:0] wake_match;
  integer e, wf;
  always @* begin
    for (e = 0; e < QD; e = e + 1) begin
      wake_match[e] = 1'b0;
      for (wf = 0; wf < NFE; wf = wf + 1)
        if ((pre_v[wf] && (pre_idx[wf] == tgt_q[e]))
            || (exit_v[wf] && (exit_idx[wf] == tgt_q[e])))
          wake_match[e] = 1'b1;
      wake_now[e] = valid_q[e] & wait_q[e] & wake_match[e];
    end
  end

  // One allocation batch is reserved while its metadata crosses the
  // ingress->IQ register boundary. A registered pick can be reused by the new
  // request, but slots reserved by the pending batch remain unavailable.
  reg [QD-1:0] alloc_sel_q [0:3];
  reg [2:0] pend_cnt_q;
  wire [QD-1:0] pend_hit = alloc_sel_q[0] | alloc_sel_q[1]
                         | alloc_sel_q[2] | alloc_sel_q[3];
  wire [QD-1:0] free0 = (~valid_q | picked_iq) & ~pend_hit;

  // Unary saturated-count merge. Bit k means "this prefix contains at least
  // k+1 free slots". The operator is associative, so five Kogge-Stone style
  // stages compute every prefix without binary add/compare chains.
  function [3:0] unary_add;
    input [3:0] x;
    input [3:0] y;
    begin
      unary_add[0] = x[0] | y[0];
      unary_add[1] = x[1] | (x[0] & y[0]) | y[1];
      unary_add[2] = x[2] | (x[1] & y[0]) | (x[0] & y[1]) | y[2];
      unary_add[3] = x[3] | (x[2] & y[0]) | (x[1] & y[1])
                          | (x[0] & y[2]) | y[3];
    end
  endfunction

  wire [3:0] ps0 [0:QD-1];
  wire [3:0] ps1 [0:QD-1];
  wire [3:0] ps2 [0:QD-1];
  wire [3:0] ps3 [0:QD-1];
  wire [3:0] ps4 [0:QD-1];
  wire [3:0] ps5 [0:QD-1];
  generate
    for (gi = 0; gi < QD; gi = gi + 1) begin : g_free_prefix
      assign ps0[gi] = {3'b000, free0[gi]};
      if (gi >= 1) assign ps1[gi] = unary_add(ps0[gi], ps0[gi-1]);
      else         assign ps1[gi] = ps0[gi];
      if (gi >= 2) assign ps2[gi] = unary_add(ps1[gi], ps1[gi-2]);
      else         assign ps2[gi] = ps1[gi];
      if (gi >= 4) assign ps3[gi] = unary_add(ps2[gi], ps2[gi-4]);
      else         assign ps3[gi] = ps2[gi];
      if (gi >= 8) assign ps4[gi] = unary_add(ps3[gi], ps3[gi-8]);
      else         assign ps4[gi] = ps3[gi];
      if (gi >= 16) assign ps5[gi] = unary_add(ps4[gi], ps4[gi-16]);
      else          assign ps5[gi] = ps4[gi];
    end
  endgenerate

  wire [QD-1:0] alloc_sel [0:3];
  genvar gs;
  generate
    for (gs = 0; gs < QD; gs = gs + 1) begin : g_free_rank
      wire [3:0] prefix_before;
      if (gs == 0) assign prefix_before = 4'b0000;
      else         assign prefix_before = ps5[gs-1];
      assign alloc_sel[0][gs] = free0[gs] && !prefix_before[0];
      assign alloc_sel[1][gs] = free0[gs]
                                  && prefix_before[0] && !prefix_before[1];
      assign alloc_sel[2][gs] = free0[gs]
                                  && prefix_before[1] && !prefix_before[2];
      assign alloc_sel[3][gs] = free0[gs]
                                  && prefix_before[2] && !prefix_before[3];
    end
  endgenerate

  reg [RAW-1:0] alloc_rob [0:3];
  reg [1:0]     alloc_lat [0:3];
  reg [RAW-1:0] alloc_tgt [0:3];
  reg           alloc_isdep [0:3];
  reg           alloc_crit [0:3];
  integer a, k;
  reg [RAW:0] aseq;
  always @* begin
    for (a = 0; a < 4; a = a + 1) begin
      aseq          = alloc_seq + a[RAW:0];
      alloc_rob[a]  = aseq[RAW-1:0];
      alloc_lat[a]  = slot_lat[aseq[1:0]];
      alloc_tgt[a]  = slot_tgt[aseq[1:0]];
      alloc_isdep[a] = slot_isdep[aseq[1:0]];
      alloc_crit[a] = 1'b0;
      for (k = 0; k < 4; k = k + 1)
        if (kw_vld[k] && (k_tgt[k] == aseq[RAW-1:0]))
          alloc_crit[a] = 1'b1;
    end
  end

  // Pending request metadata. The ROB allocation still occurs at ingress;
  // only the compact IQ descriptor crosses this explicit register boundary.
  reg [RAW-1:0] pend_rob_q [0:3];
  reg [1:0]     pend_lat_q [0:3];
  reg [RAW-1:0] pend_tgt_q [0:3];
  reg           pend_isdep_q [0:3];
  reg           pend_crit_q [0:3];

  // A pending descriptor can become ready either from a result already
  // retained in the ROB or from one of the four registered scheduler/result
  // tags.  Keep the tag comparison in six-bit form; building a 64-bit event
  // bitmap and indexing it by pend_tgt recreates the path E050 removes.
  wire [3:0] pend_event;
  wire [3:0] pend_ready;
  genvar gp;
  generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_pending_result
      assign pend_event[gp] = (pre_v[0] && (pre_idx[0] == pend_tgt_q[gp]))
                            | (pre_v[1] && (pre_idx[1] == pend_tgt_q[gp]))
                            | (pre_v[2] && (pre_idx[2] == pend_tgt_q[gp]))
                            | (pre_v[3] && (pre_idx[3] == pend_tgt_q[gp]))
                            | (exit_v[0] && (exit_idx[0] == pend_tgt_q[gp]))
                            | (exit_v[1] && (exit_idx[1] == pend_tgt_q[gp]))
                            | (exit_v[2] && (exit_idx[2] == pend_tgt_q[gp]))
                            | (exit_v[3] && (exit_idx[3] == pend_tgt_q[gp]));
      assign pend_ready[gp] = res_known[pend_tgt_q[gp]] | pend_event[gp];
    end
  endgenerate

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
      assign alloc_lane[ga] = {alloc_sel_q[3][ga],
                               alloc_sel_q[2][ga],
                               alloc_sel_q[1][ga],
                               alloc_sel_q[0][ga]};
      assign alloc_hit[ga] = |alloc_lane[ga];
      assign slot_new_rob[ga] = (pend_rob_q[0] & {RAW{alloc_lane[ga][0]}})
                              | (pend_rob_q[1] & {RAW{alloc_lane[ga][1]}})
                              | (pend_rob_q[2] & {RAW{alloc_lane[ga][2]}})
                              | (pend_rob_q[3] & {RAW{alloc_lane[ga][3]}});
      assign slot_new_lat[ga] = (pend_lat_q[0] & {2{alloc_lane[ga][0]}})
                              | (pend_lat_q[1] & {2{alloc_lane[ga][1]}})
                              | (pend_lat_q[2] & {2{alloc_lane[ga][2]}})
                              | (pend_lat_q[3] & {2{alloc_lane[ga][3]}});
      assign slot_new_tgt[ga] = (pend_tgt_q[0] & {RAW{alloc_lane[ga][0]}})
                              | (pend_tgt_q[1] & {RAW{alloc_lane[ga][1]}})
                              | (pend_tgt_q[2] & {RAW{alloc_lane[ga][2]}})
                              | (pend_tgt_q[3] & {RAW{alloc_lane[ga][3]}});
      assign slot_new_rdy[ga] = |(alloc_lane[ga]
                                  & {~pend_isdep_q[3]
                                       | pend_ready[3],
                                     ~pend_isdep_q[2]
                                       | pend_ready[2],
                                     ~pend_isdep_q[1]
                                       | pend_ready[1],
                                     ~pend_isdep_q[0]
                                       | pend_ready[0]});
      assign slot_new_wtg[ga] = |(alloc_lane[ga]
                                  & {pend_isdep_q[3]
                                       & ~pend_ready[3],
                                     pend_isdep_q[2]
                                       & ~pend_ready[2],
                                     pend_isdep_q[1]
                                       & ~pend_ready[1],
                                     pend_isdep_q[0]
                                       & ~pend_ready[0]});
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
  assign newer_alloc[0] = alloc_sel_q[1] | alloc_sel_q[2]
                        | alloc_sel_q[3];
  assign newer_alloc[1] = alloc_sel_q[2] | alloc_sel_q[3];
  assign newer_alloc[2] = alloc_sel_q[3];
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
  wire [QAW:0] iq_reserved_n = iq_count_n
                               + {{(QAW-2){1'b0}}, acnt};
  assign iq_over_n = (iq_reserved_n > 6'd23);

  reg [QD-1:0] crit_hit;
  integer ch, ck;
  always @* begin
    crit_hit = {QD{1'b0}};
    for (ch = 0; ch < QD; ch = ch + 1)
      for (ck = 0; ck < 4; ck = ck + 1)
        if (kw_vld[ck] && (k_tgt[ck] == rob_q[ch])) crit_hit[ch] = 1'b1;
  end

  integer q;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= {QD{1'b0}};
      ready_q <= {QD{1'b0}};
      wait_q  <= {QD{1'b0}};
      crit_q  <= {QD{1'b0}};
      iq_count <= {(QAW+1){1'b0}};
      pend_cnt_q <= 3'd0;
      for (q = 0; q < 4; q = q + 1)
        alloc_sel_q[q] <= {QD{1'b0}};
      for (q = 0; q < QD; q = q + 1)
        older_q[q] <= {QD{1'b0}};
    end else begin
      iq_count <= iq_count_n;
      pend_cnt_q <= acnt;
      for (q = 0; q < 4; q = q + 1) begin
        // Keep only ranks that belong to this batch. This moves the variable
        // count decode before the register boundary instead of placing it on
        // every reservation, metadata, and age-matrix consumer.
        alloc_sel_q[q] <= (q[2:0] < acnt) ? alloc_sel[q] : {QD{1'b0}};
        pend_rob_q[q]  <= alloc_rob[q];
        pend_lat_q[q]  <= alloc_lat[q];
        pend_tgt_q[q]  <= alloc_tgt[q];
        pend_isdep_q[q] <= alloc_isdep[q];
        pend_crit_q[q] <= alloc_crit[q];
      end
      for (q = 0; q < QD; q = q + 1) begin
        older_q[q] <= older_n[q];
        if (picked_iq[q]) begin
          valid_q[q] <= 1'b0;
          ready_q[q] <= 1'b0;
          wait_q[q]  <= 1'b0;
          crit_q[q]  <= 1'b0;
        end else begin
          if (wake_now[q]) begin
            ready_q[q] <= 1'b1;
            wait_q[q]  <= 1'b0;
          end
          if (valid_q[q] && crit_hit[q]) crit_q[q] <= 1'b1;
        end

        // Allocation has final precedence, including same-edge pick reuse.
        if (alloc_hit[q]) begin
          valid_q[q] <= 1'b1;
          ready_q[q] <= slot_new_rdy[q];
          wait_q[q]  <= slot_new_wtg[q];
          crit_q[q]  <= slot_new_crit[q];
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
