import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import InputPktHandle :: *;
import PrimUtils :: *;
import Settings :: *;
import SimDma :: *;
import SimGenRdmaReqResp :: *;
import Utils :: *;
import Utils4Test :: *;

module mkSimExtractNormalHeaderPayload#(DataStreamPipeOut rdmaPktPipeIn)(
    RdmaPktMetaDataAndPayloadPipeOut
);
    FIFOF#(RdmaPktMetaData) pktMetaDataOutQ <- mkFIFOF;
    FIFOF#(DataStream)          payloadOutQ <- mkFIFOF;

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

        // Do not use rdmaHeader.headerMetaData.hasPayload here,
        // since it is only depend on RdamOpCode
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
            // $display(
            //     "time=%0t: mkSimExtractNormalHeaderPayload recvPktFrag", $time,
            //     ", bth.opcode=", fshow(bth.opcode),
            //     ", bth.psn=%h", bth.psn,
            //     ", bthPadCnt=%0d", bthPadCnt,
            //     ", fragLen=%0d", fragLen,
            //     ", payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
            //     ", payloadFrag.isLast=", fshow(payloadFrag.isLast),
            //     ", fragLenWithOutPad=%0d", fragLenWithOutPad,
            //     ", pktFragNum=%0d", pktFragNum,
            //     ", pktLen=%0d", pktLen,
            //     ", rdmaHeader=", fshow(rdmaHeader)
            // );
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

    interface pktMetaData = toPipeOut(pktMetaDataOutQ);
    interface payload     = toPipeOut(payloadOutQ);
endmodule

(* doc = "testcase" *)
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
