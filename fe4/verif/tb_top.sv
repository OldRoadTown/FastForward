// =============================================================================
// tb_top - self-checking testbench for the fast_forward ff top
//
// Checks:
//  1. FEIN protocol : each packet issued exactly once, correct data/lat;
//                     dependent packets carry dp_vld + dp_data == forwarded
//                     result of target, and are issued strictly AFTER the
//                     target's result appeared on FEOUT.
//  2. FEOUT schedule: results appear exactly lat+1 cycles after FEIN, no
//                     output collisions (also checked inside fe_model).
//  3. PKTOUT        : strict rotating-lane in-order delivery of the golden
//                     forwarded data.
//  4. BKPR          : honored by the generator (no input while asserted).
//
// Plusargs: +NPKT=<n> +LOADPCT=<0..100> +SEED=<n>
// =============================================================================
`timescale 1ns/1ps

`ifndef REG_FEIN_V
`define REG_FEIN_V 0
`endif
`ifndef WAKE_BYPASS_V
// E069 default: registered latency1..3 prewake, no live wake-to-picker tag path.
`define WAKE_BYPASS_V 1
`endif
`ifndef DUAL_STEAL_V
`define DUAL_STEAL_V 0
`endif

module tb_top;

  int NPKT    = 2000;
  int LOADPCT = 100;
  int SEED    = 1;
  int DEPHEAVY = 0;

  // --------------------------------------------------------------------------
  // clock / reset
  // --------------------------------------------------------------------------
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #0.5 clk = ~clk;

  int cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  // --------------------------------------------------------------------------
  // DUT wires
  // --------------------------------------------------------------------------
  logic         li_v [4];
  logic [127:0] li_d [4];
  logic [4:0]   li_c [4];

  logic         lo_v [4];
  logic [127:0] lo_d [4];

  logic         bkpr;

  logic         fw_v   [4];
  logic [127:0] fw_d   [4];
  logic [1:0]   fw_l   [4];
  logic         fw_dpv [4];
  logic [127:0] fw_dpd [4];

  logic         fe_v [4];
  logic [127:0] fe_d [4];

  ff #(.REG_FEIN(`REG_FEIN_V), .WAKE_BYPASS(`WAKE_BYPASS_V),
       .DUAL_STEAL(`DUAL_STEAL_V)) u_ff (
    .clk(clk), .rst_n(rst_n),
    .lane0_pkt_in_vld(li_v[0]), .lane0_pkt_in_data(li_d[0]), .lane0_pkt_in_ctrl(li_c[0]),
    .lane1_pkt_in_vld(li_v[1]), .lane1_pkt_in_data(li_d[1]), .lane1_pkt_in_ctrl(li_c[1]),
    .lane2_pkt_in_vld(li_v[2]), .lane2_pkt_in_data(li_d[2]), .lane2_pkt_in_ctrl(li_c[2]),
    .lane3_pkt_in_vld(li_v[3]), .lane3_pkt_in_data(li_d[3]), .lane3_pkt_in_ctrl(li_c[3]),
    .lane0_pkt_out_vld(lo_v[0]), .lane0_pkt_out_data(lo_d[0]),
    .lane1_pkt_out_vld(lo_v[1]), .lane1_pkt_out_data(lo_d[1]),
    .lane2_pkt_out_vld(lo_v[2]), .lane2_pkt_out_data(lo_d[2]),
    .lane3_pkt_out_vld(lo_v[3]), .lane3_pkt_out_data(lo_d[3]),
    .pkt_in_bkpr(bkpr)
  );

  // The production top integrates the four FEs.  Keep the detailed protocol
  // monitors by tapping the internal FEIN/FEOUT nets hierarchically in TB only.
  generate
    for (genvar f = 0; f < 4; f++) begin : g_fe_tap
      assign fw_v[f]   = u_ff.fwd_v[f];
      assign fw_d[f]   = u_ff.fwd_d_f[f*128 +: 128];
      assign fw_l[f]   = u_ff.fwd_l_f[f*2 +: 2];
      assign fw_dpv[f] = u_ff.fwd_dpv[f];
      assign fw_dpd[f] = u_ff.fwd_dpd_f[f*128 +: 128];
    end
  endgenerate
  assign fe_v[0] = u_ff.fwded0_pkt_data_vld;
  assign fe_v[1] = u_ff.fwded1_pkt_data_vld;
  assign fe_v[2] = u_ff.fwded2_pkt_data_vld;
  assign fe_v[3] = u_ff.fwded3_pkt_data_vld;
  assign fe_d[0] = u_ff.fwded0_pkt_data;
  assign fe_d[1] = u_ff.fwded1_pkt_data;
  assign fe_d[2] = u_ff.fwded2_pkt_data;
  assign fe_d[3] = u_ff.fwded3_pkt_data;

  // --------------------------------------------------------------------------
  // golden model (must match fe_model.fe_xform)
  // --------------------------------------------------------------------------
  function automatic logic [127:0] fe_xform(input logic [127:0] d,
                                            input logic         dpv,
                                            input logic [127:0] dpd);
    return {d[126:0], d[127]} ^ (dpv ? dpd : 128'h0)
           ^ 128'h5A5A_A5A5_3C3C_C3C3_0F0F_F0F0_5555_AAAA;
  endfunction

  localparam int MAXP = 1 << 20;
  logic [127:0] gen_data [];
  logic [127:0] gold     [];
  byte          gen_dep  [];
  byte          gen_lat  [];
  int           issue_cyc[];
  bit           issued_f [];
  int           deliv_cyc[];
  bit           deliv_f  [];

  // per-FE expected output schedule
  int exp_cyc [4][$];
  int exp_seq [4][$];

  int sent      = 0;
  int stat_cycles = 0;
  int stat_bkpr   = 0;
  int stat_occ    = 0;
  int stat_win    = 0;
  int rd_seq    = 0;
  int errors    = 0;
  int first_in  = -1;
  int last_out  = -1;
  int last_prog = 0;

  task automatic chk(input bit ok, input string msg);
    if (!ok) begin
      errors++;
      $error("[TB] %s @cycle %0d", msg, cycle);
      if (errors > 50) begin
        $display("[TB] too many errors, aborting");
        $finish;
      end
    end
  endtask

  // --------------------------------------------------------------------------
  // main negedge process: monitors first, then drive
  // --------------------------------------------------------------------------
  always @(negedge clk) begin
    if (rst_n) begin
      // ---------------- FEOUT monitor ----------------
      // mixed-latency streams exit a single FE out of insertion order:
      // match the scheduled entry by its due cycle
      for (int f = 0; f < 4; f++) begin
        int hit;
        hit = -1;
        for (int q = 0; q < exp_cyc[f].size(); q++)
          if (exp_cyc[f][q] == cycle) hit = q;
        if (fe_v[f]) begin
          chk(hit >= 0, $sformatf("FEOUT%0d: unexpected result", f));
          if (hit >= 0) begin
            int s;
            s = exp_seq[f][hit];
            chk(fe_d[f] == gold[s],
                $sformatf("FEOUT%0d: seq %0d result data mismatch", f, s));
            deliv_f[s]   = 1'b1;
            deliv_cyc[s] = cycle;
            exp_cyc[f].delete(hit);
            exp_seq[f].delete(hit);
          end
        end else begin
          chk(hit < 0, $sformatf("FEOUT%0d: missing result (seq %0d)", f,
                                 (hit >= 0) ? exp_seq[f][hit] : -1));
        end
      end

      // ---------------- FEIN monitor ----------------
      for (int f = 0; f < 4; f++) begin
        if (fw_v[f]) begin
          int s;
          s = int'(fw_d[f][15:0]);
          chk(s >= 0 && s < sent, $sformatf("FEIN%0d: unknown seq %0d", f, s));
          if (s >= 0 && s < sent) begin
            chk(!issued_f[s], $sformatf("FEIN%0d: seq %0d issued twice", f, s));
            issued_f[s]  = 1'b1;
            issue_cyc[s] = cycle;
            chk(fw_d[f] == gen_data[s],
                $sformatf("FEIN%0d: seq %0d data mismatch", f, s));
            chk(fw_l[f] == gen_lat[s][1:0],
                $sformatf("FEIN%0d: seq %0d lat mismatch exp %0d got %0d",
                          f, s, gen_lat[s], fw_l[f]));
            if (gen_dep[s] != 0) begin
              int t;
              t = s - int'(gen_dep[s]);
              chk(fw_dpv[f], $sformatf("FEIN%0d: seq %0d missing dp_vld", f, s));
              chk(deliv_f[t],
                  $sformatf("FEIN%0d: seq %0d issued before target %0d delivered", f, s, t));
              if (deliv_f[t]) begin
                chk(deliv_cyc[t] <= cycle,
                    $sformatf("FEIN%0d: seq %0d issued before target %0d delivery", f, s, t));
                chk(fw_dpd[f] == gold[t],
                    $sformatf("FEIN%0d: seq %0d dp_data mismatch", f, s));
              end
            end else begin
              chk(!fw_dpv[f], $sformatf("FEIN%0d: seq %0d spurious dp_vld", f, s));
            end
            for (int q = 0; q < exp_cyc[f].size(); q++)
              chk(exp_cyc[f][q] != cycle + int'(fw_l[f]) + 1,
                  $sformatf("FEIN%0d: output collision booked (seq %0d)", f, s));
            exp_cyc[f].push_back(cycle + int'(fw_l[f]) + 1);
            exp_seq[f].push_back(s);
          end
        end
      end

      // ---------------- PKTOUT monitor ----------------
      begin
        int popped;
        int nv;
        popped = 0;
        nv     = (lo_v[0] ? 1 : 0) + (lo_v[1] ? 1 : 0)
               + (lo_v[2] ? 1 : 0) + (lo_v[3] ? 1 : 0);
        for (int k = 0; k < 4; k++) begin
          int l;
          l = rd_seq % 4;
          if (lo_v[l] && popped < nv) begin
            chk(rd_seq < sent, $sformatf("PKTOUT: seq %0d beyond sent", rd_seq));
            if (rd_seq < sent) begin
              if (lo_d[l] != gold[rd_seq]) begin
                for (int s = ((rd_seq > 64) ? rd_seq - 64 : 0);
                     s < ((rd_seq + 64 < sent) ? rd_seq + 64 : sent); s++) begin
                  if (lo_d[l] == gold[s])
                    $display("[TB-DBG] got gold of seq %0d instead (dep=%0d lat=%0d, iss@%0d dlv@%0d)",
                             s, gen_dep[s], gen_lat[s], issue_cyc[s], deliv_cyc[s]);
                  if (lo_d[l] == gen_data[s])
                    $display("[TB-DBG] got RAW input data of seq %0d", s);
                end
                $display("[TB-DBG] rd_seq=%0d dep=%0d lat=%0d iss@%0d dlv@%0d entry=%0d",
                         rd_seq, gen_dep[rd_seq], gen_lat[rd_seq],
                         issue_cyc[rd_seq], deliv_cyc[rd_seq], rd_seq % 32);
              end
              chk(lo_d[l] == gold[rd_seq],
                  $sformatf("PKTOUT lane%0d: seq %0d data mismatch", l, rd_seq));
            end
            rd_seq++;
            popped++;
            last_prog = cycle;
            if (rd_seq == NPKT) last_out = cycle;
          end else begin
            break;
          end
        end
        chk(nv == popped,
            $sformatf("PKTOUT: non-contiguous lane valids (nv=%0d popped=%0d rd=%0d, v=%b%b%b%b)",
                      nv, popped, rd_seq, lo_v[3], lo_v[2], lo_v[1], lo_v[0]));
      end

      // ---------------- generator ----------------
      for (int l = 0; l < 4; l++) li_v[l] = 1'b0;
      if (!bkpr && sent < NPKT) begin
        for (int l = 0; l < 4; l++) begin
          if (sent < NPKT && int'($urandom_range(99)) < LOADPCT) begin
            int d, r;
            if (DEPHEAVY != 0) begin
              d = int'($urandom_range(7));      // stress: 7/8 dependent
            end else begin
              r = int'($urandom_range(20));
              d = (r < 14) ? 0 : (r - 13);     // official 14:1:...:1
            end
            if (d > sent) d = 0;      // no invalid dependency at stream head
            gen_dep[sent]  = byte'(d);
            gen_lat[sent]  = byte'($urandom_range(3));
            gen_data[sent] = {$urandom(), $urandom(), $urandom(),
                              16'($urandom()), 16'(sent)};
            gold[sent]     = fe_xform(gen_data[sent], d != 0,
                                      (d != 0) ? gold[sent - d] : 128'h0);
            li_v[l] = 1'b1;
            li_d[l] = gen_data[sent];
            li_c[l] = {3'(d), 2'(gen_lat[sent])};
            if (first_in < 0) first_in = cycle;
            last_prog = cycle;
            sent++;
          end
        end
      end

      // ---------------- stats ----------------
      if (first_in >= 0 && rd_seq < NPKT) begin
        stat_cycles++;
        if (bkpr) stat_bkpr++;
        // E068 applies same-edge retirement/issue credit, so sample the
        // actual qualified causes rather than the pre-credit raw distances.
        if (u_ff.u_rob.occ_over) stat_occ++;
        if (u_ff.u_rob.win_over) stat_win++;
      end

      // ---------------- end / watchdog ----------------
      if (rd_seq >= NPKT) begin
        bit leftover;
        leftover = 0;
        for (int f = 0; f < 4; f++) if (exp_cyc[f].size() != 0) leftover = 1;
        chk(!leftover, "FE queues not empty at end of test");
        repeat_done();
      end
      if (cycle - last_prog > 3000) begin
        errors++;
        $error("[TB] WATCHDOG: no progress. sent=%0d rd_seq=%0d bkpr=%b @cycle %0d",
               sent, rd_seq, bkpr, cycle);
        repeat_done();
      end
    end
  end

  task automatic repeat_done();
    int cyc_total;
    cyc_total = last_out - first_in + 1;
    $display("==================================================================");
    $display(" NPKT=%0d LOADPCT=%0d SEED=%0d", NPKT, LOADPCT, SEED);
    $display(" cycles (first-in .. last-out) = %0d", cyc_total);
    if (cyc_total > 0)
      $display(" throughput = %.3f pkt/cycle", real'(NPKT) / real'(cyc_total));
    $display(" bkpr: %0d / %0d cycles (occ-cause %0d, win-cause %0d)",
             stat_bkpr, stat_cycles, stat_occ, stat_win);
    if (errors == 0) $display(" TEST PASSED");
    else             $display(" TEST FAILED with %0d errors", errors);
    $display("==================================================================");
    $finish;
  endtask

  // --------------------------------------------------------------------------
  initial begin
    void'($value$plusargs("NPKT=%d", NPKT));
    void'($value$plusargs("LOADPCT=%d", LOADPCT));
    void'($value$plusargs("SEED=%d", SEED));
    void'($value$plusargs("DEPHEAVY=%d", DEPHEAVY));
    if (NPKT > MAXP) NPKT = MAXP;
    void'($urandom(SEED));

    gen_data  = new[NPKT];
    gold      = new[NPKT];
    gen_dep   = new[NPKT];
    gen_lat   = new[NPKT];
    issue_cyc = new[NPKT];
    issued_f  = new[NPKT];
    deliv_cyc = new[NPKT];
    deliv_f   = new[NPKT];

    for (int l = 0; l < 4; l++) begin
      li_v[l] = 1'b0;
      li_d[l] = '0;
      li_c[l] = '0;
    end

    rst_n = 1'b0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
  end

endmodule
