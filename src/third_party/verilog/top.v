`timescale 1ps / 1ps
`define ENABLE_CMAC_RS_FEC

module top#(
   parameter PL_LINK_CAP_MAX_LINK_WIDTH          = 16,            // 1- X1; 2 - X2; 4 - X4; 8 - X8
   parameter C_DATA_WIDTH                        = 512,
   parameter CMAC_GT_LANE_WIDTH                  = 4

)(
    // PCIe and XDMA
    output [(PL_LINK_CAP_MAX_LINK_WIDTH - 1) : 0] pci_exp_txp,
    output [(PL_LINK_CAP_MAX_LINK_WIDTH - 1) : 0] pci_exp_txn,
    input [(PL_LINK_CAP_MAX_LINK_WIDTH - 1) : 0]  pci_exp_rxp,
    input [(PL_LINK_CAP_MAX_LINK_WIDTH - 1) : 0]  pci_exp_rxn,

    input 					 sys_clk_p,
    input 					 sys_clk_n,
    input 					 sys_rst_n,

    input            board_sys_clk_n,
    input            board_sys_clk_p,


    // CMAC
    // input qsfp1_ref_clk_p,
    // input qsfp1_ref_clk_n,

    input qsfp2_ref_clk_p,
    input qsfp2_ref_clk_n,

    // input  [CMAC_GT_LANE_WIDTH - 1 : 0] qsfp1_rxn_in,
    // input  [CMAC_GT_LANE_WIDTH - 1 : 0] qsfp1_rxp_in,
    // output [CMAC_GT_LANE_WIDTH - 1 : 0] qsfp1_txn_out,
    // output [CMAC_GT_LANE_WIDTH - 1 : 0] qsfp1_txp_out

    input  [CMAC_GT_LANE_WIDTH - 1 : 0] qsfp2_rxn_in,
    input  [CMAC_GT_LANE_WIDTH - 1 : 0] qsfp2_rxp_in,
    output [CMAC_GT_LANE_WIDTH - 1 : 0] qsfp2_txn_out,
    output [CMAC_GT_LANE_WIDTH - 1 : 0] qsfp2_txp_out,

    input qsfp2_fault_in,
    output qsfp2_lpmode_out,
    output qsfp2_resetl_out
);

  localparam AXIL_ADDR_WIDTH = 20;

  localparam CMAC_AXIS_TDATA_WIDTH = 512;
  localparam CMAC_AXIS_TKEEP_WIDTH = 64;
  localparam CMAC_AXIS_TUSER_WIDTH = 1;
   
   wire 					   user_lnk_up;
   
   //----------------------------------------------------------------------------------------------------------------//
   //  AXI Interface                                                                                                 //
   //----------------------------------------------------------------------------------------------------------------//
   
   wire 					   user_clk_250;
   (*mark_debug, mark_debug_clock="user_clk_250" *) wire 					   user_resetn;



  //----------------------------------------------------------------------------------------------------------------//
  //    System(SYS) Interface                                                                                       //
  //----------------------------------------------------------------------------------------------------------------//

    wire                                    sys_clk;
    wire                                    sys_clk_gt;
    wire                                    global_reset_100mhz_clk;
    wire                                    sys_rst_n_c;




//////////////////////////////////////////////////  LITE
   //-- AXI Master Write Address Channel
    wire [AXIL_ADDR_WIDTH-1 : 0] m_axil_awaddr;
    wire [2:0]  m_axil_awprot;
    wire 	m_axil_awvalid;
    wire 	m_axil_awready;

    //-- AXI Master Write Data Channel
    wire [31:0] m_axil_wdata;
    wire [3:0]  m_axil_wstrb;
    wire 	m_axil_wvalid;
    wire 	m_axil_wready;
    //-- AXI Master Write Response Channel
    wire 	m_axil_bvalid;
    wire 	m_axil_bready;
    //-- AXI Master Read Address Channel
    wire [AXIL_ADDR_WIDTH-1:0] m_axil_araddr;
    wire [2:0]  m_axil_arprot;
    wire 	m_axil_arvalid;
    wire 	m_axil_arready;
    //-- AXI Master Read Data Channel
    wire [31:0] m_axil_rdata;
    wire [1:0]  m_axil_rresp;
    wire 	m_axil_rvalid;
    wire 	m_axil_rready;
    wire [1:0]  m_axil_bresp;

    // wire [2:0]    msi_vector_width;
    // wire          msi_enable;

    // AXI streaming ports
    wire [C_DATA_WIDTH-1:0]	m_axis_h2c_tdata_0;
    wire 			m_axis_h2c_tlast_0;
    (*mark_debug, mark_debug_clock="user_clk_250" *) wire 			m_axis_h2c_tvalid_0;
    (*mark_debug, mark_debug_clock="user_clk_250" *) wire 			m_axis_h2c_tready_0;
    wire [C_DATA_WIDTH/8-1:0]	m_axis_h2c_tkeep_0;
    
    wire [C_DATA_WIDTH-1:0] s_axis_c2h_tdata_0; 
    wire s_axis_c2h_tlast_0;
    (*mark_debug, mark_debug_clock="user_clk_250" *) wire s_axis_c2h_tvalid_0;
    (*mark_debug, mark_debug_clock="user_clk_250" *) wire s_axis_c2h_tready_0;
    wire [C_DATA_WIDTH/8-1:0] s_axis_c2h_tkeep_0; 

    wire [7:0] c2h_sts_0;
    wire [7:0] h2c_sts_0;


  // Ref clock buffer
  IBUFDS_GTE4 # (.REFCLK_HROW_CK_SEL(2'b00)) refclk_ibuf (.O(sys_clk_gt), .ODIV2(sys_clk), .I(sys_clk_p), .CEB(1'b0), .IB(sys_clk_n));
  // Reset buffer
  IBUF   sys_reset_n_ibuf (.O(sys_rst_n_c), .I(sys_rst_n));
  

  IBUFDS IBUFDS_inst (
      .O(global_reset_100mhz_clk),    // 1-bit output: Buffer output
      .I(board_sys_clk_p),            // 1-bit input: Diff_p buffer input (connect directly to top-level port)
      .IB(board_sys_clk_n)            // 1-bit input: Diff_n buffer input (connect directly to top-level port)
  );

// Descriptor Bypass Control Logic
  (*mark_debug, mark_debug_clock="user_clk_250" *) wire c2h_dsc_byp_ready_0;
  wire [63 : 0] c2h_dsc_byp_src_addr_0;
  wire [63 : 0] c2h_dsc_byp_dst_addr_0;
  wire [27 : 0] c2h_dsc_byp_len_0;
  wire [4 : 0] c2h_dsc_byp_ctl_0;
  (*mark_debug, mark_debug_clock="user_clk_250" *) wire c2h_dsc_byp_load_0;
  (*mark_debug, mark_debug_clock="user_clk_250" *) wire h2c_dsc_byp_ready_0;
  wire [63 : 0] h2c_dsc_byp_src_addr_0;
  wire [63 : 0] h2c_dsc_byp_dst_addr_0;
  wire [27 : 0] h2c_dsc_byp_len_0;
  wire [4 : 0] h2c_dsc_byp_ctl_0;
  (*mark_debug, mark_debug_clock="user_clk_250" *) wire h2c_dsc_byp_load_0;

  //  (*mark_debug, mark_debug_clock="user_clk_250" *)


// GT Signals
    wire            gt_txusrclk2;
    wire            gt_usr_tx_reset;
    wire            gt_usr_rx_reset;

    wire            gt_rx_axis_tvalid;
    wire            gt_rx_axis_tready;
    wire            gt_rx_axis_tlast;
    wire [CMAC_AXIS_TDATA_WIDTH - 1 : 0] gt_rx_axis_tdata;
    wire [CMAC_AXIS_TKEEP_WIDTH - 1 : 0] gt_rx_axis_tkeep;
    wire [CMAC_AXIS_TUSER_WIDTH - 1 : 0] gt_rx_axis_tuser;

    wire            gt_stat_rx_aligned;
    wire [8:0]      gt_stat_rx_pause_req;
    wire [2:0]      gt_stat_rx_bad_fcs;
    wire [2:0]      gt_stat_rx_stomped_fcs;
    wire            gt_ctl_rx_enable;
    wire            gt_ctl_rx_force_resync;
    wire            gt_ctl_rx_test_pattern;
    wire            gt_ctl_rx_check_etype_gcp;
    wire            gt_ctl_rx_check_etype_gpp;
    wire            gt_ctl_rx_check_etype_pcp;
    wire            gt_ctl_rx_check_etype_ppp;
    wire            gt_ctl_rx_check_mcast_gcp;
    wire            gt_ctl_rx_check_mcast_gpp;
    wire            gt_ctl_rx_check_mcast_pcp;
    wire            gt_ctl_rx_check_mcast_ppp;
    wire            gt_ctl_rx_check_opcode_gcp;
    wire            gt_ctl_rx_check_opcode_gpp;
    wire            gt_ctl_rx_check_opcode_pcp;
    wire            gt_ctl_rx_check_opcode_ppp;
    wire            gt_ctl_rx_check_sa_gcp;
    wire            gt_ctl_rx_check_sa_gpp;
    wire            gt_ctl_rx_check_sa_pcp;
    wire            gt_ctl_rx_check_sa_ppp;
    wire            gt_ctl_rx_check_ucast_gcp;
    wire            gt_ctl_rx_check_ucast_gpp;
    wire            gt_ctl_rx_check_ucast_pcp;
    wire            gt_ctl_rx_check_ucast_ppp;
    wire            gt_ctl_rx_enable_gcp;
    wire            gt_ctl_rx_enable_gpp;
    wire            gt_ctl_rx_enable_pcp;
    wire            gt_ctl_rx_enable_ppp;
    wire [8:0]      gt_ctl_rx_pause_ack;
    wire [8:0]      gt_ctl_rx_pause_enable;

    wire            gt_tx_axis_tready;
    wire            gt_tx_axis_tvalid;
    wire            gt_tx_axis_tlast;
    wire [CMAC_AXIS_TDATA_WIDTH - 1 : 0] gt_tx_axis_tdata;
    wire [CMAC_AXIS_TKEEP_WIDTH - 1 : 0] gt_tx_axis_tkeep;
    wire [CMAC_AXIS_TUSER_WIDTH - 1 : 0] gt_tx_axis_tuser;

    wire            gt_tx_ovfout;
    wire            gt_tx_unfout;
    wire            gt_ctl_tx_enable;
    wire            gt_ctl_tx_test_pattern;
    wire            gt_ctl_tx_send_idle;
    wire            gt_ctl_tx_send_rfi;
    wire            gt_ctl_tx_send_lfi;
    wire [8:0]      gt_ctl_tx_pause_enable;
    wire [15:0]     gt_ctl_tx_pause_quanta0;
    wire [15:0]     gt_ctl_tx_pause_quanta1;
    wire [15:0]     gt_ctl_tx_pause_quanta2;
    wire [15:0]     gt_ctl_tx_pause_quanta3;
    wire [15:0]     gt_ctl_tx_pause_quanta4;
    wire [15:0]     gt_ctl_tx_pause_quanta5;
    wire [15:0]     gt_ctl_tx_pause_quanta6;
    wire [15:0]     gt_ctl_tx_pause_quanta7;
    wire [15:0]     gt_ctl_tx_pause_quanta8;
    wire [8:0]      gt_ctl_tx_pause_req;
    wire            gt_ctl_tx_resend_pause;


    // CMAC RS-FEC Signals
    wire            gt_ctl_rsfec_ieee_error_indication_mode;
    wire            gt_ctl_tx_rsfec_enable;
    wire            gt_ctl_rx_rsfec_enable;
    wire            gt_ctl_rx_rsfec_enable_correction;
    wire            gt_ctl_rx_rsfec_enable_indication;

    wire    global_soft_reset;

    // CMAC CTRL STATE
    wire [3:0]      cmac_ctrl_tx_state;
    wire [3:0]      cmac_ctrl_rx_state;
    wire            is_cmac_rx_aligned;


    reg qsfp_reset_flag_reg;

    always @ (negedge user_resetn) begin
      qsfp_reset_flag_reg <= !qsfp_reset_flag_reg;
    end

    assign qsfp2_lpmode_out = 1'b0;
    // assign qsfp2_resetl_out = qsfp_reset_flag_reg ? 1'b1 : user_resetn;
    assign qsfp2_resetl_out = 1'b1;

    xdma_0 xdma_0_i
     (
      .sys_rst_n       ( sys_rst_n_c ),

      .sys_clk         ( sys_clk ),
      .sys_clk_gt      ( sys_clk_gt),

      .dma_bridge_resetn(global_soft_reset),
      
      // Tx
      .pci_exp_txn     ( pci_exp_txn ),
      .pci_exp_txp     ( pci_exp_txp ),
      
      // Rx
      .pci_exp_rxn     ( pci_exp_rxn ),
      .pci_exp_rxp     ( pci_exp_rxp ),
      


      // AXI streaming ports
      .s_axis_c2h_tdata_0(s_axis_c2h_tdata_0),  
      .s_axis_c2h_tlast_0(s_axis_c2h_tlast_0),
      .s_axis_c2h_tvalid_0(s_axis_c2h_tvalid_0), 
      .s_axis_c2h_tready_0(s_axis_c2h_tready_0), 
      .s_axis_c2h_tkeep_0(s_axis_c2h_tkeep_0),



      .m_axis_h2c_tdata_0(m_axis_h2c_tdata_0),
      .m_axis_h2c_tlast_0(m_axis_h2c_tlast_0),
      .m_axis_h2c_tvalid_0(m_axis_h2c_tvalid_0),
      .m_axis_h2c_tready_0(m_axis_h2c_tready_0),
      .m_axis_h2c_tkeep_0(m_axis_h2c_tkeep_0),

      .c2h_sts_0(c2h_sts_0),                            // output wire [7 : 0] c2h_sts_0
      .h2c_sts_0(h2c_sts_0),                            // output wire [7 : 0] h2c_sts_0

      // LITE interface   
      //-- AXI Master Write Address Channel
      .m_axil_awaddr    (m_axil_awaddr),
      .m_axil_awprot    (m_axil_awprot),
      .m_axil_awvalid   (m_axil_awvalid),
      .m_axil_awready   (m_axil_awready),
      //-- AXI Master Write Data Channel
      .m_axil_wdata     (m_axil_wdata),
      .m_axil_wstrb     (m_axil_wstrb),
      .m_axil_wvalid    (m_axil_wvalid),
      .m_axil_wready    (m_axil_wready),
      //-- AXI Master Write Response Channel
      .m_axil_bvalid    (m_axil_bvalid),
      .m_axil_bresp     (m_axil_bresp),
      .m_axil_bready    (m_axil_bready),
      //-- AXI Master Read Address Channel
      .m_axil_araddr    (m_axil_araddr),
      .m_axil_arprot    (m_axil_arprot),
      .m_axil_arvalid   (m_axil_arvalid),
      .m_axil_arready   (m_axil_arready),
      //-- AXI Master Read Data Channel
      .m_axil_rdata     (m_axil_rdata),
      .m_axil_rresp     (m_axil_rresp),
      .m_axil_rvalid    (m_axil_rvalid),
      .m_axil_rready    (m_axil_rready),


      // Descriptor Bypass
      .c2h_dsc_byp_ready_0    (c2h_dsc_byp_ready_0),
      .c2h_dsc_byp_src_addr_0 (c2h_dsc_byp_src_addr_0),
      .c2h_dsc_byp_dst_addr_0 (c2h_dsc_byp_dst_addr_0),
      .c2h_dsc_byp_len_0      (c2h_dsc_byp_len_0),
      .c2h_dsc_byp_ctl_0      (c2h_dsc_byp_ctl_0),
      .c2h_dsc_byp_load_0     (c2h_dsc_byp_load_0),

      .h2c_dsc_byp_ready_0    (h2c_dsc_byp_ready_0),
      .h2c_dsc_byp_src_addr_0 (h2c_dsc_byp_src_addr_0),
      .h2c_dsc_byp_dst_addr_0 (h2c_dsc_byp_dst_addr_0),
      .h2c_dsc_byp_len_0      (h2c_dsc_byp_len_0),
      .h2c_dsc_byp_ctl_0      (h2c_dsc_byp_ctl_0),
      .h2c_dsc_byp_load_0     (h2c_dsc_byp_load_0),

      .usr_irq_req  (0),
      .usr_irq_ack  (),

      //-- AXI Global
      .axi_aclk        ( user_clk_250),
      .axi_aresetn     ( user_resetn ),
      .user_lnk_up     ( user_lnk_up )
    );


    mkBsvTop bsv_top(
      .cmac_rxtx_clk(gt_txusrclk2),
      .cmac_rx_resetn(~gt_usr_rx_reset),
      .cmac_tx_resetn(~gt_usr_tx_reset),
      .CLK(user_clk_250),
      .RST_N(user_resetn),
      .global_reset_100mhz_clk(global_reset_100mhz_clk),
      .global_reset_resetn(sys_rst_n_c),
      .csrSoftResetSignal(global_soft_reset),

      .xdmaChannel_rawH2cAxiStream_tvalid(m_axis_h2c_tvalid_0),
      .xdmaChannel_rawH2cAxiStream_tdata(m_axis_h2c_tdata_0),
      .xdmaChannel_rawH2cAxiStream_tkeep(m_axis_h2c_tkeep_0),
      .xdmaChannel_rawH2cAxiStream_tlast(m_axis_h2c_tlast_0),
      .xdmaChannel_rawH2cAxiStream_tready(m_axis_h2c_tready_0),

      .xdmaChannel_rawC2hAxiStream_tvalid(s_axis_c2h_tvalid_0),
      .xdmaChannel_rawC2hAxiStream_tdata(s_axis_c2h_tdata_0),
      .xdmaChannel_rawC2hAxiStream_tkeep(s_axis_c2h_tkeep_0),
      .xdmaChannel_rawC2hAxiStream_tlast(s_axis_c2h_tlast_0),
      .xdmaChannel_rawC2hAxiStream_tready(s_axis_c2h_tready_0),

      .xdmaChannel_h2cDescByp_ready(h2c_dsc_byp_ready_0),

      .xdmaChannel_h2cDescByp_load(h2c_dsc_byp_load_0),

      .xdmaChannel_h2cDescByp_src_addr(h2c_dsc_byp_src_addr_0),

      .xdmaChannel_h2cDescByp_dst_addr(h2c_dsc_byp_dst_addr_0),

      .xdmaChannel_h2cDescByp_len(h2c_dsc_byp_len_0),

      .xdmaChannel_h2cDescByp_ctl(h2c_dsc_byp_ctl_0),

      .xdmaChannel_h2cDescByp_desc_done(h2c_sts_0[3]),

      .xdmaChannel_c2hDescByp_ready(c2h_dsc_byp_ready_0),

      .xdmaChannel_c2hDescByp_load(c2h_dsc_byp_load_0),

      .xdmaChannel_c2hDescByp_src_addr(c2h_dsc_byp_src_addr_0),

      .xdmaChannel_c2hDescByp_dst_addr(c2h_dsc_byp_dst_addr_0),

      .xdmaChannel_c2hDescByp_len(c2h_dsc_byp_len_0),

      .xdmaChannel_c2hDescByp_ctl(c2h_dsc_byp_ctl_0),

      .xdmaChannel_c2hDescByp_desc_done(c2h_sts_0[3]),

      .axilRegBlock_awvalid(m_axil_awvalid),
      .axilRegBlock_awaddr(m_axil_awaddr),
      .axilRegBlock_awprot(m_axil_awprot),

      .axilRegBlock_awready(m_axil_awready),

      .axilRegBlock_wvalid(m_axil_wvalid),
      .axilRegBlock_wdata(m_axil_wdata),
      .axilRegBlock_wstrb(m_axil_wstrb),

      .axilRegBlock_wready(m_axil_wready),

      .axilRegBlock_bvalid(m_axil_bvalid),

      .axilRegBlock_bresp(m_axil_bresp),

      .axilRegBlock_bready(m_axil_bready),

      .axilRegBlock_arvalid(m_axil_arvalid),
      .axilRegBlock_araddr(m_axil_araddr),
      .axilRegBlock_arprot(m_axil_arprot),

      .axilRegBlock_arready(m_axil_arready),

      .axilRegBlock_rvalid(m_axil_rvalid),

      .axilRegBlock_rresp(m_axil_rresp),

      .axilRegBlock_rdata(m_axil_rdata),

      .axilRegBlock_rready(m_axil_rready),


      // CMAC Interface

      .cmac_tx_axis_tvalid    (gt_tx_axis_tvalid),
      .cmac_tx_axis_tdata     (gt_tx_axis_tdata ),
      .cmac_tx_axis_tkeep     (gt_tx_axis_tkeep ),
      .cmac_tx_axis_tlast     (gt_tx_axis_tlast ),
      .cmac_tx_axis_tuser     (gt_tx_axis_tuser ),
      .cmac_tx_axis_tready    (gt_tx_axis_tready),

      .tx_stat_ovfout         (gt_tx_ovfout),
      .tx_stat_unfout         (gt_tx_unfout),
      .tx_stat_rx_aligned     (gt_stat_rx_aligned),

      .tx_ctl_enable          (gt_ctl_tx_enable      ),
      .tx_ctl_test_pattern    (gt_ctl_tx_test_pattern),
      .tx_ctl_send_idle       (gt_ctl_tx_send_idle   ),
      .tx_ctl_send_lfi        (gt_ctl_tx_send_lfi    ),
      .tx_ctl_send_rfi        (gt_ctl_tx_send_rfi    ),
      .tx_ctl_reset           (),

      .tx_ctl_pause_enable    (gt_ctl_tx_pause_enable ),
      .tx_ctl_pause_req       (gt_ctl_tx_pause_req    ),
      .tx_ctl_pause_quanta0   (gt_ctl_tx_pause_quanta0),
      .tx_ctl_pause_quanta1   (gt_ctl_tx_pause_quanta1),
      .tx_ctl_pause_quanta2   (gt_ctl_tx_pause_quanta2),
      .tx_ctl_pause_quanta3   (gt_ctl_tx_pause_quanta3),
      .tx_ctl_pause_quanta4   (gt_ctl_tx_pause_quanta4),
      .tx_ctl_pause_quanta5   (gt_ctl_tx_pause_quanta5),
      .tx_ctl_pause_quanta6   (gt_ctl_tx_pause_quanta6),
      .tx_ctl_pause_quanta7   (gt_ctl_tx_pause_quanta7),
      .tx_ctl_pause_quanta8   (gt_ctl_tx_pause_quanta8),

      .cmac_rx_axis_tvalid    (gt_rx_axis_tvalid),
      .cmac_rx_axis_tdata     (gt_rx_axis_tdata ),
      .cmac_rx_axis_tkeep     (gt_rx_axis_tkeep ),
      .cmac_rx_axis_tlast     (gt_rx_axis_tlast ),
      .cmac_rx_axis_tuser     (gt_rx_axis_tuser ),
      .cmac_rx_axis_tready    (gt_rx_axis_tready),

      .rx_stat_aligned        (gt_stat_rx_aligned    ),
      .rx_stat_pause_req      (gt_stat_rx_pause_req  ),
      .rx_ctl_enable          (gt_ctl_rx_enable      ),
      .rx_ctl_force_resync    (gt_ctl_rx_force_resync),
      .rx_ctl_test_pattern    (gt_ctl_rx_test_pattern),
      .rx_ctl_reset           (),
      .rx_ctl_pause_enable    (gt_ctl_rx_pause_enable),
      .rx_ctl_pause_ack       (gt_ctl_rx_pause_ack   ),

      .rx_ctl_enable_gcp      (gt_ctl_rx_enable_gcp),
      .rx_ctl_check_mcast_gcp (gt_ctl_rx_check_mcast_gcp),
      .rx_ctl_check_ucast_gcp (gt_ctl_rx_check_ucast_gcp),
      .rx_ctl_check_sa_gcp    (gt_ctl_rx_check_sa_gcp),
      .rx_ctl_check_etype_gcp (gt_ctl_rx_check_etype_gcp),
      .rx_ctl_check_opcode_gcp(gt_ctl_rx_check_opcode_gcp),

      .rx_ctl_enable_pcp      (gt_ctl_rx_enable_pcp),
      .rx_ctl_check_mcast_pcp (gt_ctl_rx_check_mcast_pcp),
      .rx_ctl_check_ucast_pcp (gt_ctl_rx_check_ucast_pcp),
      .rx_ctl_check_sa_pcp    (gt_ctl_rx_check_sa_pcp),
      .rx_ctl_check_etype_pcp (gt_ctl_rx_check_etype_pcp),
      .rx_ctl_check_opcode_pcp(gt_ctl_rx_check_opcode_pcp),

      .rx_ctl_enable_gpp      (gt_ctl_rx_enable_gpp),
      .rx_ctl_check_mcast_gpp (gt_ctl_rx_check_mcast_gpp),
      .rx_ctl_check_ucast_gpp (gt_ctl_rx_check_ucast_gpp),
      .rx_ctl_check_sa_gpp    (gt_ctl_rx_check_sa_gpp),
      .rx_ctl_check_etype_gpp (gt_ctl_rx_check_etype_gpp),
      .rx_ctl_check_opcode_gpp(gt_ctl_rx_check_opcode_gpp),

      .rx_ctl_enable_ppp      (gt_ctl_rx_enable_ppp),
      .rx_ctl_check_mcast_ppp (gt_ctl_rx_check_mcast_ppp),
      .rx_ctl_check_ucast_ppp (gt_ctl_rx_check_ucast_ppp),
      .rx_ctl_check_sa_ppp    (gt_ctl_rx_check_sa_ppp),
      .rx_ctl_check_etype_ppp (gt_ctl_rx_check_etype_ppp),
      .rx_ctl_check_opcode_ppp(gt_ctl_rx_check_opcode_ppp),

      .tx_ctl_rsfec_enable    (gt_ctl_tx_rsfec_enable),
      .rx_ctl_rsfec_enable    (gt_ctl_rx_rsfec_enable),
      .rx_ctl_rsfec_enable_correction(gt_ctl_rx_rsfec_enable_correction),
      .rx_ctl_rsfec_enable_indication(gt_ctl_rx_rsfec_enable_indication),
      .ctl_rsfec_ieee_error_indication_mode(gt_ctl_rsfec_ieee_error_indication_mode),

      // Controller State
      .cmac_ctrl_tx_state     (cmac_ctrl_tx_state ),
      .cmac_ctrl_rx_state     (cmac_ctrl_rx_state ),
      .cmac_rx_aligned_indication(is_cmac_rx_aligned)
  );

  wire [(CMAC_GT_LANE_WIDTH * 3)-1 :0]    gt_loopback_in;
  //// For other GT loopback options please change the value appropriately
  //// For example, for Near End PMA loopback for 4 Lanes update the gt_loopback_in = {4{3'b010}};
  //// For more information and settings on loopback, refer GT Transceivers user guide
  assign gt_loopback_in  = {CMAC_GT_LANE_WIDTH{3'b000}};

  wire            gtwiz_reset_tx_datapath;
  wire            gtwiz_reset_rx_datapath;
  assign gtwiz_reset_tx_datapath    = 1'b0;
  assign gtwiz_reset_rx_datapath    = 1'b0;

  assign udp_reset = user_resetn;
  assign cmac_sys_reset = ~ user_resetn;


  cmac_usplus_0 cmac_inst(
        .gt_rxp_in                            (qsfp2_rxp_in  ),
        .gt_rxn_in                            (qsfp2_rxn_in  ),
        .gt_txp_out                           (qsfp2_txp_out ),
        .gt_txn_out                           (qsfp2_txn_out ),
        .gt_loopback_in                       (gt_loopback_in),
        
        .gtwiz_reset_tx_datapath              (gtwiz_reset_tx_datapath),
        .gtwiz_reset_rx_datapath              (gtwiz_reset_rx_datapath),
        .sys_reset                            (cmac_sys_reset),
        .gt_ref_clk_p                         (qsfp2_ref_clk_p),
        .gt_ref_clk_n                         (qsfp2_ref_clk_n),
        .init_clk                             (user_clk_250),

        .gt_txusrclk2                         (gt_txusrclk2),
        .usr_rx_reset                         (gt_usr_rx_reset),
        .usr_tx_reset                         (gt_usr_tx_reset),

        // RX
        .rx_axis_tvalid                       (gt_rx_axis_tvalid),
        .rx_axis_tdata                        (gt_rx_axis_tdata ),
        .rx_axis_tkeep                        (gt_rx_axis_tkeep ),
        .rx_axis_tlast                        (gt_rx_axis_tlast ),
        .rx_axis_tuser                        (gt_rx_axis_tuser ),
        
        .stat_rx_bad_fcs                      (gt_stat_rx_bad_fcs),
        .stat_rx_stomped_fcs                  (gt_stat_rx_stomped_fcs),
        .stat_rx_aligned                      (gt_stat_rx_aligned),
        .stat_rx_pause_req                    (gt_stat_rx_pause_req),
        .ctl_rx_enable                        (gt_ctl_rx_enable),
        .ctl_rx_force_resync                  (gt_ctl_rx_force_resync),
        .ctl_rx_test_pattern                  (gt_ctl_rx_test_pattern),
        .ctl_rx_check_etype_gcp               (gt_ctl_rx_check_etype_gcp),
        .ctl_rx_check_etype_gpp               (gt_ctl_rx_check_etype_gpp),
        .ctl_rx_check_etype_pcp               (gt_ctl_rx_check_etype_pcp),
        .ctl_rx_check_etype_ppp               (gt_ctl_rx_check_etype_ppp),
        .ctl_rx_check_mcast_gcp               (gt_ctl_rx_check_mcast_gcp),
        .ctl_rx_check_mcast_gpp               (gt_ctl_rx_check_mcast_gpp),
        .ctl_rx_check_mcast_pcp               (gt_ctl_rx_check_mcast_pcp),
        .ctl_rx_check_mcast_ppp               (gt_ctl_rx_check_mcast_ppp),
        .ctl_rx_check_opcode_gcp              (gt_ctl_rx_check_opcode_gcp),
        .ctl_rx_check_opcode_gpp              (gt_ctl_rx_check_opcode_gpp),
        .ctl_rx_check_opcode_pcp              (gt_ctl_rx_check_opcode_pcp),
        .ctl_rx_check_opcode_ppp              (gt_ctl_rx_check_opcode_ppp),
        .ctl_rx_check_sa_gcp                  (gt_ctl_rx_check_sa_gcp),
        .ctl_rx_check_sa_gpp                  (gt_ctl_rx_check_sa_gpp),
        .ctl_rx_check_sa_pcp                  (gt_ctl_rx_check_sa_pcp),
        .ctl_rx_check_sa_ppp                  (gt_ctl_rx_check_sa_ppp),
        .ctl_rx_check_ucast_gcp               (gt_ctl_rx_check_ucast_gcp),
        .ctl_rx_check_ucast_gpp               (gt_ctl_rx_check_ucast_gpp),
        .ctl_rx_check_ucast_pcp               (gt_ctl_rx_check_ucast_pcp),
        .ctl_rx_check_ucast_ppp               (gt_ctl_rx_check_ucast_ppp),
        .ctl_rx_enable_gcp                    (gt_ctl_rx_enable_gcp),
        .ctl_rx_enable_gpp                    (gt_ctl_rx_enable_gpp),
        .ctl_rx_enable_pcp                    (gt_ctl_rx_enable_pcp),
        .ctl_rx_enable_ppp                    (gt_ctl_rx_enable_ppp),
        .ctl_rx_pause_ack                     (gt_ctl_rx_pause_ack),
        .ctl_rx_pause_enable                  (gt_ctl_rx_pause_enable),
    

        // TX
        .tx_axis_tready                       (gt_tx_axis_tready),
        .tx_axis_tvalid                       (gt_tx_axis_tvalid),
        .tx_axis_tdata                        (gt_tx_axis_tdata),
        .tx_axis_tkeep                        (gt_tx_axis_tkeep),
        .tx_axis_tlast                        (gt_tx_axis_tlast),
        .tx_axis_tuser                        (gt_tx_axis_tuser),
        
        .tx_ovfout                            (gt_tx_ovfout),
        .tx_unfout                            (gt_tx_unfout),
        .ctl_tx_enable                        (gt_ctl_tx_enable),
        .ctl_tx_test_pattern                  (gt_ctl_tx_test_pattern),
        .ctl_tx_send_idle                     (gt_ctl_tx_send_idle),
        .ctl_tx_send_rfi                      (gt_ctl_tx_send_rfi),
        .ctl_tx_send_lfi                      (gt_ctl_tx_send_lfi),
        .ctl_tx_pause_enable                  (gt_ctl_tx_pause_enable),
        .ctl_tx_pause_req                     (gt_ctl_tx_pause_req),
        .ctl_tx_pause_quanta0                 (gt_ctl_tx_pause_quanta0),
        .ctl_tx_pause_quanta1                 (gt_ctl_tx_pause_quanta1),
        .ctl_tx_pause_quanta2                 (gt_ctl_tx_pause_quanta2),
        .ctl_tx_pause_quanta3                 (gt_ctl_tx_pause_quanta3),
        .ctl_tx_pause_quanta4                 (gt_ctl_tx_pause_quanta4),
        .ctl_tx_pause_quanta5                 (gt_ctl_tx_pause_quanta5),
        .ctl_tx_pause_quanta6                 (gt_ctl_tx_pause_quanta6),
        .ctl_tx_pause_quanta7                 (gt_ctl_tx_pause_quanta7),
        .ctl_tx_pause_quanta8                 (gt_ctl_tx_pause_quanta8),

        .ctl_tx_pause_refresh_timer0          (16'd0),
        .ctl_tx_pause_refresh_timer1          (16'd0),
        .ctl_tx_pause_refresh_timer2          (16'd0),
        .ctl_tx_pause_refresh_timer3          (16'd0),
        .ctl_tx_pause_refresh_timer4          (16'd0),
        .ctl_tx_pause_refresh_timer5          (16'd0),
        .ctl_tx_pause_refresh_timer6          (16'd0),
        .ctl_tx_pause_refresh_timer7          (16'd0),
        .ctl_tx_pause_refresh_timer8          (16'd0),
        .ctl_tx_resend_pause                  (1'b0 ),
        .tx_preamblein                        (56'd0),

        // RS-FEC
`ifdef ENABLE_CMAC_RS_FEC
        .ctl_rsfec_ieee_error_indication_mode (gt_ctl_rsfec_ieee_error_indication_mode),
        .ctl_tx_rsfec_enable                  (gt_ctl_tx_rsfec_enable),
        .ctl_rx_rsfec_enable                  (gt_ctl_rx_rsfec_enable),
        .ctl_rx_rsfec_enable_correction       (gt_ctl_rx_rsfec_enable_correction),
        .ctl_rx_rsfec_enable_indication       (gt_ctl_rx_rsfec_enable_indication),
`endif    

        .core_rx_reset                        (1'b0 ),
        .core_tx_reset                        (1'b0 ),
        .rx_clk                               (gt_txusrclk2),
        .core_drp_reset                       (1'b0 ),
        .drp_clk                              (1'b0 ),
        .drp_addr                             (10'b0),
        .drp_di                               (16'b0),
        .drp_en                               (1'b0 ),
        .drp_do                               (),
        .drp_rdy                              (),
        .drp_we                               (1'b0 )
    );
endmodule