// Adjustible settings
typedef 32 MAX_PENDING_REQ_NUM;
// typedef 16 MAX_PENDING_READ_ATOMIC_REQ_NUM;
typedef 256 DATA_BUS_WIDTH;
typedef 2 MIN_PKT_NUM_IN_BUF;

// Limitations
typedef TExp#(31) MAX_MR_SIZE; // 2GB
typedef 1 MAX_SEND_SGE;
typedef 1 MAX_RECV_SGE;
typedef 0 MAX_INLINE_DATA; // No inline data
