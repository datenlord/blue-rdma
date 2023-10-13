import ClientServer :: *;
import Cntrs :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Randomizable :: *;
import Vector :: *;

import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Settings :: *;
import Utils :: *;
import Utils4Test :: *;

function DataStream getDmaReadRespData(
    DmaReadResp dmaReadResp
) = dmaReadResp.dataStream;

function DataStream getDmaWriteReqData(
    DmaWriteReq dmaWriteReq
) = dmaWriteReq.dataStream;

// DmaReadResp 2 PipeOut
module mkPipeOutFromDmaReadResp#(Get#(DmaReadResp) resp)(PipeOut#(DmaReadResp));
    PipeOut#(DmaReadResp) ret <- mkSource_from_fav(resp.get);
    return ret;
endmodule

module mkDataStreamPipeOutFromDmaReadResp#(Get#(DmaReadResp) resp)(DataStreamPipeOut);
    PipeOut#(DmaReadResp) dmaReadRespPipeOut <- mkPipeOutFromDmaReadResp(resp);
    DataStreamPipeOut ret <- mkFunc2Pipe(getDmaReadRespData, dmaReadRespPipeOut);
    // rule display;
    //     $display(
    //         "Before segment: time=%0t, isFirst=%b, isLast=%b, byteEn=%h",
    //         $time, ret.first.isFirst, ret.first.isLast, ret.first.byteEn
    //     );
    // endrule

    return ret;
endmodule

interface DmaReadSrvAndReqRespPipeOut;
    interface DmaReadSrv dmaReadSrv;
    interface PipeOut#(DmaReadReq) dmaReadReq;
    interface PipeOut#(DmaReadResp) dmaReadResp;
endinterface

// TODO: proper handle DMA cancel requests if QP reset
module mkSimDmaReadSrvAndReqRespPipeOut(DmaReadSrvAndReqRespPipeOut);
    FIFOF#(DmaReadReq)      dmaReadReqQ <- mkFIFOF;
    FIFOF#(DmaReadResp)    dmaReadRespQ <- mkFIFOF;
    FIFOF#(DmaReadReq)   dmaReadReqOutQ <- mkFIFOF;
    FIFOF#(DmaReadResp) dmaReadRespOutQ <- mkFIFOF;

    // Randomize#(DataStream) randomDataStream <- mkGenericRandomizer;
    // Reg#(Bool) dmaReadSrvInitReg <- mkReg(False);
    DataStreamPipeOut randomDataStreamPipeOut <- mkGenericRandomPipeOut;

    Reg#(TotalFragNum) remainingFragNumReg <- mkRegU;
    Reg#(Bool) busyReg <- mkReg(False);
    Reg#(Bool) isFirstReg <- mkRegU;
    Reg#(ByteEn) lastFragByteEnReg <- mkRegU;
    Reg#(BusBitNum) lastFragInvalidBitNumReg <- mkRegU;
    Reg#(DmaReadReq) curReqReg <- mkRegU;

    Bool isFragCntZero = isZero(remainingFragNumReg);

    // rule debugNotFull if (!(
    //     dmaReadReqQ.notFull    &&
    //     dmaReadRespQ.notFull   &&
    //     dmaReadReqOutQ.notFull &&
    //     dmaReadRespOutQ.notFull
    // ));
    //     $display(
    //         "time=%0t: mkSimDmaReadSrvAndReqRespPipeOut debug", $time,
    //         ", dmaReadReqQ.notFull=", fshow(dmaReadReqQ.notFull),
    //         ", dmaReadRespQ.notFull=", fshow(dmaReadRespQ.notFull),
    //         ", dmaReadReqOutQ.notFull=", fshow(dmaReadReqOutQ.notFull),
    //         ", dmaReadRespOutQ.notFull=", fshow(dmaReadRespOutQ.notFull)
    //     );
    // endrule

    // rule debugNotEmpty if (!(
    //     dmaReadReqQ.notEmpty    &&
    //     dmaReadRespQ.notEmpty   &&
    //     dmaReadReqOutQ.notEmpty &&
    //     dmaReadRespOutQ.notEmpty
    // ));
    //     $display(
    //         "time=%0t: mkSimDmaReadSrvAndReqRespPipeOut debug", $time,
    //         ", dmaReadReqQ.notEmpty=", fshow(dmaReadReqQ.notEmpty),
    //         ", dmaReadRespQ.notEmpty=", fshow(dmaReadRespQ.notEmpty),
    //         ", dmaReadReqOutQ.notEmpty=", fshow(dmaReadReqOutQ.notEmpty),
    //         ", dmaReadRespOutQ.notEmpty=", fshow(dmaReadRespOutQ.notEmpty)
    //     );
    // endrule

    // rule init if (!dmaReadSrvInitReg);
    //     randomDataStream.cntrl.init;

    //     dmaReadReqQ.clear;
    //     dmaReadRespQ.clear;
    //     dmaReadReqOutQ.clear;
    //     dmaReadRespOutQ.clear;

    //     // isFirstReg <= True;
    //     busyReg <= False;
    //     dmaReadSrvInitReg <= True;
    //     // $display("time=%0t: SimDmaReadSrv inited", $time);
    // endrule

    rule acceptReq if (!busyReg); // && dmaReadSrvInitReg);
        let dmaReadReq = dmaReadReqQ.first;
        dmaReadReqQ.deq;
        dmaReadReqOutQ.enq(dmaReadReq);

        // if (
        //     dmaReadReq.initiator == DMA_SRC_SQ_CANCEL ||
        //     dmaReadReq.initiator == DMA_SRC_RQ_CANCEL
        // ) begin
        //     dmaReadSrvInitReg <= False;

        //     // $display(
        //     //     "time=%0t: mkSimDmaReadSrvAndReqRespPipeOut acceptReq", $time,
        //     //     ", cancel DMA read, initiator=", fshow(dmaReadReq.initiator)
        //     // );
        // end
        // else begin
        // end
        let isZeroLen = isZero(dmaReadReq.len);
        immAssert(
            !isZeroLen,
            "dmaReadReq.len non-zero assrtion",
            $format("dmaReadReq.len=%0d should not be zero", dmaReadReq.len)
        );

        let { totalFragCnt, lastFragByteEn, lastFragValidByteNum } =
            calcTotalFragNumByLength(zeroExtend(dmaReadReq.len));
        let { lastFragValidBitNum, lastFragInvalidByteNum, lastFragInvalidBitNum } =
            calcFragBitNumAndByteNum(lastFragValidByteNum);

        remainingFragNumReg <= isZeroLen ? 0 : totalFragCnt - 1;
        lastFragByteEnReg <= lastFragByteEn;
        lastFragInvalidBitNumReg <= lastFragInvalidBitNum;

        immAssert(
            !isZero(lastFragByteEn),
            "lastFragByteEn non-zero assertion",
            $format(
                "lastFragByteEn=%h should not have zero ByteEn, dmaReadReq.len=%0d",
                lastFragByteEn, dmaReadReq.len
            )
        );

        curReqReg <= dmaReadReq;
        busyReg <= True;
        isFirstReg <= True;

        // $display(
        //     "time=%0t: mkSimDmaReadSrvAndReqRespPipeOut acceptReq", $time,
        //     ", DMA read request, wr.id=%h, dmaReadReq.len=%0d, totalFragCnt=%0d",
        //     dmaReadReq.mrID, dmaReadReq.len, totalFragCnt
        // );
    endrule

    rule genResp if (busyReg); // && dmaReadSrvInitReg);
        remainingFragNumReg <= remainingFragNumReg - 1;
        // let dataStream <- randomDataStream.next;
        let dataStream = randomDataStreamPipeOut.first;
        randomDataStreamPipeOut.deq;

        dataStream.isFirst = isFirstReg;
        isFirstReg <= False;
        dataStream.isLast = isFragCntZero;
        dataStream.byteEn = maxBound;

        if (isFragCntZero) begin
            busyReg <= False;
            dataStream.byteEn = lastFragByteEnReg;
            DATA tmpData = dataStream.data >> lastFragInvalidBitNumReg;
            dataStream.data = truncate(tmpData << lastFragInvalidBitNumReg);
        end

        let resp = DmaReadResp {
            initiator : curReqReg.initiator,
            sqpn      : curReqReg.sqpn,
            isRespErr : False,
            dataStream: dataStream
        };
        dmaReadRespQ.enq(resp);
        dmaReadRespOutQ.enq(resp);

        immAssert(
            !isZero(dataStream.byteEn),
            "dmaReadResp.data.byteEn non-zero assertion",
            $format("dmaReadResp.data should not have zero ByteEn, ", fshow(dataStream))
        );
        // $display(
        //     "time=%0t: mkSimDmaReadSrvAndReqRespPipeOut genResp", $time,
        //     ", DMA read response, wr.id=%h, remainingFragNum=%0d",
        //     curReqReg.mrID, remainingFragNumReg,
        //     // ", dataStream=", fshow(dataStream)
        //     ", dataStream.isFirst=", fshow(dataStream.isFirst),
        //     ", dataStream.isLast=", fshow(dataStream.isLast)
        // );
    endrule

    interface dmaReadSrv  = toGPServer(dmaReadReqQ, dmaReadRespQ);
    interface dmaReadReq  = toPipeOut(dmaReadReqOutQ);
    interface dmaReadResp = toPipeOut(dmaReadRespOutQ);
endmodule

interface DmaReadSrvAndDataStreamPipeOut;
    interface DmaReadSrv dmaReadSrv;
    interface DataStreamPipeOut dataStream;
endinterface

module mkSimDmaReadSrvAndDataStreamPipeOut(DmaReadSrvAndDataStreamPipeOut);
    let simDmaReadSrv <- mkSimDmaReadSrvAndReqRespPipeOut;
    mkSink(simDmaReadSrv.dmaReadReq);
    DataStreamPipeOut dataStreamPipeOut <- mkFunc2Pipe(
        getDmaReadRespData, simDmaReadSrv.dmaReadResp
    );

    interface dmaReadSrv = simDmaReadSrv.dmaReadSrv;
    interface dataStream = dataStreamPipeOut;
endmodule

module mkSimDmaReadSrv(DmaReadSrv);
    let simDmaReadSrv <- mkSimDmaReadSrvAndReqRespPipeOut;
    mkSink(simDmaReadSrv.dmaReadReq);
    mkSink(simDmaReadSrv.dmaReadResp);
    return simDmaReadSrv.dmaReadSrv;
endmodule

module mkSimDmaReadSrvWithErr#(
    Bool hasRespErr, Length minErrLen, Length maxErrLen
)(DmaReadSrv);
    let simDmaReadSrv <- mkSimDmaReadSrvAndReqRespPipeOut;
    mkSink(simDmaReadSrv.dmaReadReq);
    mkSink(simDmaReadSrv.dmaReadResp);

    let errLenPipeOut <- mkRandomLenPipeOut(minErrLen, maxErrLen);
    FIFOF#(DmaReadResp) dmaReadRespQ <- mkFIFOF;
    Count#(Length) payloadLenCnt <- mkCount(0);
    Reg#(Bool) errRespGenReg <- mkReg(False);

    rule genErrDmaReadRespIfNeeded;
        let dmaReadResp <- simDmaReadSrv.dmaReadSrv.response.get;
        let curFragLen = calcByteEnBitNumInSim(dmaReadResp.dataStream.byteEn);
        let errLen = errLenPipeOut.first;

        dmaReadResp.isRespErr = errRespGenReg;
        if (hasRespErr) begin
            if (!errRespGenReg) begin
                if (payloadLenCnt >= errLen) begin
                    payloadLenCnt <= 0;
                    dmaReadResp.isRespErr = True;
                    errRespGenReg <= True;
                    errLenPipeOut.deq;
                end
                else begin
                    payloadLenCnt <= payloadLenCnt + zeroExtend(curFragLen);
                end
            end
        //     dmaReadRespQ.enq(dmaReadResp);
        // end
        // else begin
        end
        dmaReadRespQ.enq(dmaReadResp);

        // $display(
        //     "time=%0t: genErrDmaReadRespIfNeeded", $time,
        //     ", dmaReadResp.isRespErr=", fshow(dmaReadResp.isRespErr),
        //     ", payloadLenCnt=%0d", payloadLenCnt,
        //     ", errLen=%0d", errLen
        // );
    endrule

    interface request = simDmaReadSrv.dmaReadSrv.request;
    interface response = toGet(dmaReadRespQ);
endmodule

interface DmaWriteSrvAndReqRespPipeOut;
    interface DmaWriteSrv dmaWriteSrv;
    interface PipeOut#(DmaWriteReq) dmaWriteReq;
    interface PipeOut#(DmaWriteResp) dmaWriteResp;
endinterface

// TODO: proper handle DMA cancel requests if QP reset
module mkSimDmaWriteSrvAndReqRespPipeOut(DmaWriteSrvAndReqRespPipeOut);
    FIFOF#(DmaWriteReq)      dmaWriteReqQ <- mkFIFOF;
    FIFOF#(DmaWriteResp)    dmaWriteRespQ <- mkFIFOF;
    FIFOF#(DmaWriteReq)   dmaWriteReqOutQ <- mkFIFOF;
    FIFOF#(DmaWriteResp) dmaWriteRespOutQ <- mkFIFOF;

    // Reg#(Bool) dmaWriteSrvInitReg <- mkReg(False);

    function Action genDmaWriteResp(DmaWriteMetaData metaData);
        action
            let dmaWriteResp = DmaWriteResp {
                initiator: metaData.initiator,
                sqpn     : metaData.sqpn,
                psn      : metaData.psn,
                isRespErr: False
            };
            // $display("time=%0t: dmaWriteResp=", $time, fshow(dmaWriteResp));

            dmaWriteRespQ.enq(dmaWriteResp);
            dmaWriteRespOutQ.enq(dmaWriteResp);
        endaction
    endfunction

    // rule init if (!dmaWriteSrvInitReg);
    //     dmaWriteReqQ.clear;
    //     dmaWriteRespQ.clear;
    //     dmaWriteReqOutQ.clear;
    //     dmaWriteRespOutQ.clear;

    //     dmaWriteSrvInitReg <= True;
    //     // $display("time=%0t: SimDmaWriteSrv inited", $time);
    // endrule

    rule write; // if (dmaWriteSrvInitReg);
        let dmaWriteReq = dmaWriteReqQ.first;
        dmaWriteReqQ.deq;
        dmaWriteReqOutQ.enq(dmaWriteReq);

        // if (
        //     dmaWriteReq.metaData.initiator == DMA_SRC_SQ_CANCEL ||
        //     dmaWriteReq.metaData.initiator == DMA_SRC_RQ_CANCEL
        // ) begin
        //     dmaWriteSrvInitReg <= False;
        //     genDmaWriteResp(dmaWriteReq.metaData);

        //     // $display(
        //     //     "time=%0t: cancel DMA write", $time,
        //     //     ", initiator=", fshow(dmaWriteReq.metaData.initiator)
        //     // );
        // end
        // else begin
        // end
        if (dmaWriteReq.dataStream.isLast) begin
            genDmaWriteResp(dmaWriteReq.metaData);
        end

        // $display("time=%0t: dmaWriteReq=", $time, fshow(dmaWriteReq));
    endrule

    interface dmaWriteSrv  = toGPServer(dmaWriteReqQ, dmaWriteRespQ);
    interface dmaWriteReq  = toPipeOut(dmaWriteReqOutQ);
    interface dmaWriteResp = toPipeOut(dmaWriteRespOutQ);
endmodule

interface DmaWriteSrvAndDataStreamPipeOut;
    interface DmaWriteSrv dmaWriteSrv;
    interface DataStreamPipeOut dataStream;
endinterface

module mkSimDmaWriteSrvAndDataStreamPipeOut(DmaWriteSrvAndDataStreamPipeOut);
    let simDmaWriteSrv <- mkSimDmaWriteSrvAndReqRespPipeOut;
    mkSink(simDmaWriteSrv.dmaWriteResp);
    DataStreamPipeOut dataStreamPipeOut <- mkFunc2Pipe(
        getDmaWriteReqData, simDmaWriteSrv.dmaWriteReq
    );

    interface dmaWriteSrv = simDmaWriteSrv.dmaWriteSrv;
    interface dataStream = dataStreamPipeOut;
endmodule

module mkSimDmaWriteSrv(DmaWriteSrv);
    let simDmaWriteSrv <- mkSimDmaWriteSrvAndReqRespPipeOut;
    mkSink(simDmaWriteSrv.dmaWriteReq);
    mkSink(simDmaWriteSrv.dmaWriteResp);
    return simDmaWriteSrv.dmaWriteSrv;
endmodule

module mkFixedPktLenDataStreamPipeOut#(
    PipeOut#(PktLen) pktLenPipeOut
)(Vector#(vSz, DataStreamPipeOut));
    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dataStreamPipeOut <- mkDataStreamPipeOutFromDmaReadResp(simDmaReadSrv.response);
    Vector#(vSz, DataStreamPipeOut) dataStreamPipeOutVec <- mkForkVector(dataStreamPipeOut);

    rule sendDmaReq;
        let pktLen = pktLenPipeOut.first;
        pktLenPipeOut.deq;

        let dmaReq = DmaReadReq {
            initiator: DMA_SRC_RQ_RD,
            sqpn     : getDefaultQPN,
            startAddr: dontCareValue,
            len      : pktLen,
            mrID     : dontCareValue
        };
        simDmaReadSrv.request.put(dmaReq);
        // $display("time=%0t: pktLen=%0d", $time, pktLen);
    endrule

    return dataStreamPipeOutVec;
endmodule

// typedef Vector#(vSz, DataStreamPipeOut) SimDataStreamPipeOut#(type numeric vSz);
module mkRandomPktLenDataStreamPipeOut#(
    PktLen minPktLen, PktLen maxPktLen
)(Vector#(vSz, DataStreamPipeOut));
    Vector#(1, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minPktLen, maxPktLen);
    let pktLenPipeOut = pktLenPipeOutVec[0];
    Vector#(vSz, DataStreamPipeOut) simDataStreamPipeOut <-
        mkFixedPktLenDataStreamPipeOut(pktLenPipeOut);

    return simDataStreamPipeOut;
endmodule

(* doc = "testcase" *)
module mkTestFixedPktLenDataStreamPipeOut(Empty);
    let minPktLen = 1;
    let maxPktLen = 125;

    Vector#(1, PipeOut#(PktLen)) pktLenPipeOutVec <- mkRandomValueInRangePipeOut(minPktLen, maxPktLen);
    let { pktLenPipeOut4Gen, pktLenPipeOut4Ref } <- mkForkAndBufferRight(pktLenPipeOutVec[0]);
    Vector#(1, DataStreamPipeOut) simDataStreamPipeOutVec <-
        mkFixedPktLenDataStreamPipeOut(pktLenPipeOut4Gen);
    Reg#(PktLen) refPktLenReg <- mkRegU;
    Reg#(PktLen) pktLenReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule compare;
        let curDataStreamFrag = simDataStreamPipeOutVec[0].first;
        simDataStreamPipeOutVec[0].deq;

        let curFragLen = calcByteEnBitNumInSim(curDataStreamFrag.byteEn);

        let totalPktLen = pktLenReg;
        let refPktLen = refPktLenReg;
        if (curDataStreamFrag.isFirst) begin
            refPktLen = pktLenPipeOut4Ref.first;
            pktLenPipeOut4Ref.deq;
            refPktLenReg <= refPktLen;

            totalPktLen = zeroExtend(curFragLen);
            pktLenReg <= zeroExtend(curFragLen);
        end
        else begin
            totalPktLen = pktLenReg + zeroExtend(curFragLen);
            pktLenReg <= totalPktLen;
        end

        if (curDataStreamFrag.isLast) begin
            immAssert(
                totalPktLen == refPktLen,
                "dataStream length assertion @ mkTestFixedPktLenDataStreamPipeOut",
                $format("totalPktLen=%0d should == refPktLen=%0d", totalPktLen, refPktLen)
            );
        end

        countDown.decr;
    endrule
endmodule

(* doc = "testcase" *)
module mkTestDmaReadAndWriteSrv(Empty);
    let minPktLen = 1;
    let maxPktLen = 4096;

    Vector#(1, PipeOut#(PktLen)) pktLenPipeOutVec <- mkRandomValueInRangePipeOut(minPktLen, maxPktLen);
    let pktLenPipeOut = pktLenPipeOutVec[0];

    Reg#(PSN) psnReg <- mkReg(0);
    FIFOF#(DmaWriteMetaData) dmaWriteMetaDataQ <- mkFIFOF;

    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaWriteSrv <- mkSimDmaWriteSrvAndDataStreamPipeOut;

    let expectedDmaWriteDataStreamPipeOut <- mkBufferN(2, simDmaReadSrv.dataStream);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule issueDmaReadReq;
        let pktLen = pktLenPipeOut.first;
        pktLenPipeOut.deq;

        let dmaReadReq = DmaReadReq {
            initiator: DMA_SRC_RQ_RD,
            sqpn     : getDefaultQPN,
            startAddr: dontCareValue,
            len      : pktLen,
            mrID     : dontCareValue
        };
        simDmaReadSrv.dmaReadSrv.request.put(dmaReadReq);

        let dmaWriteMetaData = DmaWriteMetaData {
            initiator: DMA_SRC_RQ_WR,
            sqpn     : getDefaultQPN,
            startAddr: dontCareValue,
            len      : pktLen,
            psn      : psnReg,
            mrID     : dontCareValue
        };
        psnReg <= psnReg + 1;
        dmaWriteMetaDataQ.enq(dmaWriteMetaData);
        // $display("time=%0t: issueDmaReadReq, pktLen=%0d", $time, pktLen);
    endrule

    rule issueDmaWriteReq;
        let dmaWriteMetaData = dmaWriteMetaDataQ.first;
        let dmaReadResp <- simDmaReadSrv.dmaReadSrv.response.get;
        let dmaReadRespDataStream = dmaReadResp.dataStream;

        if (dmaReadRespDataStream.isLast) begin
            dmaWriteMetaDataQ.deq;
        end

        let dmaWriteReq = DmaWriteReq {
            metaData   : dmaWriteMetaData,
            dataStream : dmaReadRespDataStream
        };
        simDmaWriteSrv.dmaWriteSrv.request.put(dmaWriteReq);
        // $display(
        //     "time=%0t: issueDmaWriteReq", $time,
        //     ", dmaWriteMetaData=", fshow(dmaWriteMetaData)
        // );
    endrule

    rule recvDmaWriteResp;
        let dmaWriteResp <- simDmaWriteSrv.dmaWriteSrv.response.get;
        countDown.decr;
    endrule

    rule compareDataStream;
        let actualDataStream = simDmaWriteSrv.dataStream.first;
        simDmaWriteSrv.dataStream.deq;

        let expectedDataStream = expectedDmaWriteDataStreamPipeOut.first;
        expectedDmaWriteDataStreamPipeOut.deq;

        immAssert(
            actualDataStream == expectedDataStream,
            "DMA read and write DataStream assertion @ mkTestDmaReadAndWriteSrv",
            $format(
                "actualDataStream=", fshow(actualDataStream),
                " should == expectedDataStream=", fshow(expectedDataStream)
            )
        );
    endrule
endmodule
