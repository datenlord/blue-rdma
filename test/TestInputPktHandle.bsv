import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import DataTypes :: *;
import Headers :: *;
import InputPktHandle :: *;
import MetaData :: *;
import PrimUtils :: *;
import QueuePair :: *;
import Settings :: *;
import SimGenRdmaReqResp :: *;
import SimExtractRdmaHeaderPayload :: *;
import Utils :: *;
import Utils4Test :: *;

(* doc = "testcase" *)
module mkTestReceiveCNP(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    let qpIndex = getDefaultIndexQP;
    let qp = qpMetaData.getQueuePairByIndexQP(qpIndex);

    let cnpDataStream = buildCNP(qp.statusSQ);
    let cnpDataStreamPipeIn <- mkConstantPipeOut(cnpDataStream);
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        cnpDataStreamPipeIn
    );
    let dut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );

    for (Integer idx = 1; idx < valueOf(MAX_QP); idx = idx + 1) begin
        let reqPktMetaDataPipeOutEmptyRule <- addRules(genEmptyPipeOutRule(
            dut[idx].reqPktPipeOut.pktMetaData,
            "dut[" + integerToString(idx) +
            "].reqPktPipeOut.pktMetaData empty assertion @ mkTestReceiveCNP"
        ));
        let reqPktPayloadPipeOutEmptyRule <- addRules(genEmptyPipeOutRule(
            dut[idx].reqPktPipeOut.payload,
            "dut[" + integerToString(idx) +
            "].reqPktPipeOut.payload empty assertion @ mkTestReceiveCNP"
        ));

        let respPktMetaDataPipeOutEmptyRule <- addRules(genEmptyPipeOutRule(
            dut[idx].respPktPipeOut.pktMetaData,
            "dut[" + integerToString(idx) +
            "].respPktPipeOut.pktMetaData empty assertion @ mkTestReceiveCNP"
        ));
        let respPktPayloadPipeOutEmptyRule <- addRules(genEmptyPipeOutRule(
            dut[idx].respPktPipeOut.payload,
            "dut[" + integerToString(idx) +
            "].respPktPipeOut.payload empty assertion @ mkTestReceiveCNP"
        ));

        let cnpPipeOutEmptyRule <- addRules(genEmptyPipeOutRule(
            dut[idx].cnpPipeOut,
            "dut[" + integerToString(idx) +
            "].cnpPipeOut empty assertion @ mkTestReceiveCNP"
        ));
    end

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule checkCNP;
        let cnpBth = dut[qpIndex].cnpPipeOut.first;
        dut[qpIndex].cnpPipeOut.deq;
        immAssert(
            { pack(cnpBth.trans), pack(cnpBth.opcode) } == fromInteger(valueOf(ROCE_CNP)),
            "CNP assertion @ mkTestReceiveCNP",
            $format(
                "cnpBth.trans=", fshow(cnpBth.trans),
                " cnpBth.opcode=", fshow(cnpBth.opcode),
                " not match ROCE_CNP=%h", valueOf(ROCE_CNP)
            )
        );

        let reqPktMetaDataAndPayloadPipeOut = dut[qpIndex].reqPktPipeOut;
        let respPktMetaDataAndPayloadPipeOut = dut[qpIndex].respPktPipeOut;
        immAssert(
            !reqPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty &&
            !reqPktMetaDataAndPayloadPipeOut.payload.notEmpty,
            "reqPktMetaDataAndPayloadPipeOut assertion @ mkTestReceiveCNP",
            $format(
                "reqPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty=",
                fshow(reqPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty),
                " and reqPktMetaDataAndPayloadPipeOut.payload.notEmpty=",
                fshow(reqPktMetaDataAndPayloadPipeOut.payload.notEmpty),
                " should both be false"
            )
        );

        immAssert(
            !respPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty &&
            !respPktMetaDataAndPayloadPipeOut.payload.notEmpty,
            "respPktMetaDataAndPayloadPipeOut assertion @ mkTestReceiveCNP",
            $format(
                "respPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty=",
                fshow(respPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty),
                " and respPktMetaDataAndPayloadPipeOut.payload.notEmpty=",
                fshow(respPktMetaDataAndPayloadPipeOut.payload.notEmpty),
                " should both be false"
            )
        );
        // $display(
        //     "time=%0t:", $time,
        //     " cnpBth.trans=", fshow(cnpBth.trans),
        //     " cnpBth.opcode=", fshow(cnpBth.opcode),
        //     " not match ROCE_CNP=%h", valueOf(ROCE_CNP)
        // );
        countDown.decr;
    endrule
endmodule

(* doc = "testcase" *)
module mkTestCalculateRandomPktLen(Empty);
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_4096;
    Length minPayloadLen = 8192;
    Length maxPayloadLen = 10241;

    let ret <- mkTestCalculatePktLen(
        qpType, pmtu, minPayloadLen, maxPayloadLen
    );
endmodule

(* doc = "testcase" *)
module mkTestCalculatePktLenEqPMTU(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;
    Length minPayloadLen = zeroExtend(calcPmtuLen(pmtu));
    Length maxPayloadLen = zeroExtend(calcPmtuLen(pmtu));

    let ret <- mkTestCalculatePktLen(
        qpType, pmtu, minPayloadLen, maxPayloadLen
    );
endmodule

(* doc = "testcase" *)
module mkTestCalculateZeroPktLen(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;
    Length minPayloadLen = 0;
    Length maxPayloadLen = 0;

    let ret <- mkTestCalculatePktLen(
        qpType, pmtu, minPayloadLen, maxPayloadLen
    );
endmodule

module mkTestCalculatePktLen#(
    TypeQP qpType,
    PMTU   pmtu,
    Length minPayloadLen,
    Length maxPayloadLen
)(Empty);
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    let newPendingWorkReqPipeOut =
        genNewPendingWorkReqPipeOut(workReqPipeOutVec[0]);

    // Generate RDMA requests
    let reqGenSQ <- mkSimGenRdmaReq(
        newPendingWorkReqPipeOut, qpType, pmtu
    );
    let pendingWorkReqPipeOut4Ref <- mkBufferN(2, reqGenSQ.pendingWorkReqPipeOut);
    let rdmaReqPipeOut = reqGenSQ.rdmaReqDataStreamPipeOut;

    // QP metadata
    let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);

    // DUT
    let isRespPktPipeIn = False;
    let dut <- mkSimInputPktBuf4SingleQP(isRespPktPipeIn, rdmaReqPipeOut, qpMetaData);
    // let dut <- mkSimExtractNormalHeaderPayload(rdmaReqPipeOut);
    let pktMetaDataPipeOut = dut.pktMetaData;

    // // Payload sink
    mkSink(dut.payload);
    Reg#(Length) pktLenSumReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(pendingWorkReqPipeOut4Ref);
    // mkSink(pktMetaDataPipeOut);

    rule compareWorkReqLen;
        let pendingWR   = pendingWorkReqPipeOut4Ref.first;
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
            // $display("time=%0t: PendingWorkReq=", $time, fshow(pendingWR));

            if (isReadWorkReq(pendingWR.wr.opcode) || isAtomicWorkReq(pendingWR.wr.opcode)) begin
                immAssert(
                    isZero(pktLenSum),
                    "pktLenSum assertion @ mkTestCalculatePktLen",
                    $format("pktLenSum=%0d should be zero", pktLenSum)
                );
            end
            else begin
                // Length pktPadCnt = zeroExtend(bth.padCnt);
                immAssert(
                    pktLenSum == pendingWR.wr.len,
                    // pktLenSum == (pendingWR.wr.len + pktPadCnt),
                    "pktLenSum assertion @ mkTestCalculatePktLen",
                    $format(
                        "pktLenSum=%0d should == pendingWR.wr.len=%0d",
                        pktLenSum, pendingWR.wr.len
                        // "pktLenSum=%0d should == pendingWR.wr.len=%0d + pktPadCnt=%0d",
                        // pktLenSum, pendingWR.wr.len, pktPadCnt
                    )
                );
            end
        end

        immAssert(
            rdmaReqOpCodeMatchWorkReqOpCode(bth.opcode, pendingWR.wr.opcode),
            "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestCalculatePktLen",
            $format(
                "rdmaOpCode=", fshow(bth.opcode),
                " should match workReqOpCode=", fshow(pendingWR.wr.opcode)
            )
        );

        countDown.decr;
        // $display(
        //     "time=%0t:", $time,
        //     " received bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h, bth.padCnt=%h, pktLenSum=%0d",
        //     bth.psn, bth.padCnt, pktLenSum
        // );
    endrule
endmodule
