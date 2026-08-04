// =============================================================================
// ff_pick - I0 issue selection (4-FE work-stealing variant)
//
// RTL revision : 4FE-safe-v27
// Experiment   : E028-V1
// Based on     : 4FE-safe-v20 / E021-N1
// Changes      : compute fast bank/post/pre valid signals beside local payloads
//
// Per latency class: the two oldest ready candidates are found with
// hierarchical bank/local priority selection; a packet some dependent is
// waiting on (critical) jumps the queue (unless the age-oldest candidate is
// the very window head). If a class has a backlog (2nd candidate) while
// another FE is idle, the idle FE may steal it. DUAL_STEAL=0 disables both
// matchers for the timing-safe profile; DUAL_STEAL=1 enables both matchers in
// the throughput/full profiles.
// gated by exact output-slot conflict checks against the ff_sched booking.
// rob_src records the FE each entry was issued to (result routing).
// =============================================================================
module ff_pick #(
  parameter D           = 64,
  parameter AW          = 6,
  parameter NFE         = 4,
  parameter WAKE_BYPASS = 0,
  parameter DUAL_STEAL  = 0,
  parameter REG_FEIN    = 0    // steal bookkeeping assumes issue = pick+1:
                               // with REG_FEIN (pick+2) stealing is disabled
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [D-1:0]        rdy_q,
  input  wire [D-1:0]        wake_now,
  input  wire [D-1:0]        crit_q,
  input  wire [D*2-1:0]      rob_lat_f,
  input  wire [D*AW-1:0]     rob_tgt_f,
  input  wire [AW-1:0]       rbase,        // oldest un-issued index
  input  wire [NFE*4-1:0]    sched_v_f,    // output-slot booking (ff_sched)
  output wire [D-1:0]        picked,
  output reg  [NFE-1:0]      pk_v_q,       // registered (I0 -> I1)
  output wire [NFE*AW-1:0]   pk_idx_f,
  output wire [NFE*AW-1:0]   pk_tgt_f,     // target index, I0-retimed for I1
  output wire [NFE*2-1:0]    pk_lat_f,
  output wire [NFE*8-1:0]    pk_bank_oh_f,
  output wire [NFE*8-1:0]    pk_local_oh_f,
  output wire [D*2-1:0]      rob_src_f     // FE each entry was issued to
);

  function [3:0] pe8;
    input [7:0] v;
    integer i;
    begin
      pe8 = 4'b0;
      for (i = 7; i >= 0; i = i - 1)
        if (v[i]) pe8 = {1'b1, i[2:0]};
    end
  endfunction

  // Local priority result with its one-hot form preserved.  Packing is
  // {onehot[7:0], valid, index[2:0]} so the safe picker does not have to
  // decode a full 6-bit physical index again when building picked_n.
  function [11:0] pe8h;
    input [7:0] v;
    integer i;
    begin
      pe8h = 12'b0;
      for (i = 7; i >= 0; i = i - 1)
        if (v[i]) pe8h = {(8'b1 << i), 1'b1, i[2:0]};
    end
  endfunction

  // Fast presence sideband for the safe selector.  The local PE still builds
  // index/one-hot payloads in parallel, but bank arbitration no longer waits
  // for the valid bit embedded in that wider priority result.  The explicit
  // tree fixes this control reduction at three two-input OR levels.
  function or8_bal;
    input [7:0] v;
    reg p0, p1, p2, p3;
    reg q0, q1;
    begin
      p0 = v[0] | v[1];
      p1 = v[2] | v[3];
      p2 = v[4] | v[5];
      p3 = v[6] | v[7];
      q0 = p0 | p1;
      q1 = p2 | p3;
      or8_bal = q0 | q1;
    end
  endfunction

  function [7:0] rotr8;
    input [7:0] v;
    input [2:0] s;
    reg [15:0] t;
    begin
      t = {v, v} >> s;
      rotr8 = t[7:0];
    end
  endfunction

  // Select the first non-base bank in circular age order.  Packing is
  // {valid, physical_bank[2:0], physical_bank_onehot[7:0]}.  The explicit
  // fixed orders avoid the safe selector's former variable rotate -> PE ->
  // index add -> dynamic bank-read chain.  Each case arm returns the physical
  // bank directly, so the one-hot also feeds the local result mux in parallel.
  function [11:0] pebank_after;
    input [7:0] v;
    input [2:0] base_bank;
    begin
      pebank_after = 12'b0;
      case (base_bank)
        3'd0: begin
          if      (v[1]) pebank_after = {1'b1, 3'd1, 8'h02};
          else if (v[2]) pebank_after = {1'b1, 3'd2, 8'h04};
          else if (v[3]) pebank_after = {1'b1, 3'd3, 8'h08};
          else if (v[4]) pebank_after = {1'b1, 3'd4, 8'h10};
          else if (v[5]) pebank_after = {1'b1, 3'd5, 8'h20};
          else if (v[6]) pebank_after = {1'b1, 3'd6, 8'h40};
          else if (v[7]) pebank_after = {1'b1, 3'd7, 8'h80};
        end
        3'd1: begin
          if      (v[2]) pebank_after = {1'b1, 3'd2, 8'h04};
          else if (v[3]) pebank_after = {1'b1, 3'd3, 8'h08};
          else if (v[4]) pebank_after = {1'b1, 3'd4, 8'h10};
          else if (v[5]) pebank_after = {1'b1, 3'd5, 8'h20};
          else if (v[6]) pebank_after = {1'b1, 3'd6, 8'h40};
          else if (v[7]) pebank_after = {1'b1, 3'd7, 8'h80};
          else if (v[0]) pebank_after = {1'b1, 3'd0, 8'h01};
        end
        3'd2: begin
          if      (v[3]) pebank_after = {1'b1, 3'd3, 8'h08};
          else if (v[4]) pebank_after = {1'b1, 3'd4, 8'h10};
          else if (v[5]) pebank_after = {1'b1, 3'd5, 8'h20};
          else if (v[6]) pebank_after = {1'b1, 3'd6, 8'h40};
          else if (v[7]) pebank_after = {1'b1, 3'd7, 8'h80};
          else if (v[0]) pebank_after = {1'b1, 3'd0, 8'h01};
          else if (v[1]) pebank_after = {1'b1, 3'd1, 8'h02};
        end
        3'd3: begin
          if      (v[4]) pebank_after = {1'b1, 3'd4, 8'h10};
          else if (v[5]) pebank_after = {1'b1, 3'd5, 8'h20};
          else if (v[6]) pebank_after = {1'b1, 3'd6, 8'h40};
          else if (v[7]) pebank_after = {1'b1, 3'd7, 8'h80};
          else if (v[0]) pebank_after = {1'b1, 3'd0, 8'h01};
          else if (v[1]) pebank_after = {1'b1, 3'd1, 8'h02};
          else if (v[2]) pebank_after = {1'b1, 3'd2, 8'h04};
        end
        3'd4: begin
          if      (v[5]) pebank_after = {1'b1, 3'd5, 8'h20};
          else if (v[6]) pebank_after = {1'b1, 3'd6, 8'h40};
          else if (v[7]) pebank_after = {1'b1, 3'd7, 8'h80};
          else if (v[0]) pebank_after = {1'b1, 3'd0, 8'h01};
          else if (v[1]) pebank_after = {1'b1, 3'd1, 8'h02};
          else if (v[2]) pebank_after = {1'b1, 3'd2, 8'h04};
          else if (v[3]) pebank_after = {1'b1, 3'd3, 8'h08};
        end
        3'd5: begin
          if      (v[6]) pebank_after = {1'b1, 3'd6, 8'h40};
          else if (v[7]) pebank_after = {1'b1, 3'd7, 8'h80};
          else if (v[0]) pebank_after = {1'b1, 3'd0, 8'h01};
          else if (v[1]) pebank_after = {1'b1, 3'd1, 8'h02};
          else if (v[2]) pebank_after = {1'b1, 3'd2, 8'h04};
          else if (v[3]) pebank_after = {1'b1, 3'd3, 8'h08};
          else if (v[4]) pebank_after = {1'b1, 3'd4, 8'h10};
        end
        3'd6: begin
          if      (v[7]) pebank_after = {1'b1, 3'd7, 8'h80};
          else if (v[0]) pebank_after = {1'b1, 3'd0, 8'h01};
          else if (v[1]) pebank_after = {1'b1, 3'd1, 8'h02};
          else if (v[2]) pebank_after = {1'b1, 3'd2, 8'h04};
          else if (v[3]) pebank_after = {1'b1, 3'd3, 8'h08};
          else if (v[4]) pebank_after = {1'b1, 3'd4, 8'h10};
          else if (v[5]) pebank_after = {1'b1, 3'd5, 8'h20};
        end
        default: begin
          if      (v[0]) pebank_after = {1'b1, 3'd0, 8'h01};
          else if (v[1]) pebank_after = {1'b1, 3'd1, 8'h02};
          else if (v[2]) pebank_after = {1'b1, 3'd2, 8'h04};
          else if (v[3]) pebank_after = {1'b1, 3'd3, 8'h08};
          else if (v[4]) pebank_after = {1'b1, 3'd4, 8'h10};
          else if (v[5]) pebank_after = {1'b1, 3'd5, 8'h20};
          else if (v[6]) pebank_after = {1'b1, 3'd6, 8'h40};
        end
      endcase
    end
  endfunction

  // Oldest set entry relative to base.  Each physical 8-entry bank has one
  // local PE; an 8-bit bank-valid vector then selects the first bank after the
  // base bank.  The base bank is split into post-base and pre-base pieces so
  // wraparound ordering remains exact.  Return value is {valid, physical idx}.
  function [AW:0] peH;
    input [D-1:0]  v;
    input [AW-1:0] base;
    integer b;
    reg [31:0] bank_pe_f;
    reg [7:0]  bank_v;
    reg [7:0]  base_bits, post_mask;
    reg [7:0]  bank_rot;
    reg [3:0]  post_pe, pre_pe, bank_pe, local_pe;
    reg [2:0]  base_bank, next_bank, other_bank;
    begin
      bank_pe_f = 32'b0;
      bank_v    = 8'b0;
      for (b = 0; b < 8; b = b + 1) begin
        bank_pe_f[b*4 +: 4] = pe8(v[b*8 +: 8]);
        bank_v[b] = bank_pe_f[b*4+3];
      end

      base_bank = base[5:3];
      base_bits = v[base_bank*8 +: 8];
      post_mask = 8'hff << base[2:0];
      post_pe   = pe8(base_bits & post_mask);
      pre_pe    = pe8(base_bits & ~post_mask);

      // Search complete banks beginning with base_bank+1.  The base bank is
      // cleared because its pre-base portion is the final wraparound group.
      bank_v[base_bank] = 1'b0;
      next_bank  = base_bank + 3'd1;
      bank_rot   = rotr8(bank_v, next_bank);
      bank_pe    = pe8(bank_rot);
      other_bank = bank_pe[2:0] + next_bank;
      local_pe   = bank_pe_f[other_bank*4 +: 4];

      if (post_pe[3])
        peH = {1'b1, base_bank, post_pe[2:0]};
      else if (bank_pe[3])
        peH = {1'b1, other_bank, local_pe[2:0]};
      else if (pre_pe[3])
        peH = {1'b1, base_bank, pre_pe[2:0]};
      else
        peH = {(AW+1){1'b0}};
    end
  endfunction

  // Safe-profile hierarchical selector returning the physical one-hot, the
  // selected entry's target payload, binary index, and the already-known
  // bank/local one-hots used by the next-cycle packet-data read:
  // {head_present, bank_oh[7:0], local_oh[7:0], physical_onehot[D-1:0],
  //  target[AW-1:0], valid, index[AW-1:0]}.
  function [D+2*AW+17:0] peHoh;
    input [D-1:0]  v;
    input [AW-1:0] base;
    input [D*AW-1:0] tgt_f;
    integer b, l;
    reg [95:0] bank_h_f;
    reg [8*AW-1:0] bank_tgt_f;
    reg [7:0]  bank_v;
    reg [7:0]  base_bits, post_mask;
    reg [11:0] post_h, pre_h, bank_sel_h, local_h;
    reg [2:0]  base_bank, other_bank;
    reg [7:0]  other_bank_oh;
    reg [AW-1:0] post_tgt, pre_tgt, other_tgt, result_tgt;
    reg [D-1:0]  result_oh;
    reg [7:0]    result_bank_oh, result_local_oh;
    reg [AW-1:0] result_idx;
    reg          post_v, pre_v;
    reg          result_v, head_present;
    begin
      bank_h_f = 96'b0;
      bank_tgt_f = {(8*AW){1'b0}};
      bank_v   = 8'b0;
      for (b = 0; b < 8; b = b + 1) begin
        bank_h_f[b*12 +: 12] = pe8h(v[b*8 +: 8]);
        bank_v[b] = or8_bal(v[b*8 +: 8]);
        for (l = 0; l < 8; l = l + 1)
          bank_tgt_f[b*AW +: AW] = bank_tgt_f[b*AW +: AW]
            | (tgt_f[(b*8+l)*AW +: AW]
               & {AW{bank_h_f[b*12+4+l]}});
      end

      base_bank = base[5:3];
      base_bits = v[base_bank*8 +: 8];
      post_mask = 8'hff << base[2:0];
      post_h    = pe8h(base_bits & post_mask);
      pre_h     = pe8h(base_bits & ~post_mask);
      post_v    = or8_bal(base_bits & post_mask);
      pre_v     = or8_bal(base_bits & ~post_mask);
      // The post-base local PE selects rbase itself exactly when the window
      // head is a candidate.  Export that already-computed fact so the safe
      // critical override does not wait for the full 64-entry page index and
      // does not infer the separate cand[rbase] 64-to-1 mux tried in E015.
      head_present = post_h[4 + base[2:0]];
      post_tgt  = {AW{1'b0}};
      pre_tgt   = {AW{1'b0}};
      for (l = 0; l < 8; l = l + 1) begin
        post_tgt = post_tgt
          | (tgt_f[(base_bank*8+l)*AW +: AW] & {AW{post_h[4+l]}});
        pre_tgt = pre_tgt
          | (tgt_f[(base_bank*8+l)*AW +: AW] & {AW{pre_h[4+l]}});
      end

      bank_sel_h  = pebank_after(bank_v, base_bank);
      other_bank  = bank_sel_h[10:8];
      other_bank_oh = bank_sel_h[7:0];
      local_h     = 12'b0;
      other_tgt   = {AW{1'b0}};
      for (b = 0; b < 8; b = b + 1) begin
        local_h = local_h
          | (bank_h_f[b*12 +: 12] & {12{other_bank_oh[b]}});
        other_tgt = other_tgt
          | (bank_tgt_f[b*AW +: AW] & {AW{other_bank_oh[b]}});
      end

      result_oh  = {D{1'b0}};
      result_bank_oh = 8'b0;
      result_local_oh = 8'b0;
      result_tgt = {AW{1'b0}};
      result_idx = {AW{1'b0}};
      result_v   = 1'b0;
      if (post_v) begin
        result_v   = 1'b1;
        result_idx = {base_bank, post_h[2:0]};
        result_tgt = post_tgt;
        result_bank_oh[base_bank] = 1'b1;
        result_local_oh = post_h[11:4];
        for (b = 0; b < 8; b = b + 1)
          if (base_bank == b[2:0])
            result_oh[b*8 +: 8] = post_h[11:4];
      end else if (bank_sel_h[11]) begin
        result_v   = 1'b1;
        result_idx = {other_bank, local_h[2:0]};
        result_tgt = other_tgt;
        result_bank_oh = other_bank_oh;
        result_local_oh = local_h[11:4];
        for (b = 0; b < 8; b = b + 1)
          result_oh[b*8 +: 8] = bank_h_f[b*12+4 +: 8]
                                 & {8{other_bank_oh[b]}};
      end else if (pre_v) begin
        result_v   = 1'b1;
        result_idx = {base_bank, pre_h[2:0]};
        result_tgt = pre_tgt;
        result_bank_oh[base_bank] = 1'b1;
        result_local_oh = pre_h[11:4];
        for (b = 0; b < 8; b = b + 1)
          if (base_bank == b[2:0])
            result_oh[b*8 +: 8] = pre_h[11:4];
      end
      peHoh = {head_present, result_bank_oh, result_local_oh,
               result_oh, result_tgt, result_v, result_idx};
    end
  endfunction

  // steal-conflict on receiver for donor class cc: output slot must be free
  // in the booked pipeline and not being booked by the packet currently
  // issuing on that FE  (svr[k-1] carries sched_v[k]; need sched_v[cc+3])
  function stcfl;
    input [3:0] svr;      // sched_v of the receiver FE
    input       pkv;      // pk_v_q of the receiver FE
    input [1:0] pkl;      // pk_lat_q of the receiver FE
    input [1:0] cc;       // donor class
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

  // unpack
  wire [1:0]    rob_lat [0:D-1];
  wire [AW-1:0] rob_tgt [0:D-1];
  wire [3:0] sched_v [0:NFE-1];
  genvar gi;
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ul
      assign rob_lat[gi] = rob_lat_f[gi*2 +: 2];
      assign rob_tgt[gi] = rob_tgt_f[gi*AW +: AW];
    end
    for (gi = 0; gi < NFE; gi = gi + 1) begin : g_us
      assign sched_v[gi] = sched_v_f[gi*4 +: 4];
    end
  endgenerate

  reg [NFE-1:0] pk_v_int;
  reg [AW-1:0]  pk_idx_q [0:NFE-1];
  reg [AW-1:0]  pk_tgt_q [0:NFE-1];
  reg [1:0]     pk_lat_q [0:NFE-1];
  reg [7:0]     pk_bank_oh_q [0:NFE-1];
  reg [7:0]     pk_local_oh_q [0:NFE-1];
  reg [D-1:0]   picked_q;

  // E005 stores the commit bitmap beside pk_v_int/pk_idx_q.  All three
  // registers describe the same picks, but pk_idx_q no longer passes through
  // a 6-to-64 decode before feeding the next picker or ROB old_u logic.
  assign picked = picked_q;

  // A registered pick is not removed from rdy_q until its issue/commit edge.
  // The one-hot mask preserves v2 scheduling behavior; the timing reduction
  // comes from the hierarchical selector replacing the 64-bit rotate/PE cone.
  wire [D-1:0] rdy_avail = rdy_q & ~picked;
  wire [D-1:0] rdy_eff   = rdy_avail
                           | (WAKE_BYPASS ? wake_now : {D{1'b0}});
  localparam [D-1:0] MASK_PHYS_EVEN = {32{2'b01}};
  wire [D-1:0] mask_age_even = rbase[0] ? ~MASK_PHYS_EVEN : MASK_PHYS_EVEN;

  // -------------------------------------------------------------------------
  // per class: two oldest ready candidates + critical-first primary
  // -------------------------------------------------------------------------
  wire [NFE-1:0] fnd_raw;
  wire [AW-1:0]  sel_idx [0:NFE-1];
  wire [AW-1:0]  sel_tgt [0:NFE-1];
  wire [D-1:0]   sel_oh  [0:NFE-1];
  wire [7:0]     sel_bank_oh [0:NFE-1];
  wire [7:0]     sel_local_oh [0:NFE-1];
  wire [NFE-1:0] sec_fnd;
  wire [AW-1:0]  sec_sel [0:NFE-1];

  genvar gf;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_pick
      reg [D-1:0] cand;
      integer ce;
      always @* begin
        for (ce = 0; ce < D; ce = ce + 1)
          cand[ce] = rdy_eff[ce] & (rob_lat[ce] == gf[1:0]);
      end
      if (DUAL_STEAL == 0) begin : g_safe
        // The safe profile consumes only the primary candidate.  Preserve the
        // hierarchical one-hot result beside its binary index so picked_n can
        // use it directly instead of decoding pk_idx_n back to 64 bits.
        wire [D+2*AW+17:0] page_h = peHoh(cand, rbase, rob_tgt_f);
        wire [D+2*AW+17:0] pec_h  = peHoh(cand & crit_q, rbase, rob_tgt_f);
        wire [AW:0] page = page_h[AW:0];
        wire [AW:0] pec  = pec_h[AW:0];
        // E016-N1 local-head equivalence: page.idx differs from rbase exactly
        // when the normal selector's base-bank post-mask PE did not select
        // rbase.  This keeps the decision parallel with the remaining bank
        // selection while reusing an 8-entry local cone already in peHoh.
        wire use_crit = pec[AW] && !page_h[D+2*AW+17];
        assign fnd_raw[gf] = use_crit ? pec[AW] : page[AW];
        assign sel_idx[gf] = use_crit ? pec[AW-1:0] : page[AW-1:0];
        assign sel_tgt[gf] = use_crit ? pec_h[2*AW:AW+1]
                                      : page_h[2*AW:AW+1];
        assign sel_oh[gf]  = use_crit ? pec_h[D+2*AW:2*AW+1]
                                      : page_h[D+2*AW:2*AW+1];
        assign sel_local_oh[gf] = use_crit
                                  ? pec_h[D+2*AW+8:D+2*AW+1]
                                  : page_h[D+2*AW+8:D+2*AW+1];
        assign sel_bank_oh[gf]  = use_crit
                                  ? pec_h[D+2*AW+16:D+2*AW+9]
                                  : page_h[D+2*AW+16:D+2*AW+9];
        assign sec_fnd[gf] = 1'b0;
        assign sec_sel[gf] = {AW{1'b0}};
      end else begin : g_dual
        // Dual/full profiles retain two parity candidates for work stealing.
        wire [AW:0]  pee  = peH(cand & mask_age_even, rbase);
        wire [AW:0]  peo  = peH(cand & ~mask_age_even, rbase);
        wire [AW:0]  pec  = peH(cand & crit_q, rbase);
        wire         bothf  = pee[AW] & peo[AW];
        wire [AW-1:0] pee_age = pee[AW-1:0] - rbase;
        wire [AW-1:0] peo_age = peo[AW-1:0] - rbase;
        wire         eolder = (pee_age < peo_age);
        wire [AW:0]  page = bothf ? (eolder ? pee : peo)
                                  : (pee[AW] ? pee : peo);
        // critical-first: a packet some dependent waits on jumps the queue,
        // unless the age-oldest candidate is the very window head (pos 0)
        wire [AW:0]  pri = (pec[AW] && (page[AW-1:0] != rbase))
                               ? pec : page;
        wire [AW:0]  sec = (pri == pee) ? peo : pee;
        assign fnd_raw[gf] = pri[AW];
        assign sel_idx[gf] = pri[AW-1:0];
        assign sel_tgt[gf] = {AW{1'b0}};
        assign sel_oh[gf]  = {D{1'b0}};
        assign sel_bank_oh[gf]  = 8'b0;
        assign sel_local_oh[gf] = 8'b0;
        assign sec_fnd[gf] = bothf && (sec[AW-1:0] != pri[AW-1:0]);
        assign sec_sel[gf] = sec[AW-1:0];
      end
    end
  endgenerate

  // own-class pick gate: the FE's output slot for its own latency may be
  // taken by an earlier steal of a longer latency
  reg [NFE-1:0] own_cfl;
  integer oc;
  always @* begin
    for (oc = 0; oc < NFE; oc = oc + 1) begin
      own_cfl[oc] = 1'b0;
      if (oc <= 1)
        if (sched_v[oc][oc+2]) own_cfl[oc] = 1'b1;   // sched_v[oc][oc+3] slot
      if (oc < 3)
        if (pk_v_int[oc] && (pk_lat_q[oc] == oc[1:0] + 2'd1))
          own_cfl[oc] = 1'b1;
    end
  end
  wire [NFE-1:0] fnd = (REG_FEIN == 0) ? (fnd_raw & ~own_cfl) : fnd_raw;

  // -------------------------------------------------------------------------
  // work stealing (up to two steals per cycle)
  // donors: registered 2nd candidates, re-validated this cycle
  // -------------------------------------------------------------------------
  reg [NFE-1:0] sec_v_q;
  reg [AW-1:0]  sec_idx_q [0:NFE-1];
  integer f;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) sec_v_q <= {NFE{1'b0}};
    else        sec_v_q <= sec_fnd;
  end
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1)
      // sec_v_q qualifies sec_idx_q, so the index is don't-care when no
      // secondary exists. Unconditional writes prevent a long pick condition
      // from being implemented as an ICG enable path for these small controls.
      sec_idx_q[f] <= sec_sel[f];
  end

  reg [NFE-1:0] don_ok;
  integer dc;
  always @* begin
    for (dc = 0; dc < NFE; dc = dc + 1)
      don_ok[dc] = sec_v_q[dc] && rdy_avail[sec_idx_q[dc]]
                   && !(fnd[dc] && (sel_idx[dc] == sec_idx_q[dc]));
  end

  reg        st1_v,  st2_v;
  reg [1:0]  st1_dc, st2_dc;
  reg [AW-1:0] st1_didx, st2_didx;
  reg [1:0]  st1_rr, st2_rr;
  reg        st1_dv, st2_dv, st1_rv, st2_rv;
  reg [AW-1:0] d_age, c_age;
  integer rr;
  always @* begin
    // donor 1 = valid donor whose secondary is globally OLDEST (smallest
    // rotated age distance) - issues window-critical work first
    st1_dv = 1'b0; st1_dc = 2'd0; st1_didx = {AW{1'b0}};
    d_age  = {AW{1'b1}};
    for (dc = NFE-1; dc >= 0; dc = dc - 1) begin
      c_age = sec_idx_q[dc] - rbase;
      if (don_ok[dc] && (!st1_dv || (c_age < d_age))) begin
        st1_dv = 1'b1; st1_dc = dc[1:0]; st1_didx = sec_idx_q[dc];
        d_age  = c_age;
      end
    end
    st1_rv = 1'b0; st1_rr = 2'd0;
    for (rr = NFE-1; rr >= 0; rr = rr - 1)
      if (!fnd[rr] && !stcfl(sched_v[rr], pk_v_int[rr], pk_lat_q[rr], st1_dc)) begin
        st1_rv = 1'b1; st1_rr = rr[1:0];
      end
    // Stealing assumes issue = pick+1 for its slot bookkeeping.  The E004
    // timing-safe profile also disables it to remove lane-to-lane picker
    // feedback; DUAL_STEAL=1 preserves both matchers for throughput A/B.
    st1_v = st1_dv & st1_rv & (REG_FEIN == 0) & (DUAL_STEAL != 0);

    // matcher 2: donor scanned 0->3 (must differ), receiver scanned 3->0
    st2_dv = 1'b0; st2_dc = 2'd0; st2_didx = {AW{1'b0}};
    for (dc = 0; dc < NFE; dc = dc + 1)
      if (don_ok[dc] && (!st1_v || (dc[1:0] != st1_dc))) begin
        st2_dv = 1'b1; st2_dc = dc[1:0]; st2_didx = sec_idx_q[dc];
      end
    st2_rv = 1'b0; st2_rr = 2'd0;
    for (rr = 0; rr < NFE; rr = rr + 1)
      if (!fnd[rr] && (!st1_v || (rr[1:0] != st1_rr))
          && !stcfl(sched_v[rr], pk_v_int[rr], pk_lat_q[rr], st2_dc)) begin
        st2_rv = 1'b1; st2_rr = rr[1:0];
      end
    st2_v = st2_dv & st2_rv & st1_v & (DUAL_STEAL != 0);
                                                // matcher 2 follows matcher 1
  end

  // -------------------------------------------------------------------------
  // pick registers + issue-FE record
  // -------------------------------------------------------------------------
  reg [NFE-1:0] pk_v_n;
  reg [AW-1:0] pk_idx_n [0:NFE-1];
  reg [AW-1:0] pk_tgt_n [0:NFE-1];
  reg [1:0]    pk_lat_n [0:NFE-1];
  reg [7:0]    pk_bank_oh_n [0:NFE-1];
  reg [7:0]    pk_local_oh_n [0:NFE-1];
  always @* begin
    for (f = 0; f < NFE; f = f + 1) begin
      pk_v_n[f] = fnd[f] | (st1_v && (st1_rr == f[1:0]))
                          | (st2_v && (st2_rr == f[1:0]));
      // pk_v_int qualifies both fields. Defaults are deliberately not the
      // previous register values, otherwise synthesis may infer clock enables
      // and place the full pick cone on clock-gating latch inputs.
      pk_idx_n[f] = sel_idx[f];
      pk_lat_n[f] = f[1:0];
      if (st1_v && (st1_rr == f[1:0])) begin
        pk_idx_n[f] = st1_didx;
        pk_lat_n[f] = st1_dc;
      end else if (st2_v && (st2_rr == f[1:0])) begin
        pk_idx_n[f] = st2_didx;
        pk_lat_n[f] = st2_dc;
      end
    end
  end

  // The safe selector already knows both hierarchy coordinates. Register
  // them beside pk_idx so I1 does not rebuild either 3-to-8 decoder on the
  // 128-bit packet-data path. Dual-steal can select a registered donor, so it
  // derives the same metadata from the final stolen index instead.
  generate
    if (DUAL_STEAL == 0) begin : g_safe_read_sel
      integer sf;
      always @* begin
        for (sf = 0; sf < NFE; sf = sf + 1) begin
          pk_bank_oh_n[sf]  = sel_bank_oh[sf];
          pk_local_oh_n[sf] = sel_local_oh[sf];
        end
      end
    end else begin : g_dual_read_sel
      integer sf;
      always @* begin
        for (sf = 0; sf < NFE; sf = sf + 1) begin
          pk_bank_oh_n[sf]  = 8'b0;
          pk_local_oh_n[sf] = 8'b0;
          pk_bank_oh_n[sf][pk_idx_n[sf][5:3]] = 1'b1;
          pk_local_oh_n[sf][pk_idx_n[sf][2:0]] = 1'b1;
        end
      end
    end
  endgenerate

  // Retimed target read.  In the timing-safe profile, use the target payload
  // carried through the hierarchical picker.  This avoids adding a second
  // 6-to-64 decode after pk_idx_n merely to select six target bits.
  // Dual-steal retains the binary read because a receiver may use a donor's
  // registered secondary index instead of its own primary one-hot.
  generate
    if (DUAL_STEAL == 0) begin : g_safe_tgt
      integer tf;
      always @* begin
        for (tf = 0; tf < NFE; tf = tf + 1)
          pk_tgt_n[tf] = sel_tgt[tf];
      end
    end else begin : g_dual_tgt
      integer tf;
      always @* begin
        for (tf = 0; tf < NFE; tf = tf + 1)
          pk_tgt_n[tf] = rob_tgt[pk_idx_n[tf]];
      end
    end
  endgenerate

  reg [D-1:0] picked_n;
  generate
    if (DUAL_STEAL == 0) begin : g_safe_picked
      integer pf;
      always @* begin
        picked_n = {D{1'b0}};
        for (pf = 0; pf < NFE; pf = pf + 1)
          if (pk_v_n[pf]) picked_n = picked_n | sel_oh[pf];
      end
    end else begin : g_dual_picked
      integer pf;
      always @* begin
        picked_n = {D{1'b0}};
        for (pf = 0; pf < NFE; pf = pf + 1)
          if (pk_v_n[pf]) picked_n[pk_idx_n[pf]] = 1'b1;
      end
    end
  endgenerate

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pk_v_int <= {NFE{1'b0}};
      picked_q <= {D{1'b0}};
    end else begin
      pk_v_int <= pk_v_n;
      picked_q <= picked_n;
    end
  end
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1) begin
      pk_idx_q[f] <= pk_idx_n[f];
      // Retiming the dependency target across the existing I0/I1 boundary
      // removes pk_idx_q -> rob_tgt[64:1] from the FE input cycle.  This is
      // unconditional so the picker cone cannot become an ICG-enable path.
      pk_tgt_q[f] <= pk_tgt_n[f];
      pk_lat_q[f] <= pk_lat_n[f];
      pk_bank_oh_q[f] <= pk_bank_oh_n[f];
      pk_local_oh_q[f] <= pk_local_oh_n[f];
    end
  end

  // record which FE each entry was issued to (result routing)
  reg [1:0] rob_src [0:D-1];
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1)
      if (pk_v_int[f]) rob_src[pk_idx_q[f]] <= f[1:0];
  end

  // -------------------------------------------------------------------------
  // exports
  // -------------------------------------------------------------------------
  always @* pk_v_q = pk_v_int;

  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_ex
      assign pk_idx_f[gf*AW +: AW] = pk_idx_q[gf];
      assign pk_tgt_f[gf*AW +: AW] = pk_tgt_q[gf];
      assign pk_lat_f[gf*2 +: 2]   = pk_lat_q[gf];
      assign pk_bank_oh_f[gf*8 +: 8]  = pk_bank_oh_q[gf];
      assign pk_local_oh_f[gf*8 +: 8] = pk_local_oh_q[gf];
    end
    for (gi = 0; gi < D; gi = gi + 1) begin : g_es
      assign rob_src_f[gi*2 +: 2] = rob_src[gi];
    end
  endgenerate

endmodule
