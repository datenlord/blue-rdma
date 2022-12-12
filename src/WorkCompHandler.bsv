import FIFOF :: *;
import PAClib :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import ScanFIFOF :: *;
import Settings :: *;
import Utils :: *;

function Maybe#(WorkComp) genWorkCompFromWorkReq(
    Controller cntrl,
    WorkReq wr,
    WorkCompStatus wcStatus
);
    let maybeWorkCompOpCode = workReqOpCode2WorkCompOpCode4SQ(wr.opcode);
    let wcFlags = workReqOpCode2WorkCompFlags(wr.opcode);

    if (maybeWorkCompOpCode matches tagged Valid .opcode) begin
        let wc = WorkComp {
            id      : wr.id,
            opcode  : opcode,
            flags   : wcFlags,
            status  : wcStatus,
            len     : wr.len,
            pkey    : cntrl.getPKEY,
            dqpn    : cntrl.getDQPN,
            sqpn    : cntrl.getSQPN,
            immDt   : wr.immDt,
            rkey2Inv: wr.rkey2Inv
        };
        return tagged Valid wc;
    end
    else begin
        return tagged Invalid;
    end
endfunction

// function WorkComp genFlushErrWorkCompFromRecvReq(
//     Controller cntrl,
//     RecvReq rr
// );
//     let wc = WorkComp {
//         id      : rr.id,
//         opcode  : IBV_WC_RECV,
//         flags   : IBV_WC_NO_FLAGS,
//         status  : IBV_WC_WR_FLUSH_ERR,
//         len     : rr.len,
//         pkey    : cntrl.pkey,
//         dqpn    : cntrl.dqpn,
//         sqpn    : cntrl.sqpn,
//         immDt   : tagged Invalid,
//         rkey2Inv: tagged Invalid
//     };
//     return wc;
// endfunction

interface WorkCompHandler;
    // This method only used for SQ to report error when request generation
    method Action submitFromReqGenInSQ(
        PendingWorkReq pendingWR,
        WorkCompStatus wcStatus
    );
    method Action submitFromRespHandleInSQ(
        PendingWorkReq pendingWR,
        Bool wcWaitDmaResp,
        WorkCompStatus wcStatus
    );
    // method Action submitFromRQ(
    //     PendingWorkReq pendingWR,
    //     Bool wcWaitDmaResp,
    //     WorkCompStatus wcStatus
    // );
    // method Action reqHandlePipeEmptyInRQ;
    method Action respHandlePipeEmptyInSQ;
    // interface PipeOut#(WorkComp) workCompPipeOutRQ;
    interface PipeOut#(WorkComp) workCompPipeOutSQ;
endinterface

// TODO: support WC from RQ
module mkWorkCompHandler#(
    Controller cntrl,
    PipeOut#(PayloadConResp) payloadConRespPipeIn,
    PendingWorkReqBuf pendingWorkReqBuf
    // RecvReqBuf recvReqBuf
)(WorkCompHandler);
    // FIFOF#(WorkComp) workCompOutQ4RQ <- mkSizedFIFOF(valueOf(MAX_CQE));
    FIFOF#(WorkComp) workCompOutQ4SQ <- mkSizedFIFOF(valueOf(MAX_CQE));

    // There will be at most one item in pendingWorkCompQ4ReqGenInSQ,
    // since the item in pendingWorkCompQ4ReqGenInSQ is for error WC.
    FIFOF#(Tuple3#(PendingWorkReq, Bool, WorkCompStatus)) pendingWorkCompQ4ReqGenInSQ <- mkFIFOF;
    FIFOF#(Tuple3#(PendingWorkReq, Bool, WorkCompStatus)) pendingWorkCompQ4RespHandleInSQ <-
        mkSizedFIFOF(valueOf(MAX_PENDING_REQ_NUM));
    // FIFOF#(Tuple3#(PendingWorkReq, Bool, WorkCompStatus)) pendingWorkCompQ4RQ <-
    //     mkSizedFIFOF(valueOf(MAX_PENDING_REQ_NUM));

    // Reg#(Bool)  reqHandlePipeEmptyReg <- mkRegU;
    Reg#(Bool) respHandlePipeEmptyReg <- mkRegU;

    function Action handleWorkComp(
        FIFOF#(Tuple3#(PendingWorkReq, Bool, WorkCompStatus)) pendingWorkCompQ,
        FIFOF#(WorkComp) workCompOutQ
    );
        action
            let { pendingWR, wcWaitDmaResp, wcStatus } = pendingWorkCompQ.first;
            let maybeWorkComp = genWorkCompFromWorkReq(cntrl, pendingWR.wr, wcStatus);
            dynAssert(
                isValid(maybeWorkComp),
                "maybeWorkComp assertion @ mkWorkCompHandler",
                $format("maybeWorkComp=", fshow(maybeWorkComp), " should be valid")
            );

            let workComp = fromMaybe(?, maybeWorkComp);
            if (wcWaitDmaResp) begin
                dynAssert(
                    isValid(pendingWR.startPSN) &&
                    isValid(pendingWR.endPSN)   &&
                    isValid(pendingWR.pktNum)   &&
                    isValid(pendingWR.isOnlyReqPkt),
                    "pendingWR assertion @ mkWorkCompHandler",
                    $format(
                        "pendingWR should have valid PSN and PktNum when wcWaitDmaResp=",
                        fshow(wcWaitDmaResp), ", pendingWR=", fshow(pendingWR)
                    )
                );
                let endPSN = fromMaybe(?, pendingWR.endPSN);

                // TODO: report error if waiting too long for DMA write response
                let payloadConsumeResp = payloadConRespPipeIn.first;
                payloadConRespPipeIn.deq;
                if (payloadConsumeResp.dmaWriteResp.psn == endPSN) begin
                    pendingWorkCompQ.deq;
                    workCompOutQ.enq(workComp);
                end
            end
            else begin
                pendingWorkCompQ.deq;
                workCompOutQ.enq(workComp);
            end
        endaction
    endfunction

    function Action submitWorkComp(
        PendingWorkReq pendingWR,
        Bool wcWaitDmaResp,
        WorkCompStatus wcStatus,
        FIFOF#(Tuple3#(PendingWorkReq, Bool, WorkCompStatus)) pendingWorkCompQ,
        FIFOF#(WorkComp) workCompOutQ
    );
        action
            // $display(
            //     "time=%0d: recv pendingWR=", $time, fshow(pendingWR),
            //     ", wcStatus=", fshow(wcStatus)
            // );

            let errWorkCompStatus = wcStatus != IBV_WC_SUCCESS;
            if (workReqNeedWorkComp(pendingWR.wr) || errWorkCompStatus) begin
                pendingWorkCompQ.enq(tuple3(pendingWR, wcWaitDmaResp, wcStatus));
            end
            if (errWorkCompStatus) begin
                cntrl.setStateErr;
                // reqHandlePipeEmptyReg  <= False;
                respHandlePipeEmptyReg <= False;

                dynAssert(
                    !wcWaitDmaResp,
                    "wcWaitDmaResp assertion @ mkWorkCompHandler",
                    $format(
                        "wcWaitDmaResp=", fshow(wcWaitDmaResp),
                        " should be false when error WC, wcStatus=", fshow(wcStatus)
                    )
                );
            end
/*
            else if (!workCompOutQ.notFull) begin // || !workCompOutQ4RQ.notFull)
                // Change to error state if CQ full
                cntrl.setStateErr;
                // TODO: async event to report CQ full
            end
*/
        endaction
    endfunction

    rule outputWorkComp if (cntrl.isRTRorRTS || cntrl.isERR);
        dynAssert(
            workCompOutQ4SQ.notFull, // || !workCompOutQ4RQ.notFull,
            "CQ not full assertion @ mkWorkCompHandler",
            $format(
                "workCompOutQ4RQ and workCompOutQ4SQ should not be full",
                // ", workCompOutQ4RQ.notFull=", fshow(workCompOutQ4RQ.notFull),
                ", workCompOutQ4SQ.notFull=", fshow(workCompOutQ4SQ.notFull)
            )
        );

        if (pendingWorkCompQ4RespHandleInSQ.notEmpty) begin
            handleWorkComp(pendingWorkCompQ4RespHandleInSQ, workCompOutQ4SQ);
        end

        // if (pendingWorkCompQ4RQ.notEmpty) begin
        //     handleWorkComp(pendingWorkCompQ4RQ, workCompOutQ4RQ);
        // end
    endrule

    rule errFlush if (cntrl.isERR);
        if (pendingWorkReqBuf.fifoF.notEmpty && respHandlePipeEmptyReg) begin
            let pendingWR = pendingWorkReqBuf.fifoF.first;
            pendingWorkReqBuf.fifoF.deq;

            let wcStatus = IBV_WC_WR_FLUSH_ERR;
            if (pendingWorkCompQ4ReqGenInSQ.notEmpty) begin
                let { pwr, wcwdr, wcs } = pendingWorkCompQ4ReqGenInSQ.first;
                if (pwr.wr.id == pendingWR.wr.id) begin
                    pendingWorkCompQ4ReqGenInSQ.deq;
                    wcStatus = wcs;
                end
            end

            let wcWaitDmaResp = False;
            pendingWorkCompQ4RespHandleInSQ.enq(tuple3(pendingWR, wcWaitDmaResp, wcStatus));
        end

        if (!pendingWorkReqBuf.fifoF.notEmpty) begin
            dynAssert(
                !pendingWorkCompQ4ReqGenInSQ.notEmpty,
                "pendingWorkCompQ4ReqGenInSQ assertion @ mkWorkCompHandler",
                $format(
                    "pendingWorkCompQ4ReqGenInSQ should be empty when pendingWorkReqBuf is emtpy",
                    ", pendingWorkCompQ4ReqGenInSQ.notEmpty=",
                    fshow(pendingWorkCompQ4ReqGenInSQ.notEmpty),
                    ", pendingWorkReqBuf.fifoF.notEmpty=",
                    fshow(pendingWorkReqBuf.fifoF.notEmpty)
                )
            );
        end

        // if (recvReqBuf.notEmpty && reqHandlePipeEmptyReg) begin
        //     let pendingRR = recvReqBuf.first;
        //     recvReqBuf.deq;
        //     let workComp = genFlushErrWorkCompFromRecvReq(cntrl, pendingRR);
        //     workCompOutQ4RQ.enq(workComp);
        // end

        // TODO: check both pending WR and RR are flushed
        if (!pendingWorkReqBuf.fifoF.notEmpty) begin
            cntrl.errFlushDone;
        end
    endrule

    // This method only called when error
    method Action submitFromReqGenInSQ(
        PendingWorkReq pendingWR,
        WorkCompStatus wcStatus
    ) if (cntrl.isRTRorRTS);
        let wcWaitDmaResp = False;
        dynAssert(
            wcStatus != IBV_WC_SUCCESS,
            "wcStatus assertion @ mkWorkCompHandler",
            $format(
                "wcStatus=", fshow(wcStatus),
                " should not be success when calling submitFromReqGenInSQ()"
            )
        );
        submitWorkComp(
            pendingWR,
            wcWaitDmaResp,
            wcStatus,
            pendingWorkCompQ4ReqGenInSQ,
            workCompOutQ4SQ
        );
    endmethod

    method Action submitFromRespHandleInSQ(
        PendingWorkReq pendingWR,
        Bool wcWaitDmaResp,
        WorkCompStatus wcStatus
    ) if (cntrl.isRTRorRTS) = submitWorkComp(
        pendingWR,
        wcWaitDmaResp,
        wcStatus,
        pendingWorkCompQ4RespHandleInSQ,
        workCompOutQ4SQ
    );

    // method Action submitFromRQ(
    //     PendingWorkReq pendingWR,
    //     Bool wcWaitDmaResp,
    //     WorkCompStatus wcStatus
    // ) if (cntrl.isRTRorRTS) = submitWorkComp(
    //     pendingWR,
    //     wcWaitDmaResp,
    //     wcStatus,
    //     pendingWorkCompQ4RQ,
    //     workCompOutQ4RQ
    // );

    // method Action reqHandlePipeEmptyInRQ() if (cntrl.isERR);
    //     reqHandlePipeEmptyReg <= True;
    // endmethod

    method Action respHandlePipeEmptyInSQ() if (cntrl.isERR);
        respHandlePipeEmptyReg <= True;
    endmethod

    interface workCompPipeOutSQ = convertFifo2PipeOut(workCompOutQ4SQ);
    // interface workCompPipeOutRQ = convertFifo2PipeOut(workCompOutQ4RQ);
endmodule
