import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;

import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import PayloadGen :: *;
import PrimUtils :: *;
import Reserved :: *;
import Settings :: *;
import Utils :: *;

typedef struct {
    MAC    macAddr;
    IP     ipAddr;
    PktLen pktLen;
} PktInfo4UDP deriving(Bits, FShow);

typedef struct {
    HeaderData    headerData;
    HeaderByteNum headerLen;
    Bool          hasPayload;
    Bool          hasHeader;
} PktHeaderInfo deriving(Bits, FShow);

function PktHeaderInfo genPktHeaderInfo(
    HeaderData headerData, HeaderByteNum headerLen, Bool hasPayload
);
    return PktHeaderInfo {
        headerData: headerData,
        headerLen : headerLen,
        hasPayload: hasPayload,
        hasHeader : True
    };
endfunction

function PktHeaderInfo genEmptyPktHeaderInfo(Bool hasPayload);
    return PktHeaderInfo {
        headerData: dontCareValue,
        headerLen : 0,
        hasPayload: hasPayload,
        hasHeader : False
    };
endfunction

function Maybe#(RdmaOpCode) genFirstOrOnlyRdmaOpCode(WorkReqOpCode wrOpCode, Bool isOnlyReqPkt);
    return case (wrOpCode)
        IBV_WR_RDMA_WRITE          : tagged Valid (isOnlyReqPkt ? RDMA_WRITE_ONLY                : RDMA_WRITE_FIRST);
        IBV_WR_RDMA_WRITE_WITH_IMM : tagged Valid (isOnlyReqPkt ? RDMA_WRITE_ONLY_WITH_IMMEDIATE : RDMA_WRITE_FIRST);
        IBV_WR_SEND                : tagged Valid (isOnlyReqPkt ? SEND_ONLY                      : SEND_FIRST);
        IBV_WR_SEND_WITH_IMM       : tagged Valid (isOnlyReqPkt ? SEND_ONLY_WITH_IMMEDIATE       : SEND_FIRST);
        IBV_WR_SEND_WITH_INV       : tagged Valid (isOnlyReqPkt ? SEND_ONLY_WITH_INVALIDATE      : SEND_FIRST);
        IBV_WR_RDMA_READ_RESP      : tagged Valid (isOnlyReqPkt ? RDMA_READ_RESPONSE_ONLY        : RDMA_READ_RESPONSE_FIRST);
        IBV_WR_RDMA_READ           : tagged Valid RDMA_READ_REQUEST;
        IBV_WR_ATOMIC_CMP_AND_SWP  : tagged Valid COMPARE_SWAP;
        IBV_WR_ATOMIC_FETCH_AND_ADD: tagged Valid FETCH_ADD;
        default                    : tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaOpCode) genMiddleOrLastRdmaOpCode(WorkReqOpCode wrOpCode, Bool isLastReqPkt);
    return case (wrOpCode)
        IBV_WR_RDMA_WRITE         : tagged Valid (isLastReqPkt ? RDMA_WRITE_LAST                : RDMA_WRITE_MIDDLE);
        IBV_WR_RDMA_WRITE_WITH_IMM: tagged Valid (isLastReqPkt ? RDMA_WRITE_LAST_WITH_IMMEDIATE : RDMA_WRITE_MIDDLE);
        IBV_WR_SEND               : tagged Valid (isLastReqPkt ? SEND_LAST                      : SEND_MIDDLE);
        IBV_WR_SEND_WITH_IMM      : tagged Valid (isLastReqPkt ? SEND_LAST_WITH_IMMEDIATE       : SEND_MIDDLE);
        IBV_WR_SEND_WITH_INV      : tagged Valid (isLastReqPkt ? SEND_LAST_WITH_INVALIDATE      : SEND_MIDDLE);
        IBV_WR_RDMA_READ_RESP     : tagged Valid (isLastReqPkt ? RDMA_READ_RESPONSE_LAST        : RDMA_READ_RESPONSE_MIDDLE);
        default                   : tagged Invalid;
    endcase;
endfunction

function Maybe#(XRCETH) genXRCETH(WorkQueueElem wqe);
    return case (wqe.qpType)
        IBV_QPT_XRC_SEND: tagged Valid XRCETH {
            srqn: unwrapMaybe(wqe.srqn),
            rsvd: unpack(0)
        };
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(DETH) genDETH(WorkQueueElem wqe);
    return case (wqe.qpType)
        IBV_QPT_UD: tagged Valid DETH {
            qkey: unwrapMaybe(wqe.qkey),
            sqpn: wqe.sqpn,
            rsvd: unpack(0)
        };
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(RETH) genRETH(
    WorkReqOpCode wrOpCode, ADDR raddr, RKEY rkey, Length dlen
);
    return case (wrOpCode)
        IBV_WR_RDMA_WRITE         ,
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_RDMA_READ          : tagged Valid RETH {
            va  : raddr,
            rkey: rkey,
            dlen: dlen
        };
        default                   : tagged Invalid;
    endcase;
endfunction

function Maybe#(LETH) genLETH(WorkQueueElem wqe, Length dlen);
    let firstIdxSGE = 0;
    return case (wqe.opcode)
        IBV_WR_RDMA_READ: tagged Valid LETH {
            va  : wqe.sgl[firstIdxSGE].laddr,
            lkey: wqe.sgl[firstIdxSGE].lkey,
            dlen: dlen
        };
        default         : tagged Invalid;
    endcase;
endfunction

// TODO: check fetch add needs both swap and comp?
function Maybe#(AtomicEth) genAtomicEth(WorkQueueElem wqe);
    if (wqe.swap matches tagged Valid .swap &&& wqe.comp matches tagged Valid .comp) begin
        return case (wqe.opcode)
            IBV_WR_ATOMIC_CMP_AND_SWP  ,
            IBV_WR_ATOMIC_FETCH_AND_ADD: tagged Valid AtomicEth {
                va  : wqe.raddr,
                rkey: wqe.rkey,
                swap: swap,
                comp: comp
            };
            default                    : tagged Invalid;
        endcase;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(ImmDt) genImmDt(WorkQueueElem wqe);
    case (wqe.opcode)
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_SEND_WITH_IMM      :
            if (
                wqe.immDtOrInvRKey matches tagged Valid .immDtOrInvRKey &&&
                immDtOrInvRKey     matches tagged Imm   .immDt
            ) begin
                return tagged Valid ImmDt {
                    data: immDt
                };
            end
            else begin
                return tagged Invalid;
            end
        default                   : return tagged Invalid;
    endcase
endfunction

function Maybe#(IETH) genIETH(WorkQueueElem wqe);
    if (
        wqe.immDtOrInvRKey matches tagged Valid .immDtOrInvRKey &&&
        immDtOrInvRKey     matches tagged RKey  .rkey2Inv       &&&
        wqe.opcode == IBV_WR_SEND_WITH_INV
    ) begin
        return tagged Valid IETH {
            rkey: rkey2Inv
        };
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(PktHeaderInfo) genFirstOrOnlyPktHeader(
    WorkQueueElem wqe, Bool isOnlyReqPkt, Bool solicited, PSN psn, PAD padCnt,
    Bool ackReq, ADDR remoteAddr, Length dlen, Bool hasPayload
);
    let maybeTrans  = qpType2TransType(wqe.qpType);
    let maybeOpCode = genFirstOrOnlyRdmaOpCode(wqe.opcode, isOnlyReqPkt);

    let isReadOrAtomicWR = isReadOrAtomicWorkReq(wqe.opcode);
    if (
        maybeTrans  matches tagged Valid .trans  &&&
        maybeOpCode matches tagged Valid .opcode
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: isOnlyReqPkt && solicited,
            migReq   : unpack(0),
            padCnt   : padCnt,
            tver     : unpack(0),
            pkey     : dontCareValue, // wqe.pkey,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : wqe.dqpn,
            ackReq   : isOnlyReqPkt && ackReq,
            resv7    : unpack(0),
            psn      : psn
        };

        let xrceth = genXRCETH(wqe);
        let deth = genDETH(wqe);
        let reth = genRETH(wqe.opcode, remoteAddr, wqe.rkey, dlen);
        let leth = genLETH(wqe, dlen);
        let atomicEth = genAtomicEth(wqe);
        let immDt = genImmDt(wqe);
        let ieth = genIETH(wqe);

        // If WR has zero length, then no payload, no matter what kind of opcode
        // let hasPayload = workReqHasPayload(wr);
        case (wqe.opcode)
            IBV_WR_RDMA_WRITE: begin
                return case (wqe.qpType)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_WRITE_WITH_IMM: begin
                return case (wqe.qpType)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid genPktHeaderInfo(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)), pack(unwrapMaybe(immDt))}) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth))}),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genPktHeaderInfo(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(reth)), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(reth)) }),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND: begin
                return case (wqe.qpType)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB(pack(bth)),
                        fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_UD: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(deth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(DETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_IMM: begin
                return case (wqe.qpType)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid genPktHeaderInfo(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB(pack(bth)),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_UD: tagged Valid genPktHeaderInfo(
                        // UD always has only pkt
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(deth)), pack(unwrapMaybe(immDt)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(DETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genPktHeaderInfo(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)) }),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_INV: begin
                return case (wqe.qpType)
                    IBV_QPT_RC: tagged Valid genPktHeaderInfo(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(ieth)) }) :
                            zeroExtendLSB(pack(bth)),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genPktHeaderInfo(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(ieth)) }) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)) }),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_READ: begin
                return case (wqe.qpType)
                    IBV_QPT_RC: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)), pack(unwrapMaybe(leth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        False // Read requests have no payload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(reth)), pack(unwrapMaybe(leth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        False // Read requests have no payload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_ATOMIC_CMP_AND_SWP  ,
            IBV_WR_ATOMIC_FETCH_AND_ADD: begin
                return case (wqe.qpType)
                    IBV_QPT_RC: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(atomicEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(ATOMIC_ETH_BYTE_WIDTH)),
                        False // Atomic requests have no payload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(atomicEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(ATOMIC_ETH_BYTE_WIDTH)),
                        False // Atomic requests have no payload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_READ_RESP: begin
                return case (wqe.qpType)
                    IBV_QPT_RC      ,
                    IBV_QPT_XRC_SEND,
                    IBV_QPT_XRC_RECV: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default         : tagged Invalid;
                endcase;
            end
            default: return tagged Invalid;
        endcase
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(PktHeaderInfo) genMiddleOrLastPktHeader(
    WorkQueueElem wqe, Bool isLastReqPkt, Bool solicited, PSN psn,
    PAD padCnt, Bool ackReq, ADDR remoteAddr, PktLen pktLen // , Bool hasPayload
);
    let maybeTrans  = qpType2TransType(wqe.qpType);
    let maybeOpCode = genMiddleOrLastRdmaOpCode(wqe.opcode, isLastReqPkt);

    if (
        maybeTrans  matches tagged Valid .trans  &&&
        maybeOpCode matches tagged Valid .opcode
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: isLastReqPkt && solicited,
            migReq   : unpack(0),
            padCnt   : padCnt,
            tver     : unpack(0),
            pkey     : dontCareValue, // wqe.pkey,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : wqe.dqpn,
            ackReq   : isLastReqPkt && ackReq,
            resv7    : unpack(0),
            psn      : psn
        };

        Length dlen = zeroExtend(pktLen);
        let xrceth = genXRCETH(wqe);
        let reth = genRETH(wqe.opcode, remoteAddr, wqe.rkey, dlen);
        let immDt = genImmDt(wqe);
        let ieth = genIETH(wqe);

        let hasPayload = True;
        case (wqe.opcode)
            IBV_WR_RDMA_WRITE:begin
                return case (wqe.qpType)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_WRITE_WITH_IMM: begin
                return case (wqe.qpType)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid genPktHeaderInfo(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)), pack(unwrapMaybe(immDt))}) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)) }),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genPktHeaderInfo(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(reth)), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(reth)) }),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND: begin
                return case (wqe.qpType)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB(pack(bth)),
                        fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_IMM: begin
                return case (wqe.qpType)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid genPktHeaderInfo(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB(pack(bth)),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genPktHeaderInfo(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)) }),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_INV: begin
                return case (wqe.qpType)
                    IBV_QPT_RC: tagged Valid genPktHeaderInfo(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(ieth)) }) :
                            zeroExtendLSB(pack(bth)),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genPktHeaderInfo(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(ieth)) }) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)) }),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_READ_RESP: begin
                return case (wqe.qpType)
                    IBV_QPT_RC      ,
                    IBV_QPT_XRC_SEND,
                    IBV_QPT_XRC_RECV: tagged Valid genPktHeaderInfo(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default         : tagged Invalid;
                endcase;
            end
            default: return tagged Invalid;
        endcase
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Bool workReqNeedPayloadGen(WorkReqOpCode opcode);
    return case (opcode)
        IBV_WR_RDMA_WRITE         ,
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_SEND               ,
        IBV_WR_SEND_WITH_IMM      ,
        IBV_WR_SEND_WITH_INV      ,
        IBV_WR_RDMA_READ_RESP     : True;
        default                   : False;
    endcase;
endfunction

typedef TMul#(32, 1024) WQE_SLICE_MAX_SIZE; // 32KB

typedef struct {
    ADDR   remoteAddr;
    Length totalLen;
    PSN    curPSN;
    PktLen pktLen;
    PAD    padCnt;
    Bool   hasPayload;
    Bool   ackReq;
    Bool   solicited;
    Bool   isFirstPkt;
    Bool   isLastPkt;
    Bool   isOnlyPkt;
    Bool   qpRawPkt;
} HeaderGenInfo deriving(Bits, FShow);

typedef struct {
    ReservedZero#(0) rsvd;
} SendResp deriving(Bits, FShow);

interface SendQ;
    interface Server#(WorkQueueElem, SendResp) srvPort;
    interface PipeOut#(PktInfo4UDP) udpInfoPipeOut;
    interface DataStreamPipeOut rdmaDataStreamPipeOut;
    method Bool isEmpty();
endinterface

module mkSendQ#(
    Bool clearAll,
    PayloadGenerator payloadGenerator
)(SendQ);
    FIFOF#(WorkQueueElem)         reqQ <- mkFIFOF;
    FIFOF#(SendResp)             respQ <- mkFIFOF;
    FIFOF#(PktInfo4UDP) udpPktInfoOutQ <- mkFIFOF;

    // Pipeline FIFOF
    FIFOF#(Tuple3#(WorkQueueElem, Bool, Bool)) totalMetaDataQ <- mkFIFOF;
    FIFOF#(Tuple7#(WorkQueueElem, Length, PktNum, Bool, Bool, Bool, Bool)) psnUpdateQ <- mkFIFOF;
    FIFOF#(Tuple2#(WorkQueueElem, HeaderGenInfo)) headerPrepareQ <- mkFIFOF;
    FIFOF#(Tuple6#(MAC, IP, Maybe#(PktHeaderInfo), PktLen, Bool, Bool)) pendingHeaderQ <- mkFIFOF;
    FIFOF#(HeaderRDMA) pktHeaderQ <- mkFIFOF;

    Reg#(PSN)       curPsnReg <- mkRegU;
    Reg#(Bool) wqeFirstPktReg <- mkRegU;

    let headerDataStreamAndMetaDataPipeOut <- mkHeader2DataStream(
        clearAll, toPipeOut(pktHeaderQ)
    );
    let rdmaPktDataStreamPipeOut <- mkPrependHeader2PipeOut(
        clearAll,
        headerDataStreamAndMetaDataPipeOut.headerDataStream,
        headerDataStreamAndMetaDataPipeOut.headerMetaData,
        payloadGenerator.payloadDataStreamPipeOut
    );

    rule resetAndClear if (clearAll);
        reqQ.clear;
        respQ.clear;
        udpPktInfoOutQ.clear;

        totalMetaDataQ.clear;
        psnUpdateQ.clear;
        headerPrepareQ.clear;
        pendingHeaderQ.clear;
        pktHeaderQ.clear;

        wqeFirstPktReg <= True;
        // $display("time=%0t: reset and clear mkSendQ", $time);
    endrule

    (* conflict_free = "recvWQE, \
                        recvTotalMetaData, \
                        updatePSN, \
                        prepareHeader, \
                        genPktHeader" *)
    rule recvWQE if (!clearAll);
        let wqe = reqQ.first;
        reqQ.deq;

        let qpType = wqe.qpType;
        let shouldAddPadding = qpType != IBV_QPT_RAW_PACKET;
        immAssert(
            qpType == IBV_QPT_RC       ||
            qpType == IBV_QPT_XRC_RECV ||
            qpType == IBV_QPT_XRC_SEND ||
            qpType == IBV_QPT_UC       ||
            qpType == IBV_QPT_UD       ||
            qpType == IBV_QPT_RAW_PACKET,
            "qpType assertion @ mkSendQ",
            $format(
                "qpType=", fshow(qpType), " unsupported"
            )
        );

        let sgeIdx = 0;
        let firstSGE = wqe.sgl[sgeIdx];
        let lenFirstSGE = firstSGE.len;
        if (isAtomicWorkReq(wqe.opcode)) begin
            immAssert(
                lenFirstSGE == fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)),
                "atomic length assertion @ mkSendQ",
                $format(
                    "lenFirstSGE=%0d", lenFirstSGE,
                    " should be %0d for atomic WQE", valueOf(ATOMIC_WORK_REQ_LEN)
                )
            );
        end
        if (isZeroR(lenFirstSGE)) begin
            immAssert(
                wqe.isFirst && wqe.isLast && firstSGE.isFirst && firstSGE.isLast,
                "zero length assertion @ mkSendQ",
                $format(
                    "wqe.isFirst=", fshow(wqe.isFirst),
                    ", wqe.isLast=", fshow(wqe.isLast),
                    ", firstSGE.isFirst=", fshow(firstSGE.isFirst),
                    ", firstSGE.isLast=", fshow(firstSGE.isLast),
                    " should be all true when lenFirstSGE=%0d", lenFirstSGE
                )
            );
        end

        let hasImmDt = workReqHasImmDt(wqe.opcode);
        let hasInv   = workReqHasInv(wqe.opcode);
        let hasComp  = workReqHasComp(wqe.opcode);
        let hasSwap  = workReqHasSwap(wqe.opcode);
        if (hasComp) begin
            immAssert(
                isValid(wqe.comp),
                "hasComp assertion @ mkSendQ",
                $format(
                    "wqe.comp=", fshow(wqe.comp),
                    " should be valid when wqe.opcode=", fshow(wqe.opcode)
                )
            );
        end
        if (hasSwap) begin
            immAssert(
                isValid(wqe.swap),
                "hasSwap assertion @ mkSendQ",
                $format(
                    "wqe.swap=", fshow(wqe.swap),
                    " should be valid when wqe.opcode=", fshow(wqe.opcode)
                )
            );
        end
        if (hasImmDt) begin
            immAssert(
                isValid(wqe.immDtOrInvRKey),
                "hasImmDt assertion @ mkSendQ",
                $format(
                    "wqe.immDtOrInvRKey=", fshow(wqe.immDtOrInvRKey),
                    " should be valid when wqe.opcode=", fshow(wqe.opcode)
                )
            );
            let immDtOrInvRKey = unwrapMaybe(wqe.immDtOrInvRKey);
            // TODO: check immDtOrInvRKey is Imm
        end
        if (hasInv) begin
            immAssert(
                isValid(wqe.immDtOrInvRKey),
                "hasInv assertion @ mkSendQ",
                $format(
                    "wqe.immDtOrInvRKey=", fshow(wqe.immDtOrInvRKey),
                    " should be valid when wqe.opcode=", fshow(wqe.opcode)
                )
            );
            let immDtOrInvRKey = unwrapMaybe(wqe.immDtOrInvRKey);
            // TODO: check immDtOrInvRKey is RKey
        end

        let qpRawPkt = isRawPktTypeQP(wqe.qpType);
        let isSendWR = isSendWorkReq(wqe.opcode);
        let shouldGenPayload = qpRawPkt || workReqNeedPayloadGen(wqe.opcode);

        let remoteAddr = wqe.raddr;
        if (qpRawPkt || isSendWR) begin
            remoteAddr = 0;
        end
        if (shouldGenPayload) begin
            let payloadGenReq = PayloadGenReqSG {
                wrID      : wqe.id,
                sqpn      : wqe.sqpn,
                sgl       : wqe.sgl,
                totalLen  : wqe.totalLen,
                raddr     : remoteAddr,
                pmtu      : wqe.pmtu,
                addPadding: shouldAddPadding
            };
            payloadGenerator.srvPort.request.put(payloadGenReq);
        end
        totalMetaDataQ.enq(tuple3(wqe, qpRawPkt, shouldGenPayload));
        // TODO: handle pending read/atomic request number limit

        // $display(
        //     "time=%0t: mkSendQ 1st stage recvWQE", $time,
        //     ", sqpn=%h", wqe.sqpn,
        //     ", id=%h", wqe.id,
        //     ", macAddr=%h", wqe.macAddr,
        //     ", pmtu=", fshow(wqe.pmtu),
        //     ", shouldGenPayload=", fshow(shouldGenPayload)
        // );
    endrule

    rule recvTotalMetaData if (!clearAll);
        let { wqe, qpRawPkt, shouldGenPayload } = totalMetaDataQ.first;
        totalMetaDataQ.deq;

        let sglZeroIdx  = 0;
        let hasPayload  =  shouldGenPayload;
        let isOnlyPkt   = !shouldGenPayload;
        let totalLen    = wqe.totalLen; // wqe.sgl[sglZeroIdx].len;
        let totalPktNum = 1;

        if (!wqe.isFirst && !wqe.isLast) begin
            immAssert(
                !isOnlyPkt &&
                totalLen == fromInteger(valueOf(WQE_SLICE_MAX_SIZE)),
                "wqe slice length assertion @ mkSendQ",
                $format(
                    "totalLen=%0d", totalLen,
                    " should == WQE_SLICE_MAX_SIZE=%0d", valueOf(WQE_SLICE_MAX_SIZE),
                    ", and isOnlyPkt=", fshow(isOnlyPkt),
                    " should be false when wqe.isFirst=", fshow(wqe.isFirst),
                    " and wqe.isLast=", fshow(wqe.isLast)
                )
            );
        end
        else if (!wqe.isFirst && wqe.isLast) begin
            immAssert(
                fromInteger(valueOf(WQE_SLICE_MAX_SIZE)) >= totalLen,
                "wqe slice length assertion @ mkSendQ",
                $format(
                    "totalLen=%0d", totalLen,
                    " should be no more than WQE_SLICE_MAX_SIZE=%0d", valueOf(WQE_SLICE_MAX_SIZE),
                    " when wqe.isFirst=", fshow(wqe.isFirst),
                    " and wqe.isLast=", fshow(wqe.isLast)
                )
            );
        end

        if (shouldGenPayload) begin
            let payloadTotalMetaData = payloadGenerator.totalMetaDataPipeOut.first;
            payloadGenerator.totalMetaDataPipeOut.deq;

            hasPayload  = !payloadTotalMetaData.isZeroPayloadLen;
            isOnlyPkt   =  payloadTotalMetaData.isOnlyPkt;
            // totalLen    =  payloadTotalMetaData.totalLen;
            totalPktNum =  payloadTotalMetaData.totalPktNum;
        end
        psnUpdateQ.enq(tuple7(
            wqe, totalLen, totalPktNum, shouldGenPayload, hasPayload, isOnlyPkt, qpRawPkt
        ));
        // $display(
        //     "time=%0t: mkSendQ 2nd stage recvTotalMetaData", $time,
        //     ", sqpn=%h", wqe.sqpn,
        //     ", id=%h", wqe.id,
        //     ", psn=%h", wqe.psn,
        //     ", totalLen=%0d", totalLen,
        //     ", totalPktNum=%0d", totalPktNum,
        //     ", qpRawPkt=", fshow(qpRawPkt),
        //     ", hasPayload=", fshow(hasPayload),
        //     ", isOnlyPkt=", fshow(isOnlyPkt),
        //     ", shouldGenPayload=", fshow(shouldGenPayload)
        // );
    endrule

    rule updatePSN if (!clearAll);
        let {
            wqe, totalLen, totalPktNum, shouldGenPayload, hasPayload, isOnlyPkt, qpRawPkt
        } = psnUpdateQ.first;

        let curPSN = curPsnReg;
        if (wqeFirstPktReg) begin
            curPSN = wqe.psn;
        end
        curPsnReg <= curPSN + 1;

        let remoteAddr = wqe.raddr;
        let pktPayloadLen = 0;
        let padCnt = 0;
        let wqeLastPkt = isOnlyPkt;
        if (shouldGenPayload) begin
            let payloadGenResp <- payloadGenerator.srvPort.response.get;
            remoteAddr    = payloadGenResp.raddr;
            pktPayloadLen = payloadGenResp.pktLen;
            padCnt        = payloadGenResp.padCnt;
            wqeLastPkt    = payloadGenResp.isLast;
        end
        wqeFirstPktReg <= wqeLastPkt;

        if (wqeLastPkt) begin
            psnUpdateQ.deq;
        end

        let isFirstPkt = wqeFirstPktReg && wqe.isFirst;
        let isLastPkt  = wqeLastPkt && wqe.isLast;
        if (!isLastPkt) begin
            immAssert(
                !isOnlyPkt,
                "isOnlyPkt assertion @ mkSendQ",
                $format(
                    "isOnlyPkt=", fshow(isOnlyPkt),
                    " should be false when wqe.isFirstPkt=", fshow(isFirstPkt),
                    " and wqe.isLastPkt=", fshow(isLastPkt)
                )
            );
        end
        if (isFirstPkt && isLastPkt) begin
            immAssert(
                isOnlyPkt,
                "isOnlyPkt assertion @ mkSendQ",
                $format(
                    "isOnlyPkt=", fshow(isOnlyPkt),
                    " should be true when wqe.isFirstPkt=", fshow(isFirstPkt),
                    " and wqe.isLastPkt=", fshow(isLastPkt)
                )
            );
        end

        if (qpRawPkt) begin
            immAssert(
                hasPayload && isZero(padCnt),
                "qpRawPkt assertion @ mkSendQ",
                $format(
                    "hasPayload=", fshow(hasPayload),
                    " should be true, and pacCnt=%0d", padCnt,
                    " should be zero when qpRawPkt=", fshow(qpRawPkt),
                    " and wqe.qpType=", fshow(wqe.qpType)
                )
            );
        end

        let ackReq = containWorkReqFlag(wqe.flags, IBV_SEND_SIGNALED);
        let solicited = containWorkReqFlag(wqe.flags, IBV_SEND_SOLICITED);
        let headerGenInfo = HeaderGenInfo {
            remoteAddr: remoteAddr,
            totalLen  : totalLen,
            curPSN    : curPSN,
            pktLen    : pktPayloadLen,
            padCnt    : padCnt,
            hasPayload: hasPayload,
            ackReq    : ackReq,
            solicited : solicited,
            isFirstPkt: isFirstPkt,
            isLastPkt : isLastPkt,
            isOnlyPkt : isOnlyPkt,
            qpRawPkt  : qpRawPkt
        };
        headerPrepareQ.enq(tuple2(wqe, headerGenInfo));
        // $display(
        //     "time=%0t: mkSendQ 3th stage updatePSN", $time,
        //     ", sqpn=%h", wqe.sqpn,
        //     ", id=%h", wqe.id,
        //     ", curPSN=%h", curPSN,
        //     ", pktPayloadLen=%0d", pktPayloadLen,
        //     ", padCnt=%0d", padCnt,
        //     ", hasPayload=", fshow(hasPayload),
        //     ", isFirstPkt=", fshow(isFirstPkt),
        //     ", isLastPkt=", fshow(isLastPkt),
        //     ", isOnlyPkt=", fshow(isOnlyPkt)
        // );
    endrule

    rule prepareHeader if (!clearAll);
        let { wqe, headerGenInfo } = headerPrepareQ.first;
        headerPrepareQ.deq;

        let remoteAddr    = headerGenInfo.remoteAddr;
        let totalLen      = headerGenInfo.totalLen;
        let curPSN        = headerGenInfo.curPSN;
        let pktPayloadLen = headerGenInfo.pktLen;
        let padCnt        = headerGenInfo.padCnt;
        let hasPayload    = headerGenInfo.hasPayload;
        let ackReq        = headerGenInfo.ackReq;
        let solicited     = headerGenInfo.solicited;
        let isFirstPkt    = headerGenInfo.isFirstPkt;
        let isLastPkt     = headerGenInfo.isLastPkt;
        let isOnlyPkt     = headerGenInfo.isOnlyPkt;
        let qpRawPkt      = headerGenInfo.qpRawPkt;

        let maybePktHeaderInfo = dontCareValue;
        if (qpRawPkt) begin
            maybePktHeaderInfo = tagged Valid genEmptyPktHeaderInfo(hasPayload);
        end
        else if (isFirstPkt) begin
            let maybeFirstOrOnlyPktHeaderInfo = genFirstOrOnlyPktHeader(
                wqe, isOnlyPkt, solicited, curPSN, padCnt,
                ackReq, remoteAddr, totalLen, hasPayload
            );
            immAssert(
                isValid(maybeFirstOrOnlyPktHeaderInfo),
                "maybeFirstOrOnlyPktHeaderInfo assertion @ mkSendQ",
                $format(
                    "maybeFirstOrOnlyPktHeaderInfo=", fshow(maybeFirstOrOnlyPktHeaderInfo),
                    " is not valid, and current WQE=", fshow(wqe)
                )
            );

            maybePktHeaderInfo = maybeFirstOrOnlyPktHeaderInfo;
        end
        else begin
            let maybeMiddleOrLastPktHeaderInfo = genMiddleOrLastPktHeader(
                wqe, isLastPkt, solicited, curPSN, padCnt,
                ackReq, remoteAddr, pktPayloadLen
            );
            immAssert(
                isValid(maybeMiddleOrLastPktHeaderInfo),
                "maybeMiddleOrLastPktHeaderInfo assertion @ mkSendQ",
                $format(
                    "maybeMiddleOrLastPktHeaderInfo=", fshow(maybeMiddleOrLastPktHeaderInfo),
                    " is not valid, and current WQE=", fshow(wqe)
                )
            );

            maybePktHeaderInfo = maybeMiddleOrLastPktHeaderInfo;
        end

        let pktLenWithPadCnt = pktPayloadLen + zeroExtend(padCnt);
        PAD zeroPad = truncate(pktLenWithPadCnt);
        immAssert(
            isZero(zeroPad),
            "zeroPad assertion @ mkSendQ",
            $format(
                "zeroPad=%0d", zeroPad,
                " should be zero, when padCnt=%0d", padCnt,
                ", pktPayloadLen=%0d", pktPayloadLen,
                " and pktLenWithPadCnt=%0d", pktLenWithPadCnt
            )
        );

        let isSendDone = isOnlyPkt || isLastPkt;
        pendingHeaderQ.enq(tuple6(
            wqe.macAddr, wqe.dqpIP, maybePktHeaderInfo, pktLenWithPadCnt, qpRawPkt, isSendDone
        ));
        // $display(
        //     "time=%0t: mkSendQ 4th stage prepareHeader", $time,
        //     ", sqpn=%h", wqe.sqpn,
        //     ", id=%h", wqe.id,
        //     ", curPSN=%h", curPSN,
        //     ", isFirstPkt=", fshow(isFirstPkt),
        //     ", isLastPkt=", fshow(isLastPkt),
        //     ", isOnlyPkt=", fshow(isOnlyPkt),
        //     ", isValid(maybePktHeaderInfo)=", fshow(isValid(maybePktHeaderInfo)),
        //     ", hasPayload=", fshow(hasPayload)
        // );
    endrule

    rule genPktHeader if (!clearAll);
        let {
            macAddr, ipAddr, maybePktHeaderInfo, pktLenWithPadCnt, qpRawPkt, isSendDone
        } = pendingHeaderQ.first;
        pendingHeaderQ.deq;

        if (maybePktHeaderInfo matches tagged Valid .pktHeaderInfo) begin
            let headerData = pktHeaderInfo.headerData;
            let headerLen  = pktHeaderInfo.headerLen;
            let hasPayload = pktHeaderInfo.hasPayload;
            let pktHeader  = qpRawPkt ?
                genEmptyHeaderRDMA(hasPayload) :
                genHeaderRDMA(headerData, headerLen, hasPayload);

            let udpPktInfo = PktInfo4UDP {
                macAddr: macAddr,
                ipAddr : ipAddr,
                pktLen : pktLenWithPadCnt + zeroExtend(headerLen)
            };

            pktHeaderQ.enq(pktHeader);
            udpPktInfoOutQ.enq(udpPktInfo);
            if (isSendDone) begin
                let sendResp = SendResp {
                    rsvd: unpack(0)
                };
                respQ.enq(sendResp);
            end
            // $display(
            //     "time=%0t: mkSendQ 5th stage genPktHeader", $time,
            //     // ", sqpn=%h", wqe.sqpn,
            //     // ", id=%h", wqe.id,
            //     ", pktLenWithPadCnt=%0d", pktLenWithPadCnt,
            //     ", headerLen=%0d", headerLen,
            //     ", udpPktInfo.macAddr=%h", udpPktInfo.macAddr,
            //     ", udpPktInfo.ipAddr=", fshow(udpPktInfo.ipAddr),
            //     ", udpPktInfo.pktLen=%0d", udpPktInfo.pktLen,
            //     ", hasPayload=", fshow(hasPayload)
            // );
        end
    endrule

    interface srvPort = toGPServer(reqQ, respQ);
    interface rdmaDataStreamPipeOut = rdmaPktDataStreamPipeOut;
    interface udpInfoPipeOut = toPipeOut(udpPktInfoOutQ);
    method Bool isEmpty() = !(
        reqQ.notEmpty           ||
        respQ.notEmpty          ||
        udpPktInfoOutQ.notEmpty ||
        totalMetaDataQ.notEmpty ||
        psnUpdateQ.notEmpty     ||
        headerPrepareQ.notEmpty ||
        pendingHeaderQ.notEmpty ||
        pktHeaderQ.notEmpty
    );
endmodule

interface SQ;
    interface DmaReadClt dmaReadClt;
    interface SendQ sendQ;
    method Action clearAll();
endinterface

(* synthesize *)
module mkSQ(SQ);
    FIFOF#(DmaReadReq)   dmaReadReqQ <- mkFIFOF;
    FIFOF#(DmaReadResp) dmaReadRespQ <- mkFIFOF;

    Reg#(Bool) clearReg <- mkReg(False);

    let dmaReadSrv = toGPServer(dmaReadReqQ, dmaReadRespQ);
    let dmaReadCntrl <- mkDmaReadCntrl(clearReg, dmaReadSrv);

    let payloadGenerator <- mkPayloadGenerator(clearReg, dmaReadCntrl);
    let sq <- mkSendQ(clearReg, payloadGenerator);

    rule resetAndClear if (clearReg);
        clearReg <= False;
    endrule

    interface dmaReadClt = toGPClient(dmaReadReqQ, dmaReadRespQ);
    interface sendQ = sq;

    method Action clearAll if (!clearReg);
        clearReg <= True;
    endmethod
endmodule
