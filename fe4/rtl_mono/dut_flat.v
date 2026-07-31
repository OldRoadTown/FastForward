// =============================================================================
// fast_forward top (4-FE out-of-order variant) -- module: dut -- Verilog-2001
//
// Score uses unified-suite execution time T:
// Score = 1/(T^2*sqrt(Area*Power)); equivalent Cost = T^4*Area*Power.
//
// Architecture (see fe4/docs/design_spec.md):
//   * 4 Forwarding Engines. Primary binding: FE[L] serves latency class L
//     (a same-latency stream never collides at the FE output port).
//   * WORK STEALING: each class picks its two oldest ready packets (parallel
//     even/odd-position priority encodes). If some class has a backlog
//     (a 2nd candidate) while another FE is idle, the idle FE "steals" one
//     packet per cycle. A per-FE 4-slot result scheduler books output slots
//     exactly, so mixed-latency streams on one FE can never collide.
//   * 64-entry ROB, unified storage (input data overwritten by the forwarded
//     result after issue -> one 128b register per packet).
//   * Out-of-order issue, in-order output through the ROB, lane = seq[1:0].
//   * Pre-wake: the result scheduler predicts a result one cycle early, so a
//     dependent packet enters the FE in the SAME cycle its target's result
//     appears on FEOUT (dp_data bypassed from the FEOUT bus).
//   * Retained results + backpressure windows guarantee a target's forwarded
//     result survives in the ROB until every possible dependent (window = 7)
//     has issued, even if the target packet was already output.
//
// PKTIN registered before use; PKTOUT/BKPR registered outputs (spec).
// FEIN/FEOUT are internal interfaces (no register constraint).
//   REG_FEIN=1    : add an output register stage on FEIN  (timing fallback)
//   WAKE_BYPASS=0 : disable same-cycle pick on pre-wake   (timing fallback)
// =============================================================================
module dut #(
  parameter REG_FEIN    = 0,
  parameter WAKE_BYPASS = 1
)(
  input  wire         clk,
  input  wire         rst_n,

  // ------------------------- PKTIN --------------------------------
  input  wire         lane0_pkt_in_vld,
  input  wire [127:0] lane0_pkt_in_data,
  input  wire [4:0]   lane0_pkt_in_ctrl,
  input  wire         lane1_pkt_in_vld,
  input  wire [127:0] lane1_pkt_in_data,
  input  wire [4:0]   lane1_pkt_in_ctrl,
  input  wire         lane2_pkt_in_vld,
  input  wire [127:0] lane2_pkt_in_data,
  input  wire [4:0]   lane2_pkt_in_ctrl,
  input  wire         lane3_pkt_in_vld,
  input  wire [127:0] lane3_pkt_in_data,
  input  wire [4:0]   lane3_pkt_in_ctrl,

  // ------------------------- PKTOUT -------------------------------
  output reg          lane0_pkt_out_vld,
  output reg  [127:0] lane0_pkt_out_data,
  output reg          lane1_pkt_out_vld,
  output reg  [127:0] lane1_pkt_out_data,
  output reg          lane2_pkt_out_vld,
  output reg  [127:0] lane2_pkt_out_data,
  output reg          lane3_pkt_out_vld,
  output reg  [127:0] lane3_pkt_out_data,

  // ------------------------- BKPR ---------------------------------
  output reg          pkt_in_bkpr,

  // ------------------------- FEIN (4 engines) ---------------------
  output wire         fwd0_pkt_data_vld,
  output wire [127:0] fwd0_pkt_data,
  output wire [1:0]   fwd0_pkt_lat,
  output wire         fwd0_pkt_dp_vld,
  output wire [127:0] fwd0_pkt_dp_data,
  output wire         fwd1_pkt_data_vld,
  output wire [127:0] fwd1_pkt_data,
  output wire [1:0]   fwd1_pkt_lat,
  output wire         fwd1_pkt_dp_vld,
  output wire [127:0] fwd1_pkt_dp_data,
  output wire         fwd2_pkt_data_vld,
  output wire [127:0] fwd2_pkt_data,
  output wire [1:0]   fwd2_pkt_lat,
  output wire         fwd2_pkt_dp_vld,
  output wire [127:0] fwd2_pkt_dp_data,
  output wire         fwd3_pkt_data_vld,
  output wire [127:0] fwd3_pkt_data,
  output wire [1:0]   fwd3_pkt_lat,
  output wire         fwd3_pkt_dp_vld,
  output wire [127:0] fwd3_pkt_dp_data,

  // ------------------------- FEOUT (4 engines) --------------------
  input  wire         fwded0_pkt_data_vld,
  input  wire [127:0] fwded0_pkt_data,
  input  wire         fwded1_pkt_data_vld,
  input  wire [127:0] fwded1_pkt_data,
  input  wire         fwded2_pkt_data_vld,
  input  wire [127:0] fwded2_pkt_data,
  input  wire         fwded3_pkt_data_vld,
  input  wire [127:0] fwded3_pkt_data
);

  // -------------------------------------------------------------------------
  // localparams
  // -------------------------------------------------------------------------
  localparam D   = 64;                 // ROB depth
  localparam AW  = 6;                  // ROB index width
  localparam SW  = 7;                  // sequence counter width (idx + wrap)
  localparam NFE = 4;

  // BKPR thresholds (2 cycles / up to 8 packets of unaccounted in-flight
  // input between the combinational decision and the throttle taking effect):
  //  * occupancy   : entry reuse (seq n overwrites n-64):  (D-1)-8      = 55
  //  * issue window: retained-result overwrite hazard   : (D-7)-8-lag   = 45
  localparam [SW-1:0] OCC_TH = 55;
  localparam [SW-1:0] WIN_TH = 45;

  localparam PLW = 133;                // {ctrl[4:0], data[127:0]}

  // -------------------------------------------------------------------------
  // helper functions
  // -------------------------------------------------------------------------
  function [D-1:0] rotrD;              // rotate right by s: out[j]=v[(j+s)%D]
    input [D-1:0]  v;
    input [AW-1:0] s;
    reg [2*D-1:0] t;
    begin
      t     = {v, v} >> s;
      rotrD = t[D-1:0];
    end
  endfunction

  function [AW:0] peD;                 // priority encode from bit0:
    input [D-1:0] v;                   // {found, position[AW-1:0]}
    integer i;
    begin
      peD = {(AW+1){1'b0}};
      for (i = D-1; i >= 0; i = i - 1)
        if (v[i]) peD = {1'b1, i[AW-1:0]};
    end
  endfunction

  // -------------------------------------------------------------------------
  // input packing + S0 input registers (PKTIN must be registered before use)
  // -------------------------------------------------------------------------
  wire [3:0]   in_vld = {lane3_pkt_in_vld, lane2_pkt_in_vld,
                         lane1_pkt_in_vld, lane0_pkt_in_vld};
  wire [127:0] in_data [0:3];
  wire [4:0]   in_ctrl [0:3];

  assign in_data[0] = lane0_pkt_in_data;
  assign in_data[1] = lane1_pkt_in_data;
  assign in_data[2] = lane2_pkt_in_data;
  assign in_data[3] = lane3_pkt_in_data;
  assign in_ctrl[0] = lane0_pkt_in_ctrl;
  assign in_ctrl[1] = lane1_pkt_in_ctrl;
  assign in_ctrl[2] = lane2_pkt_in_ctrl;
  assign in_ctrl[3] = lane3_pkt_in_ctrl;

  reg [3:0]   in_vld_q;
  reg [127:0] in_data_q [0:3];
  reg [4:0]   in_ctrl_q [0:3];
  integer i;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) in_vld_q <= 4'b0;
    else        in_vld_q <= in_vld;
  end
  always @(posedge clk) begin          // enable-gated datapath, no reset
    for (i = 0; i < 4; i = i + 1) begin
      if (in_vld[i]) begin
        in_data_q[i] <= in_data[i];
        in_ctrl_q[i] <= in_ctrl[i];
      end
    end
  end

  // -------------------------------------------------------------------------
  // ROB state
  // -------------------------------------------------------------------------
  reg [127:0]  rob_data  [0:D-1];      // input data, later the fwded result
  reg [1:0]    rob_lat   [0:D-1];
  reg [1:0]    rob_src   [0:D-1];      // FE the packet was issued to
  reg [AW-1:0] rob_tgt   [0:D-1];
  reg          rob_isdep [0:D-1];

  reg [D-1:0]  crit_q;                 // some dependent is waiting on this
  reg [D-1:0]  rdy_q;                  // ready, not yet picked
  reg [D-1:0]  wtg_q;                  // waiting for dependency result
  reg [D-1:0]  iss_q;                  // picked/issued
  reg [D-1:0]  resv_q;                 // result present (retained after pop)
  reg [D-1:0]  outp_q;                 // popped to PKTOUT

  reg [SW-1:0] alloc_seq_q;
  reg [SW-1:0] out_seq_q;
  reg [SW-1:0] old_u_q;                // oldest un-issued sequence number

  // -------------------------------------------------------------------------
  // S1: allocation - lane compaction, sequence numbering, dependency resolve
  // -------------------------------------------------------------------------
  reg [PLW-1:0] comp [0:3];
  reg [2:0]     acnt;
  wire [PLW-1:0] pl0 = {in_ctrl_q[0], in_data_q[0]};
  wire [PLW-1:0] pl1 = {in_ctrl_q[1], in_data_q[1]};
  wire [PLW-1:0] pl2 = {in_ctrl_q[2], in_data_q[2]};
  wire [PLW-1:0] pl3 = {in_ctrl_q[3], in_data_q[3]};

  always @* begin
    comp[0] = pl0; comp[1] = pl1; comp[2] = pl2; comp[3] = pl3;
    acnt    = 3'd0;
    case (in_vld_q)
      4'b0000: acnt = 3'd0;
      4'b0001: begin acnt = 3'd1; comp[0] = pl0; end
      4'b0010: begin acnt = 3'd1; comp[0] = pl1; end
      4'b0100: begin acnt = 3'd1; comp[0] = pl2; end
      4'b1000: begin acnt = 3'd1; comp[0] = pl3; end
      4'b0011: begin acnt = 3'd2; comp[0] = pl0; comp[1] = pl1; end
      4'b0101: begin acnt = 3'd2; comp[0] = pl0; comp[1] = pl2; end
      4'b1001: begin acnt = 3'd2; comp[0] = pl0; comp[1] = pl3; end
      4'b0110: begin acnt = 3'd2; comp[0] = pl1; comp[1] = pl2; end
      4'b1010: begin acnt = 3'd2; comp[0] = pl1; comp[1] = pl3; end
      4'b1100: begin acnt = 3'd2; comp[0] = pl2; comp[1] = pl3; end
      4'b0111: begin acnt = 3'd3; comp[0] = pl0; comp[1] = pl1; comp[2] = pl2; end
      4'b1011: begin acnt = 3'd3; comp[0] = pl0; comp[1] = pl1; comp[2] = pl3; end
      4'b1101: begin acnt = 3'd3; comp[0] = pl0; comp[1] = pl2; comp[2] = pl3; end
      4'b1110: begin acnt = 3'd3; comp[0] = pl1; comp[1] = pl2; comp[2] = pl3; end
      4'b1111: begin acnt = 3'd4; comp[0] = pl0; comp[1] = pl1;
                     comp[2] = pl2; comp[3] = pl3; end
      default: acnt = 3'd0;
    endcase
  end

  // per-packet (k = position in this cycle's packet order) attributes
  reg [1:0]    k_lat  [0:3];
  reg [2:0]    k_dep  [0:3];
  reg [AW-1:0] k_tgt  [0:3];
  reg          k_rdy  [0:3];
  reg          k_wtg  [0:3];
  reg          k_isdep[0:3];

  wire [D-1:0] res_now;                // result written this cycle
  wire [D-1:0] res_pred;               // result arriving next cycle

  integer k;
  reg [SW-1:0] seq_k, tgt_k;
  reg          incyc_k, tdone_k;
  always @* begin
    for (k = 0; k < 4; k = k + 1) begin
      k_lat[k]   = comp[k][129:128];
      k_dep[k]   = comp[k][132:130];
      k_isdep[k] = (k_dep[k] != 3'd0);
      seq_k      = alloc_seq_q + k[SW-1:0];
      tgt_k      = seq_k - {4'b0, k_dep[k]};
      k_tgt[k]   = tgt_k[AW-1:0];
      // same-cycle earlier-lane target cannot be done yet
      incyc_k    = k_isdep[k] && ({1'b0, k_dep[k]} <= k[3:0]);
      // retained-result lookup incl. same-cycle write and next-cycle predict
      tdone_k    = resv_q[tgt_k[AW-1:0]] | res_now[tgt_k[AW-1:0]]
                                         | res_pred[tgt_k[AW-1:0]];
      k_rdy[k]   = !k_isdep[k] || (!incyc_k && tdone_k);
      k_wtg[k]   = ~k_rdy[k];
    end
  end

  // rotate packet-order slots so entry e is only written from slot e[1:0]
  reg [127:0]   slot_dat [0:3];
  reg [1:0]     slot_lat [0:3];
  reg [AW-1:0]  slot_tgt [0:3];
  reg           slot_rdy [0:3];
  reg           slot_wtg [0:3];
  reg           slot_isdep [0:3];

  integer j;
  reg [1:0] kj;
  always @* begin
    for (j = 0; j < 4; j = j + 1) begin
      kj            = j[1:0] - alloc_seq_q[1:0];
      slot_dat[j]   = comp[kj][127:0];
      slot_lat[j]   = k_lat[kj];
      slot_tgt[j]   = k_tgt[kj];
      slot_rdy[j]   = k_rdy[kj];
      slot_wtg[j]   = k_wtg[kj];
      slot_isdep[j] = k_isdep[kj];
    end
  end

  reg [D-1:0] alloc_oh;
  reg [SW-1:0] aseq;
  always @* begin
    alloc_oh = {D{1'b0}};
    for (k = 0; k < 4; k = k + 1) begin
      aseq = alloc_seq_q + k[SW-1:0];
      if (k[2:0] < acnt) alloc_oh[aseq[AW-1:0]] = 1'b1;
    end
  end

  // -------------------------------------------------------------------------
  // FEOUT buses + per-FE 4-slot result scheduler
  //   during cycle x, slot s (1..4) holds a result exiting at cycle x+(s-1);
  //   exit = slot1, prediction (exit next cycle) = slot2.
  //   An issue during cycle u with lat class c books slot c+1 -> exact
  //   output-collision bookkeeping even for mixed-latency (stolen) streams.
  // -------------------------------------------------------------------------
  wire [NFE-1:0] fe_ov = {fwded3_pkt_data_vld, fwded2_pkt_data_vld,
                          fwded1_pkt_data_vld, fwded0_pkt_data_vld};
  wire [127:0]   fe_od [0:NFE-1];
  assign fe_od[0] = fwded0_pkt_data;
  assign fe_od[1] = fwded1_pkt_data;
  assign fe_od[2] = fwded2_pkt_data;
  assign fe_od[3] = fwded3_pkt_data;

  wire [NFE-1:0] issue_v;
  wire [AW-1:0]  issue_idx [0:NFE-1];
  wire [1:0]     issue_lat [0:NFE-1];

  reg [4:1]    sched_v   [0:NFE-1];
  reg [AW-1:0] sched_idx [0:NFE-1][1:4];

  integer sf, sk;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (sf = 0; sf < NFE; sf = sf + 1) sched_v[sf] <= 4'b0;
    end else begin
      for (sf = 0; sf < NFE; sf = sf + 1) begin
        for (sk = 1; sk <= 3; sk = sk + 1)
          sched_v[sf][sk] <= sched_v[sf][sk+1];
        sched_v[sf][4] <= 1'b0;
        if (issue_v[sf])
          sched_v[sf][{1'b0, issue_lat[sf]} + 3'd1] <= 1'b1;
      end
    end
  end
  always @(posedge clk) begin
    for (sf = 0; sf < NFE; sf = sf + 1) begin
      for (sk = 1; sk <= 3; sk = sk + 1)
        sched_idx[sf][sk] <= sched_idx[sf][sk+1];
      if (issue_v[sf])
        sched_idx[sf][{1'b0, issue_lat[sf]} + 3'd1] <= issue_idx[sf];
    end
  end

  wire [NFE-1:0] exit_v;
  wire [AW-1:0]  exit_idx [0:NFE-1];
  wire [NFE-1:0] pre_v;
  wire [AW-1:0]  pre_idx  [0:NFE-1];

  genvar gf;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_exit
      assign exit_v[gf]   = sched_v[gf][1];
      assign exit_idx[gf] = sched_idx[gf][1];
      // lat-class-0 issue this cycle also exits next cycle
      assign pre_v[gf]    = sched_v[gf][2]
                          | (issue_v[gf] & (issue_lat[gf] == 2'd0));
      assign pre_idx[gf]  = sched_v[gf][2] ? sched_idx[gf][2] : issue_idx[gf];
    end
  endgenerate

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
  assign res_now  = res_now_r;
  assign res_pred = res_pred_r;

  // pre-wake: target result arrives next cycle -> dependent can enter the FE
  // in the same cycle the result shows up on FEOUT (dp taken from the bus)
  reg [D-1:0] wake_now;
  integer e;
  always @* begin
    for (e = 0; e < D; e = e + 1)
      wake_now[e] = wtg_q[e] & res_pred[rob_tgt[e]];
  end

  // -------------------------------------------------------------------------
  // I0 pick: per class, two oldest ready candidates via parallel priority
  //          encodes on even/odd rotated positions
  // -------------------------------------------------------------------------
  wire [D-1:0] rdy_eff = rdy_q | (WAKE_BYPASS ? wake_now : {D{1'b0}});
  wire [AW-1:0] rbase  = old_u_q[AW-1:0];
  localparam [D-1:0] MASK_EVEN = {32{2'b01}};
  wire [D-1:0] crit_rot = rotrD(crit_q, rbase);

  wire [NFE-1:0] fnd_raw;
  wire [AW-1:0]  sel_idx [0:NFE-1];
  wire [NFE-1:0] sec_fnd;
  wire [AW-1:0]  sec_sel [0:NFE-1];

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

  // pick registers (I0 -> I1), lat now dynamic because of stealing
  reg [NFE-1:0] pk_v_q;
  reg [AW-1:0]  pk_idx_q [0:NFE-1];
  reg [1:0]     pk_lat_q [0:NFE-1];

  // own-class pick gate: the FE's output slot for its own latency may be
  // taken by an earlier steal of a longer latency
  reg [NFE-1:0] own_cfl;
  integer oc;
  always @* begin
    for (oc = 0; oc < NFE; oc = oc + 1) begin
      own_cfl[oc] = 1'b0;
      if (oc <= 1)
        if (sched_v[oc][oc+3]) own_cfl[oc] = 1'b1;
      if (oc < 3)
        if (pk_v_q[oc] && (pk_lat_q[oc] == oc[1:0] + 2'd1))
          own_cfl[oc] = 1'b1;
    end
  end
  wire [NFE-1:0] fnd = (REG_FEIN == 0) ? (fnd_raw & ~own_cfl) : fnd_raw;

  // ---------------- work stealing (up to two steals per cycle) ------------
  // donors: registered 2nd candidates, re-validated this cycle
  reg [NFE-1:0] sec_v_q;
  reg [AW-1:0]  sec_idx_q [0:NFE-1];
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

  // steal-conflict on receiver rr for donor class cc: output slot must be
  // free in the booked pipeline and not being booked by the packet
  // currently issuing on that FE
  function stcfl;
    input [3:0] svr;      // sched_v[rr]
    input       pkv;      // pk_v_q[rr]
    input [1:0] pkl;      // pk_lat_q[rr]
    input [1:0] cc;       // donor class
    begin
      // svr[k-1] carries sched_v[k]; need sched_v[cc+3]
      stcfl = 1'b0;
      if (cc <= 2'd1) begin
        if (cc == 2'd0) stcfl = svr[2];
        else            stcfl = svr[3];
      end
      if (cc != 2'd3)
        if (pkv && (pkl == cc + 2'd1)) stcfl = 1'b1;
    end
  endfunction

  // matcher 1: donor scanned 0->3, receiver scanned 0->3
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
      if (!fnd[rr] && !stcfl(sched_v[rr], pk_v_q[rr], pk_lat_q[rr], st1_dc)) begin
        st1_rv = 1'b1; st1_rr = rr[1:0];
      end
    // stealing assumes issue = pick+1 for its slot bookkeeping; with the
    // REG_FEIN fallback (issue = pick+2) disable stealing entirely - the
    // remaining pure latency-binding is structurally collision-free
    st1_v = st1_dv & st1_rv & (REG_FEIN == 0);

    // matcher 2: donor scanned 3->0 (must differ), receiver scanned 3->0
    st2_dv = 1'b0; st2_dc = 2'd0; st2_didx = {AW{1'b0}};
    for (dc = 0; dc < NFE; dc = dc + 1)
      if (don_ok[dc] && (!st1_v || (dc[1:0] != st1_dc))) begin
        st2_dv = 1'b1; st2_dc = dc[1:0]; st2_didx = sec_idx_q[dc];
      end
    st2_rv = 1'b0; st2_rr = 2'd0;
    for (rr = 0; rr < NFE; rr = rr + 1)
      if (!fnd[rr] && (!st1_v || (rr[1:0] != st1_rr))
          && !stcfl(sched_v[rr], pk_v_q[rr], pk_lat_q[rr], st2_dc)) begin
        st2_rv = 1'b1; st2_rr = rr[1:0];
      end
    st2_v = st2_dv & st2_rv & st1_v;   // matcher 2 only on top of matcher 1
  end

  reg [D-1:0] picked;
  always @* begin
    picked = {D{1'b0}};
    for (f = 0; f < NFE; f = f + 1)
      if (fnd[f]) picked[sel_idx[f]] = 1'b1;
    if (st1_v) picked[st1_didx] = 1'b1;
    if (st2_v) picked[st2_didx] = 1'b1;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) pk_v_q <= {NFE{1'b0}};
    else begin
      for (f = 0; f < NFE; f = f + 1)
        pk_v_q[f] <= fnd[f] | (st1_v && (st1_rr == f[1:0]))
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
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1)
      if (fnd[f]) rob_src[sel_idx[f]] <= f[1:0];
    if (st1_v) rob_src[st1_didx] <= st1_rr;
    if (st2_v) rob_src[st2_didx] <= st2_rr;
  end

  // -------------------------------------------------------------------------
  // I1: issue stage - read ROB data / dependency data, drive FEIN
  // -------------------------------------------------------------------------
  wire         fein_v   [0:NFE-1];
  wire [127:0] fein_d   [0:NFE-1];
  wire         fein_dpv [0:NFE-1];
  wire [127:0] fein_dpd [0:NFE-1];

  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_iss
      wire [AW-1:0] ridx = pk_idx_q[gf];
      wire [AW-1:0] tgt  = rob_tgt[ridx];
      assign fein_v[gf]   = pk_v_q[gf];
      assign fein_d[gf]   = rob_data[ridx];
      assign fein_dpv[gf] = rob_isdep[ridx];
      // dp bypass: target result may be on the FEOUT bus this very cycle
      assign fein_dpd[gf] = res_now[tgt] ? fe_od[rob_src[tgt]]
                                         : rob_data[tgt];
    end
  endgenerate

  wire         fo_v   [0:NFE-1];
  wire [127:0] fo_d   [0:NFE-1];
  wire [1:0]   fo_l   [0:NFE-1];
  wire         fo_dpv [0:NFE-1];
  wire [127:0] fo_dpd [0:NFE-1];

  generate
    if (REG_FEIN) begin : g_regfe
      reg [NFE-1:0] rv_q;
      reg [127:0]   rd_q   [0:NFE-1];
      reg [1:0]     rl_q   [0:NFE-1];
      reg           rdpv_q [0:NFE-1];
      reg [127:0]   rdpd_q [0:NFE-1];
      reg [AW-1:0]  ridx_q [0:NFE-1];
      integer rf;
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rv_q <= {NFE{1'b0}};
        else for (rf = 0; rf < NFE; rf = rf + 1) rv_q[rf] <= fein_v[rf];
      end
      always @(posedge clk) begin
        for (rf = 0; rf < NFE; rf = rf + 1) begin
          if (fein_v[rf]) begin
            rd_q[rf]   <= fein_d[rf];
            rl_q[rf]   <= pk_lat_q[rf];
            rdpv_q[rf] <= fein_dpv[rf];
            rdpd_q[rf] <= fein_dpd[rf];
            ridx_q[rf] <= pk_idx_q[rf];
          end
        end
      end
      for (gf = 0; gf < NFE; gf = gf + 1) begin : g_ro
        assign fo_v[gf]      = rv_q[gf];
        assign fo_d[gf]      = rd_q[gf];
        assign fo_l[gf]      = rl_q[gf];
        assign fo_dpv[gf]    = rdpv_q[gf];
        assign fo_dpd[gf]    = rdpd_q[gf];
        assign issue_v[gf]   = rv_q[gf];
        assign issue_idx[gf] = ridx_q[gf];
        assign issue_lat[gf] = rl_q[gf];
      end
    end else begin : g_combfe
      for (gf = 0; gf < NFE; gf = gf + 1) begin : g_co
        assign fo_v[gf]      = fein_v[gf];
        assign fo_d[gf]      = fein_d[gf];
        assign fo_l[gf]      = pk_lat_q[gf];
        assign fo_dpv[gf]    = fein_dpv[gf];
        assign fo_dpd[gf]    = fein_dpd[gf];
        assign issue_v[gf]   = pk_v_q[gf];
        assign issue_idx[gf] = pk_idx_q[gf];
        assign issue_lat[gf] = pk_lat_q[gf];
      end
    end
  endgenerate

  assign fwd0_pkt_data_vld = fo_v[0];
  assign fwd1_pkt_data_vld = fo_v[1];
  assign fwd2_pkt_data_vld = fo_v[2];
  assign fwd3_pkt_data_vld = fo_v[3];
  assign fwd0_pkt_data     = fo_d[0];
  assign fwd1_pkt_data     = fo_d[1];
  assign fwd2_pkt_data     = fo_d[2];
  assign fwd3_pkt_data     = fo_d[3];
  assign fwd0_pkt_lat      = fo_l[0];
  assign fwd1_pkt_lat      = fo_l[1];
  assign fwd2_pkt_lat      = fo_l[2];
  assign fwd3_pkt_lat      = fo_l[3];
  assign fwd0_pkt_dp_vld   = fo_dpv[0];
  assign fwd1_pkt_dp_vld   = fo_dpv[1];
  assign fwd2_pkt_dp_vld   = fo_dpv[2];
  assign fwd3_pkt_dp_vld   = fo_dpv[3];
  assign fwd0_pkt_dp_data  = fo_dpd[0];
  assign fwd1_pkt_dp_data  = fo_dpd[1];
  assign fwd2_pkt_dp_data  = fo_dpd[2];
  assign fwd3_pkt_dp_data  = fo_dpd[3];

  // -------------------------------------------------------------------------
  // Output stage: pop up to 4 contiguous completed entries, lane = seq[1:0];
  //               a result arriving THIS cycle pops this cycle (bypass)
  // -------------------------------------------------------------------------
  wire [D-1:0] cmpl = resv_q | res_now;

  wire [AW-1:0] oidx0 = out_seq_q[AW-1:0];
  wire [AW-1:0] oidx1 = out_seq_q[AW-1:0] + 6'd1;
  wire [AW-1:0] oidx2 = out_seq_q[AW-1:0] + 6'd2;
  wire [AW-1:0] oidx3 = out_seq_q[AW-1:0] + 6'd3;
  wire can0 = cmpl[oidx0] & ~outp_q[oidx0];
  wire can1 = cmpl[oidx1] & ~outp_q[oidx1];
  wire can2 = cmpl[oidx2] & ~outp_q[oidx2];
  wire can3 = cmpl[oidx3] & ~outp_q[oidx3];

  reg [2:0] pop_cnt;
  always @* begin
    pop_cnt = 3'd0;
    if (can0) begin
      pop_cnt = 3'd1;
      if (can1) begin
        pop_cnt = 3'd2;
        if (can2) begin
          pop_cnt = 3'd3;
          if (can3) pop_cnt = 3'd4;
        end
      end
    end
  end

  reg [D-1:0] pop_oh;
  always @* begin
    pop_oh = {D{1'b0}};
    if (pop_cnt > 3'd0) pop_oh[oidx0] = 1'b1;
    if (pop_cnt > 3'd1) pop_oh[oidx1] = 1'b1;
    if (pop_cnt > 3'd2) pop_oh[oidx2] = 1'b1;
    if (pop_cnt > 3'd3) pop_oh[oidx3] = 1'b1;
  end

  reg [3:0]    out_act;
  reg [127:0]  out_dat [0:3];
  integer l;
  reg [1:0]     kl;
  reg [AW-1:0]  osrc, osi;
  always @* begin
    for (l = 0; l < 4; l = l + 1) begin
      kl         = l[1:0] - out_seq_q[1:0];
      out_act[l] = ({1'b0, kl} < pop_cnt);
      osrc       = out_seq_q[AW-1:0] + {4'b0, kl};
      osi        = {osrc[AW-1:2], l[1:0]};   // osrc[1:0]==l by construction
      out_dat[l] = res_now[osi] ? fe_od[rob_src[osi]] : rob_data[osi];
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lane0_pkt_out_vld <= 1'b0;
      lane1_pkt_out_vld <= 1'b0;
      lane2_pkt_out_vld <= 1'b0;
      lane3_pkt_out_vld <= 1'b0;
    end else begin
      lane0_pkt_out_vld <= out_act[0];
      lane1_pkt_out_vld <= out_act[1];
      lane2_pkt_out_vld <= out_act[2];
      lane3_pkt_out_vld <= out_act[3];
    end
  end
  always @(posedge clk) begin
    if (out_act[0]) lane0_pkt_out_data <= out_dat[0];
    if (out_act[1]) lane1_pkt_out_data <= out_dat[1];
    if (out_act[2]) lane2_pkt_out_data <= out_dat[2];
    if (out_act[3]) lane3_pkt_out_data <= out_dat[3];
  end

  // -------------------------------------------------------------------------
  // oldest-un-issued pointer: full-speed catch-up, clamped at alloc frontier
  // -------------------------------------------------------------------------
  reg [SW-1:0] adv;
  reg [SW-1:0] adv_raw, dist_f;
  reg [D-1:0]  niss_rot;
  reg [AW:0]   ffz;
  always @* begin
    niss_rot = rotrD(~iss_q, old_u_q[AW-1:0]);
    ffz      = peD(niss_rot);
    adv_raw  = ffz[AW] ? {1'b0, ffz[AW-1:0]} : 7'd64;
    dist_f   = alloc_seq_q - old_u_q;
    adv      = (adv_raw > dist_f) ? dist_f : adv_raw;
  end

  // -------------------------------------------------------------------------
  // BKPR (registered output)
  // -------------------------------------------------------------------------
  wire [SW-1:0] alloc_nxt = alloc_seq_q + {4'b0, acnt};
  wire [SW-1:0] occ       = alloc_nxt - out_seq_q;
  wire [SW-1:0] win       = alloc_nxt - old_u_q;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) pkt_in_bkpr <= 1'b0;
    else        pkt_in_bkpr <= (occ > OCC_TH) || (win > WIN_TH);
  end

  // -------------------------------------------------------------------------
  // ROB state update
  // -------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdy_q       <= {D{1'b0}};
      crit_q      <= {D{1'b0}};
      wtg_q       <= {D{1'b0}};
      iss_q       <= {D{1'b0}};
      resv_q      <= {D{1'b0}};
      outp_q      <= {D{1'b0}};
      alloc_seq_q <= {SW{1'b0}};
      out_seq_q   <= {SW{1'b0}};
      old_u_q     <= {SW{1'b0}};
    end else begin
      for (e = 0; e < D; e = e + 1) begin
        if (alloc_oh[e]) begin
          rdy_q[e]  <= slot_rdy[e[1:0]];
          wtg_q[e]  <= slot_wtg[e[1:0]];
          crit_q[e] <= 1'b0;
          iss_q[e]  <= 1'b0;
          resv_q[e] <= 1'b0;
          outp_q[e] <= 1'b0;
        end else begin
          if (picked[e]) begin
            rdy_q[e] <= 1'b0;
            iss_q[e] <= 1'b1;
          end else if (wake_now[e]) begin
            rdy_q[e] <= 1'b1;
          end
          if (wake_now[e]) wtg_q[e]  <= 1'b0;
          if (res_now[e])  resv_q[e] <= 1'b1;
          if (pop_oh[e])   outp_q[e] <= 1'b1;
        end
      end
      // mark dependency targets of newly waiting packets as critical
      // (placed after the entry loop: overrides the alloc-clear when the
      //  target is allocated in the same cycle)
      for (k = 0; k < 4; k = k + 1) begin
        if ((k[2:0] < acnt) && k_wtg[k]) crit_q[k_tgt[k]] <= 1'b1;
      end
      alloc_seq_q <= alloc_seq_q + {4'b0, acnt};
      out_seq_q   <= out_seq_q + {4'b0, pop_cnt};
      old_u_q     <= old_u_q + adv;
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
      end else if (res_now[e]) begin
        rob_data[e] <= fe_od[rob_src[e]];  // unique result source per entry
      end
    end
  end

`ifndef SYNTHESIS
  // internal consistency: FE result valids must match the booked schedule
  always @(posedge clk) begin
    if (rst_n) begin
      for (f = 0; f < NFE; f = f + 1) begin
        if (exit_v[f] !== fe_ov[f])
          $display("[dut] ERROR: FE%0d result valid mismatch @%0t", f, $time);
      end
    end
  end
`endif

endmodule
