// =============================================================================
// ff_pick - I0 issue selection (8-FE variant)
//
// One issue port per {latency class, entry parity}: the 8 candidate sets
// partition the ROB, so there is no inter-port arbitration. Each port picks
// its oldest ready candidate in rotated age order (base = oldest un-issued).
// =============================================================================
module ff_pick #(
  parameter D           = 64,
  parameter AW          = 6,
  parameter NFE         = 8,
  parameter WAKE_BYPASS = 1
)(
  input  wire                    clk,
  input  wire                    rst_n,
  input  wire [D-1:0]            rdy_q,
  input  wire [D-1:0]            wake_now,
  input  wire [D*2-1:0]          rob_lat_f,
  input  wire [AW-1:0]           rbase,        // oldest un-issued index
  output reg  [D-1:0]            picked,
  output reg  [NFE-1:0]          pk_v_q,       // registered (I0 -> I1)
  output wire [NFE*(AW-1)-1:0]   pk_idxh_f     // idx[AW-1:1]; idx[0]=parity
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

  wire [1:0] rob_lat [0:D-1];
  genvar gi;
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ul
      assign rob_lat[gi] = rob_lat_f[gi*2 +: 2];
    end
  endgenerate

  wire [D-1:0] rdy_eff = rdy_q | (WAKE_BYPASS ? wake_now : {D{1'b0}});

  wire [NFE-1:0] fnd;
  wire [AW-1:0]  sel_idx [0:NFE-1];

  genvar gf;
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

  integer f;
  always @* begin
    picked = {D{1'b0}};
    for (f = 0; f < NFE; f = f + 1)
      if (fnd[f]) picked[sel_idx[f]] = 1'b1;
  end

  reg [AW-2:0] pk_idxh_q [0:NFE-1];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) pk_v_q <= {NFE{1'b0}};
    else        pk_v_q <= fnd;
  end
  always @(posedge clk) begin
    for (f = 0; f < NFE; f = f + 1)
      if (fnd[f]) pk_idxh_q[f] <= sel_idx[f][AW-1:1];
  end

  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_ex
      assign pk_idxh_f[gf*(AW-1) +: (AW-1)] = pk_idxh_q[gf];
    end
  endgenerate

endmodule
