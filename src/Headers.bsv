import Reserved :: *;

// import DataTypes :: *;

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
typedef Bit#(RDMA_MAX_LEN_WIDTH) Length;
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

typedef enum {
    RC  = 3'b000,
    UC  = 3'b001,
    RD  = 3'b010,
    UD  = 3'b011,
    CNP = 3'b100,
    XRC = 3'b101
} TransType deriving(Bits, Bounded);

typedef enum {
    SEND_FIRST = 5'h00,
    SEND_MIDDLE = 5'h01,
    SEND_LAST = 5'h02,
    SEND_LAST_WITH_IMMEDIATE = 5'h03,
    SEND_ONLY = 5'h04,
    SEND_ONLY_WITH_IMMEDIATE = 5'h05,
    RDMA_WRITE_FIRST = 5'h06,
    RDMA_WRITE_MIDDLE = 5'h07,
    RDMA_WRITE_LAST = 5'h08,
    RDMA_WRITE_LAST_WITH_IMMEDIATE = 5'h09,
    RDMA_WRITE_ONLY = 5'h0a,
    RDMA_WRITE_ONLY_WITH_IMMEDIATE = 5'h0b,
    RDMA_READ_REQUEST = 5'h0c,
    RDMA_READ_RESPONSE_FIRST = 5'h0d,
    RDMA_READ_RESPONSE_MIDDLE = 5'h0e,
    RDMA_READ_RESPONSE_LAST = 5'h0f,
    RDMA_READ_RESPONSE_ONLY = 5'h10,
    ACKNOWLEDGE = 5'h11,
    ATOMIC_ACKNOWLEDGE = 5'h12,
    COMPARE_SWAP = 5'h13,
    FETCH_ADD = 5'h14,
    RESYNC = 5'h15,
    SEND_LAST_WITH_INVALIDATE = 5'h16,
    SEND_ONLY_WITH_INVALIDATE = 5'h17
    // CNP = 5'h00, // TODO: check where to set CNP opcode
} RdmaOpCode deriving(Bits, Bounded, Eq);

typedef enum {
    ACK  = 2'b00,
    RNR  = 2'b01,
    RSVD = 2'b10,
    NAK  = 2'b11
} AethCode deriving(Bits, Bounded, Eq);

// Headers

// 12 bytes
typedef struct {
    TransType trans;
    RdmaOpCode opcode;
    Bool solicited;
    Bool migReq;
    PAD padCnt;
    ReservedZero#(4) tver;
    PKEY pkey;
    Bool fecn;
    Bool becn;
    ReservedZero#(6) resv6;
    QPN dqpn;
    Bool ackreq;
    ReservedZero#(7) resv7;
    PSN psn;
} BTH deriving(Bits, Bounded);

typedef SizeOf#(BTH) BTH_WIDTH;

// 4 bytes
typedef struct {
    ReservedZero#(1) rsvd;
    AethCode code;
    AethValue value;
    MSN msn;
} AETH deriving(Bits, Bounded);

typedef SizeOf#(AETH) AETH_WIDTH;

// 16 bytes
typedef struct {
    ADDR va;
    RKEY rkey;
    Length dlen;
} RETH deriving(Bits, Bounded);

typedef SizeOf#(RETH) RETH_WIDTH;

// 28 bytes
typedef struct {
    ADDR va;
    RKEY rkey;
    Long swap;
    Long comp;
} AtomicEth deriving(Bits, Bounded);

typedef SizeOf#(AtomicEth) ATOMIC_ETH_WIDTH;

// 8 byes
typedef struct {
    Long orig;
} AtomicAckEth deriving(Bits, Bounded);

typedef SizeOf#(AtomicAckEth) ATOMIC_ACK_ETH_WIDTH;

// 4 bytes
typedef struct {
    IMM data;
} ImmDt deriving(Bits, Bounded);

typedef SizeOf#(ImmDt) IMM_DT_WIDTH;

// 4 bytes
typedef struct {
    RKEY rkey;
} IETH deriving(Bits, Bounded);

typedef SizeOf#(IETH) IETH_WIDTH;

// 8 bytes
typedef struct {
    QKEY qkey;
    ReservedZero#(8) rsvd;
    QPN sqpn;
} DETH deriving(Bits, Bounded);

typedef SizeOf#(DETH) DETH_WIDTH;

// 4 bytes
typedef struct {
    ReservedZero#(8) rsvd;
    QPN srqn;
} XRCETH deriving(Bits, Bounded);

typedef SizeOf#(XRCETH) XRCETH_WIDTH;

// 16 bytes
typedef struct {
    ReservedZero#(LONG_WIDTH) rsvd1;
    ReservedZero#(LONG_WIDTH) rsvd2;
} CNPPadding deriving(Bits, Bounded);

typedef SizeOf#(CNPPadding) CNP_PADDING_WIDTH;

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
