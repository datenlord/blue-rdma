import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import PayloadConAndGen :: *;
import Headers :: *;
import Utils :: *;

// function Maybe#(TransType) getTransTypeFromQpType(QpType qpType);
//     return case (qpType)
//         IBV_QPT_RC      : tagged Valid TRANS_TYPE_RC;
//         IBV_QPT_UD      : tagged Valid TRANS_TYPE_UD;
//         IBV_QPT_XRC_SEND: tagged Valid TRANS_TYPE_XRC;
//         default         : tagged Invalid;
//     endcase;
// endfunction

function Maybe#(QPN) getMaybeDQPN(WorkReq wr, Controller cntrl);
    return case (cntrl.getQpType)
        IBV_QPT_RC, IBV_QPT_XRC_SEND: tagged Valid cntrl.getDQPN;
        IBV_QPT_UD: wr.dqpn;
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaOpCode) genFirstOrOnlyRdmaOpCode(WorkReqOpCode wrOpCode, Bool isOnlyReqPkt);
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

function Maybe#(RdmaOpCode) genMiddleOrLastRdmaOpCode(WorkReqOpCode wrOpCode, Bool isLastReqPkt);
    return case (wrOpCode)
        IBV_WR_RDMA_WRITE         : tagged Valid (isLastReqPkt ? RDMA_WRITE_LAST                : RDMA_WRITE_MIDDLE);
        IBV_WR_RDMA_WRITE_WITH_IMM: tagged Valid (isLastReqPkt ? RDMA_WRITE_LAST_WITH_IMMEDIATE : RDMA_WRITE_MIDDLE);
        IBV_WR_SEND               : tagged Valid (isLastReqPkt ? SEND_LAST                      : SEND_MIDDLE);
        IBV_WR_SEND_WITH_IMM      : tagged Valid (isLastReqPkt ? SEND_LAST_WITH_IMMEDIATE       : SEND_MIDDLE);
        IBV_WR_SEND_WITH_INV      : tagged Valid (isLastReqPkt ? SEND_LAST_WITH_INVALIDATE      : SEND_MIDDLE);
        default                   : tagged Invalid;
    endcase;
endfunction

function Maybe#(XRCETH) genXRCETH(WorkReq wr, Controller cntrl);
    return case (cntrl.getQpType)
        IBV_QPT_XRC_SEND: tagged Valid XRCETH {
            srqn: fromMaybe(?, wr.srqn),
            rsvd: unpack(0)
        };
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(DETH) genDETH(WorkReq wr, Controller cntrl);
    return case (cntrl.getQpType)
        IBV_QPT_UD: tagged Valid DETH {
            qkey: fromMaybe(?, wr.qkey),
            sqpn: cntrl.getSQPN,
            rsvd: unpack(0)
        };
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(RETH) genRETH(WorkReq wr);
    return case (wr.opcode)
        IBV_WR_RDMA_WRITE, IBV_WR_RDMA_WRITE_WITH_IMM, IBV_WR_RDMA_READ: tagged Valid RETH {
            va: wr.raddr,
            rkey: wr.rkey,
            dlen: wr.len
        };
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(AtomicEth) genAtomicEth(WorkReq wr);
    if (wr.swap matches tagged Valid .swap &&& wr.comp matches tagged Valid .comp) begin
        return case (wr.opcode)
            IBV_WR_ATOMIC_CMP_AND_SWP, IBV_WR_ATOMIC_FETCH_AND_ADD: tagged Valid AtomicEth {
                va: wr.raddr,
                rkey: wr.rkey,
                swap: swap,
                comp: comp
            };
            default: tagged Invalid;
        endcase;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(ImmDt) genImmDt(WorkReq wr);
    return case (wr.opcode)
        IBV_WR_RDMA_WRITE_WITH_IMM, IBV_WR_SEND_WITH_IMM: tagged Valid ImmDt {
            data: fromMaybe(?, wr.immDt)
        };
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(IETH) genIETH(WorkReq wr);
    return case (wr.opcode)
        IBV_WR_SEND_WITH_INV: (tagged Valid IETH {
            rkey: fromMaybe(?, wr.rkey2Inv)
        });
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaHeader) genFirstOrOnlyPktHeader(WorkReq wr, Controller cntrl, Bool isOnlyReqPkt);
    let maybeTrans  = qpType2TransType(cntrl.getQpType);
    let maybeOpCode = genFirstOrOnlyRdmaOpCode(wr.opcode, isOnlyReqPkt);
    let maybeDQPN   = getMaybeDQPN(wr, cntrl);

    if (
        maybeTrans matches tagged Valid .trans &&&
        maybeOpCode matches tagged Valid .opcode &&&
        maybeDQPN matches tagged Valid .dqpn
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: wr.solicited,
            migReq   : unpack(0),
            padCnt   : isOnlyReqPkt ? calcPadCnt(wr.len) : 0,
            tver     : unpack(0),
            pkey     : cntrl.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : dqpn,
            ackReq   : cntrl.getSigAll || (isOnlyReqPkt && workReqRequireAck(wr)),
            resv7    : unpack(0),
            psn      : cntrl.getNPSN
        };

        let xrcEth = genXRCETH(wr, cntrl);
        let deth = genDETH(wr, cntrl);
        let reth = genRETH(wr);
        let atomicEth = genAtomicEth(wr);
        let immDt = genImmDt(wr);
        let ieth = genIETH(wr);

        // If WR has zero length, then no payload, no matter what kind of opcode
        let hasPayload = workReqHasPayload(wr);
        case (wr.opcode)
            IBV_WR_RDMA_WRITE: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(fromMaybe(?, reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)), pack(fromMaybe(?, reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_WRITE_WITH_IMM: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, reth)), pack(fromMaybe(?, immDt))}) :
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, reth))}),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)), pack(fromMaybe(?, reth)), pack(fromMaybe(?, immDt)) }) :
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)), pack(fromMaybe(?, reth)) }),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        zeroExtendLSB(pack(bth)),
                        fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_UD: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(fromMaybe(?, deth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(DETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_IMM: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, immDt)) }) :
                            zeroExtendLSB(pack(bth)),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_UD: tagged Valid genRdmaHeader(
                        // UD always has only pkt
                        zeroExtendLSB({ pack(bth), pack(fromMaybe(?, deth)), pack(fromMaybe(?, immDt)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(DETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)), pack(fromMaybe(?, immDt)) }) :
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)) }),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_INV: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, ieth)) }) :
                            zeroExtendLSB(pack(bth)),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)), pack(fromMaybe(?, ieth)) }) :
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)) }),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_READ: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(fromMaybe(?, reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        False // Read requests have no payload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)), pack(fromMaybe(?, reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        False // Read requests have no payload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_ATOMIC_CMP_AND_SWP, IBV_WR_ATOMIC_FETCH_AND_ADD: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(fromMaybe(?, atomicEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(ATOMIC_ETH_BYTE_WIDTH)),
                        False // Atomic requests have no payload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)), pack(fromMaybe(?, atomicEth)) }),
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

function Maybe#(RdmaHeader) genMiddleOrLastPktHeader(WorkReq wr, Controller cntrl, PSN psn, Bool isLastReqPkt);
    let maybeTrans  = qpType2TransType(cntrl.getQpType);
    let maybeOpCode = genMiddleOrLastRdmaOpCode(wr.opcode, isLastReqPkt);
    let maybeDQPN   = getMaybeDQPN(wr, cntrl);

    if (
        maybeTrans matches tagged Valid .trans &&&
        maybeOpCode matches tagged Valid .opcode &&&
        maybeDQPN matches tagged Valid .dqpn
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: wr.solicited,
            migReq   : unpack(0),
            padCnt   : isLastReqPkt ? calcPadCnt(wr.len) : 0,
            tver     : unpack(0),
            pkey     : cntrl.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : dqpn,
            ackReq   : cntrl.getSigAll || (isLastReqPkt && workReqRequireAck(wr)),
            resv7    : unpack(0),
            psn      : psn
        };

        let xrcEth = genXRCETH(wr, cntrl);
        let immDt = genImmDt(wr);
        let ieth = genIETH(wr);

        let hasPayload = True;
        case (wr.opcode)
            IBV_WR_RDMA_WRITE:begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        zeroExtendLSB(pack(bth)),
                        fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_WRITE_WITH_IMM: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, immDt))}) :
                            zeroExtendLSB(pack(bth)),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)), pack(fromMaybe(?, immDt)) }) :
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)) }),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        zeroExtendLSB(pack(bth)),
                        fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_IMM: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, immDt)) }) :
                            zeroExtendLSB(pack(bth)),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)), pack(fromMaybe(?, immDt)) }) :
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)) }),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_INV: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, ieth)) }) :
                            zeroExtendLSB(pack(bth)),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)), pack(fromMaybe(?, ieth)) }) :
                            zeroExtendLSB({ pack(bth), pack(fromMaybe(?, xrcEth)) }),
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

interface PendingWorkReqAndDataStreamPipeOut;
    interface PipeOut#(PendingWorkReq) pendingWorkReq;
    interface DataStreamPipeOut rdmaReq;
endinterface

module mkWorkReq2RdmaReq#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn
)(PendingWorkReqAndDataStreamPipeOut);
    FIFOF#(PendingWorkReq) pendingWorkReqOutQ <- mkFIFOF;
    FIFOF#(RdmaHeader) headerQ <- mkFIFOF;

    Reg#(PendingWorkReq) curPendingWorkReqReg <- mkRegU;
    Reg#(PktNum) pktNumReg <- mkRegU;
    Reg#(PSN)    curPsnReg <- mkRegU;
    Reg#(Bool)     busyReg <- mkReg(False);

    let payloadGenerator <- mkPayloadGenerator(cntrl, dmaReadSrv);
    let payloadDataStreamPipeOut <- mkFunc2Pipe(
        getDataStreamFromPayloadGenRespPipeOut,
        payloadGenerator.respPipeOut
    );
    let segDataStreamPipeOut <- mkSegmentDataStreamByPmtu(
        payloadDataStreamPipeOut,
        cntrl.getPMTU
    );
    let headerDataStreamAndMetaDataPipeOut <- mkHeader2DataStream(
        convertFifo2PipeOut(headerQ)
    );
    let rdmaReqPipeOut <- mkPrependHeader2PipeOut(
        headerDataStreamAndMetaDataPipeOut.headerDataStream,
        headerDataStreamAndMetaDataPipeOut.headerMetaData,
        segDataStreamPipeOut
    );

    rule deqWorkReqPipeOut if (cntrl.isRTS && !busyReg);
        let qpType = cntrl.getQpType;
        dynAssert(
            qpType == IBV_QPT_RC || qpType == IBV_QPT_XRC_SEND || qpType == IBV_QPT_UD,
            "qpType assertion @ mkReqGenSQ",
            $format(
                "qpType=", fshow(qpType), " unsupported"
            )
        );

        let curPendingWR = pendingWorkReqPipeIn.first;
        pendingWorkReqPipeIn.deq;
        // $display("time=%0d: received PendingWorkReq=", $time, fshow(curPendingWR));

        dynAssert(
            curPendingWR.wr.sqpn == cntrl.getSQPN,
            "curPendingWR.wr.sqpn assertion @ mkWorkReq2RdmaReq",
            $format(
                "curPendingWR.wr.sqpn=%h should == cntrl.getSQPN=%h",
                curPendingWR.wr.sqpn, cntrl.getSQPN
            )
        );

        if (isAtomicWorkReq(curPendingWR.wr.opcode)) begin
            dynAssert(
                curPendingWR.wr.len == fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)),
                "curPendingWR.wr.len assertion @ mkWorkReq2RdmaReq",
                $format(
                    "curPendingWR.wr.len=%0d should be %0d for atomic WR=",
                    curPendingWR.wr.len, valueOf(ATOMIC_WORK_REQ_LEN), fshow(curPendingWR)
                )
            );
        end

        let isNewWorkReq = False;
        if (isValid(curPendingWR.isOnlyReqPkt)) begin
            // Should be retry WorkReq
            dynAssert(
                isValid(curPendingWR.startPSN) &&
                isValid(curPendingWR.endPSN)   &&
                isValid(curPendingWR.pktNum)   &&
                isValid(curPendingWR.isOnlyReqPkt),
                "curPendingWR assertion @ mkWorkReq2Headers",
                $format(
                    "curPendingWR should have valid PSN and PktNum, curPendingWR=",
                    fshow(curPendingWR)
                )
            );
        end
        else begin
            let startPktSeqNum = cntrl.getNPSN;
            let { isOnlyPkt, totalPktNum, nextPktSeqNum, endPktSeqNum } = calcPktNumNextAndEndPSN(
                startPktSeqNum,
                curPendingWR.wr.len,
                cntrl.getPMTU
            );
            dynAssert(
                startPktSeqNum <= endPktSeqNum && (endPktSeqNum + 1 == nextPktSeqNum),
                "startPSN, endPSN, nextPSN assertion @ mkReqGenSQ",
                $format(
                    "startPSN=%h should <= endPSN=%h, and endPSN=%h + 1 should == nextPSN=%h",
                    startPktSeqNum, endPktSeqNum, endPktSeqNum, nextPktSeqNum
                )
            );

            cntrl.setNPSN(nextPktSeqNum);
            let hasOnlyReqPkt = isOnlyPkt || isReadWorkReq(curPendingWR.wr.opcode);

            curPendingWR.startPSN = tagged Valid startPktSeqNum;
            curPendingWR.endPSN = tagged Valid endPktSeqNum;
            curPendingWR.pktNum = tagged Valid totalPktNum;
            curPendingWR.isOnlyReqPkt = tagged Valid hasOnlyReqPkt;

            isNewWorkReq = True;
            // $display(
            //     "time=%0d: curPendingWR=" $time, fshow(curPendingWR), ", nPSN=%h", nextPktSeqNum
            // );
        end

        PSN startPSN = fromMaybe(?, curPendingWR.startPSN);
        PktNum pktNum = fromMaybe(?, curPendingWR.pktNum);
        Bool isOnlyReqPkt = fromMaybe(?, curPendingWR.isOnlyReqPkt);
        curPendingWorkReqReg <= curPendingWR;
        curPsnReg <= startPSN + 1;
        // Current cycle output first/only packet,
        // so the remaining pktNum = totalPktNum - 2
        pktNumReg <= pktNum - 2;

        let maybeFirstOrOnlyHeader = genFirstOrOnlyPktHeader(curPendingWR.wr, cntrl, isOnlyReqPkt);
        dynAssert(
            isValid(maybeFirstOrOnlyHeader),
            "maybeFirstOrOnlyHeader assertion @ mkReqGenSQ",
            $format(
                "maybeFirstOrOnlyHeader=", fshow(maybeFirstOrOnlyHeader),
                " is not valid, and current WR=", fshow(curPendingWR)
            )
        );

        // Only for RC and XRC output new WR as pending WR, not retry WR
        if (isNewWorkReq && (qpType == IBV_QPT_RC || qpType == IBV_QPT_XRC_SEND)) begin
            pendingWorkReqOutQ.enq(curPendingWR);
        end

        if (maybeFirstOrOnlyHeader matches tagged Valid .firstOrOnlyHeader) begin
            // TODO: check WR length cannot be larger than PMTU for UD
            if (workReqNeedDmaRead(curPendingWR.wr)) begin
                let payloadGenReq = PayloadGenReq {
                    initiator    : PAYLOAD_INIT_SQ_RD,
                    addPadding   : True,
                    dmaReadReq   : DmaReadReq {
                        sqpn     : cntrl.getSQPN,
                        startAddr: curPendingWR.wr.laddr,
                        len      : curPendingWR.wr.len,
                        wrID     : curPendingWR.wr.id
                    }
                };
                payloadGenerator.request(payloadGenReq);
            end

            headerQ.enq(firstOrOnlyHeader);
            busyReg <= !isOnlyReqPkt;

            // $display(
            //     "time=%0d: output PendingWorkReq=", $time, fshow(curPendingWR),
            //     ", output header=", fshow(firstOrOnlyHeader)
            // );
        end
        else begin
            // TODO: generate error WC for illegal WR
        end
    endrule

    rule genHeaders if (cntrl.isRTS && busyReg);
        let qpType = cntrl.getQpType;
        dynAssert(
            qpType == IBV_QPT_RC || qpType == IBV_QPT_XRC_SEND,
            "qpType assertion @ mkReqGenSQ",
            $format(
                "qpType=", fshow(qpType), " cannot generate multi-packet requests"
            )
        );

        let nextPSN = curPsnReg + 1;
        let remainingPktNum = pktNumReg - 1;
        curPsnReg <= nextPSN;
        pktNumReg <= remainingPktNum;
        let isLastReqPkt = isZero(pktNumReg);

        let maybeMiddleOrLastHeader = genMiddleOrLastPktHeader(
            curPendingWorkReqReg.wr, cntrl, curPsnReg, isLastReqPkt
        );
        dynAssert(
            isValid(maybeMiddleOrLastHeader),
            "maybeMiddleOrLastHeader assertion @ mkReqGenSQ",
            $format(
                "maybeMiddleOrLastHeader=", fshow(maybeMiddleOrLastHeader),
                " is not valid, and current WR=", fshow(curPendingWorkReqReg)
            )
        );
        if (maybeMiddleOrLastHeader matches tagged Valid .middleOrLastHeader) begin
            headerQ.enq(middleOrLastHeader);
        end
        else begin
            // TODO: generate error WC for illegal WR
        end
        // $display(
        //     "time=%0d: curPsnReg=%h, pktNumReg=%0d, isLastReqPkt=%b",
        //     $time, curPsnReg, pktNumReg, isLastReqPkt
        // );

        if (isLastReqPkt) begin
            busyReg <= !isLastReqPkt;
            let endPSN = fromMaybe(?, curPendingWorkReqReg.endPSN);
            dynAssert(
                curPsnReg == endPSN,
                "endPSN assertion @ mkWorkReq2Headers",
                $format(
                    "curPsnReg=%h should == curPendingWorkReqReg.endPSN=%h",
                    curPsnReg, endPSN,
                    ", curPendingWorkReqReg=", fshow(curPendingWorkReqReg)
                )
            );
        end
    endrule

    interface pendingWorkReq = convertFifo2PipeOut(pendingWorkReqOutQ);
    interface rdmaReq = rdmaReqPipeOut;
endmodule
