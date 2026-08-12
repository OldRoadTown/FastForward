// =============================================================================
// ff_egress - in-order output stage
//
// RTL revision : 4FE-safe-v59
// Experiment   : E059-R64-IQ32-onehot-retirement-boundary
// Based on     : 4FE-safe-v28 / E029-R32
// Changes      : one-hot head drives lane mapping and retirement feedback
//
// Pops up to 4 contiguous completed entries starting at the one-hot head; lane
// = seq[1:0] (spec rotating-lane rule -> (D/4):1 mux per lane). A result
// is detected from registered result state. PKTOUT is registered.
// =============================================================================
module ff_egress #(
  parameter D   = 64,
  parameter AW  = 6,
  parameter SW  = 7,
  parameter NFE = 4
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [D-1:0]        out_oh,
  input  wire [D-1:0]        resv_q,
  input  wire [D-1:0]        live_q,
  input  wire [D*128-1:0]    rob_data_f,
  output wire [2:0]          pop_cnt,
  output wire [3:0]          pop_therm,
  output reg  [3:0]          lane_v,        // registered PKTOUT valids
  output reg  [511:0]        lane_d_f       // registered PKTOUT data, 4 x 128
);

  // unpack
  wire [127:0] rob_data [0:D-1];
  genvar gi;
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ur
      assign rob_data[gi] = rob_data_f[gi*128 +: 128];
    end
  endgenerate

  // Fixed rotations of the one-hot retirement head turn each completion read
  // into an AND plus a balanced OR tree. A result becomes eligible one cycle
  // after FEOUT, when ROB data and state have both been registered.
  wire [D-1:0] om0 = out_oh;
  wire [D-1:0] om1 = {out_oh[D-2:0], out_oh[D-1]};
  wire [D-1:0] om2 = {out_oh[D-3:0], out_oh[D-1:D-2]};
  wire [D-1:0] om3 = {out_oh[D-4:0], out_oh[D-1:D-3]};
  wire can0 = |(resv_q & live_q & om0);
  wire can1 = |(resv_q & live_q & om1);
  wire can2 = |(resv_q & live_q & om2);
  wire can3 = |(resv_q & live_q & om3);

  // The contiguous head test naturally produces a thermometer code. Consume
  // that form directly in lane/ROB control; the binary count now only feeds
  // the registered occupancy credit.
  assign pop_therm[0] = can0;
  assign pop_therm[1] = pop_therm[0] & can1;
  assign pop_therm[2] = pop_therm[1] & can2;
  assign pop_therm[3] = pop_therm[2] & can3;
  assign pop_cnt[2] = pop_therm[3];
  assign pop_cnt[1] = pop_therm[1] & ~pop_therm[3];
  assign pop_cnt[0] = pop_therm[0] ^ pop_therm[1]
                    ^ pop_therm[2] ^ pop_therm[3];

  // Four consecutive physical ROB positions contain exactly one packet for
  // each output lane. Reuse the one-hot head rotations to select that entry,
  // avoiding binary sequence arithmetic and address muxing.
  wire [D-1:0] head4_oh = om0 | om1 | om2 | om3;
  wire [D-1:0] retire_oh = ({D{pop_therm[0]}} & om0)
                         | ({D{pop_therm[1]}} & om1)
                         | ({D{pop_therm[2]}} & om2)
                         | ({D{pop_therm[3]}} & om3);
  wire [3:0] out_act;
  wire [127:0] out_dat [0:3];
  genvar gl, ge, gb, gd;
  generate
    for (gl = 0; gl < 4; gl = gl + 1) begin : g_lane_select
      wire [D/4-1:0] head_lane;
      wire [D/4-1:0] retire_lane;
      for (ge = 0; ge < D/4; ge = ge + 1) begin : g_lane_entry
        assign head_lane[ge] = head4_oh[gl + 4*ge];
        assign retire_lane[ge] = retire_oh[gl + 4*ge];
      end
      assign out_act[gl] = |retire_lane;
      for (gb = 0; gb < 128; gb = gb + 1) begin : g_lane_bit
        wire [D/4-1:0] data_term;
        for (gd = 0; gd < D/4; gd = gd + 1) begin : g_data_entry
          assign data_term[gd] = head_lane[gd]
                               & rob_data[gl + 4*gd][gb];
        end
        assign out_dat[gl][gb] = |data_term;
      end
    end
  endgenerate

  // registered PKTOUT
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) lane_v <= 4'b0;
    else        lane_v <= out_act;
  end
  integer l;
  always @(posedge clk) begin
    for (l = 0; l < 4; l = l + 1)
      // lane_v qualifies lane_d_f.  Always writing the data removes the
      // sched_idx/res_now -> out_act -> lane_d clock-gate enable path.
      lane_d_f[l*128 +: 128] <= out_dat[l];
  end

endmodule
