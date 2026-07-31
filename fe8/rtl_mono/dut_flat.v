// =============================================================================
// fast_forward top (8-FE variant) -- module name: dut -- Verilog-2001
//
// Score uses unified-suite execution time T:
// Score = 1/(T^2*sqrt(Area*Power)); equivalent Cost = T^4*Area*Power.
//
// Verilog-2001 port of the validated SystemVerilog design (../rtl/dut.sv);
// cycle-accurate identical behavior. Architecture (docs/design_spec.md):
//   * 8 Forwarding Engines, latency-class bound:
//       FE index f = {latclass[1:0], parity} = 2*L + p
//       - FE f only ever receives packets whose latency field == L(f)=f/2:
//         a same-latency stream NEVER collides at the FE output port ->
//         no busy/slot tracking at all, the per-FE in-flight tag tracker
//         degenerates to a fixed (L+1)-deep delay line.
//       - parity p = ROB entry index bit0: each entry's result comes from
//         exactly one FE per latency value -> tiny result write mux, and the
//         8 issue ports' candidate sets partition the ROB (zero arbitration).
//   * 64-entry ROB, unified storage (input data overwritten by the forwarded
//     result after issue -> one 128b register per packet).
//   * Out-of-order issue, in-order output through the ROB, lane = seq[1:0].
//   * Pre-wake: the tag delay line deterministically predicts a result one
//     cycle early, so a dependent packet enters the FE in the SAME cycle its
//     target's result appears on FEOUT (dp_data bypassed from the FEOUT bus).
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

  // ------------------------- FEIN (8 engines) ---------------------
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
  output wire         fwd4_pkt_data_vld,
  output wire [127:0] fwd4_pkt_data,
  output wire [1:0]   fwd4_pkt_lat,
  output wire         fwd4_pkt_dp_vld,
  output wire [127:0] fwd4_pkt_dp_data,
  output wire         fwd5_pkt_data_vld,
  output wire [127:0] fwd5_pkt_data,
  output wire [1:0]   fwd5_pkt_lat,
  output wire         fwd5_pkt_dp_vld,
  output wire [127:0] fwd5_pkt_dp_data,
  output wire         fwd6_pkt_data_vld,
  output wire [127:0] fwd6_pkt_data,
  output wire [1:0]   fwd6_pkt_lat,
  output wire         fwd6_pkt_dp_vld,
  output wire [127:0] fwd6_pkt_dp_data,
  output wire         fwd7_pkt_data_vld,
  output wire [127:0] fwd7_pkt_data,
  output wire [1:0]   fwd7_pkt_lat,
  output wire         fwd7_pkt_dp_vld,
  output wire [127:0] fwd7_pkt_dp_data,

  // ------------------------- FEOUT (8 engines) --------------------
  input  wire         fwded0_pkt_data_vld,
  input  wire [127:0] fwded0_pkt_data,
  input  wire         fwded1_pkt_data_vld,
  input  wire [127:0] fwded1_pkt_data,
  input  wire         fwded2_pkt_data_vld,
  input  wire [127:0] fwded2_pkt_data,
  input  wire         fwded3_pkt_data_vld,
  input  wire [127:0] fwded3_pkt_data,
  input  wire         fwded4_pkt_data_vld,
  input  wire [127:0] fwded4_pkt_data,
  input  wire         fwded5_pkt_data_vld,
  input  wire [127:0] fwded5_pkt_data,
  input  wire         fwded6_pkt_data_vld,
  input  wire [127:0] fwded6_pkt_data,
  input  wire         fwded7_pkt_data_vld,
  input  wire [127:0] fwded7_pkt_data
);

  // -------------------------------------------------------------------------
  // localparams
  // -------------------------------------------------------------------------
  localparam D   = 64;                 // ROB depth
  localparam AW  = 6;                  // ROB index width
  localparam SW  = 7;                  // sequence counter width (idx + wrap)
  localparam NFE = 8;

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
  reg [AW-1:0] rob_tgt   [0:D-1];
  reg          rob_isdep [0:D-1];

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
  // FEOUT buses, per-FE fixed tag delay lines, result write, wake-up
  // -------------------------------------------------------------------------
  wire [NFE-1:0] fe_ov = {fwded7_pkt_data_vld, fwded6_pkt_data_vld,
                          fwded5_pkt_data_vld, fwded4_pkt_data_vld,
                          fwded3_pkt_data_vld, fwded2_pkt_data_vld,
                          fwded1_pkt_data_vld, fwded0_pkt_data_vld};
  wire [127:0]   fe_od [0:NFE-1];
  assign fe_od[0] = fwded0_pkt_data;
  assign fe_od[1] = fwded1_pkt_data;
  assign fe_od[2] = fwded2_pkt_data;
  assign fe_od[3] = fwded3_pkt_data;
  assign fe_od[4] = fwded4_pkt_data;
  assign fe_od[5] = fwded5_pkt_data;
  assign fe_od[6] = fwded6_pkt_data;
  assign fe_od[7] = fwded7_pkt_data;

  wire [NFE-1:0] issue_v;
  wire [AW-1:0]  issue_idx [0:NFE-1];

  wire [NFE-1:0] exit_v;
  wire [AW-1:0]  exit_idx [0:NFE-1];
  wire [NFE-1:0] pre_v;
  wire [AW-1:0]  pre_idx  [0:NFE-1];

  genvar gf;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_tag
      // latency class = gf/2, FE latency = gf/2+1 cycles
      localparam TD = gf/2 + 1;
      reg [TD-1:0]  tv;
      reg [AW-1:0]  tq [0:TD-1];
      integer s;
      if (TD == 1) begin : g_t1
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) tv <= 1'b0;
          else        tv <= issue_v[gf];
        end
      end else begin : g_tn
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) tv <= {TD{1'b0}};
          else        tv <= {tv[TD-2:0], issue_v[gf]};
        end
      end
      always @(posedge clk) begin
        tq[0] <= issue_idx[gf];
        for (s = 1; s < TD; s = s + 1) tq[s] <= tq[s-1];
      end
      assign exit_v[gf]   = tv[TD-1];
      assign exit_idx[gf] = tq[TD-1];
      // one-cycle-early exit prediction (deterministic delay line)
      if (TD == 1) begin : g_p1
        assign pre_v[gf]   = issue_v[gf];
        assign pre_idx[gf] = issue_idx[gf];
      end else begin : g_pn
        assign pre_v[gf]   = tv[TD-2];
        assign pre_idx[gf] = tq[TD-2];
      end
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
  // I0: pick stage - one issue port per {latency class, entry parity}.
  //     The 8 candidate sets partition the ROB -> no inter-port arbitration.
  // -------------------------------------------------------------------------
  wire [D-1:0] rdy_eff = rdy_q | (WAKE_BYPASS ? wake_now : {D{1'b0}});
  wire [AW-1:0] rbase  = old_u_q[AW-1:0];

  wire [NFE-1:0]  fnd;
  wire [AW-1:0]   sel_idx  [0:NFE-1];
  reg  [NFE-1:0]  pk_v_q;
  reg  [AW-2:0]   pk_idxh_q [0:NFE-1];  // idx[AW-1:1]; idx[0] == port parity

  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_pick
      localparam [1:0] LCB = gf / 2;
      localparam       PR  = gf % 2;
      reg [D-1:0] cand;
      integer ce;
      always @* begin
        for (ce = 0; ce < D; ce = ce + 1)
          cand[ce] = rdy_eff[ce] & (rob_lat[ce] == LCB) & ((ce % 2) == PR);
      end
      wire [D-1:0] rot = rotrD(cand, rbase);
      wire [AW:0]  pe  = peD(rot);
      assign fnd[gf]     = pe[AW];
      assign sel_idx[gf] = pe[AW-1:0] + rbase;
    end
  endgenerate

  reg [D-1:0] picked;
  always @* begin
    picked = {D{1'b0}};
    for (f = 0; f < NFE; f = f + 1)
      if (fnd[f]) picked[sel_idx[f]] = 1'b1;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) pk_v_q <= {NFE{1'b0}};
    else        pk_v_q <= fnd;
  end
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1)
      if (fnd[f]) pk_idxh_q[f] <= sel_idx[f][AW-1:1];
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
      localparam [0:0] PRB = gf % 2;
      // parity fixed per port -> (D/2):1 data muxes
      wire [AW-1:0] ridx = {pk_idxh_q[gf], PRB};
      wire [AW-1:0] tgt  = rob_tgt[ridx];
      assign fein_v[gf]   = pk_v_q[gf];
      assign fein_d[gf]   = rob_data[ridx];
      assign fein_dpv[gf] = rob_isdep[ridx];
      // dp bypass: target result may be on the FEOUT bus this very cycle
      assign fein_dpd[gf] = res_now[tgt] ? fe_od[{rob_lat[tgt], tgt[0]}]
                                         : rob_data[tgt];
    end
  endgenerate

  wire         fo_v   [0:NFE-1];
  wire [127:0] fo_d   [0:NFE-1];
  wire         fo_dpv [0:NFE-1];
  wire [127:0] fo_dpd [0:NFE-1];

  generate
    if (REG_FEIN) begin : g_regfe
      reg [NFE-1:0] rv_q;
      reg [127:0]   rd_q   [0:NFE-1];
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
            rdpv_q[rf] <= fein_dpv[rf];
            rdpd_q[rf] <= fein_dpd[rf];
          end
        end
      end
      // tag pipes are fed from the registered (FEIN-aligned) stage
      always @(posedge clk) begin
        for (rf = 0; rf < NFE; rf = rf + 1)
          if (fein_v[rf]) ridx_q[rf] <= {pk_idxh_q[rf], rf[0]};
      end
      for (gf = 0; gf < NFE; gf = gf + 1) begin : g_ro
        assign fo_v[gf]      = rv_q[gf];
        assign fo_d[gf]      = rd_q[gf];
        assign fo_dpv[gf]    = rdpv_q[gf];
        assign fo_dpd[gf]    = rdpd_q[gf];
        assign issue_v[gf]   = rv_q[gf];
        assign issue_idx[gf] = ridx_q[gf];
      end
    end else begin : g_combfe
      for (gf = 0; gf < NFE; gf = gf + 1) begin : g_co
        localparam [0:0] PRB2 = gf % 2;
        assign fo_v[gf]      = fein_v[gf];
        assign fo_d[gf]      = fein_d[gf];
        assign fo_dpv[gf]    = fein_dpv[gf];
        assign fo_dpd[gf]    = fein_dpd[gf];
        assign issue_v[gf]   = pk_v_q[gf];
        assign issue_idx[gf] = {pk_idxh_q[gf], PRB2};
      end
    end
  endgenerate

  assign fwd0_pkt_data_vld = fo_v[0];
  assign fwd1_pkt_data_vld = fo_v[1];
  assign fwd2_pkt_data_vld = fo_v[2];
  assign fwd3_pkt_data_vld = fo_v[3];
  assign fwd4_pkt_data_vld = fo_v[4];
  assign fwd5_pkt_data_vld = fo_v[5];
  assign fwd6_pkt_data_vld = fo_v[6];
  assign fwd7_pkt_data_vld = fo_v[7];
  assign fwd0_pkt_data     = fo_d[0];
  assign fwd1_pkt_data     = fo_d[1];
  assign fwd2_pkt_data     = fo_d[2];
  assign fwd3_pkt_data     = fo_d[3];
  assign fwd4_pkt_data     = fo_d[4];
  assign fwd5_pkt_data     = fo_d[5];
  assign fwd6_pkt_data     = fo_d[6];
  assign fwd7_pkt_data     = fo_d[7];
  assign fwd0_pkt_dp_vld   = fo_dpv[0];
  assign fwd1_pkt_dp_vld   = fo_dpv[1];
  assign fwd2_pkt_dp_vld   = fo_dpv[2];
  assign fwd3_pkt_dp_vld   = fo_dpv[3];
  assign fwd4_pkt_dp_vld   = fo_dpv[4];
  assign fwd5_pkt_dp_vld   = fo_dpv[5];
  assign fwd6_pkt_dp_vld   = fo_dpv[6];
  assign fwd7_pkt_dp_vld   = fo_dpv[7];
  assign fwd0_pkt_dp_data  = fo_dpd[0];
  assign fwd1_pkt_dp_data  = fo_dpd[1];
  assign fwd2_pkt_dp_data  = fo_dpd[2];
  assign fwd3_pkt_dp_data  = fo_dpd[3];
  assign fwd4_pkt_dp_data  = fo_dpd[4];
  assign fwd5_pkt_dp_data  = fo_dpd[5];
  assign fwd6_pkt_dp_data  = fo_dpd[6];
  assign fwd7_pkt_dp_data  = fo_dpd[7];

  // latency field per FE is a constant (latency-class binding: L = f/2)
  assign fwd0_pkt_lat = 2'd0;
  assign fwd1_pkt_lat = 2'd0;
  assign fwd2_pkt_lat = 2'd1;
  assign fwd3_pkt_lat = 2'd1;
  assign fwd4_pkt_lat = 2'd2;
  assign fwd5_pkt_lat = 2'd2;
  assign fwd6_pkt_lat = 2'd3;
  assign fwd7_pkt_lat = 2'd3;

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
      out_dat[l] = res_now[osi] ? fe_od[{rob_lat[osi], osi[0]}]
                                : rob_data[osi];
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
        // unique result source per entry: FE {lat, entry parity}
        rob_data[e] <= fe_od[{rob_lat[e], e[0]}];
      end
    end
  end

`ifndef SYNTHESIS
  // internal consistency: FE result valids must match the tag-pipe schedule
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
