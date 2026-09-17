// =============================================================================
// ff_prefix_add7 - seven-bit parallel-prefix adder
//
// The sequence counters in this design are only seven bits wide, but a
// technology-independent '+' maps to a ripple carry in the simple timing
// proxy.  This fixed-width prefix form limits carry propagation to three
// merge levels (1/2/4 bits).  cin=1 with an inverted b implements a-b.
// =============================================================================
module ff_prefix_add7 (
  input  wire [6:0] a,
  input  wire [6:0] b,
  input  wire       cin,
  output wire [6:0] y
);
  wire [6:0] p0 = a ^ b;
  wire [6:0] g0 = a & b;
  wire [6:0] p1, g1, p2, g2, p4, g4;

  genvar i;
  generate
    for (i = 0; i < 7; i = i + 1) begin : g_l1
      if (i >= 1) begin
        assign p1[i] = p0[i] & p0[i-1];
        assign g1[i] = g0[i] | (p0[i] & g0[i-1]);
      end else begin
        assign p1[i] = p0[i];
        assign g1[i] = g0[i];
      end
    end
    for (i = 0; i < 7; i = i + 1) begin : g_l2
      if (i >= 2) begin
        assign p2[i] = p1[i] & p1[i-2];
        assign g2[i] = g1[i] | (p1[i] & g1[i-2]);
      end else begin
        assign p2[i] = p1[i];
        assign g2[i] = g1[i];
      end
    end
    for (i = 0; i < 7; i = i + 1) begin : g_l4
      if (i >= 4) begin
        assign p4[i] = p2[i] & p2[i-4];
        assign g4[i] = g2[i] | (p2[i] & g2[i-4]);
      end else begin
        assign p4[i] = p2[i];
        assign g4[i] = g2[i];
      end
    end
  endgenerate

  wire [7:0] carry;
  assign carry[0] = cin;
  generate
    for (i = 0; i < 7; i = i + 1) begin : g_carry
      assign carry[i+1] = g4[i] | (p4[i] & cin);
      assign y[i] = p0[i] ^ carry[i];
    end
  endgenerate
endmodule

// Four-bit prefix slice used by the registered 7-bit subtractor below.
module ff_prefix_add4 (
  input  wire [3:0] a,
  input  wire [3:0] b,
  input  wire       cin,
  output wire [3:0] y,
  output wire       cout
);
  wire [3:0] p0 = a ^ b;
  wire [3:0] g0 = a & b;
  wire [3:0] p1, g1, p2, g2;

  assign p1[0] = p0[0];
  assign g1[0] = g0[0];
  assign p1[1] = p0[1] & p0[0];
  assign g1[1] = g0[1] | (p0[1] & g0[0]);
  assign p1[2] = p0[2] & p0[1];
  assign g1[2] = g0[2] | (p0[2] & g0[1]);
  assign p1[3] = p0[3] & p0[2];
  assign g1[3] = g0[3] | (p0[3] & g0[2]);

  assign p2[0] = p1[0];
  assign g2[0] = g1[0];
  assign p2[1] = p1[1];
  assign g2[1] = g1[1];
  assign p2[2] = p1[2] & p1[0];
  assign g2[2] = g1[2] | (p1[2] & g1[0]);
  assign p2[3] = p1[3] & p1[1];
  assign g2[3] = g1[3] | (p1[3] & g1[1]);

  wire [4:0] carry;
  assign carry[0] = cin;
  assign carry[1] = g2[0] | (p2[0] & cin);
  assign carry[2] = g2[1] | (p2[1] & cin);
  assign carry[3] = g2[2] | (p2[2] & cin);
  assign carry[4] = g2[3] | (p2[3] & cin);
  assign y = p0 ^ carry[3:0];
  assign cout = carry[4];
endmodule

// Registered 4+3 split subtraction.  Each half has at most two prefix merge
// levels, so a-b no longer consumes a complete 7-bit clock stage.
module ff_split_sub7 (
  input  wire       clk,
  input  wire       rst_n,
  input  wire [6:0] a,
  input  wire [6:0] b,
  output wire [6:0] y
);
  wire [3:0] lo_y;
  wire       lo_cout;
  ff_prefix_add4 u_lo (
    .a(a[3:0]), .b(~b[3:0]), .cin(1'b1), .y(lo_y), .cout(lo_cout));

  reg [3:0] lo_q;
  reg [2:0] hi_a_q, hi_nb_q;
  reg       hi_cin_q;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lo_q     <= 4'b0;
      hi_a_q   <= 3'b0;
      hi_nb_q  <= 3'b0;
      hi_cin_q <= 1'b0;
    end else begin
      lo_q     <= lo_y;
      hi_a_q   <= a[6:4];
      hi_nb_q  <= ~b[6:4];
      hi_cin_q <= lo_cout;
    end
  end

  wire [3:0] hi_y;
  wire       hi_cout_unused;
  ff_prefix_add4 u_hi (
    .a({1'b0, hi_a_q}), .b({1'b0, hi_nb_q}), .cin(hi_cin_q),
    .y(hi_y), .cout(hi_cout_unused));
  assign y = {hi_y[2:0], lo_q};
endmodule
