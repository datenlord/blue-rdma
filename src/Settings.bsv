// `define SUPPORT_SGL


// Adjustible settings
// typedef 250 TARGET_FREQ_MHZ;
typedef 4 TARGET_CYCLE_NS;

typedef 2 MIN_PKT_NUM_IN_RECV_BUF;
typedef TMul#(2, MAX_QP_WR) MAX_PENDING_WORK_COMP_NUM;

typedef 250000000 UDP_FREQ;
typedef 250000000 RDMA_FREQ;
typedef 250000000 DMAC_FREQ;

typedef 100000000 BOARD_SYS_CLK_FREQ;
`ifdef IS_DEBUG
    typedef 5   BOARD_SOFT_RESET_COUNTER_VALUE;
`else
    typedef 5000000   BOARD_SOFT_RESET_COUNTER_VALUE;  // 50ms @ BOARD_SYS_CLK_FREQ
`endif

// RDMA device attributes
// Must be power of 2

`ifdef IS_250MHZ_512BITS
typedef 512 DATA_BUS_WIDTH;
`else
typedef 256 DATA_BUS_WIDTH;
`endif

typedef TExp#(31)           MAX_MR_SIZE;   // 2GB
typedef TExp#(21)           PAGE_SIZE_CAP; // 2MB
typedef 8                   MAX_QP;
typedef 32                  MAX_QP_WR;
`ifdef SUPPORT_SGL
    typedef 4               MAX_SGE;
`else
    typedef 1               MAX_SGE;
`endif
typedef 8                   MAX_CQ;
typedef MAX_QP_WR           MAX_CQE;
typedef 256                 MAX_MR;
typedef 2                   MAX_PD;
typedef TDiv#(MAX_QP_WR, 2) MAX_QP_RD_ATOM;
typedef TDiv#(MAX_QP_WR, 2) MAX_QP_DST_RD_ATOM;
typedef 0                   MAX_SRQ;
typedef MAX_QP_WR           MAX_SRQ_WR;
typedef MAX_SGE             MAX_SRQ_SGE;
// End must-be-power-of-2

typedef 1 MAX_SEND_SGE;
typedef 1 MAX_RECV_SGE;
typedef 0 MAX_INLINE_DATA; // No inline data

typedef TExp#(17)   MAX_PTE_ENTRY_CNT; // Max cover 256GB

// The following two param set the inflight queue size. 
// Greater value means it can handle longer PCIe latency without bubles in pipeline,
// but will take more area as buffer.
typedef 30 DMA_READ_INFLIGHT_QUEUE_LENGTH;
typedef 128 DMA_WRITE_INFLIGHT_QUEUE_LENGTH;

/*
struct ibv_device_attr {
    char                fw_ver[64];
    __be64              node_guid;
    __be64              sys_image_guid;
    uint64_t            max_mr_size;
    uint64_t            page_size_cap;
    uint32_t            vendor_id;
    uint32_t            vendor_part_id;
    uint32_t            hw_ver;
    int                 max_qp;
    int                 max_qp_wr;
    unsigned int        device_cap_flags;
    int                 max_sge;
    int                 max_sge_rd;
    int                 max_cq;
    int                 max_cqe;
    int                 max_mr;
    int                 max_pd;
    int                 max_qp_rd_atom;
    int                 max_ee_rd_atom;
    int                 max_res_rd_atom;
    int                 max_qp_init_rd_atom;
    int                 max_ee_init_rd_atom;
    enum ibv_atomic_cap atomic_cap;
    int                 max_ee;
    int                 max_rdd;
    int                 max_mw;
    int                 max_raw_ipv6_qp;
    int                 max_raw_ethy_qp;
    int                 max_mcast_grp;
    int                 max_mcast_qp_attach;
    int                 max_total_mcast_qp_attach;
    int                 max_ah;
    int                 max_fmr;
    int                 max_map_per_fmr;
    int                 max_srq;
    int                 max_srq_wr;
    int                 max_srq_sge;
    uint16_t            max_pkeys;
    uint8_t             local_ca_ack_delay;
    uint8_t             phys_port_cnt;
};
*/