// =============================================================================
// ff_fetrack - per-FE in-flight tag tracking (8-FE latency-bound variant)
//
// FE f serves latency class L = f/2 only, so the tracker is a fixed
// (L+1)-deep delay line: FEIN valid at cycle t -> FEOUT valid at t+(L+1).
// pre_* is the deterministic one-cycle-early prediction used for pre-wake.
// =============================================================================
module ff_fetrack #(
  parameter AW  = 6,
  parameter NFE = 8
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [NFE-1:0]      issue_v,
  input  wire [NFE*AW-1:0]   issue_idx_f,
  output wire [NFE-1:0]      exit_v,
  output wire [NFE*AW-1:0]   exit_idx_f,
  output wire [NFE-1:0]      pre_v,
  output wire [NFE*AW-1:0]   pre_idx_f
);

  genvar gf;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_tag
      localparam TD = gf/2 + 1;         // latency class gf/2 -> L+1 cycles
      wire [AW-1:0] iidx = issue_idx_f[gf*AW +: AW];
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
        tq[0] <= iidx;
        for (s = 1; s < TD; s = s + 1) tq[s] <= tq[s-1];
      end
      assign exit_v[gf]              = tv[TD-1];
      assign exit_idx_f[gf*AW +: AW] = tq[TD-1];
      // one-cycle-early exit prediction (deterministic delay line)
      if (TD == 1) begin : g_p1
        assign pre_v[gf]              = issue_v[gf];
        assign pre_idx_f[gf*AW +: AW] = iidx;
      end else begin : g_pn
        assign pre_v[gf]              = tv[TD-2];
        assign pre_idx_f[gf*AW +: AW] = tq[TD-2];
      end
    end
  endgenerate

endmodule
