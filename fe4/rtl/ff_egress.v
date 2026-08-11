// =============================================================================
// ff_egress - two-phase in-order output stage
//
// RTL revision : 4FE-safe-v43
// Experiment   : E043-400ps
// Based on     : E042-R64-IQ32
//
// Phase R0 uses a physical one-hot retirement head to test/read four entries
// in parallel.  Phase R1 operates only on the registered four-bit completion
// vector, emits PKTOUT, and commits pop_cnt/pop_oh.  The deliberate two-phase
// protocol removes the scheduler -> completion decode -> retirement -> ROB
// feedback path.  Same-cycle FEOUT bypass is not used: ROB captures the result
// first, then R0 observes resv_q on a later cycle.
// =============================================================================
module ff_egress #(
  parameter D   = 64,
  parameter AW  = 6,
  parameter SW  = 7,
  parameter NFE = 4
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [SW-1:0]       out_seq,
  input  wire [D-1:0]        resv_q,
  input  wire [D-1:0]        outp_q,
  input  wire [D-1:0]        res_now,
  input  wire [D*128-1:0]    rob_data_f,
  input  wire [D*2-1:0]      rob_src_f,
  input  wire [NFE*128-1:0]  fe_od_f,
  output reg  [2:0]          pop_cnt,
  output reg  [D-1:0]        pop_oh,
  output reg  [3:0]          lane_v,
  output reg  [511:0]        lane_d_f
);

  wire [127:0] rob_data [0:D-1];
  genvar gi;
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_unpack_data
      assign rob_data[gi] = rob_data_f[gi*128 +: 128];
    end
  endgenerate

  // Physical retirement pointer.  Four fixed rotations replace four 64:1
  // indexed completion muxes with four parallel AND/OR reductions.
  reg [D-1:0] scan_oh_q;
  wire [D-1:0] scan0 = scan_oh_q;
  wire [D-1:0] scan1 = {scan_oh_q[D-2:0], scan_oh_q[D-1]};
  wire [D-1:0] scan2 = {scan_oh_q[D-3:0], scan_oh_q[D-1:D-2]};
  wire [D-1:0] scan3 = {scan_oh_q[D-4:0], scan_oh_q[D-1:D-3]};
  wire [D-1:0] retireable = resv_q & ~outp_q;
  wire [3:0] scan_can = {|(retireable & scan3),
                         |(retireable & scan2),
                         |(retireable & scan1),
                         |(retireable & scan0)};

  // One-hot data reads happen beside the completion reductions in R0.
  reg [127:0] scan_dat [0:3];
  integer e;
  always @* begin
    scan_dat[0] = 128'b0;
    scan_dat[1] = 128'b0;
    scan_dat[2] = 128'b0;
    scan_dat[3] = 128'b0;
    for (e = 0; e < D; e = e + 1) begin
      scan_dat[0] = scan_dat[0] | (rob_data[e] & {128{scan0[e]}});
      scan_dat[1] = scan_dat[1] | (rob_data[e] & {128{scan1[e]}});
      scan_dat[2] = scan_dat[2] | (rob_data[e] & {128{scan2[e]}});
      scan_dat[3] = scan_dat[3] | (rob_data[e] & {128{scan3[e]}});
    end
  end

  reg         ret_v_q;
  reg [3:0]   ret_can_q;
  reg [1:0]   ret_base_q;
  reg [127:0] ret_dat_q [0:3];

  wire take0 = ret_v_q & ret_can_q[0];
  wire take1 = take0 & ret_can_q[1];
  wire take2 = take1 & ret_can_q[2];
  wire take3 = take2 & ret_can_q[3];
  always @* begin
    // Thermometer-to-binary without a priority-mux cascade.
    pop_cnt[2] = take3;
    pop_cnt[1] = take1 & ~take3;
    pop_cnt[0] = (take0 & ~take1) | (take2 & ~take3);
  end

  // scan_oh_q still points at the R0 batch while ret_v_q is set.  The pop
  // bitmap therefore needs only four one-hot gates and a shallow OR.
  always @* begin
    pop_oh = ({D{take0}} & scan0)
           | ({D{take1}} & scan1)
           | ({D{take2}} & scan2)
           | ({D{take3}} & scan3);
  end

  reg [3:0]   out_act;
  reg [127:0] out_dat [0:3];
  reg [1:0]   out_lane;
  integer k;
  always @* begin
    out_act = 4'b0;
    out_dat[0] = 128'b0;
    out_dat[1] = 128'b0;
    out_dat[2] = 128'b0;
    out_dat[3] = 128'b0;
    for (k = 0; k < 4; k = k + 1) begin
      out_lane = ret_base_q + k[1:0];
      out_dat[out_lane] = ret_dat_q[k];
      case (k)
        0: out_act[out_lane] = take0;
        1: out_act[out_lane] = take1;
        2: out_act[out_lane] = take2;
        3: out_act[out_lane] = take3;
      endcase
    end
  end

  // R0 capture and R1 commit alternate. ret_base_q is also the modulo-four
  // output-lane head, avoiding a dependency on the ROB's full binary counter.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ret_v_q    <= 1'b0;
      ret_can_q  <= 4'b0;
      ret_base_q <= 2'b0;
      scan_oh_q  <= {{(D-1){1'b0}}, 1'b1};
    end else if (ret_v_q) begin
      ret_v_q <= 1'b0;
      ret_base_q <= ret_base_q + pop_cnt[1:0];
      case (pop_cnt)
        3'd1: scan_oh_q <= scan1;
        3'd2: scan_oh_q <= scan2;
        3'd3: scan_oh_q <= scan3;
        3'd4: scan_oh_q <= {scan_oh_q[D-5:0], scan_oh_q[D-1:D-4]};
        default: scan_oh_q <= scan_oh_q;
      endcase
    end else begin
      ret_v_q    <= 1'b1;
      ret_can_q  <= scan_can;
    end
  end

  always @(posedge clk) begin
    if (!ret_v_q) begin
      ret_dat_q[0] <= scan_dat[0];
      ret_dat_q[1] <= scan_dat[1];
      ret_dat_q[2] <= scan_dat[2];
      ret_dat_q[3] <= scan_dat[3];
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) lane_v <= 4'b0;
    else        lane_v <= out_act;
  end
  always @(posedge clk) begin
    lane_d_f[0*128 +: 128] <= out_dat[0];
    lane_d_f[1*128 +: 128] <= out_dat[1];
    lane_d_f[2*128 +: 128] <= out_dat[2];
    lane_d_f[3*128 +: 128] <= out_dat[3];
  end

  // Kept in the interface for drop-in compatibility with E042.  res_now,
  // rob_src_f and fe_od_f are intentionally not part of the E043 R0 cone.
  wire _unused_ok = &{1'b0, out_seq[0], res_now[0], rob_src_f[0], fe_od_f[0]};

endmodule
