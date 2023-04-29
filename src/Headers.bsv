import Reserved :: *;

// Fixed settings
typedef 64 ADDR_WIDTH;
typedef 64 LONG_WIDTH;
typedef 24 PSN_WIDTH;
typedef 24 QPN_WIDTH;
typedef 32 RDMA_MAX_LEN_WIDTH;
typedef 64 WR_ID_WIDTH;
typedef 2  PAD_WIDTH;
typedef 16 PKEY_WIDTH;
typedef 5  AETH_VALUE_WIDTH;
typedef 24 MSN_WIDTH;
typedef 32 KEY_WIDTH;
typedef 32 IMM_WIDTH;

typedef 256  MIN_PMTU;
typedef 4096 MAX_PMTU;

// Header fields

typedef Bit#(ADDR_WIDTH) ADDR;
typedef Bit#(RDMA_MAX_LEN_WIDTH) Length; // Byte length
typedef Bit#(LONG_WIDTH) Long;
typedef Bit#(QPN_WIDTH) QPN;
typedef Bit#(PSN_WIDTH) PSN;
typedef Bit#(PAD_WIDTH) PAD;
typedef Bit#(PKEY_WIDTH) PKEY;
typedef Bit#(AETH_VALUE_WIDTH) AethValue;
typedef Bit#(MSN_WIDTH) MSN;
typedef Bit#(KEY_WIDTH) RKEY;
typedef Bit#(KEY_WIDTH) LKEY;
typedef Bit#(KEY_WIDTH) QKEY;
typedef Bit#(IMM_WIDTH) IMM;

typedef 8'h00 RC_SEND_FIRST;
typedef 8'h01 RC_SEND_MIDDLE;
typedef 8'h02 RC_SEND_LAST;
typedef 8'h03 RC_SEND_LAST_WITH_IMMEDIATE;
typedef 8'h04 RC_SEND_ONLY;
typedef 8'h05 RC_SEND_ONLY_WITH_IMMEDIATE;
typedef 8'h06 RC_RDMA_WRITE_FIRST;
typedef 8'h07 RC_RDMA_WRITE_MIDDLE;
typedef 8'h08 RC_RDMA_WRITE_LAST;
typedef 8'h09 RC_RDMA_WRITE_LAST_WITH_IMMEDIATE;
typedef 8'h0a RC_RDMA_WRITE_ONLY;
typedef 8'h0b RC_RDMA_WRITE_ONLY_WITH_IMMEDIATE;
typedef 8'h0c RC_RDMA_READ_REQUEST;
typedef 8'h0d RC_RDMA_READ_RESPONSE_FIRST;
typedef 8'h0e RC_RDMA_READ_RESPONSE_MIDDLE;
typedef 8'h0f RC_RDMA_READ_RESPONSE_LAST;
typedef 8'h10 RC_RDMA_READ_RESPONSE_ONLY;
typedef 8'h11 RC_ACKNOWLEDGE;
typedef 8'h12 RC_ATOMIC_ACKNOWLEDGE;
typedef 8'h13 RC_COMPARE_SWAP;
typedef 8'h14 RC_FETCH_ADD;
typedef 8'h16 RC_SEND_LAST_WITH_INVALIDATE;
typedef 8'h17 RC_SEND_ONLY_WITH_INVALIDATE;

typedef 8'ha0 XRC_SEND_FIRST;
typedef 8'ha1 XRC_SEND_MIDDLE;
typedef 8'ha2 XRC_SEND_LAST;
typedef 8'ha3 XRC_SEND_LAST_WITH_IMMEDIATE;
typedef 8'ha4 XRC_SEND_ONLY;
typedef 8'ha5 XRC_SEND_ONLY_WITH_IMMEDIATE;
typedef 8'ha6 XRC_RDMA_WRITE_FIRST;
typedef 8'ha7 XRC_RDMA_WRITE_MIDDLE;
typedef 8'ha8 XRC_RDMA_WRITE_LAST;
typedef 8'ha9 XRC_RDMA_WRITE_LAST_WITH_IMMEDIATE;
typedef 8'haa XRC_RDMA_WRITE_ONLY;
typedef 8'hab XRC_RDMA_WRITE_ONLY_WITH_IMMEDIATE;
typedef 8'hac XRC_RDMA_READ_REQUEST;
typedef 8'had XRC_RDMA_READ_RESPONSE_FIRST;
typedef 8'hae XRC_RDMA_READ_RESPONSE_MIDDLE;
typedef 8'haf XRC_RDMA_READ_RESPONSE_LAST;
typedef 8'hb0 XRC_RDMA_READ_RESPONSE_ONLY;
typedef 8'hb1 XRC_ACKNOWLEDGE;
typedef 8'hb2 XRC_ATOMIC_ACKNOWLEDGE;
typedef 8'hb3 XRC_COMPARE_SWAP;
typedef 8'hb4 XRC_FETCH_ADD;
typedef 8'hb6 XRC_SEND_LAST_WITH_INVALIDATE;
typedef 8'hb7 XRC_SEND_ONLY_WITH_INVALIDATE;

typedef 8'h64 UD_SEND_ONLY;
typedef 8'h65 UD_SEND_ONLY_WITH_IMMEDIATE;

typedef 8'h81 ROCE_CNP; // RoCEv2 CNP 8'b10000001

typedef enum {
    TRANS_TYPE_RC  = 3'h0, // 3'b000
    TRANS_TYPE_UC  = 3'h1, // 3'b001
    TRANS_TYPE_RD  = 3'h2, // 3'b010
    TRANS_TYPE_UD  = 3'h3, // 3'b011
    TRANS_TYPE_CNP = 3'h4, // 3'b100
    TRANS_TYPE_XRC = 3'h5  // 3'b101
} TransType deriving(Bits, Bounded, Eq, FShow);

typedef SizeOf#(TransType) TRANS_TYPE_WIDTH;

typedef enum {
    SEND_FIRST                     = 5'h00,
    SEND_MIDDLE                    = 5'h01,
    SEND_LAST                      = 5'h02,
    SEND_LAST_WITH_IMMEDIATE       = 5'h03,
    SEND_ONLY                      = 5'h04,
    SEND_ONLY_WITH_IMMEDIATE       = 5'h05,
    RDMA_WRITE_FIRST               = 5'h06,
    RDMA_WRITE_MIDDLE              = 5'h07,
    RDMA_WRITE_LAST                = 5'h08,
    RDMA_WRITE_LAST_WITH_IMMEDIATE = 5'h09,
    RDMA_WRITE_ONLY                = 5'h0a,
    RDMA_WRITE_ONLY_WITH_IMMEDIATE = 5'h0b,
    RDMA_READ_REQUEST              = 5'h0c,
    RDMA_READ_RESPONSE_FIRST       = 5'h0d,
    RDMA_READ_RESPONSE_MIDDLE      = 5'h0e,
    RDMA_READ_RESPONSE_LAST        = 5'h0f,
    RDMA_READ_RESPONSE_ONLY        = 5'h10,
    ACKNOWLEDGE                    = 5'h11,
    ATOMIC_ACKNOWLEDGE             = 5'h12,
    COMPARE_SWAP                   = 5'h13,
    FETCH_ADD                      = 5'h14,
    RESYNC                         = 5'h15,
    SEND_LAST_WITH_INVALIDATE      = 5'h16,
    SEND_ONLY_WITH_INVALIDATE      = 5'h17
} RdmaOpCode deriving(Bits, Bounded, Eq, FShow);

typedef SizeOf#(RdmaOpCode) RDMA_OPCODE_WIDTH;

typedef enum {
    AETH_CODE_ACK  = 2'b00,
    AETH_CODE_RNR  = 2'b01,
    AETH_CODE_RSVD = 2'b10,
    AETH_CODE_NAK  = 2'b11
} AethCode deriving(Bits, Bounded, Eq, FShow);

typedef enum {
    AETH_ACK_VALUE_INVALID_CREDIT_CNT = 5'b11111
} AethAckValueCreditCnt deriving(Bits, Bounded, Eq);

typedef enum {
    AETH_NAK_SEQ_ERR = 5'h0, // 5'b00000 PSN Sequence Error
    AETH_NAK_INV_REQ = 5'h1, // 5'b00001 Invalid Request
    AETH_NAK_RMT_ACC = 5'h2, // 5'b00010 Remote Access Error
    AETH_NAK_RMT_OP  = 5'h3, // 5'b00011 Remote Operational Error
    AETH_NAK_INV_RD  = 5'h4  // 5'b00100 Invalid RD Request
//  Reserved 5'h5 - 5'h1F
} AethNakValue deriving(Bits, Bounded, Eq);

// Headers

// 12 bytes
// Reserved fields (except tver and migReq) not count for ICRC
typedef struct {
    TransType trans;
    RdmaOpCode opcode;
    Bool solicited;
    ReservedZero#(1) migReq; // Not support path migration
    PAD padCnt;
    ReservedZero#(4) tver;
    PKEY pkey;
    ReservedZero#(1) fecn; // Not used in RoCEv2
    ReservedZero#(1) becn; // Not used in RoCEv2
    ReservedZero#(6) resv6;
    QPN dqpn;
    Bool ackReq;
    ReservedZero#(7) resv7;
    PSN psn;
} BTH deriving(Bits, Bounded, FShow);

typedef SizeOf#(BTH)        BTH_WIDTH;
typedef TDiv#(BTH_WIDTH, 8) BTH_BYTE_WIDTH;

// 4 bytes
typedef struct {
    ReservedZero#(1) rsvd;
    AethCode code;
    AethValue value;
    MSN msn;
} AETH deriving(Bits, Bounded, FShow);

typedef SizeOf#(AETH)        AETH_WIDTH;
typedef TDiv#(AETH_WIDTH, 8) AETH_BYTE_WIDTH;

// 16 bytes
typedef struct {
    ADDR va;
    RKEY rkey;
    Length dlen;
} RETH deriving(Bits, Bounded);

typedef SizeOf#(RETH)        RETH_WIDTH;
typedef TDiv#(RETH_WIDTH, 8) RETH_BYTE_WIDTH;

// 28 bytes
typedef struct {
    ADDR va;
    RKEY rkey;
    Long swap;
    Long comp;
} AtomicEth deriving(Bits, Bounded);

typedef SizeOf#(AtomicEth)         ATOMIC_ETH_WIDTH;
typedef TDiv#(ATOMIC_ETH_WIDTH, 8) ATOMIC_ETH_BYTE_WIDTH;

// 8 byes
typedef struct {
    Long orig;
} AtomicAckEth deriving(Bits, Bounded);

typedef SizeOf#(AtomicAckEth)          ATOMIC_ACK_ETH_WIDTH;
typedef TDiv#(ATOMIC_ACK_ETH_WIDTH, 8) ATOMIC_ACK_ETH_BYTE_WIDTH;

// 4 bytes
typedef struct {
    IMM data;
} ImmDt deriving(Bits, Bounded);

typedef SizeOf#(ImmDt)         IMM_DT_WIDTH;
typedef TDiv#(IMM_DT_WIDTH, 8) IMM_DT_BYTE_WIDTH;

// 4 bytes
typedef struct {
    RKEY rkey;
} IETH deriving(Bits, Bounded);

typedef SizeOf#(IETH)        IETH_WIDTH;
typedef TDiv#(IETH_WIDTH, 8) IETH_BYTE_WIDTH;

// 8 bytes
typedef struct {
    QKEY qkey;
    ReservedZero#(8) rsvd;
    QPN sqpn;
} DETH deriving(Bits, Bounded);

typedef SizeOf#(DETH)        DETH_WIDTH;
typedef TDiv#(DETH_WIDTH, 8) DETH_BYTE_WIDTH;

// 4 bytes
typedef struct {
    ReservedZero#(8) rsvd;
    QPN srqn;
} XRCETH deriving(Bits, Bounded);

typedef SizeOf#(XRCETH)        XRCETH_WIDTH;
typedef TDiv#(XRCETH_WIDTH, 8) XRCETH_BYTE_WIDTH;

// 16 bytes
typedef struct {
    ReservedZero#(LONG_WIDTH) rsvd1;
    ReservedZero#(LONG_WIDTH) rsvd2;
} PayloadCNP deriving(Bits, Bounded);

typedef SizeOf#(PayloadCNP)         CNP_PAYLOAD_WIDTH;
typedef TDiv#(CNP_PAYLOAD_WIDTH, 8) CNP_PAYLOAD_BYTE_WIDTH;

// RC headers:
// BTH + IETH = 20 bytes
// BTH + RETH + ImmDT = 32 bytes
// BTH + AtomicEth = 40 bytes
// BTH + AETH + AtomicAckEth = 24 bytes

// XRC headers:
// BTH + XRCETH + IETH = 24 bytes
// BTH + XRCETH + RETH = 32 bytes
// BTH + XRCETH + RETH + ImmDT = 36 bytes
// BTH + XRCETH + AtomicEth = 44 bytes
// BTH + AETH + AtomicAckEth = 24 bytes

// UD headers:
// BTH + DETH + ImmDT = 24 bytes
// BTH + AETH = 16 bytes

function Integer calcHeaderLenByTransTypeAndRdmaOpCode(
    TransType transType, RdmaOpCode rdmaOpCode
);
    return case ({ pack(transType), pack(rdmaOpCode) } )
        // RC requests
        fromInteger(valueOf(RC_SEND_FIRST))                    : valueOf(BTH_BYTE_WIDTH);
        fromInteger(valueOf(RC_SEND_MIDDLE))                   : valueOf(BTH_BYTE_WIDTH);
        fromInteger(valueOf(RC_SEND_LAST))                     : valueOf(BTH_BYTE_WIDTH);
        fromInteger(valueOf(RC_SEND_LAST_WITH_IMMEDIATE))      : valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH);
        fromInteger(valueOf(RC_SEND_ONLY))                     : valueOf(BTH_BYTE_WIDTH);
        fromInteger(valueOf(RC_SEND_ONLY_WITH_IMMEDIATE))      : valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH);
        fromInteger(valueOf(RC_RDMA_WRITE_FIRST))              : valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH);
        fromInteger(valueOf(RC_RDMA_WRITE_MIDDLE))             : valueOf(BTH_BYTE_WIDTH);
        fromInteger(valueOf(RC_RDMA_WRITE_LAST))               : valueOf(BTH_BYTE_WIDTH);
        fromInteger(valueOf(RC_RDMA_WRITE_LAST_WITH_IMMEDIATE)): valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH);
        fromInteger(valueOf(RC_RDMA_WRITE_ONLY))               : valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH);
        fromInteger(valueOf(RC_RDMA_WRITE_ONLY_WITH_IMMEDIATE)): valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH);
        fromInteger(valueOf(RC_RDMA_READ_REQUEST))             : valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH);
        fromInteger(valueOf(RC_COMPARE_SWAP))                  : valueOf(BTH_BYTE_WIDTH) + valueOf(ATOMIC_ETH_BYTE_WIDTH);
        fromInteger(valueOf(RC_FETCH_ADD))                     : valueOf(BTH_BYTE_WIDTH) + valueOf(ATOMIC_ETH_BYTE_WIDTH);
        fromInteger(valueOf(RC_SEND_LAST_WITH_INVALIDATE))     : valueOf(BTH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH);
        fromInteger(valueOf(RC_SEND_ONLY_WITH_INVALIDATE))     : valueOf(BTH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH);

        // RC and XRC responses
        fromInteger(valueOf(RC_RDMA_READ_RESPONSE_FIRST)),  fromInteger(valueOf(XRC_RDMA_READ_RESPONSE_FIRST)) : valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH);
        fromInteger(valueOf(RC_RDMA_READ_RESPONSE_MIDDLE)), fromInteger(valueOf(XRC_RDMA_READ_RESPONSE_MIDDLE)): valueOf(BTH_BYTE_WIDTH);
        fromInteger(valueOf(RC_RDMA_READ_RESPONSE_LAST)),   fromInteger(valueOf(XRC_RDMA_READ_RESPONSE_LAST))  : valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH);
        fromInteger(valueOf(RC_RDMA_READ_RESPONSE_ONLY)),   fromInteger(valueOf(XRC_RDMA_READ_RESPONSE_ONLY))  : valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH);
        fromInteger(valueOf(RC_ACKNOWLEDGE)),               fromInteger(valueOf(XRC_ACKNOWLEDGE))              : valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH);
        fromInteger(valueOf(RC_ATOMIC_ACKNOWLEDGE)),        fromInteger(valueOf(XRC_ATOMIC_ACKNOWLEDGE))       : valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH) + valueOf(ATOMIC_ACK_ETH_BYTE_WIDTH);

        // XRC requests
        fromInteger(valueOf(XRC_SEND_FIRST))                    : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH);
        fromInteger(valueOf(XRC_SEND_MIDDLE))                   : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH);
        fromInteger(valueOf(XRC_SEND_LAST))                     : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH);
        fromInteger(valueOf(XRC_SEND_LAST_WITH_IMMEDIATE))      : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH);
        fromInteger(valueOf(XRC_SEND_ONLY))                     : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH);
        fromInteger(valueOf(XRC_SEND_ONLY_WITH_IMMEDIATE))      : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH);
        fromInteger(valueOf(XRC_RDMA_WRITE_FIRST))              : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH);
        fromInteger(valueOf(XRC_RDMA_WRITE_MIDDLE))             : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH);
        fromInteger(valueOf(XRC_RDMA_WRITE_LAST))               : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH);
        fromInteger(valueOf(XRC_RDMA_WRITE_LAST_WITH_IMMEDIATE)): valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH);
        fromInteger(valueOf(XRC_RDMA_WRITE_ONLY))               : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH);
        fromInteger(valueOf(XRC_RDMA_WRITE_ONLY_WITH_IMMEDIATE)): valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH);
        fromInteger(valueOf(XRC_RDMA_READ_REQUEST))             : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH);
        fromInteger(valueOf(XRC_COMPARE_SWAP))                  : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(ATOMIC_ETH_BYTE_WIDTH);
        fromInteger(valueOf(XRC_FETCH_ADD))                     : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(ATOMIC_ETH_BYTE_WIDTH);
        fromInteger(valueOf(XRC_SEND_LAST_WITH_INVALIDATE))     : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH);
        fromInteger(valueOf(XRC_SEND_ONLY_WITH_INVALIDATE))     : valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH);

        // UD requests
        fromInteger(valueOf(UD_SEND_ONLY))               : valueOf(BTH_BYTE_WIDTH) + valueOf(DETH_BYTE_WIDTH);
        fromInteger(valueOf(UD_SEND_ONLY_WITH_IMMEDIATE)): valueOf(BTH_BYTE_WIDTH) + valueOf(DETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH);

        // CNP notification
        fromInteger(valueOf(ROCE_CNP)): valueOf(BTH_BYTE_WIDTH) + valueOf(CNP_PAYLOAD_BYTE_WIDTH);
        default: 0; // error("invalid transType and rdmaOpCode in calcHeaderLenByTransTypeAndRdmaOpCode()");
    endcase;
endfunction

function Bool rdmaOpCodeHasPayload(RdmaOpCode opcode);
    return case (opcode)
        SEND_FIRST                    ,
        SEND_MIDDLE                   ,
        SEND_LAST                     ,
        SEND_ONLY                     ,
        SEND_LAST_WITH_IMMEDIATE      ,
        SEND_ONLY_WITH_IMMEDIATE      ,
        SEND_LAST_WITH_INVALIDATE     ,
        SEND_ONLY_WITH_INVALIDATE     ,

        RDMA_WRITE_FIRST              ,
        RDMA_WRITE_MIDDLE             ,
        RDMA_WRITE_LAST               ,
        RDMA_WRITE_ONLY               ,
        RDMA_WRITE_LAST_WITH_IMMEDIATE,
        RDMA_WRITE_ONLY_WITH_IMMEDIATE,

        RDMA_READ_RESPONSE_FIRST      ,
        RDMA_READ_RESPONSE_MIDDLE     ,
        RDMA_READ_RESPONSE_LAST       ,
        RDMA_READ_RESPONSE_ONLY       : True;

        default                       : False;
    endcase;
endfunction
