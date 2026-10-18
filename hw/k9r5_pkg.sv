// K9R5: Cheshire (CVA6 + Ara) with a Spatz cluster on its external AXI ports.

package k9r5_pkg;

  import cheshire_pkg::*;

  // Ara configuration; the build passes NR_LANES and VLEN (ara/config/*.mk)
`ifdef NR_LANES
  localparam int unsigned AraNrLanes = `NR_LANES;
`else
  localparam int unsigned AraNrLanes = 2;
`endif
`ifdef VLEN
  localparam int unsigned AraVLEN = `VLEN;
`else
  localparam int unsigned AraVLEN = 2048;
`endif

  // Spatz cluster window: TCDM at the base, cluster peripherals after it. Must
  // match cluster_base_addr in hw/spatz/k9r5.spatz_cluster.hjson. Inside CVA6's
  // uncached region [0x4000_0000, 0x8000_0000) of Cheshire.
  localparam doub_bt SpatzBase = 64'h0000_0000_5100_0000;
  localparam doub_bt SpatzSize = 64'h0000_0000_0080_0000;

  function automatic cheshire_cfg_t gen_k9r5_cfg();
    cheshire_cfg_t ret = DefaultCfg;
    // Ara on CVA6's accelerator port
    ret.Ara        = 1;
    ret.AraNrLanes = AraNrLanes;
    ret.AraVLEN    = AraVLEN;
    // Spatz: one external AXI master (cluster -> SoC) and one external slave
    // (SoC -> cluster TCDM and peripherals)
    ret.AxiExtNumMst         = 1;
    ret.AxiExtNumSlv         = 1;
    ret.AxiExtNumRules       = 1;
    ret.AxiExtRegionIdx[0]   = 0;
    ret.AxiExtRegionStart[0] = SpatzBase;
    ret.AxiExtRegionEnd[0]   = SpatzBase + SpatzSize;
    return ret;
  endfunction

  localparam cheshire_cfg_t K9R5Cfg = gen_k9r5_cfg();

endpackage
