import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Randomizable :: *;
import Vector :: *;
// import SVA :: *;

import Assertions :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import DataTypes :: *;
import Settings :: *;
import SimDmaHandler :: *;
import TestSettings :: *;
import Utils :: *;

(* synthesize *)
module mkTestHeaderAndDataStreamConversion(Empty);
    let minHeaderLen = 1;
    let maxHeaderLen = fromInteger(valueOf(MAX_HEADER_BYTE_LENGTH));

    FIFOF#(HeaderAndByteEn) headerQ <- mkFIFOF;
    FIFOF#(HeaderAndByteEn) headerRefQ <- mkFIFOF;
    Vector#(2, PipeOut#(HeaderByteNum)) randomHeaderLenPipeOutVec <-
        mkRandomHeaderLenPipeOut(minHeaderLen, maxHeaderLen);

    let headerLenPipeOut <- mkBuffer_n(2, randomHeaderLenPipeOutVec[0]);
    let headerLenPipeOutRef = randomHeaderLenPipeOutVec[1];
    // let { randomHeaderLenPipeOutRef, randomHeaderLenPipeOut } = randomHeaderLenPipeOutTuple;
    let headerDataPipeOut <- mkRandomHeaderDataPipeOut;
    let h2dsPipeOut <- mkHeader2DataStream(convertFifo2PipeOut(headerQ));
    let ds2hPipeOut <- mkDataStream2Header(h2dsPipeOut, headerLenPipeOut);
    let countDown <- mkCountDown;

    rule genHeader;
        let headerLen = headerLenPipeOutRef.first;
        headerLenPipeOutRef.deq;

        let headerData = headerDataPipeOut.first;
        headerDataPipeOut.deq;

        let { headerFragNum, headerLastFragValidByteNum } =
            calcHeaderFragNumAndLastFragByeEnBitNum(headerLen);
        let { headerLastFragValidBitNum, headerLastFragInvalidByteNum, headerLastFragInvalidBitNum } =
            calcFragBitByteNum(headerLastFragValidByteNum);

        let rightShiftedHeaderData = headerData >> headerLastFragInvalidBitNum;
        let leftAlignedHeaderData = reverseBits(rightShiftedHeaderData);
        // HeaderData headerData = zeroExtendLSB(rawHeader);
        HeaderByteEn headerByteEn = (1 << headerLen) - 1;
        let leftAlignedHeaderByteEn = reverseBits(headerByteEn);
        let headerAndByteEn = HeaderAndByteEn {
            headerData: leftAlignedHeaderData,
            headerByteEn: headerByteEn,
            headerFragNum: headerFragNum,
            lastFragValidByteNum: headerLastFragValidByteNum
        };
        $display(
            "headerAndByteEn.headerData=%h, headerAndByteEn.headerByteEn=%h, headerLen=%0d, headerFragNum=%0d, headerLastFragValidByteNum=%0d, headerLastFragInvalidByteNum=%0d, headerLastFragInvalidBitNum=%0d",
            headerAndByteEn.headerData, headerAndByteEn.headerByteEn, headerLen, headerFragNum, headerLastFragValidByteNum, headerLastFragInvalidByteNum, headerLastFragInvalidBitNum
        );
        headerQ.enq(headerAndByteEn);
        headerRefQ.enq(headerAndByteEn);
    endrule

    rule compHeader;
        let headerAndByteEn = ds2hPipeOut.first;
        ds2hPipeOut.deq;

        let refHeaderAndByteEn = headerRefQ.first;
        headerRefQ.deq;

        dynAssert(
            headerAndByteEn != refHeaderAndByteEn,
            "headerAndByteEn assertion",
            $format(
                "headerAndByteEn=%s should == refHeaderAndByteEn=%s",
                fshow(headerAndByteEn), fshow(refHeaderAndByteEn)
            )
        );
    endrule
endmodule

(* synthesize *)
module mkTestExtractHeaderLongerThanDataStream(Empty);
    let minDmaLength = 1;
    let maxDmaLength = fromInteger(valueOf(MAX_HEADER_BYTE_LENGTH));
    HeaderByteNum headerLen = fromInteger(valueOf(MAX_HEADER_BYTE_LENGTH));

    Vector#(2, PipeOut#(DataStream)) dataStreamPipeOutVec <-
        mkRandomLenSimDataStreamPipeOut(minDmaLength, maxDmaLength);
    let headerLenPipeOut <- mkConstantPipeOut(headerLen);
    let extractHeader4PipeOut <-
        mkExtractHeader4PipeOut(dataStreamPipeOutVec[0], headerLenPipeOut);
    let refDataStreamPipeOut = dataStreamPipeOutVec[1];

    rule compare;
        let headerPipeOut = extractHeader4PipeOut.header.first;
        extractHeader4PipeOut.header.deq;

        let refDataStream = refDataStreamPipeOut.first;
        refDataStreamPipeOut.deq;

        dynAssert(
            headerPipeOut == refDataStream,
            "headerPipeOut assertion @ mkTestExtractHeaderLongerThanDataStream",
            $format(
                "headerPipeOut=", fshow(headerPipeOut),
                " should == refDataStream=", fshow(refDataStream)
            )
        );

        dynAssert(
            !extractHeader4PipeOut.data.notEmpty,
            "extractHeader4PipeOut assertion @ mkTestExtractHeaderLongerThanDataStream",
            $format(
                "extractHeader4PipeOut.data.notEmpty=%b should be False",
                extractHeader4PipeOut.data.notEmpty
            )
        );
    endrule
endmodule

(* synthesize *)
module mkTestExtractAndPrependHeader(Empty);
    let minDmaLength = 128;
    let maxDmaLength = 256;
    let minHeaderLen = 1;
    let maxHeaderLen = 64;

    Vector#(2, PipeOut#(DataStream)) dataStreamPipeOutVec <-
        mkRandomLenSimDataStreamPipeOut(minDmaLength, maxDmaLength);
    // let { headerLenPipeOut4Extract, headerLenPipeOut4Prepend } <-
    Vector#(2, PipeOut#(HeaderByteNum)) headerLenPipeOutVec <- 
        mkRandomHeaderLenPipeOut(minHeaderLen, maxHeaderLen);
    let headerLenPipeOut4Extract = headerLenPipeOutVec[0];
    let headerLenPipeOut4Prepend <- mkBuffer_n(2, headerLenPipeOutVec[1]);
    let extractHeader4PipeOut <- mkExtractHeader4PipeOut(
        dataStreamPipeOutVec[0], headerLenPipeOut4Extract
    );
    let prependHeader2PipeOut <- mkPrependHeader2PipeOut(
        extractHeader4PipeOut.header, headerLenPipeOut4Prepend, extractHeader4PipeOut.data
    );
    let refDataStreamPipeOut <- mkBuffer_n(2, dataStreamPipeOutVec[1]);

    rule compare;
        let prependHeaderDataStream = prependHeader2PipeOut.first;
        prependHeader2PipeOut.deq;

        let refDataStream = refDataStreamPipeOut.first;
        refDataStreamPipeOut.deq;

        dynAssert(
            prependHeaderDataStream == refDataStream,
            "DataStream assertion @ mkTestExtractAndPrependHeader",
            $format(
                "prependHeaderDataStream=", fshow(prependHeaderDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );
    endrule
endmodule
