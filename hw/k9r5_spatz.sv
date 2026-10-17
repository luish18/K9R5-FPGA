// K9R5 Spatz subsystem: the Spatz cluster in its own clock domain, attached to
// Cheshire's external AXI ports through clock domain crossings. The cluster
// wrapper (generated from hw/spatz/k9r5.spatz_cluster.hjson) contains the
// Spatz-side halves of both crossings; this module adds the Cheshire-side ones,
// as Carfield's cheshire_wrap does.
//
// Wake-up and interrupts are left to software for now: CVA6 starts the cores
// through the cluster peripheral registers (CL_CLINT_SET), so the cluster's
// interrupt and debug inputs are tied off.

`include "cheshire/typedef.svh"

module k9r5_spatz import cheshire_pkg::*; #(
  parameter cheshire_cfg_t Cfg = '0
) (
  // Cheshire's clock domain
  input  logic clk_i,
  input  logic rst_ni,
  input  logic test_mode_i,
  // Spatz's clock domain; rst_spatz_ni is synchronized internally
  input  logic clk_spatz_i,
  input  logic rst_spatz_ni,
  // Cheshire's external AXI slave port (SoC -> cluster)
  input  logic [$bits(spatz_cluster_pkg::spatz_axi_in_req_t)-1:0]   axi_slv_req_i,
  output logic [$bits(spatz_cluster_pkg::spatz_axi_in_resp_t)-1:0]  axi_slv_rsp_o,
  // Cheshire's external AXI master port (cluster -> SoC)
  output logic [$bits(spatz_cluster_pkg::spatz_axi_out_req_t)-1:0]  axi_mst_req_o,
  input  logic [$bits(spatz_cluster_pkg::spatz_axi_out_resp_t)-1:0] axi_mst_rsp_i,
  // Cluster busy indication (SPATZ_STATUS register), e.g. for an LED
  output logic cluster_probe_o
);

  import spatz_cluster_pkg::*;

  // Cheshire's AXI types for this configuration: the cluster's input uses the
  // slave-side IDs, its output the master-side IDs.
  `CHESHIRE_TYPEDEF_ALL(, Cfg)

  // The cluster was generated for Cheshire's widths (k9r5.spatz_cluster.hjson)
  if ($bits(axi_slv_req_t) != $bits(spatz_axi_in_req_t) ||
      $bits(axi_mst_req_t) != $bits(spatz_axi_out_req_t))
    $error("Spatz cluster AXI widths do not match Cheshire's: regenerate it with matching ",
           "id_width_in/id_width_out/user_width (make k9r5-spatz-gen)");

  axi_slv_req_t slv_req;
  axi_slv_rsp_t slv_rsp;
  axi_mst_req_t mst_req;
  axi_mst_rsp_t mst_rsp;

  assign slv_req       = axi_slv_req_i;
  assign axi_slv_rsp_o = slv_rsp;
  assign axi_mst_req_o = mst_req;
  assign mst_rsp       = axi_mst_rsp_i;

  ///////////
  // Reset //
  ///////////

  logic rst_spatz_n;

  rstgen i_rstgen_spatz (
    .clk_i       ( clk_spatz_i  ),
    .rst_ni      ( rst_spatz_ni ),
    .test_mode_i ( test_mode_i  ),
    .rst_no      ( rst_spatz_n  ),
    .init_no     ( )
  );

  ////////////////////////////////
  // Clock domain crossings     //
  ////////////////////////////////

  // SoC -> cluster: source half in Cheshire's domain
  axi_slv_aw_chan_t [2**SpatzLogDepth-1:0] async_in_aw_data;
  axi_slv_w_chan_t  [2**SpatzLogDepth-1:0] async_in_w_data;
  axi_slv_b_chan_t  [2**SpatzLogDepth-1:0] async_in_b_data;
  axi_slv_ar_chan_t [2**SpatzLogDepth-1:0] async_in_ar_data;
  axi_slv_r_chan_t  [2**SpatzLogDepth-1:0] async_in_r_data;
  logic [SpatzLogDepth:0] async_in_aw_wptr, async_in_aw_rptr;
  logic [SpatzLogDepth:0] async_in_w_wptr,  async_in_w_rptr;
  logic [SpatzLogDepth:0] async_in_b_wptr,  async_in_b_rptr;
  logic [SpatzLogDepth:0] async_in_ar_wptr, async_in_ar_rptr;
  logic [SpatzLogDepth:0] async_in_r_wptr,  async_in_r_rptr;

  axi_cdc_src #(
    .LogDepth   ( SpatzLogDepth      ),
    .SyncStages ( SpatzCdcSyncStages ),
    .aw_chan_t  ( axi_slv_aw_chan_t  ),
    .w_chan_t   ( axi_slv_w_chan_t   ),
    .b_chan_t   ( axi_slv_b_chan_t   ),
    .ar_chan_t  ( axi_slv_ar_chan_t  ),
    .r_chan_t   ( axi_slv_r_chan_t   ),
    .axi_req_t  ( axi_slv_req_t      ),
    .axi_resp_t ( axi_slv_rsp_t      )
  ) i_cdc_src_soc_to_spatz (
    .src_clk_i                   ( clk_i  ),
    .src_rst_ni                  ( rst_ni ),
    .src_req_i                   ( slv_req ),
    .src_resp_o                  ( slv_rsp ),
    .async_data_master_aw_data_o ( async_in_aw_data ),
    .async_data_master_aw_wptr_o ( async_in_aw_wptr ),
    .async_data_master_aw_rptr_i ( async_in_aw_rptr ),
    .async_data_master_w_data_o  ( async_in_w_data  ),
    .async_data_master_w_wptr_o  ( async_in_w_wptr  ),
    .async_data_master_w_rptr_i  ( async_in_w_rptr  ),
    .async_data_master_b_data_i  ( async_in_b_data  ),
    .async_data_master_b_wptr_i  ( async_in_b_wptr  ),
    .async_data_master_b_rptr_o  ( async_in_b_rptr  ),
    .async_data_master_ar_data_o ( async_in_ar_data ),
    .async_data_master_ar_wptr_o ( async_in_ar_wptr ),
    .async_data_master_ar_rptr_i ( async_in_ar_rptr ),
    .async_data_master_r_data_i  ( async_in_r_data  ),
    .async_data_master_r_wptr_i  ( async_in_r_wptr  ),
    .async_data_master_r_rptr_o  ( async_in_r_rptr  )
  );

  // Cluster -> SoC: destination half in Cheshire's domain
  axi_mst_aw_chan_t [2**SpatzLogDepth-1:0] async_out_aw_data;
  axi_mst_w_chan_t  [2**SpatzLogDepth-1:0] async_out_w_data;
  axi_mst_b_chan_t  [2**SpatzLogDepth-1:0] async_out_b_data;
  axi_mst_ar_chan_t [2**SpatzLogDepth-1:0] async_out_ar_data;
  axi_mst_r_chan_t  [2**SpatzLogDepth-1:0] async_out_r_data;
  logic [SpatzLogDepth:0] async_out_aw_wptr, async_out_aw_rptr;
  logic [SpatzLogDepth:0] async_out_w_wptr,  async_out_w_rptr;
  logic [SpatzLogDepth:0] async_out_b_wptr,  async_out_b_rptr;
  logic [SpatzLogDepth:0] async_out_ar_wptr, async_out_ar_rptr;
  logic [SpatzLogDepth:0] async_out_r_wptr,  async_out_r_rptr;

  axi_cdc_dst #(
    .LogDepth   ( SpatzLogDepth      ),
    .SyncStages ( SpatzCdcSyncStages ),
    .aw_chan_t  ( axi_mst_aw_chan_t  ),
    .w_chan_t   ( axi_mst_w_chan_t   ),
    .b_chan_t   ( axi_mst_b_chan_t   ),
    .ar_chan_t  ( axi_mst_ar_chan_t  ),
    .r_chan_t   ( axi_mst_r_chan_t   ),
    .axi_req_t  ( axi_mst_req_t      ),
    .axi_resp_t ( axi_mst_rsp_t      )
  ) i_cdc_dst_spatz_to_soc (
    .async_data_slave_aw_data_i ( async_out_aw_data ),
    .async_data_slave_aw_wptr_i ( async_out_aw_wptr ),
    .async_data_slave_aw_rptr_o ( async_out_aw_rptr ),
    .async_data_slave_w_data_i  ( async_out_w_data  ),
    .async_data_slave_w_wptr_i  ( async_out_w_wptr  ),
    .async_data_slave_w_rptr_o  ( async_out_w_rptr  ),
    .async_data_slave_b_data_o  ( async_out_b_data  ),
    .async_data_slave_b_wptr_o  ( async_out_b_wptr  ),
    .async_data_slave_b_rptr_i  ( async_out_b_rptr  ),
    .async_data_slave_ar_data_i ( async_out_ar_data ),
    .async_data_slave_ar_wptr_i ( async_out_ar_wptr ),
    .async_data_slave_ar_rptr_o ( async_out_ar_rptr ),
    .async_data_slave_r_data_o  ( async_out_r_data  ),
    .async_data_slave_r_wptr_o  ( async_out_r_wptr  ),
    .async_data_slave_r_rptr_i  ( async_out_r_rptr  ),
    .dst_clk_i                  ( clk_i   ),
    .dst_rst_ni                 ( rst_ni  ),
    .dst_req_o                  ( mst_req ),
    .dst_resp_i                 ( mst_rsp )
  );

  ///////////////////
  // Spatz cluster //
  ///////////////////

  spatz_cluster_wrapper i_spatz_cluster (
    .clk_i                   ( clk_spatz_i ),
    .rst_ni                  ( rst_spatz_n ),
    .pwr_on_rst_ni           ( rst_spatz_n ),
    .debug_req_i             ( '0 ),
    .meip_i                  ( '0 ),
    .mtip_i                  ( '0 ),
    .msip_i                  ( '0 ),
    .cluster_probe_o         ( cluster_probe_o ),
    // Cluster -> SoC
    .async_axi_out_aw_data_o ( async_out_aw_data ),
    .async_axi_out_aw_wptr_o ( async_out_aw_wptr ),
    .async_axi_out_aw_rptr_i ( async_out_aw_rptr ),
    .async_axi_out_w_data_o  ( async_out_w_data  ),
    .async_axi_out_w_wptr_o  ( async_out_w_wptr  ),
    .async_axi_out_w_rptr_i  ( async_out_w_rptr  ),
    .async_axi_out_b_data_i  ( async_out_b_data  ),
    .async_axi_out_b_wptr_i  ( async_out_b_wptr  ),
    .async_axi_out_b_rptr_o  ( async_out_b_rptr  ),
    .async_axi_out_ar_data_o ( async_out_ar_data ),
    .async_axi_out_ar_wptr_o ( async_out_ar_wptr ),
    .async_axi_out_ar_rptr_i ( async_out_ar_rptr ),
    .async_axi_out_r_data_i  ( async_out_r_data  ),
    .async_axi_out_r_wptr_i  ( async_out_r_wptr  ),
    .async_axi_out_r_rptr_o  ( async_out_r_rptr  ),
    // SoC -> cluster
    .async_axi_in_ar_data_i  ( async_in_ar_data ),
    .async_axi_in_ar_wptr_i  ( async_in_ar_wptr ),
    .async_axi_in_ar_rptr_o  ( async_in_ar_rptr ),
    .async_axi_in_aw_data_i  ( async_in_aw_data ),
    .async_axi_in_aw_wptr_i  ( async_in_aw_wptr ),
    .async_axi_in_aw_rptr_o  ( async_in_aw_rptr ),
    .async_axi_in_b_data_o   ( async_in_b_data  ),
    .async_axi_in_b_wptr_o   ( async_in_b_wptr  ),
    .async_axi_in_b_rptr_i   ( async_in_b_rptr  ),
    .async_axi_in_r_data_o   ( async_in_r_data  ),
    .async_axi_in_r_wptr_o   ( async_in_r_wptr  ),
    .async_axi_in_r_rptr_i   ( async_in_r_rptr  ),
    .async_axi_in_w_data_i   ( async_in_w_data  ),
    .async_axi_in_w_wptr_i   ( async_in_w_wptr  ),
    .async_axi_in_w_rptr_o   ( async_in_w_rptr  )
  );

endmodule
