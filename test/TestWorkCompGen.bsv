import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import InputPktHandle :: *;
// import PayloadConAndGen :: *;
import ScanFIFOF :: *;
import Settings :: *;
import SimDma :: *;
import Utils4Test :: *;
import Utils :: *;
import WorkCompGen :: *;

// (* synthesize *)
// module mkTestWorkCompGenNormalCaseSQ(Empty);
//     function Bool workReqNeedDmaWriteResp(PendingWorkReq pwr);
//         return !isZero(pwr.wr.len) && isReadOrAtomicWorkReq(pwr.wr.opcode);
//     endfunction

//     let minDmaLength = 1;
//     let maxDmaLength = 8192;
//     let qpType = IBV_QPT_XRC_SEND;
//     let pmtu = IBV_MTU_512;

//     let cntrl <- mkSimController(qpType, pmtu);
//     PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;

//     function ActionValue#(PayloadConResp) genPayloadConRespPipeOut(
//         PendingWorkReq pendingWR
//     );
//         actionvalue
//             let endPSN = unwrapMaybe(pendingWR.endPSN);
//             let payloadConResp = PayloadConResp {
//                 initiator: dontCareValue,
//                 dmaWriteResp: DmaWriteResp {
//                     sqpn: cntrl.getSQPN,
//                     psn : endPSN
//                 }
//             };

//             // $display(
//             //     "time=%0d: generate payloadConResp for SQPN=%h and PSN=%h",
//             //     $time, cntrl.getSQPN, endPSN
//             // );
//             return payloadConResp;
//         endactionvalue
//     endfunction

//     // WorkReq generation
//     Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
//         mkRandomWorkReq(minDmaLength, maxDmaLength);
//     Vector#(2, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
//         mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOutVec[0]);
//     let pendingWorkReqPipeOut4Dut = existingPendingWorkReqPipeOutVec[0];
//     let pendingWorkReqPipeOut4DmaResp = existingPendingWorkReqPipeOutVec[1];
//     // let pendingWorkReqPipeOut4Ref <- mkBufferN(2, existingPendingWorkReqPipeOutVec[2]);
//     FIFOF#(PendingWorkReq) pendingWorkReqPipeOut4Ref <- mkFIFOF;

//     // PayloadConResp generation
//     let workReqNeedDmaWriteRespPipeOut <- mkPipeFilter(
//         workReqNeedDmaWriteResp, pendingWorkReqPipeOut4DmaResp
//     );
//     let payloadConRespPipeOut <- mkActionValueFunc2Pipe(
//         genPayloadConRespPipeOut, workReqNeedDmaWriteRespPipeOut
//     );

//     // WC requests
//     FIFOF#(WorkCompGenReqSQ) wcGenReqQ4ReqGenInSQ <- mkFIFOF;
//     FIFOF#(WorkCompGenReqSQ) wcGenReqQ4RespHandleInSQ <- mkFIFOF;

//     // DUT
//     let workCompPipeOut <- mkWorkCompGenSQ(
//         cntrl,
//         payloadConRespPipeOut,
//         pendingWorkReqBuf,
//         convertFifo2PipeOut(wcGenReqQ4ReqGenInSQ),
//         convertFifo2PipeOut(wcGenReqQ4RespHandleInSQ)
//     );
// /*
//     function ActionValue#(PendingWorkReq) submitWorkReq2WorkCompGen(
//         PendingWorkReq pendingWR
//     );
//         actionvalue
//             let wcWaitDmaResp = True;
//             let wcStatus = IBV_WC_SUCCESS;
//             workCompGen.submitFromRespHandleInSQ(
//                 pendingWR,
//                 wcWaitDmaResp,
//                 wcStatus
//             );
//             $display(
//                 "time=%0d: submit to workCompGen pendingWR=", fshow(pendingWR)
//             );
//             return pendingWR;
//         endactionvalue
//     endfunction

//     // Submit WC to DUT
//     let pendingWorkReqPipeOutFromDut <- mkActionValueFunc2Pipe(
//         submitWorkReq2WorkCompGen, pendingWorkReqPipeOut4Dut
//     );
//     // Filter WR do not require WC
//     let pendingWorkReqPipeOut4Ref <- mkPipeFilter(
//         pendingWorkReqNeedWorkComp, pendingWorkReqPipeOutFromDut
//     );
// */
//     let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

//     // (* no_implicit_conditions, fire_when_enabled *)
//     (* fire_when_enabled *)
//     rule filterWR if (cntrl.isRTS);
//         let pendingWR = pendingWorkReqPipeOut4Dut.first;
//         pendingWorkReqPipeOut4Dut.deq;

//         let wcWaitDmaResp = True;
//         let wcReqType = WC_REQ_TYPE_SUC_FULL_ACK;
//         let respPSN = unwrapMaybe(pendingWR.endPSN);
//         let wcStatus = IBV_WC_SUCCESS;

//         let wcGenReq = WorkCompGenReqSQ {
//             pendingWR: pendingWR,
//             wcWaitDmaResp: wcWaitDmaResp,
//             wcReqType: wcReqType,
//             respPSN: respPSN,
//             wcStatus: wcStatus
//         };

//         // $display(
//         //     "time=%0d: submit to workCompGen pendingWR=", fshow(pendingWR)
//         // );

//         if (pendingWorkReqNeedWorkComp(pendingWR)) begin
//             wcGenReqQ4RespHandleInSQ.enq(wcGenReq);
//             pendingWorkReqPipeOut4Ref.enq(pendingWR);
//         end
//     endrule

//     rule compare;
//         let pendingWR = pendingWorkReqPipeOut4Ref.first;
//         pendingWorkReqPipeOut4Ref.deq;

//         let workComp = workCompPipeOut.first;
//         workCompPipeOut.deq;

//         dynAssert(
//             workCompMatchWorkReqInSQ(workComp, pendingWR.wr),
//             "workCompMatchWorkReqInSQ assertion @ mkTestWorkCompGen",
//             $format("WC=", fshow(workComp), " not match WR=", fshow(pendingWR.wr))
//         );

//         countDown.dec;
//         // $display(
//         //     "time=%0d: WC=", $time, fshow(workComp), " not match WR=", fshow(pendingWR.wr)
//         // );
//     endrule
// endmodule

module mkPendingWorkReqPipeOut#(
    PipeOut#(WorkReq) workReqPipeIn, PMTU pmtu
)(Vector#(vSz, PipeOut#(PendingWorkReq)));
    Reg#(PSN) nextPSN <- mkReg(0);

    function ActionValue#(PendingWorkReq) genExistingPendingWorkReq(WorkReq wr);
        actionvalue
            let startPktSeqNum = nextPSN;
            let { isOnlyPkt, totalPktNum, nextPktSeqNum, endPktSeqNum } =
                calcPktNumNextAndEndPSN(
                    startPktSeqNum,
                    wr.len,
                    pmtu
                );

            nextPSN <= nextPktSeqNum;
            let isOnlyReqPkt = isOnlyPkt || isReadWorkReq(wr.opcode);
            let pendingWR = PendingWorkReq {
                wr: wr,
                startPSN: tagged Valid startPktSeqNum,
                endPSN: tagged Valid endPktSeqNum,
                pktNum: tagged Valid totalPktNum,
                isOnlyReqPkt: tagged Valid isOnlyReqPkt
            };

            // $display(
            //     "time=%0d: generates pendingWR=", $time, fshow(pendingWR)
            // );
            return pendingWR;
        endactionvalue
    endfunction

    PipeOut#(PendingWorkReq) pendingWorkReqPipeOut <- mkActionValueFunc2Pipe(
        genExistingPendingWorkReq, workReqPipeIn
    );

    Vector#(vSz, PipeOut#(PendingWorkReq)) resultPipeOutVec <-
        mkForkVector(pendingWorkReqPipeOut);
    return resultPipeOutVec;
endmodule

(* synthesize *)
module mkTestWorkCompGenNormalCaseSQ(Empty);
    let isNormalCase = True;
    let result <- mkTestWorkCompGenSQ(isNormalCase);
endmodule

(* synthesize *)
module mkTestWorkCompGenErrorCaseSQ(Empty);
    let isNormalCase = False;
    let result <- mkTestWorkCompGenSQ(isNormalCase);
endmodule

module mkTestWorkCompGenSQ#(Bool isNormalCase)(Empty);
    function Bool workReqNeedDmaWriteResp(PendingWorkReq pwr);
        return !isZero(pwr.wr.len) && isReadOrAtomicWorkReq(pwr.wr.opcode);
    endfunction

    let minDmaLength = 1;
    let maxDmaLength = 8192;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_512;

    let cntrl <- mkSimController(qpType, pmtu);
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;
/*
    function ActionValue#(PayloadConResp) genPayloadConRespPipeOut(
        PendingWorkReq pendingWR
    );
        actionvalue
            let endPSN = unwrapMaybe(pendingWR.endPSN);
            let payloadConResp = PayloadConResp {
                initiator: dontCareValue,
                dmaWriteResp: DmaWriteResp {
                    sqpn: cntrl.getSQPN,
                    psn : endPSN
                }
            };

            // $display(
            //     "time=%0d: generate payloadConResp for SQPN=%h and PSN=%h",
            //     $time, cntrl.getSQPN, endPSN
            // );
            return payloadConResp;
        endactionvalue
    endfunction
*/
    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    Vector#(2, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkPendingWorkReqPipeOut(workReqPipeOutVec[0], pmtu);
    let pendingWorkReqPipeOut4Dut = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4DmaResp = existingPendingWorkReqPipeOutVec[1];
    // let pendingWorkReqPipeOut4Ref <- mkBufferN(2, existingPendingWorkReqPipeOutVec[2]);
    FIFOF#(PendingWorkReq) pendingWorkReqPipeOut4Ref <- mkFIFOF;

    // PayloadConResp
    FIFOF#(PayloadConResp) payloadConRespQ <- mkFIFOF;
    // let workReqNeedDmaWriteRespPipeOut <- mkPipeFilter(
    //     workReqNeedDmaWriteResp, pendingWorkReqPipeOut4DmaResp
    // );
    // let payloadConRespPipeOut <- mkActionValueFunc2Pipe(
    //     genPayloadConRespPipeOut, workReqNeedDmaWriteRespPipeOut
    // );

    // WC requests
    FIFOF#(WorkCompGenReqSQ) wcGenReqQ4ReqGenInSQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqSQ) wcGenReqQ4RespHandleInSQ <- mkFIFOF;

    // DUT
    let workCompPipeOut <- mkWorkCompGenSQ(
        cntrl,
        // payloadConRespPipeOut,
        convertFifo2PipeOut(payloadConRespQ),
        pendingWorkReqBuf,
        convertFifo2PipeOut(wcGenReqQ4ReqGenInSQ),
        convertFifo2PipeOut(wcGenReqQ4RespHandleInSQ)
    );

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule genPayloadConResp;
        let pendingWR = pendingWorkReqPipeOut4DmaResp.first;
        pendingWorkReqPipeOut4DmaResp.deq;

        if (workReqNeedDmaWriteResp(pendingWR)) begin
            let endPSN = unwrapMaybe(pendingWR.endPSN);
            let payloadConResp = PayloadConResp {
                initiator: dontCareValue,
                dmaWriteResp: DmaWriteResp {
                    sqpn: cntrl.getSQPN,
                    psn : endPSN
                }
            };
            if (isNormalCase) begin
                payloadConRespQ.enq(payloadConResp);
            end
        end
    endrule

    rule fillPendingWorkReqBuf;
        let pendingWR = pendingWorkReqPipeOut4Dut.first;
        pendingWorkReqPipeOut4Dut.deq;

        // $display(
        //     "time=%0d: fill pendingWR=", $time, fshow(pendingWR)
        // );
        pendingWorkReqBuf.fifoF.enq(pendingWR);
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    // (* fire_when_enabled *)
    rule filterWR;
        let pendingWR = pendingWorkReqBuf.fifoF.first;
        pendingWorkReqBuf.fifoF.deq;

        let wcWaitDmaResp = True;
        let wcReqType = isNormalCase ? WC_REQ_TYPE_SUC_FULL_ACK : WC_REQ_TYPE_ERR_FULL_ACK;
        let respPSN = unwrapMaybe(pendingWR.endPSN);
        let wcStatus = isNormalCase ? IBV_WC_SUCCESS : IBV_WC_WR_FLUSH_ERR;

        let wcGenReq = WorkCompGenReqSQ {
            pendingWR: pendingWR,
            wcWaitDmaResp: wcWaitDmaResp,
            wcReqType: wcReqType,
            respPSN: respPSN,
            wcStatus: wcStatus
        };

        if (cntrl.isRTS && pendingWorkReqNeedWorkComp(pendingWR)) begin
            wcGenReqQ4RespHandleInSQ.enq(wcGenReq);
            pendingWorkReqPipeOut4Ref.enq(pendingWR);

            // $display(
            //     "time=%0d: submit to workCompGen pendingWR=",
            //     $time, fshow(pendingWR)
            // );
        end
        else if (cntrl.isERR) begin
            pendingWorkReqPipeOut4Ref.enq(pendingWR);
            // $display(
            //     "time=%0d: for reference pendingWR=",
            //     $time, fshow(pendingWR)
            // );
        end
    endrule

    rule compare;
        let pendingWR = pendingWorkReqPipeOut4Ref.first;
        pendingWorkReqPipeOut4Ref.deq;

        let workComp = workCompPipeOut.first;
        workCompPipeOut.deq;

        dynAssert(
            workCompMatchWorkReqInSQ(workComp, pendingWR.wr),
            "workCompMatchWorkReqInSQ assertion @ mkTestWorkCompGen",
            $format("WC=", fshow(workComp), " not match WR=", fshow(pendingWR.wr))
        );

        let expectedWorkCompStatus = isNormalCase ? IBV_WC_SUCCESS : IBV_WC_WR_FLUSH_ERR;
        dynAssert(
            workComp.status == expectedWorkCompStatus,
            "workCompMatchWorkReqInSQ assertion @ mkTestWorkCompGen",
            $format(
                "WC=", fshow(workComp), " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        countDown.dec;
        // $display(
        //     "time=%0d: WC=", $time, fshow(workComp), " not match WR=", fshow(pendingWR.wr)
        // );
    endrule
endmodule
