import FIFOF :: *;
import PAClib :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import ScanFIFOF :: *;
import Settings :: *;
import Utils :: *;

function Maybe#(WorkComp) genWorkComp4WorkReq(
    Controller cntrl, WorkCompGenReqSQ wcGenReqSQ
);
    let wr = wcGenReqSQ.pendingWR.wr;
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
            pkey    : cntrl.getPKEY,
            dqpn    : cntrl.getDQPN,
            sqpn    : cntrl.getSQPN,
            immDt   : tagged Invalid,
            rkey2Inv: tagged Invalid
        };
        return tagged Valid workComp;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(WorkComp) genWorkComp4RecvReq(
    Controller cntrl, WorkCompGenReqRQ wcGenReqRQ
);
    let rr = wcGenReqRQ.recvReq;
    let maybeWorkCompOpCode = rdmaOpCode2WorkCompOpCode4RQ(wcGenReqRQ.reqOpCode);
    let wcFlags = rdmaOpCode2WorkCompFlags(wcGenReqRQ.reqOpCode);
    if (maybeWorkCompOpCode matches tagged Valid .opcode) begin
        let workComp = WorkComp {
            id      : rr.id,
            opcode  : opcode,
            flags   : wcFlags,
            status  : wcGenReqRQ.wcStatus,
            len     : rr.len,
            pkey    : cntrl.getPKEY,
            dqpn    : cntrl.getDQPN,
            sqpn    : cntrl.getSQPN,
            immDt   : wcGenReqRQ.immDt,
            rkey2Inv: wcGenReqRQ.rkey2Inv
        };
        return tagged Valid workComp;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(WorkComp) genErrFlushWorkComp4WorkReq(
    Controller cntrl, WorkReq wr
);
    let maybeWorkCompOpCode = workReqOpCode2WorkCompOpCode4SQ(wr.opcode);

    if (maybeWorkCompOpCode matches tagged Valid .opcode) begin
        let workComp = WorkComp {
            id      : wr.id,
            opcode  : opcode,
            flags   : IBV_WC_NO_FLAGS,
            status  : IBV_WC_WR_FLUSH_ERR,
            len     : wr.len,
            pkey    : cntrl.getPKEY,
            dqpn    : cntrl.getDQPN,
            sqpn    : cntrl.getSQPN,
            immDt   : tagged Invalid,
            rkey2Inv: tagged Invalid
        };
        return tagged Valid workComp;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function WorkComp genErrFlushWorkComp4RecvReq(
    Controller cntrl, RecvReq rr
);
    let workComp = WorkComp {
        id      : rr.id,
        opcode  : IBV_WC_RECV,
        flags   : IBV_WC_NO_FLAGS,
        status  : IBV_WC_WR_FLUSH_ERR,
        len     : rr.len,
        pkey    : cntrl.getPKEY,
        dqpn    : cntrl.getDQPN,
        sqpn    : cntrl.getSQPN,
        immDt   : tagged Invalid,
        rkey2Inv: tagged Invalid
    };
    return workComp;
endfunction

typedef enum {
    WC_GEN_ST_STOP,
    WC_GEN_ST_NORMAL,
    WC_GEN_ST_ERR_FLUSH
} WorkCompGenState deriving(Bits, Eq);

module mkWorkCompGenSQ#(
    Controller cntrl,
    PipeOut#(PayloadConResp) payloadConRespPipeIn,
    PendingWorkReqBuf pendingWorkReqBuf,
    // RecvReqBuf recvReqBuf,
    PipeOut#(WorkCompGenReqSQ) wcGenReqPipeInFromReqGenInSQ,
    PipeOut#(WorkCompGenReqSQ) wcGenReqPipeInFromRespHandleInSQ
    // PipeOut#(WorkCompGenReqRQ) wcGenReqPipeInFromRQ
)(PipeOut#(WorkComp));
    // FIFOF#(WorkComp) workCompOutQ4RQ <- mkSizedFIFOF(valueOf(MAX_CQE));
    FIFOF#(WorkComp) workCompOutQ4SQ <- mkSizedFIFOF(valueOf(MAX_CQE));

    // FIFOF#(WorkCompGenReqRQ) pendingWorkCompQ4RQ <- mkSizedFIFOF(valueOf(MAX_PENDING_WORK_COMP_NUM));
    FIFOF#(WorkCompGenReqSQ) pendingWorkCompQ4SQ <- mkSizedFIFOF(valueOf(MAX_PENDING_WORK_COMP_NUM));

    Reg#(WorkCompGenState) workCompGenStateReg <- mkReg(WC_GEN_ST_STOP);

    function ActionValue#(Bool) submitWorkCompUntilFirstErr(
        Bool wcWaitDmaResp,
        Bool needWorkCompWhenNormal,
        WorkCompReqType wcReqType,
        PSN dmaWriteRespMatchPSN,
        Maybe#(WorkComp) maybeWorkComp,
        FIFOF#(WorkCompGenReqSQ) pendingWorkCompQ,
        FIFOF#(WorkComp) workCompOutQ
    );
        actionvalue
            dynAssert(
                isValid(maybeWorkComp),
                "maybeWorkComp assertion @ mkWorkCompGen",
                $format("maybeWorkComp=", fshow(maybeWorkComp), " should be valid")
            );
            let workComp = unwrapMaybe(maybeWorkComp);
            let isWorkCompSuccess = workComp.status == IBV_WC_SUCCESS;
            let isCompQueueFull = False;

            if (isWorkCompSuccess) begin
                if (wcWaitDmaResp) begin
                    // TODO: report error if waiting too long for DMA write response
                    let payloadConsumeResp = payloadConRespPipeIn.first;
                    payloadConRespPipeIn.deq;
                    dynAssert (
                        payloadConsumeResp.dmaWriteResp.psn == dmaWriteRespMatchPSN,
                        "dmaWriteRespMatchPSN assertion @ mkWorkCompGen",
                        $format(
                            "payloadConsumeResp.dmaWriteResp.psn=%h should == dmaWriteRespMatchPSN=%h",
                            payloadConsumeResp.dmaWriteResp.psn, dmaWriteRespMatchPSN
                        )
                    );
                    pendingWorkCompQ.deq;

                    if (needWorkCompWhenNormal) begin
                        if (workCompOutQ.notFull) begin
                            workCompOutQ.enq(workComp);
                        end
                        else begin
                            isCompQueueFull = True;
                        end
                    end
                end
                else begin
                    pendingWorkCompQ.deq;

                    if (needWorkCompWhenNormal) begin
                        if (workCompOutQ.notFull) begin
                            workCompOutQ.enq(workComp);
                        end
                        else begin
                            isCompQueueFull = True;
                        end
                    end
                end
            end
            else begin
                pendingWorkCompQ.deq;

                if (workCompOutQ.notFull) begin
                    workCompOutQ.enq(workComp);
                end
                else begin
                    isCompQueueFull = True;
                end
            end

            return !isWorkCompSuccess || isCompQueueFull;
        endactionvalue
    endfunction

    function Action flushPendingWorkCompGenReqQ(
        WorkComp errFlushWC,
        FIFOF#(WorkCompGenReqSQ) pendingWorkCompQ,
        FIFOF#(WorkComp) workCompOutQ
    );
        action
            let wcGenReq = pendingWorkCompQ.first;
            pendingWorkCompQ.deq;
            if (
                wcGenReq.wcReqType == WC_REQ_TYPE_SUC_FULL_ACK ||
                wcGenReq.wcReqType == WC_REQ_TYPE_ERR_FULL_ACK
            ) begin
                workCompOutQ.enq(errFlushWC);
            end
        endaction
    endfunction

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule start if (cntrl.isRTS && workCompGenStateReg == WC_GEN_ST_STOP);
        // if () begin
            workCompGenStateReg <= WC_GEN_ST_NORMAL;
        // end
    endrule

    rule recvWorkCompGenReq if (
        workCompGenStateReg == WC_GEN_ST_NORMAL ||
        workCompGenStateReg == WC_GEN_ST_ERR_FLUSH
    );
        if (wcGenReqPipeInFromReqGenInSQ.notEmpty) begin
            let wcGenReqSQ = wcGenReqPipeInFromReqGenInSQ.first;
            wcGenReqPipeInFromReqGenInSQ.deq;
            pendingWorkCompQ4SQ.enq(wcGenReqSQ);
        end
        else if (wcGenReqPipeInFromRespHandleInSQ.notEmpty) begin
            let wcGenReqSQ = wcGenReqPipeInFromRespHandleInSQ.first;
            wcGenReqPipeInFromRespHandleInSQ.deq;
            pendingWorkCompQ4SQ.enq(wcGenReqSQ);
        end

        // if (wcGenReqFromRQ.notEmpty) begin
        //     let wcGenReqRQ = wcGenReqFromRQ.first;
        //     wcGenReqFromRQ.deq;
        //     pendingWorkCompQ4RQ.enq(wcGenReqRQ);
        // end
    endrule

    rule genWorkCompNormalCase if (cntrl.isRTS && workCompGenStateReg == WC_GEN_ST_NORMAL);
        // let hasErrWorkCompOrCompQueueFullSQ = False;
        // let hasErrWorkCompOrCompQueueFullRQ = False;

        // if (pendingWorkCompQ4SQ.notEmpty) begin
        let wcGenReqSQ = pendingWorkCompQ4SQ.first;

        let maybeWorkComp = genWorkComp4WorkReq(cntrl, wcGenReqSQ);
        let needWorkCompWhenNormal =
            workReqNeedWorkComp(wcGenReqSQ.pendingWR.wr) &&
            wcGenReqSQ.wcReqType == WC_REQ_TYPE_SUC_FULL_ACK;

        let hasErrWorkCompOrCompQueueFullSQ <- submitWorkCompUntilFirstErr(
            wcGenReqSQ.wcWaitDmaResp,
            needWorkCompWhenNormal,
            wcGenReqSQ.wcReqType,
            wcGenReqSQ.respPSN,
            maybeWorkComp,
            pendingWorkCompQ4SQ,
            workCompOutQ4SQ
        );
        // end

        // if (pendingWorkCompQ4RQ.notEmpty) begin
        //     let wcGenReqRQ = pendingWorkCompQ4RQ.first;
        //     pendingWorkCompQ4RQ.deq;

        //     let maybeWorkComp = genWorkComp4WorkReq(cntrl, wcGenReqRQ);
        //     let needWorkCompWhenNormal = wcGenReqRQ.wcReqType == WC_REQ_TYPE_SUC_FULL_ACK;
        //     hasErrWorkCompOrCompQueueFullRQ <- submitWorkCompUntilFirstErr(
        //         wcGenReqRQ.wcWaitDmaResp,
        //         needWorkCompWhenNormal,
        //         wcGenReqRQ.wcReqType,
        //         wcGenReqRQ.reqPSN,
        //         maybeWorkComp,
        //         pendingWorkCompQ4RQ,
        //         workCompOutQ4RQ
        //     );
        // end

        if (hasErrWorkCompOrCompQueueFullSQ) begin
            cntrl.setStateErr;
            workCompGenStateReg <= WC_GEN_ST_ERR_FLUSH;

            // $display(
            //     "time=%0d: hasErrWorkCompOrCompQueueFullSQ=",
            //     $time, fshow(hasErrWorkCompOrCompQueueFullSQ),
            //     ", wcGenReqSQ=", fshow(wcGenReqSQ)
            // );
        end
    endrule

    // rule exitPendingWorkCompGenReqSQ if (
    //     cntrl.isERR &&
    //     workCompGenStateReg == WC_GEN_ST_ERR_FLUSH
    // );
    //     if (pendingWorkCompQ4SQ.notEmpty) begin
    //         workCompGenStateReg <= WC_GEN_ST_ERR_FLUSH_PENDING_WR;
    //     end
    // endrule

    rule errFlushPendingWorkCompGenReqSQ if (
        cntrl.isERR &&
        workCompGenStateReg == WC_GEN_ST_ERR_FLUSH
    );
        let wcGenReqSQ = pendingWorkCompQ4SQ.first;

        let maybeErrFlushWC = genErrFlushWorkComp4WorkReq(cntrl, wcGenReqSQ.pendingWR.wr);
        dynAssert(
            isValid(maybeErrFlushWC),
            "maybeErrFlushWC assertion @ mkWorkCompGen",
            $format("maybeErrFlushWC=", fshow(maybeErrFlushWC), " should be valid")
        );
        let errFlushWC = unwrapMaybe(maybeErrFlushWC);
        flushPendingWorkCompGenReqQ(
            errFlushWC,
            pendingWorkCompQ4SQ,
            workCompOutQ4SQ
        );

        $display(
            "time=%0d: flush pendingWorkCompQ4SQ, errFlushWC=",
            $time, fshow(errFlushWC)
        );

        // if (pendingWorkCompQ4RQ.notEmpty) begin
        //     let wcGenReqRQ = pendingWorkCompQ4RQ.first;
        //     pendingWorkCompQ4RQ.deq;
        //     let errFlushWC = genErrFlushWorkComp4RecvReq(cntrl, wcGenReqRQ.recvReq);
        //     flushPendingWorkCompGenReqQ(
        //         errFlushWC,
        //         pendingWorkCompQ,
        //         workCompOutQ
        //     );
        // end
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule errFlushWorkReqSQ if (
        cntrl.isERR && !pendingWorkCompQ4SQ.notEmpty
        // workCompGenStateReg == WC_GEN_ST_ERR_FLUSH
    );
        // if (!pendingWorkCompQ4SQ.notEmpty) begin
            if (pendingWorkReqBuf.fifoF.notEmpty) begin
                let pendingWR = pendingWorkReqBuf.fifoF.first;
                pendingWorkReqBuf.fifoF.deq;

                let maybeErrFlushWC = genErrFlushWorkComp4WorkReq(cntrl, pendingWR.wr);
                dynAssert(
                    isValid(maybeErrFlushWC),
                    "maybeErrFlushWC assertion @ mkWorkCompGen",
                    $format("maybeErrFlushWC=", fshow(maybeErrFlushWC), " should be valid")
                );

                let errFlushWC = unwrapMaybe(maybeErrFlushWC);
                if (workCompOutQ4SQ.notFull) begin
                    workCompOutQ4SQ.enq(errFlushWC);
                end

                // $display("time=%0d: flush pendingWorkReqBuf, errFlushWR=", $time, fshow(errFlushWC));
            end
            else begin
                // Notify controller when flush done
                cntrl.errFlushDone;
                $display(
                    "time=%0d: error flush done, pendingWorkReqBuf.scanIfc.count=%0d",
                    $time, pendingWorkReqBuf.scanIfc.count
                );
                // workCompGenStateReg <= WC_GEN_ST_STOP;
            end
        // end

        // if (recvReqBuf.notEmpty) begin
        //     let pendingRR = recvReqBuf.first;
        //     recvReqBuf.deq;
        //     let errFlushWC = genErrFlushWorkComp4RecvReq(cntrl, pendingRR);
        //     if (workCompOutQ4RQ.notFull) begin
        //         workCompOutQ4RQ.enq(errFlushWC);
        //     end
        // end
    endrule

    return convertFifo2PipeOut(workCompOutQ4SQ);
    // interface workCompPipeOutRQ = convertFifo2PipeOut(workCompOutQ4RQ);
endmodule
