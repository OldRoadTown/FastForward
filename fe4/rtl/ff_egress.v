// =============================================================================
// ff_egress - in-order output stage
//
// RTL revision : 4FE-safe-v67
// Experiment   : E067-R32-retire-bitmap-cleanup
// Based on     : 4FE-safe-v20 / E021-N1
// Changes      : rely on monotonic out_seq instead of a retired-entry bitmap
//
// Pops up to 4 contiguous completed entries starting at out_seq, output lane
// = seq[1:0] (spec rotating-lane rule -> (D/4):1 mux per lane). A result
// arriving in this cycle may pop through the FEOUT bypass. PKTOUT is registered.
// =============================================================================
module ff_egress #(
  parameter D   = 32,
  parameter AW  = 5,
  parameter SW  = 6,
  parameter NFE = 4
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [SW-1:0]       alloc_seq,
  input  wire [SW-1:0]       out_seq,
  input  wire [D-1:0]        resv_q,
  input  wire [D-1:0]        res_now,
  input  wire [D*128-1:0]    rob_data_f,
  input  wire [D*2-1:0]      rob_src_f,     // FE each entry was issued to
  input  wire [NFE*128-1:0]  fe_od_f,
  output reg  [2:0]          pop_cnt,
  output reg  [3:0]          lane_v,        // registered PKTOUT valids
  output reg  [511:0]        lane_d_f       // registered PKTOUT data, 4 x 128
);

  // unpack
  wire [127:0] rob_data [0:D-1];
  wire [1:0]   rob_src  [0:D-1];
  wire [127:0] fe_od    [0:NFE-1];
  genvar gi;
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ur
      assign rob_data[gi] = rob_data_f[gi*128 +: 128];
      assign rob_src[gi]  = rob_src_f[gi*2 +: 2];
    end
    for (gi = 0; gi < NFE; gi = gi + 1) begin : g_uo
      assign fe_od[gi] = fe_od_f[gi*128 +: 128];
    end
  endgenerate

  // Same-cycle result bypass remains part of the completion check.
  wire [D-1:0] cmpl = resv_q | res_now;

  wire [AW-1:0] oidx0 = out_seq[AW-1:0];
  wire [AW-1:0] oidx1 = out_seq[AW-1:0] + {{(AW-2){1'b0}}, 2'd1};
  wire [AW-1:0] oidx2 = out_seq[AW-1:0] + {{(AW-2){1'b0}}, 2'd2};
  wire [AW-1:0] oidx3 = out_seq[AW-1:0] + {{(AW-2){1'b0}}, 2'd3};
  // out_seq always identifies the first not-yet-retired sequence. Once an
  // entry retires, the head advances at the same edge, so a separate popped
  // bitmap and its 3-to-32 feedback decode are redundant.  The live count
  // qualifies retained result bits after the ROB becomes empty or wraps.
  wire [SW-1:0] live_cnt = alloc_seq - out_seq;
  wire can0 = (live_cnt > 0) && cmpl[oidx0];
  wire can1 = (live_cnt > 1) && cmpl[oidx1];
  wire can2 = (live_cnt > 2) && cmpl[oidx2];
  wire can3 = (live_cnt > 3) && cmpl[oidx3];

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

  // lane mapping + same-cycle result data mux
  reg [3:0]    out_act;
  reg [127:0]  out_dat [0:3];
  integer l;
  reg [1:0]     kl;
  reg [AW-1:0]  osrc, osi;
  always @* begin
    for (l = 0; l < 4; l = l + 1) begin
      kl         = l[1:0] - out_seq[1:0];
      out_act[l] = ({1'b0, kl} < pop_cnt);
      osrc       = out_seq[AW-1:0] + {{(AW-2){1'b0}}, kl};
      osi        = {osrc[AW-1:2], l[1:0]};   // osrc[1:0]==l by construction
      out_dat[l] = res_now[osi] ? fe_od[rob_src[osi]] : rob_data[osi];
    end
  end

  // registered PKTOUT
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) lane_v <= 4'b0;
    else        lane_v <= out_act;
  end
  always @(posedge clk) begin
    for (l = 0; l < 4; l = l + 1)
      // lane_v qualifies lane_d_f.  Always writing the data removes the
      // sched_idx/res_now -> out_act -> lane_d clock-gate enable path.
      lane_d_f[l*128 +: 128] <= out_dat[l];
  end

endmodule
