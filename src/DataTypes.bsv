import ClientServer :: *;
import CompletionBuffer :: *;

import Headers :: *;
import Settings :: *;

// Derived settings
typedef TExp#(31) RDMA_MAX_LEN;
typedef TAdd#(TAdd#(BTH_WIDTH, XRCETH_WIDTH), ATOMIC_ETH_WIDTH) MAX_HEADER_BYTE_LENGTH;

typedef TDiv#(DATA_BUS_WIDTH, 8) DATA_BUS_BYTE_WIDTH;
typedef TLog#(DATA_BUS_BYTE_WIDTH) DATA_BUS_BYTE_NUM_WIDTH;
typedef TLog#(DATA_BUS_WIDTH) DATA_BUS_BIT_NUM_WIDTH;

typedef TDiv#(MAX_HEADER_BYTE_LENGTH, DATA_BUS_BYTE_WIDTH) MAX_HEADER_FRAG_NUM;
typedef TMul#(DATA_BUS_WIDTH, MAX_HEADER_FRAG_NUM) MAX_HEADER_WIDTH;
typedef TMul#(DATA_BUS_BYTE_WIDTH, MAX_HEADER_FRAG_NUM) MAX_HEADER_BYTE_EN_WIDTH;

typedef TLog#(TLog#(MAX_PMTU)) PMTU_MAX_WIDTH;
typedef TSub#(RDMA_MAX_LEN_WIDTH, TLog#(DATA_BUS_BYTE_WIDTH)) FRAG_NUM_WIDTH;
typedef TSub#(RDMA_MAX_LEN_WIDTH, TLog#(MIN_PMTU)) PKT_NUM_WIDTH;

// Derived types
typedef Bit#(DATA_BUS_WIDTH) DATA;
typedef Bit#(DATA_BUS_BYTE_WIDTH) ByteEn;

typedef Bit#(MAX_HEADER_WIDTH) HeaderData;
typedef Bit#(MAX_HEADER_BYTE_EN_WIDTH) HeaderByteEn;
typedef Bit#(TLog#(TAdd#(1, MAX_HEADER_BYTE_EN_WIDTH))) HeaderByteNum;
typedef Bit#(TAdd#(1, MAX_HEADER_WIDTH)) HeaderBitNum;
typedef Bit#(TLog#(TAdd#(1, MAX_HEADER_FRAG_NUM))) HeaderFragNum;

typedef Bit#(DATA_BUS_BYTE_NUM_WIDTH) BusByteWidthMask;
typedef Bit#(TAdd#(1, DATA_BUS_BYTE_NUM_WIDTH)) ByteEnBitNum;
typedef Bit#(TAdd#(1, DATA_BUS_BIT_NUM_WIDTH)) BusBitNum;
// typedef Bit#(TAdd#(1, MAX_HEADER_BYTE_EN_WIDTH)) HeaderByteEnBitNum;

typedef Bit#(TLog#(TAdd#(1, MAX_PENDING_REQ_NUM))) PendingReqCnt;
// typedef UInt(TAdd#(TLog#(MAX_PENDING_REQ_NUM) + 1)) PendingReadAtomicReqCnt;
typedef Bit#(TExp#(PMTU_MAX_WIDTH)) PmtuMask;
typedef Bit#(FRAG_NUM_WIDTH) FragNum;
typedef Bit#(PKT_NUM_WIDTH) PktNum;

typedef Bit#(WR_ID_WIDTH) WorkReqID;
// typedef Bits#(PMTU_MAX_WIDTH) PmtuVal;

typedef CBToken#(MAX_PENDING_REQ_NUM) PendingReqToken;

// typedef enum {
//     PSN_EQ,
//     PSN_GE,
//     PSN_GT,
//     PSN_LE,
//     PSN_LT,
//     PSN_OUTRANGE
// } PsnCmpRslt deriving(Bits, Eq);

// RDMA related requests and responses

typedef struct {
    RdmaOpCode opcode;
    PSN psn;
} RdmaReq deriving(Bits);

typedef struct {
    RdmaOpCode opcode;
    PSN psn;
    // AETH
} RdmaResp deriving(Bits);

// DATA and ByteEn are left algined
typedef struct {
    DATA data;
    ByteEn byteEn;
    Bool isFirst;
    Bool isLast;
} DataStream deriving(Bits, Bounded, Eq);

instance FShow#(DataStream);
    function Fmt fshow(DataStream ds);
        return $format(
            "<DataStream data=%h, byteEn=%h, isFirst=%b, isLast=%b>",
            ds.data, ds.byteEn, ds.isFirst, ds.isLast
        );
    endfunction
endinstance

// HeaderData and HeaderByteEn are left aligned
typedef struct {
    HeaderData headerData;
    HeaderByteEn headerByteEn;
    HeaderFragNum headerFragNum;
    ByteEnBitNum lastFragValidByteNum;
} HeaderAndByteEn deriving(Bits, Bounded, Eq);

instance FShow#(HeaderAndByteEn);
    function Fmt fshow(HeaderAndByteEn hb);
        return $format(
            "<HeaderAndByteEn headerData=%h, headerByteEn=%h, headerFragNum=%0d, lastFragValidByteNum=%0d>",
            hb.headerData, hb.headerByteEn, hb.headerFragNum, hb.lastFragValidByteNum
        );
    endfunction
endinstance


// DMA related

typedef enum {
    RQ_RD, RQ_WR, RQ_DUP_RD, RQ_ATOMIC,
    SQ_RD, SQ_WR, SQ_ATOMIC_WR
} DmaInitiator deriving(Bits, Eq);

typedef struct {
    DmaInitiator initiator;
    QPN sqpn;
    ADDR startAddr;
    Length len;
    PendingReqToken token;
} DmaReadReq deriving(Bits);

typedef struct {
    DmaInitiator initiator;
    QPN sqpn;
    PendingReqToken token;
    DataStream data;
} DmaReadResp deriving(Bits);

typedef struct {
    DmaInitiator initiator;
    QPN sqpn;
    ADDR startAddr;
    Length len;
    // If invalid token, then no DMA write response
    Maybe#(PendingReqToken) maybeToken;
} DmaWriteReq deriving(Bits);

typedef struct {
    DmaInitiator initiator;
    QPN sqpn;
    // ADDR startAddr;
    PendingReqToken token;
} DmaWriteResp deriving(Bits);

// RDMA related types

typedef enum {
    RESET,
    INIT,
    RTR,
    RTS,
    SQD,
    ERR
} QpState deriving(Bits, Eq);

typedef enum {
    MTU_256  =  8, // log2(256)
    MTU_512  =  9, // log2(512)
    MTU_1024 = 10, // log2(1024)
    MTU_2048 = 11, // log2(2048)
    MTU_4096 = 12  // log2(4096)
} PMTU deriving(Bits, Eq);

// WorkReq related

typedef enum {
    IBV_WR_RDMA_WRITE = 0,
    IBV_WR_RDMA_WRITE_WITH_IMM = 1,
    IBV_WR_SEND = 2,
    IBV_WR_SEND_WITH_IMM = 3,
    IBV_WR_RDMA_READ = 4,
    IBV_WR_ATOMIC_CMP_AND_SWP = 5,
    IBV_WR_ATOMIC_FETCH_AND_ADD = 6,
    IBV_WR_LOCAL_INV = 7,
    IBV_WR_BIND_MW = 8,
    IBV_WR_SEND_WITH_INV = 9,
    IBV_WR_TSO = 10,
    IBV_WR_DRIVER1 = 11
} WorkReqOpCode deriving(Bits, Eq);

typedef enum {
    IBV_SEND_FENCE = 1,
    IBV_SEND_SIGNALED = 2,
    IBV_SEND_SOLICITED = 4,
    IBV_SEND_INLINE = 8,
    IBV_SEND_IP_CSUM = 16
} WorkReqSendFlags deriving(Bits, Eq);

typedef struct {
    WorkReqID id;
    WorkReqOpCode opcode;
    WorkReqSendFlags flags; // TODO: support multiple flags
    ADDR raddr;
    RKEY rkey;
    Length len;
    PSN startPSN;
    PSN endPSN;
    ADDR laddr;
    LKEY lkey;
    Maybe#(IMM) immDt;
    Maybe#(RKEY) rkey2Inv;
    QPN srqn; // for XRC
    QPN dqpn; // for UD
} WorkReq deriving(Bits);

// WorkComp related

typedef enum {
    IBV_WC_SUCCESS = 0,
    IBV_WC_LOC_LEN_ERR = 1,
    IBV_WC_LOC_QP_OP_ERR = 2,
    IBV_WC_LOC_EEC_OP_ERR = 3,
    IBV_WC_LOC_PROT_ERR = 4,
    IBV_WC_WR_FLUSH_ERR = 5,
    IBV_WC_MW_BIND_ERR = 6,
    IBV_WC_BAD_RESP_ERR = 7,
    IBV_WC_LOC_ACCESS_ERR = 8,
    IBV_WC_REM_INV_REQ_ERR = 9,
    IBV_WC_REM_ACCESS_ERR = 10,
    IBV_WC_REM_OP_ERR = 11,
    IBV_WC_RETRY_EXC_ERR = 12,
    IBV_WC_RNR_RETRY_EXC_ERR = 13,
    IBV_WC_LOC_RDD_VIOL_ERR = 14,
    IBV_WC_REM_INV_RD_REQ_ERR = 15,
    IBV_WC_REM_ABORT_ERR = 16,
    IBV_WC_INV_EECN_ERR = 17,
    IBV_WC_INV_EEC_STATE_ERR = 18,
    IBV_WC_FATAL_ERR = 19,
    IBV_WC_RESP_TIMEOUT_ERR = 20,
    IBV_WC_GENERAL_ERR = 21,
    IBV_WC_TM_ERR = 22,
    IBV_WC_TM_RNDV_INCOMPLETE = 23
} WorkCompStatus deriving(Bits, Eq);

typedef enum {
    IBV_WC_NO_FLAGS = 0, // Not defined in rdma-core
    IBV_WC_GRH = 1,
    IBV_WC_WITH_IMM = 2,
    IBV_WC_IP_CSUM_OK = 4,
    IBV_WC_WITH_INV = 8,
    IBV_WC_TM_SYNC_REQ = 16,
    IBV_WC_TM_MATCH = 32,
    IBV_WC_TM_DATA_VALID = 64
} WorkCompFlags deriving(Bits, Eq);

typedef struct {
    WorkReqID id;
    WorkCompFlags flags; // TODO: support multiple flags
    WorkCompStatus status;
} WorkComp deriving(Bits);
