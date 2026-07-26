// =============================================================================
// ff_pick - I0 issue selection (4-FE work-stealing variant)
//
// Per latency class: the two oldest ready candidates are found with parallel
// priority encodes on even/odd rotated positions; a packet some dependent is
// waiting on (critical) jumps the queue (unless the age-oldest candidate is
// the very window head). If a class has a backlog (2nd candidate) while
// another FE is idle, the idle FE steals it (up to two steals per cycle),
// gated by exact output-slot conflict checks against the ff_sched booking.
// rob_src records the FE each entry was issued to (result routing).
// =============================================================================
module ff_pick #(
  parameter D           = 64,
  parameter AW          = 6,
  parameter NFE         = 4,
  parameter WAKE_BYPASS = 1,
  parameter REG_FEIN    = 0    // steal bookkeeping assumes issue = pick+1:
                               // with REG_FEIN (pick+2) stealing is disabled
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [D-1:0]        rdy_q,
  input  wire [D-1:0]        wake_now,
  input  wire [D-1:0]        crit_q,
  input  wire [D*2-1:0]      rob_lat_f,
  input  wire [AW-1:0]       rbase,        // oldest un-issued index
  input  wire [NFE*4-1:0]    sched_v_f,    // output-slot booking (ff_sched)
  output reg  [D-1:0]        picked,
  output reg  [NFE-1:0]      pk_v_q,       // registered (I0 -> I1)
  output wire [NFE*AW-1:0]   pk_idx_f,
  output wire [NFE*2-1:0]    pk_lat_f,
  output wire [D*2-1:0]      rob_src_f     // FE each entry was issued to
);

  function [D-1:0] rotrD;
    input [D-1:0]  v;
    input [AW-1:0] s;
    reg [2*D-1:0] t;
    begin
      t     = {v, v} >> s;
      rotrD = t[D-1:0];
    end
  endfunction

  function [AW:0] peD;
    input [D-1:0] v;
    integer i;
    begin
      peD = {(AW+1){1'b0}};
      for (i = D-1; i >= 0; i = i - 1)
        if (v[i]) peD = {1'b1, i[AW-1:0]};
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
  wire [1:0] rob_lat [0:D-1];
  wire [3:0] sched_v [0:NFE-1];
  genvar gi;
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ul
      assign rob_lat[gi] = rob_lat_f[gi*2 +: 2];
    end
    for (gi = 0; gi < NFE; gi = gi + 1) begin : g_us
      assign sched_v[gi] = sched_v_f[gi*4 +: 4];
    end
  endgenerate

  wire [D-1:0] rdy_eff  = rdy_q | (WAKE_BYPASS ? wake_now : {D{1'b0}});
  localparam [D-1:0] MASK_EVEN = {32{2'b01}};
  wire [D-1:0] crit_rot = rotrD(crit_q, rbase);

  reg [NFE-1:0] pk_v_int;
  reg [AW-1:0]  pk_idx_q [0:NFE-1];
  reg [1:0]     pk_lat_q [0:NFE-1];

  // -------------------------------------------------------------------------
  // per class: two oldest ready candidates + critical-first primary
  // -------------------------------------------------------------------------
  wire [NFE-1:0] fnd_raw;
  wire [AW-1:0]  sel_idx [0:NFE-1];
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
      wire [D-1:0] rot  = rotrD(cand, rbase);
      wire [AW:0]  pee  = peD(rot & MASK_EVEN);
      wire [AW:0]  peo  = peD(rot & ~MASK_EVEN);
      wire [AW:0]  pec  = peD(rot & crit_rot);   // oldest critical candidate
      wire         bothf  = pee[AW] & peo[AW];
      wire         eolder = (pee[AW-1:0] < peo[AW-1:0]);
      wire [AW:0]  page = bothf ? (eolder ? pee : peo)
                                : (pee[AW] ? pee : peo);
      // critical-first: a packet some dependent waits on jumps the queue,
      // unless the age-oldest candidate is the very window head (pos 0)
      wire [AW:0]  pri = (pec[AW] && (page[AW-1:0] != {AW{1'b0}})) ? pec
                                                                   : page;
      wire [AW:0]  sec = (pri == pee) ? peo : pee;
      assign fnd_raw[gf] = pri[AW];
      assign sel_idx[gf] = pri[AW-1:0] + rbase;
      assign sec_fnd[gf] = bothf && (sec[AW-1:0] != pri[AW-1:0]);
      assign sec_sel[gf] = sec[AW-1:0] + rbase;
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
      if (sec_fnd[f]) sec_idx_q[f] <= sec_sel[f];
  end

  reg [NFE-1:0] don_ok;
  integer dc;
  always @* begin
    for (dc = 0; dc < NFE; dc = dc + 1)
      don_ok[dc] = sec_v_q[dc] && rdy_q[sec_idx_q[dc]]
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
    // stealing assumes issue = pick+1 for its slot bookkeeping; with the
    // REG_FEIN fallback (issue = pick+2) disable stealing entirely - the
    // remaining pure latency-binding is structurally collision-free
    st1_v = st1_dv & st1_rv & (REG_FEIN == 0);

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
    st2_v = st2_dv & st2_rv & st1_v;   // matcher 2 only on top of matcher 1
  end

  // -------------------------------------------------------------------------
  // picked bitmap + pick registers + issue-FE record
  // -------------------------------------------------------------------------
  always @* begin
    picked = {D{1'b0}};
    for (f = 0; f < NFE; f = f + 1)
      if (fnd[f]) picked[sel_idx[f]] = 1'b1;
    if (st1_v) picked[st1_didx] = 1'b1;
    if (st2_v) picked[st2_didx] = 1'b1;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) pk_v_int <= {NFE{1'b0}};
    else begin
      for (f = 0; f < NFE; f = f + 1)
        pk_v_int[f] <= fnd[f] | (st1_v && (st1_rr == f[1:0]))
                              | (st2_v && (st2_rr == f[1:0]));
    end
  end
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1) begin
      if (st1_v && (st1_rr == f[1:0])) begin
        pk_idx_q[f] <= st1_didx;
        pk_lat_q[f] <= st1_dc;
      end else if (st2_v && (st2_rr == f[1:0])) begin
        pk_idx_q[f] <= st2_didx;
        pk_lat_q[f] <= st2_dc;
      end else if (fnd[f]) begin
        pk_idx_q[f] <= sel_idx[f];
        pk_lat_q[f] <= f[1:0];
      end
    end
  end

  // record which FE each entry was issued to (result routing)
  reg [1:0] rob_src [0:D-1];
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1)
      if (fnd[f]) rob_src[sel_idx[f]] <= f[1:0];
    if (st1_v) rob_src[st1_didx] <= st1_rr;
    if (st2_v) rob_src[st2_didx] <= st2_rr;
  end

  // -------------------------------------------------------------------------
  // exports
  // -------------------------------------------------------------------------
  always @* pk_v_q = pk_v_int;

  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_ex
      assign pk_idx_f[gf*AW +: AW] = pk_idx_q[gf];
      assign pk_lat_f[gf*2 +: 2]   = pk_lat_q[gf];
    end
    for (gi = 0; gi < D; gi = gi + 1) begin : g_es
      assign rob_src_f[gi*2 +: 2] = rob_src[gi];
    end
  endgenerate

endmodule
