import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import MetaData :: *;
import PrimUtils :: *;
import Settings :: *;
import Utils :: *;
import Utils4Test :: *;
import WorkCompGen :: *;

(* synthesize *)
module mkTestWorkCompGenNormalCaseSQ(Empty);
    let isNormalCase = True;
    let result <- mkTestWorkCompGenSQ(isNormalCase);
endmodule

(* synthesize *)
module mkTestWorkCompGenErrFlushCaseSQ(Empty);
    let isNormalCase = False;
    let result <- mkTestWorkCompGenSQ(isNormalCase);
endmodule

module mkTestWorkCompGenSQ#(Bool isNormalCase)(Empty);
    function Bool workReqNeedDmaWriteRespSQ(PendingWorkReq pwr);
        return !isZero(pwr.wr.len) && isReadOrAtomicWorkReq(pwr.wr.opcode);
    endfunction

    let minDmaLength = 1;
    let maxDmaLength = 8192;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_512;

    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;
    // It needs extra controller to generate pending WR,
    // since WC might change controller to error state,
    // which prevent generating pending WR.
    // let cntrl4PendingWorkReqGen <- mkSimCntrl(qpType, pmtu);
    // let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let qpIndex = getDefaultIndexQP;
    // let cntrl4PendingWorkReqGen = qpMetaData.getCntrlByIndexQP(qpIndex);
    Vector#(2, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOutVec[0]);
    let pendingWorkReqPipeOut4WorkCompReq = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4DmaResp = existingPendingWorkReqPipeOutVec[1];
    FIFOF#(PendingWorkReq) pendingWorkReqPipeOut4Ref <- mkFIFOF;

    // PayloadConResp
    FIFOF#(PayloadConResp) payloadConRespQ <- mkFIFOF;

    // WC requests
    FIFOF#(WorkCompGenReqSQ) wcGenReqQ4ReqGenInSQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqSQ) wcGenReqQ4RespHandleInSQ <- mkFIFOF;
    // WC status from RQ
    // FIFOF#(WorkCompStatus) workCompStatusQFromRQ <- mkFIFOF;

    // CntrlQP for DUT that will be triggered into error state
    // let setExpectedPsnAsNextPSN = False;
    // let cntrl <- mkSimCntrlQP(qpType, pmtu, setExpectedPsnAsNextPSN);

    // DUT
    let dut <- mkWorkCompGenSQ(
        cntrlStatus,
        toPipeOut(payloadConRespQ),
        toPipeOut(wcGenReqQ4ReqGenInSQ),
        toPipeOut(wcGenReqQ4RespHandleInSQ)
        // toPipeOut(workCompStatusQFromRQ)
    );
    // let workCompPipeOut = dut.workCompPipeOut;

    Reg#(Bool) hasWorkCompGenReg <- mkReg(False);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule checkHasErr;
        if (isNormalCase) begin
            immAssert(
                !dut.hasErr,
                "hasErr assertion @ mkTestWorkCompGenRQ",
                $format("dut.hasErr=", fshow(dut.hasErr), " should be false")
            );
        end
        else if (hasWorkCompGenReg) begin
            immAssert(
                dut.hasErr,
                "hasErr assertion @ mkTestWorkCompGenRQ",
                $format("dut.hasErr=", fshow(dut.hasErr), " should be true")
            );
        end
    endrule

    rule genPayloadConResp;
        let pendingWR = pendingWorkReqPipeOut4DmaResp.first;
        pendingWorkReqPipeOut4DmaResp.deq;

        if (workReqNeedDmaWriteRespSQ(pendingWR)) begin
            let endPSN = unwrapMaybe(pendingWR.endPSN);
            let payloadConResp = PayloadConResp {
                dmaWriteResp: DmaWriteResp {
                    initiator: dontCareValue,
                    sqpn     : cntrlStatus.comm.getSQPN,
                    psn      : endPSN,
                    isRespErr: False
                }
            };
            if (isNormalCase) begin
                payloadConRespQ.enq(payloadConResp);
                // $display(
                //     "time=%0t: pendingWR=", $time, fshow(pendingWR),
                //     " payloadConResp=", fshow(payloadConResp)
                // );
            end
        end
    endrule

    rule filterWorkReqNeedWorkComp if (cntrlStatus.comm.isRTS || cntrlStatus.comm.isERR);
        let pendingWR = pendingWorkReqPipeOut4WorkCompReq.first;
        pendingWorkReqPipeOut4WorkCompReq.deq;

        let wcWaitDmaResp = workReqNeedDmaWriteRespSQ(pendingWR);
        let wcReqType = WC_REQ_TYPE_FULL_ACK;
        let triggerPSN = unwrapMaybe(pendingWR.endPSN);
        let wcStatus = isNormalCase ? IBV_WC_SUCCESS : IBV_WC_WR_FLUSH_ERR;

        let wcGenReq = WorkCompGenReqSQ {
            wr           : pendingWR.wr,
            wcWaitDmaResp: wcWaitDmaResp,
            wcReqType    : wcReqType,
            triggerPSN   : triggerPSN,
            wcStatus     : wcStatus
        };

        if (workReqNeedWorkCompSQ(pendingWR.wr)) begin
            wcGenReqQ4RespHandleInSQ.enq(wcGenReq);
            pendingWorkReqPipeOut4Ref.enq(pendingWR);

            // $display(
            //     "time=%0t: submit to workCompGen pendingWR=",
            //     $time, fshow(pendingWR)
            // );
        end
    endrule

    rule compareWC;
        let pendingWR = pendingWorkReqPipeOut4Ref.first;
        pendingWorkReqPipeOut4Ref.deq;

        let workCompSQ = dut.workCompPipeOut.first;
        dut.workCompPipeOut.deq;

        immAssert(
            workCompMatchWorkReqInSQ(workCompSQ, pendingWR.wr),
            "workCompMatchWorkReqInSQ assertion @ mkTestWorkCompGenSQ",
            $format("WC=", fshow(workCompSQ), " not match WR=", fshow(pendingWR.wr))
        );

        let expectedWorkCompStatus = isNormalCase ? IBV_WC_SUCCESS : IBV_WC_WR_FLUSH_ERR;
        immAssert(
            workCompSQ.status == expectedWorkCompStatus,
            "workCompSQ.status assertion @ mkTestWorkCompGenSQ",
            $format(
                "WC=", fshow(workCompSQ), " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        // $display(
        //     "time=%0t: WC=", $time, fshow(workCompSQ), " not match WR=", fshow(pendingWR.wr)
        // );
        hasWorkCompGenReg <= True;
        countDown.decr;
    endrule
endmodule

(* synthesize *)
module mkTestWorkCompGenNormalCaseRQ(Empty);
    let isNormalCase = True;
    let result <- mkTestWorkCompGenRQ(isNormalCase);
endmodule

(* synthesize *)
module mkTestWorkCompGenErrFlushCaseRQ(Empty);
    let isNormalCase = False;
    let result <- mkTestWorkCompGenRQ(isNormalCase);
endmodule

module mkTestWorkCompGenRQ#(Bool isNormalCase)(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 8192;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_512;

    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomSendOrWriteImmWorkReq(
        minPayloadLen, maxPayloadLen
    );
    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextRQ.statusRQ;
    // It needs extra controller to generate pending WR,
    // since WC might change controller to error state,
    // which prevent generating pending WR.
    // let cntrl4PendingWorkReqGen <- mkSimCntrl(qpType, pmtu);
    // let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let qpIndex = getDefaultIndexQP;
    // let cntrl4PendingWorkReqGen = qpMetaData.getCntrlByIndexQP(qpIndex);
    Vector#(1, PipeOut#(PendingWorkReq)) pendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOutVec[0]);

    let pendingWorkReqPipeOut = pendingWorkReqPipeOutVec[0];

    // RecvReq
    FIFOF#(RecvReq) recvReqQ <- mkFIFOF;

    // PayloadConResp
    FIFOF#(PayloadConResp) payloadConRespQ <- mkFIFOF;

    // WC requests
    FIFOF#(WorkCompGenReqRQ) workCompGenReqQ4RQ <- mkFIFOF;

    // CntrlQP for DUT that will be triggered into error state
    // let setExpectedPsnAsNextPSN = False;
    // let cntrl <- mkSimCntrlQP(qpType, pmtu, setExpectedPsnAsNextPSN);

    // DUT
    let dut <- mkWorkCompGenRQ(
        cntrlStatus,
        toPipeOut(payloadConRespQ),
        toPipeOut(workCompGenReqQ4RQ)
    );
    // let workCompPipeOut = dut.workCompPipeOut;

    // RecvReq ID
    PipeOut#(WorkReqID) recvReqIdPipeOut <- mkGenericRandomPipeOut;

    // Expected WC
    FIFOF#(Tuple5#(
        WorkReqID, WorkCompOpCode, WorkCompFlags, Maybe#(IMM), Maybe#(RKEY)
    )) expectedWorkCompQ <- mkFIFOF;

    Reg#(Bool) hasWorkCompGenReg <- mkReg(False);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));
/*
    rule setCntrlErrState if (cntrlStatus.comm.isRTS && dut.hasErr);
        // let wcStatus = dut.workCompStatusPipeOutRQ.first;
        // dut.workCompStatusPipeOutRQ.deq;

        // immAssert(
        //     wcStatus != IBV_WC_SUCCESS,
        //     "wcStatus assertion @ mkTestWorkCompGenRQ",
        //     $format("wcStatus=", fshow(wcStatus), " should not be success")
        // );
        cntrl.setStateErr;
        // $display(
        //     "time=%0t:", $time,
        //     " set CntrlQP to error state, wcStatus=", fshow(wcStatus)
        // );
    endrule
*/
    rule checkHasErr;
        if (isNormalCase) begin
            immAssert(
                !dut.hasErr,
                "hasErr assertion @ mkTestWorkCompGenRQ",
                $format("dut.hasErr=", fshow(dut.hasErr), " should be false")
            );
        end
        else if (hasWorkCompGenReg) begin
            immAssert(
                dut.hasErr,
                "hasErr assertion @ mkTestWorkCompGenRQ",
                $format("dut.hasErr=", fshow(dut.hasErr), " should be true")
            );
        end
    endrule

    rule genWorkCompReq4RQ;
        let pendingWR = pendingWorkReqPipeOut.first;
        pendingWorkReqPipeOut.deq;

        let hasImmDt   = isValid(pendingWR.wr.immDt);
        let hasIETH    = isValid(pendingWR.wr.rkey2Inv);
        let isZeroLen  = isZero(pendingWR.wr.len);

        let maybeImmDt     = pendingWR.wr.immDt;
        let maybeRKey2Inv  = pendingWR.wr.rkey2Inv;
        let maybeRecvReqID = tagged Invalid;
        if (workReqNeedRecvReq(pendingWR.wr.opcode)) begin
            let endPSN = unwrapMaybe(pendingWR.endPSN);
            if (!isZeroLen) begin
                let payloadConResp = PayloadConResp {
                    dmaWriteResp: DmaWriteResp {
                        initiator: dontCareValue,
                        sqpn     : cntrlStatus.comm.getSQPN,
                        psn      : endPSN,
                        isRespErr: False
                    }
                };
                if (isNormalCase) begin
                    payloadConRespQ.enq(payloadConResp);
                end
            end

            let reqOpCode = case (pendingWR.wr.opcode)
                IBV_WR_SEND_WITH_IMM      : SEND_LAST_WITH_IMMEDIATE;
                IBV_WR_SEND_WITH_INV      : SEND_LAST_WITH_INVALIDATE;
                IBV_WR_RDMA_WRITE         : RDMA_WRITE_LAST;
                IBV_WR_RDMA_WRITE_WITH_IMM: RDMA_WRITE_LAST_WITH_IMMEDIATE;
                // IBV_WR_SEND
                default                   : SEND_LAST;
            endcase;
            let recvReqID = recvReqIdPipeOut.first;
            recvReqIdPipeOut.deq;

            maybeRecvReqID = tagged Valid recvReqID;
            let wcOpCode = isSendWorkReq(pendingWR.wr.opcode) ? IBV_WC_RECV : IBV_WC_RECV_RDMA_WITH_IMM;
            let wcFlags = hasImmDt ? IBV_WC_WITH_IMM : (hasIETH ? IBV_WC_WITH_INV : IBV_WC_NO_FLAGS);

            if (!isNormalCase) begin
                reqOpCode = SEND_ONLY;
                wcOpCode  = IBV_WC_RECV;
                wcFlags   = IBV_WC_NO_FLAGS;
            end

            expectedWorkCompQ.enq(tuple5(recvReqID, wcOpCode, wcFlags, maybeImmDt, maybeRKey2Inv));

            let workCompReq = WorkCompGenReqRQ {
                rrID        : maybeRecvReqID,
                len         : pendingWR.wr.len,
                // sqpn        : cntrlStatus.comm.getSQPN,
                reqPSN      : endPSN,
                isZeroDmaLen: isZeroLen,
                wcStatus    : isNormalCase ? IBV_WC_SUCCESS : IBV_WC_WR_FLUSH_ERR,
                reqOpCode   : reqOpCode,
                immDt       : maybeImmDt,
                rkey2Inv    : maybeRKey2Inv
            };

            workCompGenReqQ4RQ.enq(workCompReq);

            // $display("time=%0t: workCompReq=", $time, fshow(workCompReq));
        end
    endrule

    rule compare;
        let {
            recvReqID, wcOpCode, wcFlags, maybeImmDt, maybeRKey2Inv
        } = expectedWorkCompQ.first;
        expectedWorkCompQ.deq;

        let workCompRQ = dut.workCompPipeOut.first;
        dut.workCompPipeOut.deq;

        immAssert(
            workCompRQ.id == recvReqID,
            "workCompRQ.id assertion @ mkTestWorkCompGenRQ",
            $format(
                "WC ID=", fshow(workCompRQ.id),
                " not match expected recvReqID=", fshow(recvReqID))
        );

        immAssert(
            workCompRQ.opcode == wcOpCode,
            "workCompRQ.opcode assertion @ mkTestWorkCompGenRQ",
            $format(
                "WC opcode=", fshow(workCompRQ.opcode),
                " not match expected WC opcode=", fshow(wcOpCode))
        );

        immAssert(
            workCompRQ.flags == wcFlags,
            "workCompRQ.flags assertion @ mkTestWorkCompGenRQ",
            $format(
                "WC flags=", fshow(workCompRQ.flags),
                " not match expected WC flags=", fshow(wcFlags))
        );

        immAssert(
            workCompRQ.immDt == maybeImmDt,
            "workCompRQ.immDt assertion @ mkTestWorkCompGenRQ",
            $format(
                "WC immDt=", fshow(workCompRQ.immDt),
                " not match expected WC immDt=", fshow(maybeImmDt))
        );

        immAssert(
            workCompRQ.rkey2Inv == maybeRKey2Inv,
            "workCompRQ.rkey2Inv assertion @ mkTestWorkCompGenRQ",
            $format(
                "WC rkey2Inv=", fshow(workCompRQ.rkey2Inv),
                " not match expected WC rkey2Inv=", fshow(maybeRKey2Inv))
        );

        let expectedWorkCompStatus = isNormalCase ? IBV_WC_SUCCESS : IBV_WC_WR_FLUSH_ERR;
        immAssert(
            workCompRQ.status == expectedWorkCompStatus,
            "workCompRQ.status assertion @ mkTestWorkCompGenRQ",
            $format(
                "WC status=", fshow(workCompRQ.status),
                " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        // $display("time=%0t: WC=", $time, fshow(workCompRQ));
        hasWorkCompGenReg <= True;
        countDown.decr;
    endrule
endmodule
