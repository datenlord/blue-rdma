import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import DataTypes :: *;
import Settings :: *;
import SimDma :: *;
import PrimUtils :: *;
import Utils :: *;
import Utils4Test :: *;

function PktLen headerMetaData2PktLen(HeaderMetaData hmd) = zeroExtend(hmd.headerLen);

(* doc = "testcase" *)
module mkTestHeaderAndDataStreamConversion(Empty);
    let alwaysHasPayload = False;
    let minHeaderLen = 1;
    let maxHeaderLen = fromInteger(valueOf(HEADER_MAX_BYTE_LENGTH));

    Vector#(3, PipeOut#(HeaderMetaData)) headerMetaDataPipeOutVec <-
        mkRandomHeaderMetaPipeOut(minHeaderLen, maxHeaderLen, alwaysHasPayload);
    let headerMetaDataPipeOut4Dma = headerMetaDataPipeOutVec[0];
    let headerMetaDataPipeOut4Conv <- mkBufferN(2, headerMetaDataPipeOutVec[1]);
    let headerMetaDataPipeOut4Ref  <- mkBufferN(2, headerMetaDataPipeOutVec[2]);

    let pktLenPipeOut <- mkFunc2Pipe(headerMetaData2PktLen, headerMetaDataPipeOut4Dma);
    Vector#(2, DataStreamPipeOut) dataStreamPipeOutVec <-
        mkFixedPktLenDataStreamPipeOut(pktLenPipeOut);
    let dataStreamPipeOut4Conv = dataStreamPipeOutVec[0];
    let dataStreamPipeOut4Ref <- mkBufferN(2, dataStreamPipeOutVec[1]);

    let ds2hPipeOut <- mkDataStream2Header(
        dataStreamPipeOut4Conv, headerMetaDataPipeOut4Conv
    );
    Reg#(Bool) clearReg <- mkReg(True);
    let h2dsPipeOut <- mkHeader2DataStream(clearReg, ds2hPipeOut);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule clearAll if (clearReg);
        clearReg <= False;
    endrule

    rule compareHeaderMetaData;
        let headerMetaData = h2dsPipeOut.headerMetaData.first;
        h2dsPipeOut.headerMetaData.deq;

        let refHeaderMetaData = headerMetaDataPipeOut4Ref.first;
        headerMetaDataPipeOut4Ref.deq;

        immAssert(
            headerMetaData == refHeaderMetaData,
            "headerMetaData assertion @ mkTestHeaderAndDataStreamConversion",
            $format(
                "headerMetaData=", headerMetaData,
                " should == refHeaderMetaData=", refHeaderMetaData
            )
        );
    endrule

    rule compareHeaderDataStream;
        let headerDataStream = h2dsPipeOut.headerDataStream.first;
        h2dsPipeOut.headerDataStream.deq;

        let refDataStream = dataStreamPipeOut4Ref.first;
        dataStreamPipeOut4Ref.deq;

        immAssert(
            headerDataStream == refDataStream,
            "headerDataStream assertion @ mkTestHeaderAndDataStreamConversion",
            $format(
                "headerDataStream=", fshow(headerDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );

        countDown.decr;
    endrule
endmodule

(* doc = "testcase" *)
module mkTestPrependHeaderBeforeEmptyDataStream(Empty);
    let alwaysHasPayload = False;
    let minHeaderLen = 1;
    let maxHeaderLen = fromInteger(valueOf(HEADER_MAX_BYTE_LENGTH));
    let emptyDataStream = DataStream {
        data: 0,
        byteEn: 0,
        isFirst: True,
        isLast: True
    };

    let emptyDataStreamPipeOut <- mkConstantPipeOut(emptyDataStream);
    Vector#(2, PipeOut#(HeaderMetaData)) headerMetaDataPipeOutVec <-
        mkRandomHeaderMetaPipeOut(minHeaderLen, maxHeaderLen, alwaysHasPayload);
    let headerMetaDataPipeOut4Dma = headerMetaDataPipeOutVec[0];
    let headerMetaDataPipeOut4Prepend <- mkBufferN(2, headerMetaDataPipeOutVec[1]);

    let pktLenPipeOut <- mkFunc2Pipe(headerMetaData2PktLen, headerMetaDataPipeOut4Dma);
    Vector#(2, DataStreamPipeOut) dataStreamPipeOutVec <-
        mkFixedPktLenDataStreamPipeOut(pktLenPipeOut);
    let headerDataStreamPipeOut4Prepend = dataStreamPipeOutVec[0];
    let headerDataStreamPipeOut4Ref <- mkBufferN(2, dataStreamPipeOutVec[1]);

    Reg#(Bool) clearReg <- mkReg(True);
    let prependHeader2PipeOut <- mkPrependHeader2PipeOut(
        clearReg,
        headerDataStreamPipeOut4Prepend,
        headerMetaDataPipeOut4Prepend,
        emptyDataStreamPipeOut
    );

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule clearAll if (clearReg);
        clearReg <= False;
    endrule

    rule compare;
        let dataStreamAfterPrepend = prependHeader2PipeOut.first;
        prependHeader2PipeOut.deq;

        let refDataStream = headerDataStreamPipeOut4Ref.first;
        headerDataStreamPipeOut4Ref.deq;

        immAssert(
            dataStreamAfterPrepend == refDataStream,
            "dataStreamAfterPrepend assertion @ mkTestPrependHeaderToEmptyDataStream",
            $format(
                "dataStreamAfterPrepend=", fshow(dataStreamAfterPrepend),
                " should == refDataStream=", fshow(refDataStream)
            )
        );

        countDown.decr;
    endrule
endmodule

(* doc = "testcase" *)
module mkTestExtractHeaderWithPayloadLessThanOneFrag(Empty);
    let alwaysHasPayload = True;
    PktLen minPktPayloadLen = 1;
    PktLen maxPktPayloadLen = 7;
    HeaderByteNum minHeaderLen = 1;
    HeaderByteNum maxHeaderLen = 64;

    Vector#(1, PipeOut#(PktLen)) pktPayloadLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minPktPayloadLen, maxPktPayloadLen);
    let pktPayloadLenPipeOut = pktPayloadLenPipeOutVec[0];

    function ActionValue#(PktLen) headerLen2PktLen(HeaderByteNum headerLen);
        actionvalue
            let pktPayloadLen = pktPayloadLenPipeOut.first;
            pktPayloadLenPipeOut.deq;
            return zeroExtend(headerLen) + pktPayloadLen;
        endactionvalue
    endfunction

    Vector#(2, PipeOut#(HeaderByteNum)) headerLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minHeaderLen, maxHeaderLen);
    let headerLenPipeOut = headerLenPipeOutVec[0];
    Vector#(2, PipeOut#(HeaderMetaData)) headerMetaDataPipeOutVec <-
        mkFixedLenHeaderMetaPipeOut(headerLenPipeOut, alwaysHasPayload);
    let headerMetaDataPipeOut4Extract = headerMetaDataPipeOutVec[0];
    let headerMetaDataPipeOut4Prepend <- mkBufferN(2, headerMetaDataPipeOutVec[1]);

    PipeOut#(PktLen) pktLenPipeOut <- mkActionValueFunc2Pipe(
        headerLen2PktLen, headerLenPipeOutVec[1]
    );
    Vector#(2, DataStreamPipeOut) dataStreamPipeOutVec <-
        mkFixedPktLenDataStreamPipeOut(pktLenPipeOut);
    let dataStreamPipeOut4Extract = dataStreamPipeOutVec[0];
    let dataStreamPipeOut4Ref <- mkBufferN(2, dataStreamPipeOutVec[1]);

    let extractHeaderFromPipeOut <- mkExtractHeaderFromDataStreamPipeOut(
        dataStreamPipeOut4Extract, headerMetaDataPipeOut4Extract
    );

    Reg#(Bool) clearReg <- mkReg(True);
    let prependHeader2PipeOut <- mkPrependHeader2PipeOut(
        clearReg,
        extractHeaderFromPipeOut.header,
        headerMetaDataPipeOut4Prepend,
        extractHeaderFromPipeOut.payload
    );

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule clearAll if (clearReg);
        clearReg <= False;
    endrule

    rule compare;
        let prependHeaderDataStream = prependHeader2PipeOut.first;
        prependHeader2PipeOut.deq;

        let refDataStream = dataStreamPipeOut4Ref.first;
        dataStreamPipeOut4Ref.deq;

        immAssert(
            prependHeaderDataStream == refDataStream,
            "prependHeaderDataStream assertion @ mkTestExtractHeaderWithLessThanOneFragPayload",
            $format(
                "prependHeaderDataStream=", fshow(prependHeaderDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );

        countDown.decr;
    endrule
endmodule

(* doc = "testcase" *)
module mkTestExtractHeaderLongerThanDataStream(Empty);
    let minPktLen = 1;
    let maxPktLen = fromInteger(valueOf(HEADER_MAX_BYTE_LENGTH)) - 1;

    HeaderByteNum headerLen = fromInteger(valueOf(HEADER_MAX_BYTE_LENGTH));
    let { headerFragNum, headerLastFragValidByteNum } =
        calcHeaderFragNumAndLastFragValidByeNum(headerLen);
    let headerMetaData = HeaderMetaData {
        headerLen: headerLen,
        headerFragNum: headerFragNum,
        lastFragValidByteNum: headerLastFragValidByteNum,
        hasPayload: True
    };

    Vector#(2, DataStreamPipeOut) dataStreamPipeOutVec <-
        mkRandomPktLenDataStreamPipeOut(minPktLen, maxPktLen);
    let headerMetaDataPipeOut <- mkConstantPipeOut(headerMetaData);
    let extractHeaderFromPipeOut <- mkExtractHeaderFromDataStreamPipeOut(
        dataStreamPipeOutVec[0], headerMetaDataPipeOut
    );
    let refDataStreamPipeOut <- mkBufferN(2, dataStreamPipeOutVec[1]);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule compareHeaderDataStream;
        let headerDataStream = extractHeaderFromPipeOut.header.first;
        extractHeaderFromPipeOut.header.deq;

        let refDataStream = refDataStreamPipeOut.first;
        refDataStreamPipeOut.deq;

        immAssert(
            headerDataStream == refDataStream,
            "headerDataStream assertion @ mkTestExtractHeaderLongerThanDataStream",
            $format(
                "headerDataStream=", fshow(headerDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );
    endrule

    rule comparePayloadDataStream;
        let payloadDataStream = extractHeaderFromPipeOut.payload.first;
        extractHeaderFromPipeOut.payload.deq;

        immAssert(
            isZero(payloadDataStream.byteEn),
            "payloadDataStream.byteEn assertion @ mkTestExtractHeaderLongerThanDataStream",
            $format(
                "payloadDataStream.byteEn=%h should be all zero",
                payloadDataStream.byteEn
            )
        );

        countDown.decr;
        // $display("time=%0t: payloadDataStream=", $time, fshow(payloadDataStream));
    endrule
endmodule

(* doc = "testcase" *)
module mkTestExtractAndPrependHeader(Empty);
    let alwaysHasPayload = True; // TODO: support no payload case
    let minPktLen = 128;
    let maxPktLen = 256;
    let minHeaderLen = 1;
    let maxHeaderLen = 64;

    Vector#(2, DataStreamPipeOut) dataStreamPipeOutVec <-
        mkRandomPktLenDataStreamPipeOut(minPktLen, maxPktLen);
    Vector#(2, PipeOut#(HeaderMetaData)) headerMetaDataPipeOutVec <-
        mkRandomHeaderMetaPipeOut(minHeaderLen, maxHeaderLen, alwaysHasPayload);
    let headerMetaDataPipeOut4Extract = headerMetaDataPipeOutVec[0];
    let headerMetaDataPipeOut4Prepend <- mkBufferN(2, headerMetaDataPipeOutVec[1]);
    let extractHeaderFromPipeOut <- mkExtractHeaderFromDataStreamPipeOut(
        dataStreamPipeOutVec[0], headerMetaDataPipeOut4Extract
    );

    Reg#(Bool) clearReg <- mkReg(True);
    let prependHeader2PipeOut <- mkPrependHeader2PipeOut(
        clearReg,
        extractHeaderFromPipeOut.header,
        headerMetaDataPipeOut4Prepend,
        extractHeaderFromPipeOut.payload
    );
    let refDataStreamPipeOut <- mkBufferN(2, dataStreamPipeOutVec[1]);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule clearAll if (clearReg);
        clearReg <= False;
    endrule

    rule compare;
        let prependHeaderDataStream = prependHeader2PipeOut.first;
        prependHeader2PipeOut.deq;

        let refDataStream = refDataStreamPipeOut.first;
        refDataStreamPipeOut.deq;

        immAssert(
            prependHeaderDataStream == refDataStream,
            "prependHeaderDataStream assertion @ mkTestExtractAndPrependHeader",
            $format(
                "prependHeaderDataStream=", fshow(prependHeaderDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );

        countDown.decr;
    endrule
endmodule
