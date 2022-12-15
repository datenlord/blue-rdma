import ClientServer :: *;
import CompletionBuffer :: *;
import PAClib :: *;

import Headers :: *;
import ScanFIFOF :: *;
import Settings :: *;

// Protocol settings
typedef TExp#(31) RDMA_MAX_LEN;
typedef 8         ATOMIC_WORK_REQ_LEN;
typedef 3         RETRY_CNT_WIDTH;

typedef 7 INFINITE_RETRY;
typedef 0 INFINITE_TIMEOUT;

// Derived settings
typedef AETH_VALUE_WIDTH TIMER_WIDTH;

typedef TAdd#(TAdd#(BTH_BYTE_WIDTH, XRCETH_BYTE_WIDTH), ATOMIC_ETH_BYTE_WIDTH) HEADER_MAX_BYTE_LENGTH;

typedef TDiv#(DATA_BUS_WIDTH, 8)   DATA_BUS_BYTE_WIDTH;
typedef TLog#(DATA_BUS_BYTE_WIDTH) DATA_BUS_BYTE_NUM_WIDTH;
typedef TLog#(DATA_BUS_WIDTH)      DATA_BUS_BIT_NUM_WIDTH;

typedef TDiv#(HEADER_MAX_BYTE_LENGTH, DATA_BUS_BYTE_WIDTH) HEADER_MAX_FRAG_NUM;
typedef TMul#(DATA_BUS_WIDTH, HEADER_MAX_FRAG_NUM)         HEADER_MAX_DATA_WIDTH;
typedef TMul#(DATA_BUS_BYTE_WIDTH, HEADER_MAX_FRAG_NUM)    HEADER_MAX_BYTE_EN_WIDTH;

typedef TAdd#(1, TSub#(RDMA_MAX_LEN_WIDTH, TLog#(DATA_BUS_BYTE_WIDTH))) TOTAL_FRAG_NUM_WIDTH;
typedef TAdd#(1, TLog#(TSub#(MAX_PMTU, DATA_BUS_BYTE_WIDTH)))           PMTU_FRAG_NUM_WIDTH;
typedef TAdd#(1, TSub#(RDMA_MAX_LEN_WIDTH, TLog#(MIN_PMTU)))            PKT_NUM_WIDTH;
typedef TAdd#(1, TLog#(MAX_PMTU))                                       PKT_LEN_WIDTH;

// typedef TLog#(TLog#(MAX_PMTU))               PMTU_VALUE_MAX_WIDTH;
typedef TDiv#(MAX_PMTU, DATA_BUS_BYTE_WIDTH) PMTU_MAX_FRAG_NUM;
typedef TDiv#(MIN_PMTU, DATA_BUS_BYTE_WIDTH) PMTU_MIN_FRAG_NUM;

typedef TExp#(PAD_WIDTH) FRAG_MIN_VALID_BYTE_NUM;

typedef TMul#(MIN_PKT_NUM_IN_RECV_BUF, PMTU_MAX_FRAG_NUM)   DATA_STREAM_FRAG_BUF_SIZE;
typedef TDiv#(DATA_STREAM_FRAG_BUF_SIZE, PMTU_MIN_FRAG_NUM) PKT_META_DATA_BUF_SIZE;

// Derived types
typedef Bit#(DATA_BUS_WIDTH)      DATA;
typedef Bit#(DATA_BUS_BYTE_WIDTH) ByteEn;

typedef Bit#(HEADER_MAX_DATA_WIDTH)                     HeaderData;
typedef Bit#(HEADER_MAX_BYTE_EN_WIDTH)                  HeaderByteEn;
typedef Bit#(TLog#(TAdd#(1, HEADER_MAX_BYTE_EN_WIDTH))) HeaderByteNum;
typedef Bit#(TAdd#(1, HEADER_MAX_DATA_WIDTH))           HeaderBitNum;
typedef Bit#(TLog#(TAdd#(1, HEADER_MAX_FRAG_NUM)))      HeaderFragNum;

typedef Bit#(DATA_BUS_BYTE_NUM_WIDTH) BusByteWidthMask;
typedef Bit#(PAD_WIDTH)               PadMask;

typedef Bit#(TAdd#(1, DATA_BUS_BIT_NUM_WIDTH))  BusBitNum;
typedef Bit#(TAdd#(1, DATA_BUS_BYTE_NUM_WIDTH)) ByteEnBitNum;

typedef Bit#(TLog#(TAdd#(1, MAX_PENDING_REQ_NUM))) PendingReqCnt;
// typedef UInt(TAdd#(TLog#(MAX_PENDING_REQ_NUM) + 1)) PendingReadAtomicReqCnt;

// typedef Bit#(PMTU_VALUE_MAX_WIDTH) PmtuValueWidth;
typedef Bit#(TLog#(MAX_PMTU))      PmtuMask;
typedef Bit#(TOTAL_FRAG_NUM_WIDTH) TotalFragNum;
typedef Bit#(PMTU_FRAG_NUM_WIDTH)  PmtuFragNum;
typedef Bit#(PKT_NUM_WIDTH)        PktNum;
typedef Bit#(PKT_LEN_WIDTH)        PktLen;

typedef Bit#(WR_ID_WIDTH)    WorkReqID;

typedef Bit#(RETRY_CNT_WIDTH) RetryCnt;
typedef Bit#(TIMER_WIDTH)     TimeOutTimer;
typedef Bit#(TIMER_WIDTH)     RnrTimer;

typedef CBToken#(MAX_PENDING_REQ_NUM) PendingReqToken;
typedef PipeOut#(DataStream)          DataStreamPipeOut;

typedef Server#(DmaReadReq, DmaReadResp)   DmaReadSrv;
typedef Server#(DmaWriteReq, DmaWriteResp) DmaWriteSrv;

typedef ScanFIFOF#(MAX_PENDING_REQ_NUM, PendingWorkReq) PendingWorkReqBuf;
typedef PipeOut#(RecvReq)                               RecvReqBuf;

// RDMA related requests and responses

typedef enum {
    RDMA_RESP_NORMAL,
    RDMA_RESP_RETRY,
    RDMA_RESP_ERROR,
    RDMA_RESP_UNKNOWN
} RdmaRespType deriving(Bits, Eq, FShow);

typedef enum {
    RETRY_REASON_NOT_RETRY,
    RETRY_REASON_RNR,
    RETRY_REASON_SEQ_ERR,
    RETRY_REASON_IMPLICIT,
    RETRY_REASON_TIME_OUT
} RetryReason deriving(Bits, Eq);

// DATA and ByteEn are left algined
typedef struct {
    DATA data;
    ByteEn byteEn;
    Bool isFirst;
    Bool isLast;
} DataStream deriving(Bits, Bounded, Eq, FShow);

typedef struct {
    HeaderByteNum headerLen;
    HeaderFragNum headerFragNum;
    ByteEnBitNum lastFragValidByteNum;
    Bool hasPayload;
} HeaderMetaData deriving(Bits, Bounded, Eq);

instance FShow#(HeaderMetaData);
    function Fmt fshow(HeaderMetaData hmd);
        return $format(
            "HeaderMetaData { headerLen=%0d, headerFragNum=%0d, lastFragValidByteNum=%0d, hasPayload=",
            hmd.headerLen, hmd.headerFragNum, hmd.lastFragValidByteNum, fshow(hmd.hasPayload), " }"
        );
    endfunction
endinstance

// HeaderData and HeaderByteEn are left aligned
typedef struct {
    HeaderData headerData;
    HeaderByteEn headerByteEn;
    HeaderMetaData headerMetaData;
} RdmaHeader deriving(Bits, Bounded, FShow);

typedef enum {
    PKT_ST_VALID,
    PKT_ST_LEN_ERR,
    PKT_ST_ACC_ERR
    // PKT_ST_INVALID
} PktVeriStatus deriving(Bits, Bounded, Eq);

typedef struct {
    PktLen pktPayloadLen;
    PmtuFragNum pktFragNum;
    RdmaHeader pktHeader;
    Bool pktValid;
    PktVeriStatus pktStatus;
} RdmaPktMetaData deriving(Bits, Bounded);

instance FShow#(RdmaPktMetaData);
    function Fmt fshow(RdmaPktMetaData rpmd);
        return $format(
            "RdmaPktMetaData { pktPayloadLen=%0d, pktFragNum=%0d",
            rpmd.pktPayloadLen, rpmd.pktFragNum,
            ", pktHeader=", fshow(rpmd.pktHeader),
            ", pktValid=", fshow(rpmd.pktValid), " }"
        );
    endfunction
endinstance

// DMA related

typedef enum {
    PAYLOAD_INIT_RQ_RD,
    PAYLOAD_INIT_RQ_WR,
    PAYLOAD_INIT_RQ_DUP_RD,
    PAYLOAD_INIT_RQ_ATOMIC,
    PAYLOAD_INIT_SQ_RD,
    PAYLOAD_INIT_SQ_WR,
    PAYLOAD_INIT_SQ_ATOMIC,
    PAYLOAD_INIT_SQ_DISCARD
} PayloadInitiator deriving(Bits, Eq);

typedef struct {
    QPN sqpn;
    ADDR startAddr;
    Length len;
    WorkReqID wrID;
} DmaReadReq deriving(Bits);

typedef struct {
    QPN sqpn;
    WorkReqID wrID;
    DataStream data;
} DmaReadResp deriving(Bits);

typedef struct {
    QPN sqpn;
    ADDR startAddr;
    PktLen len;
    PSN psn;
} DmaWriteMetaData deriving(Bits, Eq, FShow);

typedef struct {
    DmaWriteMetaData metaData;
    DataStream data;
} DmaWriteReq deriving(Bits);

typedef struct {
    QPN sqpn;
    PSN psn;
} DmaWriteResp deriving(Bits);

typedef struct {
    PayloadInitiator initiator;
    Bool addPadding;
    DmaReadReq dmaReadReq;
} PayloadGenReq deriving(Bits);

typedef struct {
    PayloadInitiator initiator;
    Bool addPadding;
    DmaReadResp dmaReadResp;
} PayloadGenResp deriving(Bits);

typedef union tagged {
    void DiscardPayload;
    Tuple2#(DmaWriteMetaData, Long) AtomicRespInfoAndPayload;
    DmaWriteMetaData ReadRespInfo;
} PayloadConInfo deriving(Bits, Eq, FShow);

typedef struct {
    PayloadInitiator initiator;
    PmtuFragNum fragNum;
    PayloadConInfo consumeInfo;
} PayloadConReq deriving(Bits);

typedef struct {
    PayloadInitiator initiator;
    DmaWriteResp dmaWriteResp;
} PayloadConResp deriving(Bits);

// QP related types

typedef enum {
    IBV_QPS_RESET,
    IBV_QPS_INIT,
    IBV_QPS_RTR,
    IBV_QPS_RTS,
    IBV_QPS_SQD,
    IBV_QPS_SQE,
    IBV_QPS_ERR,
    IBV_QPS_UNKNOWN
} QpState deriving(Bits, Eq);

typedef enum {
    IBV_QPT_RC = 2,
    IBV_QPT_UC = 3,
    IBV_QPT_UD = 4,
    IBV_QPT_RAW_PACKET = 8,
    IBV_QPT_XRC_SEND = 9,
    IBV_QPT_XRC_RECV = 10
    // IBV_QPT_DRIVER = 0xff
} QpType deriving(Bits, Eq, FShow);

typedef enum {
    IBV_ACCESS_LOCAL_WRITE   =  1,
    IBV_ACCESS_REMOTE_WRITE  =  2, // (1 << 1)
    IBV_ACCESS_REMOTE_READ   =  4, // (1 << 2)
    IBV_ACCESS_REMOTE_ATOMIC =  8, // (1 << 3)
    IBV_ACCESS_MW_BIND       = 16, // (1 << 4)
    IBV_ACCESS_ZERO_BASED    = 32, // (1 << 5)
    IBV_ACCESS_ON_DEMAND     = 64, // (1 << 6)
    IBV_ACCESS_HUGETLB       = 128 // (1 << 7)
    // IBV_ACCESS_RELAXED_ORDERING	= IBV_ACCESS_OPTIONAL_FIRST,
} QpAccessTypeFlags deriving(Bits, Eq);

typedef enum {
    IBV_MTU_256  = 1,
    IBV_MTU_512  = 2,
    IBV_MTU_1024 = 3,
    IBV_MTU_2048 = 4,
    IBV_MTU_4096 = 5
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
} WorkReqOpCode deriving(Bits, Eq, FShow);

typedef enum {
    IBV_SEND_NO_FLAGS = 0, // Not defined in rdma-core
    IBV_SEND_FENCE = 1,
    IBV_SEND_SIGNALED = 2,
    IBV_SEND_SOLICITED = 4,
    IBV_SEND_INLINE = 8,
    IBV_SEND_IP_CSUM = 16
} WorkReqSendFlags deriving(Bits, Eq, FShow);

typedef struct {
    WorkReqID id;
    WorkReqOpCode opcode;
    WorkReqSendFlags flags; // TODO: support multiple flags
    ADDR raddr;
    RKEY rkey;
    Length len;
    ADDR laddr;
    LKEY lkey;
    QPN sqpn; // For WR dispatching
    Bool solicited; // Relevant only for the Send and RDMA Write with immediate data
    Maybe#(Long) comp;
    Maybe#(Long) swap;
    Maybe#(IMM) immDt;
    Maybe#(RKEY) rkey2Inv;
    Maybe#(QPN) srqn; // for XRC
    Maybe#(QPN) dqpn; // for UD
    Maybe#(QKEY) qkey; // for UD
} WorkReq deriving(Bits);

instance FShow#(WorkReq);
    function Fmt fshow(WorkReq wr);
        return $format(
            "WorkReq { id=%h", wr.id, ", opcode=", fshow(wr.opcode), ", flags=", fshow(wr.flags),
            ", raddr=%h, rkey=%h, len=%0d, laddr=%h, lkey=%h, sqpn=%h",
            wr.raddr, wr.rkey, wr.len, wr.laddr, wr.lkey, wr.sqpn,
            ", solicited=", fshow(wr.solicited), ", comp=", fshow(wr.comp), ", swap=", fshow(wr.swap),
            ", immDt=", fshow(wr.immDt), ", rkey2Inv=", fshow(wr.rkey2Inv), ", srqn=", fshow(wr.srqn),
            ", dqpn=", fshow(wr.dqpn), ", qkey=", fshow(wr.qkey), " }"
        );
    endfunction
endinstance

typedef struct {
    WorkReq wr;
    Maybe#(PSN) startPSN;
    Maybe#(PSN) endPSN;
    Maybe#(PktNum) pktNum;
    Maybe#(Bool) isOnlyReqPkt;
} PendingWorkReq deriving(Bits);

instance FShow#(PendingWorkReq);
    function Fmt fshow(PendingWorkReq pwr);
        let pktNumFmt = case (pwr.pktNum) matches
            tagged Valid .pn: $format("tagged Valid %0d", pn);
            tagged Invalid : $format("tagged Invalid PktNum");
        endcase;
        return $format(
            "PendingWorkReq { wr=", fshow(pwr.wr),
            ", startPSN=", fshow(pwr.startPSN), ", endPSN=", fshow(pwr.endPSN),
            ", pktNum=", pktNumFmt, ", isOnlyReqPkt=", fshow(pwr.isOnlyReqPkt), " }"
        );
    endfunction
endinstance

typedef struct {
    WorkReqID id;
    Length len;
    ADDR laddr;
    LKEY lkey;
    QPN sqpn; // For RR dispatching
} RecvReq deriving(Bits);

// WorkComp related

typedef enum {
    IBV_WC_SEND = 0,
    IBV_WC_RDMA_WRITE = 1,
    IBV_WC_RDMA_READ = 2,
    IBV_WC_COMP_SWAP = 3,
    IBV_WC_FETCH_ADD = 4,
    IBV_WC_BIND_MW = 5,
    IBV_WC_LOCAL_INV = 6,
    IBV_WC_TSO = 7,
    // consumers can test if a completion is a receive by testing (opcode & IBV_WC_RECV)
    IBV_WC_RECV = 128, // 1 << 7
    IBV_WC_RECV_RDMA_WITH_IMM = 129,
    IBV_WC_TM_ADD = 130,
    IBV_WC_TM_DEL = 131,
    IBV_WC_TM_SYNC = 132,
    IBV_WC_TM_RECV = 133,
    IBV_WC_TM_NO_TAG = 134,
    IBV_WC_DRIVER1 = 135,
    IBV_WC_DRIVER2 = 136,
    IBV_WC_DRIVER3 = 137
} WorkCompOpCode deriving(Bits, Eq, FShow);

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
} WorkCompStatus deriving(Bits, Eq, FShow);

typedef enum {
    IBV_WC_NO_FLAGS = 0, // Not defined in rdma-core
    IBV_WC_GRH = 1,
    IBV_WC_WITH_IMM = 2,
    IBV_WC_IP_CSUM_OK = 4,
    IBV_WC_WITH_INV = 8,
    IBV_WC_TM_SYNC_REQ = 16,
    IBV_WC_TM_MATCH = 32,
    IBV_WC_TM_DATA_VALID = 64
} WorkCompFlags deriving(Bits, Eq, FShow);

typedef struct {
    WorkReqID id;
    WorkCompOpCode opcode;
    WorkCompFlags flags; // TODO: support multiple flags
    WorkCompStatus status;
    Length len;
    PKEY pkey;
    QPN dqpn;
    QPN sqpn;
    Maybe#(IMM) immDt;
    Maybe#(RKEY) rkey2Inv;
} WorkComp deriving(Bits, FShow);

typedef enum {
    WC_REQ_TYPE_SUC_FULL_ACK,
    WC_REQ_TYPE_SUC_PARTIAL_ACK,
    WC_REQ_TYPE_ERR_FULL_ACK,
    WC_REQ_TYPE_ERR_PARTIAL_ACK,
    WC_REQ_TYPE_NO_WC,
    WC_REQ_TYPE_UNKNOWN
} WorkCompReqType deriving(Bits, Eq, FShow);

typedef struct {
    RecvReq recvReq;
    Bool wcWaitDmaResp;
    WorkCompReqType wcReqType;
    PSN reqPSN;
    WorkCompStatus wcStatus;
    RdmaOpCode reqOpCode;
    Maybe#(IMM) immDt;
    Maybe#(RKEY) rkey2Inv;
} WorkCompGenReqRQ deriving(Bits);

typedef struct {
    PendingWorkReq pendingWR;
    Bool wcWaitDmaResp;
    WorkCompReqType wcReqType;
    PSN respPSN;
    WorkCompStatus wcStatus;
} WorkCompGenReqSQ deriving(Bits, FShow);

// Async event related

typedef enum {
	IBV_EVENT_CQ_ERR,
	IBV_EVENT_QP_FATAL,
	IBV_EVENT_QP_REQ_ERR,
	IBV_EVENT_QP_ACCESS_ERR,
	IBV_EVENT_COMM_EST,
	IBV_EVENT_SQ_DRAINED,
	IBV_EVENT_PATH_MIG,
	IBV_EVENT_PATH_MIG_ERR,
	IBV_EVENT_DEVICE_FATAL,
	IBV_EVENT_PORT_ACTIVE,
	IBV_EVENT_PORT_ERR,
	IBV_EVENT_LID_CHANGE,
	IBV_EVENT_PKEY_CHANGE,
	IBV_EVENT_SM_CHANGE,
	IBV_EVENT_SRQ_ERR,
	IBV_EVENT_SRQ_LIMIT_REACHED,
	IBV_EVENT_QP_LAST_WQE_REACHED,
	IBV_EVENT_CLIENT_REREGISTER,
	IBV_EVENT_GID_CHANGE,
	IBV_EVENT_WQ_FATAL
} AsyncEventType deriving(Bits, Eq);
