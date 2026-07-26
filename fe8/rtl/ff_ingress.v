// =============================================================================
// ff_ingress - S0/S1: PKTIN input registers, valid-lane compaction, per-packet
//              attribute/dependency resolve, slot rotation, allocation one-hot
//
// Slot rotation: ROB entry e is only ever written from fixed source slot
// e[1:0], so each entry has a single input write source.
// =============================================================================
module ff_ingress #(
  parameter D  = 64,
  parameter AW = 6,
  parameter SW = 7
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
  // allocation outputs
  output wire [2:0]      acnt_o,
  output wire [511:0]    slot_dat_f,    // 4 x 128, slot j -> entries e[1:0]==j
  output wire [7:0]      slot_lat_f,    // 4 x 2
  output wire [4*AW-1:0] slot_tgt_f,
  output wire [3:0]      slot_rdy_o,
  output wire [3:0]      slot_wtg_o,
  output wire [3:0]      slot_isdep_o,
  output wire [D-1:0]    alloc_oh_o
);

  localparam PLW = 133;                 // {ctrl[4:0], data[127:0]}

  // -------------------------------------------------------------------------
  // unpack
  // -------------------------------------------------------------------------
  wire [127:0] in_data [0:3];
  wire [4:0]   in_ctrl [0:3];
  genvar gi;
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_up
      assign in_data[gi] = in_data_f[gi*128 +: 128];
      assign in_ctrl[gi] = in_ctrl_f[gi*5 +: 5];
    end
  endgenerate

  // -------------------------------------------------------------------------
  // S0 input registers (PKTIN must be registered before use)
  // -------------------------------------------------------------------------
  reg [3:0]   in_vld_q;
  reg [127:0] in_data_q [0:3];
  reg [4:0]   in_ctrl_q [0:3];
  integer i;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) in_vld_q <= 4'b0;
    else        in_vld_q <= in_vld;
  end
  always @(posedge clk) begin           // enable-gated datapath, no reset
    for (i = 0; i < 4; i = i + 1) begin
      if (in_vld[i]) begin
        in_data_q[i] <= in_data[i];
        in_ctrl_q[i] <= in_ctrl[i];
      end
    end
  end

  // -------------------------------------------------------------------------
  // valid-lane compaction into packet order
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

  // -------------------------------------------------------------------------
  // per-packet (k = position in packet order) attributes + dependency resolve
  // -------------------------------------------------------------------------
  reg [1:0]    k_lat  [0:3];
  reg [2:0]    k_dep  [0:3];
  reg [AW-1:0] k_tgt  [0:3];
  reg          k_rdy  [0:3];
  reg          k_wtg  [0:3];
  reg          k_isdep[0:3];

  integer k;
  reg [SW-1:0] seq_k, tgt_k;
  reg          incyc_k, tdone_k;
  always @* begin
    for (k = 0; k < 4; k = k + 1) begin
      k_lat[k]   = comp[k][129:128];
      k_dep[k]   = comp[k][132:130];
      k_isdep[k] = (k_dep[k] != 3'd0);
      seq_k      = alloc_seq + k[SW-1:0];
      tgt_k      = seq_k - {4'b0, k_dep[k]};
      k_tgt[k]   = tgt_k[AW-1:0];
      // same-cycle earlier-lane target cannot be done yet
      incyc_k    = k_isdep[k] && ({1'b0, k_dep[k]} <= k[3:0]);
      // retained-result lookup incl. same-cycle write and next-cycle predict
      tdone_k    = res_known[tgt_k[AW-1:0]];
      k_rdy[k]   = !k_isdep[k] || (!incyc_k && tdone_k);
      k_wtg[k]   = ~k_rdy[k];
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
  assign acnt_o       = acnt;
  assign slot_rdy_o   = slot_rdy;
  assign slot_wtg_o   = slot_wtg;
  assign slot_isdep_o = slot_isdep;
  assign alloc_oh_o   = alloc_oh;

endmodule
