// =============================================================================
// fe_model - behavioral stand-in for the black-box Forwarding Engine
//
//  * non-blocking pipeline, accepts one packet per cycle
//  * forwarding latency = lat field + 1 (1..4 cycles), carried per packet
//  * output collision (two packets maturing in the same cycle) is a DESIGN
//    error of the scheduler -> flagged with $error
//  * transform function is arbitrary (real FE is a black box); the TB golden
//    model uses the same function, so end-to-end data checking validates all
//    of the DUT's plumbing (data path, dp data path, ordering)
// =============================================================================
module fe_model (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         pkt_data_vld,
  input  logic [127:0] pkt_data,
  input  logic [1:0]   pkt_lat,
  input  logic         pkt_dp_vld,
  input  logic [127:0] pkt_dp_data,
  output logic         fwded_pkt_data_vld,
  output logic [127:0] fwded_pkt_data
);

  function automatic logic [127:0] fe_xform(input logic [127:0] d,
                                            input logic         dpv,
                                            input logic [127:0] dpd);
    logic [127:0] r;
    r = {d[126:0], d[127]} ^ (dpv ? dpd : 128'h0)
        ^ 128'h5A5A_A5A5_3C3C_C3C3_0F0F_F0F0_5555_AAAA;
    return r;
  endfunction

  // slot[k] = result due in k cycles (k = 1..4)
  logic         vq [5];
  logic [127:0] dq [5];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int k = 0; k <= 4; k++) vq[k] <= 1'b0;
    end else begin
      // shift down
      for (int k = 1; k <= 3; k++) begin
        vq[k] <= vq[k+1];
        dq[k] <= dq[k+1];
      end
      vq[4] <= 1'b0;
      if (pkt_data_vld) begin
        // collision: slot (lat+1) would already be occupied after the shift
        if ((pkt_lat <= 2'd2) ? vq[32'(pkt_lat) + 2] : 1'b0) begin
          $error("[fe_model %m] output collision: lat=%0d @%0t", pkt_lat + 1, $time);
        end
        vq[32'(pkt_lat) + 1] <= 1'b1;
        dq[32'(pkt_lat) + 1] <= fe_xform(pkt_data, pkt_dp_vld, pkt_dp_data);
      end
    end
  end

  assign fwded_pkt_data_vld = vq[1];
  assign fwded_pkt_data     = dq[1];

endmodule

// Production-interface wrapper used only by local verification.  The real
// integration flow supplies its own uppercase `FE` implementation with this
// same port contract; ff therefore needs no FEIN/FEOUT ports at its boundary.
module FE (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         fwd_pkt_data_vld,
  input  logic [127:0] fwd_pkt_data,
  input  logic [1:0]   fwd_pkt_lat,
  input  logic         fwd_pkt_dp_vld,
  input  logic [127:0] fwd_pkt_dp_data,
  output logic         fwded_pkt_data_vld,
  output logic [127:0] fwded_pkt_data
);

  fe_model u_model (
    .clk(clk),
    .rst_n(rst_n),
    .pkt_data_vld(fwd_pkt_data_vld),
    .pkt_data(fwd_pkt_data),
    .pkt_lat(fwd_pkt_lat),
    .pkt_dp_vld(fwd_pkt_dp_vld),
    .pkt_dp_data(fwd_pkt_dp_data),
    .fwded_pkt_data_vld(fwded_pkt_data_vld),
    .fwded_pkt_data(fwded_pkt_data)
  );

endmodule
