import BRAM :: *;
import ClientServer :: *;
import Cntrs :: *;
import Connectable :: *;
import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Settings :: *;
import RdmaUtils :: *;

typedef enum {
    TAG_VEC_RECV_REQ,
    TAG_VEC_RESP_INSERT,
    TAG_VEC_RESP_REMOVE
} TagVecState deriving(Bits, Eq);

// MR related

typedef struct {
    ADDR laddr;
    Length len;
    FlagsType#(MemAccessTypeFlag) accFlags;
    HandlerPD pdHandler;
    KeyPartMR keyPart;
} MemRegion deriving(Bits, FShow);

typedef struct {
    Bool      allocOrNot;
    MemRegion mr;
    Bool      lkeyOrNot;
    LKEY      lkey;
    RKEY      rkey;
} ReqMR deriving(Bits, FShow);

typedef struct {
    Bool      successOrNot;
    MemRegion mr;
    LKEY      lkey;
    RKEY      rkey;
} RespMR deriving(Bits, FShow);

typedef Server#(ReqMR, RespMR) SrvPortMR;

function IndexMR key2IndexMR(Bit#(KEY_WIDTH) key) = unpack(truncateLSB(key));


