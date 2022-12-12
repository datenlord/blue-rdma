import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import InputPktHandle :: *;
import PayloadConAndGen :: *;
import ScanFIFOF :: *;
import Settings :: *;
import SimDma :: *;
import Utils4Test :: *;
import Utils :: *;
import WorkCompHandler :: *;

// TODO: test error case
(* synthesize *)
module mkTestWorkCompHandlerNormalCase(Empty);
    function Bool workReqNeedDmaWriteResp(PendingWorkReq pwr);
        return !isZero(pwr.wr.len) && isReadOrAtomicWorkReq(pwr.wr.opcode);
    endfunction

    function Bool pendingWorkReqNeedWorkComp(PendingWorkReq pwr);
        return workReqNeedWorkComp(pwr.wr);
    endfunction

    let minDmaLength = 1;
    let maxDmaLength = 8192;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_512;

    let cntrl <- mkSimController(qpType, pmtu);
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;

    function ActionValue#(PayloadConResp) genPayloadConRespPipeOut(
        PendingWorkReq pendingWR
    );
        actionvalue
            let payloadConResp = PayloadConResp {
                initiator: ?,
                dmaWriteResp: DmaWriteResp {
                    sqpn: cntrl.getSQPN,
                    psn : fromMaybe(?, pendingWR.endPSN)
                }
            };
            return payloadConResp;
        endactionvalue
    endfunction

    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    Vector#(2, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOutVec[0]);
    let pendingWorkReqPipeOut4Dut = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4DmaResp = existingPendingWorkReqPipeOutVec[1];
    // let pendingWorkReqPipeOut4Ref <- mkBufferN(2, existingPendingWorkReqPipeOutVec[2]);

    // PayloadConResp generation
    let workReqNeedDmaWriteRespPipeOut <- mkPipeFilter(
        workReqNeedDmaWriteResp, pendingWorkReqPipeOut4DmaResp
    );
    let payloadConRespPipeOut <- mkActionValueFunc2Pipe(
        genPayloadConRespPipeOut, workReqNeedDmaWriteRespPipeOut
    );

    // DUT
    let workCompHandler <- mkWorkCompHandler(
        cntrl,
        payloadConRespPipeOut,
        pendingWorkReqBuf
    );

    function ActionValue#(PendingWorkReq) genWorkComp(
        PendingWorkReq pendingWR
    );
        actionvalue
            let wcWaitDmaResp = True;
            let wcStatus = IBV_WC_SUCCESS;
            workCompHandler.submitFromRespHandleInSQ(
                pendingWR,
                wcWaitDmaResp,
                wcStatus
            );
            return pendingWR;
        endactionvalue
    endfunction

    // Submit WC to DUT
    let pendingWorkReqPipeOutFromDut <- mkActionValueFunc2Pipe(
        genWorkComp, pendingWorkReqPipeOut4Dut
    );
    // Filter WR do not require WC
    let pendingWorkReqPipeOut4Ref <- mkPipeFilter(
        pendingWorkReqNeedWorkComp, pendingWorkReqPipeOutFromDut
    );

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule compare;
        let pendingWR = pendingWorkReqPipeOut4Ref.first;
        pendingWorkReqPipeOut4Ref.deq;

        let workComp = workCompHandler.workCompPipeOutSQ.first;
        workCompHandler.workCompPipeOutSQ.deq;

        dynAssert(
            workCompMatchWorkReqInSQ(workComp, pendingWR.wr),
            "workCompMatchWorkReqInSQ assertion @ mkTestWorkCompHandler",
            $format("WC=", fshow(workComp), " not match WR=", fshow(pendingWR.wr))
        );

        countDown.dec;
        // $display(
        //     "time=%0d: WC=", $time, fshow(workComp), " not match WR=", fshow(pendingWR.wr)
        // );
    endrule
endmodule
