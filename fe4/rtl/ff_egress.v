// =============================================================================
// ff_egress - in-order output stage
//
// RTL revision : 4FE-safe-v72a
// Experiment   : E072A-R32-completion-spill
// Based on     : E068-R32-dynamic-bkpr-credit
// Changes      : retire physical/spill results without a tag compare in pop path
//
// Pops up to 4 contiguous stored-complete entries starting at out_seq, output
// lane = seq[1:0]. Results retire only after their ROB/spill write edge, which
// keeps completion routing off the pop -> out_seq critical path.
// =============================================================================
module ff_egress #(
  parameter D   = 32,
  parameter AW  = 5,
  parameter SW  = 6
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [SW-1:0]       alloc_seq,
  input  wire [SW-1:0]       out_seq,
  input  wire [D-1:0]        resv_q,
  input  wire [3:0]          spill_resv,
  input  wire [4*128-1:0]    spill_data_f,
  input  wire [D*128-1:0]    rob_data_f,
  output reg  [2:0]          pop_cnt,
  output wire [3:0]          pop_therm,
  output reg  [3:0]          lane_v,        // registered PKTOUT valids
  output reg  [511:0]        lane_d_f       // registered PKTOUT data, 4 x 128
);

  // unpack
  wire [127:0] rob_data [0:D-1];
  wire [127:0] spill_data [0:3];
  genvar gi;
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ur
      assign rob_data[gi] = rob_data_f[gi*128 +: 128];
    end
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_us
      assign spill_data[gi] = spill_data_f[gi*128 +: 128];
    end
  endgenerate

  wire [D-1:0] cmpl = resv_q;
  wire [SW-1:0] live_cnt = alloc_seq - out_seq;

  wire [SW-1:0] oseq [0:3];
  wire [AW-1:0] oidx [0:3];
  wire [3:0] spill_head;
  wire live_gt32 = live_cnt[5] & (|live_cnt[4:0]);
  wire live_gt33 = live_cnt[5] & (|live_cnt[4:1]);
  wire live_gt34 = live_cnt[5]
                   & ((|live_cnt[4:2]) | (&live_cnt[1:0]));
  wire live_gt35 = live_cnt[5] & (|live_cnt[4:2]);
  assign spill_head = {live_gt35, live_gt34, live_gt33, live_gt32};
  genvar go;
  generate
    for (go = 0; go < 4; go = go + 1) begin : g_head
      assign oseq[go] = out_seq + go[SW-1:0];
      assign oidx[go] = oseq[go][AW-1:0];
      // The spill always holds the four sequences immediately behind the
      // newest 32 physical residents. Therefore a retirement candidate is in
      // spill exactly when more than D+go live entries remain; no tag compare
      // is needed on the pop/out-sequence critical path.
    end
  endgenerate
  // out_seq always identifies the first not-yet-retired sequence. Once an
  // entry retires, the head advances at the same edge, so a separate popped
  // bitmap and its 3-to-32 feedback decode are redundant.  The live count
  // qualifies retained result bits after the ROB becomes empty or wraps.
  wire can0 = (live_cnt > 0)
              && (spill_head[0] ? spill_resv[oseq[0][1:0]]
                               : cmpl[oidx[0]]);
  wire can1 = (live_cnt > 1)
              && (spill_head[1] ? spill_resv[oseq[1][1:0]]
                               : cmpl[oidx[1]]);
  wire can2 = (live_cnt > 2)
              && (spill_head[2] ? spill_resv[oseq[2][1:0]]
                               : cmpl[oidx[2]]);
  wire can3 = (live_cnt > 3)
              && (spill_head[3] ? spill_resv[oseq[3][1:0]]
                               : cmpl[oidx[3]]);

  // Contiguous retirement already forms a thermometer code. Export it so
  // ROB backpressure can consume same-edge progress without re-encoding the
  // binary pop count or speculating about a future completion.
  assign pop_therm[0] = can0;
  assign pop_therm[1] = pop_therm[0] & can1;
  assign pop_therm[2] = pop_therm[1] & can2;
  assign pop_therm[3] = pop_therm[2] & can3;

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

  // lane mapping + physical/spill stored-data mux
  reg [3:0]    out_act;
  reg [127:0]  out_dat [0:3];
  integer l;
  reg [1:0]     kl;
  reg [AW-1:0]  osrc, osi;
  reg [SW-1:0]  oseq_l;
  always @* begin
    for (l = 0; l < 4; l = l + 1) begin
      kl         = l[1:0] - out_seq[1:0];
      out_act[l] = ({1'b0, kl} < pop_cnt);
      osrc       = out_seq[AW-1:0] + {{(AW-2){1'b0}}, kl};
      osi        = {osrc[AW-1:2], l[1:0]};   // osrc[1:0]==l by construction
      oseq_l     = out_seq + {{(SW-2){1'b0}}, kl};
      if (spill_head[kl])
        out_dat[l] = spill_data[oseq_l[1:0]];
      else
        out_dat[l] = rob_data[osi];
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
      // completion routing -> out_act -> lane_d clock-gate enable path.
      lane_d_f[l*128 +: 128] <= out_dat[l];
  end

endmodule
