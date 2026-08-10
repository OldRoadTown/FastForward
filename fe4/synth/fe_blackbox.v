// Local synthesis proxy only. Production integration replaces this black box
// with the official forwarding engine implementation.
(* blackbox *)
module FE (
  input  wire         clk,
  input  wire         rst_n,
  input  wire         fwd_pkt_data_vld,
  input  wire [127:0] fwd_pkt_data,
  input  wire [1:0]   fwd_pkt_lat,
  input  wire         fwd_pkt_dp_vld,
  input  wire [127:0] fwd_pkt_dp_data,
  output wire         fwded_pkt_data_vld,
  output wire [127:0] fwded_pkt_data
);
endmodule
