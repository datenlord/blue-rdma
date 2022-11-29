import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import DataTypes :: *;
import Settings :: *;
import SimDma :: *;
import Utils4Test :: *;
import Utils :: *;

function Length headerMetaData2DmaLen(HeaderMetaData hmd) = zeroExtend(hmd.headerLen);

(* synthesize *)
module mkTestHeaderAndDataStreamConversion(Empty);
    let alwaysHasPayload = False;
    let minHeaderLen = 1;
    let maxHeaderLen = fromInteger(valueOf(HEADER_MAX_BYTE_LENGTH));

    Vector#(3, PipeOut#(HeaderMetaData)) headerMetaDataPipeOutVec <-
        mkRandomHeaderMetaPipeOut(minHeaderLen, maxHeaderLen, alwaysHasPayload);
    let headerMetaDataPipeOut4Dma = headerMetaDataPipeOutVec[0];
    let headerMetaDataPipeOut4Conv <- mkBufferN(4, headerMetaDataPipeOutVec[1]);
    let headerMetaDataPipeOut4Ref  <- mkBufferN(4, headerMetaDataPipeOutVec[2]);

    let dmaLenPipeOut <- mkFunc2Pipe(headerMetaData2DmaLen, headerMetaDataPipeOut4Dma);
    Vector#(2, DataStreamPipeOut) dataStreamPipeOutVec <-
        mkFixedLenSimDataStreamPipeOut(dmaLenPipeOut);
    let dataStreamPipeOut4Conv = dataStreamPipeOutVec[0];
    let dataStreamPipeOut4Ref <- mkBufferN(2, dataStreamPipeOutVec[1]);

    let ds2hPipeOut <- mkDataStream2Header(
        dataStreamPipeOut4Conv, headerMetaDataPipeOut4Conv
    );
    let h2dsPipeOut <- mkHeader2DataStream(ds2hPipeOut);

    rule compareHeaderMetaData;
        let headerMetaData = h2dsPipeOut.headerMetaData.first;
        h2dsPipeOut.headerMetaData.deq;

        let refHeaderMetaData = headerMetaDataPipeOut4Ref.first;
        headerMetaDataPipeOut4Ref.deq;

        dynAssert(
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

        dynAssert(
            headerDataStream == refDataStream,
            "headerDataStream assertion @ mkTestHeaderAndDataStreamConversion",
            $format(
                "headerDataStream=", fshow(headerDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );
    endrule
endmodule

(* synthesize *)
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
    let headerMetaDataPipeOut4Prepend <- mkBufferN(4, headerMetaDataPipeOutVec[1]);

    let dmaLenPipeOut <- mkFunc2Pipe(headerMetaData2DmaLen, headerMetaDataPipeOut4Dma);
    Vector#(2, DataStreamPipeOut) dataStreamPipeOutVec <-
        mkFixedLenSimDataStreamPipeOut(dmaLenPipeOut);
    let headerDataStreamPipeOut4Prepend = dataStreamPipeOutVec[0];
    let headerDataStreamPipeOut4Ref <- mkBufferN(2, dataStreamPipeOutVec[1]);

    let prependHeader2PipeOut <- mkPrependHeader2PipeOut(
        headerDataStreamPipeOut4Prepend, headerMetaDataPipeOut4Prepend, emptyDataStreamPipeOut
    );

    rule compare;
        let dataStreamAfterPrepend = prependHeader2PipeOut.first;
        prependHeader2PipeOut.deq;

        let refDataStream = headerDataStreamPipeOut4Ref.first;
        headerDataStreamPipeOut4Ref.deq;

        dynAssert(
            dataStreamAfterPrepend == refDataStream,
            "dataStreamAfterPrepend assertion @ mkTestPrependHeaderToEmptyDataStream",
            $format(
                "dataStreamAfterPrepend=", fshow(dataStreamAfterPrepend),
                " should == refDataStream=", fshow(refDataStream)
            )
        );
    endrule
endmodule

(* synthesize *)
module mkTestExtractHeaderWithLessThanOneFragPayload(Empty);
    let alwaysHasPayload = True;
    Length minPayloadLen = 1;
    Length maxPayloadLen = 7;
    HeaderByteNum minHeaderLen = 1;
    HeaderByteNum maxHeaderLen = 64;

    Vector#(1, PipeOut#(Length)) payloadLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minPayloadLen, maxPayloadLen);

    function ActionValue#(Length) headerLen2DmaLen(HeaderByteNum headerLen);
        actionvalue
            let payloadLen = payloadLenPipeOutVec[0].first;
            payloadLenPipeOutVec[0].deq;
            return zeroExtend(headerLen) + payloadLen;
        endactionvalue
    endfunction

    Vector#(2, PipeOut#(HeaderByteNum)) headerLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minHeaderLen, maxHeaderLen);
    let headerLenPipeOut = headerLenPipeOutVec[0];
    Vector#(2, PipeOut#(HeaderMetaData)) headerMetaDataPipeOutVec <-
        mkFixedLenHeaderMetaPipeOut(
            headerLenPipeOut, alwaysHasPayload
        );
    let headerMetaDataPipeOut4Extract = headerMetaDataPipeOutVec[0];
    let headerMetaDataPipeOut4Prepend <- mkBufferN(2, headerMetaDataPipeOutVec[1]);

    PipeOut#(Length) dmaLenPipeOut <- mkActionValueFunc2Pipe(
        headerLen2DmaLen, headerLenPipeOutVec[1]
    );
    Vector#(2, DataStreamPipeOut) dataStreamPipeOutVec <-
        mkFixedLenSimDataStreamPipeOut(dmaLenPipeOut);
    let dataStreamPipeOut4Extract = dataStreamPipeOutVec[0];
    let dataStreamPipeOut4Ref <- mkBufferN(2, dataStreamPipeOutVec[1]);

    let extractHeaderFromPipeOut <- mkExtractHeaderFromDataStreamPipeOut(
        dataStreamPipeOut4Extract, headerMetaDataPipeOut4Extract
    );
    let prependHeader2PipeOut <- mkPrependHeader2PipeOut(
        extractHeaderFromPipeOut.header,
        headerMetaDataPipeOut4Prepend,
        extractHeaderFromPipeOut.payload
    );

    rule compare;
        let prependHeaderDataStream = prependHeader2PipeOut.first;
        prependHeader2PipeOut.deq;

        let refDataStream = dataStreamPipeOut4Ref.first;
        dataStreamPipeOut4Ref.deq;

        dynAssert(
            prependHeaderDataStream == refDataStream,
            "prependHeaderDataStream assertion @ mkTestExtractHeaderWithLessThanOneFragPayload",
            $format(
                "prependHeaderDataStream=", fshow(prependHeaderDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );
    endrule
endmodule

(* synthesize *)
module mkTestExtractHeaderLongerThanDataStream(Empty);
    let minDmaLength = 1;
    let maxDmaLength = fromInteger(valueOf(HEADER_MAX_BYTE_LENGTH)) - 1;

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
        mkRandomLenSimDataStreamPipeOut(minDmaLength, maxDmaLength);
    let headerMetaDataPipeOut <- mkConstantPipeOut(headerMetaData);
    let extractHeaderFromPipeOut <- mkExtractHeaderFromDataStreamPipeOut(
        dataStreamPipeOutVec[0], headerMetaDataPipeOut
    );
    let refDataStreamPipeOut = dataStreamPipeOutVec[1];

    rule compareHeaderDataStream;
        let headerDataStream = extractHeaderFromPipeOut.header.first;
        extractHeaderFromPipeOut.header.deq;

        let refDataStream = refDataStreamPipeOut.first;
        refDataStreamPipeOut.deq;

        dynAssert(
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

        dynAssert(
            isZero(payloadDataStream.byteEn),
            "payloadDataStream.byteEn assertion @ mkTestExtractHeaderLongerThanDataStream",
            $format(
                "payloadDataStream.byteEn=%h should be all zero",
                payloadDataStream.byteEn
            )
        );
        // $display("time=%0d: payloadDataStream=", $time, fshow(payloadDataStream));
    endrule
endmodule

(* synthesize *)
module mkTestExtractAndPrependHeader(Empty);
    let alwaysHasPayload = True; // TODO: support no payload case
    let minDmaLength = 128;
    let maxDmaLength = 256;
    let minHeaderLen = 1;
    let maxHeaderLen = 64;

    Vector#(2, DataStreamPipeOut) dataStreamPipeOutVec <-
        mkRandomLenSimDataStreamPipeOut(minDmaLength, maxDmaLength);
    Vector#(2, PipeOut#(HeaderMetaData)) headerMetaDataPipeOutVec <-
        mkRandomHeaderMetaPipeOut(minHeaderLen, maxHeaderLen, alwaysHasPayload);
    let headerMetaDataPipeOut4Extract = headerMetaDataPipeOutVec[0];
    let headerMetaDataPipeOut4Prepend <- mkBufferN(2, headerMetaDataPipeOutVec[1]);
    let extractHeaderFromPipeOut <- mkExtractHeaderFromDataStreamPipeOut(
        dataStreamPipeOutVec[0], headerMetaDataPipeOut4Extract
    );
    let prependHeader2PipeOut <- mkPrependHeader2PipeOut(
        extractHeaderFromPipeOut.header,
        headerMetaDataPipeOut4Prepend,
        extractHeaderFromPipeOut.payload
    );
    let refDataStreamPipeOut <- mkBufferN(2, dataStreamPipeOutVec[1]);

    rule compare;
        let prependHeaderDataStream = prependHeader2PipeOut.first;
        prependHeader2PipeOut.deq;

        let refDataStream = refDataStreamPipeOut.first;
        refDataStreamPipeOut.deq;

        dynAssert(
            prependHeaderDataStream == refDataStream,
            "prependHeaderDataStream assertion @ mkTestExtractAndPrependHeader",
            $format(
                "prependHeaderDataStream=", fshow(prependHeaderDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );
    endrule
endmodule
