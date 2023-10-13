import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;

import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
import Utils :: *;

function Maybe#(QPN) getMaybeDestQpnSQ(WorkReq wr, CntrlStatus cntrlStatus);
    return case (cntrlStatus.getTypeQP)
        IBV_QPT_RC      ,
        IBV_QPT_UC      ,
        IBV_QPT_XRC_SEND: tagged Valid cntrlStatus.comm.getDQPN;
        IBV_QPT_UD      : wr.dqpn;
        default         : tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaOpCode) genFirstOrOnlyReqRdmaOpCode(WorkReqOpCode wrOpCode, Bool isOnlyReqPkt);
    return case (wrOpCode)
        IBV_WR_RDMA_WRITE          : tagged Valid (isOnlyReqPkt ? RDMA_WRITE_ONLY                : RDMA_WRITE_FIRST);
        IBV_WR_RDMA_WRITE_WITH_IMM : tagged Valid (isOnlyReqPkt ? RDMA_WRITE_ONLY_WITH_IMMEDIATE : RDMA_WRITE_FIRST);
        IBV_WR_SEND                : tagged Valid (isOnlyReqPkt ? SEND_ONLY                      : SEND_FIRST);
        IBV_WR_SEND_WITH_IMM       : tagged Valid (isOnlyReqPkt ? SEND_ONLY_WITH_IMMEDIATE       : SEND_FIRST);
        IBV_WR_SEND_WITH_INV       : tagged Valid (isOnlyReqPkt ? SEND_ONLY_WITH_INVALIDATE      : SEND_FIRST);
        IBV_WR_RDMA_READ           : tagged Valid RDMA_READ_REQUEST;
        IBV_WR_ATOMIC_CMP_AND_SWP  : tagged Valid COMPARE_SWAP;
        IBV_WR_ATOMIC_FETCH_AND_ADD: tagged Valid FETCH_ADD;
        default                    : tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaOpCode) genMiddleOrLastReqRdmaOpCode(WorkReqOpCode wrOpCode, Bool isLastReqPkt);
    return case (wrOpCode)
        IBV_WR_RDMA_WRITE         : tagged Valid (isLastReqPkt ? RDMA_WRITE_LAST                : RDMA_WRITE_MIDDLE);
        IBV_WR_RDMA_WRITE_WITH_IMM: tagged Valid (isLastReqPkt ? RDMA_WRITE_LAST_WITH_IMMEDIATE : RDMA_WRITE_MIDDLE);
        IBV_WR_SEND               : tagged Valid (isLastReqPkt ? SEND_LAST                      : SEND_MIDDLE);
        IBV_WR_SEND_WITH_IMM      : tagged Valid (isLastReqPkt ? SEND_LAST_WITH_IMMEDIATE       : SEND_MIDDLE);
        IBV_WR_SEND_WITH_INV      : tagged Valid (isLastReqPkt ? SEND_LAST_WITH_INVALIDATE      : SEND_MIDDLE);
        default                   : tagged Invalid;
    endcase;
endfunction

function Maybe#(XRCETH) genXRCETH(WorkReq wr, CntrlStatus cntrlStatus);
    return case (cntrlStatus.getTypeQP)
        IBV_QPT_XRC_SEND: tagged Valid XRCETH {
            srqn: unwrapMaybe(wr.srqn),
            rsvd: unpack(0)
        };
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(DETH) genDETH(WorkReq wr, CntrlStatus cntrlStatus);
    return case (cntrlStatus.getTypeQP)
        IBV_QPT_UD: tagged Valid DETH {
            qkey: unwrapMaybe(wr.qkey),
            sqpn: cntrlStatus.comm.getSQPN,
            rsvd: unpack(0)
        };
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(RETH) genRETH(WorkReq wr);
    return case (wr.opcode)
        IBV_WR_RDMA_WRITE         ,
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_RDMA_READ          : tagged Valid RETH {
            va: wr.raddr,
            rkey: wr.rkey,
            dlen: wr.len
        };
        default                   : tagged Invalid;
    endcase;
endfunction

function Maybe#(AtomicEth) genAtomicEth(WorkReq wr);
    if (wr.swap matches tagged Valid .swap &&& wr.comp matches tagged Valid .comp) begin
        return case (wr.opcode)
            IBV_WR_ATOMIC_CMP_AND_SWP  ,
            IBV_WR_ATOMIC_FETCH_AND_ADD: tagged Valid AtomicEth {
                va: wr.raddr,
                rkey: wr.rkey,
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

function Maybe#(ImmDt) genImmDt(WorkReq wr);
    return case (wr.opcode)
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_SEND_WITH_IMM      : tagged Valid ImmDt {
            data: unwrapMaybe(wr.immDt)
        };
        default                   : tagged Invalid;
    endcase;
endfunction

function Maybe#(IETH) genIETH(WorkReq wr);
    return case (wr.opcode)
        IBV_WR_SEND_WITH_INV: tagged Valid IETH {
            rkey: unwrapMaybe(wr.rkey2Inv)
        };
        default             : tagged Invalid;
    endcase;
endfunction

function Maybe#(Tuple3#(HeaderData, HeaderByteNum, Bool)) genFirstOrOnlyReqHeader(
    WorkReq wr, CntrlStatus cntrlStatus, PSN psn, Bool isOnlyReqPkt
);
    let maybeTrans  = qpType2TransType(cntrlStatus.getTypeQP);
    let maybeOpCode = genFirstOrOnlyReqRdmaOpCode(wr.opcode, isOnlyReqPkt);
    let maybeDQPN   = getMaybeDestQpnSQ(wr, cntrlStatus);

    let isReadOrAtomicWR = isReadOrAtomicWorkReq(wr.opcode);
    if (
        maybeTrans  matches tagged Valid .trans  &&&
        maybeOpCode matches tagged Valid .opcode &&&
        maybeDQPN   matches tagged Valid .dqpn
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: wr.solicited,
            migReq   : unpack(0),
            padCnt   : (isOnlyReqPkt && !isReadOrAtomicWR) ? calcPadCnt(wr.len) : 0,
            tver     : unpack(0),
            pkey     : cntrlStatus.comm.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : dqpn,
            ackReq   : cntrlStatus.comm.getSigAll || (isOnlyReqPkt && workReqRequireAck(wr)),
            resv7    : unpack(0),
            psn      : psn
        };

        let xrceth = genXRCETH(wr, cntrlStatus);
        let deth = genDETH(wr, cntrlStatus);
        let reth = genRETH(wr);
        let atomicEth = genAtomicEth(wr);
        let immDt = genImmDt(wr);
        let ieth = genIETH(wr);

        // If WR has zero length, then no payload, no matter what kind of opcode
        let hasPayload = workReqHasPayload(wr);
        case (wr.opcode)
            IBV_WR_RDMA_WRITE: begin
                return case (cntrlStatus.getTypeQP)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid tuple3(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid tuple3(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_WRITE_WITH_IMM: begin
                return case (cntrlStatus.getTypeQP)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid tuple3(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)), pack(unwrapMaybe(immDt))}) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth))}),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid tuple3(
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
                return case (cntrlStatus.getTypeQP)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid tuple3(
                        zeroExtendLSB(pack(bth)),
                        fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_UD: tagged Valid tuple3(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(deth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(DETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid tuple3(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_IMM: begin
                return case (cntrlStatus.getTypeQP)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid tuple3(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB(pack(bth)),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_UD: tagged Valid tuple3(
                        // UD always has only pkt
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(deth)), pack(unwrapMaybe(immDt)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(DETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid tuple3(
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
                return case (cntrlStatus.getTypeQP)
                    IBV_QPT_RC: tagged Valid tuple3(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(ieth)) }) :
                            zeroExtendLSB(pack(bth)),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid tuple3(
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
                return case (cntrlStatus.getTypeQP)
                    IBV_QPT_RC: tagged Valid tuple3(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        False // Read requests have no payload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid tuple3(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        False // Read requests have no payload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_ATOMIC_CMP_AND_SWP  ,
            IBV_WR_ATOMIC_FETCH_AND_ADD: begin
                return case (cntrlStatus.getTypeQP)
                    IBV_QPT_RC: tagged Valid tuple3(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(atomicEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(ATOMIC_ETH_BYTE_WIDTH)),
                        False // Atomic requests have no payload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid tuple3(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)), pack(unwrapMaybe(atomicEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(ATOMIC_ETH_BYTE_WIDTH)),
                        False // Atomic requests have no payload
                    );
                    default: tagged Invalid;
                endcase;
            end
            default: return tagged Invalid;
        endcase
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(Tuple3#(HeaderData, HeaderByteNum, Bool)) genMiddleOrLastReqHeader(
    WorkReq wr, CntrlStatus cntrlStatus, PSN psn, Bool isLastReqPkt
);
    let maybeTrans  = qpType2TransType(cntrlStatus.getTypeQP);
    let maybeOpCode = genMiddleOrLastReqRdmaOpCode(wr.opcode, isLastReqPkt);
    let maybeDQPN   = getMaybeDestQpnSQ(wr, cntrlStatus);

    if (
        maybeTrans  matches tagged Valid .trans  &&&
        maybeOpCode matches tagged Valid .opcode &&&
        maybeDQPN   matches tagged Valid .dqpn
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: wr.solicited,
            migReq   : unpack(0),
            padCnt   : isLastReqPkt ? calcPadCnt(wr.len) : 0,
            tver     : unpack(0),
            pkey     : cntrlStatus.comm.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : dqpn,
            ackReq   : cntrlStatus.comm.getSigAll || (isLastReqPkt && workReqRequireAck(wr)),
            resv7    : unpack(0),
            psn      : psn
        };

        let xrceth = genXRCETH(wr, cntrlStatus);
        let immDt = genImmDt(wr);
        let ieth = genIETH(wr);

        let hasPayload = True;
        case (wr.opcode)
            IBV_WR_RDMA_WRITE:begin
                return case (cntrlStatus.getTypeQP)
                    IBV_QPT_RC: tagged Valid tuple3(
                        zeroExtendLSB(pack(bth)),
                        fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid tuple3(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_WRITE_WITH_IMM: begin
                return case (cntrlStatus.getTypeQP)
                    IBV_QPT_RC: tagged Valid tuple3(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(immDt))}) :
                            zeroExtendLSB(pack(bth)),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid tuple3(
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
            IBV_WR_SEND: begin
                return case (cntrlStatus.getTypeQP)
                    IBV_QPT_RC: tagged Valid tuple3(
                        zeroExtendLSB(pack(bth)),
                        fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid tuple3(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrceth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_IMM: begin
                return case (cntrlStatus.getTypeQP)
                    IBV_QPT_RC: tagged Valid tuple3(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB(pack(bth)),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid tuple3(
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
                return case (cntrlStatus.getTypeQP)
                    IBV_QPT_RC: tagged Valid tuple3(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(ieth)) }) :
                            zeroExtendLSB(pack(bth)),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid tuple3(
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
            default: return tagged Invalid;
        endcase
    end
    else begin
        return tagged Invalid;
    end
endfunction

typedef struct {
    PSN            curPSN;
    PendingWorkReq pendingWR;
    Bool           isFirstReqPkt;
    Bool           isLastReqPkt;
} ReqPktHeaderInfo deriving(Bits);

typedef struct {
    Bool isNewWorkReq;
    Bool isZeroPmtuResidue;
    Bool isReliableConnection;
    Bool isUnreliableDatagram;
    Bool needDmaRead;
} WorkReqInfo deriving(Bits, FShow);

interface ReqGenSQ;
    interface PipeOut#(PendingWorkReq) pendingWorkReqPipeOut;
    interface DataStreamPipeOut rdmaReqDataStreamPipeOut;
    interface PipeOut#(WorkCompGenReqSQ) workCompGenReqPipeOut;
    method Bool reqHeaderOutNotEmpty();
endinterface

module mkReqGenSQ#(
    ContextSQ contextSQ,
    PayloadGenerator payloadGenerator,
    // DmaReadSrv dmaReadSrv,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn,
    Bool pendingWorkReqBufNotEmpty
)(ReqGenSQ);
    // Output FIFO for PipeOut
    FIFOF#(PendingWorkReq)   pendingWorkReqOutQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqSQ) workCompGenReqOutQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(Tuple7#(
        PendingWorkReq, PktNum, PmtuResidue, Bool, Bool, Bool, Bool
    )) workReqPayloadGenQ <- mkFIFOF;
    FIFOF#(Tuple3#(PendingWorkReq, PktNum, WorkReqInfo)) workReqPktNumQ <- mkFIFOF;
    FIFOF#(Tuple2#(PendingWorkReq, WorkReqInfo))            workReqPsnQ <- mkFIFOF;
    FIFOF#(Tuple2#(PendingWorkReq, WorkReqInfo))            workReqOutQ <- mkFIFOF;
    FIFOF#(Tuple2#(PendingWorkReq, WorkReqInfo))          workReqCheckQ <- mkFIFOF;
    FIFOF#(Tuple2#(PendingWorkReq, WorkReqInfo))              reqCountQ <- mkFIFOF;
    FIFOF#(Tuple2#(ReqPktHeaderInfo, WorkReqInfo))    reqHeaderPrepareQ <- mkFIFOF;
    FIFOF#(Tuple4#(
        PendingWorkReq, WorkReqInfo, Maybe#(Tuple3#(HeaderData, HeaderByteNum, Bool)), PSN
    )) pendingReqHeaderQ <- mkFIFOF;
    FIFOF#(Tuple4#(
        PendingWorkReq, Maybe#(RdmaHeader), Maybe#(PayloadGenResp), PSN
    )) reqHeaderGenQ <- mkFIFOF;
    FIFOF#(RdmaHeader)  reqHeaderOutQ <- mkFIFOF;
    FIFOF#(PSN)            psnReqOutQ <- mkFIFOF;

    let cntrlStatus = contextSQ.statusSQ;

    function Action flushInternalNormalStatePipelineQ();
        action
            workReqPktNumQ.clear;
            workReqPsnQ.clear;
            workReqOutQ.clear;
            workReqCheckQ.clear;
            reqCountQ.clear;
            reqHeaderPrepareQ.clear;
            pendingReqHeaderQ.clear;
            reqHeaderGenQ.clear;
            reqHeaderOutQ.clear;
            psnReqOutQ.clear;
        endaction
    endfunction

    Reg#(PktNum)   remainingPktNumReg <- mkRegU;
    Reg#(PSN)               curPsnReg <- mkRegU;
    Reg#(Bool)       isNormalStateReg <- mkReg(True);
    Reg#(Bool) isFirstOrOnlyReqPktReg <- mkReg(True);

    let rdmaReqPipeOut <- mkCombineHeaderAndPayload(
        cntrlStatus,
        toPipeOut(reqHeaderOutQ),
        toPipeOut(psnReqOutQ),
        payloadGenerator.payloadDataStreamPipeOut
    );

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (cntrlStatus.comm.isReset);
        // Flush output FIFO
        pendingWorkReqOutQ.clear;
        workCompGenReqOutQ.clear;

        // Flush pipeline FIFO
        workReqPayloadGenQ.clear;
        flushInternalNormalStatePipelineQ;
        // psnReqOutQ.clear;

        // payloadGenReqOutQ.clear;

        isNormalStateReg       <= True;
        isFirstOrOnlyReqPktReg <= True;

        // $display("time=%0t: reset and clear mkReqGenSQ", $time);
    endrule

    // rule debugNotFullSQ if (!(
    //     workReqPayloadGenQ.notFull &&
    //     workReqPktNumQ.notFull     &&
    //     workReqPsnQ.notFull        &&
    //     workReqOutQ.notFull        &&
    //     workReqCheckQ.notFull      &&
    //     reqCountQ.notFull          &&
    //     reqHeaderPrepareQ.notFull  &&
    //     pendingReqHeaderQ.notFull  &&
    //     reqHeaderGenQ.notFull      &&
    //     reqHeaderOutQ.notFull      &&
    //     psnReqOutQ.notFull         &&
    //     // payloadGenReqOutQ.notFull  &&
    //     pendingWorkReqOutQ.notFull &&
    //     workCompGenReqOutQ.notFull // &&
    //     // payloadGenerator.payloadDataStreamPipeOut.notEmpty
    // ));
    //     $display(
    //         "time=%0t: mkReqGenSQ debug", $time,
    //         ", sqpn=%h", cntrlStatus.comm.getSQPN,
    //         ", cntrlStatus.comm.isStableRTS=", fshow(cntrlStatus.comm.isStableRTS),
    //         ", cntrlStatus.comm.isERR=", fshow(cntrlStatus.comm.isERR),
    //         ", pendingWorkReqPipeIn.notEmpty=", fshow(pendingWorkReqPipeIn.notEmpty),
    //         ", workReqPayloadGenQ.notFull=", fshow(workReqPayloadGenQ.notFull),
    //         ", workReqPktNumQ.notFull=", fshow(workReqPktNumQ.notFull),
    //         ", workReqPsnQ.notFull=", fshow(workReqPsnQ.notFull),
    //         ", workReqOutQ.notFull=", fshow(workReqOutQ.notFull),
    //         ", workReqCheckQ.notFull=", fshow(workReqCheckQ.notFull),
    //         ", reqCountQ.notFull=", fshow(reqCountQ.notFull),
    //         ", reqHeaderPrepareQ.notFull=", fshow(reqHeaderPrepareQ.notFull),
    //         ", pendingReqHeaderQ.notFull=", fshow(pendingReqHeaderQ.notFull),
    //         ", reqHeaderGenQ.notFull=", fshow(reqHeaderGenQ.notFull),
    //         ", reqHeaderOutQ.notFull=", fshow(reqHeaderOutQ.notFull),
    //         ", psnReqOutQ.notFull=", fshow(psnReqOutQ.notFull),
    //         // ", payloadGenReqOutQ.notFull=", fshow(payloadGenReqOutQ.notFull),
    //         ", pendingWorkReqOutQ.notFull=", fshow(pendingWorkReqOutQ.notFull),
    //         ", workCompGenReqOutQ.notFull=", fshow(workCompGenReqOutQ.notFull),
    //         ", payloadGenerator.payloadDataStreamPipeOut.notEmpty=", fshow(payloadGenerator.payloadDataStreamPipeOut.notEmpty)
    //     );
    // endrule

    // rule debugNotEmptySQ;
    //     if (psnReqOutQ.notEmpty) begin
    //         let curPSN = psnReqOutQ.first;
    //         $display(
    //             "time=%0t: mkReqGenSQ debugNotEmptySQ", $time,
    //             ", sqpn=%h", cntrlStatus.comm.getSQPN,
    //             ", curPSN=%0h", curPSN
    //         );
    //     end
    //     else begin
    //         $display(
    //             "time=%0t: mkReqGenSQ debugNotEmptySQ", $time,
    //             ", sqpn=%h", cntrlStatus.comm.getSQPN,
    //             ", psnReqOutQ.notEmpty=", fshow(psnReqOutQ.notEmpty)
    //         );
    //     end
    // endrule

    (* conflict_free = "recvWorkReq, \
                        issuePayloadGenReq, \
                        calcPktNum4NewWorkReq, \
                        calcPktSeqNum4NewWorkReq, \
                        checkPendingWorkReq, \
                        outputNewPendingWorkReq, \
                        countReqPkt, \
                        prepareReqHeaderGen, \
                        genReqHeader, \
                        recvPayloadGenRespAndGenErrWorkComp, \
                        errFlushWR" *)
    rule recvWorkReq if (cntrlStatus.comm.isStableRTS || cntrlStatus.comm.isERR);
        let qpType = cntrlStatus.getTypeQP;
        immAssert(
            qpType == IBV_QPT_RC || qpType == IBV_QPT_UC ||
            qpType == IBV_QPT_XRC_SEND || qpType == IBV_QPT_UD,
            "qpType assertion @ mkReqGenSQ",
            $format(
                "qpType=", fshow(qpType), " unsupported"
            )
        );

        let isReliableConnection = qpType == IBV_QPT_RC || qpType == IBV_QPT_XRC_SEND;
        let isUnreliableDatagram = qpType == IBV_QPT_UD;
        if (cntrlStatus.comm.isSQD) begin
            immAssert(
                isReliableConnection,
                "SQD assertion @ mkReqGenSQ",
                $format(
                    "cntrlStatus.comm.isSQD=", fshow(cntrlStatus.comm.isSQD),
                    " should be RC or XRC, but qpType=", fshow(qpType)
                )
            );
        end

        let shouldDeqPendingWR = True;
        let curPendingWR = pendingWorkReqPipeIn.first;
        if (
            cntrlStatus.comm.isRTS && containWorkReqFlag(curPendingWR.wr.flags, IBV_SEND_FENCE) // Fence
        ) begin
            shouldDeqPendingWR = !pendingWorkReqBufNotEmpty;
            $info(
                "time=%0t: wait pendingWorkReqBufNotEmpty=",
                $time, fshow(pendingWorkReqBufNotEmpty),
                " to be false, when IBV_QPS_SQD or IBV_SEND_FENCE"
            );
        end
        else begin // SQ Drain
            shouldDeqPendingWR = !cntrlStatus.comm.isSQD;
        end

        immAssert(
            curPendingWR.wr.sqpn == cntrlStatus.comm.getSQPN,
            "curPendingWR.wr.sqpn assertion @ mkWorkReq2RdmaReq",
            $format(
                "curPendingWR.wr.sqpn=%h should == cntrlStatus.comm.getSQPN=%h",
                curPendingWR.wr.sqpn, cntrlStatus.comm.getSQPN
            )
        );

        if (isAtomicWorkReq(curPendingWR.wr.opcode)) begin
            immAssert(
                curPendingWR.wr.len == fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)),
                "curPendingWR.wr.len assertion @ mkWorkReq2RdmaReq",
                $format(
                    "curPendingWR.wr.len=%0d should be %0d for atomic WR=",
                    curPendingWR.wr.len, valueOf(ATOMIC_WORK_REQ_LEN), fshow(curPendingWR)
                )
            );
        end
        // TODO: handle pending read/atomic request number limit

        let isNewWorkReq = !isValid(curPendingWR.isOnlyReqPkt);
        let needDmaRead = workReqNeedDmaReadSQ(curPendingWR.wr);
        let { tmpReqPktNum, pmtuResidue } = truncateLenByPMTU(
            curPendingWR.wr.len, cntrlStatus.comm.getPMTU
        );
        if (shouldDeqPendingWR) begin
            pendingWorkReqPipeIn.deq;

            workReqPayloadGenQ.enq(tuple7(
                curPendingWR, tmpReqPktNum, pmtuResidue, needDmaRead,
                isNewWorkReq, isReliableConnection, isUnreliableDatagram
            ));

            // if (cntrlStatus.comm.isERR) begin
            // $display(
            //     "time=%0t: mkReqGenSQ 1st stage recvWorkReq", $time,
            //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
            //     ", pmtu=", fshow(cntrlStatus.comm.getPMTU),
            //     ", wr.id=%h", curPendingWR.wr.id,
            //     ", shouldDeqPendingWR=", fshow(shouldDeqPendingWR)
            //     // ", curPendingWR=", fshow(curPendingWR)
            // );
            // end
        end
        // $display(
        //     "time=%0t: mkReqGenSQ 1st stage recvWorkReq", $time,
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", shouldDeqPendingWR=", fshow(shouldDeqPendingWR)
        // );
    endrule

    rule issuePayloadGenReq if (cntrlStatus.comm.isStableRTS && isNormalStateReg);
        let {
            curPendingWR, tmpReqPktNum, pmtuResidue, needDmaRead,
            isNewWorkReq, isReliableConnection, isUnreliableDatagram
        } = workReqPayloadGenQ.first;
        workReqPayloadGenQ.deq;

        if (needDmaRead) begin
            let payloadGenReq = PayloadGenReq {
                // segment      : True,
                addPadding     : True,
                pmtu           : cntrlStatus.comm.getPMTU,
                dmaReadMetaData: DmaReadMetaData {
                    initiator: DMA_SRC_SQ_RD,
                    sqpn     : cntrlStatus.comm.getSQPN,
                    startAddr: curPendingWR.wr.laddr,
                    len      : curPendingWR.wr.len,
                    mrID     : wr2IndexMR(curPendingWR.wr)
                }
            };

            payloadGenerator.srvPort.request.put(payloadGenReq);
            // $display(
            //     "time=%0t: mkReqGenSQ issuePayloadGenReq", $time,
            //     ", payloadGenReq=", fshow(payloadGenReq)
            // );
        end

        let isZeroPmtuResidue = isZero(pmtuResidue);
        let workReqInfo = WorkReqInfo {
            isNewWorkReq        : isNewWorkReq,
            isZeroPmtuResidue   : isZeroPmtuResidue,
            isReliableConnection: isReliableConnection,
            isUnreliableDatagram: isUnreliableDatagram,
            needDmaRead         : needDmaRead
        };
        workReqPktNumQ.enq(tuple3(curPendingWR, tmpReqPktNum, workReqInfo));
        // $display(
        //     "time=%0t: mkReqGenSQ 2nd stage issuePayloadGenReq", $time,
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", wr.id=%h", curPendingWR.wr.id,
        //     ", curPendingWR.wr.len=%0d", curPendingWR.wr.len,
        //     // ", workReqInfo=", fshow(workReqInfo),
        //     ", tmpReqPktNum=%0d", tmpReqPktNum
        // );
    endrule

    rule calcPktNum4NewWorkReq if (cntrlStatus.comm.isStableRTS && isNormalStateReg);
        let { curPendingWR, tmpReqPktNum, workReqInfo } = workReqPktNumQ.first;
        workReqPktNumQ.deq;

        let isZeroPmtuResidue = workReqInfo.isZeroPmtuResidue;
        let isNewWorkReq      = workReqInfo.isNewWorkReq;

        if (isNewWorkReq) begin
            // let { isOnlyPkt, totalPktNum } = calcPktNumByLength(
            //     curPendingWR.wr.len, cntrlStatus.comm.getPMTU
            // );
            let totalPktNum = isZeroPmtuResidue ? tmpReqPktNum : tmpReqPktNum + 1;
            let isOnlyPkt = isLessOrEqOneR(totalPktNum);

            curPendingWR.pktNum = tagged Valid totalPktNum;
            curPendingWR.isOnlyReqPkt = tagged Valid isOnlyPkt;
        end
        else begin
            // Should be retry WorkReq
            immAssert(
                isValid(curPendingWR.startPSN) &&
                isValid(curPendingWR.endPSN)   &&
                isValid(curPendingWR.pktNum)   &&
                isValid(curPendingWR.isOnlyReqPkt),
                "curPendingWR assertion @ mkReqGenSQ",
                $format(
                    "curPendingWR should have valid PSN and PktNum, curPendingWR=",
                    fshow(curPendingWR)
                )
            );
        end

        workReqPsnQ.enq(tuple2(curPendingWR, workReqInfo));
        // $display(
        //     "time=%0t: mkReqGenSQ 3rd stage calcPktNum4NewWorkReq", $time,
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", wr.id=%h", curPendingWR.wr.id,
        //     ", curPendingWR.wr.len=%0d", curPendingWR.wr.len,
        //     ", isNewWorkReq=", fshow(isNewWorkReq),
        //     ", curPendingWR.pktNum=", fshow(curPendingWR.pktNum)
        // );
    endrule

    rule calcPktSeqNum4NewWorkReq if (cntrlStatus.comm.isStableRTS && isNormalStateReg);
        let { curPendingWR, workReqInfo } = workReqPsnQ.first;
        workReqPsnQ.deq;

        let isNewWorkReq = workReqInfo.isNewWorkReq;
        let totalPktNum  = unwrapMaybe(curPendingWR.pktNum);
        let isOnlyPkt    = unwrapMaybe(curPendingWR.isOnlyReqPkt);

        let startPktSeqNum = contextSQ.getNPSN;
        let { nextPktSeqNum, endPktSeqNum } = calcNextAndEndPSN(
            startPktSeqNum, totalPktNum, isOnlyPkt, cntrlStatus.comm.getPMTU
        );

        if (isNewWorkReq) begin
            immAssert(
                (endPktSeqNum + 1 == nextPktSeqNum) &&
                (
                    endPktSeqNum == startPktSeqNum ||
                    psnInRangeExclusive(endPktSeqNum, startPktSeqNum, nextPktSeqNum)
                ),
                "startPSN, endPSN, nextPSN assertion @ mkReqGenSQ",
                $format(
                    "endPSN=%h should >= startPSN=%h, and endPSN=%h + 1 should == nextPSN=%h",
                    endPktSeqNum, startPktSeqNum, endPktSeqNum, nextPktSeqNum
                )
            );

            contextSQ.setNPSN(nextPktSeqNum);
            let hasOnlyReqPkt = isOnlyPkt || isReadWorkReq(curPendingWR.wr.opcode);

            curPendingWR.startPSN     = tagged Valid startPktSeqNum;
            curPendingWR.endPSN       = tagged Valid endPktSeqNum;
            // curPendingWR.pktNum       = tagged Valid totalPktNum;
            curPendingWR.isOnlyReqPkt = tagged Valid hasOnlyReqPkt;

            // $display(
            //     "time=%0t: mkReqGenSQ calcPktSeqNum4NewWorkReq", $time,
            //     ", wr.id=%h", curPendingWR.wr.id,
            //     ", startPSN=%h, endPSN=%h, nextPktSeqNum=%h",
            //     startPktSeqNum, endPktSeqNum, nextPktSeqNum
            // );
        end

        workReqCheckQ.enq(tuple2(curPendingWR, workReqInfo));
        // $display(
        //     "time=%0t: mkReqGenSQ 4th stage calcPktSeqNum4NewWorkReq", $time,
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", wr.id=%h", curPendingWR.wr.id
        //     // ", startPSN=%h, endPSN=%h, nextPktSeqNum=%h",
        //     // startPktSeqNum, endPktSeqNum, nextPktSeqNum
        // );
    endrule

    rule checkPendingWorkReq if (cntrlStatus.comm.isStableRTS && isNormalStateReg);
        let { curPendingWR, workReqInfo } = workReqCheckQ.first;
        workReqCheckQ.deq;

        let isOnlyReqPkt = unwrapMaybe(curPendingWR.isOnlyReqPkt);

        let isNewWorkReq         = workReqInfo.isNewWorkReq;
        let isUnreliableDatagram = workReqInfo.isUnreliableDatagram;
        let isValidWorkReq       = !isUnreliableDatagram || isOnlyReqPkt;

        if (!isNewWorkReq) begin
            immAssert(
                isValidWorkReq,
                "existing UD WR assertion @ mkReqGenSQ",
                $format(
                    "illegal existing UD WR with length=%0d", curPendingWR.wr.len,
                    " larger than PMTU when TypeQP=", fshow(cntrlStatus.getTypeQP),
                    " and isOnlyReqPkt=", fshow(isOnlyReqPkt)
                )
            );
        end

        if (isValidWorkReq) begin // Discard UD with payload more than one packets
            reqCountQ.enq(tuple2(curPendingWR, workReqInfo));
        end
        workReqOutQ.enq(tuple2(curPendingWR, workReqInfo));
        // $display(
        //     "time=%0t: mkReqGenSQ 5th stage checkPendingWorkReq", $time,
        //     ", isValidWorkReq=", fshow(isValidWorkReq),
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", wr.id=%h", curPendingWR.wr.id
        // );
    endrule

    rule outputNewPendingWorkReq if (cntrlStatus.comm.isStableRTS && isNormalStateReg);
        let { curPendingWR, workReqInfo } = workReqOutQ.first;
        workReqOutQ.deq;

        let isNewWorkReq         = workReqInfo.isNewWorkReq;
        let isReliableConnection = workReqInfo.isReliableConnection;

        if (isNewWorkReq && isReliableConnection) begin
            // Only for RC and XRC output new WR as pending WR, not retry WR
            pendingWorkReqOutQ.enq(curPendingWR);
            // $display(
            //     "time=%0t: mkReqGenSQ 6th-2 stage outputNewPendingWorkReq", $time,
            //     ", isReliableConnection=", fshow(isReliableConnection),
            //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
            //     ", wr.id=%h", curPendingWR.wr.id
            //     // ", pending WR=", fshow(curPendingWR)
            // );
        end
    endrule

    rule countReqPkt if (cntrlStatus.comm.isStableRTS && isNormalStateReg);
        let { pendingWR, workReqInfo } = reqCountQ.first;

        let startPSN = unwrapMaybe(pendingWR.startPSN);
        let totalPktNum = unwrapMaybe(pendingWR.pktNum);
        let isOnlyReqPkt = unwrapMaybe(pendingWR.isOnlyReqPkt);
        let qpType = cntrlStatus.getTypeQP;

        let curPSN = curPsnReg;
        let remainingPktNum = remainingPktNumReg;

        let isLastOrOnlyReqPkt = isOnlyReqPkt || (!isFirstOrOnlyReqPktReg && isZero(remainingPktNumReg));
        let isFirstReqPkt = isFirstOrOnlyReqPktReg;
        let isLastReqPkt  = isLastOrOnlyReqPkt;

        // Check WR length cannot be larger than PMTU for UD
        immAssert(
            !(qpType == IBV_QPT_UD) || isOnlyReqPkt,
            "UD assertion @ mkReqGenSQ",
            $format(
                "illegal UD WR with length=%0d", pendingWR.wr.len,
                " larger than PMTU when TypeQP=", fshow(qpType),
                " and isOnlyReqPkt=", fshow(isOnlyReqPkt)
            )
        );

        if (isLastOrOnlyReqPkt) begin
            reqCountQ.deq;
            isFirstOrOnlyReqPktReg <= True;
        end
        else begin
            isFirstOrOnlyReqPktReg <= False;
        end

        if (isFirstOrOnlyReqPktReg) begin
            curPSN = startPSN;

            // Current cycle output first/only packet,
            // so the remaining pktNum = totalPktNum - 2
            if (isOnlyReqPkt) begin
                remainingPktNum = 0;
            end
            else begin
                remainingPktNum = totalPktNum - 2;
            end
        end
        else if (!isLastReqPkt) begin
            remainingPktNum = remainingPktNumReg - 1;
        end
        remainingPktNumReg <= remainingPktNum;
        curPsnReg <= curPSN + 1;

        let reqPktHeaderInfo = ReqPktHeaderInfo {
            curPSN       : curPSN,
            pendingWR    : pendingWR,
            isFirstReqPkt: isFirstReqPkt,
            isLastReqPkt : isLastReqPkt
        };
        reqHeaderPrepareQ.enq(tuple2(reqPktHeaderInfo, workReqInfo));
        // $display(
        //     "time=%0t: mkReqGenSQ 6th-1 stage countReqPkt", $time,
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", wr.id=%h", pendingWR.wr.id,
        //     ", isLastOrOnlyReqPkt=", fshow(isLastOrOnlyReqPkt),
        //     ", isOnlyReqPkt=", fshow(isOnlyReqPkt),
        //     ", isFirstReqPkt=", fshow(isFirstReqPkt),
        //     ", isLastReqPkt=", fshow(isLastReqPkt),
        //     ", totalPktNum=%0d", totalPktNum,
        //     ", remainingPktNum=%0d", remainingPktNum,
        //     ", remainingPktNumReg=%0d", remainingPktNumReg,
        //     ", curPSN=%h", curPSN
        // );
    endrule

    rule prepareReqHeaderGen if (cntrlStatus.comm.isStableRTS && isNormalStateReg);
        let { reqPktHeaderInfo, workReqInfo } = reqHeaderPrepareQ.first;
        reqHeaderPrepareQ.deq;

        let pendingWR    = reqPktHeaderInfo.pendingWR;
        let curPSN       = reqPktHeaderInfo.curPSN;
        let isOnlyReqPkt = unwrapMaybe(pendingWR.isOnlyReqPkt);
        let isLastReqPkt = reqPktHeaderInfo.isLastReqPkt;
        let maybeReqHeaderGenInfo  = dontCareValue;

        if (reqPktHeaderInfo.isFirstReqPkt) begin
            let maybeFirstOrOnlyHeaderGenInfo = genFirstOrOnlyReqHeader(
                pendingWR.wr, cntrlStatus, curPSN, isOnlyReqPkt
            );
            // TODO: remove this assertion, just report error by WC
            immAssert(
                isValid(maybeFirstOrOnlyHeaderGenInfo),
                "maybeFirstOrOnlyHeaderGenInfo assertion @ mkReqGenSQ",
                $format(
                    "maybeFirstOrOnlyHeaderGenInfo=", fshow(maybeFirstOrOnlyHeaderGenInfo),
                    " is not valid, and current WR=", fshow(pendingWR.wr)
                )
            );

            maybeReqHeaderGenInfo = maybeFirstOrOnlyHeaderGenInfo;
        end
        else begin
            let maybeMiddleOrLastHeaderGenInfo = genMiddleOrLastReqHeader(
                pendingWR.wr, cntrlStatus, curPSN, isLastReqPkt
            );
            immAssert(
                isValid(maybeMiddleOrLastHeaderGenInfo),
                "maybeMiddleOrLastHeaderGenInfo assertion @ mkReqGenSQ",
                $format(
                    "maybeMiddleOrLastHeaderGenInfo=", fshow(maybeMiddleOrLastHeaderGenInfo),
                    " is not valid, and current WR=", fshow(pendingWR.wr)
                )
            );

            maybeReqHeaderGenInfo = maybeMiddleOrLastHeaderGenInfo;

            if (isLastReqPkt) begin
                let endPSN = unwrapMaybe(pendingWR.endPSN);
                immAssert(
                    curPSN == endPSN,
                    "endPSN assertion @ mkReqGenSQ",
                    $format(
                        "curPSN=%h should == pendingWR.endPSN=%h",
                        curPSN, endPSN,
                        ", pendingWR=", fshow(pendingWR)
                    )
                );
            end
        end

        pendingReqHeaderQ.enq(tuple4(pendingWR, workReqInfo, maybeReqHeaderGenInfo, curPSN));
        // $display(
        //     "time=%0t: mkReqGenSQ 7th stage prepareReqHeaderGen", $time,
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", wr.id=%h", pendingWR.wr.id,
        //     // ", output PendingWorkReq=", fshow(pendingWR),
        //     // ", maybeReqHeaderGenInfo=", fshow(maybeReqHeaderGenInfo),
        //     ", isOnlyReqPkt=", fshow(isOnlyReqPkt),
        //     ", isLastReqPkt=", fshow(isLastReqPkt),
        //     ", curPSN=%h", curPSN
        // );
    endrule

    rule genReqHeader if (cntrlStatus.comm.isStableRTS && isNormalStateReg);
        let {
            pendingWR, workReqInfo, maybeReqHeaderGenInfo, triggerPSN
        } = pendingReqHeaderQ.first;
        pendingReqHeaderQ.deq;

        let maybeReqHeader = tagged Invalid;
        let maybePayloadGenResp = tagged Invalid;
        if (maybeReqHeaderGenInfo matches tagged Valid .reqHeaderGenInfo) begin
            let { headerData, headerLen, hasPayload } = reqHeaderGenInfo;
            let reqHeader = genRdmaHeader(headerData, headerLen, hasPayload);
            maybeReqHeader = tagged Valid reqHeader;

            if (workReqInfo.needDmaRead) begin
                let payloadGenResp <- payloadGenerator.srvPort.response.get;
                maybePayloadGenResp = tagged Valid payloadGenResp;
            end
        end
        reqHeaderGenQ.enq(tuple4(pendingWR, maybeReqHeader, maybePayloadGenResp, triggerPSN));
        // $display(
        //     "time=%0t: mkReqGenSQ 8th stage genReqHeader", $time,
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", wr.id=%h", pendingWR.wr.id,
        //     // ", reqHeader=", fshow(reqHeader),
        //     ", curPSN=%h", triggerPSN
        // );
    endrule

    rule recvPayloadGenRespAndGenErrWorkComp if (cntrlStatus.comm.isStableRTS && isNormalStateReg);
        let {
            pendingWR, maybeReqHeader, maybePayloadGenResp, triggerPSN
        } = reqHeaderGenQ.first;
        reqHeaderGenQ.deq;

        // Partial WR ACK because this WR has inserted into pending WR buffer.
        let wcReqType         = WC_REQ_TYPE_PARTIAL_ACK;
        let wcStatus          = IBV_WC_LOC_QP_OP_ERR;
        let wcWaitDmaResp     = False;
        let errWorkCompGenReq = WorkCompGenReqSQ {
            wr           : pendingWR.wr,
            wcWaitDmaResp: wcWaitDmaResp,
            wcReqType    : wcReqType,
            triggerPSN   : triggerPSN,
            wcStatus     : wcStatus
        };

        let reqHasPayload = False;
        if (maybeReqHeader matches tagged Valid .reqHeader) begin
            if (maybePayloadGenResp matches tagged Valid .payloadGenResp) begin
                reqHasPayload = True;

                if (payloadGenResp.isRespErr) begin
                    workCompGenReqOutQ.enq(errWorkCompGenReq);
                    isNormalStateReg <= False;

                    // $display(
                    //     "time=%0t: mkReqGenSQ recvPayloadGenRespAndGenErrWorkComp", $time,
                    //     ", payloadGenResp.isRespErr=", fshow(payloadGenResp.isRespErr)
                    // );
                end
                else begin
                    reqHeaderOutQ.enq(reqHeader);
                    psnReqOutQ.enq(triggerPSN);
                end
            end
            else begin
                reqHeaderOutQ.enq(reqHeader);
                psnReqOutQ.enq(triggerPSN);
            end
        end
        else begin // Illegal RDMA request headers
            workCompGenReqOutQ.enq(errWorkCompGenReq);
            isNormalStateReg <= False;
        end

        // $display(
        //     "time=%0t: mkReqGenSQ 9th stage recvPayloadGenRespAndGenErrWorkComp", $time,
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", wr.id=%h", pendingWR.wr.id,
        //     // ", reqHeader=", fshow(reqHeader),
        //     ", curPSN=%h", triggerPSN,
        //     ", reqHasPayload=", fshow(reqHasPayload)
        // );
    endrule

    rule errFlushWR if (cntrlStatus.comm.isERR || (cntrlStatus.comm.isRTS && !isNormalStateReg));
        let {
            curPendingWR, totalReqPktNum, pmtuResidue, needDmaRead, isNewWorkReq,
            isReliableConnection, isUnreliableDatagram
        } = workReqPayloadGenQ.first;
        workReqPayloadGenQ.deq;

        // Only for RC and XRC output new WR as pending WR to generate WC
        if (isNewWorkReq && isReliableConnection) begin
            pendingWorkReqOutQ.enq(curPendingWR);
            // $display(
            //     "time=%0t: mkReqGenSQ errFlushWR", $time,
            //     ", wr.id=%h", curPendingWR.wr.id
            // );
        end
    endrule

    interface pendingWorkReqPipeOut    = toPipeOut(pendingWorkReqOutQ);
    interface rdmaReqDataStreamPipeOut = rdmaReqPipeOut;
    interface workCompGenReqPipeOut    = toPipeOut(workCompGenReqOutQ);
    method Bool reqHeaderOutNotEmpty() = psnReqOutQ.notEmpty;
endmodule
