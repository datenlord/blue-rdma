// Adjustible settings
typedef 32 MAX_PENDING_REQ_NUM;
// typedef 16 MAX_PENDING_READ_ATOMIC_REQ_NUM;
typedef 256 DATA_BUS_WIDTH;
typedef 2 MIN_PKT_NUM_IN_BUF;

// Device attributes
typedef TExp#(31)           MAX_MR_SIZE; // 2GB
typedef MAX_PENDING_REQ_NUM MAX_CQE;
typedef 1                   MAX_SGE;
// typedef 1                   MAX_SEND_SGE;
// typedef 1                   MAX_RECV_SGE;
typedef 0                   MAX_INLINE_DATA; // No inline data

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