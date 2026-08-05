// =============================================================================
// ff_issue - I1 issue stage (4-FE work-stealing variant)
//
// RTL revision : 4FE-rob-depth-v34
// Experiment   : ROB-R48 score candidate
// Based on     : E021-N1 / 4FE-safe-v11
// Changes      : limit hierarchical reads to the implemented ROB banks
//
// Reads packet data / dependency data from the ROB, drives FEIN with the
// packet's true latency (dynamic because of stealing). dp_data is bypassed
// from the FEOUT bus when the target's result arrives in this very cycle
// (WAKE_BYPASS pre-wake support).  With WAKE_BYPASS=0, issue occurs only after
// the target result has been stored in the ROB, so that live bypass cone is
// compiled out without adding a pipeline cycle.
// REG_FEIN=1 inserts an output register stage (timing fallback); the tag
// pipe (issue_v/issue_idx) is always fed FEIN-cycle aligned.
// =============================================================================
module ff_issue #(
  parameter D        = 48,
  parameter AW       = 6,
  parameter NFE      = 4,
  parameter REG_FEIN = 0,
  parameter WAKE_BYPASS = 0
)(
  input  wire                    clk,
  input  wire                    rst_n,
  // picks (I0 registered)
  input  wire [NFE-1:0]          pk_v_q,
  input  wire [NFE*AW-1:0]       pk_idx_f,
  input  wire [NFE*AW-1:0]       pk_tgt_f,
  input  wire [NFE*2-1:0]        pk_lat_f,
  input  wire [NFE*8-1:0]        pk_bank_oh_f,
  input  wire [NFE*8-1:0]        pk_local_oh_f,
  // ROB read view
  input  wire [D*128-1:0]        rob_data_f,
  input  wire [D*2-1:0]          rob_src_f,     // FE each entry was issued to
  input  wire [D-1:0]            rob_isdep,
  // same-cycle result bypass
  input  wire [D-1:0]            res_now,
  input  wire [NFE*128-1:0]      fe_od_f,
  // FEIN
  output wire [NFE-1:0]          fwd_v,
  output wire [NFE*128-1:0]      fwd_d_f,
  output wire [NFE*2-1:0]        fwd_l_f,       // dynamic lat (stealing)
  output wire [NFE-1:0]          fwd_dpv,
  output wire [NFE*128-1:0]      fwd_dpd_f,
  // FEIN-cycle-aligned issue view for the tag tracker
  output wire [NFE-1:0]          issue_v,
  output wire [NFE*AW-1:0]       issue_idx_f,
  output wire [NFE*2-1:0]        issue_lat_f
);

  localparam NBANK = D / 8;

  // unpack
  wire [127:0]  rob_data [0:D-1];
  wire [1:0]    rob_src  [0:D-1];
  wire [127:0]  fe_od    [0:NFE-1];
  wire [AW-1:0] pk_idx   [0:NFE-1];
  wire [AW-1:0] pk_tgt   [0:NFE-1];
  wire [1:0]    pk_lat   [0:NFE-1];
  wire [7:0]    pk_bank_oh [0:NFE-1];
  wire [7:0]    pk_local_oh [0:NFE-1];
  genvar gi;
  generate
    for (gi = 0; gi < D; gi = gi + 1) begin : g_ur
      assign rob_data[gi] = rob_data_f[gi*128 +: 128];
      assign rob_src[gi]  = rob_src_f[gi*2 +: 2];
    end
    for (gi = 0; gi < NFE; gi = gi + 1) begin : g_uo
      assign fe_od[gi]  = fe_od_f[gi*128 +: 128];
      assign pk_idx[gi] = pk_idx_f[gi*AW +: AW];
      assign pk_tgt[gi] = pk_tgt_f[gi*AW +: AW];
      assign pk_lat[gi] = pk_lat_f[gi*2 +: 2];
      assign pk_bank_oh[gi] = pk_bank_oh_f[gi*8 +: 8];
      assign pk_local_oh[gi] = pk_local_oh_f[gi*8 +: 8];
    end
  endgenerate

  wire         fein_v   [0:NFE-1];
  wire [127:0] fein_d   [0:NFE-1];
  wire         fein_dpv [0:NFE-1];
  wire [127:0] fein_dpd [0:NFE-1];

  genvar gf, gb;
  generate
    for (gf = 0; gf < NFE; gf = gf + 1) begin : g_iss
      wire [AW-1:0] ridx = pk_idx[gf];
      wire [127:0] bank_data [0:7];
      for (gb = 0; gb < 8; gb = gb + 1) begin : g_bank_read
        if (gb < NBANK) begin : g_valid_bank
          assign bank_data[gb] =
            (rob_data[gb*8+0] & {128{pk_local_oh[gf][0]}})
          | (rob_data[gb*8+1] & {128{pk_local_oh[gf][1]}})
          | (rob_data[gb*8+2] & {128{pk_local_oh[gf][2]}})
          | (rob_data[gb*8+3] & {128{pk_local_oh[gf][3]}})
          | (rob_data[gb*8+4] & {128{pk_local_oh[gf][4]}})
          | (rob_data[gb*8+5] & {128{pk_local_oh[gf][5]}})
          | (rob_data[gb*8+6] & {128{pk_local_oh[gf][6]}})
          | (rob_data[gb*8+7] & {128{pk_local_oh[gf][7]}});
        end else begin : g_unused_bank
          assign bank_data[gb] = 128'b0;
        end
      end
      wire [127:0] packet_data =
          (bank_data[0] & {128{pk_bank_oh[gf][0]}})
        | (bank_data[1] & {128{pk_bank_oh[gf][1]}})
        | (bank_data[2] & {128{pk_bank_oh[gf][2]}})
        | (bank_data[3] & {128{pk_bank_oh[gf][3]}})
        | (bank_data[4] & {128{pk_bank_oh[gf][4]}})
        | (bank_data[5] & {128{pk_bank_oh[gf][5]}})
        | (bank_data[6] & {128{pk_bank_oh[gf][6]}})
        | (bank_data[7] & {128{pk_bank_oh[gf][7]}});
      // pk_tgt was read and registered beside pk_idx in I0.  The I1 FE-input
      // path therefore contains only the target-data read, not two cascaded
      // full-ROB muxes (packet->target followed by target->data).
      wire [AW-1:0] tgt  = pk_tgt[gf];
      assign fein_v[gf]   = pk_v_q[gf];
      assign fein_d[gf]   = packet_data;
      assign fein_dpv[gf] = rob_isdep[ridx];
      if (WAKE_BYPASS == 0) begin : g_stored_dp
        // Without same-cycle wake-to-pick bypass, the target result is written
        // to rob_data one edge before this packet reaches issue.  Reading the
        // retained copy is therefore exact and removes res_now/rob_src/FEOUT
        // selection from the safe-profile FE input timing path.
        assign fein_dpd[gf] = rob_data[tgt];
      end else begin : g_live_dp
        // Full-throughput profile: a pre-woken packet may enter the FE in the
        // same cycle as its target result and must consume the live FEOUT bus.
        assign fein_dpd[gf] = res_now[tgt] ? fe_od[rob_src[tgt]]
                                           : rob_data[tgt];
      end
    end
  endgenerate

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
            rl_q[rf]   <= pk_lat[rf];
            rdpv_q[rf] <= fein_dpv[rf];
            rdpd_q[rf] <= fein_dpd[rf];
            ridx_q[rf] <= pk_idx[rf];
          end
        end
      end
      for (gf = 0; gf < NFE; gf = gf + 1) begin : g_ro
        assign fwd_v[gf]                = rv_q[gf];
        assign fwd_d_f[gf*128 +: 128]   = rd_q[gf];
        assign fwd_l_f[gf*2 +: 2]       = rl_q[gf];
        assign fwd_dpv[gf]              = rdpv_q[gf];
        assign fwd_dpd_f[gf*128 +: 128] = rdpd_q[gf];
        assign issue_v[gf]              = rv_q[gf];
        assign issue_idx_f[gf*AW +: AW] = ridx_q[gf];
        assign issue_lat_f[gf*2 +: 2]   = rl_q[gf];
      end
    end else begin : g_combfe
      for (gf = 0; gf < NFE; gf = gf + 1) begin : g_co
        assign fwd_v[gf]                = fein_v[gf];
        assign fwd_d_f[gf*128 +: 128]   = fein_d[gf];
        assign fwd_l_f[gf*2 +: 2]       = pk_lat[gf];
        assign fwd_dpv[gf]              = fein_dpv[gf];
        assign fwd_dpd_f[gf*128 +: 128] = fein_dpd[gf];
        assign issue_v[gf]              = pk_v_q[gf];
        assign issue_idx_f[gf*AW +: AW] = pk_idx[gf];
        assign issue_lat_f[gf*2 +: 2]   = pk_lat[gf];
      end
    end
  endgenerate

endmodule
