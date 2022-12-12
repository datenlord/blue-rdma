import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import Utils :: *;

interface HeaderAndMetaDataAndPayloadSeperateDataStreamPipeOut;
    interface HeaderDataStreamAndMetaDataPipeOut headerAndMetaData;
    interface DataStreamPipeOut payload;
endinterface

// After extract header from rdmaPktPipeIn,
// it outputs header DataStream and payload DataStream,
// and every header DataStream has corresponding payload DataStream,
// if header has no payload, then output empty payload DataStream.
// This module will not discard invalid packet.
module mkExtractHeaderFromRdmaPktPipeOut#(
    DataStreamPipeOut rdmaPktPipeIn
)(HeaderAndMetaDataAndPayloadSeperateDataStreamPipeOut);
// TODO: reset mkExtractHeaderFromRdmaPktPipeOut when error or retry
    FIFOF#(HeaderMetaData) headerMetaDataInQ <- mkFIFOF;
    FIFOF#(DataStream) dataInQ <- mkFIFOF;

    Vector#(2, PipeOut#(HeaderMetaData)) headerMetaDataPipeOutVec <-
        mkForkVector(convertFifo2PipeOut(headerMetaDataInQ));
    let headerMetaDataPipeIn = headerMetaDataPipeOutVec[0];
    let headerMetaDataPipeOut = headerMetaDataPipeOutVec[1];
    let dataPipeIn = convertFifo2PipeOut(dataInQ);
    let headerAndPayloadPipeOut <- mkExtractHeaderFromDataStreamPipeOut(
        dataPipeIn, headerMetaDataPipeIn
    );

    rule extractHeader;
        let rdmaPktDataStream = rdmaPktPipeIn.first;
        rdmaPktPipeIn.deq;
        dataInQ.enq(rdmaPktDataStream);

        if (rdmaPktDataStream.isFirst) begin
            let { transType, rdmaOpCode } =
                extractTranTypeAndRdmaOpCode(rdmaPktDataStream.data);

            let headerHasPayload = rdmaOpCodeHasPayload(rdmaOpCode);
            HeaderByteNum headerLen = fromInteger(
                calcHeaderLenByTransTypeAndRdmaOpCode(transType, rdmaOpCode)
            );
            dynAssert(
                !isZero(headerLen),
                "!isZero(headerLen) assertion @ mkExtractHeaderFromRdmaPktPipeOut",
                $format(
                    "headerLen=%0d should not be zero, transType=",
                    headerLen, fshow(transType),
                    ", rdmaOpCode=", fshow(rdmaOpCode)
                )
            );

            let headerMetaData = genHeaderMetaData(headerLen, headerHasPayload);
            headerMetaDataInQ.enq(headerMetaData);
            // $display(
            //     "time=%0d: headerLen=%0d, transType=", $time, headerLen, fshow(transType),
            //     ", rdmaOpCode=", fshow(rdmaOpCode),
            //     ", rdmaPktDataStream=", fshow(rdmaPktDataStream),
            //     ", headerHasPayload=", fshow(headerHasPayload),
            //     ", headerMetaData=", fshow(headerMetaData)
            // );
        end
        // $display("time=%0d: rdmaPktDataStream=", $time, fshow(rdmaPktDataStream));
    endrule

    interface headerAndMetaData = interface HeaderDataStreamAndMetaDataPipeOut;
        interface headerDataStream = headerAndPayloadPipeOut.header;
        interface headerMetaData = headerMetaDataPipeOut;
    endinterface;
    interface payload = headerAndPayloadPipeOut.payload;
endmodule

interface RdmaPktMetaDataAndPayloadPipeOut;
    interface PipeOut#(RdmaPktMetaData) pktMetaData;
    interface DataStreamPipeOut payload;
endinterface

typedef enum {
    RDMA_PKT_BUF_RECV_FRAG,
    RDMA_PKT_BUF_DISCARD_FRAG
} RdmaPktBufState deriving(Bits, Eq);
// This module will discard:
// - invalid packet that header is without payload but packet has payload;
// TODO: handle invalid TransType or RdmaOpCode
// TODO: discard BTH or AETH with reserved value, and packet validation
// TODO: reset mkInputRdmaPktBufAndCalcPktLen when error or retry
module mkInputRdmaPktBufAndCalcPktLen#(
    // Only output payload when packet has non-zero payload,
    // otherwise output packet header/metadata only,
    // namely header and payload are not one-to-one mapping,
    // and packet header/metadata is aligned to the last fragment of payload.
    HeaderAndMetaDataAndPayloadSeperateDataStreamPipeOut pipeIn,
    PMTU pmtu
)(RdmaPktMetaDataAndPayloadPipeOut);
    // TODO: payloadOutQ should use BramFIFO?
    // TODO: check payloadOutQ buffer size is enough for DMA write delay?
    FIFOF#(DataStream) payloadOutQ <- mkSizedFIFOF(valueOf(DATA_STREAM_FRAG_BUF_SIZE));
    FIFOF#(RdmaPktMetaData) pktMetaDataOutQ <- mkSizedFIFOF(valueOf(PKT_META_DATA_BUF_SIZE));

    FIFOF#(DataStream) payloadTmpQ <- mkFIFOF;
    FIFOF#(RdmaHeader) rdmaHeaderTmpQ <- mkFIFOF;
    Reg#(PktLen) pktLenReg <- mkRegU;
    Reg#(PmtuFragNum) pktFragNumReg <- mkRegU;
    Reg#(Bool) pktValidReg <- mkRegU;

    Reg#(RdmaPktBufState) pktBufStateReg <- mkReg(RDMA_PKT_BUF_RECV_FRAG);

    let payloadPipeIn <- mkBufferN(2, pipeIn.payload);
    let rdmaHeaderPipeOut <- mkDataStream2Header(
        pipeIn.headerAndMetaData.headerDataStream,
        pipeIn.headerAndMetaData.headerMetaData
    );

    rule discardInvalidFrag if (pktBufStateReg == RDMA_PKT_BUF_DISCARD_FRAG);
        let payload = payloadPipeIn.first;
        payloadPipeIn.deq;
        if (payload.isLast) begin
            pktBufStateReg <= RDMA_PKT_BUF_RECV_FRAG;
        end
    endrule

    rule calcPktLen; // if (pktBufStateReg == RDMA_PKT_BUF_RECV_FRAG);
        let payloadFrag = payloadTmpQ.first;
        payloadTmpQ.deq;

        let rdmaHeader = rdmaHeaderTmpQ.first;
        let bth = extractBTH(rdmaHeader.headerData);
        // let isOnlyPkt = isOnlyRdmaOpCode(bth.opcode);
        let isLastPkt = isLastRdmaOpCode(bth.opcode);
        let isFirstOrMidPkt = isFirstOrMiddleRdmaOpCode(bth.opcode);

        let payloadFragLen = calcFragByteNumFromByteEn(payloadFrag.byteEn);
        dynAssert(
            isValid(payloadFragLen),
            "isValid(payloadFragLen) assertion @ mkInputRdmaPktBufAndCalcPktLen",
            $format(
                "payloadFragLen=", fshow(payloadFragLen), " should be valid"
            )
        );
        PktLen fragLen = zeroExtend(fromMaybe(?, payloadFragLen));
        // $display(
        //     "time=%0d: payloadFrag.byteEn=%h, payloadFrag.isFirst=",
        //     $time, payloadFrag.byteEn, fshow(payloadFrag.isFirst),
        //     ", payloadFrag.isLast=", payloadFrag.isLast,
        //     ", bth.opcode=", fshow(bth.opcode), ", bth.psn=%h", bth.psn,
        //     ", payloadFrag.data=%h", payloadFrag.data
        // );

        let isByteEnAllOne = isAllOnes(payloadFrag.byteEn);
        let pktLen = pktLenReg;
        let pktFragNum = pktFragNumReg;
        let pktValid = False;
        case ({ pack(payloadFrag.isFirst), pack(payloadFrag.isLast) })
            2'b11: begin // payloadFrag.isFirst && payloadFrag.isLast
                pktLen = fragLen;
                pktFragNum = 1;
                pktValid = isFirstOrMidPkt ? False : (isLastPkt ? (!isZero(fragLen)) : True);
            end
            2'b10: begin // payloadFrag.isFirst && !payloadFrag.isLast
                pktLen = fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
                pktFragNum = 1;
                pktValid = isByteEnAllOne;
            end
            2'b01: begin // !payloadFrag.isFirst && payloadFrag.islast
                pktLen = pktLenReg + fragLen;
                pktFragNum = pktFragNumReg + 1;
                pktValid = pktValidReg;
            end
            2'b00: begin // !payloadFrag.isFirst && !payloadFrag.islast
                pktLen = pktLenReg + fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
                pktFragNum = pktFragNumReg + 1;
                pktValid = pktValidReg && isByteEnAllOne;
            end
        endcase

        pktLenReg <= pktLen;
        pktFragNumReg <= pktFragNum;
        pktValidReg <= pktValid;

        let isZeroLen = isZero(pktLen);
        if (payloadFrag.isLast) begin
            rdmaHeaderTmpQ.deq;
            if (!isZeroLen) begin
                payloadOutQ.enq(payloadFrag);
                // $display("time=%0d: payloadFrag=", $time, fshow(payloadFrag));

            end
            else begin
                // Discard zero length payload no matter packet has payload or not
                // $info("time=%0d: discard zero-length payload for RDMA packet", $time);
            end

            let pktMetaData = RdmaPktMetaData {
                pktPayloadLen: pktLen,
                pktFragNum   : (isZeroLen ? 0 : pktFragNum),
                pktHeader    : rdmaHeader,
                pktValid     : (isFirstOrMidPkt ? pktLenEqPMTU(pktLen, pmtu) : pktValid)
            };
            pktMetaDataOutQ.enq(pktMetaData);
            // $display(
            //     "time=%0d: bth=", $time, fshow(bth), ", pktMetaData=", fshow(pktMetaData)
            // );
        end
        else begin
            payloadOutQ.enq(payloadFrag);
            // $display("time=%0d: payloadFrag=", $time, fshow(payloadFrag));
        end
    endrule

    rule recvPktFrag if (pktBufStateReg == RDMA_PKT_BUF_RECV_FRAG);
        let payloadFrag = payloadPipeIn.first;
        payloadPipeIn.deq;
        let payloadHasSingleFrag = payloadFrag.isFirst && payloadFrag.isLast;
        let fragHasNoData = isZero(payloadFrag.byteEn);

        let rdmaHeader = rdmaHeaderPipeOut.first;
        if (payloadFrag.isFirst) begin
            rdmaHeaderPipeOut.deq;
            let bth = extractBTH(rdmaHeader.headerData);

            // Discard packet that should not have payload
            if (!rdmaHeader.headerMetaData.hasPayload) begin
                if (payloadHasSingleFrag && fragHasNoData) begin
                    rdmaHeaderTmpQ.enq(rdmaHeader);
                    // Keep the empty payload of the packet without payload for now.
                    payloadTmpQ.enq(payloadFrag);

                    // $display(
                    //     "time=%0d: bth=", $time, fshow(bth),
                    //     ", headerMetaData=", fshow(rdmaHeader.headerMetaData)
                    // );
                end
                else if (!payloadFrag.isLast) begin
                    $warning(
                        "time=%0d: discard RDMA packet should not have multi-fragment payload", $time
                    );
                    pktBufStateReg <= RDMA_PKT_BUF_DISCARD_FRAG;
                end
                else begin
                    $warning(
                        "time=%0d: discard RDMA packet should not have single-fragment payload", $time
                    );
                end
            end
            else begin
                // Packet has payload
                rdmaHeaderTmpQ.enq(rdmaHeader);
                payloadTmpQ.enq(payloadFrag);

                // $display(
                //     "time=%0d: bth=", $time, fshow(bth),
                //     ", headerMetaData=", fshow(rdmaHeader.headerMetaData),
                //     "\ntime=%0d: payloadFrag=", $time, fshow(payloadFrag)
                // );
            end
        end
        else begin
            payloadTmpQ.enq(payloadFrag);
            // $display("time=%0d: payloadFrag=", $time, fshow(payloadFrag));
        end
    endrule

    interface pktMetaData = convertFifo2PipeOut(pktMetaDataOutQ);
    interface payload = convertFifo2PipeOut(payloadOutQ);
endmodule
