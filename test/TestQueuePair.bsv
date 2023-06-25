import BuildVector :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
// import InputPktHandle :: *;
// import MetaData :: *;
import PrimUtils :: *;
import QueuePair :: *;
import Settings :: *;
import SimDma :: *;
import SimExtractRdmaHeaderPayload :: *;
import Utils :: *;
import Utils4Test :: *;

/*
module mkTestSimExtractNormalHeaderPayload(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    let newPendingWorkReqPipeOut =
        genNewPendingWorkReqPipeOut(workReqPipeOutVec[0]);

    // Generate RDMA requests
    let reqGenSQ <- mkSimGenRdmaReq(
        newPendingWorkReqPipeOut, qpType, pmtu
    );
    let discardPendingWR <- mkSink(reqGenSQ.pendingWorkReqPipeOut);
    Vector#(2, DataStreamPipeOut) rdmaReqPipeOutVec <-
        mkForkVector(reqGenSQ.rdmaReqDataStreamPipeOut);
    let rdmaReqPipeOut4InputPktBuf <- mkBufferN(8, rdmaReqPipeOutVec[0]);
    let rdmaReqPipeOut4DUT <- mkBufferN(8, rdmaReqPipeOutVec[1]);
    // let rdmaReqPipeOut4DUT = reqGenSQ.rdmaReqDataStreamPipeOut;

    // QP metadata
    let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);

    // InputPktBuf
    let isRespPktPipeIn = False;
    let inputPktBuf <- mkSimInputPktBuf4SingleQP(isRespPktPipeIn, rdmaReqPipeOut4InputPktBuf, qpMetaData);

    // DUT
    let dut <- mkSimExtractNormalHeaderPayload(rdmaReqPipeOut4DUT);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(rdmaReqPipeOut4InputPktBuf);
    // mkSink(rdmaReqPipeOut4DUT);
    // mkSink(inputPktBuf.pktMetaData);
    // mkSink(dut.pktMetaData);
    // mkSink(inputPktBuf.payload);
    // mkSink(dut.payload);

    rule comparePktMetaData;
        let pktMetaDataRef = inputPktBuf.pktMetaData.first;
        inputPktBuf.pktMetaData.deq;

        let pktMetaData = dut.pktMetaData.first;
        dut.pktMetaData.deq;

        immAssert(
            pktMetaData.pktPayloadLen == pktMetaDataRef.pktPayloadLen    &&
            pktMetaData.pktFragNum    == pktMetaDataRef.pktFragNum,
            "pktPayloadLen and pktFragNum assertion @ mkTestSimExtractNormalHeaderPayload",
            $format(
                "pktMetaData.pktPayloadLen=%0d should == pktMetaDataRef.pktPayloadLen=%0d",
                pktMetaData.pktPayloadLen, pktMetaDataRef.pktPayloadLen,
                ", pktMetaData.pktFragNum=%0d should == pktMetaDataRef.pktFragNum=%0d",
                pktMetaData.pktFragNum, pktMetaDataRef.pktFragNum
            )
        );

        immAssert(
            pktMetaData.isZeroPayloadLen == pktMetaDataRef.isZeroPayloadLen &&
            pktMetaData.pktValid         == pktMetaDataRef.pktValid         &&
            pktMetaData.pktStatus        == pktMetaDataRef.pktStatus,
            "pktMetaData assertion @ mkTestSimExtractNormalHeaderPayload",
            $format(
                "pktMetaData.isZeroPayloadLen=", fshow(pktMetaData.isZeroPayloadLen),
                " should == pktMetaDataRef.isZeroPayloadLen", fshow(pktMetaDataRef.isZeroPayloadLen),
                ", pktMetaData.pktValid=", fshow(pktMetaData.pktValid),
                " should == pktMetaDataRef.pktValid", fshow(pktMetaDataRef.pktValid),
                ", pktMetaData.pktStatus=", fshow(pktMetaData.pktStatus),
                " should == pktMetaDataRef.pktStatus", fshow(pktMetaDataRef.pktStatus)
            )
        );
        immAssert(
            pktMetaData.pktHeader.headerData     == pktMetaDataRef.pktHeader.headerData   &&
            pktMetaData.pktHeader.headerByteEn   == pktMetaDataRef.pktHeader.headerByteEn &&
            pktMetaData.pktHeader.headerMetaData == pktMetaDataRef.pktHeader.headerMetaData,
            "pktHeader assertion @ mkTestSimExtractNormalHeaderPayload",
            $format(
                "pktMetaData.pktHeader=", fshow(pktMetaData.pktHeader),
                " should == pktMetaDataRef.pktHeader", fshow(pktMetaDataRef.pktHeader)
            )
        );

        countDown.decr;
        // $display(
        //     "time=%0t: pktMetaData=", $time, fshow(pktMetaData),
        //     " should match pktMetaDataRef=", fshow(pktMetaDataRef)
        // );
    endrule

    rule comparePayload;
        let payloadFragRef = inputPktBuf.payload.first;
        inputPktBuf.payload.deq;

        let payloadFrag = dut.payload.first;
        dut.payload.deq;

        immAssert(
            payloadFrag == payloadFragRef,
            "payloadFrag assertion @ mkTestSimExtractNormalHeaderPayload",
            $format(
                "payloadFrag=", fshow(payloadFrag),
                " should == payloadFragRef=", fshow(payloadFragRef)
            )
        );
        // $display(
        //     "time=%0t: payloadFrag=", $time, fshow(payloadFrag),
        //     " should match payloadFragRef=", fshow(payloadFragRef)
        // );
    endrule
endmodule

module mkSimExtractNormalHeaderPayload#(DataStreamPipeOut rdmaPktPipeIn)(
    RdmaPktMetaDataAndPayloadPipeOut
);
    FIFOF#(RdmaPktMetaData) pktMetaDataOutQ <- mkFIFOF;
    FIFOF#(DataStream)          payloadOutQ <- mkFIFOF;

    // Reg#(Bool)        isValidPktReg <- mkRegU;
    Reg#(RdmaHeader)  rdmaHeaderReg <- mkRegU;
    Reg#(PmtuFragNum) pktFragNumReg <- mkRegU;
    Reg#(PktLen)          pktLenReg <- mkRegU;
    Reg#(Bool)          pktValidReg <- mkRegU;

    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaPktPipeIn
    );
    let payloadPipeIn <- mkBuffer(headerAndMetaDataAndPayloadPipeOut.payload);
    let rdmaHeaderPipeOut <- mkDataStream2Header(
        headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream,
        headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData
    );

    rule extractHeader;
        let payloadFrag = payloadPipeIn.first;
        payloadPipeIn.deq;

        let rdmaHeader = rdmaHeaderReg;
        if (payloadFrag.isFirst) begin
            rdmaHeader = rdmaHeaderPipeOut.first;
            rdmaHeaderPipeOut.deq;
            rdmaHeaderReg <= rdmaHeader;
        end
        let bth  = extractBTH(rdmaHeader.headerData);
        let aeth = extractAETH(rdmaHeader.headerData);
        let bthPadCnt = bth.padCnt;

        let bthCheckResult = checkZeroFields4BTH(bth);
        let headerCheckResult =
            padCntCheckReqHeader(bth) || padCntCheckRespHeader(bth, aeth);
        immAssert(
            bthCheckResult && headerCheckResult,
            "bth valid assertion @ mkSimExtractNormalHeaderPayload",
            $format(
                "bth=", fshow(bth),
                " should be valid, but bthCheckResult=", fshow(bthCheckResult),
                " and headerCheckResult=", fshow(headerCheckResult)
            )
        );

        let isFirstOrMidPkt = isFirstOrMiddleRdmaOpCode(bth.opcode);
        let isLastPkt       = isLastRdmaOpCode(bth.opcode);

        let pktLen = pktLenReg;
        let pktFragNum = pktFragNumReg;
        let pktValid = False;

        let isByteEnAllOne = isAllOnesR(payloadFrag.byteEn);
        let payloadFragLen = calcFragByteNumFromByteEn(payloadFrag.byteEn);
        immAssert(
            isValid(payloadFragLen),
            "isValid(payloadFragLen) assertion @ mkSimExtractNormalHeaderPayload",
            $format(
                "payloadFragLen=", fshow(payloadFragLen), " should be valid"
            )
        );

        let fragLen = unwrapMaybe(payloadFragLen);
        let isByteEnNonZero = !isZero(fragLen);
        ByteEnBitNum fragLenWithOutPad = fragLen - zeroExtend(bthPadCnt);
        PktLen fragLenExtWithOutPad = zeroExtend(fragLenWithOutPad);
        case ({ pack(payloadFrag.isFirst), pack(payloadFrag.isLast) })
            2'b11: begin // payloadFrag.isFirst && payloadFrag.isLast
                pktLen = fragLenExtWithOutPad;
                pktFragNum = 1;
                pktValid = (isFirstOrMidPkt ? False : (isLastPkt ? isByteEnNonZero : True));
            end
            2'b10: begin // payloadFrag.isFirst && !payloadFrag.isLast
                pktLen = fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
                pktFragNum = 1;
                pktValid = isByteEnAllOne;
            end
            2'b01: begin // !payloadFrag.isFirst && payloadFrag.islast
                pktLen = pktLenAddFragLen(pktLenReg, fragLenWithOutPad);
                // pktLen = pktLenReg + fragLenExtWithOutPad;
                pktFragNum = pktFragNumReg + 1;
                pktValid = pktValidReg;
            end
            2'b00: begin // !payloadFrag.isFirst && !payloadFrag.islast
                pktLen = pktLenAddBusByteWidth(pktLenReg);
                // pktLen = pktLenReg + fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
                pktFragNum = pktFragNumReg + 1;
                pktValid = pktValidReg && isByteEnAllOne;
            end
        endcase

        pktLenReg     <= pktLen;
        pktValidReg   <= pktValid;
        pktFragNumReg <= pktFragNum;

        let pktStatus = PKT_ST_VALID;
        if (!pktValid) begin
            // Invalid packet length
            pktStatus = PKT_ST_LEN_ERR;
        end

        let isZeroPayloadLen = isZeroR(pktLen);
        if (payloadFrag.isLast) begin
            let pktMetaData = RdmaPktMetaData {
                pktPayloadLen   : pktLen,
                pktFragNum      : (isZeroPayloadLen ? 0 : pktFragNum),
                isZeroPayloadLen: isZeroPayloadLen,
                pktHeader       : rdmaHeader,
                pdHandler       : dontCareValue,
                pktValid        : pktValid,
                pktStatus       : pktStatus
            };
            pktMetaDataOutQ.enq(pktMetaData);
        end

        // if (rdmaHeader.headerMetaData.hasPayload) begin
        if (!isZeroPayloadLen) begin
            payloadOutQ.enq(payloadFrag);
        end
        else begin
            immAssert(
                !rdmaHeader.headerMetaData.hasPayload,
                "hasPayload assertion @ mkSimExtractNormalHeaderPayload",
                $format(
                    "hasPayload=", fshow(rdmaHeader.headerMetaData.hasPayload),
                    " should be false when isZeroPayloadLen=", fshow(isZeroPayloadLen)
                )
            );
        end

        if (bth.opcode == ACKNOWLEDGE) begin
            $display(
                "time=%0t: mkSimExtractNormalHeaderPayload recvPktFrag", $time,
                ", bth.opcode=", fshow(bth.opcode),
                ", bth.psn=%h", bth.psn,
                ", bthPadCnt=%0d", bthPadCnt,
                ", fragLen=%0d", fragLen,
                ", payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
                ", payloadFrag.isLast=", fshow(payloadFrag.isLast),
                ", fragLenWithOutPad=%0d", fragLenWithOutPad,
                ", pktFragNum=%0d", pktFragNum,
                ", pktLen=%0d", pktLen,
                ", rdmaHeader=", fshow(rdmaHeader)
            );
            immAssert(
                isZeroPayloadLen && payloadFrag.isLast && payloadFrag.isFirst,
                "isZeroPayloadLen assertion @ mkSimExtractNormalHeaderPayload",
                $format(
                    "isZeroPayloadLen=", fshow(isZeroPayloadLen),
                    ", payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
                    ", payloadFrag.isLast=", fshow(payloadFrag.isLast),
                    " should all be true when bth.opcode=", fshow(bth.opcode)
                )
            );
        end
    endrule

    interface pktMetaData = convertFifo2PipeOut(pktMetaDataOutQ);
    interface payload     = convertFifo2PipeOut(payloadOutQ);
endmodule
*/

(* synthesize *)
module mkTestQueuePairTimeOutErrCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    let sendSideQP <- mkQP;

    // Set QP to RTS
    let setExpectedPsnAsNextPSN = True;
    let setZero2ExpectedPsnAndNextPSN = True;
    let setSendQ2RTS <- mkChange2CntrlStateRTS(
        sendSideQP.srvPortQP, qpType, pmtu,
        setExpectedPsnAsNextPSN, setZero2ExpectedPsnAndNextPSN
    );

    // WorkReq
    Vector#(2, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minPayloadLen, maxPayloadLen);
    let workReqPipeOut = workReqPipeOutVec[0];
    let workReqPipeOut4Ref <- mkBufferN(valueOf(MAX_QP_WR), workReqPipeOutVec[1]);
    mkConnection(toGet(workReqPipeOut), sendSideQP.workReqIn);

    // RecvReq
    FIFOF#(RecvReq) emptyRecvReqQ <- mkFIFOF;
    mkConnection(toGet(emptyRecvReqQ), sendSideQP.recvReqIn);

    // DMA
    // let dmaReadClt  <- mkDmaReadCltAribter(vec(sendSideQP.dmaReadClt4RQ, sendSideQP.dmaReadClt4SQ));
    // let dmaWriteClt <- mkDmaWriteCltAribter(vec(sendSideQP.dmaWriteClt4RQ, sendSideQP.dmaWriteClt4SQ));
    // let simDmaReadSrv  <- mkSimDmaReadSrv;
    // let simDmaWriteSrv <- mkSimDmaWriteSrv;
    // mkConnection(dmaReadClt, simDmaReadSrv);
    // mkConnection(dmaWriteClt, simDmaWriteSrv);
    Vector#(2, DmaReadClt)  dmaReadCltVec  = vec(sendSideQP.dmaReadClt4SQ, sendSideQP.dmaReadClt4RQ);
    Vector#(2, DmaWriteClt) dmaWriteCltVec = vec(sendSideQP.dmaWriteClt4SQ, sendSideQP.dmaWriteClt4RQ);
    Vector#(2, DmaReadSrv)  simDmaReadSrvVec  <- replicateM(mkSimDmaReadSrv);
    Vector#(2, DmaWriteSrv) simDmaWriteSrvVec <- replicateM(mkSimDmaWriteSrv);
    for (Integer idx = 0; idx < 2; idx = idx + 1) begin
        mkConnection(dmaReadCltVec[idx], simDmaReadSrvVec[idx]);
        mkConnection(dmaWriteCltVec[idx], simDmaWriteSrvVec[idx]);
    end

    // MR permission check
    let mrCheckPassOrFail = True;
    let simPermCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);
    let permCheckClt <- mkPermCheckCltArbiter(vec(
        sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ
    ));
    mkConnection(permCheckClt, simPermCheckSrv);

    // Extract RDMA request metadata and payload
    let reqPktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(sendSideQP.rdmaReqRespPipeOut);
    let reqPayloadSink <- mkSink(reqPktMetaDataAndPayloadPipeOut.payload);
    let reqPktMetaDataPipeOut = reqPktMetaDataAndPayloadPipeOut.pktMetaData;
    let reqPktMetaDataSink <- mkSink(reqPktMetaDataPipeOut);

    // Empty pipe check
    let addSendQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        sendSideQP.workCompPipeOutRQ,
        "sendSideQP.workCompPipeOutRQ empty assertion @ mkTestQueuePairTimeOutCase"
    ));
    // let addRecvQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
    //     sendSideQP.workCompPipeOutSQ,
    //     "sendSideQP.workCompPipeOutSQ empty assertion @ mkTestQueuePairTimeOutCase"
    // ));

    Reg#(Bool) firstWorkReqSavedReg <- mkReg(False);
    Reg#(WorkReq) firstWorkReqReg <- mkRegU;
    // Count#(Bit#(TLog#(DEFAULT_RETRY_NUM))) retryCnt <- mkCount();
    // let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // rule compareWorkReq;
    //     let pktMetaData = reqPktMetaDataPipeOut.first;
    //     reqPktMetaDataPipeOut.deq;

    //     let bth = extractBTH(pktMetaData.pktHeader.headerData);
    //     let rdmaOpCode = bth.opcode;

    //     // let workReq4Ref = workReqPipeOut4Ref.first;
    //     // if (isLastOrOnlyRdmaOpCode(rdmaOpCode)) begin
    //     //     workReqPipeOut4Ref.deq;
    //     // end

    //     // immAssert(
    //     //     rdmaReqOpCodeMatchWorkReqOpCode(rdmaOpCode, workReq4Ref.opcode),
    //     //     "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestQueuePairTimeOutCase",
    //     //     $format(
    //     //         "RDMA request opcode=", fshow(rdmaOpCode),
    //     //         " should match workReqOpCode=", fshow(workReq4Ref.opcode)
    //     //     )
    //     // );

    //     $display(
    //         "time=%0t: rdmaOpCode=", $time, fshow(rdmaOpCode)
    //         // " not match WR=", fshow(workReq4Ref)
    //     );
    //     // countDown.decr;
    // endrule

    // TODO: find out why workReqPipeOut4Ref size > MAX_QP_WR or flush this buffer will deadlock?
    rule saveFirstWorkReq if (!firstWorkReqSavedReg);
        let workReq4Ref = workReqPipeOut4Ref.first;
        workReqPipeOut4Ref.deq;

        if (!firstWorkReqSavedReg) begin
            firstWorkReqReg <= workReq4Ref;
            firstWorkReqSavedReg <= True;
        end
    endrule

    rule checkTimeOutErrWC if (firstWorkReqSavedReg);
        let timeOutErrWC = sendSideQP.workCompPipeOutSQ.first;
        sendSideQP.workCompPipeOutSQ.deq;

        immAssert(
            workCompMatchWorkReqInSQ(timeOutErrWC, firstWorkReqReg),
            "workCompMatchWorkReqInSQ assertion @ mkTestQueuePairTimeOutErrCase",
            $format(
                "timeOutErrWC=", fshow(timeOutErrWC),
                " not match WR=", fshow(firstWorkReqReg)
            )
        );

        let expectedWorkCompStatus = IBV_WC_RESP_TIMEOUT_ERR;
        immAssert(
            timeOutErrWC.status == expectedWorkCompStatus,
            "workCompSQ.status assertion @ mkTestQueuePairTimeOutErrCase",
            $format(
                "timeOutErrWC=", fshow(timeOutErrWC),
                " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        // $display(
        //     "time=%0t: timeOutErrWC=", $time, fshow(timeOutErrWC),
        //     " not match WR=", fshow(firstWorkReqReg)
        // );
        normalExit;
    endrule
endmodule

(* synthesize *)
module mkTestQueuePairNormalCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    let sendSideQP <- mkQP;
    let recvSideQP <- mkQP;

    // Set QP to RTS
    let setExpectedPsnAsNextPSN = True;
    let setZero2ExpectedPsnAndNextPSN = True;
    let setSendQ2RTS <- mkChange2CntrlStateRTS(
        sendSideQP.srvPortQP, qpType, pmtu,
        setExpectedPsnAsNextPSN, setZero2ExpectedPsnAndNextPSN
    );
    let setRecvQ2RTS <- mkChange2CntrlStateRTS(
        recvSideQP.srvPortQP, qpType, pmtu,
        setExpectedPsnAsNextPSN, setZero2ExpectedPsnAndNextPSN
    );

    // WorkReq
    Vector#(2, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minPayloadLen, maxPayloadLen);
    let workReqPipeOut = workReqPipeOutVec[0];
    let workReqPipeOut4Ref <- mkBufferN(8, workReqPipeOutVec[1]);
    mkConnection(toGet(workReqPipeOut), sendSideQP.workReqIn);
    FIFOF#(WorkReq) emptyWorkReqQ <- mkFIFOF;
    mkConnection(toGet(emptyWorkReqQ), recvSideQP.workReqIn);

    // RecvReq
    Vector#(2, PipeOut#(RecvReq)) recvReqBufVec <- mkSimGenRecvReq;
    let recvReqPipeOut = recvReqBufVec[0];
    let recvReqPipeOut4Ref <- mkBufferN(valueOf(MAX_QP_WR), recvReqBufVec[1]);
    mkConnection(toGet(recvReqPipeOut), recvSideQP.recvReqIn);
    FIFOF#(RecvReq) emptyRecvReqQ <- mkFIFOF;
    mkConnection(toGet(emptyRecvReqQ), sendSideQP.recvReqIn);

    // DMA
    // let dmaReadClt  <- mkDmaReadCltAribter(vec(sendSideQP.dmaReadClt, recvSideQP.dmaReadClt));
    // let dmaWriteClt <- mkDmaWriteCltAribter(vec(sendSideQP.dmaWriteClt, recvSideQP.dmaWriteClt));
    // let dmaReadClt  <- mkDmaReadCltAribter(vec(sendSideQP.dmaReadClt4SQ, sendSideQP.dmaReadClt4RQ, recvSideQP.dmaReadClt4RQ, recvSideQP.dmaReadClt4SQ));
    // let dmaWriteClt <- mkDmaWriteCltAribter(vec(sendSideQP.dmaWriteClt4SQ, sendSideQP.dmaWriteClt4RQ, recvSideQP.dmaWriteClt4RQ, recvSideQP.dmaWriteClt4SQ));
    // let simDmaReadSrv  <- mkSimDmaReadSrv;
    // let simDmaWriteSrv <- mkSimDmaWriteSrv;
    // mkConnection(dmaReadClt, simDmaReadSrv);
    // mkConnection(dmaWriteClt, simDmaWriteSrv);
    Vector#(4, DmaReadClt)  dmaReadCltVec  = vec(sendSideQP.dmaReadClt4SQ, sendSideQP.dmaReadClt4RQ, recvSideQP.dmaReadClt4SQ, recvSideQP.dmaReadClt4RQ);
    Vector#(4, DmaWriteClt) dmaWriteCltVec = vec(sendSideQP.dmaWriteClt4SQ, sendSideQP.dmaWriteClt4RQ, recvSideQP.dmaWriteClt4SQ, recvSideQP.dmaWriteClt4RQ);
    Vector#(4, DmaReadSrv)  simDmaReadSrvVec  <- replicateM(mkSimDmaReadSrv);
    Vector#(4, DmaWriteSrv) simDmaWriteSrvVec <- replicateM(mkSimDmaWriteSrv);
    for (Integer idx = 0; idx < 4; idx = idx + 1) begin
        mkConnection(dmaReadCltVec[idx], simDmaReadSrvVec[idx]);
        mkConnection(dmaWriteCltVec[idx], simDmaWriteSrvVec[idx]);
    end

    // MR permission check
    let mrCheckPassOrFail = True;
    // let simPermCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);
    // let permCheckClt <- mkPermCheckCltArbiter(vec(
    //     sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ, recvSideQP.permCheckClt4RQ, recvSideQP.permCheckClt4SQ
    // ));
    // mkConnection(permCheckClt, simPermCheckSrv);
    Vector#(4, PermCheckSrv) simPermCheckVec  <- replicateM(mkSimPermCheckSrv(mrCheckPassOrFail));
    Vector#(4, PermCheckClt) permCheckCltVec = vec(
        sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ, recvSideQP.permCheckClt4RQ, recvSideQP.permCheckClt4SQ
    );
    for (Integer idx = 0; idx < 4; idx = idx + 1) begin
        mkConnection(permCheckCltVec[idx], simPermCheckVec[idx]);
    end

    let reqPktMetaDataAndPayloadPipeOut  <- mkSimExtractNormalHeaderPayload(sendSideQP.rdmaReqRespPipeOut);
    let respPktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(recvSideQP.rdmaReqRespPipeOut);

    // // Build RdmaPktMetaData and payload DataStream for requests
    // let spMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let isRespPkt4SQ = False;
    // let reqPktMetaDataAndPayloadPipeOut <- mkSimInputPktBuf4SingleQP(
    //     isRespPkt4SQ, sendSideQP.rdmaReqRespPipeOut, spMetaData
    // );
    // // Build RdmaPktMetaData and payload DataStream for responses
    // let rpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let isRespPkt2SQ = True;
    // let respPktMetaDataAndPayloadPipeOut <- mkSimInputPktBuf4SingleQP(
    //     isRespPkt2SQ, recvSideQP.rdmaReqRespPipeOut, rpMetaData
    // );
    // Connect SQ and RQ
    mkConnection(reqPktMetaDataAndPayloadPipeOut, recvSideQP.reqPktPipeIn);
    mkConnection(respPktMetaDataAndPayloadPipeOut, sendSideQP.respPktPipeIn);

    // Empty pipe check
    let addSendQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        sendSideQP.workCompPipeOutRQ,
        "sendSideQP.workCompPipeOutRQ empty assertion @ mkTestQueuePairNormalCase"
    ));
    let addRecvQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        recvSideQP.workCompPipeOutSQ,
        "recvSideQP.workCompPipeOutSQ empty assertion @ mkTestQueuePairNormalCase"
    ));

    // mkSink(sendSideQP.workCompPipeOutSQ);
    // mkSink(workReqPipeOut4Ref);
    // mkSink(recvSideQP.workCompPipeOutRQ);
    // mkSink(recvReqPipeOut4Ref);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule compareWorkComp4SQ;
        let workReq4Ref = workReqPipeOut4Ref.first;
        workReqPipeOut4Ref.deq;

        let workCompSQ = sendSideQP.workCompPipeOutSQ.first;
        sendSideQP.workCompPipeOutSQ.deq;

        immAssert(
            workCompMatchWorkReqInSQ(workCompSQ, workReq4Ref),
            "workCompMatchWorkReqInSQ assertion @ mkTestQueuePairNormalCase",
            $format("WC=", fshow(workCompSQ), " not match WR=", fshow(workReq4Ref))
        );

        let expectedWorkCompStatus = IBV_WC_SUCCESS;
        immAssert(
            workCompSQ.status == expectedWorkCompStatus,
            "workCompSQ.status assertion @ mkTestQueuePairNormalCase",
            $format(
                "WC=", fshow(workCompSQ), " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        // $display(
        //     "time=%0t: WC=", $time, fshow(workCompSQ), " not match WR=", fshow(workReq4Ref)
        // );
    endrule

    rule compareWorkComp4RQ;
        let recvReq4Ref = recvReqPipeOut4Ref.first;
        recvReqPipeOut4Ref.deq;

        let workCompRQ = recvSideQP.workCompPipeOutRQ.first;
        recvSideQP.workCompPipeOutRQ.deq;

        immAssert(
            workCompRQ.id == recvReq4Ref.id,
            "workCompRQ.id assertion @ mkTestQueuePairNormalCase",
            $format(
                "WC ID=", fshow(workCompRQ.id),
                " not match expected recvReqID=", fshow(recvReq4Ref.id))
        );

        let expectedWorkCompStatus = IBV_WC_SUCCESS;
        immAssert(
            workCompRQ.status == expectedWorkCompStatus,
            "workCompRQ.status assertion @ mkTestQueuePairNormalCase",
            $format(
                "WC=", fshow(workCompRQ), " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        countDown.decr;
        // $display(
        //     "time=%0t: WC=", $time, fshow(workCompRQ), " not match RR=", fshow(recvReq4Ref)
        // );
    endrule
endmodule
