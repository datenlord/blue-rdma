import FIFOF :: *;
import PAClib :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import Utils :: *;

// WC for SQ

function Maybe#(WorkComp) genWorkComp4WorkReq(
    Controller cntrl, WorkCompGenReqSQ wcGenReqSQ
);
    let wr = wcGenReqSQ.wr;
    let maybeWorkCompOpCode = workReqOpCode2WorkCompOpCode4SQ(wr.opcode);
    // TODO: how to set WC flags in SQ?
    // let wcFlags = workReqOpCode2WorkCompFlags(wr.opcode);
    let wcFlags = IBV_WC_NO_FLAGS;

    if (maybeWorkCompOpCode matches tagged Valid .opcode) begin
        let workComp = WorkComp {
            id      : wr.id,
            opcode  : opcode,
            flags   : wcFlags,
            status  : wcGenReqSQ.wcStatus,
            len     : wr.len,
            pkey    : cntrl.cntrlStatus.getPKEY,
            dqpn    : cntrl.cntrlStatus.getSQPN,
            sqpn    : cntrl.cntrlStatus.getDQPN,
            immDt   : tagged Invalid,
            rkey2Inv: tagged Invalid
        };
        return tagged Valid workComp;
    end
    else begin
        return tagged Invalid;
    end
endfunction

// function Maybe#(WorkComp) genErrFlushWorkComp4WorkReq(
//     Controller cntrl, WorkReq wr
// );
//     let maybeWorkCompOpCode = workReqOpCode2WorkCompOpCode4SQ(wr.opcode);

//     if (maybeWorkCompOpCode matches tagged Valid .opcode) begin
//         let workComp = WorkComp {
//             id      : wr.id,
//             opcode  : opcode,
//             flags   : IBV_WC_NO_FLAGS,
//             status  : IBV_WC_WR_FLUSH_ERR,
//             len     : wr.len,
//             pkey    : cntrl.cntrlStatus.getPKEY,
//             dqpn    : cntrl.cntrlStatus.getSQPN,
//             sqpn    : cntrl.cntrlStatus.getDQPN,
//             immDt   : tagged Invalid,
//             rkey2Inv: tagged Invalid
//         };
//         return tagged Valid workComp;
//     end
//     else begin
//         return tagged Invalid;
//     end
// endfunction

typedef struct {
    WorkCompGenReqSQ wcGenReqSQ;
    WorkComp         workComp;
    Bool             isWorkCompSuccess;
    Bool             needWorkCompWhenNormal;
} PendingWorkCompSQ deriving(Bits);

typedef enum {
    WC_GEN_ST_STOP,
    WC_GEN_ST_NORMAL,
    WC_GEN_ST_ERR_FLUSH
} WorkCompGenState deriving(Bits, Eq);

module mkWorkCompGenSQ#(
    Controller cntrl,
    PipeOut#(PayloadConResp)   payloadConRespPipeIn,
    PipeOut#(WorkCompGenReqSQ) wcGenReqPipeInFromReqGenInSQ,
    PipeOut#(WorkCompGenReqSQ) wcGenReqPipeInFromRespHandleInSQ,
    PipeOut#(WorkCompStatus)   workCompStatusPipeInFromRQ
)(PipeOut#(WorkComp));
    // Output FIFO for PipeOut
    FIFOF#(WorkComp)             workCompOutQ4SQ <- mkSizedFIFOF(valueOf(MAX_CQE));

    // Pipeline FIFO
    FIFOF#(PendingWorkCompSQ)        dmaWaitingQ <- mkFIFOF;
    FIFOF#(PendingWorkCompSQ)       genWorkCompQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqSQ) pendingWorkCompQ4SQ <- mkSizedFIFOF(valueOf(MAX_PENDING_WORK_COMP_NUM));

    Reg#(Bool)                      rqHasErrReg[2] <- mkCReg(2, False);
    Reg#(WorkCompGenState)     workCompGenStateReg <- mkReg(WC_GEN_ST_STOP);
    Reg#(Bool)      isFirstErrPartialAckWorkReqReg <- mkRegU;
    Reg#(WorkReqID) firstErrPartialAckWorkReqIdReg <- mkRegU;

    let inNormalState = cntrl.cntrlStatus.isRTS && workCompGenStateReg == WC_GEN_ST_NORMAL;
    let inErrorState  = cntrl.cntrlStatus.isERR || workCompGenStateReg == WC_GEN_ST_ERR_FLUSH;

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (cntrl.cntrlStatus.isReset);
        dmaWaitingQ.clear;
        workCompOutQ4SQ.clear;
        pendingWorkCompQ4SQ.clear;

        rqHasErrReg[1]      <= False;
        workCompGenStateReg <= WC_GEN_ST_STOP;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule start if (cntrl.cntrlStatus.isRTS && workCompGenStateReg == WC_GEN_ST_STOP);
        workCompGenStateReg <= WC_GEN_ST_NORMAL;
    endrule

    (* conflict_free = "recvWorkCompGenReqSQ, \
                        recvWorkCompStatusRQ, \
                        genPendingWorkCompSQ, \
                        waitDmaDoneSQ, \
                        genWorkCompSQ, \
                        noDmaWaitSQ, \
                        errFlushSQ, \
                        discardPayloadConRespSQ" *)
    rule recvWorkCompGenReqSQ if (inNormalState || inErrorState);
        if (wcGenReqPipeInFromReqGenInSQ.notEmpty) begin
            let wcGenReqSQ = wcGenReqPipeInFromReqGenInSQ.first;
            wcGenReqPipeInFromReqGenInSQ.deq;
            pendingWorkCompQ4SQ.enq(wcGenReqSQ);
        end
        else if (wcGenReqPipeInFromRespHandleInSQ.notEmpty) begin
            let wcGenReqSQ = wcGenReqPipeInFromRespHandleInSQ.first;
            wcGenReqPipeInFromRespHandleInSQ.deq;
            pendingWorkCompQ4SQ.enq(wcGenReqSQ);

            // $display(
            //     "time=%0t: wcGenReqPipeInFromRespHandleInSQ.notEmpty=",
            //     $time, fshow(wcGenReqPipeInFromRespHandleInSQ.notEmpty),
            //     ", wcGenReqSQ=", fshow(wcGenReqSQ)
            // );
        end
    endrule

    rule recvWorkCompStatusRQ if (inNormalState);
        let wcStatusRQ = workCompStatusPipeInFromRQ.first;
        workCompStatusPipeInFromRQ.deq;

        if (wcStatusRQ != IBV_WC_SUCCESS) begin
            rqHasErrReg[0] <= True;
        end
    endrule

    rule genPendingWorkCompSQ if (inNormalState || inErrorState);
        let wcGenReqSQ = pendingWorkCompQ4SQ.first;
        pendingWorkCompQ4SQ.deq;

        let maybeWorkComp = genWorkComp4WorkReq(cntrl, wcGenReqSQ);

        let wcReqType = wcGenReqSQ.wcReqType;
        let isWorkCompSuccess = wcGenReqSQ.wcStatus == IBV_WC_SUCCESS;
        // if (inErrorState) begin
        //     maybeWorkComp = genErrFlushWorkComp4WorkReq(cntrl, wcGenReqSQ.wr);
        // end
        immAssert(
            isValid(maybeWorkComp),
            "maybeWorkComp assertion @ mkWorkCompGenSQ",
            $format("maybeWorkComp=", fshow(maybeWorkComp), " should be valid")
        );

        let workComp = unwrapMaybe(maybeWorkComp);
        let needWorkCompWhenNormal =
            wcGenReqSQ.wcReqType == WC_REQ_TYPE_FULL_ACK &&
            (workReqNeedWorkCompSQ(wcGenReqSQ.wr) || cntrl.cntrlStatus.getSigAll);

        let pendingWorkCompSQ = PendingWorkCompSQ {
            wcGenReqSQ            : wcGenReqSQ,
            workComp              : workComp,
            isWorkCompSuccess     : isWorkCompSuccess,
            needWorkCompWhenNormal: needWorkCompWhenNormal
        };
        dmaWaitingQ.enq(pendingWorkCompSQ);
        // $display(
        //     "time=%0t: wcGenReqSQ=", $time, fshow(wcGenReqSQ),
        //     ", needWorkCompWhenNormal=", fshow(needWorkCompWhenNormal)
        // );
    endrule

    rule waitDmaDoneSQ if (inNormalState);
        let pendingWorkCompSQ = dmaWaitingQ.first;
        dmaWaitingQ.deq;

        let wcGenReqSQ             = pendingWorkCompSQ.wcGenReqSQ;
        let isWorkCompSuccess      = pendingWorkCompSQ.isWorkCompSuccess;
        let wcWaitDmaResp          = wcGenReqSQ.wcWaitDmaResp;
        // let workComp               = pendingWorkCompSQ.workComp;
        // let needWorkCompWhenNormal = pendingWorkCompSQ.needWorkCompWhenNormal;

        if (isWorkCompSuccess && wcWaitDmaResp) begin
            // TODO: report error if waiting too long for DMA write response
            let payloadConResp = payloadConRespPipeIn.first;
            payloadConRespPipeIn.deq;

            // TODO: better error handling
            let dmaRespPsnMatch = payloadConResp.dmaWriteResp.psn == wcGenReqSQ.triggerPSN;
            immAssert (
                dmaRespPsnMatch,
                "WC triggerPSN assertion @ mkWorkCompGenSQ",
                $format(
                    "dmaRespPsnMatch=", fshow(dmaRespPsnMatch),
                    " should either be true, payloadConResp.dmaWriteResp.psn=%h should == wcGenReqSQ.triggerPSN=%h",
                    payloadConResp.dmaWriteResp.psn, wcGenReqSQ.triggerPSN
                )
            );
        end

        genWorkCompQ.enq(pendingWorkCompSQ);
    endrule

    rule genWorkCompSQ if (inNormalState);
        let pendingWorkCompSQ = genWorkCompQ.first;
        genWorkCompQ.deq;

        let wcGenReqSQ             = pendingWorkCompSQ.wcGenReqSQ;
        let workComp               = pendingWorkCompSQ.workComp;
        let isWorkCompSuccess      = pendingWorkCompSQ.isWorkCompSuccess;
        let needWorkCompWhenNormal = pendingWorkCompSQ.needWorkCompWhenNormal;
        let wcWaitDmaResp          = wcGenReqSQ.wcWaitDmaResp;

        if (isWorkCompSuccess) begin
            if (needWorkCompWhenNormal) begin
                // if (workCompOutQ4SQ.notFull) begin
                workCompOutQ4SQ.enq(workComp);
                // end
                // else begin
                //     isCompQueueFull = True;
                // end
            end
        end
        else begin
            // if (workCompOutQ4SQ.notFull) begin
            workCompOutQ4SQ.enq(workComp);
            // end
            // else begin
            //     isCompQueueFull = True;
            // end
        end

        // TODO: handle CQ full
        // let hasErrWorkCompOrCompQueueFullSQ = !isWorkCompSuccess || isCompQueueFull;
        if (!isWorkCompSuccess || rqHasErrReg[1]) begin
            cntrl.setStateErr;
            workCompGenStateReg <= WC_GEN_ST_ERR_FLUSH;
            isFirstErrPartialAckWorkReqReg <=
                wcGenReqSQ.wcReqType == WC_REQ_TYPE_PARTIAL_ACK;
            firstErrPartialAckWorkReqIdReg <= wcGenReqSQ.wr.id;
            $display(
                "time=%0t:", $time,
                " set mkWorkCompGenSQ to error state, workComp.status=",
                fshow(workComp.status),
                ", isWorkCompSuccess=", fshow(isWorkCompSuccess),
                ", rqHasErrReg[1]=", fshow(rqHasErrReg[1]),
                // ", hasErrWorkCompOrCompQueueFullSQ=",
                // fshow(hasErrWorkCompOrCompQueueFullSQ),
                ", wcGenReqSQ=", fshow(wcGenReqSQ)
            );
        end
    endrule

    rule noDmaWaitSQ if (inErrorState);
        let pendingWorkCompRQ = dmaWaitingQ.first;
        dmaWaitingQ.deq;

        genWorkCompQ.enq(pendingWorkCompRQ);
    endrule

    rule errFlushSQ if (inErrorState);
        let pendingWorkCompSQ = genWorkCompQ.first;
        genWorkCompQ.deq;

        let wcGenReqSQ = pendingWorkCompSQ.wcGenReqSQ;
        let errFlushWC = pendingWorkCompSQ.workComp;
        errFlushWC.flags  = IBV_WC_NO_FLAGS;
        errFlushWC.status = IBV_WC_WR_FLUSH_ERR;

        // TODO: use formal to check no partial ACK after NAK
        immAssert(
            wcGenReqSQ.wcReqType == WC_REQ_TYPE_FULL_ACK,
            "wcGenReqSQ.wcReqType assertion @ mkWorkCompGenSQ",
            $format(
                "wcGenReqSQ.wcReqType=", fshow(wcGenReqSQ.wcReqType),
                " should == WC_REQ_TYPE_FULL_ACK, when error flush"
            )
        );

        // let isCompQueueFull = False;
        if (isFirstErrPartialAckWorkReqReg) begin
            // If the first error response is partial ACK to WR,
            // then skip the first full ACK to the WR,
            // since the WR has generated error WC.
            isFirstErrPartialAckWorkReqReg <= False;
            immAssert(
                wcGenReqSQ.wr.id == firstErrPartialAckWorkReqIdReg,
                "wcGenReqSQ.wr.id assertion @ mkWorkCompGenSQ",
                $format(
                    "wcGenReqSQ.wr.id=%h should == firstErrPartialAckWorkReqIdReg=%h",
                    wcGenReqSQ.wr.id, firstErrPartialAckWorkReqIdReg,
                    ", when error flush and isFirstErrPartialAckWorkReqReg=",
                    fshow(isFirstErrPartialAckWorkReqReg)
                )
            );
        end
        // else if (workCompOutQ4SQ.notFull) begin
        //     isCompQueueFull = True;
        // end
        else begin
            // let pendingWorkCompSQ = PendingWorkCompSQ {
            //     wcGenReqSQ            : wcGenReqSQ,
            //     workComp              : errFlushWC,
            //     isWorkCompSuccess     : False,
            //     needWorkCompWhenNormal: False
            // };
            // dmaWaitingQ.enq(pendingWorkCompSQ);
            workCompOutQ4SQ.enq(errFlushWC);
        end
        // $display(
        //     "time=%0t: flush pendingWorkCompQ4SQ, errFlushWC=",
        //     $time, fshow(errFlushWC), ", wcGenReqSQ=", fshow(wcGenReqSQ)
        // );
    endrule

    rule discardPayloadConRespSQ if (inErrorState);
        let payloadConResp = payloadConRespPipeIn.first;
        payloadConRespPipeIn.deq;
    endrule

    return convertFifo2PipeOut(workCompOutQ4SQ);
endmodule

// WC for RQ

function Maybe#(WorkComp) genWorkComp4RecvReq(
    Controller cntrl, WorkCompGenReqRQ wcGenReqRQ
);
    let maybeWorkCompOpCode = rdmaOpCode2WorkCompOpCode4RQ(wcGenReqRQ.reqOpCode);
    let wcFlags = rdmaOpCode2WorkCompFlagsRQ(wcGenReqRQ.reqOpCode);
    if (
        maybeWorkCompOpCode matches tagged Valid .opcode &&&
        wcGenReqRQ.rrID matches tagged Valid .rrID
    ) begin
        let workComp = WorkComp {
            id      : rrID,
            opcode  : opcode,
            flags   : wcFlags,
            status  : wcGenReqRQ.wcStatus,
            len     : wcGenReqRQ.len,
            pkey    : cntrl.cntrlStatus.getPKEY,
            dqpn    : cntrl.cntrlStatus.getSQPN,
            sqpn    : cntrl.cntrlStatus.getDQPN,
            immDt   : wcGenReqRQ.immDt,
            rkey2Inv: wcGenReqRQ.rkey2Inv
        };
        return tagged Valid workComp;
    end
    else begin
        return tagged Invalid;
    end
endfunction

// function Maybe#(WorkComp) genErrFlushWorkComp4WorkCompGenReqRQ(
//     Controller cntrl, WorkCompGenReqRQ wcGenReqRQ
// );
//     let maybeWorkCompOpCode = rdmaOpCode2WorkCompOpCode4RQ(wcGenReqRQ.reqOpCode);
//     let wcFlags = rdmaOpCode2WorkCompFlagsRQ(wcGenReqRQ.reqOpCode);
//     if (
//         maybeWorkCompOpCode matches tagged Valid .opcode &&&
//         wcGenReqRQ.rrID matches tagged Valid .rrID
//     ) begin
//         let workComp = WorkComp {
//             id      : rrID,
//             opcode  : opcode,
//             flags   : wcFlags,
//             status  : IBV_WC_WR_FLUSH_ERR,
//             len     : wcGenReqRQ.len,
//             pkey    : cntrl.cntrlStatus.getPKEY,
//             dqpn    : cntrl.cntrlStatus.getSQPN,
//             sqpn    : cntrl.cntrlStatus.getDQPN,
//             immDt   : wcGenReqRQ.immDt,
//             rkey2Inv: wcGenReqRQ.rkey2Inv
//         };
//         return tagged Valid workComp;
//     end
//     else begin
//         return tagged Invalid;
//     end
// endfunction

// function WorkComp genErrFlushWorkComp4RecvReq(
//     Controller cntrl, RecvReq rr
// );
//     let workComp = WorkComp {
//         id      : rr.id,
//         opcode  : IBV_WC_RECV,
//         flags   : IBV_WC_NO_FLAGS,
//         status  : IBV_WC_WR_FLUSH_ERR,
//         len     : rr.len,
//         pkey    : cntrl.cntrlStatus.getPKEY,
//         dqpn    : cntrl.cntrlStatus.getSQPN,
//         sqpn    : cntrl.cntrlStatus.getDQPN,
//         immDt   : tagged Invalid,
//         rkey2Inv: tagged Invalid
//     };
//     return workComp;
// endfunction

typedef struct {
    WorkCompGenReqRQ wcGenReqRQ;
    Maybe#(WorkComp) maybeWorkComp;
    Bool             isSendReq;
    Bool             isWriteReq;
    Bool             isWriteImmReq;
    Bool             isFirstOrOnlyReq;
    Bool             isLastOrOnlyReq;
    Bool             isWorkCompSuccess;
    Bool             needWaitDmaRespWhenNormal;
} PendingWorkCompRQ deriving(Bits);

interface WorkCompGenRQ;
    interface PipeOut#(WorkComp) workCompPipeOut;
    interface PipeOut#(WorkCompStatus) workCompStatusPipeOutRQ;
endinterface

module mkWorkCompGenRQ#(
    Controller cntrl,
    PipeOut#(PayloadConResp) payloadConRespPipeIn,
    PipeOut#(WorkCompGenReqRQ) wcGenReqPipeInFromRQ
)(WorkCompGenRQ);
    // Output FIFO for PipeOut
    FIFOF#(WorkComp)      workCompOutQ4RQ <- mkSizedFIFOF(valueOf(MAX_CQE));
    FIFOF#(WorkCompStatus)   wcStatusQ4SQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(PendingWorkCompRQ) dmaWaitingQ <- mkFIFOF;
    FIFOF#(PendingWorkCompRQ) genWorkCompQ <- mkFIFOF;

    Reg#(WorkCompGenState) workCompGenStateReg <- mkReg(WC_GEN_ST_STOP);

    let inNormalState = cntrl.cntrlStatus.isNonErr && workCompGenStateReg == WC_GEN_ST_NORMAL;
    let inErrorState  = cntrl.cntrlStatus.isERR || workCompGenStateReg == WC_GEN_ST_ERR_FLUSH;

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (cntrl.cntrlStatus.isReset);
        workCompOutQ4RQ.clear;
        wcStatusQ4SQ.clear;

        dmaWaitingQ.clear;

        workCompGenStateReg <= WC_GEN_ST_STOP;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule start if (cntrl.cntrlStatus.isNonErr && workCompGenStateReg == WC_GEN_ST_STOP);
        workCompGenStateReg <= WC_GEN_ST_NORMAL;
    endrule

    (* conflict_free = "recvWorkCompReqRQ, \
                        waitDmaDoneRQ, \
                        genWorkCompRQ, \
                        noDmaWaitRQ, \
                        errFlushRQ, \
                        discardPayloadConRespRQ" *)
    rule recvWorkCompReqRQ if (inNormalState || inErrorState);
        let wcGenReqRQ = wcGenReqPipeInFromRQ.first;
        wcGenReqPipeInFromRQ.deq;

        let reqOpCode   = wcGenReqRQ.reqOpCode;
        let isSendReq   = isSendReqRdmaOpCode(reqOpCode);
        let isWriteReq  = isWriteReqRdmaOpCode(reqOpCode);
        let isWriteImmReq    = isWriteImmReqRdmaOpCode(reqOpCode);
        let isFirstOrOnlyReq = isFirstOrOnlyRdmaOpCode(reqOpCode);
        let isLastOrOnlyReq  = isLastOrOnlyRdmaOpCode(reqOpCode);

        let maybeWorkComp             = genWorkComp4RecvReq(cntrl, wcGenReqRQ);
        let isWorkCompSuccess         = wcGenReqRQ.wcStatus == IBV_WC_SUCCESS;
        let needWaitDmaRespWhenNormal = !wcGenReqRQ.isZeroDmaLen && (isSendReq || isWriteReq);

        let pendingWorkCompRQ = PendingWorkCompRQ {
            wcGenReqRQ               : wcGenReqRQ,
            maybeWorkComp            : maybeWorkComp,
            isSendReq                : isSendReq,
            isWriteReq               : isWriteReq,
            isWriteImmReq            : isWriteImmReq,
            isFirstOrOnlyReq         : isFirstOrOnlyReq,
            isLastOrOnlyReq          : isLastOrOnlyReq,
            isWorkCompSuccess        : isWorkCompSuccess,
            needWaitDmaRespWhenNormal: needWaitDmaRespWhenNormal
        };

        dmaWaitingQ.enq(pendingWorkCompRQ);
        // $display(
        //     "time=%0t: received wcGenReqRQ=", $time, fshow(wcGenReqRQ),
        //     ", maybeWorkComp=", fshow(maybeWorkComp),
        //     ", needWaitDmaRespWhenNormal=", fshow(needWaitDmaRespWhenNormal)
        // );
    endrule

    rule waitDmaDoneRQ if (inNormalState);
        let pendingWorkCompRQ = dmaWaitingQ.first;
        dmaWaitingQ.deq;

        let wcGenReqRQ                = pendingWorkCompRQ.wcGenReqRQ;
        let maybeWorkComp             = pendingWorkCompRQ.maybeWorkComp;
        let isSendReq                 = pendingWorkCompRQ.isSendReq;
        // let isWriteReq                = pendingWorkCompRQ.isWriteReq;
        let isWriteImmReq             = pendingWorkCompRQ.isWriteImmReq;
        let isLastOrOnlyReq           = pendingWorkCompRQ.isLastOrOnlyReq;
        let isWorkCompSuccess         = pendingWorkCompRQ.isWorkCompSuccess;
        let needWaitDmaRespWhenNormal = pendingWorkCompRQ.needWaitDmaRespWhenNormal;

        if (isWorkCompSuccess) begin
            if (isLastOrOnlyReq && (isSendReq || isWriteImmReq)) begin
                genWorkCompQ.enq(pendingWorkCompRQ);
            end

            if (needWaitDmaRespWhenNormal) begin
                // TODO: report error if waiting too long for DMA write response
                let payloadConsumeResp = payloadConRespPipeIn.first;
                payloadConRespPipeIn.deq;

                // TODO: better error handling
                let dmaRespPsnMatch = payloadConsumeResp.dmaWriteResp.psn == wcGenReqRQ.reqPSN;
                immAssert (
                    dmaRespPsnMatch,
                    "dmaWriteRespMatchPSN assertion @ mkWorkCompGenRQ",
                    $format(
                        "dmaRespPsnMatch=", fshow(dmaRespPsnMatch),
                        " should either be true, payloadConsumeResp.dmaWriteResp.psn=%h should == wcGenReqRQ.reqPSN=%h",
                        payloadConsumeResp.dmaWriteResp.psn, wcGenReqRQ.reqPSN,
                        ", reqOpCode=", fshow(wcGenReqRQ.reqOpCode)
                    )
                );
                // $display(
                //     "time=%0t: payloadConsumeResp=", $time, fshow(payloadConsumeResp),
                //     ", needWaitDmaRespWhenNormal=", fshow(needWaitDmaRespWhenNormal)
                // );
            end
        end
        else begin
            wcStatusQ4SQ.enq(wcGenReqRQ.wcStatus);
            genWorkCompQ.enq(pendingWorkCompRQ);
        end
        // $display(
        //     "time=%0t: wcGenReqRQ=", $time, fshow(wcGenReqRQ),
        //     ", isWorkCompSuccess=", fshow(isWorkCompSuccess),
        //     ", needWaitDmaRespWhenNormal=", fshow(needWaitDmaRespWhenNormal)
        // );
    endrule

    rule genWorkCompRQ if (inNormalState);
        let pendingWorkCompRQ = genWorkCompQ.first;
        genWorkCompQ.deq;

        let wcGenReqRQ        = pendingWorkCompRQ.wcGenReqRQ;
        let maybeWorkComp     = pendingWorkCompRQ.maybeWorkComp;
        let isWorkCompSuccess = pendingWorkCompRQ.isWorkCompSuccess;

        // TODO: handle CQ full
        // let isCompQueueFull = False;
        if (isWorkCompSuccess) begin
            immAssert(
                isValid(maybeWorkComp),
                "maybeWorkComp assertion @ mkWorkCompGenRQ",
                $format(
                    "maybeWorkComp=", fshow(maybeWorkComp),
                    " should be valid when wcGenReqRQ=", fshow(wcGenReqRQ)
                )
            );

            let workComp = unwrapMaybe(maybeWorkComp);
            // if (workCompOutQ4RQ.notFull) begin
            workCompOutQ4RQ.enq(workComp);
            // end
            // else begin
            //     isCompQueueFull = True;
            // end
        end
        else begin
            // wcStatusQ4SQ.enq(wcGenReqRQ.wcStatus);
            workCompGenStateReg <= WC_GEN_ST_ERR_FLUSH;

            // As for RQ, error requests might not correspond to RecvReq
            if (maybeWorkComp matches tagged Valid .workComp) begin
                // if (workCompOutQ4RQ.notFull) begin
                workCompOutQ4RQ.enq(workComp);
                // end
                // else begin
                //     isCompQueueFull = True;
                // end
            end
            // $display(
            //     "time=%0t:", $time,
            //     " set mkWorkCompGenRQ to error state, wcStatus=",
            //     fshow(wcGenReqRQ.wcStatus),
            //     ", isWorkCompSuccess=", fshow(isWorkCompSuccess),
            //     ", wcGenReqRQ=", fshow(wcGenReqRQ)
            // );
        end

        // $display(
        //     "time=%0t: wcGenReqRQ=", $time, fshow(wcGenReqRQ),
        //     ", maybeWorkComp=", fshow(maybeWorkComp),
        //     ", isWorkCompSuccess=", fshow(isWorkCompSuccess)
        // );
    endrule

    rule noDmaWaitRQ if (inErrorState);
        let pendingWorkCompRQ = dmaWaitingQ.first;
        dmaWaitingQ.deq;

        genWorkCompQ.enq(pendingWorkCompRQ);
    endrule

    rule errFlushRQ if (inErrorState);
        let pendingWorkCompRQ = genWorkCompQ.first;
        genWorkCompQ.deq;

        let wcGenReqRQ       = pendingWorkCompRQ.wcGenReqRQ;
        let maybeErrFlushWC  = pendingWorkCompRQ.maybeWorkComp;
        let reqOpCode        = wcGenReqRQ.reqOpCode;
        let isSendReq        = pendingWorkCompRQ.isSendReq;
        let isWriteImmReq    = pendingWorkCompRQ.isWriteImmReq;
        let isFirstOrOnlyReq = pendingWorkCompRQ.isFirstOrOnlyReq;
        // let isCompQueueFull  = False;

        if (maybeErrFlushWC matches tagged Valid .wc) begin
            let errFlushWC = wc;
            errFlushWC.flags  = IBV_WC_NO_FLAGS;
            errFlushWC.status = IBV_WC_WR_FLUSH_ERR;

            immAssert(
                isSendReq || isWriteImmReq,
                "isSendReq or isWriteImmReq assertion @ mkWorkCompGenRQ",
                $format(
                    "maybeErrFlushWC=", fshow(maybeErrFlushWC),
                    " should be valid, when reqOpCode=", fshow(reqOpCode),
                    " should be send or write with imm"
                )
            );

            // When error, generate WC in RQ on first or only send request packets,
            // since the middle or last send request packets might be discarded.
            if ((isSendReq && isFirstOrOnlyReq) || isWriteImmReq) begin
                // if (workCompOutQ4RQ.notFull) begin
                workCompOutQ4RQ.enq(errFlushWC);
                // end
                // else begin
                //     isCompQueueFull = True;
                // end
            end
        end

        // $display(
        //     "time=%0t: flush wcGenReqPipeInFromRQ, wcGenReqRQ=",
        //     $time, fshow(wcGenReqRQ),
        //     ", maybeErrFlushWC=", fshow(maybeErrFlushWC)
        // );
    endrule

    rule discardPayloadConRespRQ if (inErrorState);
        let payloadConsumeResp = payloadConRespPipeIn.first;
        payloadConRespPipeIn.deq;
    endrule

    interface workCompPipeOut         = convertFifo2PipeOut(workCompOutQ4RQ);
    interface workCompStatusPipeOutRQ = convertFifo2PipeOut(wcStatusQ4SQ);
endmodule
