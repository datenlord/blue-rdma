import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import DataTypes :: *;
import InputPktHandle :: *;
import Headers :: *;
import Settings :: *;
import SimDma :: *;
import Utils4Test :: *;
import Utils :: *;

import ReqGenSQ :: *; // TOOD: remove this
// TODO: move this module to Utils4Test
module mkGenRdmaReqGivenWorkReq#(
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn,
    QpType qpType,
    PMTU pmtu
)(PendingWorkReqAndDataStreamPipeOut);
    let cntlr <- mkSimController(qpType, pmtu);
    let simDmaReadSrv <- mkSimDmaReadSrv;

    let resultPipeOut <- mkWorkReq2RdmaReq(
        cntlr, simDmaReadSrv, pendingWorkReqPipeIn
    );
    return resultPipeOut;
endmodule

module mkTestCalculatePktLen#(
    QpType qpType,
    PMTU pmtu,
    Length minPayloadLen,
    Length maxPayloadLen
)(Empty);
    WorkReqOpCode workReqOpCodeArray[8] = {
        IBV_WR_RDMA_WRITE,
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_SEND,
        IBV_WR_SEND_WITH_IMM,
        IBV_WR_RDMA_READ,
        IBV_WR_ATOMIC_CMP_AND_SWP,
        IBV_WR_ATOMIC_FETCH_AND_ADD,
        IBV_WR_SEND_WITH_INV
    };
    // Prepare PendingWorkReq input
    Vector#(8, WorkReqOpCode) workReqOpCodeVec =
        arrayToVector(workReqOpCodeArray);
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomWorkReqInRange(
        workReqOpCodeVec, minPayloadLen, maxPayloadLen
    );
    let newPendingWorkReqPipeOut <-
        mkNewPendingWorkReqPipeOut(workReqPipeOutVec[0]);

    // Generate RDMA requests
    let workReq2RdmaReq <- mkGenRdmaReqGivenWorkReq(
        newPendingWorkReqPipeOut, qpType, pmtu
    );
    let pendingWorkReqPipeOut4Ref <- mkBufferN(4, workReq2RdmaReq.pendingWorkReq);
    let rdmaReqPipeOut = workReq2RdmaReq.rdmaReq;

    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaReqPipeOut
    );

    // DUT
    let dut <- mkInputRdmaPktBufAndCalcPktLen(
        headerAndMetaDataAndPayloadPipeOut, pmtu
    );
    let pktMetaDataPipeOut = dut.pktMetaData;

    // Payload sink
    let payloadSink <- mkSink(dut.payload);
    Reg#(Length) pktLenSumReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule compareWorkReqLen;
        let pendingWR = pendingWorkReqPipeOut4Ref.first;
        let pktMetaData = pktMetaDataPipeOut.first;
        pktMetaDataPipeOut.deq;

        let bth = extractBTH(pktMetaData.pktHeader.headerData);
        let pktLenSum = pktLenSumReg;
        if (isFirstOrOnlyRdmaOpCode(bth.opcode)) begin
            pktLenSum = zeroExtend(pktMetaData.pktPayloadLen);
        end
        else begin
            pktLenSum = pktLenSumReg + zeroExtend(pktMetaData.pktPayloadLen);
        end
        pktLenSumReg <= pktLenSum;

        if (isLastOrOnlyRdmaOpCode(bth.opcode)) begin
            pendingWorkReqPipeOut4Ref.deq;
            // $display("time=%0d: PendingWorkReq=", $time, fshow(pendingWR));

            if (isReadWorkReq(pendingWR.wr.opcode) || isAtomicWorkReq(pendingWR.wr.opcode)) begin
                dynAssert(
                    isZero(pktLenSum),
                    "pktLenSum assertion @ mkTestCalculatePktLen",
                    $format("pktLenSum=%0d should be zero", pktLenSum)
                );
            end
            else begin
                Length pktPadCnt = zeroExtend(bth.padCnt);
                dynAssert(
                    pktLenSum == (pendingWR.wr.len + pktPadCnt),
                    "pktLenSum assertion @ mkTestCalculatePktLen",
                    $format(
                        "pktLenSum=%0d should == pendingWR.wr.len=%0d + pktPadCnt=%0d",
                        pktLenSum, pendingWR.wr.len, pktPadCnt
                    )
                );
            end
        end

        dynAssert(
            rdmaReqOpCodeMatchWorkReqOpCode(bth.opcode, pendingWR.wr.opcode),
            "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestCalculatePktLen",
            $format(
                "rdmaOpCode=", fshow(bth.opcode),
                " should match workReqOpCode=", fshow(pendingWR.wr.opcode)
            )
        );

        // Decrement the count down counter when zero payload length,
        // since ReqGenSQ will not send zero payload length request to DMA.
        if (maxPayloadLen == 0) begin
            countDown.dec;
        end
        // $display("time=%0d: pending WR=", $time, fshow(pendingWR));
    endrule
endmodule

(* synthesize *)
module mkTestCalculateRandomPktLen(Empty);
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;
    Length minPayloadLen = 128;
    Length maxPayloadLen = 1024;

    let ret <- mkTestCalculatePktLen(
        qpType, pmtu, minPayloadLen, maxPayloadLen
    );
endmodule

(* synthesize *)
module mkTestCalculatePktLenEqPMTU(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_512;
    Length minPayloadLen = fromInteger(getPmtuLogValue(pmtu));
    Length maxPayloadLen = fromInteger(getPmtuLogValue(pmtu));

    let ret <- mkTestCalculatePktLen(
        qpType, pmtu, minPayloadLen, maxPayloadLen
    );
endmodule

(* synthesize *)
module mkTestCalculateZeroPktLen(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;
    Length minPayloadLen = 0;
    Length maxPayloadLen = 0;

    let ret <- mkTestCalculatePktLen(
        qpType, pmtu, minPayloadLen, maxPayloadLen
    );
endmodule
