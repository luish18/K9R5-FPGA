// K9R5 Verilator testbench: the full K9R5 system (Cheshire with Ara and the
// Spatz cluster, k9r5_pkg::K9R5Cfg), driven by tb_k9r5_vlt.cpp.
//
// Replaces Cheshire's QuestaSim testbench (tb/fixture/vip_cheshire_soc), whose
// VIP relies on classes, timing controls and behavioral flash models. All
// timing lives in C++: it toggles the clocks and resets, preloads programs and
// decodes the UART. Only idle boot (boot mode 0) is supported:
// - DRAM is a sparse C++ memory behind DPI (k9r5_vlt_dram_*), which C++ also
//   preloads directly.
// - Everything else (e.g. the LLC SPM) is preloaded over the serial link, as
//   Cheshire's VIP does: C++ issues 64-bit memory requests to an AXI adapter
//   on a mirror serial link, which reaches the SoC like a second chip.
// - Exit codes and the CPU state for trap reports are read from the design
//   through hierarchical references.
// JTAG is held in reset; I2C and SPI have no devices attached.

`include "cheshire/typedef.svh"

module tb_k9r5_vlt import cheshire_pkg::*; (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic rtc_i,
  input  logic clk_spatz_i,
  // Serial link memory port (C++ preload and polling)
  input  logic        slink_mem_req_i,
  input  logic [63:0] slink_mem_addr_i,
  input  logic        slink_mem_we_i,
  input  logic [63:0] slink_mem_wdata_i,
  input  logic [ 7:0] slink_mem_be_i,
  output logic        slink_mem_gnt_o,
  output logic        slink_mem_rsp_valid_o,
  output logic [63:0] slink_mem_rsp_rdata_o,
  output logic        slink_mem_rsp_error_o,
  // UART line from the SoC, decoded in C++
  output logic        uart_tx_o,
  // Memory map, for C++
  output logic [63:0] dram_start_o,
  output logic [63:0] dram_end_o,
  output logic [63:0] llc_spm_cfg_addr_o,
  output logic [63:0] scratch_addr_o,
  // SCRATCH[2]: launch (bit 1, written by C++) and exit code (bit 0, by software)
  output logic [31:0] scratch2_o,
  // Hart 0 state, printed when a run ends
  output logic [63:0] pc_o,
  output logic [63:0] mcause_o,
  output logic [63:0] mepc_o,
  output logic [63:0] mtval_o
);

  localparam cheshire_cfg_t DutCfg = k9r5_pkg::K9R5Cfg;

  `CHESHIRE_TYPEDEF_ALL(, DutCfg)

  // The C++ preload and the exit-code check rely on these
  if (!DutCfg.SerialLink) $error("K9R5 Verilator testbench needs the serial link");
  if (DutCfg.AxiDataWidth != 64) $error("K9R5 Verilator testbench assumes 64-bit AXI data");

  assign dram_start_o       = DutCfg.LlcOutRegionStart;
  assign dram_end_o         = DutCfg.LlcOutRegionEnd;
  assign llc_spm_cfg_addr_o = DutCfg.LlcNotBypass ?
                              AmLlc + axi_llc_reg_pkg::AXI_LLC_CFG_SPM_LOW_OFFSET : '0;
  assign scratch_addr_o     = AmRegs + cheshire_reg_pkg::CHESHIRE_SCRATCH_0_OFFSET;

  ///////////
  //  DUT  //
  ///////////

  logic test_mode;
  assign test_mode = 1'b0;

  axi_llc_req_t axi_llc_mst_req;
  axi_llc_rsp_t axi_llc_mst_rsp;

  logic                 spih_sck_o, spih_sck_en;
  logic [SpihNumCs-1:0] spih_csb_o, spih_csb_en;
  logic [ 3:0]          spih_sd_o, spih_sd_en;

  logic [SlinkNumChan-1:0]                    slink_rcv_clk_i;
  logic [SlinkNumChan-1:0]                    slink_rcv_clk_o;
  logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_i;
  logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_o;

  axi_slv_req_t ext_slv_req;
  axi_slv_rsp_t ext_slv_rsp;
  axi_mst_req_t ext_mst_req;
  axi_mst_rsp_t ext_mst_rsp;

  // Spatz cluster on Cheshire's external AXI ports, in its own clock domain
  k9r5_spatz #(
    .Cfg ( DutCfg )
  ) i_spatz (
    .clk_i           ( clk_i       ),
    .rst_ni          ( rst_ni      ),
    .test_mode_i     ( test_mode   ),
    .clk_spatz_i     ( clk_spatz_i ),
    .rst_spatz_ni    ( rst_ni      ),
    .axi_slv_req_i   ( ext_slv_req ),
    .axi_slv_rsp_o   ( ext_slv_rsp ),
    .axi_mst_req_o   ( ext_mst_req ),
    .axi_mst_rsp_i   ( ext_mst_rsp ),
    .cluster_probe_o ( )
  );

  cheshire_soc #(
    .Cfg                ( DutCfg ),
    .ExtHartinfo        ( '0 ),
    .axi_ext_llc_req_t  ( axi_llc_req_t ),
    .axi_ext_llc_rsp_t  ( axi_llc_rsp_t ),
    .axi_ext_mst_req_t  ( axi_mst_req_t ),
    .axi_ext_mst_rsp_t  ( axi_mst_rsp_t ),
    .axi_ext_slv_req_t  ( axi_slv_req_t ),
    .axi_ext_slv_rsp_t  ( axi_slv_rsp_t ),
    .reg_ext_req_t      ( reg_req_t ),
    .reg_ext_rsp_t      ( reg_rsp_t )
  ) dut (
    .clk_i              ( clk_i     ),
    .rst_ni             ( rst_ni    ),
    .test_mode_i        ( test_mode ),
    .boot_mode_i        ( 2'b00     ),
    .rtc_i              ( rtc_i     ),
    .axi_llc_mst_req_o  ( axi_llc_mst_req ),
    .axi_llc_mst_rsp_i  ( axi_llc_mst_rsp ),
    .axi_ext_mst_req_i  ( ext_mst_req ),
    .axi_ext_mst_rsp_o  ( ext_mst_rsp ),
    .axi_ext_slv_req_o  ( ext_slv_req ),
    .axi_ext_slv_rsp_i  ( ext_slv_rsp ),
    .reg_ext_slv_req_o  ( ),
    .reg_ext_slv_rsp_i  ( '0 ),
    .intr_ext_i         ( '0 ),
    .intr_ext_o         ( ),
    .xeip_ext_o         ( ),
    .mtip_ext_o         ( ),
    .msip_ext_o         ( ),
    .dbg_active_o       ( ),
    .dbg_ext_req_o      ( ),
    .dbg_ext_unavail_i  ( '0 ),
    .jtag_tck_i         ( 1'b0 ),
    .jtag_trst_ni       ( 1'b0 ),
    .jtag_tms_i         ( 1'b0 ),
    .jtag_tdi_i         ( 1'b0 ),
    .jtag_tdo_o         ( ),
    .jtag_tdo_oe_o      ( ),
    .uart_tx_o          ( uart_tx_o ),
    .uart_rx_i          ( 1'b1 ),
    .uart_rts_no        ( ),
    .uart_dtr_no        ( ),
    .uart_cts_ni        ( 1'b0 ),
    .uart_dsr_ni        ( 1'b0 ),
    .uart_dcd_ni        ( 1'b0 ),
    .uart_rin_ni        ( 1'b0 ),
    .i2c_sda_o          ( ),
    .i2c_sda_i          ( 1'b1 ),
    .i2c_sda_en_o       ( ),
    .i2c_scl_o          ( ),
    .i2c_scl_i          ( 1'b1 ),
    .i2c_scl_en_o       ( ),
    .spih_sck_o         ( spih_sck_o  ),
    .spih_sck_en_o      ( spih_sck_en ),
    .spih_csb_o         ( spih_csb_o  ),
    .spih_csb_en_o      ( spih_csb_en ),
    .spih_sd_o          ( spih_sd_o   ),
    .spih_sd_en_o       ( spih_sd_en  ),
    .spih_sd_i          ( 4'hf ),
    .gpio_i             ( '0 ),
    .gpio_o             ( ),
    .gpio_en_o          ( ),
    .slink_rcv_clk_i    ( slink_rcv_clk_i ),
    .slink_rcv_clk_o    ( slink_rcv_clk_o ),
    .slink_i            ( slink_i ),
    .slink_o            ( slink_o ),
    .vga_hsync_o        ( ),
    .vga_vsync_o        ( ),
    .vga_red_o          ( ),
    .vga_green_o        ( ),
    .vga_blue_o         ( ),
    .usb_clk_i          ( 1'b0 ),
    .usb_rst_ni         ( 1'b1 ),
    .usb_dm_i           ( '0 ),
    .usb_dm_o           ( ),
    .usb_dm_oe_o        ( ),
    .usb_dp_i           ( '0 ),
    .usb_dp_o           ( ),
    .usb_dp_oe_o        ( )
  );

  // Hierarchical references: exit code and the CPU state for trap reports
  assign scratch2_o = dut.i_regs.scratch_2_qs;
  assign pc_o       = 64'(dut.gen_cva6_cores[0].i_core_cva6.pc_commit);
  assign mcause_o   = 64'(dut.gen_cva6_cores[0].i_core_cva6.csr_regfile_i.mcause_q);
  assign mepc_o     = 64'(dut.gen_cva6_cores[0].i_core_cva6.csr_regfile_i.mepc_q);
  assign mtval_o    = 64'(dut.gen_cva6_cores[0].i_core_cva6.csr_regfile_i.mtval_q);

  ////////////
  //  DRAM  //
  ////////////

  // AXI to memory requests (one read and one write port), served by a sparse
  // C++ memory with one cycle of latency. Addresses are absolute.
  import "DPI-C" function longint k9r5_vlt_dram_read(input longint addr);
  import "DPI-C" function void k9r5_vlt_dram_write(input longint addr, input longint data,
                                                   input byte strb);

  localparam int unsigned DramPorts = 2;

  logic  [DramPorts-1:0]                     dram_req, dram_we;
  addr_t [DramPorts-1:0]                     dram_addr;
  logic  [DramPorts-1:0][63:0]               dram_wdata, dram_rdata_q;
  logic  [DramPorts-1:0][ 7:0]               dram_strb;
  logic  [DramPorts-1:0]                     dram_rvalid_q;

  axi_to_mem_split #(
    .axi_req_t    ( axi_llc_req_t       ),
    .axi_resp_t   ( axi_llc_rsp_t       ),
    .AddrWidth    ( DutCfg.AddrWidth    ),
    .AxiDataWidth ( DutCfg.AxiDataWidth ),
    .IdWidth      ( $bits(axi_llc_id_t) ),
    .MemDataWidth ( DutCfg.AxiDataWidth ),
    .BufDepth     ( 1 ),
    .HideStrb     ( 1'b0 ),
    .OutFifoDepth ( 1 )
  ) i_dram_axi_to_mem (
    .clk_i,
    .rst_ni,
    .test_i       ( test_mode ),
    .busy_o       ( ),
    .axi_req_i    ( axi_llc_mst_req ),
    .axi_resp_o   ( axi_llc_mst_rsp ),
    .mem_req_o    ( dram_req      ),
    .mem_gnt_i    ( '1            ),
    .mem_addr_o   ( dram_addr     ),
    .mem_wdata_o  ( dram_wdata    ),
    .mem_strb_o   ( dram_strb     ),
    .mem_atop_o   ( ),
    .mem_we_o     ( dram_we       ),
    .mem_rvalid_i ( dram_rvalid_q ),
    .mem_rdata_i  ( dram_rdata_q  )
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dram_rvalid_q <= '0;
      dram_rdata_q  <= '0;
    end else begin
      dram_rvalid_q <= dram_req;
      for (int unsigned i = 0; i < DramPorts; i++) begin
        if (dram_req[i]) begin
          if (dram_we[i]) k9r5_vlt_dram_write(64'(dram_addr[i]), dram_wdata[i], dram_strb[i]);
          else            dram_rdata_q[i] <= k9r5_vlt_dram_read(64'(dram_addr[i]));
        end
      end
    end
  end

  ///////////////////
  //  Serial Link  //
  ///////////////////

  axi_mst_req_t slink_axi_req;
  axi_mst_rsp_t slink_axi_rsp;

  // Mirror instance of the serial link, reflecting another chip. Its AXI
  // output (the SoC accessing the other chip) is left unanswered.
  serial_link #(
    .axi_req_t    ( axi_mst_req_t ),
    .axi_rsp_t    ( axi_mst_rsp_t ),
    .cfg_req_t    ( reg_req_t ),
    .cfg_rsp_t    ( reg_rsp_t ),
    .aw_chan_t    ( axi_mst_aw_chan_t ),
    .ar_chan_t    ( axi_mst_ar_chan_t ),
    .r_chan_t     ( axi_mst_r_chan_t  ),
    .w_chan_t     ( axi_mst_w_chan_t  ),
    .b_chan_t     ( axi_mst_b_chan_t  ),
    .hw2reg_t     ( serial_link_single_channel_reg_pkg::serial_link_single_channel_hw2reg_t ),
    .reg2hw_t     ( serial_link_single_channel_reg_pkg::serial_link_single_channel_reg2hw_t ),
    .NumChannels  ( SlinkNumChan   ),
    .NumLanes     ( SlinkNumLanes  ),
    .MaxClkDiv    ( SlinkMaxClkDiv )
  ) i_serial_link (
    .clk_i          ( clk_i  ),
    .rst_ni         ( rst_ni ),
    .clk_sl_i       ( clk_i  ),
    .rst_sl_ni      ( rst_ni ),
    .clk_reg_i      ( clk_i  ),
    .rst_reg_ni     ( rst_ni ),
    .testmode_i     ( test_mode ),
    .axi_in_req_i   ( slink_axi_req ),
    .axi_in_rsp_o   ( slink_axi_rsp ),
    .axi_out_req_o  ( ),
    .axi_out_rsp_i  ( '0 ),
    .cfg_req_i      ( '0 ),
    .cfg_rsp_o      ( ),
    .ddr_rcv_clk_i  ( slink_rcv_clk_o ),
    .ddr_rcv_clk_o  ( slink_rcv_clk_i ),
    .ddr_i          ( slink_o ),
    .ddr_o          ( slink_i ),
    .isolated_i     ( '0 ),
    .isolate_o      ( ),
    .clk_ena_o      ( ),
    .reset_no       ( )
  );

  axi_from_mem #(
    .MemAddrWidth ( 64 ),
    .AxiAddrWidth ( DutCfg.AddrWidth    ),
    .DataWidth    ( DutCfg.AxiDataWidth ),
    .MaxRequests  ( 64 ),
    .AxiProt      ( 3'b000 ),
    .axi_req_t    ( axi_mst_req_t ),
    .axi_rsp_t    ( axi_mst_rsp_t )
  ) i_slink_from_mem (
    .clk_i,
    .rst_ni,
    .mem_req_i       ( slink_mem_req_i       ),
    .mem_addr_i      ( slink_mem_addr_i      ),
    .mem_we_i        ( slink_mem_we_i        ),
    .mem_wdata_i     ( slink_mem_wdata_i     ),
    .mem_be_i        ( slink_mem_be_i        ),
    .mem_gnt_o       ( slink_mem_gnt_o       ),
    .mem_rsp_valid_o ( slink_mem_rsp_valid_o ),
    .mem_rsp_rdata_o ( slink_mem_rsp_rdata_o ),
    .mem_rsp_error_o ( slink_mem_rsp_error_o ),
    .slv_aw_cache_i  ( 4'b0000 ),
    .slv_ar_cache_i  ( 4'b0000 ),
    .axi_req_o       ( slink_axi_req ),
    .axi_rsp_i       ( slink_axi_rsp )
  );

endmodule
